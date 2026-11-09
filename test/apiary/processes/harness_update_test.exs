defmodule Apiary.Processes.HarnessUpdateTest do
  # Update from harness: the difference between the current version and the Qory
  # harness's template at the version the workspace follows, its save as a version or a
  # trial, and the switch Keep the process at the latest, which saves a version at each
  # commit the refresh of the Qory harness reads. Not async: the tests serve the Qory
  # harness at other commits, and a refresh reads every workspace.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Artifacts, Processes, Repo, Stacks}
  alias Apiary.Audit.Entry
  alias Apiary.Harnesses.{Qory, QoryRefresh}
  alias Apiary.Organisations.Workspace
  alias Apiary.Processes.{HarnessUpdate, TypeTemplate, TypeTemplates, Version}
  alias Apiary.{PublicGitServer, QoryHarnessFixture}
  alias Apiary.Stacks.Stack
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :workflow_model
  @moduletag :capture_log

  @process "modules/software-factory/process.yaml"
  @shape "st_p9w5cvh311"
  @repository "https://code.example.com/acme/harness"

  # A workspace made from the Qory template at the fixture's commit, by its owner.
  setup do
    %{scope: scope, workspace: workspace} = sign_up_fixture()
    %{scope: scope, workspace: workspace}
  end

  # The fixture's files with the template's process.yaml changed by `fun`.
  defp files(fun), do: Map.update!(QoryHarnessFixture.files(), @process, fun)

  # The Qory harness's main moved to a commit of `files`, read as the refresh reads it.
  defp main_at!(files) do
    repository = QoryHarnessFixture.serve!(files)
    assert {:ok, commit} = Qory.read({:branch, "main"})
    assert commit == repository.commit
    commit
  end

  # The template with Shape described, and the custom type spec listed.
  defp described do
    files(fn process ->
      process
      |> String.replace("      name: Shape\n", "      name: Shape\n      description: Plan it.\n")
      |> Kernel.<>(
        "  - name: spec\n    base_view: document\n    size_limit: 65536\n    max_files: 1\n"
      )
    end)
  end

  defp versions(workspace),
    do: workspace |> Processes.list_versions() |> Enum.sort_by(& &1.number)

  defp keep(workspace),
    do: Repo.one(from w in Workspace, where: w.id == ^workspace.id, select: w.keep_process_latest)

  defp workspace_row(workspace), do: from(w in Workspace, where: w.id == ^workspace.id)

  defp git!(dir, args) do
    {_out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    :ok
  end

  # The workspace on a harness repository at `branch`, served as public with the Qory
  # fixture's files, its version 1 made from the repository's first commit, and its switch
  # turned on: the repository, `%{dir, commit}`.
  defp repository_harness!(workspace, branch, opts \\ []) do
    unique = %{".test-#{System.unique_integer([:positive])}" => ""}
    repository = PublicGitServer.repository!(Map.merge(QoryHarnessFixture.files(), unique), opts)
    PublicGitServer.serve(%{@repository => repository.dir})

    Repo.insert!(%Stack{
      organisation_id: workspace.organisation_id,
      workspace_id: workspace.id,
      choice: :repository,
      version_kind: :branch,
      version_name: branch,
      harness: "extends:\n  git: #{@repository}\n  ref: #{branch}\n  stack: software\n"
    })

    v1 = Processes.current(workspace)

    Repo.update!(
      Ecto.Changeset.change(v1,
        template: %{
          "source" => "repository",
          "git" => @repository,
          "commit" => repository.commit,
          "module" => "software-factory",
          "stack" => "software",
          "type" => v1.template["type"],
          "version" => nil
        }
      )
    )

    {1, _rows} = Repo.update_all(workspace_row(workspace), set: [keep_process_latest: true])
    repository
  end

  # A person's save of edits: Shape renamed Plan.
  defp edit!(scope, workspace) do
    document = Processes.current(workspace).document

    stages =
      Enum.map(document["stages"], fn
        %{"id" => @shape} = stage -> %{stage | "name" => "Plan"}
        stage -> stage
      end)

    {:ok, version} = Processes.save(scope, workspace, %{document | "stages" => stages})
    version
  end

  describe "read/2" do
    test "compares the current version with main's template: stages, types and stack", ctx do
      v1 = Processes.current(ctx.workspace)

      {1, _rows} =
        Repo.update_all(from(w in Workspace, where: w.id == ^ctx.workspace.id),
          set: [
            shown_standard_types:
              Artifacts.Type.standard_names() -- ["mockup" | Artifacts.Type.always_on()]
          ]
        )

      commit = main_at!(described())

      assert {:ok, update} = HarnessUpdate.read(ctx.scope, ctx.workspace)

      assert %{
               source: :qory,
               version: {:branch, "main"},
               commit: ^commit,
               stack: nil,
               changes: [{:description_changed, @shape, %{from: nil, to: "Plan it."}}]
             } = update

      assert update.in_use == QoryHarnessFixture.commit()
      assert update.base.id == v1.id

      assert update.added_types == [
               %{"name" => "mockup"},
               %{
                 "name" => "spec",
                 "base_view" => "document",
                 "size_limit" => 65_536,
                 "max_files" => 1
               }
             ]

      assert update.template == %{
               "source" => "qory",
               "git" => Qory.git(),
               "commit" => commit,
               "module" => "software-factory",
               "stack" => "software",
               "type" => "qory.software",
               "version" => nil,
               "ref_kind" => "branch",
               "ref" => "main"
             }
    end

    test "lists the stack of the template where it differs from the workspace's", ctx do
      main_at!(files(&String.replace(&1, "stack: software\n", "stack: core\n", global: false)))

      assert {:ok, %{stack: %{from: "software", to: "core"}}} =
               HarnessUpdate.read(ctx.scope, ctx.workspace)
    end

    test "is no change at the commit the version came from", ctx do
      assert {:ok, %{changes: [], added_types: [], stack: nil, commit: commit}} =
               HarnessUpdate.read(ctx.scope, ctx.workspace)

      assert commit == QoryHarnessFixture.commit()
    end

    test "a member who is no owner or admin reads nothing", ctx do
      member = member_fixture(ctx.scope).scope
      assert HarnessUpdate.read(member, ctx.workspace) == {:error, :forbidden}
    end

    test "a harness repository with no template the process came from has none", ctx do
      Repo.insert!(%Stack{
        organisation_id: ctx.workspace.organisation_id,
        workspace_id: ctx.workspace.id,
        choice: :repository,
        version_kind: :branch,
        version_name: "main",
        harness: "extends:\n  git: #{@repository}\n  stack: core\n"
      })

      assert HarnessUpdate.read(ctx.scope, ctx.workspace) == {:error, :no_template}
    end
  end

  describe "save/4" do
    test "saves the template as the current version, with its types and its commit", ctx do
      commit = main_at!(described())
      {:ok, update} = HarnessUpdate.read(ctx.scope, ctx.workspace)

      assert {:ok, %Version{number: 2, status: :current} = version} =
               HarnessUpdate.save(ctx.scope, ctx.workspace, update)

      assert version.template["commit"] == commit
      assert version.author_id == ctx.scope.user.id
      assert Processes.stage(version, @shape)["description"] == "Plan it."
      assert Processes.harness_template(version)["commit"] == commit
      assert %{name: "spec", base_view: :document} = Artifacts.type(ctx.workspace, "spec")

      assert [%Entry{details: %{"change" => "save", "harness_commit" => ^commit}}] =
               Repo.all(
                 from e in Entry,
                   where: e.workspace_id == ^ctx.workspace.id and e.action == "process.edit"
               )
    end

    test "drops the edits saved on the Workflows page, and turns the switch on again", ctx do
      edit!(ctx.scope, ctx.workspace)
      assert keep(ctx.workspace) == false
      refute HarnessUpdate.keep_latest?(ctx.workspace)

      {:ok, update} = HarnessUpdate.read(ctx.scope, ctx.workspace)
      assert [{:stage_renamed, @shape, %{from: "Plan", to: "Shape"}}] = update.changes

      assert {:ok, version} = HarnessUpdate.save(ctx.scope, ctx.workspace, update)
      assert version.document == Qory.template(QoryHarnessFixture.commit()).process
      assert keep(ctx.workspace) == true
    end

    test "Try first saves a trial, and leaves the current version and the switch", ctx do
      edit!(ctx.scope, ctx.workspace)
      main_at!(described())
      {:ok, update} = HarnessUpdate.read(ctx.scope, ctx.workspace)

      assert {:ok, %Version{status: :trial, number: 3}} =
               HarnessUpdate.save(ctx.scope, ctx.workspace, update, trial: true)

      assert Processes.current(ctx.workspace).number == 2
      assert keep(ctx.workspace) == false
    end

    test "Try first adds the artifact types and copies no stack", ctx do
      main_at!(
        described()
        |> Map.update!(
          @process,
          &String.replace(&1, "stack: software\n", "stack: core\n", global: false)
        )
      )

      {:ok, update} = HarnessUpdate.read(ctx.scope, ctx.workspace)
      assert update.stack == %{from: "software", to: "core"}

      assert {:ok, %Version{status: :trial}} =
               HarnessUpdate.save(ctx.scope, ctx.workspace, update, trial: true)

      assert %{name: "spec"} = Artifacts.type(ctx.workspace, "spec")
      assert Workspace.qory_stack(Repo.reload!(ctx.workspace)) == "software"
    end

    test "is stale once another version is current", ctx do
      {:ok, update} = HarnessUpdate.read(ctx.scope, ctx.workspace)
      main_at!(described())
      edit!(ctx.scope, ctx.workspace)

      assert HarnessUpdate.save(ctx.scope, ctx.workspace, update) == {:error, :stale}
      assert length(versions(ctx.workspace)) == 2
    end

    test "is stale once the harness choice changed after the read", ctx do
      main_at!(files(&String.replace(&1, "stack: software\n", "stack: core\n", global: false)))
      {:ok, update} = HarnessUpdate.read(ctx.scope, ctx.workspace)

      row =
        Repo.insert!(%Stack{
          organisation_id: ctx.workspace.organisation_id,
          workspace_id: ctx.workspace.id,
          choice: :repository,
          version_kind: :branch,
          version_name: "main",
          harness: "extends:\n  git: #{@repository}\n  stack: software\n"
        })

      assert HarnessUpdate.save(ctx.scope, ctx.workspace, update) == {:error, :stale}
      assert length(versions(ctx.workspace)) == 1
      assert Repo.reload!(row).harness == row.harness

      # A pin of the same harness is another choice too.
      Repo.delete!(row)
      {:ok, update} = HarnessUpdate.read(ctx.scope, ctx.workspace)

      Stacks.put_stack(
        ctx.scope,
        {:workspace, ctx.workspace},
        ~s(extends:\n  git: "#{Qory.git()}"\n  ref: "v2.4.0"\n  stack: "software"\n),
        choice: :qory,
        version: {:tag, "v2.4.0"}
      )

      assert HarnessUpdate.save(ctx.scope, ctx.workspace, update) == {:error, :stale}
      assert length(versions(ctx.workspace)) == 1
    end

    test "two saves in a row: the second adds no artifact types", ctx do
      main_at!(described())
      {:ok, update} = HarnessUpdate.read(ctx.scope, ctx.workspace)
      assert [%{"name" => "spec"}] = update.added_types
      {:ok, v2} = HarnessUpdate.save(ctx.scope, ctx.workspace, update)
      assert v2.template["added_types"] == ["spec"]

      commit = main_at!(Map.put(described(), "README.yaml", "a: 1\n"))
      {:ok, update} = HarnessUpdate.read(ctx.scope, ctx.workspace)
      assert %{added_types: [], changes: [], commit: ^commit} = update

      assert {:ok, %Version{number: 3} = v3} =
               HarnessUpdate.save(ctx.scope, ctx.workspace, update)

      refute Map.has_key?(v3.template, "added_types")
      assert v3.template["commit"] == commit
    end

    test "the same process at the same commit is unchanged", ctx do
      {:ok, update} = HarnessUpdate.read(ctx.scope, ctx.workspace)

      assert {:error, [%{error: :unchanged}]} =
               HarnessUpdate.save(ctx.scope, ctx.workspace, update)
    end

    test "copies the template's stack to the workspace", ctx do
      main_at!(files(&String.replace(&1, "stack: software\n", "stack: core\n", global: false)))
      {:ok, update} = HarnessUpdate.read(ctx.scope, ctx.workspace)

      assert {:ok, _version} = HarnessUpdate.save(ctx.scope, ctx.workspace, update)
      assert Repo.reload!(ctx.workspace).qory_stack == nil
      assert Workspace.qory_stack(Repo.reload!(ctx.workspace)) == "core"
    end
  end

  describe "work items" do
    test "in progress keep their version after an update; a new one takes the new version",
         ctx do
      v1 = Processes.current(ctx.workspace)
      in_progress = work_item_fixture(ctx.scope)

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^in_progress.id),
          set: [process_version_id: v1.id]
        )

      main_at!(described())
      assert :ok = HarnessUpdate.follow_all()
      assert %Version{number: 2} = v2 = Processes.current(ctx.workspace)

      assert Processes.version_for(Repo.reload!(in_progress)).id == v1.id
      assert Processes.version_for(work_item_fixture(ctx.scope)).id == v2.id
    end
  end

  describe "the switch" do
    test "is on for the Qory harness, off for a harness repository, and absent when pinned",
         ctx do
      assert HarnessUpdate.following(ctx.workspace) == {:qory, "main"}
      assert HarnessUpdate.keep_latest?(ctx.workspace)

      assert %{following: "main", keep_latest: true, number: 1, head: head, in_use: in_use} =
               HarnessUpdate.status(ctx.workspace)

      assert head == QoryHarnessFixture.commit()
      assert in_use == head

      row =
        Repo.insert!(%Stack{
          organisation_id: ctx.workspace.organisation_id,
          workspace_id: ctx.workspace.id,
          choice: :repository,
          version_kind: :branch,
          version_name: "main",
          harness: "extends:\n  git: #{@repository}\n  stack: core\n"
        })

      assert HarnessUpdate.following(ctx.workspace) == {:repository, "main"}
      refute HarnessUpdate.keep_latest?(ctx.workspace)
      assert %{keep_latest: false, in_use: nil, head: nil} = HarnessUpdate.status(ctx.workspace)

      Repo.update!(Ecto.Changeset.change(row, version_kind: :tag, version_name: "v2.4.0"))

      assert HarnessUpdate.following(ctx.workspace) == nil
      refute HarnessUpdate.keep_latest?(ctx.workspace)
      assert %{keep_latest: nil, version: {:tag, "v2.4.0"}} = HarnessUpdate.status(ctx.workspace)

      assert HarnessUpdate.set_keep_latest(ctx.scope, ctx.workspace, true) == {:error, :pinned}
    end

    test "is off where version 1 is a workspace type an instance admin saved", ctx do
      newest = TypeTemplates.newest("qory.software")

      Repo.insert!(%TypeTemplate{
        type: "qory.software",
        number: newest.number + 1,
        document: newest.document,
        based_on: newest.number,
        author_id: ctx.scope.user.id
      })

      %{workspace: workspace} = sign_up_fixture()
      v1 = Processes.current(workspace)
      assert %{"source" => "qory", "version" => version} = v1.template
      assert version == newest.number + 1
      assert v1.author_id == nil
      assert keep(workspace) == nil
      refute HarnessUpdate.keep_latest?(workspace)
      assert %{keep_latest: false} = HarnessUpdate.status(workspace)

      main_at!(described())
      assert :ok = HarnessUpdate.follow_all()
      assert length(versions(workspace)) == 1
      assert length(versions(ctx.workspace)) == 2
    end

    test "a person turns it off and on, with an audit entry each", ctx do
      assert {:ok, _workspace} = HarnessUpdate.set_keep_latest(ctx.scope, ctx.workspace, false)
      refute HarnessUpdate.keep_latest?(ctx.workspace)
      assert {:ok, _workspace} = HarnessUpdate.set_keep_latest(ctx.scope, ctx.workspace, true)
      assert HarnessUpdate.keep_latest?(ctx.workspace)

      assert [false, true] =
               Repo.all(
                 from e in Entry,
                   where: e.workspace_id == ^ctx.workspace.id and e.action == "process.edit",
                   order_by: [asc: e.inserted_at, asc: e.id],
                   select: e.details["on"]
               )

      member = member_fixture(ctx.scope).scope
      assert HarnessUpdate.set_keep_latest(member, ctx.workspace, false) == {:error, :forbidden}
    end

    test "the refresh saves a version at main's commit, with no author", ctx do
      commit = main_at!(described())

      assert :ok = QoryRefresh.perform(nil, %Oban.Job{args: %{}})

      assert [_v1, %Version{number: 2, status: :current, author_id: nil} = v2] =
               versions(ctx.workspace)

      assert %{"commit" => ^commit, "ref_kind" => "branch", "ref" => "main"} = v2.template
      assert Processes.stage(v2, @shape)["description"] == "Plan it."
      assert Artifacts.type(ctx.workspace, "spec")

      # Read again at the same commit: nothing is due.
      assert :ok = HarnessUpdate.follow_all()
      assert length(versions(ctx.workspace)) == 2
    end

    test "a commit that leaves the process unchanged is a version too", ctx do
      commit = main_at!(Map.put(QoryHarnessFixture.files(), "README.yaml", "a: 1\n"))
      assert :ok = HarnessUpdate.follow_all()

      assert [v1, v2] = versions(ctx.workspace)
      assert v2.template["commit"] == commit
      assert Processes.diff(v1, v2) == []
    end

    test "edits saved on the Workflows page stop it", ctx do
      edit!(ctx.scope, ctx.workspace)
      main_at!(described())
      assert :ok = HarnessUpdate.follow_all()
      assert length(versions(ctx.workspace)) == 2

      assert %{keep_latest: false, in_use: in_use, head: head} =
               HarnessUpdate.status(ctx.workspace)

      assert in_use == QoryHarnessFixture.commit()
      assert head != in_use
    end

    test "a trial of edits leaves it on until the trial becomes current, then turns it off",
         ctx do
      document = Processes.current(ctx.workspace).document
      stages = Enum.map(document["stages"], &Map.put(&1, "description", "Edited."))

      {:ok, trial} =
        Processes.save(ctx.scope, ctx.workspace, %{document | "stages" => stages}, trial: true)

      assert HarnessUpdate.keep_latest?(ctx.workspace)

      {:ok, _current} = Processes.make_current(ctx.scope, trial)
      assert keep(ctx.workspace) == false
    end

    test "a trial from the harness, made current, turns it on", ctx do
      edit!(ctx.scope, ctx.workspace)
      main_at!(described())
      {:ok, update} = HarnessUpdate.read(ctx.scope, ctx.workspace)
      {:ok, trial} = HarnessUpdate.save(ctx.scope, ctx.workspace, update, trial: true)
      assert keep(ctx.workspace) == false

      {:ok, current} = Processes.make_current(ctx.scope, trial)
      assert current.number == 3
      assert keep(ctx.workspace) == true
    end

    test "follows a harness repository's branch, read as public at each refresh", ctx do
      repository = repository_harness!(ctx.workspace, "main")

      assert :ok = QoryRefresh.perform(nil, %Oban.Job{args: %{}})
      assert length(versions(ctx.workspace)) == 1

      commit = PublicGitServer.commit!(repository.dir, described())
      assert :ok = QoryRefresh.perform(nil, %Oban.Job{args: %{}})

      assert [_v1, %Version{number: 2, status: :current, author_id: nil} = v2] =
               versions(ctx.workspace)

      assert %{
               "source" => "repository",
               "git" => @repository,
               "commit" => ^commit,
               "ref_kind" => "branch",
               "ref" => "main"
             } = v2.template

      assert Processes.stage(v2, @shape)["description"] == "Plan it."
      assert Artifacts.type(ctx.workspace, "spec")
    end

    test "follows a branch other than main", ctx do
      repository = repository_harness!(ctx.workspace, "next", branches: ["next"])

      # A commit on main is not the followed branch's.
      PublicGitServer.commit!(repository.dir, described())
      assert :ok = HarnessUpdate.follow_all()
      assert length(versions(ctx.workspace)) == 1

      git!(repository.dir, ["checkout", "-q", "next"])
      commit = PublicGitServer.commit!(repository.dir, described())
      assert :ok = HarnessUpdate.follow_all()

      assert [_v1, v2] = versions(ctx.workspace)
      assert %{"commit" => ^commit, "ref" => "next"} = v2.template
    end

    test "is off for a harness repository until a person turns it on", ctx do
      repository = repository_harness!(ctx.workspace, "main")
      {1, _rows} = Repo.update_all(workspace_row(ctx.workspace), set: [keep_process_latest: nil])

      PublicGitServer.commit!(repository.dir, described())
      assert :ok = HarnessUpdate.follow_all()
      assert length(versions(ctx.workspace)) == 1
    end

    test "a harness repository that cannot be read saves nothing, and logs why", ctx do
      repository_harness!(ctx.workspace, "main")
      PublicGitServer.serve(%{}, answer: fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

      log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = HarnessUpdate.follow_all() end)
      assert length(versions(ctx.workspace)) == 1
      assert log =~ "the process was not updated from the harness workspace=#{ctx.workspace.id}"
    end

    test "a process that fails Processes.validate/1 saves nothing", ctx do
      main_at!(files(&String.replace(&1, "id: st_6ns22c4pav", "id: #{@shape}")))

      assert {:error, [%{error: _error} | _more]} = HarnessUpdate.follow(ctx.workspace)
      assert :ok = HarnessUpdate.follow_all()
      assert length(versions(ctx.workspace)) == 1
    end

    test "artifact types that fail the template check save nothing", ctx do
      # Explore outputs a type the template does not list.
      main_at!(
        files(&String.replace(&1, "        - type: proposal\n", "        - type: blueprint\n"))
      )

      assert {:error, {:types, [_refusal | _more]}} = HarnessUpdate.follow(ctx.workspace)
      assert :ok = HarnessUpdate.follow_all()
      assert length(versions(ctx.workspace)) == 1
    end

    test "a machine type the instance does not have saves nothing", ctx do
      # The read of a harness file refuses any machine type but `default`
      # (Apiary.Harnesses.Reader), before the check of the instance's machine types.
      main_at!(files(&String.replace(&1, "  machine: default\n", "  machine: gpu-large\n")))

      assert HarnessUpdate.follow(ctx.workspace) == {:error, :no_template}
      assert :ok = HarnessUpdate.follow_all()
      assert length(versions(ctx.workspace)) == 1
    end

    test "a template that fails a check saves nothing", ctx do
      main_at!(files(&String.replace(&1, "type: qory.software\n", "type: qory.other\n")))
      assert :ok = HarnessUpdate.follow_all()
      assert length(versions(ctx.workspace)) == 1
    end

    test "a workspace made with no template is not updated", ctx do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ManyWorkspaces)

      {:ok, workspace} =
        Apiary.Organisations.create_workspace(ctx.scope, %{
          "name" => "Data",
          "domain" => "software"
        })

      main_at!(described())
      assert :ok = HarnessUpdate.follow_all()
      assert length(versions(workspace)) == 1
      assert length(versions(ctx.workspace)) == 2
    end

    @tag with_features: [:observability, :security, :secrets, :factory]
    test "does nothing with the feature workflow_model off", ctx do
      main_at!(described())
      assert :ok = HarnessUpdate.follow_all()
      assert length(Repo.all(from v in Version, where: v.workspace_id == ^ctx.workspace.id)) == 1
    end

    test "the refresh saves the process without the stack of a harness the organisation shares",
         ctx do
      Stacks.put_stack(
        ctx.scope,
        {:organisation, %Apiary.Organisations.Organisation{id: ctx.workspace.organisation_id}},
        ~s(extends:\n  git: "#{Qory.git()}"\n  ref: "main"\n  stack: "software"\n),
        choice: :qory,
        version: {:branch, "main"}
      )

      commit =
        main_at!(files(&String.replace(&1, "stack: software\n", "stack: core\n", global: false)))

      log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = HarnessUpdate.follow_all() end)

      assert [_v1, %Version{number: 2, author_id: nil} = v2] = versions(ctx.workspace)
      assert v2.template["commit"] == commit
      assert Stacks.shared(%Apiary.Organisations.Organisation{id: ctx.workspace.organisation_id})
      assert Workspace.qory_stack(Repo.reload!(ctx.workspace)) == "software"

      assert [_line] =
               Regex.scan(~r/without its stack.*workspace=#{ctx.workspace.id}/, log)

      # Nothing is due at the same commit: no second line.
      log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = HarnessUpdate.follow_all() end)
      refute log =~ "without its stack"
    end

    test "a stack to copy into the harness the organisation shares fails the save", ctx do
      Stacks.put_stack(
        ctx.scope,
        {:organisation, %Apiary.Organisations.Organisation{id: ctx.workspace.organisation_id}},
        ~s(extends:\n  git: "#{Qory.git()}"\n  ref: "main"\n  stack: "software"\n),
        choice: :qory,
        version: {:branch, "main"}
      )

      main_at!(files(&String.replace(&1, "stack: software\n", "stack: core\n", global: false)))
      {:ok, update} = HarnessUpdate.read(ctx.scope, ctx.workspace)
      assert HarnessUpdate.save(ctx.scope, ctx.workspace, update) == {:error, :shared}
      assert length(versions(ctx.workspace)) == 1
    end
  end
end
