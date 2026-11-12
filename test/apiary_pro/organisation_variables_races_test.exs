defmodule ApiaryPro.OrganisationVariablesRacesTest do
  # A write of the organisation's variables against a write of one of its workspaces'
  # variables, against another of the organisation's, and against a restore of a
  # workspace marked for deletion, each on a connection of its own, outside the SQL
  # sandbox: the first is held after its locks (`hold/1`), the second started and seen
  # waiting on it (`await_blocked/2`), then the first finishes in the same transaction
  # (`continue/2`), and the second goes through once it commits. Not async: what these
  # tests commit is visible to every other test while they run, and they delete it again
  # before they end. The level above is the edition's answer
  # (`ApiaryPro.Edition.above_workspace/1`): the organisation has no policy, so it is its
  # variables alone.
  #
  # The rule under test (`ApiaryPro.OrganisationVariables`, docs/access.md, The lock
  # order): both writes hold the organisation `FOR SHARE` first, then take the workspace
  # `FOR NO KEY UPDATE`, the organisation's write every workspace in use or restorable in
  # the order of their ids, so the second waits on the first's workspace row and holds
  # nothing the first's second half needs: nothing deadlocks, which Postgres's own count
  # of deadlocks shows, and the second write checks its names against what the first
  # wrote. Two writes of the organisation's take turns on its advisory lock where no
  # workspace orders them.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{Repo, Variables}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Workspace
  alias ApiaryPro.OrganisationVariables

  @moduletag needs: :organisation_variables

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    owner = sign_up()
    %{owner: owner.scope}
  end

  test "a workspace's write waits for the organisation's, which holds the workspace", ctx do
    before = deadlocks()
    owner = ctx.owner

    {write, write_pid} = hold(fn -> organisation_write_first_half(owner) end)

    theirs =
      start(fn ->
        Variables.create_variable(owner, :workspace, %{name: "log_level", value: "debug"})
      end)

    await_blocked(theirs.backend, write_pid)

    assert {:ok, _variable} =
             continue(write, fn ->
               OrganisationVariables.create(owner, %{name: "LOG_LEVEL", value: "info"})
             end)

    commit(write)

    # The workspace's write sees the organisation's name, and its other spelling is
    # refused.
    assert {:error, changeset} = Task.await(theirs.task)

    assert {"is %{name} in this organisation: use the same spelling", [name: "LOG_LEVEL"]} =
             changeset.errors[:name]

    assert deadlocks() == before
  end

  test "the organisation's write waits for a workspace's, which holds the workspace", ctx do
    before = deadlocks()
    owner = ctx.owner

    {write, write_pid} = hold(fn -> variables_write_first_half(owner) end)

    ours =
      start(fn -> OrganisationVariables.create(owner, %{name: "LOG_LEVEL", value: "info"}) end)

    await_blocked(ours.backend, write_pid)

    assert {:ok, _variable} =
             continue(write, fn ->
               Variables.create_variable(owner, :workspace, %{name: "log_level", value: "debug"})
             end)

    commit(write)

    # The organisation's write checks the workspaces as they are after the workspace's.
    assert {:error, changeset} = Task.await(ours.task)
    assert {"is %{name} in %{workspace}: use the same spelling", keys} = changeset.errors[:name]
    assert keys[:name] == "log_level"
    assert deadlocks() == before

    assert {:ok, []} = OrganisationVariables.list(owner)
  end

  test "two writes of the organisation's take turns, and the second sees the first", ctx do
    before = deadlocks()
    owner = ctx.owner
    names!(owner, 127)

    {write, write_pid} =
      hold(fn -> OrganisationVariables.create(owner, %{name: "ONE_MORE", value: "x"}) end)

    assert {:ok, _variable} = write.result

    ours =
      start(fn -> OrganisationVariables.create(owner, %{name: "TWO_MORE", value: "x"}) end)

    await_blocked(ours.backend, write_pid)
    commit(write)

    # Each alone is within the 128 names; the second sees the first, and is refused.
    assert {:error, changeset} = Task.await(ours.task)

    assert {"would raise a target's variables above %{limit}", [limit: 128]} =
             changeset.errors[:name]

    assert deadlocks() == before
  end

  test "two writes of an organisation with no workspace in use take turns all the same", ctx do
    before = deadlocks()
    owner = ctx.owner
    names!(owner, 127)

    # Its only workspace marked, and its purge started: no workspace orders the writes,
    # which the owner makes in the organisation, in no workspace.
    Repo.update_all(from(w in Workspace, where: w.organisation_id == ^owner.organisation.id),
      set: [
        deletion_marked_at: DateTime.utc_now(),
        purge_after: DateTime.utc_now(),
        purge_trigger: "grace_period",
        purge_started_at: DateTime.utc_now()
      ]
    )

    owner = %{owner | workspace: nil}

    {write, write_pid} =
      hold(fn -> OrganisationVariables.create(owner, %{name: "ONE_MORE", value: "x"}) end)

    assert {:ok, _variable} = write.result

    ours =
      start(fn -> OrganisationVariables.create(owner, %{name: "TWO_MORE", value: "x"}) end)

    await_blocked(ours.backend, write_pid)
    commit(write)

    assert {:error, changeset} = Task.await(ours.task)

    assert {"would raise a target's variables above %{limit}", [limit: 128]} =
             changeset.errors[:name]

    assert deadlocks() == before
  end

  test "the organisation's write waits for a restore, and checks the workspace restored", ctx do
    before = deadlocks()
    owner = ctx.owner
    platform = Apiary.OrganisationsFixtures.workspace_fixture(owner.organisation, "Platform")
    own!(platform, [{"log_level", "debug"}])
    {:ok, _} = Apiary.Deletion.delete_workspace(owner, platform.id, platform.slug)

    {restore, restore_pid} =
      hold(fn -> Apiary.Deletion.restore_workspace(owner, platform.id) end)

    assert {:ok, %Workspace{deletion_marked_at: nil}} = restore.result

    ours =
      start(fn -> OrganisationVariables.create(owner, %{name: "LOG_LEVEL", value: "info"}) end)

    await_blocked(ours.backend, restore_pid)
    commit(restore)

    assert {:error, changeset} = Task.await(ours.task)
    assert {"is %{name} in %{workspace}: use the same spelling", keys} = changeset.errors[:name]
    assert keys == [name: "log_level", workspace: "Platform"]
    assert deadlocks() == before
  end

  test "a restore waits for the organisation's write, which checked the workspace marked", ctx do
    before = deadlocks()
    owner = ctx.owner
    platform = Apiary.OrganisationsFixtures.workspace_fixture(owner.organisation, "Platform")
    own!(platform, [{"OWN_1", "x"}])
    {:ok, _} = Apiary.Deletion.delete_workspace(owner, platform.id, platform.slug)

    {write, write_pid} =
      hold(fn -> OrganisationVariables.create(owner, %{name: "LOG_LEVEL", value: "info"}) end)

    assert {:ok, _variable} = write.result

    theirs = start(fn -> Apiary.Deletion.restore_workspace(owner, platform.id) end)
    await_blocked(theirs.backend, write_pid)
    commit(write)

    assert {:ok, %Workspace{deletion_marked_at: nil}} = Task.await(theirs.task)
    assert deadlocks() == before
  end

  # The organisation's write, up to its question: the organisation's rows, then every
  # workspace of it in use or restorable, in the order of their ids
  # (`ApiaryPro.OrganisationVariables`); its second half is the whole write, whose locks
  # it holds already.
  defp organisation_write_first_half(%Scope{} = scope) do
    :ok = Apiary.Access.lock_places(scope)

    Repo.all(
      from w in Workspace,
        where: w.organisation_id == ^scope.organisation.id,
        order_by: w.id,
        lock: "FOR NO KEY UPDATE",
        select: w.id
    )

    :ok
  end

  # `count` names of the organisation's, written as rows.
  defp names!(%Scope{organisation: organisation}, count) do
    now = DateTime.utc_now()

    Repo.insert_all(
      OrganisationVariables.Variable,
      for n <- 1..count do
        %{
          id: Ecto.UUID.generate(),
          organisation_id: organisation.id,
          name: "NAME_#{n}",
          value: "x",
          locked: false,
          inserted_at: now,
          updated_at: now
        }
      end
    )
  end

  # A workspace's own variables, written as rows.
  defp own!(%Workspace{} = workspace, variables) do
    now = DateTime.utc_now()

    Repo.insert_all(
      Apiary.Variables.Variable,
      for {name, value} <- variables do
        %{
          id: Ecto.UUID.generate(),
          organisation_id: workspace.organisation_id,
          workspace_id: workspace.id,
          name: name,
          value: value,
          locked: false,
          inserted_at: now,
          updated_at: now
        }
      end
    )
  end

  # A workspace's variables write, up to its question (`Apiary.Variables`): the
  # organisation's rows, then the workspace.
  defp variables_write_first_half(%Scope{workspace: %Workspace{id: workspace_id}} = scope) do
    :ok = Apiary.Access.lock_places(scope)

    Repo.one!(
      from w in Workspace, where: w.id == ^workspace_id, lock: "FOR NO KEY UPDATE", select: w.id
    )

    :ok
  end

  # Postgres's own count of deadlocks it broke in this database.
  defp deadlocks do
    %{rows: [[count]]} =
      Repo.query!("SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()")

    count
  end
end
