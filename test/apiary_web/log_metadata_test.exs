defmodule ApiaryWeb.LogMetadataTest do
  @moduledoc """
  Every log line of a request, a LiveView and a contract call carries the organisation and
  workspace ids: they are put into the Logger metadata where each begins.
  A test's request runs in the test's own process, so its metadata is read there; a
  LiveView reports its own.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Contract.Signature
  alias Apiary.LogMetadata

  @none %{organisation_id: nil, workspace_id: nil, user_id: nil}

  # A page that puts ids into its metadata as the mount hooks do, and reports what its
  # async work runs under.
  defmodule AsyncLive do
    use ApiaryWeb, :live_view

    @impl true
    def mount(_params, %{"test" => test, "ids" => ids}, socket) do
      if connected?(socket) do
        Apiary.LogMetadata.restore(ids)
      end

      {:ok,
       socket
       |> assign_async(:ids, fn ->
         send(test, {:assign_async, Apiary.LogMetadata.get()})
         {:ok, %{ids: :sent}}
       end)
       |> start_async(:ids, fn -> send(test, {:start_async, Apiary.LogMetadata.get()}) end)
       |> stream_async(:rows, fn ->
         send(test, {:stream_async, Apiary.LogMetadata.get()})
         {:ok, []}
       end)}
    end

    @impl true
    def handle_async(:ids, _result, socket), do: {:noreply, socket}

    @impl true
    def render(assigns), do: ~H"<p>async</p>"
  end

  defp ids(%{organisation: organisation, workspace: workspace}),
    do: %{organisation_id: organisation.id, workspace_id: workspace.id}

  # A LiveView reports the metadata its process has once it has mounted: its mount's stop
  # event runs in that process, after the on_mount hooks. Only a connected mount of this
  # test's user is reported, since the handler sees every test's LiveViews.
  defp report_mounts(user_id) do
    test = self()
    handler = "log-metadata-test-#{inspect(test)}"

    :telemetry.attach(
      handler,
      [:phoenix, :live_view, :mount, :stop],
      fn _event, _measurements, %{socket: socket}, _config ->
        scope = socket.assigns[:current_scope]

        if (Phoenix.LiveView.connected?(socket) and scope) && scope.user &&
             scope.user.id == user_id do
          send(test, {:mounted, socket.view, LogMetadata.get()})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # A function that captured a socket (a literal one the compiler would fold away).
  defp reads_socket(socket), do: fn -> socket.assigns end

  describe "a path-scoped request" do
    setup :register_and_log_in_user

    test "carries the ids of the organisation and the workspace its path names", %{
      conn: conn,
      scope: scope
    } do
      assert LogMetadata.get() == @none
      conn = get(conn, ~p"/#{scope.organisation}")
      assert redirected_to(conn) == ~p"/#{scope.organisation}/#{scope.workspace}"
      assert LogMetadata.get() == Map.put(ids(scope), :user_id, scope.user.id)
    end

    test "carries only the person when the path names an organisation they are no member of",
         %{conn: conn, scope: scope} do
      other = sign_up_fixture()
      assert conn |> get(~p"/#{other.organisation}") |> response(404)
      assert LogMetadata.get() == %{@none | user_id: scope.user.id}
    end

    test "of a person's own page carries the person and no organisation", %{
      conn: conn,
      scope: scope
    } do
      assert conn |> get(~p"/users/settings") |> html_response(200)
      assert LogMetadata.get() == %{@none | user_id: scope.user.id}
    end
  end

  describe "a LiveView" do
    setup :register_and_log_in_user

    test "carries the ids of its organisation and workspace from its mount", %{
      conn: conn,
      scope: scope
    } do
      report_mounts(scope.user.id)
      {:ok, _view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings")
      assert_receive {:mounted, ApiaryWeb.SettingsLive, metadata}
      assert metadata == Map.put(ids(scope), :user_id, scope.user.id)
    end

    test "of a person's own carries the person and no organisation", %{
      conn: conn,
      scope: scope
    } do
      report_mounts(scope.user.id)
      {:ok, _view, _html} = live(conn, ~p"/users/settings")
      assert_receive {:mounted, ApiaryWeb.UserLive.Settings, metadata}
      assert metadata == %{@none | user_id: scope.user.id}
    end

    test "runs its async work under the same ids", %{conn: conn} do
      ids = %{
        organisation_id: Ecto.UUID.generate(),
        workspace_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate()
      }

      session = %{"test" => self(), "ids" => ids}
      {:ok, _view, _html} = live_isolated(conn, __MODULE__.AsyncLive, session: session)

      assert_receive {:assign_async, ^ids}
      assert_receive {:start_async, ^ids}
      assert_receive {:stream_async, ^ids}
    end

    test "is warned of a socket its async work captured, as LiveView warns" do
      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          ApiaryWeb.Async.carry(reads_socket(%Phoenix.LiveView.Socket{}), :start_async)
        end)

      assert warning =~ "accessing the LiveView socket inside a function given to start_async"
    end
  end

  describe "a contract call" do
    setup do
      %{scope: scope} = sign_up_fixture()
      %{access_key: key, secret: secret} = access_key_fixture(scope)
      %{scope: scope, key: key, secret: secret}
    end

    defp signed_get(conn, key_id, secret) do
      path = "/.well-known/qory-configuration"
      timestamp = System.os_time(:second)
      signature = Signature.sign(secret, Signature.canonical_string("GET", path, timestamp))

      conn
      |> put_req_header("x-qory-access-key", key_id)
      |> put_req_header("x-qory-timestamp", to_string(timestamp))
      |> put_req_header("x-qory-signature-256", signature)
      |> put_req_header("x-qory-contract-version", "1")
      |> get(path)
    end

    test "carries the ids of its access key's organisation and workspace, and no person", %{
      conn: conn,
      scope: scope,
      key: key,
      secret: secret
    } do
      assert conn |> signed_get(key.key_id, secret) |> json_response(200)
      assert LogMetadata.get() == Map.put(ids(scope), :user_id, nil)
    end

    test "carries neither when the signature does not verify", %{conn: conn, key: key} do
      assert conn |> signed_get(key.key_id, "not-the-secret") |> json_response(401)
      assert LogMetadata.get() == @none
    end
  end
end
