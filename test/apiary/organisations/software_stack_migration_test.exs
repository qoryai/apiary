defmodule Apiary.Organisations.SoftwareStackMigrationTest do
  # The migration that records the stack `software` on the workspaces of the software
  # domain made before `workspaces.qory_stack`, and in their Qory harness rows
  # (`RecordTheSoftwareStackOfOlderWorkspaces`), run down and up again inside the test's
  # transaction, which rolls it all back. It changes `workspaces` and `stacks` under every
  # other test, so it is not async.
  use Apiary.DataCase, async: false

  # Running a migration down and up again while later ones are applied makes Ecto warn
  # that an older migration ran after a newer one. The log is kept from the output and
  # shown only when a test fails.
  @moduletag :capture_log

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures

  alias Apiary.{Processes, Stages}
  alias Apiary.Organisations.Workspace
  alias Apiary.Processes.Version
  alias Apiary.Runs.Target
  alias Apiary.Stacks.{Sources, Stack}
  alias Apiary.WorkItems.WorkItem

  @version 20_261_106_090_000
  @migration Apiary.Repo.Migrations.RecordTheSoftwareStackOfOlderWorkspaces
  @options [log: false, migration_lock: false]

  # A time before 20261102160000 ran on any database.
  @before_the_column ~U[2026-10-31 12:00:00.000000Z]

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_record_the_software_stack_of_older_workspaces.exs")
      |> Code.require_file()
    end

    :ok
  end

  defp up! do
    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, @options)
    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, @options)
  end

  # The scope's workspace as one made before `qory_stack`: no stack, and version 1 as the
  # backfill of 20261031090500 wrote it, the type's default with no source.
  defp older!(scope) do
    made_with(scope, @before_the_column, %{"type" => "qory.software", "version" => 1})
  end

  # The scope's workspace as one made before `qory_stack` from a template of a harness
  # repository.
  defp older_from_repository!(scope) do
    made_with(scope, @before_the_column, %{
      "source" => "repository",
      "git" => "https://code.example.com/acme/harness"
    })
  end

  # The scope's workspace as one `Apiary.Organisations.create_workspace/2` makes after
  # `qory_stack`: no stack, and version 1 the type's default with no source.
  defp later_with_no_stack!(scope) do
    made_with(scope, DateTime.utc_now(), %{"type" => "qory.software", "version" => 1})
  end

  defp made_with(scope, inserted_at, template) do
    id = scope.workspace.id

    {1, _} =
      Repo.update_all(from(w in Workspace, where: w.id == ^id),
        set: [qory_stack: nil, inserted_at: inserted_at]
      )

    {1, _} =
      Repo.update_all(from(v in Version, where: v.workspace_id == ^id and v.number == 1),
        set: [template: template]
      )

    %{scope | workspace: Repo.reload!(scope.workspace)}
  end

  # A second workspace of the scope's organisation, made after `qory_stack` with no stack.
  defp second_workspace!(scope) do
    workspace = workspace_fixture(scope.organisation)
    assert workspace.qory_stack == nil
    workspace
  end

  # A Qory harness row of the scope's organisation at `stack`, as `Apiary.Stacks.Sources`
  # writes it: the workspace's by default, the organisation's with `shared: true`, or the
  # row of a target of the workspace.
  defp qory_row!(scope, stack, place \\ []) do
    workspace_id = if place[:shared], do: nil, else: scope.workspace.id

    Repo.insert!(%Stack{
      organisation_id: scope.organisation.id,
      workspace_id: workspace_id,
      target_id: place[:target] && place[:target].id,
      choice: :qory,
      version_kind: :branch,
      version_name: "main",
      harness:
        "extends:\n  git: \"https://github.com/qoryai/harness\"\n" <>
          "  ref: \"main\"\n  stack: \"#{stack}\"\n"
    })
  end

  # The row of `workspace` that chose a harness repository.
  defp repository_row!(scope, workspace) do
    Repo.insert!(%Stack{
      organisation_id: scope.organisation.id,
      workspace_id: workspace.id,
      choice: :repository,
      version_kind: :branch,
      version_name: "main",
      harness: "extends:\n  git: \"https://code.example.com/acme/harness\"\n"
    })
  end

  defp target!(scope) do
    Repo.insert!(%Target{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      system: "system.example",
      path: "team/place",
      first_seen_at: DateTime.utc_now()
    })
  end

  defp stack_of(%Workspace{} = workspace), do: Repo.reload!(workspace).qory_stack
  defp stack_of(%Stack{} = row), do: row |> Repo.reload!() |> Map.fetch!(:harness) |> stack_line()

  defp stack_line(harness) do
    [_, stack] = Regex.run(~r/\n  stack: "([^"]+)"\n/, harness)
    stack
  end

  test "up records software on an older workspace, its Qory row and its organisation's" do
    older = older!(scope_fixture())
    workspace_row = qory_row!(older, "core")
    shared = qory_row!(older, "core", shared: true)

    assert stack_of(older.workspace) == nil
    up!()

    assert stack_of(older.workspace) == "software"
    assert stack_of(workspace_row) == "software"
    assert stack_of(shared) == "software"
    assert %{choice: :qory, stack: "software"} = Sources.chosen(Repo.reload!(older.workspace))
  end

  test "up leaves a workspace made from a harness repository's template, or after the column" do
    from_repository = older_from_repository!(scope_fixture())
    later = later_with_no_stack!(scope_fixture())
    later_row = qory_row!(later, "core")
    template = scope_fixture()
    assert stack_of(template.workspace) == "software"

    up!()

    assert stack_of(from_repository.workspace) == nil
    assert stack_of(later.workspace) == nil
    assert stack_of(later_row) == "core"
    assert stack_of(template.workspace) == "software"
  end

  test "up rewrites a shared row only when no workspace reads it at core after up" do
    # A second workspace with no stack and no row reads the shared row at `core`.
    read = older!(scope_fixture())
    second_workspace!(read)
    read_shared = qory_row!(read, "core", shared: true)

    # A second workspace with a row of its workspace reads that row instead.
    unread = older!(scope_fixture())
    repository_row!(unread, second_workspace!(unread))
    unread_shared = qory_row!(unread, "core", shared: true)

    up!()

    assert stack_of(read_shared) == "core"
    assert stack_of(read.workspace) == "software"
    assert stack_of(unread_shared) == "software"
  end

  test "up leaves a row of a target, and a row at another stack" do
    older = older!(scope_fixture())
    target_row = qory_row!(older, "core", target: target!(older))
    other = qory_row!(older, "authoring")
    before = Repo.reload!(other).harness

    up!()

    assert stack_of(target_row) == "core"
    assert Repo.reload!(other).harness == before
    assert stack_of(older.workspace) == "software"
  end

  @tag needs: [:factory, :workflow_model]
  test "a work item that waits on an older workspace starts on Check again after up" do
    scope = older!(scope_fixture())
    :ok = Processes.record_declared(scope.workspace, [])
    work_item = Apiary.StagesFixtures.taken_in_fixture(scope)

    assert work_item.stage_state == :waiting_workflow
    assert Stages.check_workflows(scope, work_item) == {:error, :still_missing}

    up!()

    scope = %{scope | workspace: Repo.reload!(scope.workspace)}
    assert {:ok, %WorkItem{stage_state: :running}} = Stages.check_workflows(scope, work_item)
  end
end
