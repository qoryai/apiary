defmodule ApiaryWeb.AdapterLive.ShowTest do
  # An integration's page in Organisation settings › Integrations
  # (`ApiaryWeb.AdapterLive.Show`): where the organisation's connection to it stands, not
  # installed, pending, its pass expired, ended on the integration, or installed, with a
  # pending or expired install not installed to a member; while not installed, the install
  # block to an owner or an admin; installed, the wait for the first listing and, a minute
  # on, the line to install again; the return's flash; behind the feature, for members.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Edition, EditionStubs, Repo}
  alias Apiary.Adapters.Connection
  alias ApiaryWeb.ConnectSession

  @moduletag needs: :factory

  setup :register_and_log_in_user

  setup do
    %{adapter: adapter, pair: pair} = connectable_adapter_fixture(%{name: "Acme tracker"})
    %{adapter: adapter, pair: pair}
  end

  defp page(scope, adapter),
    do: ~p"/#{scope.organisation}/settings/integrations/#{adapter.public_id}"

  defp words(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp member_conn(scope, level \\ :member) do
    %{user: user} = member_fixture(scope, level)
    log_in_user(build_conn(), user)
  end

  defp set(%Connection{id: id}, fields) do
    {1, _} = Repo.update_all(from(c in Connection, where: c.id == ^id), set: fields)
    :ok
  end

  defp time(at), do: ApiaryWeb.Format.time(at)

  test "with no connection: not installed, and the install block with Install",
       %{conn: conn, scope: scope, adapter: adapter} do
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert has_element?(lv, "h1", "Acme tracker")

    assert page_title(lv) =~
             "Acme tracker · Integrations · Organisation settings · #{scope.organisation.name}"

    assert has_element?(lv, ~s{#settings-tab-integrations[aria-current="true"]})

    assert has_element?(
             lv,
             ~s{#breadcrumb-section[href="/#{scope.organisation.slug}/settings/integrations"]},
             "Integrations"
           )

    assert words(lv, "#integration-status") == "Not installed."

    assert words(lv, "#integration-install") ==
             "Acme tracker then brings you back here. The repositories it reaches are listed on this page. #{scope.organisation.name} can have one installation of Acme tracker. Install"

    refute has_element?(lv, "#integration-install-name")
    refute has_element?(lv, "#integration-install-cancel")

    assert has_element?(
             lv,
             ~s{form#integration-install-form[action="#{page(scope, adapter)}/install"]}
           )

    assert has_element?(lv, "#integration-install-form-install:not([disabled])")
    refute has_element?(lv, "#collections")

    form = form(lv, "#integration-install-form")
    render_submit(form)

    assert words(lv, "#integration-install-sending") == "Taking you to Acme tracker…"

    conn = follow_trigger_action(form, conn)
    assert conn.request_path == page(scope, adapter) <> "/install"
    assert conn.resp_body =~ "https://tracker.example.com/connect?state="
  end

  test "an integration not set up yet: Install disabled, and why", %{conn: conn, scope: scope} do
    adapter = adapter_fixture(%{name: "Shop tracker"})
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert has_element?(lv, "#integration-install-form-install[disabled]")

    assert words(lv, "#integration-install-not-ready") ==
             "Shop tracker can't be installed yet: this instance's admins are still setting it up."
  end

  test "pending, its pass still good: who started it today and when", %{
    conn: conn,
    scope: scope,
    adapter: adapter
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :pending)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#integration-status") ==
             "Not installed. #{scope.user.email} started an install today at #{time(connection.updated_at)} that isn't finished: finish it on Acme tracker, or press Install to start again."

    assert has_element?(lv, "#integration-install")
  end

  test "pending, its pass expired: that it expired", %{conn: conn, scope: scope, adapter: adapter} do
    {connection, _nonce} = connection_fixture(scope, adapter, :pending)
    set(connection, pass_expires_at: DateTime.add(DateTime.utc_now(:second), -1))
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#integration-status") ==
             "Not installed. #{scope.user.email}'s install, started today at #{time(connection.updated_at)}, expired before it was finished. Press Install to start again."

    assert has_element?(lv, "#integration-install")
  end

  test "pending, started before today, or its pass came back refused or cancelled: not installed",
       %{conn: conn, scope: scope, adapter: adapter} do
    {connection, _nonce} = connection_fixture(scope, adapter, :pending)
    set(connection, pass_nonce_used_at: DateTime.utc_now())
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert words(lv, "#integration-status") == "Not installed."
    assert has_element?(lv, "#integration-install")

    set(connection,
      pass_nonce_used_at: nil,
      updated_at: DateTime.add(DateTime.utc_now(), -2, :day)
    )

    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert words(lv, "#integration-status") == "Not installed."
  end

  test "ended on the integration: when, and that its tickets left every backlog", %{
    conn: conn,
    scope: scope,
    adapter: adapter
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :listed)
    ended_at = ~U[2026-03-14 09:00:00.000000Z]
    set(connection, state: :ended, ended_at: ended_at, ended_reason: :adapter_reported)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#integration-status") ==
             "Not installed. The installation ended on #{ApiaryWeb.Format.day(ended_at)}, when Acme tracker reported it gone. The tickets Acme tracker brought in left every backlog; work items already taken in stay."

    assert has_element?(lv, "#integration-install")
    refute has_element?(lv, "#collections")
  end

  test "ended on the integration, in the adapter's words for its items, or with none", %{
    conn: conn,
    scope: scope,
    adapter: adapter
  } do
    adapter = describe_source(adapter, "example-tracker.json")
    {connection, _nonce} = connection_fixture(scope, adapter, :listed)
    ended_at = DateTime.utc_now()
    set(connection, state: :ended, ended_at: ended_at, ended_reason: :adapter_reported)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#integration-status") =~
             "The issues Acme tracker brought in left every backlog;"

    describe_source(adapter, "example-projects.json")
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#integration-status") ==
             "Not installed. The installation ended on #{ApiaryWeb.Format.day(ended_at)}, when Acme tracker reported it gone."
  end

  test "ended on the integration: before it connected, not installed; before a listing, no backlogs",
       %{conn: conn, scope: scope, adapter: adapter} do
    ended_at = ~U[2026-03-14 09:00:00.000000Z]
    {connection, _nonce} = connection_fixture(scope, adapter, :pending)
    set(connection, state: :ended, ended_at: ended_at, ended_reason: :adapter_reported)
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert words(lv, "#integration-status") == "Not installed."
    assert has_element?(lv, "#integration-install")

    gone =
      "Not installed. The installation ended on #{ApiaryWeb.Format.day(ended_at)}, when Acme tracker reported it gone."

    set(connection, connected_at: ~U[2026-03-13 09:00:00.000000Z])
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert words(lv, "#integration-status") == gone

    set(connection, listed_at: ~U[2026-03-13 09:01:00.000000Z])
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#integration-status") ==
             gone <>
               " The tickets Acme tracker brought in left every backlog; work items already taken in stay."
  end

  test "an end for another reason, or a connection after it, says no end", %{
    conn: conn,
    scope: scope,
    adapter: adapter
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    set(connection, state: :ended, ended_at: DateTime.utc_now(), ended_reason: :replaced)
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert words(lv, "#integration-status") == "Not installed."

    set(connection, ended_reason: :adapter_reported)
    connection_fixture(scope, adapter, :pending)
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert words(lv, "#integration-status") =~ "started an install today"
  end

  test "installed and not yet listed: who installed it today, and the wait for its collections",
       %{conn: conn, scope: scope, adapter: adapter} do
    connection_fixture(scope, adapter, :connected)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#integration-status") == "Installed by #{scope.user.email} today."
    refute has_element?(lv, "#integration-install")
    assert words(lv, "#collections-heading") == "Repositories"

    assert words(lv, "#collections-waiting") ==
             "Waiting for Acme tracker to send its repositories…"

    assert has_element?(lv, ~s{#collections-waiting[role="status"]})
    refute has_element?(lv, "#collections-late")

    send(lv.pid, :late)

    assert has_element?(lv, "#collections-late span", "If nothing appears, install again.")
    assert has_element?(lv, "#collections-late button#collections-install-install", "Install")

    form = form(lv, "#collections-install")
    render_submit(form)
    conn = follow_trigger_action(form, conn)
    assert conn.request_path == page(scope, adapter) <> "/install"
    assert conn.resp_body =~ "https://tracker.example.com/connect?state="
  end

  test "waiting, the page starts the minute to the line to install again once, as it opens",
       %{conn: conn, scope: scope, adapter: adapter} do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    timer = :sys.get_state(lv.pid).socket.assigns.timer
    assert is_reference(timer)
    assert Process.read_timer(timer) in 55_000..60_000

    send(
      lv.pid,
      {:connection_changed, %{connection_id: connection.id, adapter_id: adapter.id}}
    )

    assert has_element?(lv, "#collections-waiting")
    assert :sys.get_state(lv.pid).socket.assigns.timer == timer
  end

  test "the collections are named in the adapter's words", %{
    conn: conn,
    scope: scope,
    adapter: adapter
  } do
    adapter = describe_source(adapter, "example-tracker.json")
    connection_fixture(scope, adapter, :connected)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#collections-heading") == "Projects"
    assert words(lv, "#collections-waiting") == "Waiting for Acme tracker to send its projects…"
  end

  test "installed on an earlier day: on which", %{conn: conn, scope: scope, adapter: adapter} do
    {connection, _nonce} = connection_fixture(scope, adapter, :listed)
    earlier = ~U[2026-03-04 10:00:00.000000Z]
    set(connection, connected_at: earlier)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#integration-status") ==
             "Installed by #{scope.user.email} on #{ApiaryWeb.Format.day(earlier)}."

    refute has_element?(lv, "#collections-waiting")
  end

  test "the wait ends when the first listing names the connection", %{
    conn: conn,
    scope: scope,
    adapter: adapter
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert has_element?(lv, "#collections-waiting")

    set(connection, listed_at: DateTime.utc_now())

    send(
      lv.pid,
      {:connection_changed, %{connection_id: connection.id, adapter_id: adapter.id}}
    )

    refute has_element?(lv, "#collections-waiting")
    send(lv.pid, :late)
    refute has_element?(lv, "#collections-late")
  end

  test "the page shows the return's flash", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    pair: pair
  } do
    {:ok, _url, {public_id, nonce} = session} = Apiary.Adapters.connect(scope, adapter)
    token = return_token(pair.secret, public_id, nonce)

    conn =
      conn
      |> ConnectSession.put(session)
      |> get(~p"/integrations/#{public_id}?return=#{token}")

    assert redirected_to(conn) == page(scope, adapter)

    {:ok, lv, _html} = live(recycle(conn), page(scope, adapter))
    assert words(lv, "#flash-info") =~ "Acme tracker is connected."
    assert has_element?(lv, "#collections-waiting")
  end

  test "a member reads where it stands, with no install block and no Install", %{
    scope: scope,
    adapter: adapter
  } do
    conn = member_conn(scope)
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert words(lv, "#integration-status") == "Not installed."
    refute has_element?(lv, "#integration-install")

    connection_fixture(scope, adapter, :connected)
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert has_element?(lv, "#collections-waiting")
    send(lv.pid, :late)
    _ = render(lv)
    refute has_element?(lv, "#collections-late")
  end

  test "a member reads a pending install, or an expired one, as not installed, with no Install",
       %{conn: conn, scope: scope, adapter: adapter} do
    member = member_conn(scope)
    {connection, _nonce} = connection_fixture(scope, adapter, :pending)

    {:ok, lv, _html} = live(member, page(scope, adapter))
    assert words(lv, "#integration-status") == "Not installed."
    refute render(lv) =~ ~r/press Install/i
    refute has_element?(lv, "#integration-install")

    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#integration-status") ==
             "Not installed. #{scope.user.email} started an install today at #{time(connection.updated_at)} that isn't finished: finish it on Acme tracker, or press Install to start again."

    set(connection, pass_expires_at: DateTime.add(DateTime.utc_now(:second), -1))

    {:ok, lv, _html} = live(member, page(scope, adapter))
    assert words(lv, "#integration-status") == "Not installed."
    refute render(lv) =~ ~r/press Install/i
    refute has_element?(lv, "#integration-install")
  end

  test "an admin has the install block too", %{scope: scope, adapter: adapter} do
    {:ok, lv, _html} = live(member_conn(scope, :admin), page(scope, adapter))
    assert has_element?(lv, "#integration-install")
  end

  test "an adapter deleted meanwhile leaves for the list", %{
    conn: conn,
    scope: scope,
    adapter: adapter
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    {:ok, _deleted} = Apiary.Adapters.delete_adapter(instance_admin_scope(), adapter)

    send(
      lv.pid,
      {:connection_changed, %{connection_id: connection.id, adapter_id: adapter.id}}
    )

    list = ~p"/#{scope.organisation}/settings/integrations"
    assert_redirect(lv, list)
  end

  test "is not found for an adapter that does not exist, or where the feature is hidden",
       %{conn: conn, scope: scope, adapter: adapter} do
    assert_raise ApiaryWeb.NotFound, fn ->
      live(conn, ~p"/#{scope.organisation}/settings/integrations/na_0000000000000000")
    end

    :ok = Edition.put_test_stub(EditionStubs.HidesNamed)
    :ok = EditionStubs.HidesNamed.put([:factory])
    assert_raise ApiaryWeb.Features.NotFound, fn -> live(conn, page(scope, adapter)) end
  end
end
