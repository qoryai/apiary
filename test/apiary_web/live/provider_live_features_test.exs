defmodule ApiaryWeb.ProviderLiveFeaturesTest do
  # Model providers and the workspace's Model need the features `factory` and `secrets`
  # both: with either off, neither section is listed in the settings, and their paths are
  # not found. Not async: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
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
            org <> "/con_0000000000000000000000000000/keys/new",
            org <> "/con_0000000000000000000000000000/keys/#{Ecto.UUID.generate()}/edit",
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

    assert Enum.drop_while(tabs, &(&1 != "secrets")) ==
             ~w(secrets model work_sources destinations harness runs)
  end

  describe "model_proxies" do
    # The radios of Provider in the add form, by the provider each sends.
    defp offered(lv) do
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s{#new-provider-form input[type=radio][name="provider[provider]"]})
      |> LazyHTML.attribute("value")
    end

    defp new_path(scope), do: ~p"/#{scope.organisation}/settings/model-providers/new"

    @tag with_features: Apiary.Features.all() -- [:model_proxies]
    test "off: the add form leaves out LiteLLM, and a LiteLLM provider added stays listed",
         %{conn: conn, scope: scope} = ctx do
      {:ok, lv, _html} = live(conn, new_path(scope))

      assert offered(lv) ==
               ~w(anthropic claude-subscription deepseek openai openai-subscription openrouter)

      # Added while the feature was on: with it off, a LiteLLM provider is not added.
      provider =
        Apiary.ConnectionsFixtures.provider_added_with_model_proxies!(ctx, scope, %{
          provider: "litellm",
          settings: %{"address" => "https://litellm.example.com"},
          keys: [%{value_id: "main", value: "sk-litellm-features-0123456789"}]
        })

      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings/model-providers")
      assert has_element?(lv, "#provider-#{provider.public_id}-name", provider.name)
    end

    @tag with_features: Apiary.Features.all()
    test "on: the add form offers LiteLLM", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, new_path(scope))

      assert offered(lv) ==
               ~w(anthropic claude-subscription deepseek litellm openai openai-subscription openrouter)
    end

    @litellm %{
      "provider" => "litellm",
      "key" => "sk-litellm-features-0123456789",
      "address" => "https://litellm.example.com"
    }

    # The secrets that keep providers' keys (`Apiary.Connections.create_provider/3`).
    defp key_secrets do
      Apiary.Repo.aggregate(
        from(s in Apiary.Secrets.Secret, where: like(s.name, "MODEL_PROVIDER_%")),
        :count
      )
    end

    @tag with_features: Apiary.Features.all() -- [:model_proxies]
    test "off: LiteLLM sent past the add form is refused, and nothing is stored",
         %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, new_path(scope))
      html = render_click(lv, "create", %{"provider" => @litellm})

      assert html =~ "Turn on the feature Model proxies to add LiteLLM: it lists no models."
      assert Apiary.Connections.list_providers(scope) == {:ok, []}
      assert key_secrets() == 0
    end

    @tag with_features: Apiary.Features.all()
    test "on: LiteLLM sent with the add form is stored", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, new_path(scope))

      assert {:error, {:live_redirect, _to}} =
               render_click(lv, "create", %{"provider" => @litellm})

      assert {:ok, [%{provider_kind: "litellm"}]} = Apiary.Connections.list_providers(scope)
      assert key_secrets() == 1
    end

    @tag with_features: Apiary.Features.all() -- [:model_proxies]
    test "off: a LiteLLM provider added before stays, and its edit is not refused",
         %{scope: scope} = ctx do
      provider =
        Apiary.ConnectionsFixtures.provider_added_with_model_proxies!(ctx, scope, %{
          provider: "litellm",
          settings: %{"address" => "https://litellm.example.com"},
          keys: [%{value_id: "main", value: "sk-litellm-features-0123456789"}]
        })

      assert {:ok, %{name: "Team proxy"}} =
               Apiary.Connections.update_provider(scope, provider, %{name: "Team proxy"})

      assert {:ok, [%{id: id}]} = Apiary.Connections.list_providers(scope)
      assert id == provider.id
    end
  end
end
