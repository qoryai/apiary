defmodule ApiaryWeb.InstanceLive.FeaturesTest do
  @moduledoc """
  Instance settings › Features (`ApiaryWeb.InstanceLive.Features`): the instance's
  features for its admins, the Instance level's second section; its rows, locks, the
  read-only state while `QORY_FEATURES` decides, the lines above Save, the save and a
  stale one; the link from Configuration; open pages that follow a save, and the pages
  a save turns off; the save on the Activity page; and a path that does not exist for
  anyone else.
  """
  # Not async: the features, the variable's value and the node's copy are the whole
  # node's, and hiding the instance's organisation acts on the row every test shares.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures, only: [member_fixture: 1]

  alias Apiary.Features
  alias Apiary.Features.Saved
  alias Apiary.Features.Saved.Row

  @moduletag :feature_sets

  @intro "Turn features on or off for every organisation. Save applies them at once, with no restart."
  @stale "Check the features again and save. Another instance admin saved them at the same time, so your change was not saved."

  setup do
    for key <- [
          :features,
          :features_setting,
          :installed_adapters,
          :installed_nodes,
          :registry_setting
        ] do
      before = Application.fetch_env(:apiary, key)

      on_exit(fn ->
        case before do
          {:ok, value} -> Application.put_env(:apiary, key, value)
          :error -> Application.delete_env(:apiary, key)
        end
      end)
    end

    Application.put_env(:apiary, :features_setting, nil)
    Application.put_env(:apiary, :installed_adapters, [])
    Application.put_env(:apiary, :installed_nodes, %{pool: nil, gateway: nil, url: nil})
    Application.put_env(:apiary, :registry_setting, nil)

    # The node's copy is the list in force: the defaults, nothing saved yet.
    Saved.refresh()

    # A workspace's set-up is finished: a link to it leads to its first page.
    Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)
  end

  defp text(view, selector),
    do:
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")

  defp row_ids(view),
    do:
      view
      |> element("#features-rows")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("li")
      |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))

  defp toggle(view, feature),
    do: view |> element("#feature-#{feature}-switch") |> render_click()

  defp save(view), do: view |> form("#features-form") |> render_submit()

  # Saves `names` as the saved list, as a save on another node would, with every feature
  # of the release seen: else an unseen default feature comes back on.
  defp store!(names) do
    Apiary.Repo.insert_all("instance_settings", [%{id: true, updated_at: DateTime.utc_now()}],
      on_conflict: :nothing,
      conflict_target: :id
    )

    {1, _rows} =
      Apiary.Repo.update_all(from(r in Row, where: r.id == true),
        set: [features: names, features_seen: Enum.map(Features.all(), &to_string/1)],
        inc: [features_version: 1]
      )

    Saved.refresh()
  end

  describe "for an instance admin" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    setup :register_and_log_in_user

    test "is the Instance level's second section, after General", %{conn: conn, scope: scope} do
      assert [
               %{key: :general},
               %{key: :features, label: "Features", path: "/instance/features"} | _
             ] = ApiaryWeb.Layouts.instance_sections(scope)

      {:ok, view, _html} = live(conn, ~p"/instance/features")

      assert has_element?(
               view,
               "#instance-tabs a#instance-tab-features[href='/instance/features'][aria-current='page']",
               "Features"
             )

      assert page_title(view) =~ "Features"
    end

    test "a row a feature, in the order of the features, with what it adds and needs",
         %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/instance/features")

      assert html =~ @intro
      assert row_ids(view) == Enum.map(Features.all(), &"feature-#{&1}")
      refute has_element?(view, "#features-env")

      assert text(view, "#feature-observability-title") == "Record and runs"
      assert text(view, "#feature-observability-name") == "observability"

      assert text(view, "#feature-observability-sentence") ==
               "The record, the runs with their terminals and timelines, the connections, and retention."

      refute has_element?(view, "#feature-observability-needs")
      refute has_element?(view, "#feature-observability-switch")
      assert text(view, "#feature-observability-reason") == "Every instance has it."

      assert text(view, "#feature-secrets-needs") == "Needs Security policy."

      assert text(view, "#feature-factory-needs") ==
               "Needs Record and runs, Security policy, and Secrets and variables."

      assert text(view, "#feature-workflow_model-needs") ==
               "Needs Record and runs, Security policy, Secrets and variables, and Work items."

      assert text(view, "#feature-organisation_variables-needs") ==
               "Needs Security policy, and Secrets and variables."

      # Until someone saves, every row is on, but the image registry and the instance
      # switch.
      assert has_element?(view, "#feature-security-switch[aria-checked='true']:not([disabled])")
      assert has_element?(view, "#feature-path_rules-switch[aria-checked='true']")
      refute has_element?(view, "#features-preview")
      assert has_element?(view, "#features-save button[type='submit']", "Save")
    end

    test "the instance switch: off until turned on, with what it needs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/features")

      assert text(view, "#feature-feature_visibility-title") == "Features by person"
      assert text(view, "#feature-feature_visibility-name") == "feature_visibility"

      assert text(view, "#feature-feature_visibility-sentence") ==
               "What a person is shown depends on who they are, not only on the organisation they are in."

      assert text(view, "#feature-feature_visibility-needs") == "Needs Record and runs."

      refute :feature_visibility in Features.enabled()
      refute has_element?(view, "#feature-feature_visibility-reason")

      assert has_element?(
               view,
               "#feature-feature_visibility-switch[aria-checked='false']:not([disabled])"
             )

      toggle(view, :feature_visibility)
      assert save(view) =~ "Features saved."
      assert :feature_visibility in Features.enabled()
    end

    # Operators running their clients is a flag of the server's config, not a feature: the
    # page has no row for it, and a save leaves it as the config has it.
    test "operator_infrastructure has no row and follows the config", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/features")
      refute has_element?(view, "#feature-operator_infrastructure")
      refute render(view) =~ "operator_infrastructure"
      refute :operator_infrastructure in Features.all()

      previous = Application.get_env(:apiary_pro, :operator_infrastructure)
      on_exit(fn -> Application.put_env(:apiary_pro, :operator_infrastructure, previous) end)
      Application.put_env(:apiary_pro, :operator_infrastructure, true)

      toggle(view, :feature_visibility)
      assert save(view) =~ "Features saved."
      assert ApiaryPro.Flags.operator_infrastructure?()

      Application.put_env(:apiary_pro, :operator_infrastructure, false)
      refute ApiaryPro.Flags.operator_infrastructure?()
    end

    test "a locked row shows why, and its switch cannot be turned", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/features")

      assert has_element?(view, "#feature-registry-switch[aria-checked='false'][disabled]")

      assert text(view, "#feature-registry-reason") ==
               "Set QORY_REGISTRY on the server to turn this on."

      refute has_element?(view, "#feature-factory-reason")

      Application.put_env(:apiary, :registry_setting, "registry.example.com")
      Application.put_env(:apiary, :installed_adapters, ["tracker"])
      {:ok, view, _html} = live(conn, ~p"/instance/features")

      assert has_element?(view, "#feature-registry-switch:not([disabled])")
      refute has_element?(view, "#feature-registry-reason")
      assert has_element?(view, "#feature-factory-switch[aria-checked='true'][disabled]")

      assert text(view, "#feature-factory-reason") ==
               "Work items stays on while adapters are set in the server's environment. Remove them there to turn it off."

      # What Work items needs is locked on with it, and names it.
      for feature <- [:security, :secrets] do
        assert has_element?(view, "#feature-#{feature}-switch[aria-checked='true'][disabled]")

        assert text(view, "#feature-#{feature}-reason") ==
                 "Work items needs it, and stays on while adapters are set in the server's environment. Remove them there to turn it off."
      end

      assert text(view, "#feature-observability-reason") == "Every instance has it."
      refute has_element?(view, "#feature-path_rules-reason")
      assert has_element?(view, "#feature-path_rules-switch:not([disabled])")
    end

    test "while QORY_FEATURES is set, it decides, and every switch is read only",
         %{conn: conn} do
      Application.put_env(:apiary, :features_setting, "all")
      {:ok, view, _html} = live(conn, ~p"/instance/features")

      assert text(view, "#features-env") ==
               "Set by the server's environment (QORY_FEATURES); change it there."

      assert has_element?(view, "#feature-security-switch[disabled]")
      refute has_element?(view, "#features-rows button[role='switch']:not([disabled])")
      refute has_element?(view, "#features-save")

      # A switch's click, sent all the same, changes nothing.
      render_click(view, "toggle", %{"feature" => "security"})
      assert has_element?(view, "#feature-security-switch[aria-checked='true']")
    end

    test "a switch changes the form; above Save, what changes with it", %{conn: conn} do
      store!(["observability"])
      {:ok, view, _html} = live(conn, ~p"/instance/features")

      assert has_element?(view, "#feature-factory-switch[aria-checked='false']")
      toggle(view, :factory)
      assert has_element?(view, "#feature-factory-switch[aria-checked='true']")
      assert has_element?(view, "#feature-security-switch[aria-checked='false']")

      assert text(view, "#features-preview-factory") ==
               "Turning on Work items also turns on Security policy, and Secrets and variables."

      # Nothing is saved until Save.
      assert Features.enabled() == [:observability]

      toggle(view, :factory)
      refute has_element?(view, "#features-preview")

      # A row that turns nothing else shows no line; one turned off names what needs it.
      store!(Enum.map(Features.all() -- [:registry], &to_string/1))
      {:ok, view, _html} = live(conn, ~p"/instance/features")
      toggle(view, :path_rules)
      refute has_element?(view, "#features-preview")

      toggle(view, :secrets)

      assert text(view, "#features-preview-secrets") ==
               "Turning off Secrets and variables also turns off Work items, Process versions, and Organisation secrets and variables."
    end

    test "a switch turned off turns off what needs it in the form; back on, they stay off",
         %{conn: conn} do
      store!(Enum.map(Features.all() -- [:registry], &to_string/1))
      before = Features.enabled()
      {:ok, view, _html} = live(conn, ~p"/instance/features")

      toggle(view, :secrets)

      for feature <- [:secrets, :factory, :workflow_model, :organisation_variables] do
        assert has_element?(view, "#feature-#{feature}-switch[aria-checked='false']"),
               inspect(feature)
      end

      assert has_element?(view, "#feature-security-switch[aria-checked='true']")

      # The line of the row turned off stays, and the rows it lists have none.
      assert text(view, "#features-preview-secrets") ==
               "Turning off Secrets and variables also turns off Work items, Process versions, and Organisation secrets and variables."

      refute has_element?(view, "#features-preview-factory")

      # Back on, the rows that need it stay off.
      toggle(view, :secrets)
      assert has_element?(view, "#feature-secrets-switch[aria-checked='true']")

      for feature <- [:factory, :workflow_model, :organisation_variables] do
        assert has_element?(view, "#feature-#{feature}-switch[aria-checked='false']"),
               inspect(feature)
      end

      assert text(view, "#features-preview-factory") ==
               "Turning off Work items also turns off Process versions."

      # Nothing is saved until Save.
      assert Features.enabled() == before
      assert %{features: ^before} = Saved.current()
    end

    test "a list of titles has a comma before and only with three or more, or an and in one" do
      alias ApiaryWeb.InstanceLive.Features, as: Page

      assert Page.titles([:factory, :workflow_model]) == "Work items and Process versions"

      assert Page.titles([:security, :secrets]) ==
               "Security policy, and Secrets and variables"

      assert Page.titles([:security, :factory, :workflow_model]) ==
               "Security policy, Work items, and Process versions"
    end

    test "with runs running, a change says how many", %{conn: conn, scope: scope} do
      Apiary.RunEventsFixtures.run_fixture(scope, %{state: "running"})
      {:ok, view, _html} = live(conn, ~p"/instance/features")
      refute has_element?(view, "#features-running")

      toggle(view, :path_rules)

      assert text(view, "#features-running") ==
               "1 run is running. It finishes with the features it started with."

      for _ <- 1..2, do: Apiary.RunEventsFixtures.run_fixture(scope, %{state: "running"})
      toggle(view, :path_rules)
      refute has_element?(view, "#features-running")
      toggle(view, :path_rules)

      assert text(view, "#features-running") ==
               "3 runs are running. They finish with the features they started with."
    end

    test "Save saves the form, and takes effect at once", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/features")
      toggle(view, :path_rules)
      html = save(view)

      assert html =~ "Features saved."
      refute :path_rules in Features.enabled()
      assert %{source: :saved, version: 1} = Saved.current()
      assert has_element?(view, "#feature-path_rules-switch[aria-checked='false']")
      refute has_element?(view, "#features-running")
    end

    test "a save made from an older read says so, and reads the list again",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/instance/features")

      # Another instance admin saves after this page read the list.
      {:ok, _} = Saved.save(scope, Features.enabled() -- [:path_rules], 0)

      toggle(view, :organisation_policy)
      html = save(view)

      # The flash shows the first sentence as its title, the rest under it.
      [title, rest] = String.split(@stale, ". ", parts: 2)
      assert html =~ title <> "."
      assert html =~ rest
      assert :organisation_policy in Features.enabled()
      assert has_element?(view, "#feature-organisation_policy-switch[aria-checked='true']")
      assert has_element?(view, "#feature-path_rules-switch[aria-checked='false']")

      # Read again, the page saves.
      toggle(view, :organisation_policy)
      assert save(view) =~ "Features saved."
      refute :organisation_policy in Features.enabled()
    end

    test "a save refused for a lock keeps the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/features")
      Application.put_env(:apiary, :installed_adapters, ["tracker"])

      toggle(view, :path_rules)
      toggle(view, :security)
      html = save(view)

      refute html =~ "Features saved."
      assert :security in Features.enabled()
      assert :path_rules in Features.enabled()

      # The form keeps its change; the rows locked since show their locks and reasons.
      assert has_element?(view, "#feature-path_rules-switch[aria-checked='false']")
      assert has_element?(view, "#feature-security-switch[aria-checked='true'][disabled]")
      assert has_element?(view, "#feature-security-reason")
      assert has_element?(view, "#feature-factory-reason")
    end

    test "Configuration links to the page under its list of features", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/configuration")

      assert text(view, "#config-features-link") ==
               "Turn features on or off in Instance settings › Features."

      assert has_element?(
               view,
               "#config-features-link a[href='/instance/features']",
               "Instance settings › Features"
             )
    end

    test "Configuration says the saved list decides, once an instance admin saved it",
         %{conn: conn, scope: scope} do
      {:ok, _} = Saved.save(scope, Features.enabled() -- [:path_rules], 0)
      {:ok, view, _html} = live(conn, ~p"/instance/configuration")

      assert text(view, "#config-features-source") ==
               "Saved in Instance settings › Features: QORY_FEATURES is not set."

      assert has_element?(view, "#config-features-source code", "QORY_FEATURES")

      # While the variable is set, it decides, saved list or not.
      Application.put_env(:apiary, :features_setting, "all")
      {:ok, view, _html} = live(conn, ~p"/instance/configuration")
      assert text(view, "#config-features-source") == "Set by QORY_FEATURES"
    end

    test "an open page follows a save: its menu at once, and away from a page turned off",
         %{conn: conn, scope: scope} do
      {:ok, overview, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")
      {:ok, policy, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/policy")
      {:ok, types, _html} = live(conn, ~p"/instance/workspace-types")
      assert has_element?(overview, "#nav-policy")

      {:ok, view, _html} = live(conn, ~p"/instance/features")
      assert has_element?(view, "#instance-tab-workspace_types")
      toggle(view, :security)
      save(view)

      refute has_element?(overview, "#nav-policy")
      refute has_element?(view, "#instance-tab-workspace_types")

      flash = assert_redirect(policy, ~p"/#{scope.organisation}")

      assert flash["error"] ==
               "That page is no longer shown in #{scope.organisation.name}."

      flash = assert_redirect(types, ~p"/instance/general")

      assert flash["error"] ==
               "That page is no longer shown: its feature is off in Instance settings › Features."
    end

    test "the save on the Activity page", %{conn: conn, scope: scope} do
      store!(["observability", "security", "secrets"])
      {:ok, _} = Saved.save(scope, ["observability", "security", "path_rules"], 1)

      {:ok, view, _html} = live(conn, "/#{scope.organisation.slug}/audit-log")
      render_async(view)

      {:ok, %{entries: [entry | _]}} =
        Apiary.Audit.list_entries(scope, %{action: "instance.features_save"})

      assert has_element?(view, "#filter-action-form li", "Features saved")
      assert text(view, "#entry-#{entry.id}-action") =~ "Saved the features"

      lines =
        view
        |> element("#entry-#{entry.id}-change")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("li, div, span")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert "Turned on: Paths in policy rules" in lines
      assert "Turned off: Secrets and variables" in lines
    end
  end

  describe "for anyone else" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    setup :register_and_log_in_user

    test "is not found for a member of the instance's organisation, with no menu item",
         %{conn: conn, scope: scope} do
      member = member_fixture(scope)
      refute Apiary.Access.instance_admin?(member.scope)
      refute Enum.any?(ApiaryWeb.Layouts.instance_sections(member.scope), &(&1.key == :features))

      conn = log_in_user(conn, member.user)
      assert_raise ApiaryWeb.NotFound, fn -> live(conn, ~p"/instance/features") end
    end
  end

  describe "for the owner of another organisation" do
    setup :register_and_log_in_user

    test "is not found", %{conn: conn, scope: scope} do
      refute Apiary.Access.instance_admin?(scope)
      assert_raise ApiaryWeb.NotFound, fn -> live(conn, ~p"/instance/features") end
    end
  end
end
