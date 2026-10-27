defmodule ApiaryWeb.ProviderLiveTest do
  # Organisation settings › Model providers (`ApiaryWeb.ProviderLive.Index` and
  # `ApiaryWeb.ProviderLive.Show`): the list, New model provider with its key and, for
  # LiteLLM, its address, and a provider's page with its keys, never a key; who sees what.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.Connections
  alias Apiary.Kinds.{Provider, Providers}
  alias ApiaryWeb.ProviderLive.Index

  @moduletag needs: [:factory, :secrets]

  @key "sk-ant-page-test-0123456789abcdef"

  setup :register_and_log_in_user

  defp list_path(scope), do: ~p"/#{scope.organisation}/settings/model-providers"
  defp new_path(scope), do: ~p"/#{scope.organisation}/settings/model-providers/new"

  defp provider!(scope, name \\ "anthropic", settings \\ %{}) do
    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: name,
        settings: settings,
        keys: [%{value_id: "key-1", value: @key}]
      })

    provider
  end

  defp member_conn(scope, level) do
    %{user: user} = member_fixture(scope, level)
    log_in_user(build_conn(), user)
  end

  defp title(name), do: (Providers.fetch(name) |> elem(1)).title

  # New model provider's form in `html` is sent with POST, and its key's field has no value.
  defp assert_posts_without_key(html) do
    form = LazyHTML.query(html, "#new-provider-form")
    assert LazyHTML.attribute(form, "method") == ["post"]

    key = LazyHTML.query(form, ~s{input[type="password"]})
    assert LazyHTML.attribute(key, "name") == ["provider[key]"]
    assert LazyHTML.attribute(key, "value") == []
  end

  describe "the list" do
    test "lists each provider with its keys, and New model provider for an owner", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = provider!(scope)

      {:ok, lv, _html} = live(conn, list_path(scope))

      assert has_element?(lv, "h1", "Model providers")
      assert page_title(lv) =~ "Model providers · Organisation settings"
      assert has_element?(lv, ~s{#settings-tab-model_providers[aria-current="page"]})
      assert has_element?(lv, "#provider-#{provider.public_id}-name", title("anthropic"))
      assert has_element?(lv, "#provider-#{provider.public_id}-keys", "1")
      assert has_element?(lv, ~s{a#new-model-provider[href="#{new_path(scope)}"]})
      refute has_element?(lv, "#providers-who")
      refute render(lv) =~ @key
    end

    test "a member reads the list without New, and its form's path is not there", ctx do
      %{scope: scope} = ctx
      provider!(scope)
      conn = member_conn(scope, :member)

      {:ok, lv, _html} = live(conn, list_path(scope))

      assert has_element?(lv, "#providers")
      refute has_element?(lv, "#new-model-provider")
      assert has_element?(lv, "#providers-who", "Only owners and admins add model providers.")
      assert_raise ApiaryWeb.NotFound, fn -> live(conn, new_path(scope)) end
    end

    test "an admin adds one", %{scope: scope} do
      {:ok, lv, _html} = live(member_conn(scope, :admin), list_path(scope))
      assert has_element?(lv, "#new-model-provider")
    end

    test "with none, says how to start", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, list_path(scope))
      assert has_element?(lv, "#providers-none", "Add a model key, so agents can run.")
    end
  end

  describe "New model provider" do
    test "adds a provider with its key, never rendering it", ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, lv, _html} = live(conn, new_path(scope))

      refute has_element?(lv, "#new-provider-address")

      {:error, {:live_redirect, %{to: to}}} =
        lv
        |> form("#new-provider-form", provider: %{provider: "anthropic", key: @key})
        |> render_submit()

      assert {:ok, [provider]} = Connections.list_providers(scope)
      assert provider.provider_kind == "anthropic"
      assert to == "#{list_path(scope)}/#{provider.public_id}"

      {:ok, show, html} = live(conn, to)
      assert has_element?(show, "h1", title("anthropic"))
      assert has_element?(show, "#provider-key-key-1", "key-1")
      refute html =~ @key
      refute html =~ String.slice(@key, -4, 4)
    end

    test "About this page says what a key is for, and where to get the chosen one", ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, lv, _html} = live(conn, new_path(scope))

      assert has_element?(lv, "aside#page-context h2", "About this page")

      assert has_element?(
               lv,
               "#page-context #new-provider-what",
               "A model provider's key lets the agents of #{scope.organisation.name}'s runs " <>
                 "call a model."
             )

      assert has_element?(
               lv,
               "#new-provider-get-key",
               "Get the key from the provider first: create an API key in the Claude Console."
             )

      assert has_element?(
               lv,
               "#new-provider-next",
               "After you save, choose #{scope.workspace.name}'s model in Workspace settings › Model."
             )

      # The help that repeated the form is gone.
      refute has_element?(lv, "#new-provider-help")
      refute render(lv) =~ "Press"

      lv
      |> form("#new-provider-form", provider: %{provider: "claude-subscription"})
      |> render_change()

      assert has_element?(lv, "#new-provider-get-key", "claude setup-token")

      assert has_element?(
               lv,
               ~s{#new-provider-get-key a[href="https://code.claude.com/docs/en/legal-and-compliance"][target="_blank"]},
               "Anthropic's terms"
             )

      lv |> form("#new-provider-form", provider: %{provider: "litellm"}) |> render_change()

      assert has_element?(
               lv,
               "#new-provider-get-key",
               "First get a key that your LiteLLM proxy accepts, and the proxy's https address " <>
                 "without /v1, such as https://litellm.example.com."
             )

      assert has_element?(
               lv,
               "#new-provider-address-hint",
               "The proxy's https address without /v1."
             )
    end

    test "Provider is a choice: each provider's title and its description's text", ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, lv, _html} = live(conn, new_path(scope))

      assert has_element?(lv, "button#provider_provider", "Anthropic API key")
      refute has_element?(lv, "select#provider_provider")

      for {provider, index} <- Enum.with_index(Providers.list()) do
        assert has_element?(
                 lv,
                 ~s{#provider_provider-#{index}[type=radio][name="provider[provider]"][value="#{provider.name}"]}
               )

        assert has_element?(lv, "label[for=provider_provider-#{index}]", provider.title)
      end

      # A subtitle is plain text: no backticks, and the terms' address is on About this page.
      subscription = Enum.find_index(Providers.list(), &(&1.name == "claude-subscription"))
      subtitle = lv |> element("#provider_provider-#{subscription}-s") |> render()
      assert subtitle =~ "an access token that claude setup-token creates."
      assert subtitle =~ "on behalf of other users."
      refute subtitle =~ "`"
      refute subtitle =~ "https://"

      # The form sends the radio as it sent the select.
      lv |> form("#new-provider-form", provider: %{provider: "litellm"}) |> render_change()
      assert has_element?(lv, "button#provider_provider", "LiteLLM")
      assert has_element?(lv, "#new-provider-address")
    end

    test "Anthropic's terms are plain words where the description has no address" do
      provider = %Provider{
        name: "claude-subscription",
        title: "Claude subscription token",
        description: %{document: %{"description" => "Runs use your Claude subscription."}}
      }

      assert Index.terms_url(provider) == nil

      html = rendered_to_string(Index.terms(%{href: nil}))
      refute html =~ "<a"
      assert html =~ "Anthropic&#39;s terms"

      html = rendered_to_string(Index.terms(%{href: "https://terms.example.com"}))
      assert html =~ ~s(href="https://terms.example.com")
    end

    test "a refused key leaves the field empty and says why", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, new_path(scope))

      html =
        lv
        |> form("#new-provider-form", provider: %{provider: "anthropic", key: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert {:ok, []} = Connections.list_providers(scope)
    end

    test "posts its form, and the key's field has no value", %{conn: conn, scope: scope} do
      # The page before it connects: a submit there is the browser's, with the form's method.
      html = conn |> get(new_path(scope)) |> html_response(200)
      assert_posts_without_key(LazyHTML.from_document(html))

      {:ok, lv, _html} = live(conn, new_path(scope))
      lv |> form("#new-provider-form", provider: %{provider: "litellm"}) |> render_change()

      html =
        lv
        |> form("#new-provider-form",
          provider: %{provider: "litellm", key: @key, address: "http://litellm.example.com"}
        )
        |> render_submit()

      assert html =~ "https://"
      assert_posts_without_key(LazyHTML.from_fragment(html))
    end

    test "LiteLLM asks its address, and the endpoint rule checks it", ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, lv, _html} = live(conn, new_path(scope))

      lv |> form("#new-provider-form", provider: %{provider: "litellm"}) |> render_change()
      assert has_element?(lv, "#new-provider-address")
      assert has_element?(lv, ~s{label[for="new-provider-address"]}, "Address")

      html =
        lv
        |> form("#new-provider-form",
          provider: %{provider: "litellm", key: @key, address: "http://litellm.example.com"}
        )
        |> render_submit()

      assert html =~ "https://"
      refute html =~ @key
      assert {:ok, []} = Connections.list_providers(scope)

      {:error, {:live_redirect, _}} =
        lv
        |> form("#new-provider-form",
          provider: %{provider: "litellm", key: @key, address: "https://litellm.example.com"}
        )
        |> render_submit()

      assert {:ok, [provider]} = Connections.list_providers(scope)

      assert Connections.Connection.settings_map(provider) == %{
               "address" => "https://litellm.example.com"
             }
    end
  end

  describe "a provider's page" do
    test "a member reads its keys, never a key", %{scope: scope} do
      provider = provider!(scope)
      conn = member_conn(scope, :member)

      {:ok, lv, html} = live(conn, "#{list_path(scope)}/#{provider.public_id}")
      assert has_element?(lv, "#provider-keys", "Keys")
      assert has_element?(lv, "#provider-key-key-1")
      refute html =~ @key
    end

    test "one of another organisation is not found", %{conn: conn, scope: scope} do
      %{scope: other} = sign_up_fixture()
      provider = provider!(other)

      assert_raise ApiaryWeb.NotFound, fn ->
        live(conn, "#{list_path(scope)}/#{provider.public_id}")
      end
    end
  end
end
