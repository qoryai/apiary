defmodule ApiaryWeb.AdapterSetupControllerTest do
  # Set up (`POST /instance/adapters/:adapter_id/setup`): an instance admin is sent on to
  # the adapter's setup_url with a new setup pass, by a page kept by no cache and telling
  # no referrer; the pass in no log line; the CSRF check; anyone else, and an adapter not
  # found, answered as a path that does not exist; and, while the adapter has nothing to
  # set up or no key in use, back to the page Set up was on, with why.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import ExUnit.CaptureLog
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Repo, SigningKey}
  alias Apiary.Adapters.SetupPass
  alias Apiary.Audit.Entry
  alias Apiary.Nodes.Node

  @moduletag needs: :factory

  setup do
    %{adapter: adapter, access_key: key} =
      settable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})

    admin = instance_admin_scope()
    %{adapter: adapter, key: key, admin: admin, conn: log_in_user(build_conn(), admin.user)}
  end

  defp set_up(conn, adapter_id, params \\ %{}),
    do: post(conn, "/instance/adapters/#{adapter_id}/setup", params)

  defp setup_entries,
    do: Repo.aggregate(from(e in Entry, where: e.action == "adapter.setup"), :count)

  # The address the page refreshes to.
  defp refresh_url(conn) do
    [_, url] = Regex.run(~r/<meta http-equiv="refresh" content="0;url=([^"]*)">/, conn.resp_body)
    url |> String.replace("&amp;", "&") |> String.replace("&#39;", "'")
  end

  test "an instance admin is sent on to the setup_url with a new pass, kept by no cache, telling no referrer",
       %{conn: conn, adapter: adapter} do
    {conn, log} = with_log([level: :debug], fn -> set_up(conn, adapter.public_id) end)

    assert conn.status == 200
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "location") == []
    assert conn.resp_body =~ ~s(<meta name="referrer" content="no-referrer">)

    assert "https://tracker.example.com/setup?site=main&state=" <> pass = refresh_url(conn)

    assert {:ok, %{adapter_id: adapter_id}} =
             SetupPass.verify(pass, SigningKey.public_key())

    assert adapter_id == adapter.public_id
    assert setup_entries() == 1

    # The pass is in the answer's body alone: in no log line, and not in the request log's
    # line for this answer.
    request_log =
      capture_log(fn ->
        ApiaryWeb.RequestLog.handle_event(
          [:phoenix, :endpoint, :stop],
          %{duration: System.convert_time_unit(1, :millisecond, :native)},
          %{conn: conn},
          :error
        )
      end)

    assert request_log =~ "POST /instance/adapters/#{adapter.public_id}/setup"
    [payload, signature] = String.split(pass, ".")

    for written <- [log, request_log], part <- [pass, payload, signature] do
      refute written =~ part
    end

    # The page has no words: nothing in its body but the document and its head.
    assert conn.resp_body |> String.replace(~r/<[^>]*>/, "") == ""
  end

  # Install offers only an adapter with nothing left to set up, so this page is a
  # configured adapter's.
  test "Install's page sends on as before, from the same page" do
    %{adapter: adapter} =
      connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})

    %{scope: owner, user: user} = sign_up_fixture()
    conn = build_conn() |> log_in_user(user)

    conn =
      post(conn, "/#{owner.organisation.slug}/settings/integrations/#{adapter.public_id}/install")

    assert conn.status == 200
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert "https://tracker.example.com/connect?state=" <> _pass = refresh_url(conn)
  end

  test "anyone but an instance admin is answered as a path that does not exist, and nothing changes",
       %{adapter: adapter} do
    %{scope: owner, user: user} = sign_up_fixture()
    %{user: member} = member_fixture(owner, :member)

    for person <- [user, member] do
      conn = build_conn() |> log_in_user(person)
      assert_error_sent 404, fn -> set_up(conn, adapter.public_id) end
    end

    assert setup_entries() == 0
  end

  test "an adapter the instance admin does not find is a path that does not exist",
       %{conn: conn, adapter: adapter, admin: admin} do
    {:ok, _} = Apiary.Adapters.delete_adapter(admin, adapter)

    for adapter_id <- [adapter.public_id, "na_0000000000000000", "nope"] do
      assert_error_sent 404, fn -> set_up(conn, adapter_id) end
    end

    assert setup_entries() == 0
  end

  test "the CSRF check stays on: without the session's token the POST is refused",
       %{conn: conn, adapter: adapter} do
    checked = Plug.Conn.put_private(conn, :plug_skip_csrf_protection, false)

    assert_error_sent 403, fn -> set_up(checked, adapter.public_id) end
    assert setup_entries() == 0

    # With the session's token, it goes through.
    token = Plug.CSRFProtection.get_csrf_token()

    conn =
      checked
      |> Plug.Conn.put_session("_csrf_token", Plug.CSRFProtection.dump_state())
      |> set_up(adapter.public_id, %{"_csrf_token" => token})

    assert conn.status == 200
    assert setup_entries() == 1
  end

  test "an anonymous visitor is sent to log in", %{adapter: adapter} do
    conn = set_up(build_conn(), adapter.public_id)
    assert redirected_to(conn) =~ "/users/log-in"
    assert setup_entries() == 0
  end

  test "with nothing to set up, back to the Overview, or to the list it came from, with why",
       %{conn: conn, adapter: adapter} do
    {1, _} = Repo.update_all(from(n in Node, where: n.id == ^adapter.id), set: [setup_url: nil])
    overview = "/instance/adapters/#{adapter.public_id}"

    sent = set_up(conn, adapter.public_id)
    assert redirected_to(sent) == overview

    assert Phoenix.Flash.get(sent.assigns.flash, :error) ==
             "This adapter has nothing to set up now."

    sent = set_up(conn, adapter.public_id, %{"back" => "list"})
    assert redirected_to(sent) == "/instance/adapters"

    # Anything else is the Overview.
    assert conn |> set_up(adapter.public_id, %{"back" => "https://a.example"}) |> redirected_to() ==
             overview

    assert setup_entries() == 0
  end

  test "with no key in use, back with why", %{
    conn: conn,
    adapter: adapter,
    key: key,
    admin: admin
  } do
    {:ok, _} = AccessKeys.revoke_access_key(admin, key)

    sent = set_up(conn, adapter.public_id)
    assert redirected_to(sent) == "/instance/adapters/#{adapter.public_id}"

    assert Phoenix.Flash.get(sent.assigns.flash, :error) ==
             "The adapter needs a key in use before it can be set up."

    assert setup_entries() == 0
  end
end
