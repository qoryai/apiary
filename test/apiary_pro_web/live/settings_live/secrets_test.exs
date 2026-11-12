defmodule ApiaryProWeb.SettingsLive.SecretsTest do
  @moduledoc """
  The organisation's secrets, the Secrets tab of its settings' Secrets and variables
  entry, and in the palette; the list, by name, note and value ID, never a value, its
  lines on the two levels and on runs; New secret, a page of the section, and Delete,
  confirmed on the row; the messages after a change; the audit log's entries; who reads
  and who changes them, a member at any reach not shown them; and the page where the
  feature is not on.
  """
  # Not async: the features are the node's, and an instance admin is an owner of the
  # suite's one instance organisation.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Features, Repo, Secrets}
  alias Apiary.Secrets.Secret
  alias ApiaryPro.Suspensions

  @moduletag with_features: Features.all()
  # The organisation's secrets need `secrets`: they run only where both are on.
  @moduletag needs: :organisation_variables

  @section "Secrets and variables"
  @not_in_runs "A run receives only its security policy."
  @levels "A workspace's secret with the same name is a different secret: neither one replaces the other."
  @sentence "A secret holds one value, such as a token, or several under one name, such as one per app. Once a value is saved, nobody sees it again."

  setup :register_and_log_in_user

  defp list_path(scope), do: ~p"/#{scope.organisation}/settings/secrets"

  defp create!(scope, name, value \\ "token-value") do
    {:ok, secret} = Secrets.create_organisation_secret(scope, %{"name" => name, "value" => value})
    secret
  end

  # The browser's title, without the suffix the root layout adds as the page loads.
  defp title(view), do: String.replace_suffix(page_title(view), " · Qory Apiary", "")

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&#39;", "'")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp jump_labels(conn, scope, q) do
    conn
    |> put_req_header("accept", "application/json")
    |> get(~p"/#{scope.organisation}/#{scope.workspace}/jump", %{"q" => q})
    |> json_response(200)
    |> Map.fetch!("groups")
    |> Enum.find(%{"items" => []}, &(&1["label"] == "Go to"))
    |> Map.fetch!("items")
    |> Enum.map(& &1["label"])
  end

  describe "the list" do
    test "the Secrets tab, by name, note and value ID, never a value",
         ctx do
      forge = create!(ctx.scope, "FORGE_TOKEN", "forge-value-not-shown")
      {:ok, forge} = Secrets.update_secret(ctx.scope, forge, %{"note" => "Opens tickets"})

      {:ok, registry} =
        Secrets.create_organisation_secret(ctx.scope, %{
          "name" => "REGISTRY_KEY",
          "values" => %{
            "0" => %{"value_id" => "main-app", "value" => "main-value-not-shown"},
            "1" => %{"value_id" => "bot-app", "value" => "bot-value-not-shown"}
          }
        })

      {:ok, lv, html} = live(ctx.conn, list_path(ctx.scope))

      assert has_element?(lv, "#settings-tabs #settings-tab-secrets[aria-current='page']")
      assert has_element?(lv, "#breadcrumb-settings", "Organisation settings")
      assert text(lv, "#breadcrumb-section[aria-current=page]") == @section
      assert text(lv, "h1#settings-section-title") == @section

      assert title(lv) ==
               "Secrets and variables · Organisation settings · #{ctx.scope.organisation.name}"

      assert text(lv, ".q-settings-head-sub") ==
               "Secrets and variables that belong to #{ctx.scope.organisation.name}, not to one workspace. A secret is never shown again once it is saved; a variable is plain text."

      # The lines of the tab, under the tabs.
      assert text(lv, "#secrets-tabs-panel #secrets-levels") == @levels
      assert text(lv, "#secrets-tabs-panel #secrets-not-in-runs") == @not_in_runs
      refute has_element?(lv, "#secrets-read-only")

      assert has_element?(lv, ".q-bar a#new-secret.btn-primary", "New secret")
      assert has_element?(lv, ".q-bar #secrets-search")
      assert has_element?(lv, ".q-bar #secrets-filter")
      assert has_element?(lv, ".q-bar #secrets-sort")

      assert has_element?(lv, "#secret-#{forge.public_id}", "FORGE_TOKEN")
      # The name, cut beside its note where the table is narrow, is whole in its title.
      assert has_element?(lv, "#secret-#{forge.public_id} .q-nm > .q-title[title=FORGE_TOKEN]")
      assert has_element?(lv, "#secret-#{forge.public_id}", "Opens tickets")
      assert has_element?(lv, "#secret-#{forge.public_id}", "One value")
      assert has_element?(lv, "#secret-#{forge.public_id}-used-by", "Not used")
      refute has_element?(lv, "#secret-#{forge.public_id}-used-by[title]")

      assert has_element?(lv, "#secret-#{registry.public_id}", "2 values")
      assert has_element?(lv, "#secret-#{registry.public_id}-main-app-value-id", "main-app")
      assert has_element?(lv, "#secret-#{registry.public_id}-bot-app-value-id", "bot-app")

      # Never a value, on the page or anywhere in its HTML.
      for value <- ~w(forge-value-not-shown main-value-not-shown bot-value-not-shown) do
        refute html =~ value
        refute render(lv) =~ value
      end
    end

    test "Used by is one line, cut to the cell, with every name whole in its title", ctx do
      forge = create!(ctx.scope, "FORGE_TOKEN")
      previous = Application.get_env(:apiary, Secrets.Usage)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:apiary, Secrets.Usage, previous),
          else: Application.delete_env(:apiary, Secrets.Usage)
      end)

      names = ["Deploy pipeline", "Ticket triage", "Nightly checks", "Deploy pipeline", "Docs"]

      Application.put_env(:apiary, Secrets.Usage,
        answer: fn _repo, secret ->
          if secret.id == forge.id,
            do:
              for(name <- names, do: %{kind: :integration, id: name, name: name, value_id: nil}),
            else: []
        end
      )

      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope))
      used_by = "Deploy pipeline, Ticket triage, Nightly checks, Docs"

      assert has_element?(lv, "#secret-#{forge.public_id}-used-by.q-cut[title='#{used_by}']")
      assert text(lv, "#secret-#{forge.public_id}-used-by") == used_by
    end

    test "with none, says what a secret is, and offers New secret", ctx do
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope))

      assert has_element?(lv, "#secrets-empty", "No secrets yet")
      assert text(lv, "#secrets-empty") =~ @sentence
      assert has_element?(lv, "#secrets-empty a[href='#{list_path(ctx.scope)}/new']")
      assert has_element?(lv, ".q-bar a#new-secret")
      refute has_element?(lv, "#secrets-search")
      refute has_element?(lv, "#secrets")
    end

    test "one entry, Secrets and variables, where Secrets and Variables were, one palette entry",
         ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.scope.organisation}/settings")

      tabs =
        lv
        |> render()
        |> then(&Regex.scan(~r/id="settings-tab-([a-z-]+)"/, &1))
        |> Enum.map(fn [_, id] -> id end)

      assert text(lv, "#settings-tab-secrets") == @section
      assert has_element?(lv, "#settings-tab-secrets[href='#{list_path(ctx.scope)}']")
      refute has_element?(lv, "#settings-tab-variables")
      index = Enum.find_index(tabs, &(&1 == "secrets"))
      # In the place of Secrets: after the core's entries, before Ownership.
      assert Enum.at(tabs, index - 1) in ["workspaces", "integrations"]

      for q <- ["secrets", "variables"] do
        labels = jump_labels(ctx.conn, ctx.scope, q)
        assert "Organisation settings › Secrets and variables" in labels, q
        refute "Organisation settings › Secrets" in labels
        refute "Organisation settings › Variables" in labels
      end

      assert Enum.count(
               jump_labels(ctx.conn, ctx.scope, "secrets"),
               &String.starts_with?(&1, "Organisation settings › Secrets")
             ) == 1
    end
  end

  describe "the tabs" do
    test "Secrets, then Variables, each with how many it holds, the open one the page", ctx do
      create!(ctx.scope, "FORGE_TOKEN")
      create!(ctx.scope, "DEPLOY_KEY")

      {:ok, _} =
        ApiaryPro.OrganisationVariables.create(ctx.scope, %{name: "LOG_LEVEL", value: "info"})

      variables = ~p"/#{ctx.scope.organisation}/settings/variables"

      for {path, open, other} <- [
            {list_path(ctx.scope), "secrets", "variables"},
            {variables, "variables", "secrets"}
          ] do
        {:ok, lv, _html} = live(ctx.conn, path)

        assert has_element?(lv, "nav#secrets-tabs[aria-label='#{@section}']")

        assert lv
               |> render()
               |> then(&Regex.scan(~r/id="secrets-tabs-(secrets|variables)"/, &1))
               |> Enum.map(fn [_, key] -> key end) == ["secrets", "variables"]

        assert text(lv, "#secrets-tabs-secrets") == "Secrets 2"
        assert text(lv, "#secrets-tabs-variables") == "Variables 1"
        assert has_element?(lv, "#secrets-tabs-secrets[href='#{list_path(ctx.scope)}']")
        assert has_element?(lv, "#secrets-tabs-variables[href='#{variables}']")
        assert has_element?(lv, "#secrets-tabs-#{open}[aria-current=page]")
        refute has_element?(lv, "#secrets-tabs-#{other}[aria-current]")

        # The section's one entry is the page on both tabs.
        assert has_element?(lv, "#settings-tab-secrets[aria-current=page]")
        assert text(lv, "h1#settings-section-title") == @section
      end
    end

    test "the Variables tab's count follows a change of the variables", ctx do
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope))
      assert text(lv, "#secrets-tabs-variables") == "Variables 0"

      {:ok, _} =
        ApiaryPro.OrganisationVariables.create(ctx.scope, %{name: "LOG_LEVEL", value: "info"})

      assert text(lv, "#secrets-tabs-variables") == "Variables 1"
    end

    test "come from the other tab, the status line says the tab and how many it holds", ctx do
      create!(ctx.scope, "FORGE_TOKEN")
      variables = ~p"/#{ctx.scope.organisation}/settings/variables"
      base = "http://www.example.com"

      {:ok, lv, _html} =
        ctx.conn
        |> put_connect_params(%{"_live_referer" => base <> variables})
        |> live(list_path(ctx.scope))

      assert text(lv, "#secrets-status") == "Secrets, 1"

      {:ok, lv, _html} =
        ctx.conn
        |> put_connect_params(%{"_live_referer" => base <> list_path(ctx.scope)})
        |> live(variables)

      assert text(lv, "#variables-status") == "Variables, 0"

      # Opened any other way, it says nothing.
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope))
      assert text(lv, "#secrets-status") == ""

      {:ok, lv, _html} =
        ctx.conn
        |> put_connect_params(%{"_live_referer" => base <> list_path(ctx.scope) <> "/new"})
        |> live(list_path(ctx.scope))

      assert text(lv, "#secrets-status") == ""
    end

    test "every form page marks the entry as its parent, its breadcrumb leading to the tab",
         ctx do
      secret = create!(ctx.scope, "FORGE_TOKEN")

      {:ok, variable} =
        ApiaryPro.OrganisationVariables.create(ctx.scope, %{name: "LOG_LEVEL", value: "info"})

      variables = ~p"/#{ctx.scope.organisation}/settings/variables"

      for {path, tab} <- [
            {list_path(ctx.scope) <> "/new", list_path(ctx.scope)},
            {list_path(ctx.scope) <> "/#{secret.public_id}/edit", list_path(ctx.scope)},
            {list_path(ctx.scope) <> "/#{secret.public_id}/add-value", list_path(ctx.scope)},
            {list_path(ctx.scope) <> "/#{secret.public_id}/change-value", list_path(ctx.scope)},
            {variables <> "/new", variables},
            {variables <> "/#{variable.id}/change", variables}
          ] do
        {:ok, lv, _html} = live(ctx.conn, path)

        assert has_element?(lv, "#settings-tab-secrets[aria-current=true]"), path
        assert text(lv, "#breadcrumb a#breadcrumb-section[href='#{tab}']") == @section, path
        refute has_element?(lv, "#secrets-tabs"), path
      end
    end
  end

  describe "New secret" do
    test "a page of the section, which saves one and leads back to the list", ctx do
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope) <> "/new")

      assert title(lv) == "New secret · Organisation settings · #{ctx.scope.organisation.name}"
      assert text(lv, "#secret-page") =~ @sentence
      assert text(lv, "#secret-levels") == @levels
      assert text(lv, "#secrets-not-in-runs") == @not_in_runs

      lv
      |> form("#secret-form",
        secret: %{"name" => "FORGE_TOKEN", "values_kind" => "one", "value" => "typed-value"}
      )
      |> render_submit()

      assert_patch(lv, list_path(ctx.scope))
      assert render(lv) =~ "FORGE_TOKEN is saved."
      refute render(lv) =~ "typed-value"

      assert {:ok, [%Secret{name: "FORGE_TOKEN"}]} =
               Secrets.list_organisation_secrets(ctx.scope)
    end

    test "a name another of the organisation's secrets has is refused under its field", ctx do
      create!(ctx.scope, "FORGE_TOKEN")
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope) <> "/new")

      html =
        lv
        |> form("#secret-form",
          secret: %{"name" => "forge_token", "values_kind" => "one", "value" => "typed-value"}
        )
        |> render_submit()

      assert html =~ "is already the name of a secret in this organisation, compared without case"
      refute html =~ "typed-value"
    end

    test "a workspace's secret with the same name is a different secret", ctx do
      {:ok, _} = Secrets.create_secret(ctx.scope, %{name: "FORGE_TOKEN", value: "workspace"})
      secret = create!(ctx.scope, "FORGE_TOKEN", "organisation")

      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope))
      assert has_element?(lv, "#secret-#{secret.public_id}", "FORGE_TOKEN")
    end
  end

  describe "a refused change of a value" do
    # The form's changeset, as the page keeps it in its assigns.
    defp form_changeset(lv) do
      %{socket: socket} = :sys.get_state(lv.pid)
      socket.assigns.form.source
    end

    defp stored(secret) do
      Repo.all(from v in Apiary.Secrets.Value, where: v.secret_id == ^secret.id)
    end

    defp holds_no_ciphertext(lv, secret) do
      changeset = form_changeset(lv)
      assert %Apiary.Secrets.Value{nonce: nil, ciphertext: nil} = changeset.data
      refute Map.has_key?(changeset.changes, :nonce)
      refute Map.has_key?(changeset.changes, :ciphertext)

      state = :erlang.term_to_binary(:sys.get_state(lv.pid))

      for value <- stored(secret), bytes <- [value.nonce, value.ciphertext] do
        assert :binary.match(state, bytes) == :nomatch
      end
    end

    test "keeps no ciphertext in the form, after Change value or Rename value", ctx do
      secret = create!(ctx.scope, "FORGE_TOKEN", "stored-value")

      {:ok, lv, _html} =
        live(ctx.conn, list_path(ctx.scope) <> "/#{secret.public_id}/change-value")

      html = lv |> form("#secret-form", secret_value: %{"value" => ""}) |> render_submit()
      assert html =~ "can&#39;t be blank"
      holds_no_ciphertext(lv, secret)

      {:ok, several} =
        Secrets.create_organisation_secret(ctx.scope, %{
          "name" => "REGISTRY_KEY",
          "values" => %{
            "0" => %{"value_id" => "main-app", "value" => "a"},
            "1" => %{"value_id" => "bot-app", "value" => "b"}
          }
        })

      {:ok, lv, _html} =
        live(ctx.conn, list_path(ctx.scope) <> "/#{several.public_id}/values/main-app/rename")

      html =
        lv |> form("#secret-form", secret_value: %{"value_id" => "bot-app"}) |> render_submit()

      assert html =~ "is already a value ID of this secret"
      holds_no_ciphertext(lv, several)
    end
  end

  describe "Delete" do
    test "asks on the row, then deletes", ctx do
      secret = create!(ctx.scope, "FORGE_TOKEN")
      path = list_path(ctx.scope) <> "/#{secret.public_id}/delete"

      {:ok, lv, _html} = live(ctx.conn, path)

      assert has_element?(lv, "#secret-#{secret.public_id}-confirm", "Delete FORGE_TOKEN?")

      assert has_element?(
               lv,
               "#secret-#{secret.public_id}-confirm",
               "The secret and its value are deleted. This cannot be undone."
             )

      lv |> element("#secret-#{secret.public_id}-confirm button", "Yes, delete") |> render_click()

      assert_patch(lv, list_path(ctx.scope))
      assert render(lv) =~ "FORGE_TOKEN is deleted."
      assert {:ok, []} = Secrets.list_organisation_secrets(ctx.scope)
    end

    test "of one that is gone meanwhile says it is no longer in the organisation", ctx do
      secret = create!(ctx.scope, "FORGE_TOKEN")
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope) <> "/#{secret.public_id}/delete")

      {:ok, _} = Secrets.delete_secret(ctx.scope, secret)

      lv |> element("#secret-#{secret.public_id}-confirm button", "Yes, delete") |> render_click()

      assert render(lv) =~
               "That secret is no longer in #{ctx.scope.organisation.name}."
    end
  end

  describe "the audit log" do
    test "writes each change as the core's stored secret entry, never a value", ctx do
      secret = create!(ctx.scope, "FORGE_TOKEN", "logged-value-not-shown")
      {:ok, _} = Secrets.delete_secret(ctx.scope, secret)

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.scope.organisation}/audit-log")
      html = render_async(lv)

      assert html =~ "Created a stored secret"
      assert html =~ "Deleted a stored secret"
      assert html =~ "FORGE_TOKEN"
      refute html =~ "logged-value-not-shown"
    end
  end

  describe "who" do
    test "a member, at any reach, opens neither tab nor any of their forms, and has no entry",
         ctx do
      secret = create!(ctx.scope, "FORGE_TOKEN")

      {:ok, variable} =
        ApiaryPro.OrganisationVariables.create(ctx.scope, %{name: "LOG_LEVEL", value: "info"})

      %{user: member, membership: membership} = member_fixture(ctx.scope, :member)
      platform = workspace_fixture(ctx.scope.organisation, "Platform")
      conn = log_in_user(build_conn(), member)
      secrets = list_path(ctx.scope)
      variables = ~p"/#{ctx.scope.organisation}/settings/variables"

      paths =
        [secrets, secrets <> "/new"] ++
          for(
            act <- ~w(edit add-value change-value delete),
            do: "#{secrets}/#{secret.public_id}/#{act}"
          ) ++
          [variables, variables <> "/new"] ++
          for(act <- ~w(change lock unlock delete), do: "#{variables}/#{variable.id}/#{act}")

      # Added to Shop only, then to every workspace: the same answer.
      for reach <- [:some, :every] do
        if reach == :every,
          do: {:ok, _} = ApiaryPro.WorkspaceAccess.add(ctx.scope, membership.id, platform.id)

        for path <- paths do
          assert_raise ApiaryWeb.NotFound, fn -> live(conn, path) end
        end

        {:ok, lv, _html} = live(conn, ~p"/#{ctx.scope.organisation}/settings")
        refute has_element?(lv, "#settings-tab-secrets")
        refute has_element?(lv, "#settings-tab-variables")

        for q <- ["secrets", "variables"] do
          refute Enum.any?(
                   jump_labels(conn, ctx.scope, q),
                   &(&1 =~ ~r/^Organisation settings › (Secrets|Variables)/)
                 )
        end
      end
    end

    test "owners, admins and readers have the entry and open both tabs", ctx do
      %{user: admin} = member_fixture(ctx.scope, :admin)
      reader = instance_admin_fixture().user
      variables = ~p"/#{ctx.scope.organisation}/settings/variables"

      for user <- [ctx.user, admin, reader] do
        conn = log_in_user(build_conn(), user)

        {:ok, lv, _html} = live(conn, ~p"/#{ctx.scope.organisation}/settings")
        assert has_element?(lv, "#settings-tab-secrets")

        for path <- [list_path(ctx.scope), variables] do
          {:ok, lv, _html} = live(conn, path)
          assert has_element?(lv, "#secrets-tabs-secrets")
          assert has_element?(lv, "#secrets-tabs-variables")
        end
      end
    end

    @tag needs: :managed_organisations
    test "in a client, the operator's people have the entry and open both tabs" do
      operator = operator_fixture()
      client = client_fixture(operator.scope)

      for organisation <- [operator.organisation, client.organisation] do
        Repo.insert!(
          %ApiaryPro.Grants.Grant{
            organisation_id: organisation.id,
            feature: :organisation_variables,
            granted: true
          },
          on_conflict: [set: [granted: true]],
          conflict_target: [:organisation_id, :feature]
        )
      end

      %{user: operator_member} = member_fixture(operator.scope, :member)

      for user <- [operator.user, operator_member] do
        conn = log_in_user(build_conn(), user)

        {:ok, lv, _html} = live(conn, ~p"/#{client.organisation}/settings")
        assert has_element?(lv, "#settings-tab-secrets")

        for path <- [
              ~p"/#{client.organisation}/settings/secrets",
              ~p"/#{client.organisation}/settings/variables"
            ] do
          {:ok, lv, _html} = live(conn, path)
          assert has_element?(lv, "#secrets-tabs-secrets")
          assert has_element?(lv, "#secrets-tabs-variables")
        end
      end
    end

    test "an instance admin, a reader, reads them, and changes nothing", _ctx do
      home = sign_up_fixture()
      secret = create!(home.scope, "FORGE_TOKEN", "read-value-not-shown")
      conn = log_in_user(build_conn(), instance_admin_fixture().user)

      {:ok, lv, html} = live(conn, list_path(home.scope))

      assert has_element?(lv, "#secret-#{secret.public_id}", "FORGE_TOKEN")
      refute html =~ "read-value-not-shown"

      assert text(lv, "#secrets-read-only") ==
               "Only owners and admins of #{home.organisation.name} change its secrets."

      refute has_element?(lv, "#new-secret")
      refute has_element?(lv, "#secret-#{secret.public_id}-menu")

      assert {:error, {:live_redirect, %{flash: %{"error" => error}}}} =
               live(conn, list_path(home.scope) <> "/new")

      assert error =~ "change nothing here"
      assert render_hook(lv, "delete_secret", %{}) =~ "change nothing"
      assert {:ok, [_secret]} = Secrets.list_organisation_secrets(home.scope)
    end

    test "an admin changes them", ctx do
      secret = create!(ctx.scope, "FORGE_TOKEN")
      %{user: admin} = member_fixture(ctx.scope, :admin)

      {:ok, lv, _html} = live(log_in_user(build_conn(), admin), list_path(ctx.scope))
      assert has_element?(lv, "#secret-#{secret.public_id}-menu")
      assert has_element?(lv, "#new-secret")
    end

    test "an admin made a member while the page is open is sent away from it", ctx do
      %{user: admin, membership: membership} = member_fixture(ctx.scope, :admin)
      conn = log_in_user(build_conn(), admin)
      {:ok, lv, _html} = live(conn, list_path(ctx.scope))

      secret = create!(ctx.scope, "FORGE_TOKEN")
      {:ok, _} = Apiary.Organisations.set_member_level(ctx.scope, membership.id, :member)

      # An event read again: the list is no longer theirs to read.
      render_hook(lv, "delete_secret", %{})

      settings = ~p"/#{ctx.scope.organisation}/settings"
      assert {^settings, flash} = assert_redirect(lv)

      assert flash["error"] ==
               "The secrets of #{ctx.scope.organisation.name} are no longer open to you."

      assert {:ok, [%{id: id}]} = Secrets.list_organisation_secrets(ctx.scope)
      assert id == secret.id
    end

    test "a suspended organisation's are read only, as its notice says", ctx do
      secret = create!(ctx.scope, "FORGE_TOKEN")
      %{instance_scope: instance} = instance_admin_fixture()
      {:ok, _} = Suspensions.suspend_organisation(instance, ctx.scope.organisation.id)

      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope))

      assert has_element?(lv, "#organisation-suspended")
      assert has_element?(lv, "#secret-#{secret.public_id}", "FORGE_TOKEN")
      refute has_element?(lv, "#secret-#{secret.public_id}-menu")
      refute has_element?(lv, "#new-secret")
      refute has_element?(lv, "#secrets-read-only")

      suspended = "#{ctx.scope.organisation.name} is suspended."

      for path <- ["/new", "/#{secret.public_id}/edit", "/#{secret.public_id}/delete"] do
        assert {:error, {:live_redirect, %{flash: %{"error" => ^suspended}}}} =
                 live(ctx.conn, list_path(ctx.scope) <> path)
      end

      assert render_hook(lv, "delete_secret", %{}) =~ suspended
      assert {:ok, [_secret]} = Secrets.list_organisation_secrets(ctx.scope)
    end

    @tag with_features: Features.all() -- [:organisation_variables, :factory, :workflow_model]
    test "without the feature and without the model keys the page is not found, and nothing leads to it",
         ctx do
      assert_error_sent :not_found, fn -> get(ctx.conn, list_path(ctx.scope)) end
      assert_error_sent :not_found, fn -> get(ctx.conn, list_path(ctx.scope) <> "/new") end

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.scope.organisation}/settings")
      refute has_element?(lv, "#settings-tab-secrets")
      refute has_element?(lv, "#settings-tab-variables")

      for q <- ["secrets", "variables"] do
        refute Enum.any?(
                 jump_labels(ctx.conn, ctx.scope, q),
                 &(&1 =~ ~r/^Organisation settings › (Secrets|Variables)/)
               ),
               q
      end
    end

    @tag with_features: Features.all() -- [:organisation_variables]
    test "without the feature the page holds the model keys alone, and the rest is not found",
         ctx do
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope))
      assert has_element?(lv, "#secrets-empty")
      refute has_element?(lv, "#new-secret")
      refute has_element?(lv, "#secrets-tabs-variables")

      # Nothing of the organisation's secrets or variables is reached through it.
      for path <- [
            list_path(ctx.scope) <> "/new",
            list_path(ctx.scope) <> "/sec_0000000000000000000000/edit"
          ] do
        assert_error_sent :not_found, fn -> get(ctx.conn, path) end
      end

      for path <- [
            ~p"/#{ctx.scope.organisation}/settings/variables",
            ~p"/#{ctx.scope.organisation}/settings/variables/new"
          ] do
        assert ctx.conn |> get(path) |> html_response(404)
      end

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.scope.organisation}/settings")
      assert has_element?(lv, "#settings-tab-secrets")
      refute has_element?(lv, "#settings-tab-variables")
    end

    @tag needs: :managed_organisations
    test "where the organisation is shown neither feature, the page is not found" do
      operator = operator_fixture()
      conn = log_in_user(build_conn(), operator.user)

      # Without security the organisation is shown neither the variables nor the factory.
      Repo.insert!(
        %ApiaryPro.Grants.Grant{
          organisation_id: operator.organisation.id,
          feature: :security,
          granted: false
        },
        on_conflict: [set: [granted: false]],
        conflict_target: [:organisation_id, :feature]
      )

      assert_error_sent(:not_found, fn -> get(conn, list_path(operator.scope)) end)

      {:ok, lv, _html} = live(conn, ~p"/#{operator.organisation}/settings")
      refute has_element?(lv, "#settings-tab-secrets")
    end

    @tag needs: :managed_organisations
    test "where the organisation does not have the feature, the page holds the model keys alone" do
      operator = operator_fixture()
      conn = log_in_user(build_conn(), operator.user)

      Repo.insert!(
        %ApiaryPro.Grants.Grant{
          organisation_id: operator.organisation.id,
          feature: :organisation_variables,
          granted: false
        },
        on_conflict: [set: [granted: false]],
        conflict_target: [:organisation_id, :feature]
      )

      {:ok, lv, _html} = live(conn, list_path(operator.scope))
      refute has_element?(lv, "#secrets-tabs-variables")
      refute has_element?(lv, "#new-secret")
      assert_error_sent(:not_found, fn -> get(conn, list_path(operator.scope) <> "/new") end)
    end
  end

  describe "who changed a secret" do
    # The row of `secret` as the list of `scope`'s organisation shows it to `user`.
    defp row(user, scope, secret) do
      {:ok, lv, _html} = live(log_in_user(build_conn(), user), list_path(scope))
      text(lv, "#secret-#{secret.public_id}")
    end

    defp letter(user), do: "#{String.upcase(String.first(user.email))} #{user.email}"

    test "a person removed from the organisation is named by their letter", ctx do
      admin = member_fixture(ctx.scope, :admin)
      secret = create!(admin.scope, "DEPLOY_TOKEN")
      Repo.delete!(admin.membership)

      row = row(ctx.user, ctx.scope, secret)
      assert row =~ "by #{letter(admin.user)}"
      refute row =~ "Former member"
    end

    test "a deleted account is a former member", ctx do
      admin = member_fixture(ctx.scope, :admin)
      secret = create!(admin.scope, "DEPLOY_TOKEN")
      {:ok, _deleted} = Apiary.Accounts.delete_user(admin.user)

      row = row(ctx.user, ctx.scope, secret)
      assert row =~ "by Former member"
      refute row =~ admin.user.email
    end

    test "who changed it is their letter, a tab stop with the address as its hint", ctx do
      admin = member_fixture(ctx.scope, :admin)
      theirs = create!(admin.scope, "DEPLOY_TOKEN")
      mine = create!(ctx.scope, "API_TOKEN")
      nobody = create!(ctx.scope, "CI_TOKEN")

      for schema <- [Secret, Apiary.Secrets.Value] do
        field = if schema == Secret, do: :id, else: :secret_id

        Repo.update_all(from(r in schema, where: field(r, ^field) == ^nobody.id),
          set: [updated_by_id: nil]
        )
      end

      {:ok, lv, _html} = live(log_in_user(build_conn(), ctx.user), list_path(ctx.scope))
      email = admin.user.email
      row = "#secret-#{theirs.public_id}"
      abbr = ~s{#{row} abbr[tabindex="0"][data-tip="#{email}"][aria-label="#{email}"]}
      letter = String.upcase(String.first(email))
      assert has_element?(lv, "#{abbr} > span[aria-hidden=true]", letter)
      assert has_element?(lv, "#{abbr} > .sr-only", email)
      # One letter in the row.
      assert lv
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#{row} abbr")
             |> Enum.count() == 1

      # The hint of the reader's letter ends in "(you)".
      you = "#{ctx.user.email} (you)"
      mine = "#secret-#{mine.public_id}"
      assert has_element?(lv, ~s{#{mine} abbr[tabindex="0"][data-tip="#{you}"]})

      # Nobody: the time alone.
      refute has_element?(lv, "#secret-#{nobody.public_id} abbr")
      refute text(lv, "#secret-#{nobody.public_id}") =~ " by "
    end

    @tag needs: :managed_organisations
    test "an operator's person, not a member of the client, is named by their account" do
      operator = operator_fixture()
      client = client_fixture(operator.scope)

      for organisation <- [operator.organisation, client.organisation] do
        Repo.insert!(
          %ApiaryPro.Grants.Grant{
            organisation_id: organisation.id,
            feature: :organisation_variables,
            granted: true
          },
          on_conflict: [set: [granted: true]],
          conflict_target: [:organisation_id, :feature]
        )
      end

      members = Apiary.Organisations.list_members(client.owner.scope)
      refute Enum.any?(members, &(&1.user.id == operator.user.id))
      secret = create!(client.owner.scope, "DEPLOY_TOKEN")

      for schema <- [Secret, Apiary.Secrets.Value] do
        field = if schema == Secret, do: :id, else: :secret_id

        Repo.update_all(from(r in schema, where: field(r, ^field) == ^secret.id),
          set: [updated_by_id: operator.user.id]
        )
      end

      row = row(client.owner.user, client.owner.scope, secret)
      assert row =~ "by #{letter(operator.user)}"
      refute row =~ "Former member"
    end
  end
end
