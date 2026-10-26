defmodule ApiaryWeb.ProviderLiveTest do
  # Organisation settings › Model providers (`ApiaryWeb.ProviderLive.Index` and
  # `ApiaryWeb.ProviderLive.Show`): the list, New model provider with its key and, for
  # LiteLLM, its address, and a provider's page with its keys, never a key; who sees what.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.Connections
  alias Apiary.Kinds.Providers

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
    test "shows the help and adds a provider with its key, never rendering it", ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, lv, _html} = live(conn, new_path(scope))

      assert has_element?(lv, "#new-provider-help", "First get a key from your model provider:")
      assert has_element?(lv, "#new-provider-help", "claude setup-token")
      assert has_element?(lv, "#new-provider-help", "choose a model for #{scope.workspace.name}")
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
