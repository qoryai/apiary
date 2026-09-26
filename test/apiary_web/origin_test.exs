defmodule ApiaryWeb.OriginTest do
  # Not async: the trusted proxies are the node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias Apiary.{Organisations, Repo}
  alias ApiaryWeb.Origin

  doctest ApiaryWeb.Origin

  @proxies [{{10, 0, 0, 0}, 8}, {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32}]

  defp trust(ranges) do
    previous = Application.get_env(:apiary, :trusted_proxies)
    Application.put_env(:apiary, :trusted_proxies, ranges)
    on_exit(fn -> Application.put_env(:apiary, :trusted_proxies, previous) end)
  end

  defp last_entry,
    do: Repo.one!(from e in Entry, order_by: [desc: e.inserted_at, desc: e.id], limit: 1)

  describe "the address behind a proxy" do
    test "an untrusted peer is the address, whatever X-Forwarded-For says" do
      assert Origin.address({203, 0, 113, 9}, ["198.51.100.1"], @proxies) == "203.0.113.9"
      assert Origin.address({10, 0, 0, 2}, ["198.51.100.1"], []) == "10.0.0.2"
    end

    test "a trusted peer passes on the right-most hop that is not a trusted proxy" do
      assert Origin.address({10, 0, 0, 2}, ["198.51.100.1"], @proxies) == "198.51.100.1"

      # Two proxies of ours in a row: both passed over.
      assert Origin.address({10, 0, 0, 2}, ["198.51.100.1, 10.0.0.7"], @proxies) ==
               "198.51.100.1"

      # The header sent twice reads as one list, in order.
      assert Origin.address({10, 0, 0, 2}, ["198.51.100.1", "10.0.0.7"], @proxies) ==
               "198.51.100.1"

      assert Origin.address({10, 0, 0, 2}, ["2001:db9::5, 2001:db8:1::9"], @proxies) ==
               "2001:db9::5"
    end

    test "the hops a client wrote to the left of the real one are never read" do
      spoofed = ["10.0.0.9, 192.0.2.66, 198.51.100.1"]
      assert Origin.address({10, 0, 0, 2}, spoofed, @proxies) == "198.51.100.1"
    end

    test "a hop that is not an address ends the walk at the last trusted one" do
      assert Origin.address({10, 0, 0, 2}, ["198.51.100.1, unknown"], @proxies) == "10.0.0.2"
      assert Origin.address({10, 0, 0, 2}, ["unknown, 10.0.0.7"], @proxies) == "10.0.0.7"
      assert Origin.address({10, 0, 0, 2}, [], @proxies) == "10.0.0.2"
    end

    test "an IPv4 peer on a dual-stack socket is read as IPv4, and recorded so" do
      mapped = {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0002}
      assert Origin.address(mapped, ["198.51.100.1"], @proxies) == "198.51.100.1"
      assert Origin.address(mapped, [], []) == "10.0.0.2"

      # A hop as a dual-stack proxy writes it.
      assert Origin.address({10, 0, 0, 2}, ["::ffff:198.51.100.1"], @proxies) ==
               "198.51.100.1"
    end

    test "a hop's port is left out, and an empty hop is skipped" do
      assert Origin.address({10, 0, 0, 2}, ["198.51.100.9:4711"], @proxies) == "198.51.100.9"

      assert Origin.address({10, 0, 0, 2}, ["[2001:db9::1]:443"], @proxies) == "2001:db9::1"
      assert Origin.address({10, 0, 0, 2}, ["[2001:db9::1]"], @proxies) == "2001:db9::1"

      assert Origin.address({10, 0, 0, 2}, ["198.51.100.9, , 10.0.0.7:80,"], @proxies) ==
               "198.51.100.9"
    end
  end

  describe "TRUSTED_PROXIES" do
    test "addresses and CIDR ranges, separated by commas; none when unset" do
      assert Origin.parse_trusted_proxies(nil) == {:ok, []}
      assert Origin.parse_trusted_proxies(" , ") == {:ok, []}

      assert Origin.parse_trusted_proxies("10.0.0.0/8, 2001:db8::/32, 192.0.2.7") ==
               {:ok, [{{10, 0, 0, 0}, 8}, hd(tl(@proxies)), {{192, 0, 2, 7}, 32}]}

      for bad <- ["10.0.0.0/33", "proxy.example", "10.0.0/8", "10.0.0.0/x", "::1/129"] do
        assert {:error, reason} = Origin.parse_trusted_proxies(bad)
        assert reason =~ "not an address or a CIDR range"
      end

      # Every address: any client would choose the address recorded.
      for every <- ["0.0.0.0/0", "::/0", "10.0.0.0/8, 0.0.0.0/0"] do
        assert {:error, reason} = Origin.parse_trusted_proxies(every)
        assert reason =~ "is every address"
      end
    end

    test "a value refused stops the boot" do
      previous = Application.get_env(:apiary, :trusted_proxies_setting)
      ranges = Application.get_env(:apiary, :trusted_proxies)

      on_exit(fn ->
        Application.put_env(:apiary, :trusted_proxies_setting, previous)
        Application.put_env(:apiary, :trusted_proxies, ranges)
      end)

      Application.put_env(:apiary, :trusted_proxies_setting, "proxy.example")
      assert_raise ArgumentError, ~r/TRUSTED_PROXIES/, fn -> Origin.boot!() end

      Application.put_env(:apiary, :trusted_proxies_setting, "0.0.0.0/0")

      assert_raise ArgumentError, ~r/TRUSTED_PROXIES is not valid: "0.0.0.0\/0" is every/, fn ->
        Origin.boot!()
      end

      Application.put_env(:apiary, :trusted_proxies_setting, "192.0.2.0/24")
      assert Origin.boot!() == [{{192, 0, 2, 0}, 24}]
      assert Origin.trusted_proxies() == [{{192, 0, 2, 0}, 24}]
    end
  end

  describe "a change's entry says where it came from" do
    setup %{conn: conn} do
      %{user: user, scope: scope} = sign_up_fixture()

      conn =
        conn
        |> log_in_user(user)
        # The peer, as the connection has it: `remote_ip` for a request, the peer's data
        # for a LiveView's connection.
        |> Map.put(:remote_ip, {10, 0, 0, 2})
        |> Plug.Test.put_peer_data(%{address: {10, 0, 0, 2}, port: 40_000, ssl_cert: nil})
        |> put_req_header("user-agent", "Browser/1.0 (test)")
        |> put_req_header("x-forwarded-for", "192.0.2.66, 198.51.100.1")

      %{conn: conn, scope: scope}
    end

    test "a request: the peer, and the client it sent", %{conn: conn, scope: scope} do
      conn = get(conn, ~p"/#{scope.organisation}/members")
      assert html_response(conn, 200)

      {:ok, _} = Organisations.update_workspace(conn.assigns.current_scope, %{name: "Renamed"})

      assert %Entry{remote_ip: "10.0.0.2", user_agent: "Browser/1.0 (test)"} = last_entry()
    end

    test "a request through a trusted proxy: the address the proxy passed on", %{
      conn: conn,
      scope: scope
    } do
      trust(@proxies)
      conn = get(conn, ~p"/#{scope.organisation}/members")

      {:ok, _} = Organisations.update_workspace(conn.assigns.current_scope, %{name: "Renamed"})

      assert %Entry{remote_ip: "198.51.100.1", user_agent: "Browser/1.0 (test)"} = last_entry()
    end

    test "a LiveView: the peer and the client of its connection", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings")

      view
      |> form("#workspace-form", workspace: %{name: "Renamed"})
      |> render_submit()

      assert %Entry{
               action: "workspace.rename",
               remote_ip: "10.0.0.2",
               user_agent: "Browser/1.0 (test)"
             } = last_entry()
    end

    test "a LiveView through a trusted proxy: the address the proxy passed on", %{
      conn: conn,
      scope: scope
    } do
      trust(@proxies)
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings")

      view
      |> form("#workspace-form", workspace: %{name: "Renamed"})
      |> render_submit()

      assert %Entry{action: "workspace.rename", remote_ip: "198.51.100.1"} = last_entry()
    end
  end
end
