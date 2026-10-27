defmodule ApiaryWeb.ProviderLiveFeaturesTest do
  # Model providers and the workspace's Model need the features `factory` and `secrets`
  # both: with either off, neither section is listed in the settings, and their paths are
  # not found. Not async: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  # The status a path answers: the instance's gate answers before the router, and a
  # page's gate raises a 404 exception.
  defp status(conn, path) do
    get(conn, path).status
  rescue
    error -> Plug.Exception.status(error)
  end

  for {name, features} <- [
        {"factory", [:observability, :security, :secrets]},
        # An instance without secrets is without factory too, which needs it.
        {"secrets", [:observability, :security]}
      ] do
    @tag with_features: features
    test "without #{name}, the sections are not listed and their paths are not found",
         %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings")
      refute has_element?(lv, "#settings-tab-model_providers")

      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings")
      refute has_element?(lv, "#settings-tab-model")

      org = "/#{scope.organisation.slug}/settings/model-providers"

      for path <- [
            org,
            org <> "/new",
            org <> "/con_0000000000000000000000000000",
            "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/model"
          ] do
        assert status(conn, path) == 404, path
      end
    end
  end

  @tag with_features: [:observability, :security, :secrets, :factory]
  test "with both, the sections are listed after Integrations and before Runs",
       %{conn: conn, scope: scope} do
    {:ok, _lv, html} = live(conn, ~p"/#{scope.organisation}/settings")
    tabs = for [_, key] <- Regex.scan(~r/id="settings-tab-([a-z_]+)"/, html), do: key

    assert Enum.drop_while(tabs, &(&1 != "integrations")) |> Enum.take(2) ==
             ~w(integrations model_providers)

    {:ok, _lv, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings")
    tabs = for [_, key] <- Regex.scan(~r/id="settings-tab-([a-z_]+)"/, html), do: key
    assert Enum.drop_while(tabs, &(&1 != "secrets")) == ~w(secrets model workflow runs)
  end
end
