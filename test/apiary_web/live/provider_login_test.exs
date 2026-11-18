defmodule ApiaryWeb.ProviderLoginTest do
  # The sign-in of an OpenAI subscription's key (`Apiary.ModelKeys.Login`) on Organisation
  # settings › Model providers: Add key and Edit key take the pasted `auth.json` in a
  # field named Sign-in, refuse a paste that is no login with the reason, and never show
  # a token; the provider's page shows each key's sign-in, Signed in or Needs a new
  # sign-in; the workspace's Secrets page takes the same paste for a workspace's key.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Apiary.ModelKeysFixtures

  alias Apiary.{Connections, Repo}
  alias Apiary.ModelKeys.Login

  @moduletag needs: [:factory, :secrets]

  setup :register_and_log_in_user

  defp base(scope), do: ~p"/#{scope.organisation}/settings/model-providers"
  defp key_path(scope, provider, rest), do: "#{base(scope)}/#{provider.public_id}/keys/#{rest}"

  defp subscription!(scope, tokens \\ login_tokens(), place \\ :organisation) do
    {:ok, provider} =
      Connections.create_provider(
        scope,
        %{
          provider: "openai-subscription",
          keys: [%{value_id: "main", value: login_paste(tokens: tokens)}]
        },
        place
      )

    provider
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

  # No token of `tokens`, nor the paste's other members, in `html`.
  defp refute_tokens(html, tokens) do
    for secret <- [tokens.access_token, tokens.refresh_token, tokens.id_token, "auth_mode"],
        do: refute(html =~ secret)
  end

  defp refute_in_assigns(lv, tokens) do
    state = inspect(:sys.get_state(lv.pid), limit: :infinity, printable_limit: :infinity)
    refute_tokens(state, tokens)
  end

  defp login_of(provider, value_id) do
    value = key_value!(provider, value_id)
    Repo.get!(Login, value.id)
  end

  describe "Add key" do
    test "names the field Sign-in and says what to paste, for a subscription's login", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = subscription!(scope)
      {:ok, lv, _html} = live(conn, key_path(scope, provider, "new"))

      assert has_element?(lv, ~s{#key-form label[for="key-value-0"]}, "Sign-in")

      assert has_element?(
               lv,
               "#key-value-0-hint",
               "Paste the contents of auth.json. Qory Apiary stores it encrypted, and nobody can view it again."
             )

      assert has_element?(lv, ~s{#key-form input#key-value-0[type=password]:not([value])})
    end

    test "keeps the names Key and its hint for any other provider", ctx do
      %{conn: conn, scope: scope} = ctx

      {:ok, provider} =
        Connections.create_provider(scope, %{
          provider: "openai",
          keys: [%{value_id: "main", value: "sk-proj-an-api-key"}]
        })

      {:ok, lv, _html} = live(conn, key_path(scope, provider, "new"))

      assert has_element?(lv, ~s{#key-form label[for="key-value-0"]}, "Key")

      assert has_element?(
               lv,
               "#key-value-0-hint",
               "Qory Apiary stores the key encrypted, and nobody can view it again."
             )
    end

    test "stores a pasted login, on several lines or on one, and shows no token", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = subscription!(scope)

      for {name, newlines?} <- [{"spare", true}, {"third", false}] do
        tokens = login_tokens(tag: name)
        paste = login_paste(tokens: tokens)
        paste = if newlines?, do: paste, else: String.replace(paste, "\n", "")
        {:ok, lv, _html} = live(conn, key_path(scope, provider, "new"))

        log =
          capture_log(fn ->
            lv
            |> form("#key-form", key: %{value_id: name, key: paste})
            |> render_submit()

            assert_redirect(lv, "#{base(scope)}/#{provider.public_id}")
          end)

        refute_tokens(log, tokens)
        assert %Login{state: "signed_in", account_id: account} = login_of(provider, name)
        assert account == tokens.account_id
      end
    end

    test "refuses a paste that is no login on the Sign-in, with the Name's errors", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = subscription!(scope)
      {:ok, lv, _html} = live(conn, key_path(scope, provider, "new"))

      html =
        lv
        |> form("#key-form", key: %{value_id: "Bad Name", key: "sk-proj-an-api-key"})
        |> render_submit()

      refute html =~ "sk-proj-an-api-key"
      assert has_element?(lv, "#key_value_id-error")

      assert has_element?(
               lv,
               "#key-value-1-error",
               "Paste the whole auth.json that codex login wrote."
             )

      assert has_element?(lv, ~s{#key-form input#key-value-1[type=password]:not([value])})

      lv
      |> form("#key-form", key: %{value_id: "spare", key: "sk-proj-an-api-key"})
      |> render_submit()

      assert text(lv, "#key-value-2-error") ==
               "Paste the whole auth.json that codex login wrote."

      assert [%{value_id: "main"}] =
               Repo.all(from v in Apiary.Secrets.Value, where: v.secret_id == ^provider.secret_id)
    end

    test "says why a login without a refresh token is refused", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = subscription!(scope)
      {:ok, lv, _html} = live(conn, key_path(scope, provider, "new"))

      no_refresh =
        login_paste()
        |> Jason.decode!()
        |> update_in(["tokens"], &Map.delete(&1, "refresh_token"))
        |> Jason.encode!()

      lv |> form("#key-form", key: %{value_id: "spare", key: no_refresh}) |> render_submit()

      assert text(lv, "#key-value-1-error") ==
               "Paste the whole auth.json that codex login wrote. This text has no refresh token."
    end

    test "keeps no token in the page's assigns", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = subscription!(scope)
      tokens = login_tokens(tag: "assigns")
      {:ok, lv, _html} = live(conn, key_path(scope, provider, "new"))

      lv
      |> form("#key-form", key: %{value_id: "spare", key: login_paste(tokens: tokens) <> "}"})
      |> render_submit()

      refute_in_assigns(lv, tokens)
    end
  end

  describe "Edit key" do
    test "keeps New value and its hint, takes a new login and refuses another paste", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = subscription!(scope)
      {:ok, lv, _html} = live(conn, key_path(scope, provider, "main/edit"))

      assert has_element?(lv, ~s{#key-form label[for="key-value-0"]}, "New value")
      assert has_element?(lv, "#key-value-0-hint", "Leave it empty to keep the value.")

      lv
      |> form("#key-form", key: %{value_id: "main", key: "sk-proj-an-api-key"})
      |> render_submit()

      assert text(lv, "#key-value-1-error") ==
               "Paste the whole auth.json that codex login wrote."

      assert %Login{generation: 1} = login_of(provider, "main")

      tokens = login_tokens(tag: "edit")

      lv
      |> form("#key-form", key: %{value_id: "main", key: login_paste(tokens: tokens)})
      |> render_submit()

      assert_redirect(lv, "#{base(scope)}/#{provider.public_id}")
      assert %Login{generation: 2, account_id: "acct-fixture-edit"} = login_of(provider, "main")
    end

    test "keeps the sign-in when New value is left empty", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = subscription!(scope)
      {:ok, lv, _html} = live(conn, key_path(scope, provider, "main/edit"))

      lv |> form("#key-form", key: %{value_id: "main", key: ""}) |> render_submit()
      assert_redirect(lv, "#{base(scope)}/#{provider.public_id}")
      assert %Login{generation: 1} = login_of(provider, "main")
    end
  end

  describe "the provider's page" do
    test "shows a signed-in key as Signed in, with the last refresh once there is one", ctx do
      %{conn: conn, scope: scope} = ctx
      tokens = login_tokens()
      provider = subscription!(scope, tokens)
      path = "#{base(scope)}/#{provider.public_id}"

      {:ok, lv, html} = live(conn, path)
      refute_tokens(html, tokens)

      assert text(lv, "#provider-key-main-login") == "Signed in."
      assert has_element?(lv, "#provider-key-main-state", "Available")

      value = key_value!(provider, "main")
      refreshed_at = ~U[2026-11-12 10:04:00.000000Z]

      Repo.update_all(from(l in Login, where: l.secret_value_id == ^value.id),
        set: [refreshed_at: refreshed_at]
      )

      {:ok, lv, html} = live(conn, path)
      refute_tokens(html, tokens)
      assert text(lv, "#provider-key-main-login") =~ ~r/\ASigned in\. Last refresh .*2026.*\.\z/
      refute_in_assigns(lv, tokens)
    end

    test "shows a key that needs a new sign-in with what to do, in place of its state", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = subscription!(scope)
      value = key_value!(provider, "main")

      Repo.update_all(from(l in Login, where: l.secret_value_id == ^value.id),
        set: [
          state: "sign_in_needed",
          sign_in_cause: "refresh_token_reused",
          last_failure: ~U[2026-11-12 10:04:00.000000Z]
        ]
      )

      {:ok, lv, html} = live(conn, "#{base(scope)}/#{provider.public_id}")

      assert has_element?(lv, "#provider-key-main-login", "Needs a new sign-in")

      assert text(lv, "#provider-key-main-login") =~
               ~r/\ANeeds a new sign-inOpenAI rejected it on .*2026.*\.Run codex login --device-auth and replace the key\.\z/

      refute has_element?(lv, "#provider-key-main-state")
      refute html =~ "refresh_token_reused"
    end

    test "shows no sign-in for a key of another provider", ctx do
      %{conn: conn, scope: scope} = ctx

      {:ok, provider} =
        Connections.create_provider(scope, %{
          provider: "openai",
          keys: [%{value_id: "main", value: "sk-proj-an-api-key"}]
        })

      {:ok, lv, _html} = live(conn, "#{base(scope)}/#{provider.public_id}")

      refute has_element?(lv, "#provider-key-main-login")
      assert has_element?(lv, "#provider-key-main-state")
    end
  end

  describe "the workspace's Secrets page" do
    defp secrets_path(scope, rest),
      do: "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/secrets#{rest}"

    test "takes the pasted login of a workspace's key in a field named Sign-in", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = subscription!(scope, login_tokens(), :workspace)
      secret = Repo.get!(Apiary.Secrets.Secret, provider.secret_id)

      {:ok, lv, _html} = live(conn, secrets_path(scope, "/#{secret.public_id}/add-value"))

      assert has_element?(lv, ~s{#secret-form label[for="secret_value_value"]}, "Sign-in")

      assert has_element?(
               lv,
               "#secret_value_value-hint",
               "Paste the contents of auth.json. Qory Apiary stores it encrypted, and nobody can view it again."
             )

      lv
      |> form("#secret-form", secret_value: %{value_id: "spare", value: "sk-proj-an-api-key"})
      |> render_submit()

      assert has_element?(
               lv,
               "#secret_value_value-error",
               "Paste the whole auth.json that codex login wrote."
             )

      tokens = login_tokens(tag: "workspace")

      html =
        lv
        |> form("#secret-form",
          secret_value: %{value_id: "spare", value: login_paste(tokens: tokens)}
        )
        |> render_submit()

      refute_tokens(html, tokens)
      assert %Login{account_id: "acct-fixture-workspace"} = login_of(provider, "spare")
      refute_in_assigns(lv, tokens)
    end

    test "keeps Value for the secrets that are no login", ctx do
      %{conn: conn, scope: scope} = ctx

      {:ok, provider} =
        Connections.create_provider(
          scope,
          %{provider: "openai", keys: [%{value_id: "main", value: "sk-proj-an-api-key"}]},
          :workspace
        )

      secret = Repo.get!(Apiary.Secrets.Secret, provider.secret_id)
      {:ok, lv, _html} = live(conn, secrets_path(scope, "/#{secret.public_id}/add-value"))

      assert has_element?(lv, ~s{#secret-form label[for="secret_value_value"]}, "Value")
    end
  end
end
