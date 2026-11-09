defmodule ApiaryWeb.HarnessLiveProcessTest do
  @moduledoc """
  Workspace settings › Harness (`ApiaryWeb.HarnessLive`) with the feature
  `workflow_model`: the rows Source, Stack and Version with the commit in use, the
  switch Keep the process at the latest, the notice of a stopped update, Update from
  harness with its difference, Save, Try first and Cancel, and a harness repository
  pinned to a tag, with no switch. Workspace settings › Workflows > Details: the harness
  line with its commit and Open Harness, and the History rows of versions made from the
  harness.

  Not async: the tests serve the Qory harness at other commits, and set the instance's
  features, which are the whole node's.
  """
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Apiary.{Processes, Repo}
  alias Apiary.Harnesses.Qory
  alias Apiary.Organisations.Workspace
  alias Apiary.Processes.HarnessUpdate
  alias Apiary.QoryHarnessFixture

  @moduletag with_features: Apiary.Features.all()
  @moduletag :capture_log

  @process "modules/software-factory/process.yaml"
  @shape "st_p9w5cvh311"

  setup :register_and_log_in_user

  setup %{scope: scope} do
    %{path: workspace_path(scope, "/settings/harness")}
  end

  defp short(commit), do: String.slice(commit, 0, 7)

  # The Qory harness's main moved to a commit where Shape has a description and the
  # template lists the custom type spec, read as the refresh reads it.
  defp main_moved! do
    files =
      Map.update!(QoryHarnessFixture.files(), @process, fn process ->
        process
        |> String.replace(
          "      name: Shape\n",
          "      name: Shape\n      description: Plan it.\n"
        )
        |> Kernel.<>(
          "  - name: spec\n    base_view: document\n    size_limit: 65536\n    max_files: 1\n"
        )
      end)

    repository = QoryHarnessFixture.serve!(files)
    assert {:ok, commit} = Qory.read({:branch, "main"})
    assert commit == repository.commit
    commit
  end

  # A person's save of edits: Shape renamed Plan, which turns the switch off.
  defp edit!(scope) do
    document = Processes.current(scope.workspace).document

    stages =
      Enum.map(document["stages"], fn
        %{"id" => @shape} = stage -> %{stage | "name" => "Plan"}
        stage -> stage
      end)

    {:ok, version} = Processes.save(scope, scope.workspace, %{document | "stages" => stages})
    version
  end

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp keep(scope),
    do:
      Repo.one(
        from w in Workspace, where: w.id == ^scope.workspace.id, select: w.keep_process_latest
      )

  describe "the Qory harness on main" do
    test "shows Source, Stack and Version with the commit in use, and the switch on", ctx do
      {:ok, view, _html} = live(ctx.conn, ctx.path)
      commit = QoryHarnessFixture.commit()

      assert has_element?(view, "#settings-section-title", "Harness")
      assert text(view, "#harness-row-source-title") == "Qory harness"
      assert has_element?(view, ~s(#harness-row-source-link[href="#{Qory.git()}"]))
      assert has_element?(view, "#harness-row-stack", "software")
      assert text(view, "#harness-row-version-line") == "Follows main"

      assert text(view, "#harness-in-use") ==
               "Commit in use: #{short(commit)}, process version 1"

      refute has_element?(view, "#harness-now-at")
      assert has_element?(view, ~s(#harness-latest[aria-checked="true"]))

      assert text(view, "#harness-latest-description") ==
               "At each new commit on main, Qory Apiary saves it as a new version of the stages. Edits saved on the Workflows page stop it."

      refute has_element?(view, "#harness-stopped")

      assert text(view, "#harness-update-line p") ==
               "Compare version 1 of the stages with the process at main, then save it as a new version."

      assert has_element?(view, "#harness-update", "Update from harness")
      assert has_element?(view, "#workflow-stages-link", "Open Workflows")

      assert text(view, "#harness-about-versions") ==
               "A run uses the commit its process version came from. Keep the process at the latest moves that commit at each new commit on the branch. A fixed version uses that tag or commit."
    end

    test "the switch turns off and on again", ctx do
      {:ok, view, _html} = live(ctx.conn, ctx.path)

      view |> element("#harness-latest") |> render_click()
      assert has_element?(view, ~s(#harness-latest[aria-checked="false"]))
      assert keep(ctx.scope) == false

      view |> element("#harness-latest") |> render_click()
      assert has_element?(view, ~s(#harness-latest[aria-checked="true"]))
      assert keep(ctx.scope) == true
    end

    test "after saved edits: the notice once, then Update from harness and Save", ctx do
      edit!(ctx.scope)
      commit = main_moved!()

      {:ok, view, _html} = live(ctx.conn, ctx.path)

      assert has_element?(view, ~s(#harness-latest[aria-checked="false"]))

      assert text(view, "#harness-stopped") ==
               "Press Update from harness to bring in main at #{short(commit)}. Edits saved on the Workflows page stop the automatic update."

      refute has_element?(view, "#harness-now-at")

      view |> element("#harness-update") |> render_click()
      render_async(view)

      assert text(view, "#harness-update-title") == "Update from main at #{short(commit)}"
      assert text(view, "#harness-update-from") =~ "v2"
      assert text(view, "#harness-update-from") =~ short(QoryHarnessFixture.commit())
      assert text(view, "#harness-update-to") == "main#{short(commit)}"
      assert text(view, "#harness-update-summary") == "2 stage changes, 1 new artifact type"

      stages = text(view, "#harness-update-stages")
      assert stages =~ "stages2 changes"
      assert stages =~ "Renamed the stage Plan to Shape."
      assert stages =~ "Changed the description of Shape. +Added: Plan it."
      assert text(view, "#harness-update-types") == "artifact types1 new+Added:spec"
      refute has_element?(view, "#harness-update-stack")

      # No line was removed, so the hint on removed lines does not show.
      refute has_element?(view, "#harness-update-removed")

      assert text(view, "#harness-update-stay") ==
               "Work items in progress stay on version 2. Work items taken in after the save follow version 3."

      assert text(view, "#harness-update-switch") ==
               "Save also turns Keep the process at the latest on again."

      view |> element("#harness-update-save") |> render_click()

      assert text(view, "#harness-update-notice") ==
               "Saved as version 3. Work items taken in from now on use it."

      refute has_element?(view, "#harness-update-diff")
      refute has_element?(view, "#harness-stopped")
      assert has_element?(view, ~s(#harness-latest[aria-checked="true"]))
      assert text(view, "#harness-in-use") == "Commit in use: #{short(commit)}, process version 3"

      current = Processes.current(ctx.scope.workspace)
      assert current.number == 3
      assert current.template["commit"] == commit
      assert current.template["added_types"] == ["spec"]
    end

    test "a removed line shows the hint; Try first saves a trial; Cancel closes", ctx do
      # The edit drops Explore's output, which the harness has.
      document = Processes.current(ctx.scope.workspace).document

      stages =
        Enum.map(document["stages"], fn
          %{"name" => "Explore"} = stage -> %{stage | "outputs" => []}
          stage -> stage
        end)

      {:ok, _v2} =
        Processes.save(ctx.scope, ctx.scope.workspace, %{document | "stages" => stages})

      main_moved!()

      {:ok, view, _html} = live(ctx.conn, ctx.path)
      view |> element("#harness-update") |> render_click()
      render_async(view)
      assert has_element?(view, "#harness-update-diff")
      view |> element("#harness-update-cancel") |> render_click()
      refute has_element?(view, "#harness-update-diff")

      # Explore's output comes back from the harness: added lines only.
      view |> element("#harness-update") |> render_click()
      render_async(view)
      assert text(view, "#harness-update-stages") =~ "Changed the outputs of Explore. +Added:"
      refute has_element?(view, "#harness-update-removed")

      view |> element("#harness-update-try") |> render_click()

      assert text(view, "#harness-update-notice") ==
               "Saved as version 3, a trial. Assign work items to it on the Workflows page."

      assert Processes.current(ctx.scope.workspace).number == 2
      assert keep(ctx.scope) == false
    end

    test "the hint on removed lines, where the edits added what the harness has not", ctx do
      document = Processes.current(ctx.scope.workspace).document

      stages =
        Enum.map(document["stages"], fn
          %{"name" => "Build"} = stage ->
            %{stage | "outputs" => [%{"type" => "screenshot", "required" => false}]}

          stage ->
            stage
        end)

      {:ok, _v2} =
        Processes.save(ctx.scope, ctx.scope.workspace, %{document | "stages" => stages})

      {:ok, view, _html} = live(ctx.conn, ctx.path)
      view |> element("#harness-update") |> render_click()
      render_async(view)

      assert text(view, "#harness-update-stages") =~
               "Changed the outputs of Build. −Removed: screenshot, optional"

      assert text(view, "#harness-update-removed") ==
               "Check the removed lines before you save: they are edits saved on the Workflows page, and version 3 does not keep them."
    end
  end

  describe "a harness repository pinned to a tag" do
    setup %{scope: scope} do
      git = "https://code.example.com/acme/harness"

      Repo.insert!(%Apiary.Stacks.Stack{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        harness: "extends:\n  git: #{git}\n  ref: v2.4.0\n  stack: software\n",
        choice: :repository,
        version_kind: :tag,
        version_name: "v2.4.0"
      })

      commit = String.duplicate("7d1e2a9", 6) <> "abcd"
      v1 = Processes.current(scope.workspace)

      v1
      |> Ecto.Changeset.change(
        template: %{
          "source" => "repository",
          "git" => git,
          "commit" => commit,
          "module" => "software-factory",
          "stack" => "software",
          "type" => "qory.software",
          "version" => nil
        }
      )
      |> Repo.update!()

      %{git: git, commit: commit}
    end

    test "shows its address, Tag, the commit in use and no switch", ctx do
      {:ok, view, _html} = live(ctx.conn, ctx.path)

      assert text(view, "#harness-row-source-title") == "A harness repository"
      assert has_element?(view, ~s(#harness-row-source-link[href="#{ctx.git}"]))
      assert text(view, "#harness-row-version-line") == "Tag v2.4.0"

      assert text(view, "#harness-in-use") ==
               "Commit in use: #{short(ctx.commit)}, process version 1"

      refute has_element?(view, "#harness-latest")
      refute has_element?(view, "#harness-stopped")

      assert text(view, "#harness-update-line p") ==
               "Compare version 1 of the stages with the process at tag v2.4.0, then save it as a new version."
    end
  end

  describe "a member" do
    test "finds no Harness page", %{scope: scope} do
      %{user: user} = Apiary.OrganisationsFixtures.member_fixture(scope)
      conn = log_in_user(build_conn(), user)

      assert_raise ApiaryWeb.NotFound, fn ->
        live(conn, workspace_path(scope, "/settings/harness"))
      end
    end
  end

  describe "Workflows > Details" do
    test "the harness line with its commit and Open Harness, and the History rows", ctx do
      edit!(ctx.scope)
      commit = main_moved!()

      # Dana's Update from harness, then a version the switch saves at the same commit.
      {:ok, update} = HarnessUpdate.read(ctx.scope, ctx.scope.workspace)
      {:ok, _v3} = HarnessUpdate.save(ctx.scope, ctx.scope.workspace, update)

      path = workspace_path(ctx.scope, "/settings/workflows?tab=details")
      {:ok, view, _html} = live(ctx.conn, path)

      assert text(view, "#stages-harness") =~
               "Harness: Qory harness, stack software, commit #{short(commit)}"

      assert has_element?(view, "#stages-harness-open", "Open Harness")

      assert has_element?(
               view,
               ~s(#stages-harness-open[href="#{workspace_path(ctx.scope, "/settings/harness")}"])
             )

      assert text(view, "#stages-export-line") ==
               "Commit this file to a harness repository. Workspaces that use that harness get it at their next update."

      v3 = text(view, "#stages-version-3")
      assert v3 =~ ~r/Version 3 current .+, updated from main at #{short(commit)}, /
      assert v3 =~ "Renamed the stage Plan to Shape."
      assert v3 =~ "Changed the description of Shape."
      assert v3 =~ "Added the artifact type spec."

      assert text(view, "#stages-version-2") =~ "Renamed the stage Shape to Plan."
      assert text(view, "#stages-version-1") =~ "Copied from the workspace type"
    end

    test "a version the switch saved, with no change, has no change line", ctx do
      commit = main_moved!()
      {:ok, update} = HarnessUpdate.read(ctx.scope, ctx.scope.workspace)

      # The switch's save: the instance's scope, with no author, of the same document.
      scope = Apiary.Accounts.Scope.for_instance(ctx.scope.organisation, ctx.scope.workspace)
      unchanged = %{update | document: update.base.document, changes: []}
      {:ok, v2} = HarnessUpdate.save(scope, ctx.scope.workspace, unchanged)
      assert v2.author_id == nil

      path = workspace_path(ctx.scope, "/settings/workflows?tab=details")
      {:ok, view, _html} = live(ctx.conn, path)

      assert text(view, "#stages-version-2") =~
               ~r/^Version 2 current Updated from main at #{short(commit)}, \d+ \w+ \d{4} Added the artifact type spec\.$/

      refute has_element?(view, "#stages-version-2 li", "No change.")
    end
  end
end
