defmodule ApiaryWeb.ProviderNewKeyTest do
  # A key the model provider returned 401 to (`Apiary.ModelKeys.reject/3`) on Organisation
  # settings > Model providers: the provider's page shows Needs a new key in the key's row
  # in place of its state, with who rejected it and when, and Edit key says under New value
  # what to enter. A new value, saved on Edit key, takes the state away. The page shows no
  # token.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.DebugLog
  import Apiary.ModelKeysFixtures, only: [in_seconds: 1, key_state!: 3, run_key!: 2]
  import Phoenix.LiveViewTest

  alias Apiary.{Connections, ModelKeys, Repo}
  alias Apiary.Secrets.Value

  import Ecto.Query, only: [from: 2]

  @moduletag needs: [:factory, :secrets]

  setup :register_and_log_in_user

  defp base(scope), do: ~p"/#{scope.organisation}/settings/model-providers"

  defp provider!(scope) do
    keys = for id <- ~w(main spare), do: %{value_id: id, value: "sk-ant-fixture-#{id}-0123456789"}
    {:ok, provider} = Connections.create_provider(scope, %{provider: "anthropic", keys: keys})
    provider
  end

  # The Edit key page of the key `value_id`, at its row id.
  defp edit_path(scope, provider, value_id) do
    value =
      Repo.one!(
        from v in Value, where: v.secret_id == ^provider.secret_id and v.value_id == ^value_id
      )

    "#{base(scope)}/#{provider.public_id}/keys/#{value.id}/edit"
  end

  # The id of the key `value_id` in the page source: its row id.
  defp key_dom(provider, value_id) do
    value =
      Repo.one!(
        from v in Value, where: v.secret_id == ^provider.secret_id and v.value_id == ^value_id
      )

    "provider-key-#{value.id}"
  end

  defp reject!(scope, provider, value_id, at) do
    value =
      Repo.one!(
        from v in Value, where: v.secret_id == ^provider.secret_id and v.value_id == ^value_id
      )

    # A run that has the key's current token: a sign-in's copy has its time.
    login = Repo.get(Apiary.ModelKeys.Login, value.id)

    key = %{
      run_key!(scope, value)
      | copy_login_at: login && (login.refreshed_at || login.signed_in_at)
    }

    :ok =
      ModelKeys.reject(
        [key],
        [%{credential: "model-1", at: at}],
        DateTime.utc_now()
      )
  end

  defp text(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  test "the provider's page shows Needs a new key for a rejected key and the other as it was",
       %{conn: conn, scope: scope} do
    provider = provider!(scope)
    reject!(scope, provider, "main", ~U[2026-11-18 09:12:00.000000Z])

    {:ok, lv, html} = live(conn, "#{base(scope)}/#{provider.public_id}")

    assert has_element?(lv, "##{key_dom(provider, "main")}-new-key", "Needs a new key")

    assert text(lv, "##{key_dom(provider, "main")}-new-key") =~
             ~r/\ANeeds a new keyAnthropic rejected it on .*2026.*\./

    refute has_element?(lv, "##{key_dom(provider, "main")}-state")
    assert has_element?(lv, "##{key_dom(provider, "spare")}-state")
    refute has_element?(lv, "##{key_dom(provider, "spare")}-new-key")
    refute html =~ "sk-ant-fixture"
  end

  describe "the list of providers counts the keys that need a new key" do
    defp keys_line(lv, provider), do: text(lv, "#provider-#{provider.public_id}-keys")

    test "after the keys, only when one does: needs for one key, need for more", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = provider!(scope)

      {:ok, lv, _html} = live(conn, base(scope))
      assert keys_line(lv, provider) == "2 keys"

      reject!(scope, provider, "main", ~U[2026-11-18 09:12:00.000000Z])
      {:ok, lv, _html} = live(conn, base(scope))
      assert keys_line(lv, provider) == "2 keys, 1 needs a new key"

      reject!(scope, provider, "spare", ~U[2026-11-18 09:12:00.000000Z])
      {:ok, lv, _html} = live(conn, base(scope))
      assert keys_line(lv, provider) == "2 keys, 2 need a new key"
    end

    test "after the count in cooldown, when a key is in cooldown", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = provider!(scope)
      key_state!(provider, "spare", until: in_seconds(3_600))
      reject!(scope, provider, "main", ~U[2026-11-18 09:12:00.000000Z])

      {:ok, lv, _html} = live(conn, base(scope))

      assert keys_line(lv, provider) == "2 keys, 1 in cooldown, 1 needs a new key"
    end

    test "not for a key whose new value was saved since", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = provider!(scope)
      reject!(scope, provider, "main", ~U[2026-11-18 09:12:00.000000Z])

      {:ok, _provider} =
        Connections.set_provider_key(scope, provider, "main", "sk-ant-fixture-main-9876543210")

      {:ok, lv, _html} = live(conn, base(scope))
      assert keys_line(lv, provider) == "2 keys"
    end
  end

  test "Edit key says what to enter, and a new value takes the state away",
       %{conn: conn, scope: scope} do
    provider = provider!(scope)
    reject!(scope, provider, "main", ~U[2026-11-18 09:12:00.000000Z])
    path = edit_path(scope, provider, "main")

    {:ok, lv, html} = live(conn, path)

    assert has_element?(lv, "#key-new-key", "Needs a new key")
    assert html =~ "Enter a new value: the stored one no longer works."

    lv
    |> form("#key-form", %{"key" => %{"key" => "sk-ant-fixture-main-9876543210"}})
    |> render_submit()

    assert ModelKeys.rejections(Repo.get!(Apiary.Connections.Connection, provider.id)) == %{}

    {:ok, lv, html} = live(conn, "#{base(scope)}/#{provider.public_id}")
    refute has_element?(lv, "##{key_dom(provider, "main")}-new-key")
    assert has_element?(lv, "##{key_dom(provider, "main")}-state")
    refute html =~ "sk-ant-fixture"
  end

  test "Edit key of a key that is not rejected has the usual hint", %{conn: conn, scope: scope} do
    provider = provider!(scope)
    reject!(scope, provider, "main", ~U[2026-11-18 09:12:00.000000Z])

    {:ok, lv, html} = live(conn, edit_path(scope, provider, "spare"))

    refute has_element?(lv, "#key-new-key")
    refute html =~ "Enter a new value: the stored one no longer works."
  end

  test "a sign-in the provider rejected shows Needs a new sign-in, with no token",
       %{conn: conn, scope: scope} do
    import Apiary.ModelKeysFixtures
    tokens = login_tokens()

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "openai-subscription",
        keys: [%{value_id: "main", value: device_login(tokens: tokens)}]
      })

    # A sign-in made just now: no refresh can fix a 401 on it.
    reject!(scope, provider, "main", DateTime.utc_now())

    {{lv, html}, log} =
      with_debug_log(fn ->
        {:ok, lv, html} = live(conn, "#{base(scope)}/#{provider.public_id}")
        {lv, html}
      end)

    assert has_element?(lv, "##{key_dom(provider, "main")}-login", "Needs a new sign-in")
    refute has_element?(lv, "##{key_dom(provider, "main")}-new-key")

    for text <- [html, log] do
      refute_secrets(text, [tokens.access_token, tokens.refresh_token, tokens.account_id])
    end
  end
end
