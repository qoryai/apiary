defmodule ApiaryWeb.IntegrationLive.UrlSourcesTest do
  # INTEGRATION_URL_SOURCES is the whole node's (`Apiary.Integrations.Source.url_sources?/0`),
  # and these tests switch it: they are not async.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog
  import Apiary.DescriptionFixtures

  alias Apiary.{Connections, Integrations}
  alias Apiary.Integrations.{Release, Source}

  @moduletag needs: :secrets

  @keys ~w(integration_url_sources_setting integration_url_sources)a
  @url "https://downloads.example.com/acme/shop/description.json"

  setup :register_and_log_in_user

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

    :ok
  end

  defp url_sources(setting) do
    Application.put_env(:apiary, :integration_url_sources_setting, setting)
    Source.boot!()
  end

  defp ipath(scope, rest),
    do: "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/integrations#{rest}"

  # An integration added from @url while the instance accepts addresses.
  defp url_integration!(scope) do
    url_sources("true")
    bytes = encode(github_description())

    Req.Test.stub(Apiary.Integrations.Fetch, fn conn ->
      case conn.request_path do
        "/acme/shop/description.json" -> Plug.Conn.send_resp(conn, 200, bytes)
        "/acme/shop/checksums.txt" -> Plug.Conn.send_resp(conn, 200, checksums(bytes))
        _ -> Plug.Conn.send_resp(conn, 404, "")
      end
    end)

    {:ok, release} = Integrations.request_release(scope, %{source: @url})
    {:ok, %{state: "ready"} = release} = Integrations.fetch_release(scope, release.id)
    {:ok, integration} = Connections.create_integration(scope, release.id, %{})
    integration
  end

  test "off, Add integration offers no address, and refuses one sent all the same",
       %{conn: conn, scope: scope} do
    url_sources("false")
    {:ok, lv, html} = live(conn, ipath(scope, "/add"))

    refute html =~ "An https address"
    refute has_element?(lv, "input[name='release[where]'][value=url]")

    # Where it is released is one of the choices shown: an address, or a crafted
    # "https:" before a path that would make one, is not.
    for {where, path} <- [{"url", ""}, {"https:", "/downloads.example.com/acme/shop"}] do
      html =
        render_hook(lv, "request", %{
          "release" => %{"where" => where, "url" => @url, "path" => path, "version" => ""}
        })

      assert html =~ "is invalid", where
    end

    assert Apiary.Repo.all(Release) == []
  end

  test "off, an integration from an address keeps its version, and says why",
       %{conn: conn, scope: scope} do
    integration = url_integration!(scope)
    url_sources("false")

    log =
      capture_log(fn ->
        {:ok, lv, _html} = live(conn, ipath(scope, "/#{integration.public_id}/settings"))

        assert has_element?(
                 lv,
                 "#connection-version-refused",
                 "This instance no longer accepts integrations from this source, so its version can't be changed."
               )

        refute has_element?(lv, "#change-version")

        assert {:error, {:live_redirect, %{to: to}}} =
                 live(conn, ipath(scope, "/#{integration.public_id}/version"))

        assert to == ipath(scope, "/#{integration.public_id}/settings")
      end)

    assert log =~ "no longer accepted"
  end

  test "Change version says a refusal it has no field for above the form",
       %{conn: conn, scope: scope} do
    integration = url_integration!(scope)
    {:ok, lv, _html} = live(conn, ipath(scope, "/#{integration.public_id}/version"))
    assert has_element?(lv, "#version-page", "It is fetched again")

    url_sources("false")
    lv |> form("#version-form") |> render_submit()

    assert has_element?(lv, "#version-problems [role=alert]", "Its source must be")
    assert length(Apiary.Repo.all(Release)) == 1
  end
end
