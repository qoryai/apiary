defmodule ApiaryPro.OrganisationPolicyRacesTest do
  # A write of the organisation's policy against a write of one of its workspaces'
  # policy, each paused half way on a connection of its own, outside the SQL sandbox: the
  # first is held after its locks (`hold/1`), the second started and seen waiting on it
  # (`await_blocked/2`), then the first finishes in the same transaction (`continue/2`),
  # and the second goes through once it commits. Not async: what these tests commit is
  # visible to every other test while they run, and they delete it again before they end.
  #
  # The rule under test (`ApiaryPro.OrganisationPolicy`, docs/access.md, The lock order):
  # both writes hold the organisation `FOR SHARE` first, then take the workspace
  # `FOR NO KEY UPDATE`, the organisation's write every workspace in the order of their
  # ids, so the second waits on the first's workspace row and holds nothing the first's
  # second half needs: nothing deadlocks, which Postgres's own count of deadlocks shows,
  # and the second write resolves against what the first wrote.
  use ExUnit.Case, async: false
  @before_compile Apiary.TestSetup

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{Policy, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Workspace
  alias ApiaryPro.OrganisationPolicy

  @moduletag needs: :organisation_policy

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    owner = sign_up()
    %{owner: owner.scope, workspace: owner.workspace}
  end

  test "a workspace's write waits for the organisation's, which holds the workspace", ctx do
    before = deadlocks()
    owner = ctx.owner

    {write, write_pid} = hold(fn -> organisation_write_first_half(owner) end)

    theirs = start(fn -> Policy.allow(owner, nil, %{host: "cdn.example"}) end)
    await_blocked(theirs.backend, write_pid)

    assert {:ok, _rule} =
             continue(write, fn -> OrganisationPolicy.deny(owner, %{host: "paste.example"}) end)

    commit(write)

    assert {:ok, _rule} = Task.await(theirs.task)
    assert deadlocks() == before

    # The organisation's deny, rendered first, and the workspace's allow after it, on the
    # version 1 the workspace got when it was created.
    assert {:ok, configuration} = Policy.current_configuration(owner, nil)
    assert configuration.version == 3

    egress = Jason.decode!(configuration.document)["security_policy"]["egress"]
    assert egress["deny"] == ["paste.example"]
    assert egress["allow"] == ["cdn.example"]
  end

  test "the organisation's write waits for a workspace's, which holds the workspace", ctx do
    before = deadlocks()
    owner = ctx.owner

    {write, write_pid} = hold(fn -> policy_write_first_half(owner) end)

    ours = start(fn -> OrganisationPolicy.deny(owner, %{host: "paste.example"}) end)
    await_blocked(ours.backend, write_pid)

    assert {:ok, _rule} =
             continue(write, fn -> Policy.allow(owner, nil, %{host: "cdn.example"}) end)

    commit(write)

    assert {:ok, _rule} = Task.await(ours.task)
    assert deadlocks() == before

    assert {:ok, configuration} = Policy.current_configuration(owner, nil)
    assert configuration.version == 3

    assert %{
             items: [
               %{action: "above_changed"},
               %{action: "rule_added"},
               %{action: "first_version"}
             ]
           } = Policy.list_changes(owner, nil, 1)
  end

  # The organisation's write, up to its question: the organisation's rows, then every
  # workspace of it (`ApiaryPro.OrganisationPolicy`); its second half is the whole write,
  # whose locks it holds already.
  defp organisation_write_first_half(%Scope{} = scope) do
    :ok = Apiary.Access.lock_places(scope)

    ids =
      Repo.all(
        from w in Workspace,
          where: w.organisation_id == ^scope.organisation.id,
          order_by: w.id,
          select: w.id
      )

    {:ok, _workspaces} = Policy.lock_workspaces(scope, ids)
    :ok
  end

  # Postgres's own count of deadlocks it broke in this database.
  defp deadlocks do
    %{rows: [[count]]} =
      Repo.query!("SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()")

    count
  end

  # A workspace's policy write, up to its question (`Apiary.Policy`).
  defp policy_write_first_half(%Scope{workspace: %Workspace{id: workspace_id}} = scope) do
    :ok = Apiary.Access.lock_places(scope)

    Repo.one!(
      from w in Workspace, where: w.id == ^workspace_id, lock: "FOR NO KEY UPDATE", select: w.id
    )

    :ok
  end
end
