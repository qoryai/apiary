defmodule Apiary.SuspensionRacesTest do
  # A write of the security policy racing the suspension of the writer's membership, which
  # takes away their right to make it. Each side runs on a connection of its own, outside
  # the SQL sandbox, so each commits and each waits on the other's locks as it would in
  # production. Not async: what these tests commit is visible to every other test while
  # they run, and they delete it again before they end.
  #
  # The rule under test (`Apiary.Organisations.suspend_member/2`,
  # `Apiary.Access.reload/2`): a write reads the membership `FOR SHARE`; a suspension
  # updates the membership. So a suspension that arrives while a write holds it waits for
  # it, and a write that arrives while a suspension holds it waits, and then sees it: a
  # write never commits on a right a suspension committed before it took away.
  #
  # Each test holds the first side's transaction open until the second side is seen, in
  # the database, waiting on a lock the first side holds (`pg_blocking_pids`).
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{Organisations, Policy, Repo}
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.Membership
  alias Apiary.Policy.{Error, Rule}

  # The security policy: left out of a run without the security feature.
  @moduletag needs: :security

  setup_all :clean_up_leftovers
  setup :setup_races

  # An organisation with an owner and a member who writes the policy.
  setup do
    %{scope: owner} = sign_up()
    %{user: user, scope: scope} = member(owner, :member)

    %{
      owner: owner,
      writer: %{scope: scope, membership: scope.membership, user: user}
    }
  end

  test "the write first, then the membership's suspension: the suspension waits, and the write commits",
       ctx do
    {write, write_pid} = hold(fn -> allow(ctx.writer.scope) end)
    assert {:ok, %Rule{}} = write.result

    suspension = start(fn -> suspend(ctx) end)
    await_blocked(suspension.backend, write_pid)
    commit(write)

    assert {:ok, _suspended} = Task.await(suspension.task)
    assert suspended?(ctx)
    assert rule?(ctx.writer)
    assert [_entry] = policy_entries(ctx.writer)
  end

  test "the membership's suspension first, then the write: the write waits, and is refused",
       ctx do
    {suspension, suspension_pid} = hold(fn -> suspend(ctx) end)
    assert {:ok, _suspended} = suspension.result

    write = start(fn -> allow(ctx.writer.scope) end)
    await_blocked(write.backend, suspension_pid)
    commit(suspension)

    # No membership that counts: forbidden.
    assert {:error, %Error{reason: :forbidden}} = Task.await(write.task)
    assert suspended?(ctx)
    refute rule?(ctx.writer)
    assert policy_entries(ctx.writer) == []
  end

  defp suspend(ctx), do: Organisations.suspend_member(ctx.owner, ctx.writer.membership.id)

  defp suspended?(ctx), do: Repo.get!(Membership, ctx.writer.membership.id).suspended_at != nil

  defp allow(scope), do: Policy.allow(scope, nil, %{host: "race.example"})

  defp rule?(writer),
    do:
      Repo.exists?(
        from r in Rule,
          where: r.workspace_id == ^writer.scope.workspace.id and r.host == "race.example"
      )

  # The policy's entries in the audit trail written by the person.
  defp policy_entries(writer) do
    Repo.all(
      from e in Entry,
        where:
          e.organisation_id == ^writer.scope.organisation.id and
            e.actor_id == ^writer.user.id and like(e.action, "security_policy.%"),
        select: e.id
    )
  end
end
