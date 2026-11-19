defmodule ApiaryProWeb.SettingsLive.ProviderKeysTest do
  @moduledoc """
  The keys of the model providers added for every workspace, on the organisation's Settings
  › Secrets and variables, the Secrets tab: listed with the provider's name and "Model
  provider key", each key by its identity line (`Apiary.ModelKeys.Identity`) and never its
  value id, mask or value; changed and deleted as the provider's keys at the key's row id,
  under `provider.write`, with no Add value and no Rename; the search matches the identity
  line; the secret's deletion refused while the provider links it; a workspace's key not
  listed; and the page with and without the feature `organisation_variables`, which the
  keys do not need.
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
  @third "third-organisation-key-0000009c2e"

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

  # The row id of the key `value_id` of `secret`, which the key's addresses have.
  defp row_id!(secret, value_id),
    do: Repo.get_by!(Secrets.Value, secret_id: secret.id, value_id: value_id).id

  # The Change value page of the key `value_id` of `secret`, at its row id.
  defp change_path(scope, secret, value_id),
    do: secrets_path(scope, "/#{secret.public_id}/values/#{row_id!(secret, value_id)}/change")

  # The identity line of a key of "Claude keys" whose value ends in `tail`.
  defp line(tail \\ "6789"), do: "Claude keys · …#{tail}"

  defp text(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

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
    test "has the key with its provider and its identity line, and what uses it", ctx do
      %{conn: conn, scope: scope, secret: secret} = ctx

      {:ok, lv, html} = live(conn, secrets_path(scope))
      refute_keys(html)

      row = "#secret-#{secret.public_id}"
      assert has_element?(lv, "#{row} .q-title", secret.name)
      assert has_element?(lv, "#{row}-provider", "Claude keys")
      assert has_element?(lv, row, "Model provider key · 1 value")
      assert text(lv, "#{row}-main-value-id") == line()
      refute html =~ "••••"
      assert has_element?(lv, "#{row}-used-by", "Claude keys")

      # Its name stays: no Edit name and note, and no page for it. A model key has no Add
      # value and no Rename.
      refute has_element?(lv, "#{row}-add")
      assert has_element?(lv, "#{row}-delete")
      assert has_element?(lv, "#{row}-main-change")
      refute has_element?(lv, "#{row}-main-rename")
      refute has_element?(lv, "#{row}-edit")

      assert has_element?(lv, ~s{[aria-label="Actions for #{line()} of #{secret.name}"]})

      assert has_element?(
               lv,
               ~s{#{row}-main-change[aria-label="Change value #{line()} of #{secret.name}"]}
             )

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
                 change_path(scope, workspace_secret, "main")
               )

      assert error == "That secret is no longer in #{scope.organisation.name}."
    end
  end

  describe "who changes" do
    test "an owner changes and deletes a key as the provider's, never showing one", ctx do
      %{conn: conn, scope: scope, secret: secret, provider: provider} = ctx
      row = "#secret-#{secret.public_id}"
      {:ok, _provider} = Connections.add_provider_key(scope, provider, %{value: @second})
      {:ok, lv, _html} = live(conn, secrets_path(scope))
      assert text(lv, "#{row}-key-1-value-id") == line("3210")

      lv |> element("#{row}-main-change") |> render_click()
      assert_patch(lv, change_path(scope, secret, "main"))
      assert has_element?(lv, "h1", "Change #{line()} of #{secret.name}")

      html =
        lv |> form("#secret-form", secret_value: %{value: "changed-#{@key}"}) |> render_submit()

      refute_keys(html)
      refute html =~ "changed-#{@key}"
      assert_patch(lv, secrets_path(scope))
      assert render(lv) =~ "#{line()} of #{secret.name} is saved."
      assert reveal(provider, "main") == {:ok, "changed-#{@key}"}
      assert has_element?(lv, row, "Model provider key · 2 values")

      lv |> element("#{row}-key-1-delete") |> render_click()

      assert_patch(
        lv,
        secrets_path(scope, "/#{secret.public_id}/values/#{row_id!(secret, "key-1")}/delete")
      )

      assert has_element?(
               lv,
               "#{row}-key-1-confirm",
               "Delete #{line("3210")} of #{secret.name}?"
             )

      html = lv |> element("#{row}-key-1-confirm button", "Yes, delete") |> render_click()
      refute_keys(html)
      assert render(lv) =~ "#{line("3210")} is deleted from #{secret.name}."
      assert reveal(provider, "key-1") == {:error, :not_found}

      # Each change is the provider's `provider.write` entry, and no `secret.write` entry.
      changes =
        Repo.all(
          from e in Apiary.Audit.Entry,
            where: e.subject_id == ^provider.id,
            select: e.details["change"]
        )

      assert Enum.count(changes, &(&1 == "provider_keys_changed")) == 3
      refute Repo.exists?(from e in Apiary.Audit.Entry, where: e.action == "secret.write")
    end

    test "the default key stays, with why on its confirmation", ctx do
      %{conn: conn, scope: scope, secret: secret, provider: provider} = ctx
      row = "#secret-#{secret.public_id}"
      {:ok, _provider} = Connections.add_provider_key(scope, provider, %{value: @second})
      {:ok, lv, _html} = live(conn, secrets_path(scope))

      lv |> element("#{row}-main-delete") |> render_click()
      assert has_element?(lv, "#{row}-main-confirm", "Delete #{line()} of #{secret.name}?")
      lv |> element("#{row}-main-confirm button", "Yes, delete") |> render_click()

      assert has_element?(
               lv,
               "#secret-refused",
               "Choose another default key for Claude keys first: #{line()} is its default key."
             )

      assert reveal(provider, "main") == {:ok, @key}
    end

    test "Add value and Rename value of a key are not found, as an unknown secret is", ctx do
      %{conn: conn, scope: scope, secret: secret} = ctx
      {:ok, _provider} = Connections.add_provider_key(scope, ctx.provider, %{value: @second})

      for rest <- [
            "/add-value",
            "/values/main/rename",
            "/values/#{row_id!(secret, "main")}/rename",
            "/values/main/change",
            "/values/key-1/change",
            "/values/key-1/delete",
            "/values/#{Ecto.UUID.generate()}/change",
            "/values/#{Ecto.UUID.generate()}/delete"
          ] do
        assert {:error, {:live_redirect, %{flash: %{"error" => error}}}} =
                 live(conn, secrets_path(scope, "/#{secret.public_id}#{rest}")),
               rest

        assert error =~ "no longer", rest
      end

      # An unknown secret has the same refusal.
      assert {:error, {:live_redirect, %{flash: %{"error" => unknown}}}} =
               live(conn, secrets_path(scope, "/sec_0000000000000000000000/add-value"))

      assert unknown == "That secret is no longer in #{scope.organisation.name}."
    end

    @tag with_features: Features.all() -- [:organisation_variables]
    test "an owner changes a key without the feature organisation_variables", ctx do
      %{conn: conn, scope: scope, secret: secret, provider: provider} = ctx

      {:ok, lv, _html} = live(conn, change_path(scope, secret, "main"))

      html = lv |> form("#secret-form", secret_value: %{value: "new-#{@key}"}) |> render_submit()
      refute html =~ "new-#{@key}"
      assert reveal(provider, "main") == {:ok, "new-#{@key}"}

      # The page the feature closes has no Add value for a key either.
      assert_raise ApiaryWeb.NotFound, fn ->
        live(conn, secrets_path(scope, "/#{secret.public_id}/add-value"))
      end
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

      {:ok, lv, _html} = live(conn, change_path(scope, secret, "main"))

      lv |> form("#secret-form", secret_value: %{value: "admin-value"}) |> render_submit()
      assert reveal(provider, "main") == {:ok, "admin-value"}
    end

    test "a member does not open the page, nor has the entry", ctx do
      %{scope: scope, secret: secret} = ctx
      %{user: member} = member_fixture(scope, :member)
      conn = log_in_user(build_conn(), member)

      for rest <- [
            "",
            "/#{secret.public_id}/values/#{row_id!(secret, "main")}/change",
            "/#{secret.public_id}/values/#{row_id!(secret, "main")}/rename",
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
               live(conn, change_path(scope, secret, "main"))

      assert error =~ "change nothing here"
      assert reveal(provider, "main") == {:ok, @key}
    end
  end

  describe "the value lines and the search" do
    setup %{scope: scope, provider: provider} do
      {:ok, _provider} = Connections.add_provider_key(scope, provider, %{value: @third})
      {:ok, _provider} = Connections.add_provider_key(scope, provider, %{value: "sk-short-1"})
      {:ok, _provider} = Connections.add_provider_key(scope, provider, %{value: @second})

      # A key saved before the hint existed has none.
      Repo.update_all(
        from(v in Secrets.Value,
          where: v.secret_id == ^provider.secret_id and v.value_id == "key-3"
        ),
        set: [hint: nil]
      )

      {:ok, plain} =
        Secrets.create_organisation_secret(scope, %{
          "name" => "DEPLOY_TOKEN",
          "values" => %{
            "0" => %{"value_id" => "prod", "value" => "p"},
            "1" => %{"value_id" => "staging", "value" => "s"}
          }
        })

      %{plain: plain}
    end

    defp found?(conn, scope, secret, q) do
      {:ok, lv, _html} = live(conn, secrets_path(scope, "?q=#{URI.encode_www_form(q)}"))
      has_element?(lv, "#secret-#{secret.public_id}")
    end

    test "each value line has the hint, or the provider's name alone for a key with none", ctx do
      %{conn: conn, scope: scope, secret: secret} = ctx
      row = "#secret-#{secret.public_id}"
      {:ok, lv, html} = live(conn, secrets_path(scope))

      assert text(lv, "#{row}-main-value-id") == line()
      assert text(lv, "#{row}-key-1-value-id") == line("9c2e")
      # A value of fewer than 12 characters, and a key saved before the hint existed.
      assert text(lv, "#{row}-key-2-value-id") == "Claude keys"
      assert text(lv, "#{row}-key-3-value-id") == "Claude keys"
      refute html =~ "••••"
      refute html =~ "sk-short-1"
    end

    test "the search matches the identity line of a key, not its value id", ctx do
      %{conn: conn, scope: scope, secret: secret} = ctx

      for q <- ["main", "key-1", "y-1", "0123456789"],
          do: refute(found?(conn, scope, secret, q), q)

      for q <- ["claude", "Claude keys", "6789", "…6789", "9c2e", "…9c2e", "Claude keys · …9c2e"],
          do: assert(found?(conn, scope, secret, q), q)
    end

    test "the search matches the value ids of an ordinary secret as before", ctx do
      %{conn: conn, scope: scope, plain: plain} = ctx

      for q <- ["staging", "prod", "deploy"], do: assert(found?(conn, scope, plain, q), q)
    end

    test "an ordinary secret keeps its value ids, Add value, Rename, Change and Delete", ctx do
      %{conn: conn, scope: scope, plain: plain} = ctx
      row = "#secret-#{plain.public_id}"
      {:ok, lv, _html} = live(conn, secrets_path(scope))

      assert text(lv, "#{row}-prod-value-id") == "prod"
      assert has_element?(lv, "#{row}-add")

      for id <- ~w(prod staging) do
        assert has_element?(lv, "#{row}-#{id}-change")
        assert has_element?(lv, "#{row}-#{id}-rename")
        assert has_element?(lv, "#{row}-#{id}-delete")
      end

      {:ok, lv, _html} = live(conn, secrets_path(scope, "/#{plain.public_id}/add-value"))
      assert has_element?(lv, ~s{#secret-form label}, "Value ID of the new value")

      {:ok, lv, _html} = live(conn, secrets_path(scope, "/#{plain.public_id}/values/prod/rename"))
      assert has_element?(lv, "h1", "Rename prod of DEPLOY_TOKEN")

      {:ok, lv, _html} = live(conn, secrets_path(scope, "/#{plain.public_id}/values/prod/change"))
      assert has_element?(lv, "h1", "Change prod of DEPLOY_TOKEN")

      {:ok, lv, _html} = live(conn, secrets_path(scope))
      lv |> element("#{row}-prod-delete") |> render_click()
      assert has_element?(lv, "#{row}-prod-confirm", "Delete prod of DEPLOY_TOKEN?")
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

    test "has the button on Change value, with the hint, and no Add value", ctx do
      %{conn: conn, scope: scope, login_secret: secret} = ctx
      Stub.put()

      {:ok, lv, _html} = live(conn, change_path(scope, secret, "main"))
      assert words(lv, "#secret-sign-in-start") == "Sign in with ChatGPT"
      assert words(lv, "#secret-sign-in-hint") == @hint
      refute has_element?(lv, "#secret-form textarea")

      assert {:error, {:live_redirect, %{flash: %{"error" => _error}}}} =
               live(conn, secrets_path(scope, "/#{secret.public_id}/add-value"))
    end

    test "has no button while the description has no device sign-in", ctx do
      %{conn: conn, scope: scope, login_secret: secret} = ctx

      {:ok, lv, _html} = live(conn, change_path(scope, secret, "main"))
      refute has_element?(lv, "#secret-sign-in-start")
    end

    test "shows its value line by the email of the sign-in", ctx do
      %{conn: conn, scope: scope, login_secret: secret, subscription: subscription} = ctx
      row = "#secret-#{secret.public_id}"

      {:ok, lv, _html} = live(conn, secrets_path(scope))
      assert words(lv, "#{row}-main-value-id") == "#{subscription.name} · dana@example.com"

      # A sign-in saved before the email was kept has the account line.
      value = Apiary.ModelKeysFixtures.key_value!(subscription, "main")

      Repo.update_all(from(l in Apiary.ModelKeys.Login, where: l.secret_value_id == ^value.id),
        set: [email: nil]
      )

      {:ok, lv, _html} = live(conn, secrets_path(scope))
      assert words(lv, "#{row}-main-value-id") == "#{subscription.name} · account …re-a"
    end

    test "keeps New value and its hint on Change value for an API key, and Value on Add value for another secret",
         ctx do
      %{conn: conn, scope: scope, secret: secret} = ctx
      Stub.put()

      {:ok, lv, _html} = live(conn, change_path(scope, secret, "main"))
      assert words(lv, ~s{#secret-form label[for="secret_value_value"]}) == "New value"

      {:ok, plain} =
        Secrets.create_organisation_secret(scope, %{"name" => "FORGE_TOKEN", "value" => "plain"})

      {:ok, lv, _html} = live(conn, secrets_path(scope, "/#{plain.public_id}/add-value"))
      assert words(lv, ~s{#secret-form label[for="secret_value_value"]}) == "Value"

      assert words(lv, "#secret_value_value-hint") ==
               "Stored encrypted. Nobody sees it again once it is saved."
    end

    test "stores a new sign-in from Change value, showing no token", ctx do
      %{conn: conn, scope: scope, login_secret: secret, subscription: subscription} = ctx
      tokens = Stub.put(tokens: Apiary.ModelKeysFixtures.login_tokens(tag: "pro"), hold: true)
      {:ok, lv, _html} = live(conn, change_path(scope, secret, "main"))

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

      # The form of a sign-in has no field, so the event is sent as the page's handler reads it.
      html = render_submit(lv, "set_value", %{"secret_value" => %{"value" => ""}})

      refute_tokens(html, tokens)
      refute_tokens(render(lv), tokens)

      value = Apiary.ModelKeysFixtures.key_value!(subscription, "main")

      assert %Apiary.ModelKeys.Login{account_id: account, generation: 2} =
               Repo.get!(Apiary.ModelKeys.Login, value.id)

      assert account == tokens.account_id
    end
  end
end
