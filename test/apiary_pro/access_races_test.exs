defmodule ApiaryPro.AccessRacesTest do
  # A member's write of the security policy racing their removal from the workspace, which
  # takes away their reach there. Each side runs on a connection of its own, outside the
  # SQL sandbox, so each commits and each waits on the other's locks as it would in
  # production. Not async: what these tests commit is visible to every other test while
  # they run, and they delete it again before they end.
  #
  # The rule under test (`Apiary.Access.reload/2`, `Apiary.Policy`): a write takes the
  # workspace's lock, then reads the membership and the workspace access `FOR SHARE`. So a
  # removal that arrives while a write holds them waits for it, and a write that arrives
  # while a removal holds them waits, and then sees it. A write never commits on a reach
  # that a removal committed before it took away. The core's races of the writer's own
  # right are in `Apiary.AccessRacesTest`.
  #
  # Each test holds the first side's transaction open until the second side is seen, in
  # the database, waiting on a lock the first side holds (`pg_blocking_pids`): the order
  # is forced, not hoped for, and no test sleeps in the test process.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{Policy, Repo}
  alias Apiary.Audit.Entry
  alias Apiary.Policy.{Error, Rule}
  alias ApiaryPro.WorkspaceAccess

  setup_all :clean_up_leftovers
  setup :setup_races

  describe "a member's policy write racing their removal from the workspace" do
    # The security policy: left out of a run without the security feature.
    @describetag needs: :security

    test "the write first: it commits, and the removal waits for it" do
      %{owner: owner, writer: member} = organisation_with_member()

      {write, write_pid} = hold(fn -> allow(member.scope) end)
      assert {:ok, %Rule{}} = write.result

      removal =
        start(fn -> WorkspaceAccess.remove(owner, member.membership.id, owner.workspace.id) end)

      await_blocked(removal.backend, write_pid)
      commit(write)

      assert {:ok, %WorkspaceAccess.Row{}} = Task.await(removal.task)
      assert rule?(member)
      assert [_entry] = policy_entries(member)
    end

    test "the removal first: the write waits for it, and answers not found" do
      %{owner: owner, writer: member} = organisation_with_member()

      {removal, removal_pid} =
        hold(fn -> WorkspaceAccess.remove(owner, member.membership.id, owner.workspace.id) end)

      assert {:ok, %WorkspaceAccess.Row{}} = removal.result

      write = start(fn -> allow(member.scope) end)
      await_blocked(write.backend, removal_pid)
      commit(removal)

      assert {:error, %Error{reason: :not_found}} = Task.await(write.task)
      refute rule?(member)
      assert policy_entries(member) == []
    end
  end

  ## The organisation: an owner, and the member whose reach the race is about

  # An organisation of a fresh owner, and a member in its workspace, through an
  # invitation.
  defp organisation_with_member do
    %{scope: owner} = sign_up()
    %{user: user, scope: scope} = member(owner, :member)
    assert scope.membership.level == :member
    %{owner: owner, writer: %{scope: scope, membership: scope.membership, user: user}}
  end

  ## The write

  defp allow(scope), do: Policy.allow(scope, nil, %{host: "race.example"})

  defp rule?(writer),
    do:
      Repo.exists?(
        from r in Rule,
          where: r.workspace_id == ^writer.scope.workspace.id and r.host == "race.example"
      )

  # The policy's entries in the audit trail written by the person, oldest first.
  defp policy_entries(writer) do
    Repo.all(
      from e in Entry,
        where:
          e.organisation_id == ^writer.scope.organisation.id and
            e.actor_id == ^writer.user.id and like(e.action, "security_policy.%"),
        order_by: e.id,
        select: e.id
    )
  end
end
