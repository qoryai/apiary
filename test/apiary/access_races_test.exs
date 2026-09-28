defmodule Apiary.AccessRacesTest do
  # A write of the security policy racing a change of the writer's own right to make it:
  # a demotion, leaving the organisation. Each side runs on a connection of its own,
  # outside the SQL sandbox, so each commits and each waits on the other's locks as it
  # would in production. Not async: what these tests commit is visible to every other test
  # while they run, and they delete it again before they end.
  #
  # The rule under test (`Apiary.Access.reload/2`, `Apiary.Policy`): a write takes the
  # workspace's lock, then reads the membership `FOR SHARE`. So a demotion or a leaving
  # that arrives while a write holds them waits for it, and a write that arrives while
  # such a change holds them waits, and then sees it. A write never commits on a right
  # that a change committed before it took away.
  #
  # Each test holds the first side's transaction open until the second side is seen, in
  # the database, waiting on a lock the first side holds (`pg_blocking_pids`): the order
  # is forced, not hoped for, and no test sleeps in the test process.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{Organisations, Policy, Repo}
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.{Membership, Workspace}
  alias Apiary.Policy.{Error, Rule}

  setup_all :clean_up_leftovers
  setup :setup_races

  describe "a policy write racing the writer's demotion" do
    # The security policy: left out of a run without the security feature.
    @describetag needs: :security

    # Two demotions that each take away the write's right: an admin made a member no longer
    # sets the mode, and an owner made an admin no longer locks a rule.
    for {from, to, write} <- [{:admin, :member, :set_mode}, {:owner, :admin, :lock}] do
      @from from
      @to to
      @write write

      test "#{from} to #{to}, the write (#{write}) first: it commits, and the demotion waits for it" do
        %{owner: owner, writer: writer} = organisation_with(@from)
        args = write_args(@write, owner)

        {write, write_pid} = hold(fn -> write(@write, writer.scope, args) end)
        assert {:ok, _} = write.result

        demotion =
          start(fn -> Organisations.set_member_level(owner, writer.membership.id, @to) end)

        await_blocked(demotion.backend, write_pid)
        commit(write)

        assert {:ok, %Membership{level: @to}} = Task.await(demotion.task)
        assert written?(@write, writer, args)
        assert [_entry] = policy_entries(writer)
      end

      test "#{from} to #{to}, the demotion first: the write waits for it, and is refused" do
        %{owner: owner, writer: writer} = organisation_with(@from)
        args = write_args(@write, owner)
        entries = policy_entries(writer)

        {demotion, demotion_pid} =
          hold(fn -> Organisations.set_member_level(owner, writer.membership.id, @to) end)

        assert {:ok, %Membership{level: @to}} = demotion.result

        write = start(fn -> write(@write, writer.scope, args) end)
        await_blocked(write.backend, demotion_pid)
        commit(demotion)

        assert {:error, %Error{reason: :forbidden}} = Task.await(write.task)
        refute written?(@write, writer, args)
        assert policy_entries(writer) == entries
      end
    end
  end

  describe "a member's policy write racing their leaving the organisation" do
    # The security policy: left out of a run without the security feature.
    @describetag needs: :security

    test "the write first: it commits, and the leaving waits for it" do
      %{writer: member} = organisation_with(:member)

      {write, write_pid} = hold(fn -> allow(member.scope) end)
      assert {:ok, %Rule{}} = write.result

      leaving = start(fn -> Organisations.remove_member(member.scope, member.membership.id) end)
      await_blocked(leaving.backend, write_pid)
      commit(write)

      assert {:ok, %Membership{}} = Task.await(leaving.task)
      assert rule?(member)
      assert [_entry] = policy_entries(member)
      refute Repo.get(Membership, member.membership.id)
    end

    test "the leaving first: the write waits for it, and is refused" do
      %{writer: member} = organisation_with(:member)

      {leaving, leaving_pid} =
        hold(fn -> Organisations.remove_member(member.scope, member.membership.id) end)

      assert {:ok, %Membership{}} = leaving.result

      write = start(fn -> allow(member.scope) end)
      await_blocked(write.backend, leaving_pid)
      commit(leaving)

      # A person with no membership where the scope is: the role refuses them.
      assert {:error, %Error{reason: :forbidden}} = Task.await(write.task)
      refute rule?(member)
      assert policy_entries(member) == []
    end
  end

  describe "two owners demoting each other at once" do
    # Each demotion locks the organisation's owners before it asks whether its own owner
    # may change a level: the second waits for the first, then finds its owner an admin,
    # who may not. The organisation keeps an owner either way.
    test "the first is made; the second, by an owner no longer, is refused" do
      %{owner: first, writer: second} = organisation_with(:owner)

      {made, made_pid} =
        hold(fn -> Organisations.set_member_level(first, second.membership.id, :admin) end)

      assert {:ok, %Membership{level: :admin}} = made.result

      refused =
        start(fn -> Organisations.set_member_level(second.scope, first.membership.id, :admin) end)

      await_blocked(refused.backend, made_pid)
      commit(made)

      assert {:error, :forbidden} = Task.await(refused.task)
      assert owners(first) == [first.membership.id]
    end

    test "started together, exactly one is made, and the organisation keeps one owner" do
      for _round <- 1..10 do
        %{owner: first, writer: second} = organisation_with(:owner)

        [one, other] =
          [
            fn -> Organisations.set_member_level(first, second.membership.id, :admin) end,
            fn -> Organisations.set_member_level(second.scope, first.membership.id, :admin) end
          ]
          |> together()

        assert Enum.count([one, other], &match?({:ok, %Membership{level: :admin}}, &1)) == 1
        assert Enum.count([one, other], &(&1 == {:error, :forbidden})) == 1

        # The one left an owner is the one whose demotion was made.
        expected = if match?({:ok, _}, one), do: first, else: second
        assert owners(first) == [expected.membership.id]
      end
    end
  end

  ## The organisation: an owner, and the person whose right the race is about

  # An organisation of a fresh owner, and a second person in its workspace at `level`: a
  # member through an invitation, then made an admin or an owner by the owner, so the
  # fixture does not lean on the level an invitation carries.
  defp organisation_with(level) do
    %{scope: owner} = sign_up()
    %{user: user, scope: scope} = member(owner, level)
    assert scope.membership.level == level
    %{owner: owner, writer: %{scope: scope, membership: scope.membership, user: user}}
  end

  ## The writes

  defp write_args(:set_mode, _owner), do: "enforce"

  # A rule for the owner to lock, made before the race.
  defp write_args(:lock, owner) do
    {:ok, rule} = Policy.deny(owner, nil, %{host: "locked.example"})
    rule
  end

  defp write(:set_mode, scope, mode), do: Policy.set_mode(scope, mode)
  defp write(:lock, scope, %Rule{} = rule), do: Policy.lock(scope, rule)

  defp written?(:set_mode, writer, mode),
    do: Repo.get!(Workspace, writer.scope.workspace.id).egress_mode == mode

  defp written?(:lock, _writer, %Rule{id: id}), do: Repo.get!(Rule, id).locked

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

  defp owners(scope) do
    Repo.all(
      from m in Membership,
        where: m.organisation_id == ^scope.organisation.id and m.level == :owner,
        select: m.id
    )
  end
end
