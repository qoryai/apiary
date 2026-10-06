defmodule Apiary.Integrations.SettingsTest do
  # Not async: the operator's settings are the whole node's, which every request and fetch
  # reads.
  use Apiary.DataCase, async: false

  import Apiary.DescriptionFixtures
  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog

  alias Apiary.{Connections, Integrations}
  alias Apiary.Integrations.{Release, Source}

  @moduletag needs: :security

  @keys ~w(integration_forge_hosts_setting integration_url_sources_setting
           integration_forge_hosts integration_url_sources)a

  @url "https://downloads.example.com/acme/shop/description.json"

  setup do
    previous = Map.new(@keys, &{&1, Application.fetch_env(:apiary, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:apiary, key, value)
          :error -> Application.delete_env(:apiary, key)
        end
      end
    end)

    %{scope: sign_up_fixture().scope}
  end

  defp settings(forge_hosts, url_sources) do
    Application.put_env(:apiary, :integration_forge_hosts_setting, forge_hosts)
    Application.put_env(:apiary, :integration_url_sources_setting, url_sources)
    Source.boot!()
  end

  # The release's files where a forge, or an address, serves them, every other path a
  # 404, each request told to the test with its address, Host and Authorization.
  defp serve(description, base) do
    bytes = encode(description)

    files = %{
      (base <> "description.json") => bytes,
      (base <> "checksums.txt") => checksums(bytes)
    }

    test = self()

    Req.Test.stub(Apiary.Integrations.Fetch, fn conn ->
      send(
        test,
        {:request, conn.host, Plug.Conn.get_req_header(conn, "host"),
         Plug.Conn.get_req_header(conn, "authorization"), conn.request_path}
      )

      case Map.fetch(files, conn.request_path) do
        {:ok, body} -> Plug.Conn.send_resp(conn, 200, body)
        :error -> Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end

  defp fetch!(scope, release, opts \\ []) do
    {:ok, release} = Integrations.fetch_release(scope, release.id, opts)
    release
  end

  describe "a forge the operator lists" do
    test "is added from as a public forge is, with the kind the operator gave its host",
         %{scope: scope} do
      settings("gitlab:private.example.com,forgejo:git.example.com", nil)
      serve(github_description(), "/acme/tools/shop/-/releases/v0.1.0/downloads/")
      attrs = %{source: "private.example.com/acme/tools/shop", version: "0.1.0"}

      assert {:ok, release} = Integrations.request_release(scope, attrs)
      assert release.forge_kind == "gitlab"

      assert {:error, changeset} =
               Integrations.request_release(scope, Map.put(attrs, :forge_kind, "forgejo"))

      assert %{forge_kind: [_]} = errors_on(changeset)

      # The host resolves to a private address, which its listing allows, and the token
      # the edition gives goes to it, as to a public forge.
      release_token = fn _scope, source ->
        if source.host == "private.example.com" and source.forge_kind == "gitlab",
          do: "forge-token"
      end

      assert %Release{state: "ready"} = fetch!(scope, release, release_token: release_token)

      assert_received {:request, "10.1.2.3", ["private.example.com"], ["Bearer forge-token"],
                       "/acme/tools/shop/-/releases/v0.1.0/downloads/description.json"}

      assert {:ok, connection} = Connections.create_integration(scope, release.id, %{})
      assert connection.source == "private.example.com/acme/tools/shop"
      assert connection.forge_kind == "gitlab"
    end

    test "is fetched from where a forge of its kind publishes a release", %{scope: scope} do
      settings("github:github.example.com,forgejo:git.example.com", nil)

      for {host, kind} <- [{"github.example.com", "github"}, {"git.example.com", "forgejo"}] do
        serve(github_description(), "/acme/shop/releases/download/v0.1.0/")

        {:ok, release} =
          Integrations.request_release(scope, %{source: host <> "/acme/shop", version: "0.1.0"})

        assert release.forge_kind == kind
        assert %Release{state: "ready"} = fetch!(scope, release)

        assert_received {:request, "203.0.113.10", [^host], [],
                         "/acme/shop/releases/download/v0.1.0/description.json"}
      end
    end

    test "is no longer fetched from, or added from, once the operator unlists it",
         %{scope: scope} do
      settings("forgejo:git.example.com", nil)
      attrs = %{source: "git.example.com/acme/shop", version: "0.1.0"}
      {:ok, pending} = Integrations.request_release(scope, attrs)

      {:ok, ready} =
        Integrations.request_release(scope, %{attrs | source: "git.example.com/acme/hub"})

      serve(github_description(), "/acme/hub/releases/download/v0.1.0/")
      assert %Release{state: "ready"} = fetch!(scope, ready)

      settings(nil, nil)

      log =
        capture_log(fn ->
          assert %Release{state: "failed", failure: "integration_source_refused"} =
                   fetch!(scope, pending)

          assert Connections.create_integration(scope, ready.id, %{}) ==
                   {:error, :integration_source_refused}
        end)

      assert log =~ "forge_host_unlisted"
      refute_received {:request, _, _, _, "/acme/shop/" <> _}

      assert {:error, changeset} = Integrations.request_release(scope, attrs)

      assert errors_on(changeset) == %{
               source: ["is not on a forge this instance adds integrations from"]
             }
    end

    test "unlisted, holds a connection to the release it has", %{scope: scope} do
      settings("forgejo:git.example.com", nil)
      attrs = %{source: "git.example.com/acme/shop", version: "0.1.0"}
      serve(github_description(), "/acme/shop/releases/download/v0.1.0/")
      {:ok, first} = Integrations.request_release(scope, attrs)
      first = fetch!(scope, first)
      {:ok, connection} = Connections.create_integration(scope, first.id, %{})

      serve(
        github_description(%{"program_version" => "0.2.0"}),
        "/acme/shop/releases/download/v0.2.0/"
      )

      {:ok, newer} = Integrations.request_release(scope, %{attrs | version: "0.2.0"})
      assert %Release{state: "ready"} = fetch!(scope, newer)

      settings(nil, nil)

      capture_log(fn ->
        assert Connections.change_release(scope, connection, newer.id) ==
                 {:error, :integration_source_refused}
      end)
    end

    test "a release found under a kind since corrected is fetched anew under the new one",
         %{scope: scope} do
      settings("github:git.example.com", nil)
      attrs = %{source: "git.example.com/acme/shop", version: "0.1.0"}
      serve(github_description(), "/acme/shop/releases/download/v0.1.0/")
      {:ok, old} = Integrations.request_release(scope, attrs)
      assert %Release{state: "ready", forge_kind: "github"} = old = fetch!(scope, old)
      {:ok, connection} = Connections.create_integration(scope, old.id, %{})
      assert {:ok, %Release{id: id}} = Integrations.request_release(scope, attrs)
      assert id == old.id

      settings("forgejo:git.example.com", nil)

      assert {:ok, %Release{state: "pending", forge_kind: "forgejo"} = new} =
               Integrations.request_release(scope, attrs)

      assert new.id != old.id
      assert %Release{state: "ready"} = fetch!(scope, new)

      capture_log(fn ->
        assert Connections.create_integration(scope, old.id, %{}) ==
                 {:error, :integration_source_refused}
      end)

      # The connection keeps the kind it was recorded with: it is removed and added again.
      assert Connections.change_release(scope, connection, new.id) ==
               {:error, {:integration_source_mismatch, :source}}

      {:ok, _deleted} = Connections.delete_connection(scope, connection)
      assert {:ok, connection} = Connections.create_integration(scope, new.id, %{})
      assert connection.forge_kind == "forgejo"
    end

    test "is reached at a private address for its own releases alone", %{scope: scope} do
      settings("gitlab:private.example.com", nil)
      release_token = fn _scope, _source -> "forge-token" end

      # A URL source on the forge's host is not let through by the forge's listing.
      serve(github_description(), "/acme/shop/")

      {:ok, release} =
        Integrations.request_release(scope, %{
          source: "https://private.example.com/acme/shop/description.json"
        })

      log =
        capture_log(fn ->
          assert %Release{failure: "fetch_failed"} =
                   fetch!(scope, release, release_token: release_token)
        end)

      assert log =~ "address_refused"
      refute_received {:request, _, _, _, _}

      # Nor is a public forge's release whose download leads there.
      test = self()

      Req.Test.stub(Apiary.Integrations.Fetch, fn conn ->
        send(test, {:request, conn.host, Plug.Conn.get_req_header(conn, "host"), [], ""})

        conn
        |> Plug.Conn.put_resp_header("location", "https://private.example.com/acme/admin")
        |> Plug.Conn.send_resp(302, "")
      end)

      {:ok, release} =
        Integrations.request_release(scope, %{source: "github.com/acme/shop", version: "0.1.0"})

      log =
        capture_log(fn ->
          assert %Release{failure: "fetch_failed"} =
                   fetch!(scope, release, release_token: release_token)
        end)

      assert log =~ "address_refused"
      assert_received {:request, "203.0.113.10", ["github.com"], _, _}
      refute_received {:request, _, ["private.example.com"], _, _}
    end
  end

  describe "INTEGRATION_URL_SOURCES" do
    test "is on by default: an integration is added from an address", %{scope: scope} do
      settings(nil, nil)
      assert Source.url_sources?()
      serve(github_description(), "/acme/shop/")

      {:ok, release} = Integrations.request_release(scope, %{source: @url})
      assert %Release{state: "ready"} = release = fetch!(scope, release)
      assert {:ok, _connection} = Connections.create_integration(scope, release.id, %{})
    end

    test "off, refuses to add an integration from an address, and to fetch one asked for",
         %{scope: scope} do
      settings(nil, "true")
      serve(github_description(), "/acme/shop/")
      {:ok, pending} = Integrations.request_release(scope, %{source: @url})
      {:ok, ready} = Integrations.request_release(scope, %{source: @url})
      assert %Release{state: "ready"} = fetch!(scope, ready)
      assert_received {:request, _, ["downloads.example.com"], _, "/acme/shop/description.json"}
      assert_received {:request, _, ["downloads.example.com"], _, "/acme/shop/checksums.txt"}

      settings(nil, "false")
      refute Source.url_sources?()

      assert {:error, changeset} = Integrations.request_release(scope, %{source: @url})

      assert errors_on(changeset) == %{
               source: [
                 "must be a repository's path: this instance adds no integration from an address"
               ]
             }

      log =
        capture_log(fn ->
          assert %Release{state: "failed", failure: "integration_source_refused"} =
                   fetch!(scope, pending)

          assert Connections.create_integration(scope, ready.id, %{}) ==
                   {:error, :integration_source_refused}
        end)

      assert log =~ "url_sources_off"
      refute_received {:request, _, _, _, _}

      # A forge's release is fetched as before.
      serve(github_description(), "/qoryai/qory-github/releases/download/v0.1.0/")

      {:ok, release} =
        Integrations.request_release(scope, %{
          source: "github.com/qoryai/qory-github",
          version: "0.1.0"
        })

      assert %Release{state: "ready"} = fetch!(scope, release)
    end
  end

  test "a value either setting refuses stops the boot; the ones accepted are fixed" do
    assert_raise ArgumentError, ~r/INTEGRATION_FORGE_HOSTS/, fn ->
      settings("gitea:git.example.com", nil)
    end

    assert_raise ArgumentError,
                 ~r/INTEGRATION_FORGE_HOSTS.*"git.example.com." ends in a dot/s,
                 fn -> settings("forgejo:git.example.com.", nil) end

    assert_raise ArgumentError, ~r/INTEGRATION_FORGE_HOSTS.*"\*.example.com" is a pattern/s, fn ->
      settings("gitlab:*.example.com", nil)
    end

    assert_raise ArgumentError, ~r/INTEGRATION_URL_SOURCES/, fn -> settings(nil, "maybe") end

    assert settings("forgejo:git.example.com", "no") == :ok
    assert Source.forge_hosts() == %{"git.example.com" => "forgejo"}
    refute Source.url_sources?()
  end
end
