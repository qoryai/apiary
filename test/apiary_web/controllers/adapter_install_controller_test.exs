defmodule ApiaryWeb.AdapterInstallControllerTest do
  # Install (`POST /:org/settings/integrations/:adapter_id/install`): the member's right
  # first, then the adapter, then `Apiary.Adapters.connect/2`; the nonce kept in the
  # session; the page that sends the person on to the adapter's connect address with the
  # pass, kept by no cache and telling no referrer; the CSRF check; and where a person is
  # sent when the organisation is connected already or the adapter cannot be connected.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Repo
  alias Apiary.Adapters.Connection
  alias Apiary.Audit.Entry
  alias ApiaryWeb.ConnectSession

  @moduletag needs: :factory

  setup :register_and_log_in_user

  setup do
    %{adapter: adapter} =
      connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})

    %{adapter: adapter}
  end

  defp install(conn, scope, adapter_id),
    do: post(conn, "/#{scope.organisation.slug}/settings/integrations/#{adapter_id}/install")

  defp connections(scope),
    do: Repo.all(from c in Connection, where: c.organisation_id == ^scope.organisation.id)

  defp connect_entries,
    do: Repo.aggregate(from(e in Entry, where: e.action == "adapter.connect"), :count)

  # The address the page refreshes to.
  defp refresh_url(conn) do
    [_, url] = Regex.run(~r/<meta http-equiv="refresh" content="0;url=([^"]*)">/, conn.resp_body)
    url |> String.replace("&amp;", "&") |> String.replace("&#39;", "'")
  end

  test "an owner is sent on to the connect address with the pass, and the session keeps the nonce",
       %{conn: conn, scope: scope, adapter: adapter} do
    conn = install(conn, scope, adapter.public_id)

    assert conn.status == 200
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert conn.resp_body =~ ~s(<meta name="referrer" content="no-referrer">)

    url = refresh_url(conn)
    assert "https://tracker.example.com/connect?state=" <> pass = url
    assert pass =~ ~r/\A[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/

    assert [%Connection{state: :pending, public_id: public_id} = connection] = connections(scope)
    nonce = ConnectSession.fetch(conn, public_id)
    assert is_binary(nonce)
    assert Apiary.Contract.Ed25519.encode(connection.pass_nonce) == nonce
    assert connect_entries() == 1

    # The page has no words: nothing in its body but the document and its head.
    assert conn.resp_body |> String.replace(~r/<[^>]*>/, "") == ""
  end

  test "an admin may install too", %{scope: scope, adapter: adapter} do
    %{user: admin} = member_fixture(scope, :admin)
    conn = build_conn() |> log_in_user(admin) |> install(scope, adapter.public_id)
    assert conn.status == 200
    assert [%Connection{}] = connections(scope)
  end

  test "a member without the right is refused 403 before anything is looked up or changed",
       %{scope: scope, adapter: adapter} do
    %{user: member} = member_fixture(scope, :member)

    for adapter_id <- [adapter.public_id, "na_0000000000000000", "nope"] do
      conn = build_conn() |> log_in_user(member) |> install(scope, adapter_id)
      assert conn.status == 403, adapter_id
      assert conn.resp_body == "Forbidden"
      assert ConnectSession.fetch(conn, "anything") == nil
    end

    assert connections(scope) == []
    assert connect_entries() == 0
  end

  test "an adapter the person does not find is a path that does not exist", %{
    conn: conn,
    scope: scope,
    adapter: adapter
  } do
    {:ok, _} = Apiary.Adapters.delete_adapter(instance_admin_scope(), adapter)

    for adapter_id <- [adapter.public_id, "na_0000000000000000", "nope"] do
      assert_error_sent 404, fn -> install(conn, scope, adapter_id) end
    end

    assert connections(scope) == []
  end

  test "the CSRF check stays on: without the session's token the POST is refused", %{
    conn: conn,
    scope: scope,
    adapter: adapter
  } do
    checked = Plug.Conn.put_private(conn, :plug_skip_csrf_protection, false)

    assert_error_sent 403, fn -> install(checked, scope, adapter.public_id) end
    assert connections(scope) == []

    # With the session's token, it goes through.
    token = Plug.CSRFProtection.get_csrf_token()

    conn =
      checked
      |> Plug.Conn.put_session("_csrf_token", Plug.CSRFProtection.dump_state())
      |> post("/#{scope.organisation.slug}/settings/integrations/#{adapter.public_id}/install", %{
        "_csrf_token" => token
      })

    assert conn.status == 200
    assert [%Connection{}] = connections(scope)
  end

  test "an anonymous visitor is sent to log in", %{scope: scope, adapter: adapter} do
    conn = install(build_conn(), scope, adapter.public_id)
    assert redirected_to(conn) =~ "/users/log-in"
    assert connections(scope) == []
  end

  test "while the organisation is connected, the person is sent to the integration's page", %{
    conn: conn,
    scope: scope,
    adapter: adapter
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :listed)
    conn = install(conn, scope, adapter.public_id)

    assert redirected_to(conn) ==
             "/#{scope.organisation.slug}/settings/integrations/#{adapter.public_id}"

    assert connections(scope) == [Repo.reload!(connection)]
  end

  test "an adapter that cannot be connected yet sends the person to Add an integration", %{
    conn: conn,
    scope: scope
  } do
    bare = adapter_fixture()
    conn = install(conn, scope, bare.public_id)
    assert redirected_to(conn) == "/#{scope.organisation.slug}/settings/integrations/new"
    assert connections(scope) == []
    assert connect_entries() == 0
  end
end
