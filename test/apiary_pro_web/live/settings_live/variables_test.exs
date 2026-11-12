defmodule ApiaryProWeb.SettingsLive.VariablesTest do
  @moduledoc """
  The organisation's variables, the Variables tab of its settings' Secrets and variables
  entry: the list, with what each variable's workspaces and targets set themselves, and
  its bar (New variable, the search and the Lock filter, in the URL); New variable and
  Change value, pages of the section; Lock, Unlock and Delete, confirmed on the row, and
  kept open with the back end's reason when it refuses; the notice that runs receive no
  variables yet, on every view; who reads and who changes them.
  """
  # Not async: the features are the node's, and an instance admin is an owner of the
  # suite's one instance organisation.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Features, Repo, Variables}
  alias Apiary.Runs.Target
  alias ApiaryPro.{OrganisationVariables, Suspensions}
  alias ApiaryPro.OrganisationVariables.Variable

  @moduletag with_features: Features.all()
  # The organisation's variables need `secrets`: they run only where both are on.
  @moduletag needs: :organisation_variables

  @not_in_runs "A run receives only its security policy."

  setup :register_and_log_in_user

  defp list_path(scope), do: ~p"/#{scope.organisation}/settings/variables"

  defp create!(scope, name, value, locked \\ false) do
    {:ok, variable} =
      OrganisationVariables.create(scope, %{"name" => name, "value" => value, "locked" => locked})

    variable
  end

  defp target!(workspace, path) do
    Repo.insert!(%Target{
      organisation_id: workspace.organisation_id,
      workspace_id: workspace.id,
      system: "github.example",
      path: path,
      first_seen_at: DateTime.utc_now()
    })
  end

  # A workspace's or a target's own value, written as a row, as it was before the
  # organisation set the name, or locked it.
  defp own!(workspace, target, name, value) do
    now = DateTime.utc_now()

    Repo.insert!(%Variables.Variable{
      organisation_id: workspace.organisation_id,
      workspace_id: workspace.id,
      target_id: target && target.id,
      name: name,
      value: value,
      locked: false,
      inserted_at: now,
      updated_at: now
    })
  end

  # Whether the page gives the focus to the element `id` once drawn (the `focus_back/1`
  # mark, whose phx-mounted focuses it).
  defp focus?(view, id), do: has_element?(view, "span[hidden][phx-mounted*='\"##{id}\"']")

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

  describe "the list" do
    test "the Variables tab, sorted by name, with what is set below",
         ctx do
      main = ctx.scope.workspace
      platform = workspace_fixture(ctx.scope.organisation, "Platform")
      site = target!(main, "example/site")

      log = create!(ctx.scope, "log_level", "info")
      registry = create!(ctx.scope, "NPM_REGISTRY", "https://registry.example.com")
      region = create!(ctx.scope, "REGION", "eu-west-1", true)
      flag = create!(ctx.scope, "EMPTY_FLAG", "")

      # Main sets its own log_level, and a target of it too; Platform's REGION is set
      # aside by the lock.
      own!(main, nil, "log_level", "debug")
      own!(main, site, "log_level", "trace")
      own!(platform, nil, "REGION", "us-east-1")

      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope))

      # The Secrets and variables entry is the page, on its Variables tab.
      assert has_element?(lv, "#settings-tabs #settings-tab-secrets[aria-current='page']")
      refute has_element?(lv, "#settings-tab-variables")
      assert has_element?(lv, "#breadcrumb-settings", "Organisation settings")
      assert text(lv, "#breadcrumb-section[aria-current=page]") == "Secrets and variables"
      assert has_element?(lv, "#secrets-tabs-variables[aria-current=page]")

      # The section is the h1; the frame names the level.
      assert text(lv, "h1#settings-section-title") == "Secrets and variables"
      refute has_element?(lv, "#settings-section-secrets h1", "Organisation settings")

      assert title(lv) ==
               "Variables · Secrets and variables · Organisation settings · #{ctx.scope.organisation.name}"

      assert text(lv, ".q-settings-head-sub") ==
               "Secrets and variables that belong to #{ctx.scope.organisation.name}, not to one workspace. A secret is never shown again once it is saved; a variable is plain text."

      # Today's sentence of the page, under the tabs.
      assert text(lv, "#secrets-tabs-panel #variables-inherit") ==
               "Names and values every workspace of #{ctx.scope.organisation.name} inherits. A workspace may override one that is not locked; a locked one holds in every workspace and repository."

      assert has_element?(lv, "p#variables-not-in-runs.q-not-on-runs", @not_in_runs)

      assert has_element?(
               lv,
               "#variables-not-in-runs",
               "Qory Apiary keeps the variables and works out what each workspace and repository inherits."
             )

      # New variable is in the bar above the list, beside the search and the Filter.
      refute has_element?(lv, ".q-settings-actions")
      assert has_element?(lv, ".q-bar a#new-variable.btn-primary", "New variable")
      assert has_element?(lv, ".q-bar #variables-search")
      assert has_element?(lv, ".q-bar #variables-filter")
      refute has_element?(lv, "#variables-read-only")

      # By name, without case.
      ids =
        lv
        |> render()
        |> then(&Regex.scan(~r/id="variable-([0-9a-f-]{36})"/, &1))
        |> Enum.map(fn [_, id] -> id end)

      assert ids == [flag.id, log.id, registry.id, region.id]

      assert has_element?(lv, "#variable-#{flag.id}-value", "Empty")

      # The name, cut where the table is narrow, is whole in its title.
      assert has_element?(lv, "#variable-#{log.id} .q-var-nm > .q-title[title=log_level]")

      # The value is one line, cut to the cell up to 28 letters wide, whole in its title.
      assert has_element?(
               lv,
               "#variable-#{registry.id}-value.q-cut[class*='max-w-[28ch]'][title='https://registry.example.com']"
             )

      refute has_element?(lv, "#variable-#{registry.id}-value.truncate")

      assert has_element?(lv, "#variable-#{region.id}-lock", "Locked")
      assert has_element?(lv, "#variable-#{registry.id}-lock.sr-only", "Not locked")

      assert text(lv, "#variable-#{log.id}-below") ==
               "1 workspace overrides it · 1 repository overrides it"

      assert text(lv, "#variable-#{region.id}-below") == "1 value set aside by the lock"
      assert text(lv, "#variable-#{registry.id}-below") == "Not overridden"

      # Below 600 px of table, where Lock and Set their own are gone, the lock beside the
      # name and the count under it.
      assert has_element?(lv, ".q-tbl th.q-from-sm", "Lock")
      assert has_element?(lv, ".q-tbl th.q-from-sm", "Overrides")
      # Changed shows from 1000 px of table, as on a workspace's Variables.
      assert has_element?(lv, ".q-tbl th.q-from-md", "Changed")
      refute has_element?(lv, ".q-tbl th.q-from-sm", "Changed")
      # The two counts break between them, in their column and on the line under the
      # name, never inside one.
      assert has_element?(lv, "#variable-#{log.id}-below.q-parts")
      assert has_element?(lv, "#variable-#{log.id} .q-var-nm .q-var-line .q-parts")
      assert has_element?(lv, "#variable-#{region.id} .q-var-nm .q-var-lock", "Locked")
      refute has_element?(lv, "#variable-#{registry.id} .q-var-nm .q-var-lock")

      assert text(lv, "#variable-#{log.id} .q-var-nm .q-var-line") ==
               "1 workspace overrides it · 1 repository overrides it"

      assert text(lv, "#variable-#{region.id} .q-var-nm .q-var-line") ==
               "1 value set aside by the lock"

      # Who changed it last: the reader's letter, then the address in hidden text, which
      # the row's text runs in.
      assert has_element?(
               lv,
               "#variable-#{registry.id}",
               "by #{String.upcase(String.first(ctx.user.email))}#{ctx.user.email} (you)"
             )

      # Each row's acts: Lock… for one unlocked, Unlock… for one locked.
      assert has_element?(lv, "#variable-#{registry.id}-change")
      assert has_element?(lv, "#variable-#{registry.id}-lock-item", "Lock…")
      refute has_element?(lv, "#variable-#{registry.id}-unlock-item")
      assert has_element?(lv, "#variable-#{region.id}-unlock-item", "Unlock…")
      assert has_element?(lv, "#variable-#{region.id}-delete", "Delete variable…")

      # Each item's accessible name starts with the words it shows.
      assert has_element?(
               lv,
               "#variable-#{registry.id}-change[aria-label='Change value of NPM_REGISTRY']",
               "Change value…"
             )

      assert has_element?(
               lv,
               "#variable-#{registry.id}-lock-item[aria-label='Lock NPM_REGISTRY']"
             )

      assert has_element?(lv, "#variable-#{region.id}-unlock-item[aria-label='Unlock REGION']")

      assert has_element?(
               lv,
               "#variable-#{region.id}-delete[aria-label='Delete variable REGION']"
             )
    end

    test "with none, says what a variable here is, and offers New variable", ctx do
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope))

      assert has_element?(lv, "#variables-empty", "No variables yet")

      assert text(lv, "#variables-empty") =~
               "Each workspace of #{ctx.scope.organisation.name} that does not override a variable set here inherits it, and so does each of its repositories that does not override it. A locked variable holds in every workspace and repository, and sets their overrides aside."

      assert has_element?(lv, "#variables-not-in-runs", @not_in_runs)

      # New variable in the bar, and in the empty state; nothing to search or filter.
      assert has_element?(lv, ".q-bar a#new-variable")
      assert has_element?(lv, "#variables-empty a[href='#{list_path(ctx.scope)}/new']")
      refute has_element?(lv, "#variables-search")
      refute has_element?(lv, "#variables-filter")
      refute has_element?(lv, "#variables")
    end

    test "follows a change made elsewhere", ctx do
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope))
      assert has_element?(lv, "#variables-empty")

      variable = create!(ctx.scope, "LOG_LEVEL", "info")

      assert render(lv) =~ "variable-#{variable.id}"
      refute has_element?(lv, "#variables-empty")
    end

    test "the palette lists its section under the organisation's settings", ctx do
      labels =
        ctx.conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/#{ctx.scope.organisation}/#{ctx.scope.workspace}/jump", %{"q" => "variables"})
        |> json_response(200)
        |> Map.fetch!("groups")
        |> Enum.find(&(&1["label"] == "Go to"))
        |> Map.fetch!("items")
        |> Enum.map(& &1["label"])

      assert "Organisation settings › Secrets and variables" in labels
      refute "Organisation settings › Variables" in labels
    end
  end

  describe "the bar" do
    setup ctx do
      %{
        log: create!(ctx.scope, "LOG_LEVEL", "info"),
        registry: create!(ctx.scope, "NPM_REGISTRY", "https://registry.example.com", true),
        region: create!(ctx.scope, "REGION", "eu-west-1")
      }
    end

    test "the search finds a variable by name or value, in the URL", ctx do
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope))

      assert has_element?(
               lv,
               "#variables-search input[placeholder='Find a variable by name or value']"
             )

      assert has_element?(lv, "#variables-search label", "Find a variable")

      # The status line is there from the start, out of sight until a search narrows.
      assert has_element?(lv, "#variables-status.sr-only[role=status]")
      refute has_element?(lv, "#variables-status p")

      lv |> form("#variables-search", q: "example.com") |> render_change()
      assert_patch(lv, list_path(ctx.scope) <> "?q=example.com")

      assert has_element?(lv, "#variable-#{ctx.registry.id}")
      refute has_element?(lv, "#variable-#{ctx.log.id}")
      refute has_element?(lv, "#variable-#{ctx.region.id}")
      refute has_element?(lv, "#variables-status.sr-only")
      assert text(lv, "#variables-status") == "1 variable matches"

      # By name, without case.
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope) <> "?q=log_")
      assert has_element?(lv, "#variable-#{ctx.log.id}")
      refute has_element?(lv, "#variable-#{ctx.registry.id}")
      assert has_element?(lv, "#variables-search input[value='log_']")
    end

    test "the Lock filter keeps the locked ones or the others, as a token", ctx do
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope))

      assert has_element?(lv, "#variables-filter-lock-yes", "Locked")
      assert has_element?(lv, "#variables-filter-lock-no", "Not locked")
      refute has_element?(lv, "#variables-tokens")

      lv |> element("#variables-filter-lock-yes") |> render_click()
      assert_patch(lv, list_path(ctx.scope) <> "?lock=yes")

      assert has_element?(lv, "#variable-#{ctx.registry.id}")
      refute has_element?(lv, "#variable-#{ctx.log.id}")
      assert has_element?(lv, "#variables-token-lock", "Locked")
      assert text(lv, "#variables-status") == "1 variable matches"

      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope) <> "?lock=no")
      assert has_element?(lv, "#variable-#{ctx.log.id}")
      assert has_element?(lv, "#variable-#{ctx.region.id}")
      refute has_element?(lv, "#variable-#{ctx.registry.id}")
      assert text(lv, "#variables-status") == "2 variables match"

      # The token takes the filter away.
      lv |> element("#variables-token-lock a") |> render_click()
      assert_patch(lv, list_path(ctx.scope))
      assert has_element?(lv, "#variable-#{ctx.registry.id}")
      refute has_element?(lv, "#variables-tokens")

      # The workspace tab's other filters and its order are not this page's.
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope) <> "?targets=own&sort=changed")
      assert has_element?(lv, "#variable-#{ctx.log.id}")
      refute has_element?(lv, "#variables-tokens")
      assert has_element?(lv, "#variables-status.sr-only")
    end

    test "with nothing left, says so and clears the search", ctx do
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope) <> "?q=nothing&lock=yes")

      assert has_element?(lv, "#variables-no-match", "No variable matches")
      refute has_element?(lv, "#variables")
      refute has_element?(lv, "#variables-empty")
      assert text(lv, "#variables-status") == "0 variables match"

      lv |> element("#variables-clear", "Clear the search") |> render_click()
      assert_patch(lv, list_path(ctx.scope))
      assert has_element?(lv, "#variable-#{ctx.log.id}")
      refute has_element?(lv, "#variables-no-match")
    end

    test "a page or a confirmation opened from a narrowed list leads back to it", ctx do
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope) <> "?lock=no")
      narrowed = list_path(ctx.scope) <> "?lock=no"

      lv |> element("#new-variable") |> render_click()
      assert has_element?(lv, "#breadcrumb a#breadcrumb-section[href='#{narrowed}']")
      assert has_element?(lv, "a#variable-save-cancel[href='#{narrowed}']")
      lv |> element("#variable-save-cancel") |> render_click()
      assert_patch(lv, narrowed)

      # A lock takes the row out of the filter: the focus goes to New variable.
      lv |> element("#variable-#{ctx.log.id}-lock-item") |> render_click()
      lv |> element("#variable-#{ctx.log.id}-confirm-act") |> render_click()
      assert_patch(lv, narrowed)
      assert render(lv) =~ "LOG_LEVEL is locked."
      refute has_element?(lv, "#variable-#{ctx.log.id}")
      assert focus?(lv, "new-variable")
    end

    test "a reader searches and filters, and is offered no New variable", ctx do
      %{user: admin} = instance_admin_fixture()
      conn = log_in_user(build_conn(), admin)

      {:ok, lv, _html} = live(conn, list_path(ctx.scope) <> "?lock=yes")

      assert has_element?(lv, ".q-bar #variables-search")
      refute has_element?(lv, "#new-variable")
      assert has_element?(lv, "#variable-#{ctx.registry.id}")
      refute has_element?(lv, "#variable-#{ctx.log.id}")
    end
  end

  describe "New variable" do
    test "a page of the section, which saves one and leads back to the list", ctx do
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope))

      lv |> element(".q-bar a#new-variable") |> render_click()
      assert_patch(lv, list_path(ctx.scope) <> "/new")

      refute has_element?(lv, "#main dialog, #main [role=dialog]")
      # Secrets and variables is current as the page's parent; the breadcrumb and Cancel
      # lead back to the Variables tab. The frame writes the level and the section, the
      # page only the form's segment.
      assert has_element?(lv, "#settings-tab-secrets[aria-current=true]")
      assert has_element?(lv, "#breadcrumb-settings", "Organisation settings")

      assert has_element?(
               lv,
               "#breadcrumb a#breadcrumb-section[href='#{list_path(ctx.scope)}']",
               "Secrets and variables"
             )

      assert has_element?(lv, "#breadcrumb [aria-current=page]", "New variable")
      refute has_element?(lv, "#breadcrumb a", "Settings")

      assert length(
               Regex.scan(~r/>\s*Secrets and variables\s*</, render(element(lv, "#breadcrumb")))
             ) == 1

      assert has_element?(lv, "h1#variable-page-title", "New variable")

      assert title(lv) ==
               "New variable · Organisation settings · #{ctx.scope.organisation.name}"

      assert text(lv, "#variable-page .q-page-desc") =~
               "Each workspace of #{ctx.scope.organisation.name} that does not override a variable set here inherits it"

      assert has_element?(
               lv,
               "a#variable-save-cancel[href='#{list_path(ctx.scope)}']",
               "Cancel"
             )

      assert has_element?(lv, "#variables-not-in-runs", @not_in_runs)

      assert has_element?(
               lv,
               "label",
               "Locked: no workspace or repository may override it"
             )

      # An error shows as it is typed.
      html =
        lv
        |> form("#variable-form", variable: %{name: "1BAD", value: "x"})
        |> render_change()

      assert html =~ "must start with a letter or _"

      lv
      |> form("#variable-form", variable: %{name: "LOG_LEVEL", value: "info", locked: "true"})
      |> render_submit()

      assert_patch(lv, list_path(ctx.scope))
      assert render(lv) =~ "LOG_LEVEL is saved."
      assert [%Variable{name: "LOG_LEVEL", locked: true}] = Repo.all(Variable)
      assert has_element?(lv, "#variables td", "LOG_LEVEL")
      assert has_element?(lv, "#variables-not-in-runs", @not_in_runs)
    end

    test "is made only from its page: the event without it shows the list again", ctx do
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope))

      render_hook(lv, "create_variable", %{"variable" => %{"name" => "SNEAKY", "value" => "x"}})

      assert has_element?(lv, "#variables-empty")
      assert Repo.all(Variable) == []
    end

    test "a limit's refusal reads in the workspaces' words, through the edition's catalogue",
         ctx do
      now = DateTime.utc_now()

      Repo.insert_all(
        Variable,
        for n <- 1..127 do
          %{
            id: Ecto.UUID.generate(),
            organisation_id: ctx.scope.organisation.id,
            name: "NAME_#{n}",
            value: "x",
            locked: false,
            inserted_at: now,
            updated_at: now
          }
        end
      )

      # Main's own name, and the organisation's 127: one more is over in Main.
      own!(ctx.scope.workspace, nil, "OWN", "x")
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope) <> "/new")

      lv
      |> form("#variable-form", variable: %{name: "ONE_MORE", value: "x"})
      |> render_submit()

      assert has_element?(
               lv,
               "#variable-form",
               "would raise a repository's variables in #{ctx.scope.workspace.name} above 128"
             )

      # And the organisation's own 128, with no workspace to blame.
      Repo.delete_all(Variables.Variable)
      create!(ctx.scope, "ONE_MORE", "x")
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope) <> "/new")

      lv
      |> form("#variable-form", variable: %{name: "TWO_MORE", value: "x"})
      |> render_submit()

      assert has_element?(lv, "#variable-form", "would raise a repository's variables above 128")
    end

    test "the back end's refusal naming a workspace shows under its field", ctx do
      own!(ctx.scope.workspace, nil, "log_level", "debug")

      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope) <> "/new")

      html =
        lv
        |> form("#variable-form", variable: %{name: "LOG_LEVEL", value: "info"})
        |> render_submit()

      assert html =~ "is log_level in #{ctx.scope.workspace.name}: use the same spelling"
      assert has_element?(lv, "#variable-form")
      assert Repo.all(Variable) == []
    end
  end

  describe "Change value" do
    test "a page of the section that changes the value only", ctx do
      variable = create!(ctx.scope, "LOG_LEVEL", "info")
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope))

      lv |> element("#variable-#{variable.id}-change") |> render_click()
      assert_patch(lv, list_path(ctx.scope) <> "/#{variable.id}/change")

      assert has_element?(lv, "h1#variable-page-title", "Change the value of LOG_LEVEL")

      assert has_element?(
               lv,
               "#variable-page .q-page-desc",
               "Each workspace that does not override it inherits the new value, and so does each of its repositories that does not override it."
             )

      assert has_element?(lv, "#variables-not-in-runs", @not_in_runs)
      refute has_element?(lv, "#variable-form input[name='variable[name]']")

      assert title(lv) ==
               "Change the value of LOG_LEVEL · Organisation settings · #{ctx.scope.organisation.name}"

      lv |> form("#variable-form", variable: %{value: "debug"}) |> render_submit()

      assert_patch(lv, list_path(ctx.scope))
      assert render(lv) =~ "LOG_LEVEL is changed."
      assert Repo.get!(Variable, variable.id).value == "debug"
    end

    test "of a locked one says every workspace and target inherits the new value", ctx do
      variable = create!(ctx.scope, "REGION", "eu-west-1", true)
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope) <> "/#{variable.id}/change")

      assert text(lv, "#variable-page .q-page-desc") ==
               "Every workspace and repository inherits the new value: REGION is locked."

      refute render(lv) =~ "Each workspace that does not override it inherits the new value"
    end

    test "a refusal on the name, which the page does not draw, shows above its foot", ctx do
      log = create!(ctx.scope, "LOG_LEVEL", "info")
      region = create!(ctx.scope, "REGION", "eu-west-1")
      own!(ctx.scope.workspace, nil, "log_level", "debug")
      workspace = ctx.scope.workspace.name

      # Another variable's spelling below holds back any change.
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope) <> "/#{region.id}/change")
      lv |> form("#variable-form", variable: %{value: "us-east-1"}) |> render_submit()

      assert has_element?(lv, "#variable-form")

      assert text(lv, "#variable-form p#variable-refused[role=alert]") ==
               "cannot be saved while #{workspace} spells LOG_LEVEL as log_level: use one spelling"

      assert Repo.get!(Variable, region.id).value == "eu-west-1"

      # The variable's own name spelled otherwise gets the variable as its subject.
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope) <> "/#{log.id}/change")
      refute has_element?(lv, "#variable-refused")
      lv |> form("#variable-form", variable: %{value: "warn"}) |> render_submit()

      assert text(lv, "#variable-refused") ==
               "LOG_LEVEL is spelled log_level in #{workspace}: use the same spelling"

      assert Repo.get!(Variable, log.id).value == "info"
    end
  end

  describe "Lock and Unlock" do
    test "ask on the row, with how many values below the lock sets aside", ctx do
      variable = create!(ctx.scope, "LOG_LEVEL", "info")
      own!(ctx.scope.workspace, nil, "LOG_LEVEL", "debug")
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope))

      lv |> element("#variable-#{variable.id}-lock-item") |> render_click()
      assert_patch(lv, list_path(ctx.scope) <> "/#{variable.id}/lock")

      assert has_element?(lv, "#variable-#{variable.id}-confirm", "Lock LOG_LEVEL?")

      assert has_element?(
               lv,
               "#variable-#{variable.id}-confirm",
               "While it is locked, no workspace or repository may override it."
             )

      assert has_element?(
               lv,
               "#lock-below",
               "1 workspace or repository override is set aside while the lock holds."
             )

      # Nothing changed while it asks.
      refute Repo.get!(Variable, variable.id).locked

      lv |> element("#variable-#{variable.id}-confirm button", "Lock") |> render_click()
      assert_patch(lv, list_path(ctx.scope))
      assert render(lv) =~ "LOG_LEVEL is locked."
      assert focus?(lv, "variable-#{variable.id}-menu-button")
      assert Repo.get!(Variable, variable.id).locked
      assert text(lv, "#variable-#{variable.id}-below") == "1 value set aside by the lock"

      # Unlock asks too, and says what comes back.
      lv |> element("#variable-#{variable.id}-unlock-item") |> render_click()
      assert has_element?(lv, "#variable-#{variable.id}-confirm", "Unlock LOG_LEVEL?")

      assert has_element?(
               lv,
               "#variable-#{variable.id}-confirm",
               "Workspaces and repositories may override it again."
             )

      assert has_element?(lv, "#unlock-below", "1 value set aside comes back in force.")

      lv |> element("#variable-#{variable.id}-confirm button", "Unlock") |> render_click()
      assert render(lv) =~ "LOG_LEVEL is unlocked."
      assert focus?(lv, "variable-#{variable.id}-menu-button")
      refute Repo.get!(Variable, variable.id).locked
    end

    test "an unlock counts only the values it puts back in force", ctx do
      region = create!(ctx.scope, "REGION", "eu-west-1", true)
      site = target!(ctx.scope.workspace, "example/site")
      platform = workspace_fixture(ctx.scope.organisation, "Platform")
      docs = target!(platform, "example/docs")

      # Main locks REGION itself: its site's own value stays set aside after an unlock of
      # the organisation's. Platform's docs' comes back.
      ws = own!(ctx.scope.workspace, nil, "REGION", "us-east-1")
      Repo.update!(Ecto.Changeset.change(ws, locked: true))
      own!(ctx.scope.workspace, site, "REGION", "ap-south-1")
      own!(platform, docs, "REGION", "sa-east-1")

      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope) <> "/#{region.id}/unlock")
      assert has_element?(lv, "#unlock-below", "2 values set aside come back in force.")

      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope) <> "/#{region.id}/delete")
      assert has_element?(lv, "#delete-below", "2 values set aside come back in force.")
    end

    test "Cancel and Escape go back to the list, the focus on the row's menu button", ctx do
      variable = create!(ctx.scope, "LOG_LEVEL", "info")
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope) <> "/#{variable.id}/lock")

      assert has_element?(
               lv,
               "#variable-#{variable.id}-confirm[phx-key=Escape][phx-window-keydown*=cancel_confirm]"
             )

      lv |> element("#variable-#{variable.id}-confirm-cancel") |> render_click()
      assert_patch(lv, list_path(ctx.scope))
      refute has_element?(lv, "#variable-#{variable.id}-confirm")
      assert focus?(lv, "variable-#{variable.id}-menu-button")
      refute Repo.get!(Variable, variable.id).locked
    end

    test "a lock path of one locked already shows the list", ctx do
      variable = create!(ctx.scope, "LOG_LEVEL", "info", true)

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(ctx.conn, list_path(ctx.scope) <> "/#{variable.id}/lock")

      assert to == list_path(ctx.scope)
      assert flash == %{}
    end

    test "an unlock the back end refuses stays open, and says why", ctx do
      create!(ctx.scope, "LOG_LEVEL", "info")
      region = create!(ctx.scope, "REGION", "eu-west-1", true)
      own!(ctx.scope.workspace, nil, "log_level", "debug")

      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope) <> "/#{region.id}/unlock")
      lv |> element("#variable-#{region.id}-confirm button", "Unlock") |> render_click()

      assert has_element?(lv, "#variable-#{region.id}-confirm", "Unlock REGION?")

      assert text(lv, "#variable-refused") ==
               "cannot be unlocked while #{ctx.scope.workspace.name} spells LOG_LEVEL as log_level: use one spelling"

      assert has_element?(lv, "#variable-#{region.id}-confirm #variable-refused[role=alert]")

      # The focus stays on the button.
      assert has_element?(
               lv,
               "span[hidden][phx-mounted*='#variable-#{region.id}-confirm-act']"
             )

      assert Repo.get!(Variable, region.id).locked
    end

    test "a lock refused for another spelling says it was the lock, with the variable's name",
         ctx do
      log = create!(ctx.scope, "LOG_LEVEL", "info")
      zone = create!(ctx.scope, "ZONE", "a")
      own!(ctx.scope.workspace, nil, "log_level", "debug")
      workspace = ctx.scope.workspace.name

      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope) <> "/#{zone.id}/lock")
      lv |> element("#variable-#{zone.id}-confirm-act") |> render_click()

      assert text(lv, "#variable-refused") ==
               "cannot be locked while #{workspace} spells LOG_LEVEL as log_level: use one spelling"

      # The refusal about the variable's own name is given it as its subject.
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope) <> "/#{log.id}/lock")
      lv |> element("#variable-#{log.id}-confirm-act") |> render_click()

      assert has_element?(lv, "#variable-#{log.id}-confirm", "Lock LOG_LEVEL?")

      assert text(lv, "#variable-refused") ==
               "LOG_LEVEL is spelled log_level in #{workspace}: use the same spelling"

      refute Repo.get!(Variable, log.id).locked
    end
  end

  describe "Delete" do
    test "asks on the row, then deletes", ctx do
      variable = create!(ctx.scope, "LOG_LEVEL", "info")
      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope))

      lv |> element("#variable-#{variable.id}-delete") |> render_click()
      assert_patch(lv, list_path(ctx.scope) <> "/#{variable.id}/delete")

      assert has_element?(lv, "#variable-#{variable.id}-confirm", "Delete LOG_LEVEL?")

      assert has_element?(
               lv,
               "#variable-#{variable.id}-confirm",
               "Workspaces no longer inherit it; a workspace or repository that overrides it keeps its value. This cannot be undone."
             )

      refute has_element?(lv, "#delete-below")

      lv |> element("#variable-#{variable.id}-confirm button", "Yes, delete") |> render_click()
      assert_patch(lv, list_path(ctx.scope))
      assert render(lv) =~ "LOG_LEVEL is deleted."
      assert Repo.all(Variable) == []
      assert has_element?(lv, "#variables-empty")
      assert focus?(lv, "new-variable")
    end

    test "the focus goes to the next row's menu, else the one before", ctx do
      a = create!(ctx.scope, "A_ONE", "1")
      b = create!(ctx.scope, "B_TWO", "2")
      c = create!(ctx.scope, "C_THREE", "3")

      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope) <> "/#{b.id}/delete")
      lv |> element("#variable-#{b.id}-confirm-act") |> render_click()
      assert focus?(lv, "variable-#{c.id}-menu-button")

      lv |> element("#variable-#{c.id}-delete") |> render_click()
      lv |> element("#variable-#{c.id}-confirm-act") |> render_click()
      assert focus?(lv, "variable-#{a.id}-menu-button")
    end

    test "of a locked one says what comes back; refused, it stays open and says why", ctx do
      create!(ctx.scope, "LOG_LEVEL", "info")
      region = create!(ctx.scope, "REGION", "eu-west-1", true)
      platform = workspace_fixture(ctx.scope.organisation, "Platform")
      own!(platform, nil, "REGION", "us-east-1")
      own!(ctx.scope.workspace, nil, "log_level", "debug")

      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope) <> "/#{region.id}/delete")

      assert has_element?(lv, "#delete-below", "1 value set aside comes back in force.")

      lv |> element("#variable-#{region.id}-confirm button", "Yes, delete") |> render_click()

      assert has_element?(lv, "#variable-#{region.id}-confirm", "Delete REGION?")

      assert text(lv, "#variable-refused") ==
               "cannot be deleted while #{ctx.scope.workspace.name} spells LOG_LEVEL as log_level: use one spelling"

      assert Repo.get!(Variable, region.id)
    end
  end

  describe "who" do
    test "a reader sees every value, no control, and who changes them", ctx do
      variable = create!(ctx.scope, "LOG_LEVEL", "info", true)
      %{user: admin} = instance_admin_fixture()
      conn = log_in_user(build_conn(), admin)

      {:ok, lv, _html} = live(conn, list_path(ctx.scope))

      assert has_element?(lv, "#variable-#{variable.id}-value", "info")
      assert has_element?(lv, "#variables-not-in-runs", @not_in_runs)

      assert has_element?(
               lv,
               "#variables-read-only",
               "Only owners and admins of #{ctx.scope.organisation.name} change its variables."
             )

      refute has_element?(lv, "#new-variable")
      refute has_element?(lv, "#variable-#{variable.id}-menu")

      # A path of a change is refused as it opens, and says why.
      assert {:error, {:live_redirect, %{to: to, flash: %{"error" => error}}}} =
               live(conn, list_path(ctx.scope) <> "/#{variable.id}/unlock")

      assert to == list_path(ctx.scope)
      assert error =~ "change nothing here"

      # And an event the page offers no control for.
      {:ok, lv, _html} = live(conn, list_path(ctx.scope))

      assert render_hook(lv, "unlock_variable", %{}) =~ "change nothing here"
      assert Repo.get!(Variable, variable.id).locked
    end

    # A client holds no grant of `secrets` (no grant names it), so it has no organisation
    # variables: the reader here is an instance admin, who reads as an operator's people do.
    test "an instance admin, a reader with no membership, reads them, and sees no control",
         _ctx do
      home = sign_up_fixture()
      variable = create!(home.scope, "LOG_LEVEL", "info", true)
      conn = log_in_user(build_conn(), instance_admin_fixture().user)

      {:ok, lv, _html} = live(conn, list_path(home.scope))

      assert has_element?(lv, "#variable-#{variable.id}-value", "info")
      assert has_element?(lv, "#variable-#{variable.id}-lock", "Locked")

      assert has_element?(
               lv,
               "#variables-read-only",
               "Only owners and admins of #{home.organisation.name} change its variables."
             )

      refute has_element?(lv, "#new-variable")
      refute has_element?(lv, "#variable-#{variable.id}-menu")

      assert render_hook(lv, "unlock_variable", %{}) =~ "change nothing"
      assert Repo.get!(Variable, variable.id).locked
    end

    test "an admin made a member while the page is open is sent away from it", ctx do
      %{user: admin, membership: membership} = member_fixture(ctx.scope, :admin)
      conn = log_in_user(build_conn(), admin)
      {:ok, lv, _html} = live(conn, list_path(ctx.scope))

      {:ok, _} = Apiary.Organisations.set_member_level(ctx.scope, membership.id, :member)

      # Any change read again: the list is no longer theirs to read.
      create!(ctx.scope, "LOG_LEVEL", "info")

      settings = ~p"/#{ctx.scope.organisation}/settings"
      assert {^settings, flash} = assert_redirect(lv)

      assert flash["error"] ==
               "The variables of #{ctx.scope.organisation.name} are no longer open to you."
    end

    test "a path naming a variable the organisation does not have says it is not there",
         ctx do
      variable = create!(ctx.scope, "LOG_LEVEL", "info")
      other = sign_up_fixture()
      conn = log_in_user(build_conn(), other.user)

      assert {:error, {:live_redirect, %{to: to, flash: %{"error" => error}}}} =
               live(conn, ~p"/#{other.organisation}/settings/variables/#{variable.id}/delete")

      assert to == ~p"/#{other.organisation}/settings/variables"
      assert error == "That variable is not in #{other.organisation.name}."
      assert Repo.get!(Variable, variable.id)
    end

    test "a member does not open it, nor sees it listed", ctx do
      %{user: member} = member_fixture(ctx.scope, :member)
      conn = log_in_user(build_conn(), member)

      assert_raise ApiaryWeb.NotFound, fn -> live(conn, list_path(ctx.scope)) end

      {:ok, lv, _html} = live(conn, ~p"/#{ctx.scope.organisation}/settings")
      refute has_element?(lv, "#settings-tab-secrets")
      refute has_element?(lv, "#settings-tab-variables")
    end

    test "an admin changes them", ctx do
      variable = create!(ctx.scope, "LOG_LEVEL", "info")
      %{user: admin} = member_fixture(ctx.scope, :admin)

      {:ok, lv, _html} = live(log_in_user(build_conn(), admin), list_path(ctx.scope))
      assert has_element?(lv, "#variable-#{variable.id}-menu")
      assert has_element?(lv, "#new-variable")
    end

    test "a suspended organisation's are read only, as its notice says", ctx do
      variable = create!(ctx.scope, "LOG_LEVEL", "info")
      %{instance_scope: instance} = instance_admin_fixture()
      {:ok, _} = Suspensions.suspend_organisation(instance, ctx.scope.organisation.id)

      {:ok, lv, _html} = live(ctx.conn, list_path(ctx.scope))

      assert has_element?(lv, "#organisation-suspended")
      assert has_element?(lv, "#variable-#{variable.id}-value", "info")
      refute has_element?(lv, "#variable-#{variable.id}-menu")
      refute has_element?(lv, "#new-variable")
      refute has_element?(lv, "#variables-read-only")

      # Its owner is refused each change, as a path or as an event, and told why.
      suspended = "#{ctx.scope.organisation.name} is suspended."

      for path <- ["/new", "/#{variable.id}/lock", "/#{variable.id}/change"] do
        assert {:error, {:live_redirect, %{flash: %{"error" => ^suspended}}}} =
                 live(ctx.conn, list_path(ctx.scope) <> path)
      end

      for {event, params} <- [
            {"create_variable", %{"variable" => %{"name" => "SNEAKY", "value" => "x"}}},
            {"lock_variable", %{}},
            {"delete_variable", %{}}
          ] do
        assert render_hook(lv, event, params) =~ suspended
      end

      assert [%Variable{name: "LOG_LEVEL", locked: false}] = Repo.all(Variable)
    end

    @tag with_features: Features.all() -- [:organisation_variables]
    test "without the feature the page is not found, and nothing leads to it", ctx do
      assert ctx.conn |> get(list_path(ctx.scope)) |> html_response(404)
      assert ctx.conn |> get(list_path(ctx.scope) <> "/new") |> html_response(404)

      # The section is there for the model keys on the Secrets tab; the Variables tab is not.
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.scope.organisation}/settings")
      assert has_element?(lv, "#settings-tab-secrets")
      refute has_element?(lv, "#settings-tab-variables")
      assert has_element?(lv, "#settings-tab-organisation")
    end
  end

  describe "who changed a variable" do
    # The row of `variable` as the list of `scope`'s organisation shows it to `user`.
    defp row(user, scope, variable) do
      {:ok, lv, _html} = live(log_in_user(build_conn(), user), list_path(scope))
      text(lv, "#variable-#{variable.id}")
    end

    defp letter(user), do: "#{String.upcase(String.first(user.email))} #{user.email}"

    test "a person removed from the organisation is named by their letter", ctx do
      admin = member_fixture(ctx.scope, :admin)
      variable = create!(admin.scope, "LOG_LEVEL", "info")
      Repo.delete!(admin.membership)

      row = row(ctx.user, ctx.scope, variable)
      assert row =~ "by #{letter(admin.user)}"
      refute row =~ "Former member"
    end

    test "a deleted account is a former member", ctx do
      admin = member_fixture(ctx.scope, :admin)
      variable = create!(admin.scope, "LOG_LEVEL", "info")
      {:ok, _deleted} = Apiary.Accounts.delete_user(admin.user)

      row = row(ctx.user, ctx.scope, variable)
      assert row =~ "by Former member"
      refute row =~ admin.user.email
    end

    test "who changed it is their letter, a tab stop with the address as its hint", ctx do
      admin = member_fixture(ctx.scope, :admin)
      theirs = create!(admin.scope, "LOG_LEVEL", "info")
      mine = create!(ctx.scope, "REGION", "eu")
      nobody = create!(ctx.scope, "TIMEOUT", "30")
      Repo.update!(Ecto.Changeset.change(nobody, updated_by_id: nil))

      {:ok, lv, _html} = live(log_in_user(build_conn(), ctx.user), list_path(ctx.scope))
      email = admin.user.email
      row = "#variable-#{theirs.id}"
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
      mine = "#variable-#{mine.id}"
      assert has_element?(lv, ~s{#{mine} abbr[tabindex="0"][data-tip="#{you}"]})

      # Nobody: the time alone.
      refute has_element?(lv, "#variable-#{nobody.id} abbr")
      refute text(lv, "#variable-#{nobody.id}") =~ " by "
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
      variable = create!(client.owner.scope, "LOG_LEVEL", "info")
      Repo.update!(Ecto.Changeset.change(variable, updated_by_id: operator.user.id))

      row = row(client.owner.user, client.owner.scope, variable)
      assert row =~ "by #{letter(operator.user)}"
      refute row =~ "Former member"
    end
  end
end
