defmodule ApiaryProWeb.SettingsLive.ProviderKeysTest do
  @moduledoc """
  The keys of the model providers added for every workspace, on the organisation's Settings
  › Secrets and variables, the Secrets tab: listed with the provider's name and "Model
  provider key", masked, never a key; changed, added, renamed and deleted as the provider's
  keys, under `provider.write`; the secret's deletion refused while the provider links it;
  a workspace's key not listed; and the page with and without the feature
  `organisation_variables`, which the keys do not need.
  """
  # Not async: the features are the node's, as in the other pages of the section.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Connections, Features, Repo, Secrets}
  alias Apiary.Connections.Connection
  alias Apiary.Secrets.Secret

  @moduletag with_features: Features.all()
  @moduletag needs: :factory

  @key "sk-ant-organisation-page-key-0123456789"
  @second "second-organisation-key-9876543210"

  setup :register_and_log_in_user

  setup %{scope: scope} do
    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        name: "Claude keys",
        keys: [%{value_id: "main", value: @key}]
      })

    %{provider: provider, secret: Repo.get!(Secret, provider.secret_id)}
  end

  defp secrets_path(scope, rest \\ ""), do: "/#{scope.organisation.slug}/settings/secrets#{rest}"

  # The key `value_id` of `provider`, as the secrets endpoint reveals it, by its row id;
  # `{:error, :not_found}` once no key has that value id.
  defp reveal(provider, value_id) do
    provider = Repo.get!(Connection, provider.id)

    case Repo.one(
           from v in Secrets.Value,
             where: v.secret_id == ^provider.secret_id and v.value_id == ^value_id
         ) do
      nil -> {:error, :not_found}
      value -> Secrets.reveal_key_for_sealing(provider, value.id)
    end
  end

  defp refute_keys(html) do
    refute html =~ @key
    refute html =~ @second
  end

  defp grant!(organisation, feature, granted) do
    Repo.insert!(
      %ApiaryPro.Grants.Grant{
        organisation_id: organisation.id,
        feature: feature,
        granted: granted
      },
      on_conflict: [set: [granted: granted]],
      conflict_target: [:organisation_id, :feature]
    )
  end

  describe "the list" do
    test "has the key with its provider, masked, and what uses it", ctx do
      %{conn: conn, scope: scope, secret: secret} = ctx

      {:ok, lv, html} = live(conn, secrets_path(scope))
      refute_keys(html)

      row = "#secret-#{secret.public_id}"
      assert has_element?(lv, "#{row} .q-title", secret.name)
      assert has_element?(lv, "#{row}-provider", "Claude keys")
      assert has_element?(lv, row, "Model provider key · 1 value")
      assert has_element?(lv, "#{row}-main-value-id", "main")
      assert has_element?(lv, "#{row}-main [aria-hidden=true]", "••••••••••••")
      assert has_element?(lv, "#{row}-used-by", "Claude keys")

      # Its name stays: no Edit name and note, and no page for it.
      assert has_element?(lv, "#{row}-add")
      assert has_element?(lv, "#{row}-delete")
      assert has_element?(lv, "#{row}-main-change")
      assert has_element?(lv, "#{row}-main-rename")
      refute has_element?(lv, "#{row}-edit")

      assert {:error, {:live_redirect, %{flash: %{"error" => error}}}} =
               live(conn, secrets_path(scope, "/#{secret.public_id}/edit"))

      assert error == "That secret is no longer in #{scope.organisation.name}."
    end

    test "has the organisation's secrets and variables tabs with the feature", ctx do
      %{conn: conn, scope: scope, secret: secret} = ctx

      {:ok, plain} =
        Secrets.create_organisation_secret(scope, %{"name" => "FORGE_TOKEN", "value" => "plain"})

      {:ok, lv, _html} = live(conn, secrets_path(scope))
      assert has_element?(lv, "#secrets-tabs-secrets .q-tabs-n", "2")
      assert has_element?(lv, "#secrets-tabs-variables")
      assert has_element?(lv, "#secret-#{plain.public_id}", "FORGE_TOKEN")
      assert has_element?(lv, "#secret-#{secret.public_id}", "Model provider key")
    end

    @tag with_features: Features.all() -- [:organisation_variables]
    test "has the key alone without the feature organisation_variables", ctx do
      %{conn: conn, scope: scope, secret: secret} = ctx

      {:ok, lv, html} = live(conn, secrets_path(scope))
      refute_keys(html)

      assert has_element?(lv, "#secret-#{secret.public_id}", "Model provider key · 1 value")
      refute has_element?(lv, "#secrets-tabs-variables")
      refute has_element?(lv, "#secrets-tabs-secrets")
      refute has_element?(lv, "#new-secret")
      refute has_element?(lv, "#secrets-read-only")

      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings")
      assert has_element?(lv, "#settings-tab-secrets")
    end

    test "does not have a key of one workspace", ctx do
      %{conn: conn, scope: scope, secret: secret} = ctx

      {:ok, workspace_provider} =
        Connections.create_provider(
          scope,
          %{
            provider: "anthropic",
            name: "Only Main keys",
            keys: [%{value_id: "main", value: "workspace-only-key-1122334455"}]
          },
          :workspace
        )

      workspace_secret = Repo.get!(Secret, workspace_provider.secret_id)

      {:ok, lv, html} = live(conn, secrets_path(scope))
      refute html =~ "workspace-only-key-1122334455"
      refute html =~ "Only Main keys"
      refute has_element?(lv, "#secret-#{workspace_secret.public_id}")
      assert has_element?(lv, "#secret-#{secret.public_id}")

      # The workspace's key is not found by its path either.
      assert {:error, {:live_redirect, %{flash: %{"error" => error}}}} =
               live(
                 conn,
                 secrets_path(scope, "/#{workspace_secret.public_id}/values/main/change")
               )

      assert error == "That secret is no longer in #{scope.organisation.name}."
    end
  end

  describe "who changes" do
    test "an owner changes, adds, renames and deletes a key as the provider's, never showing one",
         ctx do
      %{conn: conn, scope: scope, secret: secret, provider: provider} = ctx
      row = "#secret-#{secret.public_id}"
      {:ok, lv, _html} = live(conn, secrets_path(scope))

      lv |> element("#{row}-main-change") |> render_click()
      assert_patch(lv, secrets_path(scope, "/#{secret.public_id}/values/main/change"))

      html =
        lv |> form("#secret-form", secret_value: %{value: "changed-#{@key}"}) |> render_submit()

      refute_keys(html)
      refute html =~ "changed-#{@key}"
      assert_patch(lv, secrets_path(scope))
      assert render(lv) =~ "main of #{secret.name} is saved."
      assert reveal(provider, "main") == {:ok, "changed-#{@key}"}

      lv |> element("#{row}-add") |> render_click()
      assert_patch(lv, secrets_path(scope, "/#{secret.public_id}/add-value"))

      html =
        lv
        |> form("#secret-form", secret_value: %{value_id: "spare", value: @second})
        |> render_submit()

      refute_keys(html)
      assert render(lv) =~ "spare is added to #{secret.name}."
      assert reveal(provider, "spare") == {:ok, @second}
      assert has_element?(lv, row, "Model provider key · 2 values")

      lv |> element("#{row}-spare-rename") |> render_click()
      lv |> form("#secret-form", secret_value: %{value_id: "backup"}) |> render_submit()
      assert render(lv) =~ "spare of #{secret.name} is now backup."
      assert reveal(provider, "backup") == {:ok, @second}

      # The default key stays, with why on its confirmation.
      lv |> element("#{row}-main-delete") |> render_click()
      lv |> element("#{row}-main-confirm button", "Yes, delete") |> render_click()

      assert has_element?(
               lv,
               "#secret-refused",
               "Choose another default key for Claude keys first: main is its default key."
             )

      lv |> element("#{row}-backup-delete") |> render_click()
      html = lv |> element("#{row}-backup-confirm button", "Yes, delete") |> render_click()
      refute_keys(html)
      assert render(lv) =~ "backup is deleted from #{secret.name}."
      assert reveal(provider, "backup") == {:error, :not_found}

      # Each change is the provider's `provider.write` entry, and no `secret.write` entry.
      changes =
        Repo.all(
          from e in Apiary.Audit.Entry,
            where: e.subject_id == ^provider.id,
            select: e.details["change"]
        )

      assert Enum.count(changes, &(&1 == "provider_keys_changed")) == 4
      refute Repo.exists?(from e in Apiary.Audit.Entry, where: e.action == "secret.write")
    end

    @tag with_features: Features.all() -- [:organisation_variables]
    test "an owner changes a key without the feature organisation_variables", ctx do
      %{conn: conn, scope: scope, secret: secret, provider: provider} = ctx

      {:ok, lv, _html} =
        live(conn, secrets_path(scope, "/#{secret.public_id}/values/main/change"))

      html = lv |> form("#secret-form", secret_value: %{value: "new-#{@key}"}) |> render_submit()
      refute html =~ "new-#{@key}"
      assert reveal(provider, "main") == {:ok, "new-#{@key}"}

      {:ok, lv, _html} = live(conn, secrets_path(scope, "/#{secret.public_id}/add-value"))

      lv
      |> form("#secret-form", secret_value: %{value_id: "spare", value: @second})
      |> render_submit()

      assert reveal(provider, "spare") == {:ok, @second}
    end

    test "refuses to delete the secret while the provider links it", ctx do
      %{conn: conn, scope: scope, secret: secret, provider: provider} = ctx
      row = "#secret-#{secret.public_id}"
      {:ok, lv, _html} = live(conn, secrets_path(scope))

      lv |> element("#{row}-delete") |> render_click()
      assert_patch(lv, secrets_path(scope, "/#{secret.public_id}/delete"))
      lv |> element("#{row}-confirm button", "Yes, delete") |> render_click()

      assert has_element?(
               lv,
               "#secret-refused",
               "Change or add a value instead. Model provider Claude keys uses this secret, so it cannot be deleted."
             )

      assert Repo.get(Secret, secret.id)
      assert reveal(provider, "main") == {:ok, @key}
    end

    test "an admin changes a key", ctx do
      %{scope: scope, secret: secret, provider: provider} = ctx
      %{user: admin} = member_fixture(scope, :admin)
      conn = log_in_user(build_conn(), admin)

      {:ok, lv, _html} = live(conn, secrets_path(scope))
      assert has_element?(lv, "#secret-#{secret.public_id}-menu")

      {:ok, lv, _html} =
        live(conn, secrets_path(scope, "/#{secret.public_id}/values/main/change"))

      lv |> form("#secret-form", secret_value: %{value: "admin-value"}) |> render_submit()
      assert reveal(provider, "main") == {:ok, "admin-value"}
    end

    test "a member does not open the page, nor has the entry", ctx do
      %{scope: scope, secret: secret} = ctx
      %{user: member} = member_fixture(scope, :member)
      conn = log_in_user(build_conn(), member)

      for rest <- [
            "",
            "/#{secret.public_id}/values/main/change",
            "/#{secret.public_id}/values/main/rename",
            "/#{secret.public_id}/add-value",
            "/#{secret.public_id}/delete"
          ] do
        assert_raise ApiaryWeb.NotFound, fn -> live(conn, secrets_path(scope, rest)) end
      end

      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings")
      refute has_element?(lv, "#settings-tab-secrets")
    end

    test "a reader who is no member reads the key's row, and changes nothing", ctx do
      %{scope: scope, secret: secret, provider: provider} = ctx
      conn = log_in_user(build_conn(), instance_admin_fixture().user)

      {:ok, lv, html} = live(conn, secrets_path(scope))
      refute_keys(html)
      assert has_element?(lv, "#secret-#{secret.public_id}", "Model provider key")
      refute has_element?(lv, "#secret-#{secret.public_id}-menu")

      assert {:error, {:live_redirect, %{flash: %{"error" => error}}}} =
               live(conn, secrets_path(scope, "/#{secret.public_id}/values/main/change"))

      assert error =~ "change nothing here"
      assert reveal(provider, "main") == {:ok, @key}
    end
  end

  describe "without the feature organisation_variables" do
    @describetag with_features: Features.all() -- [:organisation_variables]

    test "reaches no secret and no variable of the organisation through the page", ctx do
      %{conn: conn, scope: scope} = ctx

      for rest <- [
            "/new",
            "/sec_0000000000000000000000/edit",
            "/sec_0000000000000000000000/delete"
          ] do
        assert_error_sent :not_found, fn -> get(conn, secrets_path(scope, rest)) end
      end

      for page <- ["", "/new", "/1/change", "/1/delete"] do
        assert conn
               |> get("/#{scope.organisation.slug}/settings/variables#{page}")
               |> html_response(404)
      end
    end
  end

  describe "in an organisation shown no variables" do
    @describetag needs: :managed_organisations

    test "does not reach a secret of the organisation by its path, and keeps the keys" do
      operator = operator_fixture()
      conn = log_in_user(build_conn(), operator.user)
      grant!(operator.organisation, :organisation_variables, true)

      {:ok, secret} =
        Secrets.create_organisation_secret(operator.scope, %{
          "name" => "FORGE_TOKEN",
          "value" => "plain-value-not-shown"
        })

      {:ok, provider} =
        Connections.create_provider(operator.scope, %{
          provider: "anthropic",
          name: "Operator keys",
          keys: [%{value_id: "main", value: @key}]
        })

      key_secret = Repo.get!(Secret, provider.secret_id)

      grant!(operator.organisation, :organisation_variables, false)

      {:ok, lv, html} = live(conn, secrets_path(operator.scope))
      refute html =~ "plain-value-not-shown"
      refute has_element?(lv, "#secret-#{secret.public_id}")
      refute has_element?(lv, "#secrets-tabs-variables")
      assert has_element?(lv, "#secret-#{key_secret.public_id}", "Model provider key")

      for act <- ~w(edit add-value change-value delete) do
        assert_error_sent :not_found, fn ->
          get(conn, secrets_path(operator.scope, "/#{secret.public_id}/#{act}"))
        end
      end

      # The page's events reach no secret of the organisation either.
      assert reveal(provider, "main") == {:ok, @key}

      grant!(operator.organisation, :organisation_variables, true)
      assert {:ok, [%{id: id}]} = Secrets.list_organisation_secrets(operator.scope)
      assert id == secret.id
    end
  end

  describe "the key of a subscription, a login" do
    alias Apiary.DeviceSignInStub, as: Stub

    @hint "Qory Apiary signs in to ChatGPT for this key. You enter a code on OpenAI's page, and you paste nothing."

    setup %{scope: scope} do
      {:ok, subscription} =
        Connections.create_provider(scope, %{
          provider: "openai-subscription",
          keys: [%{value_id: "main", value: Apiary.ModelKeysFixtures.device_login()}]
        })

      %{subscription: subscription, login_secret: Repo.get!(Secret, subscription.secret_id)}
    end

    defp words(lv, selector) do
      lv
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")
    end

    defp refute_tokens(html, tokens) do
      for secret <- [
            tokens.access_token,
            tokens.refresh_token,
            tokens.id_token,
            "device-auth-fixture",
            "authorization-code-fixture",
            "verifier-fixture"
          ],
          do: refute(html =~ secret)
    end

    test "has the button on Add value and Change value, with the hint", ctx do
      %{conn: conn, scope: scope, login_secret: secret} = ctx
      Stub.put()

      {:ok, lv, _html} = live(conn, secrets_path(scope, "/#{secret.public_id}/add-value"))
      assert words(lv, "#secret-sign-in-start") == "Sign in with ChatGPT"
      assert words(lv, "#secret-sign-in-hint") == @hint
      refute has_element?(lv, "#secret-form textarea")

      {:ok, lv, _html} =
        live(conn, secrets_path(scope, "/#{secret.public_id}/values/main/change"))

      assert words(lv, "#secret-sign-in-start") == "Sign in with ChatGPT"
      assert words(lv, "#secret-sign-in-hint") == @hint
    end

    test "has no button while the description has no device sign-in", ctx do
      %{conn: conn, scope: scope, login_secret: secret} = ctx

      {:ok, lv, _html} = live(conn, secrets_path(scope, "/#{secret.public_id}/add-value"))
      refute has_element?(lv, "#secret-sign-in-start")
    end

    test "keeps Value and New value, and their hint, for an API key", ctx do
      %{conn: conn, scope: scope, secret: secret} = ctx
      Stub.put()

      {:ok, lv, _html} = live(conn, secrets_path(scope, "/#{secret.public_id}/add-value"))
      assert words(lv, ~s{#secret-form label[for="secret_value_value"]}) == "Value"

      assert words(lv, "#secret_value_value-hint") ==
               "Stored encrypted. Nobody sees it again once it is saved."

      {:ok, lv, _html} =
        live(conn, secrets_path(scope, "/#{secret.public_id}/values/main/change"))

      assert words(lv, ~s{#secret-form label[for="secret_value_value"]}) == "New value"
    end

    test "refuses Add value before the sign-in, then stores the sign-in, showing no token",
         ctx do
      %{conn: conn, scope: scope, login_secret: secret, subscription: subscription} = ctx
      tokens = Stub.put(tokens: Apiary.ModelKeysFixtures.login_tokens(tag: "pro"), hold: true)
      {:ok, lv, _html} = live(conn, secrets_path(scope, "/#{secret.public_id}/add-value"))

      lv |> form("#secret-form", secret_value: %{value_id: "spare"}) |> render_submit()

      assert words(lv, "#secret-sign-in-error-1") ==
               "Click Sign in with ChatGPT, then save. This key has no sign-in yet."

      assert [%{value_id: "main"}] =
               Repo.all(from v in Secrets.Value, where: v.secret_id == ^subscription.secret_id)

      lv |> element("#secret-sign-in-start") |> render_click()
      Stub.eventually(fn -> assert has_element?(lv, "#secret-sign-in-code") end)
      assert words(lv, "#secret-sign-in-code") == "7QKD-M4TPX"
      Stub.approve()
      Stub.eventually(fn -> assert has_element?(lv, "#secret-sign-in-state", "Signed in.") end)

      refute_tokens(render(lv), tokens)

      refute_tokens(
        inspect(:sys.get_state(lv.pid), limit: :infinity, printable_limit: :infinity),
        tokens
      )

      html = lv |> form("#secret-form", secret_value: %{value_id: "spare"}) |> render_submit()

      refute_tokens(html, tokens)
      refute_tokens(render(lv), tokens)

      value = Apiary.ModelKeysFixtures.key_value!(subscription, "spare")

      assert %Apiary.ModelKeys.Login{account_id: account} =
               Repo.get!(Apiary.ModelKeys.Login, value.id)

      assert account == tokens.account_id
    end
  end
end
