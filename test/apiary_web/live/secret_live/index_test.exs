defmodule ApiaryWeb.SecretLive.IndexTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.{Repo, Secrets, Variables}
  alias Apiary.Runs.Target

  @moduletag needs: :security

  # A value that must never come back to a browser: neither after its save, nor after a
  # refused one.
  @value "ghp_exampleTokenValue0123456789"

  setup :register_and_log_in_user

  defp secrets_path(scope, rest \\ ""),
    do: "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/secrets#{rest}"

  defp variables_path(scope, rest \\ ""),
    do: "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/variables#{rest}"

  defp secret!(scope, attrs) do
    {:ok, secret} = Secrets.create_secret(scope, Map.merge(%{value: @value}, attrs))
    secret
  end

  defp variable!(scope, holder, name, value, attrs \\ %{}) do
    {:ok, variable} =
      Variables.create_variable(scope, holder, Map.merge(%{name: name, value: value}, attrs))

    variable
  end

  defp target!(scope, path) do
    Repo.insert!(%Target{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      system: "github.example",
      path: path,
      first_seen_at: DateTime.utc_now()
    })
  end

  defp reveal(scope, secret, value_id \\ nil),
    do: Secrets.reveal_for_sealing(scope.workspace, secret.public_id, value_id)

  defp secrets(scope) do
    {:ok, secrets} = Secrets.list_secrets(scope)
    secrets
  end

  defp member_conn(scope, level) do
    %{user: user} = member_fixture(scope, level)
    log_in_user(build_conn(), user)
  end

  defp refute_value(html), do: refute(html =~ @value)

  # A page's or a dialog's path the page refuses as it opens: back to the list, with why.
  defp refused_at(conn, path) do
    assert {:error, {:live_redirect, %{flash: flash, to: to}}} = live(conn, path)
    refute String.contains?(to, ["/new", "/delete", "/change", "/lock", "/rename"])
    flash["error"]
  end

  describe "the section" do
    test "is one entry of the workspace's settings, for every member", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings")
      assert has_element?(lv, "#settings-tab-secrets", "Secrets and variables")

      {:ok, lv, _html} = live(member_conn(scope, :member), secrets_path(scope))
      assert has_element?(lv, "#settings-tab-secrets[aria-current=page]")
      assert has_element?(lv, "#secrets-tabs-secrets[aria-current=page]")
    end

    test "has two tabs under its title, links with their counts, each with its own panel",
         %{conn: conn, scope: scope} do
      secret!(scope, %{name: "FORGE_TOKEN"})
      variable!(scope, :workspace, "NODE_ENV", "production")
      variable!(scope, :workspace, "NPM_REGISTRY", "https://registry.example.com")
      names = "#{scope.workspace.name} · #{scope.organisation.name}"

      {:ok, lv, _html} = live(conn, secrets_path(scope))

      # The section is the h1, the level is the frame's: the breadcrumb ends with the
      # section, the page.
      assert has_element?(lv, "h1#settings-section-title", "Secrets and variables")
      assert has_element?(lv, "#breadcrumb-settings", "Workspace settings")
      assert has_element?(lv, "#breadcrumb-section[aria-current=page]", "Secrets and variables")
      assert page_title(lv) =~ "Secrets and variables · Workspace settings · #{names}"

      # The tabs are links in a navigation named by the section, not an ARIA tablist.
      assert has_element?(lv, "nav#secrets-tabs[aria-label='Secrets and variables']")
      refute has_element?(lv, "#secrets-tabs [role=tab]")
      refute has_element?(lv, "#secrets-tabs[role=tablist]")
      refute has_element?(lv, "#secrets-views")

      assert has_element?(
               lv,
               "#secrets-tabs a#secrets-tabs-secrets[href='#{secrets_path(scope)}'][aria-current=page]",
               "Secrets"
             )

      assert has_element?(lv, "#secrets-tabs-secrets .q-tabs-n", "1")

      assert has_element?(
               lv,
               "#secrets-tabs a#secrets-tabs-variables[href='#{variables_path(scope)}']:not([aria-current])",
               "Variables"
             )

      assert has_element?(lv, "#secrets-tabs-variables .q-tabs-n", "2")

      # The header's action does not change with the tab: each tab's New is in its panel,
      # beside its search.
      refute has_element?(lv, "#settings-section-secrets .q-settings-actions")
      assert has_element?(lv, "#secrets-tabs-panel .q-bar #new-secret")
      assert has_element?(lv, "#secrets-tabs-panel .q-bar #secrets-search")
      refute has_element?(lv, "#new-variable")

      # One status line, there from the start: nothing to say on arrival.
      assert lv |> element("#secrets-and-variables-status[role=status]") |> render() =~
               ~r{<div[^>]*>\s*</div>}

      lv |> element("#secrets-tabs-variables") |> render_click()
      assert_patch(lv, variables_path(scope))

      assert has_element?(lv, "#secrets-tabs-variables[aria-current=page]")
      refute has_element?(lv, "#secrets-tabs-secrets[aria-current]")
      assert has_element?(lv, "#settings-tab-secrets[aria-current=true]")
      assert has_element?(lv, "#breadcrumb-section[aria-current=page]", "Secrets and variables")

      assert page_title(lv) =~
               "Variables · Secrets and variables · Workspace settings · #{names}"

      assert has_element?(lv, "#secrets-and-variables-status", "Variables, 2")
      assert has_element?(lv, "#secrets-tabs-panel .q-bar #new-variable")
      assert has_element?(lv, "#secrets-tabs-panel .q-bar #variables-search")
      refute has_element?(lv, "#new-secret")

      assert has_element?(
               lv,
               "#secrets-tabs-panel #not-on-runs",
               "Runs don't receive variables yet."
             )

      lv |> element("#secrets-tabs-secrets") |> render_click()
      assert_patch(lv, secrets_path(scope))
      assert has_element?(lv, "#secrets-and-variables-status", "Secrets, 1")
      assert has_element?(lv, "#settings-tab-secrets[aria-current=page]")

      # A search says what it left, in the same line.
      lv |> form("#secrets-search", q: "forge") |> render_change()
      assert has_element?(lv, "#secrets-and-variables-status", "1 secret matches")
      refute has_element?(lv, "#secrets-and-variables-status", "Secrets, 1")
    end

    test "shows no tabs on a page of a form", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, variables_path(scope, "/new"))

      refute has_element?(lv, "#secrets-tabs")
      refute has_element?(lv, "#secrets-and-variables-status")
      assert has_element?(lv, "#settings-tab-secrets[aria-current=true]")

      # The tabs are not segments: the trail goes from the section to the page.
      assert has_element?(lv, "#breadcrumb-settings", "Workspace settings")

      assert has_element?(
               lv,
               "#breadcrumb a#breadcrumb-section[href='#{variables_path(scope)}']",
               "Secrets and variables"
             )

      assert has_element?(lv, "#breadcrumb [aria-current=page]", "New variable")

      assert page_title(lv) =~
               "New variable · Workspace settings · #{scope.workspace.name} · #{scope.organisation.name}"
    end

    test "is another organisation's to read, not this one's", %{scope: scope} do
      other = sign_up_fixture()
      conn = log_in_user(build_conn(), other.user)

      assert get(conn, secrets_path(scope)).status == 404
      assert get(conn, variables_path(scope)).status == 404
    end
  end

  describe "secrets, as an owner" do
    test "starts empty, and a new secret is saved without its value coming back",
         %{conn: conn, scope: scope} do
      {:ok, lv, html} = live(conn, secrets_path(scope))
      assert has_element?(lv, "#secrets-empty")
      assert html =~ "New secret"

      # No run receives a secret yet, which the view says once, and nothing says otherwise.
      assert has_element?(
               lv,
               "#not-on-runs",
               "Runs don't receive secrets yet. Today a run receives only its security policy."
             )

      refute html =~ "the runs of this workspace are given"
      refute html =~ "runs are given"
      refute has_element?(lv, "#secrets-read-only")

      lv |> element("#new-secret") |> render_click()
      assert_patch(lv, secrets_path(scope, "/new"))

      # A page of the section, not a dialog over the list: the section's list beside it,
      # the breadcrumb ending with the section and the page, Cancel back to the list.
      refute has_element?(lv, "#secret-dialog")
      refute has_element?(lv, "#secrets")
      assert has_element?(lv, "#settings-tab-secrets[aria-current=true]")
      assert has_element?(lv, "#secret-page-title", "New secret")
      refute has_element?(lv, "#secret-page-back")
      assert has_element?(lv, "#secret-page #not-on-runs", "Runs don't receive secrets yet.")
      refute render(lv) =~ "runs are given"
      refute has_element?(lv, "#secrets-tabs")
      assert has_element?(lv, "#breadcrumb-settings", "Workspace settings")
      assert has_element?(lv, "#breadcrumb a#breadcrumb-section", "Secrets and variables")
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "New secret")
      assert has_element?(lv, "#secret-form textarea[name='secret[value]']")
      assert has_element?(lv, "#secret-save-cancel[href='#{secrets_path(scope)}']", "Cancel")

      assert page_title(lv) =~
               "New secret · Workspace settings · #{scope.workspace.name} · #{scope.organisation.name}"

      # The form sends nothing until it is submitted: a value travels only then.
      refute lv |> element("#secret-form") |> render() =~ "phx-change"

      html =
        lv
        |> form("#secret-form",
          secret: %{name: "FORGE_TOKEN", value: @value, note: "Opens pull requests"}
        )
        |> render_submit()

      refute_value(html)
      assert_patch(lv, secrets_path(scope))
      html = render(lv)
      refute_value(html)
      assert html =~ "FORGE_TOKEN is saved."
      refute has_element?(lv, "#secret-form")

      [secret] = secrets(scope)
      assert reveal(scope, secret) == {:ok, @value}
      assert has_element?(lv, "#secret-#{secret.public_id}", "FORGE_TOKEN")
      assert has_element?(lv, "#secret-#{secret.public_id}", "One value")
      assert has_element?(lv, "#secret-#{secret.public_id}", "Not used yet")

      # Opened again, the field is empty.
      lv |> element("#new-secret") |> render_click()
      refute_value(render(lv))

      assert lv |> element("#secret-form textarea[name='secret[value]']") |> render() =~
               "></textarea>"

      # Cancel goes back to the list, saving nothing.
      lv |> element("#secret-save-cancel") |> render_click()
      assert_patch(lv, secrets_path(scope))
      assert has_element?(lv, "#secrets")
      assert [_one] = secrets(scope)
    end

    test "a refused save says why and does not render the value",
         %{conn: conn, scope: scope} do
      secret!(scope, %{name: "FORGE_TOKEN"})
      {:ok, lv, _html} = live(conn, secrets_path(scope, "/new"))

      html =
        lv
        |> form("#secret-form", secret: %{name: "1NOT_A_NAME", value: @value})
        |> render_submit()

      refute_value(html)
      assert html =~ "must start with a letter or _"
      assert has_element?(lv, "#secret-form")

      assert lv |> element("#secret-form textarea[name='secret[value]']") |> render() =~
               "></textarea>"

      html =
        lv
        |> form("#secret-form", secret: %{name: "forge_token", value: @value})
        |> render_submit()

      refute_value(html)
      assert html =~ "is already the name of a secret in this workspace"

      html =
        lv
        |> form("#secret-form", secret: %{name: "NPM_REGISTRY", value: ""})
        |> render_submit()

      assert has_element?(lv, "#secret_value-error")
      refute_value(html)
      assert [_one] = secrets(scope)
    end

    test "adds a value, naming the one it holds, and lists each value with who changed it",
         %{conn: conn, scope: scope} do
      secret = secret!(scope, %{name: "GITHUB_APP_PRIVATE_KEY"})
      {:ok, lv, _html} = live(conn, secrets_path(scope))

      lv |> element("#secret-#{secret.public_id}-add") |> render_click()
      assert_patch(lv, secrets_path(scope, "/#{secret.public_id}/add-value"))
      refute has_element?(lv, "#secret-dialog")
      assert has_element?(lv, "#secret-page-title", "Add a value to GITHUB_APP_PRIVATE_KEY")
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "Add value")
      refute lv |> element("#secret-form") |> render() =~ "phx-change"

      html =
        lv
        |> form("#secret-form",
          secret_value: %{first_value_id: "", value_id: "bot-app", value: "second-#{@value}"}
        )
        |> render_submit()

      refute_value(html)
      assert has_element?(lv, "#secret_value_first_value_id-error")

      html =
        lv
        |> form("#secret-form",
          secret_value: %{first_value_id: "main-app", value_id: "bot-app", value: "second"}
        )
        |> render_submit()

      refute_value(html)
      assert_patch(lv, secrets_path(scope))
      assert render(lv) =~ "bot-app is added to GITHUB_APP_PRIVATE_KEY."

      assert reveal(scope, secret, "main-app") == {:ok, @value}
      assert reveal(scope, secret, "bot-app") == {:ok, "second"}

      assert has_element?(lv, "#secret-#{secret.public_id}", "2 values")
      assert has_element?(lv, "#secret-#{secret.public_id}-main-app-value-id", "main-app")
      assert has_element?(lv, "#secret-#{secret.public_id}-bot-app-value-id", "bot-app")

      local = scope.user.email |> String.split("@") |> hd()
      assert has_element?(lv, "#secret-#{secret.public_id}-bot-app", local)
    end

    test "changes the one value, and a named one, never showing either",
         %{conn: conn, scope: scope} do
      one = secret!(scope, %{name: "FORGE_TOKEN"})
      several = secret!(scope, %{name: "GITHUB_APP_PRIVATE_KEY", value_id: "main-app"})

      {:ok, lv, _html} = live(conn, secrets_path(scope))
      lv |> element("#secret-#{one.public_id}-change") |> render_click()
      assert_patch(lv, secrets_path(scope, "/#{one.public_id}/change-value"))
      refute has_element?(lv, "#secret-dialog")
      assert has_element?(lv, "#secret-page-title", "Change the value of FORGE_TOKEN")
      assert render(lv) =~ "The value it holds now is not shown."
      refute render(lv) =~ "Runs are given"
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "Change value")
      refute lv |> element("#secret-form") |> render() =~ "phx-change"

      html =
        lv
        |> form("#secret-form", secret_value: %{value: "changed-#{@value}"})
        |> render_submit()

      refute_value(html)
      assert render(lv) =~ "The value of FORGE_TOKEN is changed."
      assert reveal(scope, one) == {:ok, "changed-#{@value}"}

      lv |> element("#secret-#{several.public_id}-main-app-change") |> render_click()
      assert_patch(lv, secrets_path(scope, "/#{several.public_id}/values/main-app/change"))

      assert has_element?(
               lv,
               "#secret-page-title",
               "Change main-app of GITHUB_APP_PRIVATE_KEY"
             )

      html = lv |> form("#secret-form", secret_value: %{value: ""}) |> render_submit()
      assert has_element?(lv, "#secret_value_value-error")
      refute_value(html)

      lv |> form("#secret-form", secret_value: %{value: "next"}) |> render_submit()
      assert render(lv) =~ "main-app of GITHUB_APP_PRIVATE_KEY is changed."
      assert reveal(scope, several, "main-app") == {:ok, "next"}
    end

    test "edits a secret's name and note, its value kept", %{conn: conn, scope: scope} do
      secret = secret!(scope, %{name: "FORGE_TOKEN", note: "Opens pull requests"})
      secret!(scope, %{name: "NPM_TOKEN"})
      {:ok, lv, _html} = live(conn, secrets_path(scope))

      lv |> element("#secret-#{secret.public_id}-edit") |> render_click()
      assert_patch(lv, secrets_path(scope, "/#{secret.public_id}/edit"))

      # A page of its own, not a dialog over the list.
      refute has_element?(lv, "#secrets")
      assert has_element?(lv, "#settings-tab-secrets[aria-current=true]")
      assert has_element?(lv, "#secret-page-title", "Edit the name and note of FORGE_TOKEN")

      assert lv |> element("#breadcrumb [aria-current=page]") |> render() =~
               ~r{>\s*Edit name and note\s*<}

      assert has_element?(lv, "#secret-page #not-on-runs", "Runs don't receive secrets yet.")
      assert page_title(lv) =~ "Edit the name and note of FORGE_TOKEN · Workspace settings"
      assert has_element?(lv, "#secret-save button[type=submit]", "Save")
      refute has_element?(lv, "#secret-save button[type=submit]", "Save secret")
      refute has_element?(lv, "#secret-form textarea")

      assert lv |> element("#secret-form input[name='secret[name]']") |> render() =~
               ~s(value="FORGE_TOKEN")

      assert lv |> element("#secret-form input[name='secret[note]']") |> render() =~
               ~s(value="Opens pull requests")

      # A name another secret has is refused, whatever its case.
      html =
        lv
        |> form("#secret-form", secret: %{name: "npm_token", note: ""})
        |> render_submit()

      assert html =~ "is already the name of a secret in this workspace"

      lv
      |> form("#secret-form", secret: %{name: "GITLAB_TOKEN", note: "Opens merge requests"})
      |> render_submit()

      assert_patch(lv, secrets_path(scope))
      assert render(lv) =~ "GITLAB_TOKEN is saved."
      assert has_element?(lv, "#secret-#{secret.public_id}", "GITLAB_TOKEN")
      assert has_element?(lv, "#secret-#{secret.public_id}", "Opens merge requests")
      assert reveal(scope, secret) == {:ok, @value}
      refute_value(render(lv))
    end

    test "renames a value", %{conn: conn, scope: scope} do
      secret = secret!(scope, %{name: "GITHUB_APP_PRIVATE_KEY", value_id: "main-app"})

      {:ok, lv, _html} =
        live(conn, secrets_path(scope, "/#{secret.public_id}/values/main-app/rename"))

      refute has_element?(lv, "#secret-dialog")

      assert has_element?(
               lv,
               "#secret-page-title",
               "Rename main-app of GITHUB_APP_PRIVATE_KEY"
             )

      assert has_element?(lv, "#breadcrumb [aria-current=page]", "Rename value")

      assert lv |> element("#secret-form input[name='secret_value[value_id]']") |> render() =~
               ~s(value="main-app")

      html =
        lv |> form("#secret-form", secret_value: %{value_id: "Not A Slug"}) |> render_submit()

      assert html =~ "must be lowercase letters"

      lv |> form("#secret-form", secret_value: %{value_id: "web-app"}) |> render_submit()
      assert render(lv) =~ "main-app of GITHUB_APP_PRIVATE_KEY is now web-app."
      assert reveal(scope, secret, "web-app") == {:ok, @value}
      refute_value(render(lv))
    end

    test "deletes a value of several; a secret's one value goes only with it",
         %{conn: conn, scope: scope} do
      secret = secret!(scope, %{name: "GITHUB_APP_PRIVATE_KEY", value_id: "main-app"})
      {:ok, _} = Secrets.add_value(scope, secret, %{value_id: "bot-app", value: "x"})
      one = secret!(scope, %{name: "FORGE_TOKEN"})

      {:ok, lv, _html} = live(conn, secrets_path(scope))
      lv |> element("#secret-#{secret.public_id}-bot-app-delete") |> render_click()
      assert_patch(lv, secrets_path(scope, "/#{secret.public_id}/values/bot-app/delete"))

      # The value's row asks in place, nothing over the list.
      refute has_element?(lv, "#secret-dialog")
      assert has_element?(lv, "#secret-#{secret.public_id}-bot-app.q-confirming")
      assert has_element?(lv, "#secrets")

      assert has_element?(
               lv,
               "#secret-#{secret.public_id}-bot-app-confirm",
               "Delete bot-app of GITHUB_APP_PRIVATE_KEY?"
             )

      lv
      |> element("#secret-#{secret.public_id}-bot-app-confirm button", "Yes, delete")
      |> render_click()

      assert render(lv) =~ "bot-app is deleted from GITHUB_APP_PRIVATE_KEY."
      assert reveal(scope, secret, "bot-app") == {:error, :not_found}

      # The one value left has no Delete in its menu, and its path says why.
      refute has_element?(lv, "#secret-#{secret.public_id}-main-app-delete")

      assert refused_at(conn, secrets_path(scope, "/#{secret.public_id}/values/main-app/delete")) =~
               "GITHUB_APP_PRIVATE_KEY has one value, which goes only with the secret"

      assert reveal(scope, one) == {:ok, @value}
    end

    test "deletes a secret", %{conn: conn, scope: scope} do
      secret = secret!(scope, %{name: "FORGE_TOKEN"})
      {:ok, lv, _html} = live(conn, secrets_path(scope))

      lv |> element("#secret-#{secret.public_id}-delete") |> render_click()
      assert_patch(lv, secrets_path(scope, "/#{secret.public_id}/delete"))
      # The secret's row asks in place, nothing over the list.
      refute has_element?(lv, "#secret-dialog")
      assert has_element?(lv, "#secret-#{secret.public_id}.q-confirming")
      assert has_element?(lv, "#secret-#{secret.public_id}-confirm", "Delete FORGE_TOKEN?")
      assert render(lv) =~ "The secret and its value are deleted. This cannot be undone."

      # Cancel leaves it as it was.
      lv |> element("#secret-#{secret.public_id}-confirm-cancel") |> render_click()
      assert_patch(lv, secrets_path(scope))
      refute has_element?(lv, "#secret-#{secret.public_id}.q-confirming")

      lv |> element("#secret-#{secret.public_id}-delete") |> render_click()

      lv
      |> element("#secret-#{secret.public_id}-confirm button", "Yes, delete")
      |> render_click()

      assert render(lv) =~ "FORGE_TOKEN is deleted."
      assert secrets(scope) == []
      assert has_element?(lv, "#secrets-empty")
    end

    test "a dialog of a secret that is gone says so", %{conn: conn, scope: scope} do
      assert refused_at(conn, secrets_path(scope, "/sec_0000000000000000/delete")) ==
               "That secret is no longer in this workspace."
    end

    test "finds, filters and orders the secrets in the URL", %{conn: conn, scope: scope} do
      secret!(scope, %{name: "FORGE_TOKEN"})
      several = secret!(scope, %{name: "GITHUB_APP_PRIVATE_KEY", value_id: "main-app"})
      {:ok, _} = Secrets.add_value(scope, several, %{value_id: "bot-app", value: "x"})
      secret!(scope, %{name: "NPM_TOKEN"})

      {:ok, lv, _html} = live(conn, secrets_path(scope))
      lv |> form("#secrets-search", q: "bot") |> render_change()
      assert_patch(lv, secrets_path(scope, "?q=bot"))
      assert has_element?(lv, "#secret-#{several.public_id}")
      assert render(lv) =~ "1 secret matches"
      refute render(lv) =~ "FORGE_TOKEN"

      {:ok, lv, _html} = live(conn, secrets_path(scope, "?values=one&sort=changed"))
      refute has_element?(lv, "#secret-#{several.public_id}")
      assert has_element?(lv, "#secrets-token-values", "One value")
      assert has_element?(lv, "#secrets-sort-button", "Recently changed")
      assert render(lv) =~ ~r/NPM_TOKEN.*FORGE_TOKEN/s

      {:ok, lv, _html} = live(conn, secrets_path(scope, "?q=nothing-like-it"))
      assert render(lv) =~ "No secret matches"
    end
  end

  describe "secrets, as an admin and as a member" do
    test "an admin changes them", %{scope: scope} do
      secret = secret!(scope, %{name: "FORGE_TOKEN"})
      {:ok, lv, _html} = live(member_conn(scope, :admin), secrets_path(scope))

      assert has_element?(lv, "#new-secret")
      lv |> element("#secret-#{secret.public_id}-change") |> render_click()
      lv |> form("#secret-form", secret_value: %{value: "by-the-admin"}) |> render_submit()
      assert reveal(scope, secret) == {:ok, "by-the-admin"}
    end

    test "a member reads the names and value ids, and changes nothing", %{scope: scope} do
      secret = secret!(scope, %{name: "GITHUB_APP_PRIVATE_KEY", value_id: "main-app"})
      conn = member_conn(scope, :member)

      {:ok, lv, html} = live(conn, secrets_path(scope))
      refute_value(html)
      assert has_element?(lv, "#secrets-read-only", "Only owners and admins change this.")
      assert has_element?(lv, "#secret-#{secret.public_id}-main-app-value-id", "main-app")
      refute has_element?(lv, "#new-secret")
      refute has_element?(lv, "#secret-#{secret.public_id}-menu")

      # A page's or a dialog's path refuses them, and so does its event.
      assert refused_at(conn, secrets_path(scope, "/new")) ==
               "Only owners and admins change this."

      for path <- [
            "/#{secret.public_id}/delete",
            "/#{secret.public_id}/edit",
            "/#{secret.public_id}/add-value",
            "/#{secret.public_id}/values/main-app/change",
            "/#{secret.public_id}/values/main-app/rename"
          ] do
        assert refused_at(conn, secrets_path(scope, path)) ==
                 "Only owners and admins change this."
      end

      html =
        render_hook(lv, "create_secret", %{"secret" => %{"name" => "SNEAKY", "value" => @value}})

      refute_value(html)
      assert html =~ "Only owners and admins change this."
      assert [_one] = secrets(scope)

      render_hook(lv, "delete_secret", %{})
      assert [_one] = secrets(scope)

      html = render_hook(lv, "update_secret", %{"secret" => %{"name" => "SNEAKY"}})
      assert html =~ "Only owners and admins change this."
      assert [%{name: "GITHUB_APP_PRIVATE_KEY"}] = secrets(scope)
    end

    test "another organisation's owner reaches no secret of this one", %{scope: scope} do
      secret = secret!(scope, %{name: "FORGE_TOKEN"})
      other = sign_up_fixture()
      conn = log_in_user(build_conn(), other.user)

      for path <- ["/#{secret.public_id}/delete", "/#{secret.public_id}/edit"] do
        assert refused_at(conn, secrets_path(other.scope, path)) ==
                 "That secret is no longer in this workspace."
      end

      {:ok, lv, _html} = live(conn, secrets_path(other.scope))
      render_hook(lv, "delete_secret", %{})
      render_hook(lv, "update_secret", %{"secret" => %{"name" => "SNEAKY"}})
      assert [%{name: "FORGE_TOKEN"}] = secrets(scope)

      {:ok, lv, _html} = live(conn, secrets_path(other.scope))
      refute render(lv) =~ "FORGE_TOKEN"
      assert [_one] = secrets(scope)
    end
  end

  describe "variables, as an owner" do
    test "a new variable is saved with its lock, and shows its value",
         %{conn: conn, scope: scope} do
      {:ok, lv, html} = live(conn, variables_path(scope))
      assert has_element?(lv, "#variables-empty")
      assert has_element?(lv, "#secrets-tabs-variables[aria-current=page]")
      assert has_element?(lv, "#settings-tab-secrets[aria-current=true]")

      # No run receives a variable yet, which the view says once, and nothing says
      # otherwise.
      assert has_element?(
               lv,
               "#not-on-runs",
               "Runs don't receive variables yet. Today a run receives only its security policy."
             )

      refute html =~ "runs are given"
      refute html =~ "Runs are given"
      refute html =~ "receives these"

      lv |> element("#new-variable") |> render_click()
      assert_patch(lv, variables_path(scope, "/new"))
      refute has_element?(lv, "#variable-dialog")
      assert has_element?(lv, "#variable-page-title", "New variable")
      assert has_element?(lv, "#breadcrumb a", "Secrets and variables")
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "New variable")
      assert has_element?(lv, "#variable-save-cancel[href='#{variables_path(scope)}']")

      # The name's hint describes its field; the deny-list warning would too, while it
      # shows.
      assert has_element?(lv, "#variable_name[aria-describedby=variable_name-hint]")
      assert has_element?(lv, "#variable_name-hint", "Letters, digits and _")
      refute has_element?(lv, "#variable-warning")

      lv
      |> form("#variable-form",
        variable: %{name: "NPM_REGISTRY", value: "https://registry.example.com", locked: "true"}
      )
      |> render_submit()

      assert_patch(lv, variables_path(scope))
      assert render(lv) =~ "NPM_REGISTRY is saved."

      {:ok, [variable]} = Variables.list_variables(scope, :workspace)
      assert variable.locked
      assert has_element?(lv, "#variable-#{variable.id}-value", "https://registry.example.com")
      assert has_element?(lv, "#variable-#{variable.id}-lock", "Locked")
      assert has_element?(lv, "#variable-#{variable.id}-targets", "None of their own")
    end

    test "a QORY_ name is refused, and a name already set too", %{conn: conn, scope: scope} do
      variable!(scope, :workspace, "NPM_REGISTRY", "https://registry.example.com")
      {:ok, lv, _html} = live(conn, variables_path(scope, "/new"))

      html =
        lv
        |> form("#variable-form", variable: %{name: "qory_token", value: "x"})
        |> render_submit()

      assert html =~ "names beginning QORY_ are the runner&#39;s own"

      # The error describes the field in place of its hint, and the hint goes.
      assert has_element?(lv, "#variable_name[aria-describedby=variable_name-error]")
      refute has_element?(lv, "#variable_name[aria-describedby~=variable_name-hint]")
      refute has_element?(lv, "#variable_name-hint")

      html =
        lv
        |> form("#variable-form", variable: %{name: "NPM_REGISTRY", value: "x"})
        |> render_submit()

      assert html =~ "is already set here, compared without case"

      html =
        lv
        |> form("#variable-form", variable: %{name: "npm_registry", value: "x"})
        |> render_submit()

      assert html =~ "is NPM_REGISTRY elsewhere in this workspace: use the same spelling"
      assert {:ok, [_one]} = Variables.list_variables(scope, :workspace)
    end

    test "a new variable over a repository's limit of names is refused in its own words",
         %{conn: conn, scope: scope} do
      site = target!(scope, "acme/site")
      for i <- 1..120, do: variable!(scope, :workspace, "W#{i}", "")
      for i <- 1..8, do: variable!(scope, site, "T#{i}", "")
      {:ok, lv, _html} = live(conn, variables_path(scope, "/new"))

      lv
      |> form("#variable-form", variable: %{name: "W121", value: "x"})
      |> render_submit()

      # The context's refusal, as a software workspace reads it, under the name.
      assert has_element?(
               lv,
               "#variable_name-error",
               "would raise a repository's variables above 128"
             )

      refute render(lv) =~ "a target&#39;s variables"
      assert {:ok, variables} = Variables.list_variables(scope, :workspace)
      assert length(variables) == 120
    end

    test "changes a value, locks and unlocks, saying what the lock does to the repositories",
         %{conn: conn, scope: scope} do
      site = target!(scope, "acme/site")
      shop = target!(scope, "acme/shop")
      variable = variable!(scope, :workspace, "NODE_ENV", "production")
      variable!(scope, site, "NODE_ENV", "test")
      variable!(scope, shop, "NODE_ENV", "staging")

      {:ok, lv, _html} = live(conn, variables_path(scope))
      assert has_element?(lv, "#variable-#{variable.id}-targets", "2 repositories set their own")

      lv |> element("#variable-#{variable.id}-change") |> render_click()
      assert_patch(lv, variables_path(scope, "/#{variable.id}/change"))
      refute has_element?(lv, "#variable-dialog")
      assert has_element?(lv, "#variable-page-title", "Change the value of NODE_ENV")
      assert has_element?(lv, "#variable-page #not-on-runs", "Runs don't receive variables yet.")
      refute render(lv) =~ "Runs are given"
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "Change value")
      lv |> form("#variable-form", variable: %{value: "prod"}) |> render_submit()
      assert render(lv) =~ "NODE_ENV is changed."
      assert has_element?(lv, "#variable-#{variable.id}-value", "prod")

      # Lock acts at once from the menu, and says what it did to the targets.
      lv |> element("#variable-#{variable.id}-lock-item") |> render_click()

      assert render(lv) =~
               "NODE_ENV is locked: 2 repositories that set their own are set aside by the lock."

      refute render(lv) =~ "are given"

      assert has_element?(lv, "#variable-#{variable.id}-lock", "Locked")

      assert has_element?(
               lv,
               "#variable-#{variable.id}-targets",
               "2 repositories set aside by the lock"
             )

      # Locked already: its lock path has nothing to confirm.
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, variables_path(scope, "/#{variable.id}/lock"))

      assert to == variables_path(scope)

      # Its unlock path, which must not act as it opens, asks on the row.
      {:ok, lv, _html} = live(conn, variables_path(scope, "/#{variable.id}/unlock"))
      assert Repo.reload!(variable).locked
      refute has_element?(lv, "#variable-dialog")
      assert has_element?(lv, "#variable-#{variable.id}.q-confirming")
      assert has_element?(lv, "#unlock-targets", "2 repositories set their own")
      lv |> element("#variable-#{variable.id}-confirm button", "Unlock") |> render_click()

      assert render(lv) =~
               "NODE_ENV is unlocked: 2 repositories that set their own are no longer set aside."

      refute render(lv) =~ "are given"

      refute Repo.reload!(variable).locked

      # Its lock path asks the same way.
      {:ok, lv, _html} = live(conn, variables_path(scope, "/#{variable.id}/lock"))
      refute Repo.reload!(variable).locked

      assert has_element?(
               lv,
               "#lock-targets",
               "2 repositories set their own now: the lock sets them aside while it holds."
             )

      lv |> element("#variable-#{variable.id}-confirm button", "Lock") |> render_click()
      assert Repo.reload!(variable).locked

      # Another row's Lock, while this row asks, locks that row's variable alone.
      other = variable!(scope, :workspace, "LOG_LEVEL", "info")
      {:ok, lv, _html} = live(conn, variables_path(scope, "/#{variable.id}/unlock"))
      lv |> element("#variable-#{other.id}-lock-item") |> render_click()
      assert Repo.reload!(other).locked
      assert Repo.reload!(variable).locked

      # Unlock acts at once from the menu too.
      lv |> element("#variable-#{variable.id}-unlock-item") |> render_click()
      assert render(lv) =~ "NODE_ENV is unlocked"
      refute Repo.reload!(variable).locked
    end

    test "lists the repositories of a variable, found by their path",
         %{conn: conn, scope: scope} do
      variable = variable!(scope, :workspace, "NODE_ENV", "production")

      targets =
        for n <- 1..12 do
          target = target!(scope, "acme/site-#{String.pad_leading("#{n}", 2, "0")}")
          variable!(scope, target, "NODE_ENV", "test")
          target
        end

      {:ok, lv, _html} = live(conn, variables_path(scope))
      lv |> element("#variable-#{variable.id}-targets") |> render_click()
      assert_patch(lv, variables_path(scope, "/#{variable.id}/targets"))

      # A page of the section, to read, with its way back.
      refute has_element?(lv, "#variable-dialog")
      refute has_element?(lv, "#variables")
      assert has_element?(lv, "#variable-page-title", "Repositories that set NODE_ENV")
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "Repositories")
      assert has_element?(lv, "#variable-targets-foot a[href='#{variables_path(scope)}']")

      for target <- targets, do: assert(has_element?(lv, "#variable-target-#{target.id}"))
      assert has_element?(lv, "#variable-targets", "Its own value")

      # The table's region is named apart from the page's.
      assert has_element?(lv, "[role=region][aria-label=Repositories] #variable-targets")

      lv |> form("#variable-targets-search", q: "site-07") |> render_change()
      assert has_element?(lv, "#variable-target-#{Enum.at(targets, 6).id}")
      refute has_element?(lv, "#variable-target-#{Enum.at(targets, 0).id}")
    end

    test "a repository of a variable links to its page at its address",
         %{conn: conn, scope: scope} do
      variable = variable!(scope, :workspace, "NODE_ENV", "production")
      shop = target!(scope, "acme/shop")
      billing = target!(scope, "acme/billing")

      other =
        Repo.insert!(%Apiary.Runs.Target{
          organisation_id: scope.organisation.id,
          workspace_id: scope.workspace.id,
          system: "gitlab.example",
          path: "acme/shop",
          first_seen_at: DateTime.utc_now()
        })

      for target <- [shop, billing, other], do: variable!(scope, target, "NODE_ENV", "test")

      {:ok, lv, _html} = live(conn, variables_path(scope, "/#{variable.id}/targets"))

      # Its system is in the address only where its path is shared.
      for {target, path} <- [
            {shop, "/targets/github.example/acme/shop"},
            {other, "/targets/gitlab.example/acme/shop"},
            {billing, "/targets/acme/billing"}
          ] do
        assert has_element?(
                 lv,
                 "#variable-target-#{target.id} a[href='#{workspace_path(scope, path)}']"
               )
      end
    end

    test "deletes a variable", %{conn: conn, scope: scope} do
      variable = variable!(scope, :workspace, "NODE_ENV", "production")
      {:ok, lv, _html} = live(conn, variables_path(scope))

      lv |> element("#variable-#{variable.id}-delete") |> render_click()
      assert_patch(lv, variables_path(scope, "/#{variable.id}/delete"))
      refute has_element?(lv, "#variable-dialog")
      assert has_element?(lv, "#variable-#{variable.id}-confirm", "Delete NODE_ENV?")

      lv
      |> element("#variable-#{variable.id}-confirm button", "Yes, delete")
      |> render_click()

      assert render(lv) =~ "NODE_ENV is deleted."
      assert {:ok, []} = Variables.list_variables(scope, :workspace)
    end

    test "refuses to delete a locked variable as it refuses to unlock it, the confirmation open",
         %{conn: conn, scope: scope} do
      site = target!(scope, "acme/site")
      for i <- 10..24, do: variable!(scope, :workspace, "V_#{i}", String.duplicate("v", 4096))
      variable = variable!(scope, :workspace, "LOCKED", "l")
      variable!(scope, site, "LOCKED", String.duplicate("s", 4000))
      {:ok, variable} = Variables.lock_variable(scope, variable)
      # The repository is full while its own LOCKED is set aside, which either act gives back.
      variable!(scope, site, "OWN", String.duplicate("o", 4026))
      # The context's refusal, as a software workspace reads it.
      reason = "would raise a repository's variables above 64 KiB"

      # Unlock from the row's menu, with no confirmation open: the flash says why.
      {:ok, lv, _html} = live(conn, variables_path(scope))
      lv |> element("#variable-#{variable.id}-unlock-item") |> render_click()
      assert has_element?(lv, "#flash-error", "Not unlocked: #{reason}")
      assert Repo.reload!(variable).locked

      # Its unlock path asks on the row: refused, the confirmation stays open, and says why
      # under its question, with no flash.
      {:ok, lv, _html} = live(conn, variables_path(scope, "/#{variable.id}/unlock"))
      lv |> element("#variable-#{variable.id}-confirm button", "Unlock") |> render_click()

      assert has_element?(
               lv,
               "#variable-#{variable.id}-confirm #variable-refused[role=alert]",
               "Not unlocked: #{reason}"
             )

      assert has_element?(lv, "#variable-#{variable.id}-confirm button", "Unlock")
      refute has_element?(lv, "#flash-error")
      assert Repo.reload!(variable).locked

      # The deletion too.
      {:ok, lv, _html} = live(conn, variables_path(scope, "/#{variable.id}/delete"))
      assert has_element?(lv, "#variable-#{variable.id}-confirm", "Delete LOCKED?")
      refute has_element?(lv, "#variable-refused")

      lv
      |> element("#variable-#{variable.id}-confirm button", "Yes, delete")
      |> render_click()

      assert has_element?(
               lv,
               "#variable-#{variable.id}-confirm #variable-refused[role=alert]",
               "Not deleted: #{reason}"
             )

      assert has_element?(lv, "#variable-#{variable.id}-confirm button", "Yes, delete")
      refute has_element?(lv, "#flash-error")
      refute render(lv) =~ "Not saved"
      assert Repo.reload!(variable).locked

      # Cancel closes it, and the reason goes with it.
      lv |> element("#variable-#{variable.id}-confirm-cancel") |> render_click()
      assert_patch(lv, variables_path(scope))
      refute has_element?(lv, "#variable-refused")
      assert has_element?(lv, "#variable-#{variable.id}-lock", "Locked")
    end

    test "finds and filters the variables in the URL", %{conn: conn, scope: scope} do
      site = target!(scope, "acme/site")
      locked = variable!(scope, :workspace, "LOG_LEVEL", "info", %{locked: true})
      own = variable!(scope, :workspace, "NODE_ENV", "production")
      plain = variable!(scope, :workspace, "NPM_REGISTRY", "https://registry.example.com")
      variable!(scope, site, "NODE_ENV", "test")

      {:ok, lv, _html} = live(conn, variables_path(scope, "?lock=yes"))
      assert has_element?(lv, "#variable-#{locked.id}")
      refute has_element?(lv, "#variable-#{own.id}")
      assert has_element?(lv, "#variables-token-lock", "Locked")

      {:ok, lv, _html} = live(conn, variables_path(scope, "?targets=own"))
      assert has_element?(lv, "#variable-#{own.id}")
      refute has_element?(lv, "#variable-#{plain.id}")

      {:ok, lv, _html} = live(conn, variables_path(scope))
      lv |> form("#variables-search", q: "example.com") |> render_change()
      assert_patch(lv, variables_path(scope, "?q=example.com"))
      assert has_element?(lv, "#variable-#{plain.id}")
      refute has_element?(lv, "#variable-#{locked.id}")
    end
  end

  describe "variables, as an admin and as a member" do
    test "an admin changes them", %{scope: scope} do
      variable = variable!(scope, :workspace, "NODE_ENV", "production")

      {:ok, lv, _html} =
        live(member_conn(scope, :admin), variables_path(scope, "/#{variable.id}/lock"))

      lv |> element("#variable-#{variable.id}-confirm button", "Lock") |> render_click()
      assert Repo.reload!(variable).locked

      lv |> element("#variable-#{variable.id}-unlock-item") |> render_click()
      refute Repo.reload!(variable).locked
    end

    test "a member reads them and changes nothing", %{scope: scope} do
      site = target!(scope, "acme/site")
      variable = variable!(scope, :workspace, "NODE_ENV", "production")
      variable!(scope, site, "NODE_ENV", "test")
      conn = member_conn(scope, :member)

      {:ok, lv, _html} = live(conn, variables_path(scope))
      assert has_element?(lv, "#secrets-read-only", "Only owners and admins change this.")
      assert has_element?(lv, "#variable-#{variable.id}-value", "production")
      refute has_element?(lv, "#new-variable")
      refute has_element?(lv, "#variable-#{variable.id}-menu")

      # The repositories are theirs to read.
      lv |> element("#variable-#{variable.id}-targets") |> render_click()
      assert has_element?(lv, "#variable-target-#{site.id}")

      for path <- [
            "/new",
            "/#{variable.id}/change",
            "/#{variable.id}/lock",
            "/#{variable.id}/delete"
          ] do
        assert refused_at(conn, variables_path(scope, path)) ==
                 "Only owners and admins change this."
      end

      {:ok, lv, _html} = live(conn, variables_path(scope))

      html =
        render_hook(lv, "create_variable", %{"variable" => %{"name" => "SNEAKY", "value" => "x"}})

      assert html =~ "Only owners and admins change this."
      render_hook(lv, "lock_variable", %{})
      refute Repo.reload!(variable).locked

      html = render_hook(lv, "lock_variable", %{"id" => variable.id})
      assert html =~ "Only owners and admins change this."
      refute Repo.reload!(variable).locked
      assert {:ok, [_one]} = Variables.list_variables(scope, :workspace)
    end

    test "another organisation's owner reaches no variable of this one", %{scope: scope} do
      variable = variable!(scope, :workspace, "NODE_ENV", "production")
      other = sign_up_fixture()
      conn = log_in_user(build_conn(), other.user)

      for act <- ~w(delete lock targets) do
        assert refused_at(conn, variables_path(other.scope, "/#{variable.id}/#{act}")) ==
                 "That variable is no longer in this workspace."
      end

      {:ok, lv, _html} = live(conn, variables_path(other.scope))
      render_hook(lv, "delete_variable", %{})
      assert Repo.reload!(variable)
    end

    test "a repository's own variable is not this page's", %{conn: conn, scope: scope} do
      site = target!(scope, "acme/site")
      own = variable!(scope, site, "NODE_ENV", "test")

      assert refused_at(conn, variables_path(scope, "/#{own.id}/delete")) ==
               "That variable is no longer in this workspace."
    end
  end
end
