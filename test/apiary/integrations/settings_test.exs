defmodule Apiary.Integrations.SettingsTest do
  # Not async: the operator's setting is the whole node's, which every request and fetch
  # reads.
  use Apiary.DataCase, async: false

  import Apiary.DescriptionFixtures
  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog

  alias Apiary.{Connections, Integrations}
  alias Apiary.Integrations.{Release, Source}

  @moduletag needs: :security

  @keys ~w(integration_url_sources_setting integration_url_sources)a

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

  defp url_sources(setting) do
    Application.put_env(:apiary, :integration_url_sources_setting, setting)
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

  defp fetch!(scope, release) do
    {:ok, release} = Integrations.fetch_release(scope, release.id)
    release
  end

  describe "INTEGRATION_URL_SOURCES" do
    test "is on by default: an integration is added from an address", %{scope: scope} do
      url_sources(nil)
      assert Source.url_sources?()
      serve(github_description(), "/acme/shop/")

      {:ok, release} = Integrations.request_release(scope, %{source: @url})
      assert %Release{state: "ready"} = release = fetch!(scope, release)
      assert {:ok, _connection} = Connections.create_integration(scope, release.id, %{})
    end

    test "off, refuses to add an integration from an address, and to fetch one asked for",
         %{scope: scope} do
      url_sources("true")
      serve(github_description(), "/acme/shop/")
      {:ok, pending} = Integrations.request_release(scope, %{source: @url})
      {:ok, ready} = Integrations.request_release(scope, %{source: @url})
      assert %Release{state: "ready"} = fetch!(scope, ready)
      assert_received {:request, _, ["downloads.example.com"], _, "/acme/shop/description.json"}
      assert_received {:request, _, ["downloads.example.com"], _, "/acme/shop/checksums.txt"}

      url_sources("false")
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

  test "a value the setting refuses stops the boot; one accepted is fixed" do
    assert_raise ArgumentError, ~r/INTEGRATION_URL_SOURCES/, fn -> url_sources("maybe") end
    assert url_sources("no") == :ok
    refute Source.url_sources?()
  end
end
