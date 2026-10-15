defmodule ApiaryWeb.AdapterRedirectControllerTest do
  # The link to an organisation's connection to an integration
  # (`GET /integrations/:connection_id`): where it leads, the return it takes with the
  # nonce the person's session kept (`ApiaryWeb.ConnectSession`), and what it answers to a
  # return the person did not start in this browser. `ApiaryWeb.FactoryShellTest` has the
  # link without the feature and to a person who does not reach it.
  use ApiaryWeb.ConnCase, async: true

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Adapters, Repo}
  alias Apiary.Adapters.Connection
  alias ApiaryWeb.ConnectSession

  @moduletag needs: :factory

  setup :register_and_log_in_user

  setup %{scope: scope} do
    %{adapter: adapter, pair: pair} = connectable_adapter_fixture(%{name: "Acme tracker"})
    {:ok, _url, {public_id, nonce} = session} = Adapters.connect(scope, adapter)

    %{
      adapter: adapter,
      pair: pair,
      connection: Repo.get_by!(Connection, public_id: public_id),
      nonce: nonce,
      session: session
    }
  end

  defp page(scope, adapter),
    do: "/#{scope.organisation.slug}/settings/integrations/#{adapter.public_id}"

  defp reload(%Connection{id: id}), do: Repo.get!(Connection, id)

  # The answer to a request the endpoint renders an error for, as it was sent.
  defp not_found(request) do
    {404, _headers, _body} = assert_error_sent(:not_found, request)
    :ok
  end

  describe "without a return" do
    test "leads the organisation's people to the integration's page there", %{
      conn: conn,
      scope: scope,
      adapter: adapter,
      connection: connection
    } do
      assert conn |> get(~p"/integrations/#{connection}") |> redirected_to() ==
               page(scope, adapter)

      %{user: member} = member_fixture(scope, :member)

      assert build_conn()
             |> log_in_user(member)
             |> get(~p"/integrations/#{connection}")
             |> redirected_to() == page(scope, adapter)
    end
  end

  describe "with a return" do
    test "linked: in the browser that started it, the connection is activated and the page says so",
         %{
           conn: conn,
           scope: scope,
           adapter: adapter,
           pair: pair,
           connection: connection,
           nonce: nonce,
           session: session
         } do
      token = return_token(pair.secret, connection.public_id, nonce)

      conn =
        conn
        |> ConnectSession.put(session)
        |> get(~p"/integrations/#{connection}?return=#{token}")

      assert redirected_to(conn) == page(scope, adapter)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Acme tracker is connected. Its repositories and projects appear here as it sends them."

      assert get_session(conn, "connect_passes") == nil
      assert %Connection{state: :pending, activated_at: %DateTime{}} = reload(connection)

      # Used: the same link again is not found.
      not_found(fn ->
        build_conn()
        |> log_in_user(scope.user)
        |> ConnectSession.put(session)
        |> get(~p"/integrations/#{connection}?return=#{token}")
      end)
    end

    test "refused and cancelled lead to the page, say why, and change nothing but the nonce",
         %{
           conn: conn,
           scope: scope,
           adapter: adapter,
           pair: pair,
           connection: connection
         } do
      told = [
        {[outcome: :cancelled], :info,
         "You cancelled the install on Acme tracker. Nothing has changed."},
        {[outcome: :refused, reason: :not_admin], :error,
         "Acme tracker doesn't confirm that you administer that account. Ask an admin of the account to install it."},
        {[outcome: :refused, reason: :installation_taken], :error,
         "That account is already connected to another organisation."},
        {[outcome: :refused, reason: :installation_not_confirmed], :error,
         "Acme tracker couldn't confirm that installation for you. Install it again from Integrations."},
        {[outcome: :refused, reason: :installation_suspended], :error,
         "That installation is suspended on Acme tracker. Lift the suspension there, then install it again."},
        {[outcome: :refused, reason: :permission_missing], :error,
         "An owner of the account must approve the updated permissions on Acme tracker, then install it again."},
        {[outcome: :refused, reason: :pass_expired], :error,
         "The install took too long and expired. Install it again from Integrations."},
        {[outcome: :refused, reason: :github_unavailable], :error,
         "Acme tracker didn't answer. Install it again in a moment."}
      ]

      # Every reason the contract names is said.
      assert Enum.sort(Apiary.Adapters.ReturnToken.reasons()) ==
               told
               |> Enum.flat_map(fn {opts, _, _} -> List.wrap(opts[:reason]) end)
               |> Enum.sort()

      for {opts, kind, message} <- told do
        {:ok, _url, {_id, nonce} = session} = Adapters.connect(scope, adapter)
        token = return_token(pair.secret, connection.public_id, nonce, opts)

        answered =
          conn
          |> ConnectSession.put(session)
          |> get(~p"/integrations/#{connection}?return=#{token}")

        assert redirected_to(answered) == page(scope, adapter)
        assert Phoenix.Flash.get(answered.assigns.flash, kind) == message

        assert %Connection{activated_at: nil, pass_nonce_used_at: %DateTime{}} =
                 reload(connection)
      end
    end

    test "another person, or another browser, is told it is not theirs, and nothing changes",
         %{
           conn: conn,
           scope: scope,
           pair: pair,
           connection: connection,
           nonce: nonce,
           session: session
         } do
      token = return_token(pair.secret, connection.public_id, nonce)
      %{user: admin} = member_fixture(scope, :admin)

      # Another admin, even with the nonce in their session; the person who started it in
      # a browser without it.
      for asker <- [
            build_conn() |> log_in_user(admin) |> ConnectSession.put(session),
            conn
          ] do
        answered = get(asker, ~p"/integrations/#{connection}?return=#{token}")
        assert answered.status == 403
        assert ["text/plain" <> _] = get_resp_header(answered, "content-type")

        assert answered.resp_body ==
                 "Only the person who started this install can finish it, in the browser they started it in. To install it yourself, start again from Integrations."
      end

      assert reload(connection) == connection
    end

    test "a bad, foreign or expired return is not found, and changes nothing", %{
      conn: conn,
      pair: pair,
      connection: connection,
      nonce: nonce,
      session: session
    } do
      expired =
        return_token(pair.secret, connection.public_id, nonce,
          expires_at: DateTime.add(DateTime.utc_now(), -10, :second) |> DateTime.truncate(:second)
        )

      for token <- [
            "x",
            "",
            expired,
            return_token(ed25519_secret(), connection.public_id, nonce)
          ] do
        not_found(fn ->
          conn
          |> ConnectSession.put(session)
          |> get(~p"/integrations/#{connection}?return=#{token}")
        end)
      end

      not_found(fn ->
        conn
        |> ConnectSession.put(session)
        |> get("/integrations/#{connection.public_id}?return[]=x")
      end)

      assert reload(connection) == connection
    end
  end

  describe "the session's nonces" do
    test "keep the latest pass of the last few connections, one each", %{conn: conn} do
      conn = ConnectSession.put(conn, {"ac_0000000000000001", "a"})
      conn = ConnectSession.put(conn, {"ac_0000000000000001", "b"})
      assert ConnectSession.fetch(conn, "ac_0000000000000001") == "b"

      conn =
        Enum.reduce(2..(ConnectSession.kept() + 1), conn, fn n, conn ->
          ConnectSession.put(conn, {"ac_000000000000000#{n}", "n#{n}"})
        end)

      assert ConnectSession.fetch(conn, "ac_0000000000000001") == nil
      assert ConnectSession.fetch(conn, "ac_0000000000000002") == "n2"
      assert length(get_session(conn, "connect_passes")) == ConnectSession.kept()

      conn = ConnectSession.drop(conn, "ac_0000000000000002")
      assert ConnectSession.fetch(conn, "ac_0000000000000002") == nil
      assert ConnectSession.fetch(conn, "ac_0000000000000003") == "n3"
      assert ConnectSession.fetch(conn, nil) == nil

      # What the session holds that is not its shape is read as nothing.
      conn = put_session(conn, "connect_passes", %{"ac_0000000000000003" => "n3"})
      assert ConnectSession.fetch(conn, "ac_0000000000000003") == nil
    end
  end

  test "`return` is kept out of the logs" do
    assert Phoenix.Logger.filter_values(%{"return" => "a.b", "connection_id" => "ac_x"}) ==
             %{"return" => "[FILTERED]", "connection_id" => "ac_x"}
  end

  defp ed25519_secret, do: Apiary.AccessKeysFixtures.ed25519_key_pair().secret
end
