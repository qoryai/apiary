defmodule ApiaryPro.PeopleRowsRacesTest do
  # The people locks a change takes at its one point (`ApiaryPro.Tenants.lock_rows/1`)
  # against other changes, each on a connection of its own, outside the SQL sandbox, so
  # each commits and each waits on the other's locks as it would in production. Not async:
  # what these tests commit is visible to every other test while they run, and they delete
  # it again before they end.
  #
  # The rule under test is the lock order of docs/access.md: the organisation rows, then
  # the people locks in the order of their ids, then workspaces, memberships and accounts.
  # A write in a client that relies on its person's level in the operator holds the
  # operator's people lock `FOR SHARE`; a change of the operator's people locks it
  # `FOR UPDATE`; an account's deletion and suspension lock those of the account's
  # organisations `FOR UPDATE`. So the second of two such changes waits for the first, and
  # then sees it, and nothing deadlocks, which Postgres's own count of deadlocks shows.
  #
  # Each test holds the first side's transaction open until the second side is seen, in
  # the database, waiting on a lock the first side holds (`pg_blocking_pids`): the order
  # is forced, not hoped for. A side paused half way runs its second half once the other
  # waits on it (`continue/2`), what a deadlock needs.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races
  import ApiaryPro.Races

  alias Apiary.{Access, Accounts, Deletion, Organisations, OrganisationsFixtures, Repo}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.{Membership, Organisation}
  alias ApiaryPro.{Flags, Grants, Operators, Suspensions, Tenants, Transfers}
  alias ApiaryPro.Tenants.{PeopleLock, Tenant}

  @moduletag needs: :managed_organisations

  setup_all :clean_up_leftovers
  setup :setup_races

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    Flags.put_feature_visibility(false)
  end

  # An operator, made one as the product makes one, its owner and a second owner, and an
  # admin of it who reads its client through it; the client, with its owner and an admin
  # of its own; and an instance admin. The instance admin's membership is inserted as it
  # is, and goes with their account; their entries in the instance organisation's trail
  # are deleted when the test ends.
  setup do
    admin = sign_up()
    instance_organisation = ApiaryPro.Organisations.instance_organisation()

    Repo.insert!(%Membership{
      organisation_id: instance_organisation.id,
      user_id: admin.user.id,
      level: :owner
    })

    on_exit(fn -> clean_up_instance_entries(instance_organisation.id, admin.user.id) end)

    operator = sign_up()

    Repo.update_all(from(t in Tenant, where: t.organisation_id == ^operator.organisation.id),
      set: [kind: :operator]
    )

    operator_row = Organisation |> Repo.get!(operator.organisation.id) |> Tenants.put()
    {:ok, _features} = Grants.written_out(operator_row, :operator)
    in_operator = scope_in(operator.user, operator_row)

    second_owner = member(operator.scope, :owner)
    person = member(operator.scope, :admin)

    client = client(in_operator)
    client_admin = member(client.owner.scope, :admin)

    %{
      instance_admin: scope_in(admin.user, instance_organisation),
      operator: operator_row,
      in_operator: in_operator,
      second_owner: second_owner,
      person: person,
      client: client.organisation,
      workspace: client.workspace,
      client_owner: client.owner,
      client_admin: client_admin,
      person_in_client: scope_in(person.user, client.organisation, client.workspace)
    }
  end

  describe "a change of an operator's people against a write in its client that relies on it" do
    # Each change of the person's membership in the operator, made by its owner, and what
    # the person's level in the operator is once it is made: nil for none.
    @changes [
      level: :member,
      removal: nil,
      leaving: nil,
      suspension: nil
    ]

    for {change, after_level} <- @changes do
      @change change
      @after_level after_level

      test "the #{change} first: the write waits, and reads the person's level as it left it",
           ctx do
        before = deadlocks()
        {held, held_pid} = hold(fn -> change(@change, ctx) end)
        assert {:ok, %Membership{}} = held.result

        write = start(fn -> locked_reload(ctx.person_in_client) end)
        await_blocked(write.backend, held_pid)
        commit(held)

        assert {:ok, scope} = Task.await(write.task)
        assert operator_level(scope) == @after_level
        assert deadlocks() == before
      end

      test "the write first: the #{change} waits for it, and is made after", ctx do
        before = deadlocks()
        {write, write_pid} = hold(fn -> locked_reload(ctx.person_in_client) end)
        assert operator_level(write.result) == :admin

        held = start(fn -> change(@change, ctx) end)
        await_blocked(held.backend, write_pid)
        commit(write)

        assert {:ok, %Membership{}} = Task.await(held.task)
        assert deadlocks() == before
      end
    end

    test "an activation first: the write waits, and reads the person's level again", ctx do
      {:ok, _} = Organisations.suspend_member(ctx.in_operator, ctx.person.membership.id)
      before = deadlocks()

      {held, held_pid} =
        hold(fn -> Organisations.activate_member(ctx.in_operator, ctx.person.membership.id) end)

      assert {:ok, %Membership{suspended_at: nil}} = held.result

      write = start(fn -> locked_reload(ctx.person_in_client) end)
      await_blocked(write.backend, held_pid)
      commit(held)

      assert {:ok, scope} = Task.await(write.task)
      assert operator_level(scope) == :admin
      assert deadlocks() == before
    end

    test "the write first: an activation waits for it", ctx do
      {:ok, _} = Organisations.suspend_member(ctx.in_operator, ctx.person.membership.id)
      before = deadlocks()

      {write, write_pid} = hold(fn -> locked_reload(ctx.person_in_client) end)
      assert operator_level(write.result) == nil

      held =
        start(fn -> Organisations.activate_member(ctx.in_operator, ctx.person.membership.id) end)

      await_blocked(held.backend, write_pid)
      commit(write)

      assert {:ok, %Membership{suspended_at: nil}} = Task.await(held.task)
      assert deadlocks() == before
    end

    test "an acceptance of the operator's invitation first: the write waits, and reaches the client",
         ctx do
      %{user: joining} = sign_up()
      token = invite(ctx.in_operator, joining)
      in_client = %{Scope.for_user(joining) | organisation: ctx.client, workspace: ctx.workspace}
      before = deadlocks()

      {held, held_pid} = hold(fn -> Organisations.accept_invitation(joining, token) end)
      assert {:ok, %Membership{}} = held.result

      write = start(fn -> locked_reload(in_client) end)
      await_blocked(write.backend, held_pid)
      commit(held)

      assert {:ok, scope} = Task.await(write.task)
      assert operator_level(scope) == :member
      assert deadlocks() == before
    end

    test "the write first: an acceptance of the operator's invitation waits for it", ctx do
      %{user: joining} = sign_up()
      token = invite(ctx.in_operator, joining)
      before = deadlocks()

      {write, write_pid} = hold(fn -> locked_reload(ctx.person_in_client) end)
      held = start(fn -> Organisations.accept_invitation(joining, token) end)
      await_blocked(held.backend, write_pid)
      commit(write)

      assert {:ok, %Membership{}} = Task.await(held.task)
      assert deadlocks() == before
    end
  end

  describe "a change of the instance organisation's people, the instance organisation an operator" do
    # The instance organisation is an operator where the instance was set up with the
    # managed organisations; a client of it, created by the instance admin.
    setup ctx do
      instance_organisation = ApiaryPro.Organisations.instance_organisation()
      assert Tenants.operator?(instance_organisation)

      client = client(ctx.instance_admin)
      %{user: person} = sign_up()
      on_exit(fn -> clean_up_entries_naming(instance_organisation.id, person.id) end)

      %{
        instance_client: client.organisation,
        person: person,
        in_instance_client: %{
          Scope.for_user(person)
          | organisation: client.organisation,
            workspace: client.workspace
        }
      }
    end

    test "an instance admin granted first: the write in its client waits, and reaches it", ctx do
      before = deadlocks()
      {held, held_pid} = hold(fn -> Organisations.grant_instance_admin(ctx.person) end)
      assert {:ok, %{granted?: true}} = held.result

      write = start(fn -> locked_reload(ctx.in_instance_client) end)
      await_blocked(write.backend, held_pid)
      commit(held)

      assert {:ok, scope} = Task.await(write.task)
      assert operator_level(scope) == :owner
      assert deadlocks() == before
    end

    test "an instance admin revoked first: the write in its client waits, and reads it", ctx do
      {:ok, _} = Organisations.grant_instance_admin(ctx.person)
      before = deadlocks()

      {held, held_pid} = hold(fn -> Organisations.revoke_instance_admin(ctx.person) end)
      assert {:ok, %Membership{level: :member}} = held.result

      write = start(fn -> locked_reload(ctx.in_instance_client) end)
      await_blocked(write.backend, held_pid)
      commit(held)

      assert {:ok, scope} = Task.await(write.task)
      assert operator_level(scope) == :member
      assert deadlocks() == before
    end
  end

  describe "while the operator owns its clients" do
    setup do: Flags.put_operator_infrastructure(true)

    # An owner of the operator demotes its admin, who, through the operator, demotes the
    # owner in the client, where the owner is an admin too: each holds the operator's
    # people lock first, so neither holds a membership the other waits for.
    setup ctx do
      Repo.insert!(%Membership{
        organisation_id: ctx.client.id,
        user_id: ctx.in_operator.user.id,
        level: :admin
      })

      owner_in_client = scope_in(ctx.in_operator.user, ctx.client, ctx.workspace)
      %{owner_in_client: owner_in_client}
    end

    test "the demotion in the operator first: the admin's demotion in the client waits, and is refused",
         ctx do
      before = deadlocks()
      {demotion, demotion_pid} = hold(fn -> Organisations.lock_owners(ctx.in_operator) end)

      in_client =
        start(fn ->
          Organisations.set_member_level(
            ctx.person_in_client,
            ctx.owner_in_client.membership.id,
            :member
          )
        end)

      await_blocked(in_client.backend, demotion_pid)

      assert {:ok, %Membership{level: :member}} =
               continue(demotion, fn ->
                 Organisations.set_member_level(
                   ctx.in_operator,
                   ctx.person.membership.id,
                   :member
                 )
               end)

      commit(demotion)

      assert {:error, :forbidden} = Task.await(in_client.task)
      assert deadlocks() == before
    end

    test "the demotion in the client first: the demotion in the operator waits, and both are made",
         ctx do
      before = deadlocks()
      {in_client, in_client_pid} = hold(fn -> Organisations.lock_owners(ctx.person_in_client) end)

      demotion =
        start(fn ->
          Organisations.set_member_level(ctx.in_operator, ctx.person.membership.id, :member)
        end)

      await_blocked(demotion.backend, in_client_pid)

      assert {:ok, %Membership{level: :member}} =
               continue(in_client, fn ->
                 Organisations.set_member_level(
                   ctx.person_in_client,
                   ctx.owner_in_client.membership.id,
                   :member
                 )
               end)

      commit(in_client)

      assert {:ok, %Membership{level: :member}} = Task.await(demotion.task)
      assert deadlocks() == before
    end

    test "two owners of the operator demote each other: the second waits, and is refused", ctx do
      before = deadlocks()
      second = ctx.second_owner

      {first, first_pid} =
        hold(fn ->
          Organisations.set_member_level(ctx.in_operator, second.membership.id, :admin)
        end)

      assert {:ok, %Membership{level: :admin}} = first.result

      demotion =
        start(fn ->
          Organisations.set_member_level(
            second.scope,
            ctx.in_operator.membership.id,
            :admin
          )
        end)

      await_blocked(demotion.backend, first_pid)
      commit(first)

      assert {:error, :forbidden} = Task.await(demotion.task)
      assert deadlocks() == before
    end

    test "two admins of the client demote each other at once: nothing deadlocks", ctx do
      other = member(ctx.client_owner.scope, :admin)
      before = deadlocks()

      answers =
        together([
          fn ->
            Organisations.set_member_level(
              ctx.client_admin.scope,
              other.membership.id,
              :member
            )
          end,
          fn ->
            Organisations.set_member_level(other.scope, ctx.client_admin.membership.id, :member)
          end
        ])

      assert Enum.any?(answers, &match?({:ok, %Membership{level: :member}}, &1))
      refute Enum.any?(answers, &match?({:error, %Postgrex.Error{}}, &1))
      assert deadlocks() == before
    end

    test "the operator's owner's account suspended first: their change in the client waits, and is refused",
         ctx do
      owner = ctx.second_owner
      in_client = scope_in(owner.user, ctx.client, ctx.workspace)
      before = deadlocks()

      {suspension, suspension_pid} =
        hold(fn -> Suspensions.suspend_account(ctx.instance_admin, owner.user.id) end)

      assert {:ok, %{user: %User{}}} = suspension.result

      change =
        start(fn ->
          Organisations.set_member_level(in_client, ctx.client_admin.membership.id, :member)
        end)

      # It waits at the operator's people lock, the suspension's, before it reads the
      # account the suspension also holds.
      await_blocked(change.backend, suspension_pid)
      assert waits_on(change.backend) == "people_locks"
      commit(suspension)

      # Then it reads the owner's account suspended, and may not change the client.
      assert {:error, :forbidden} = Task.await(change.task)
      assert Repo.get!(Membership, ctx.client_admin.membership.id).level == :admin
      assert deadlocks() == before
    end

    test "the operator's owner's change in the client first: their account's suspension waits for it",
         ctx do
      owner = ctx.second_owner
      in_client = scope_in(owner.user, ctx.client, ctx.workspace)
      before = deadlocks()

      {change, change_pid} =
        hold(fn ->
          Organisations.set_member_level(in_client, ctx.client_admin.membership.id, :member)
        end)

      assert {:ok, %Membership{level: :member}} = change.result

      suspension =
        start(fn -> Suspensions.suspend_account(ctx.instance_admin, owner.user.id) end)

      await_blocked(suspension.backend, change_pid)
      commit(change)

      assert {:ok, %{user: %User{}}} = Task.await(suspension.task)
      assert deadlocks() == before
    end
  end

  describe "an account's deletion against a write in a client that relies on the person's level" do
    test "the deletion first: the write waits, and the person reaches the client no more", ctx do
      before = deadlocks()
      {deletion, deletion_pid} = hold(fn -> Accounts.delete_user(ctx.person.user) end)
      assert {:ok, _deleted} = deletion.result

      write = start(fn -> locked_reload(ctx.person_in_client) end)
      await_blocked(write.backend, deletion_pid)
      commit(deletion)

      assert {:ok, scope} = Task.await(write.task)
      assert scope.reach == nil
      assert deadlocks() == before
    end

    test "the write first: the deletion waits for it", ctx do
      before = deadlocks()
      {write, write_pid} = hold(fn -> locked_reload(ctx.person_in_client) end)
      assert operator_level(write.result) == :admin

      deletion = start(fn -> Accounts.delete_user(ctx.person.user) end)
      await_blocked(deletion.backend, write_pid)
      commit(write)

      assert {:ok, _deleted} = Task.await(deletion.task)
      assert deadlocks() == before
    end

    test "against the purge of an organisation the account owns: the purge waits for it" do
      owner = sign_up()
      other = sign_up()
      before = deadlocks()

      # The organisation marked for erasure, so it is due at once, and not counted as one
      # the account alone owns.
      {:ok, :ok} =
        Repo.transaction(fn ->
          {:ok, locked} = Deletion.lock_for_erasure(owner.organisation.id)
          Deletion.mark_for_erasure(locked, nil)
        end)

      {deletion, deletion_pid} =
        hold(fn -> Organisations.sole_owned_organisations(owner.user, lock: true) end)

      assert deletion.result == []

      purge = start(fn -> Deletion.purge_marked(owner.organisation, nil) end)
      await_blocked(purge.backend, deletion_pid)

      assert {:ok, _deleted} = continue(deletion, fn -> Accounts.delete_user(owner.user) end)
      commit(deletion)

      assert {:ok, :purged} = Task.await(purge.task)
      refute Repo.get(Organisation, owner.organisation.id)
      assert Repo.get(Organisation, other.organisation.id)
      assert deadlocks() == before
    end
  end

  describe "an operator made an organisation against its member's account deletion" do
    # An operator of no client, made one as the product makes one, and a member of it.
    setup do
      %{organisation: organisation, scope: owner} = sign_up()

      Repo.update_all(from(t in Tenant, where: t.organisation_id == ^organisation.id),
        set: [kind: :operator]
      )

      %{other_operator: organisation, other_member: member(owner, :member)}
    end

    test "the change of kind first: the deletion waits for it", ctx do
      before = deadlocks()

      {change, change_pid} =
        hold(fn ->
          Operators.change_kind(ctx.instance_admin, ctx.other_operator.id, :organisation)
        end)

      assert {:ok, %Organisation{}} = change.result

      deletion = start(fn -> Accounts.delete_user(ctx.other_member.user) end)
      await_blocked(deletion.backend, change_pid)
      commit(change)

      assert {:ok, _deleted} = Task.await(deletion.task)
      assert deadlocks() == before
    end

    test "the deletion first: the change of kind waits for it", ctx do
      before = deadlocks()

      {deletion, deletion_pid} = hold(fn -> Accounts.delete_user(ctx.other_member.user) end)
      assert {:ok, _deleted} = deletion.result

      change =
        start(fn ->
          Operators.change_kind(ctx.instance_admin, ctx.other_operator.id, :organisation)
        end)

      await_blocked(change.backend, deletion_pid)
      commit(deletion)

      assert {:ok, %Organisation{}} = Task.await(change.task)
      assert Tenants.kind(%Organisation{id: ctx.other_operator.id}) == :organisation
      assert deadlocks() == before
    end
  end

  describe "an acceptance into a client against a change of its operator's kind" do
    # The acceptance takes the operator's people lock without its organisation row; the
    # change of kind holds the operator's row `FOR UPDATE` and takes no people lock. While
    # the operator has a client the change is refused, and neither waits on the other.
    setup ctx do
      %{user: joining} = sign_up()
      token = invite(ctx.client_owner.scope, joining)
      %{joining: joining, token: token}
    end

    test "the change of kind first: it holds no people lock, and the acceptance is made",
         ctx do
      before = deadlocks()

      {change, _change_pid} =
        hold(fn -> Operators.change_kind(ctx.instance_admin, ctx.operator.id, :organisation) end)

      assert {:error, :has_clients} = change.result
      assert people_lock_held(ctx.operator.id) == nil

      # Made while the change of kind still holds the operator's row: it waits for nothing.
      acceptance = start(fn -> Organisations.accept_invitation(ctx.joining, ctx.token) end)
      assert {:ok, %Membership{}} = Task.await(acceptance.task)
      end_refused(change)

      assert Tenants.operator?(ctx.operator)
      assert deadlocks() == before
    end

    test "the acceptance first: it holds the operator's people lock, and the change of kind is refused",
         ctx do
      before = deadlocks()

      {acceptance, _acceptance_pid} =
        hold(fn -> Organisations.accept_invitation(ctx.joining, ctx.token) end)

      assert {:ok, %Membership{}} = acceptance.result
      assert people_lock_held(ctx.operator.id) == :share

      change =
        start(fn -> Operators.change_kind(ctx.instance_admin, ctx.operator.id, :organisation) end)

      assert {:error, :has_clients} = Task.await(change.task)
      commit(acceptance)

      assert Tenants.operator?(ctx.operator)
      assert deadlocks() == before
    end
  end

  describe "the arbiter's offer in an operator, accepted against a write in its client" do
    # The operator's owner's account suspended, the arbiter offers its ownership to its
    # admin, the person.
    setup ctx do
      Flags.put_transfers(true)

      for id <- [ctx.in_operator.user.id, ctx.second_owner.user.id] do
        {:ok, _} = Suspensions.suspend_account(ctx.instance_admin, id)
      end

      {:ok, _} =
        Transfers.arbitrate(
          ctx.instance_admin,
          ctx.operator.id,
          ctx.person.membership.id,
          "Races."
        )

      %{recipient: scope_in(ctx.person.user, ctx.operator)}
    end

    test "the acceptance first: the write waits for it", ctx do
      before = deadlocks()
      {acceptance, acceptance_pid} = hold(fn -> Transfers.accept(ctx.recipient) end)
      assert {:ok, %Organisation{}} = acceptance.result

      write = start(fn -> locked_reload(ctx.client_admin.scope) end)
      await_blocked(write.backend, acceptance_pid)
      commit(acceptance)

      assert {:ok, %Scope{}} = Task.await(write.task)
      assert deadlocks() == before
    end

    test "the write first: the acceptance waits for it", ctx do
      before = deadlocks()
      {write, write_pid} = hold(fn -> locked_reload(ctx.client_admin.scope) end)

      acceptance = start(fn -> Transfers.accept(ctx.recipient) end)
      await_blocked(acceptance.backend, write_pid)
      commit(write)

      assert {:ok, %Organisation{}} = Task.await(acceptance.task)
      assert Repo.get!(Membership, ctx.person.membership.id).level == :owner
      assert deadlocks() == before
    end
  end

  describe "a write that asks for its people locks twice in one change, against the client's drop" do
    setup do: Flags.put_transfers(true)

    test "the write first: it holds the operator's people lock in one mode, and the drop waits",
         ctx do
      before = deadlocks()

      {write, write_pid} =
        hold(fn ->
          :ok = Access.lock_places(ctx.person_in_client)
          first = people_lock_held(ctx.operator.id)
          scope = Access.reload(ctx.person_in_client, lock: :share)
          {first, scope}
        end)

      {first, scope} = write.result
      assert operator_level(scope) == :admin
      assert first == :share
      # Asked again by the locked reload, the same row is held in the same mode.
      assert people_lock_held(ctx.operator.id) == :share

      drop = start(fn -> Transfers.drop(ctx.in_operator, ctx.client.id, ctx.client.name) end)
      await_blocked(drop.backend, write_pid)
      commit(write)

      assert {:ok, %Organisation{edition: %{tenant: %Tenant{operator_id: nil}}}} =
               Task.await(drop.task)

      assert deadlocks() == before
    end

    test "the drop first: the write waits, and reaches the client no more", ctx do
      before = deadlocks()

      {drop, drop_pid} =
        hold(fn -> Transfers.drop(ctx.in_operator, ctx.client.id, ctx.client.name) end)

      assert {:ok, %Organisation{}} = drop.result

      write = start(fn -> locked_reload(ctx.person_in_client) end)
      await_blocked(write.backend, drop_pid)
      commit(drop)

      assert {:ok, scope} = Task.await(write.task)
      assert scope.reach == nil
      assert deadlocks() == before
    end
  end

  describe "an operator whose people lock is missing" do
    setup ctx do
      Repo.delete_all(from p in PeopleLock, where: p.organisation_id == ^ctx.operator.id)
      :ok
    end

    test "a change of its people first: the row is made and locked, and the write waits", ctx do
      before = deadlocks()

      {held, held_pid} =
        hold(fn ->
          Organisations.set_member_level(ctx.in_operator, ctx.person.membership.id, :member)
        end)

      assert {:ok, %Membership{}} = held.result

      write = start(fn -> locked_reload(ctx.person_in_client) end)
      await_blocked(write.backend, held_pid)
      commit(held)

      assert {:ok, scope} = Task.await(write.task)
      assert operator_level(scope) == :member
      assert Repo.get(PeopleLock, ctx.operator.id)
      assert deadlocks() == before
    end

    test "the write first: the row is made and held, and the change of its people waits", ctx do
      before = deadlocks()
      {write, write_pid} = hold(fn -> locked_reload(ctx.person_in_client) end)
      assert operator_level(write.result) == :admin

      held =
        start(fn ->
          Organisations.set_member_level(ctx.in_operator, ctx.person.membership.id, :member)
        end)

      await_blocked(held.backend, write_pid)
      commit(write)

      assert {:ok, %Membership{level: :member}} = Task.await(held.task)
      assert [_row] = Repo.all(from p in PeopleLock, where: p.organisation_id == ^ctx.operator.id)
      assert deadlocks() == before
    end
  end

  describe "people locks asked for in both modes" do
    # Two organisations' people locks, the one with the larger id held by another
    # transaction so that a share of it waits.
    setup ctx do
      [first, second] = Enum.sort([ctx.operator.id, ctx.client.id])
      %{first: first, second: second}
    end

    test "each is held in the strongest mode asked, and they are taken in the order of their ids",
         ctx do
      before = deadlocks()

      {blocker, blocker_pid} =
        hold(fn ->
          Repo.all(
            from p in PeopleLock,
              where: p.organisation_id == ^ctx.second,
              lock: "FOR NO KEY UPDATE"
          )
        end)

      parent = self()

      locker =
        start(fn ->
          Repo.transaction(fn ->
            :ok =
              Tenants.lock_people([
                {ctx.second, :share},
                {ctx.first, :share},
                {ctx.first, :update},
                {ctx.second, :share}
              ])

            send(parent, {:locked, self()})

            receive do
              :done -> :ok
            end
          end)
        end)

      # Waiting on the second, it holds the first already, in the stronger mode.
      await_blocked(locker.backend, blocker_pid)
      assert people_lock_held(ctx.first) == :update

      commit(blocker)
      assert_receive {:locked, pid}, 5_000
      assert people_lock_held(ctx.first) == :update
      assert people_lock_held(ctx.second) == :share

      send(pid, :done)
      assert {:ok, :ok} = Task.await(locker.task)
      assert deadlocks() == before
    end
  end

  ## The changes

  defp change(:level, ctx),
    do: Organisations.set_member_level(ctx.in_operator, ctx.person.membership.id, :member)

  defp change(:removal, ctx),
    do: Organisations.remove_member(ctx.in_operator, ctx.person.membership.id)

  defp change(:leaving, ctx),
    do: Organisations.remove_member(ctx.person.scope, ctx.person.membership.id)

  defp change(:suspension, ctx),
    do: Organisations.suspend_member(ctx.in_operator, ctx.person.membership.id)

  # A write that must stay allowed, up to its question: the organisation rows and the
  # edition's, then the membership and the account (`Apiary.Access.reload/2`): the scope
  # read again under its locks.
  defp locked_reload(scope) do
    Repo.transaction(fn ->
      :ok = Access.lock_places(scope)
      Access.reload(scope, lock: :share)
    end)
  end

  # The person's level in the client's operator, as the scope's reach carries it: nil for
  # none.
  defp operator_level({:ok, %Scope{} = scope}), do: operator_level(scope)
  defp operator_level(%Scope{reach: {:operator, %Membership{level: level}}}), do: level
  defp operator_level(%Scope{}), do: nil

  # An invitation of `user` into the scope's organisation, as a member: its token.
  defp invite(scope, %User{email: email}) do
    %{token: token} = OrganisationsFixtures.invitation_fixture(scope, %{"email" => email})
    token
  end

  # How another connection finds the people lock of the organisation `id` held: `:share`
  # when a share is let by and an update is not, `:update` when neither is, nil when both
  # are.
  defp people_lock_held(id) do
    case {probe(id, :share), probe(id, :update)} do
      {:free, :free} -> nil
      {:free, :busy} -> :share
      {:busy, :busy} -> :update
    end
  end

  # Whether a connection of its own takes the people lock of the organisation `id` at once
  # in `mode`, `FOR SHARE` or `FOR NO KEY UPDATE`: `:free`, or `:busy` when it is held so
  # that it would wait.
  defp probe(id, mode) do
    Task.async(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
      query = from p in PeopleLock, where: p.organisation_id == ^id, select: p.organisation_id

      try do
        {:ok, [^id]} =
          Repo.transaction(fn ->
            case mode do
              :share -> Repo.all(lock(query, "FOR SHARE NOWAIT"))
              :update -> Repo.all(lock(query, "FOR NO KEY UPDATE NOWAIT"))
            end
          end)

        :free
      rescue
        e in Postgrex.Error ->
          %Postgrex.Error{postgres: %{code: :lock_not_available}} = e
          :busy
      end
    end)
    |> Task.await()
  end

  # Ends what `hold/1` holds of a refused change, which held its locks until now: the
  # refusal rolled the transaction back.
  defp end_refused(%{task: task, pid: pid}) do
    send(pid, :commit)
    assert {:error, :rollback} = Task.await(task)
  end

  # The table of the row the backend `backend` waits for: the tuple lock a waiter for a
  # row holds while it waits for the row's locker.
  defp waits_on(backend) do
    %{rows: [[table]]} =
      Repo.query!(
        "SELECT relation::regclass::text FROM pg_locks WHERE pid = $1 AND locktype = 'tuple'",
        [backend]
      )

    table
  end

  # Postgres's own count of deadlocks it broke in this database.
  defp deadlocks do
    %{rows: [[count]]} =
      Repo.query!("SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()")

    count
  end

  defp scope_in(user, organisation, workspace \\ nil) do
    {:ok, scope} =
      Organisations.resolve_scope(
        Scope.for_user(user),
        organisation.slug,
        workspace && workspace.slug
      )

    scope
  end

  # The entries in the instance organisation's trail that name the person `user_id`, as a
  # grant and a revoke of an instance admin, by the instance, leave them.
  defp clean_up_entries_naming(instance_organisation_id, user_id) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

    Repo.delete_all(
      from e in Apiary.Audit.Entry,
        where:
          e.organisation_id == ^instance_organisation_id and
            fragment("?->>'user_id'", e.details) == ^user_id
    )

    Ecto.Adapters.SQL.Sandbox.checkin(Repo)
  end

  # The instance admin's entries in the instance organisation's trail, which no
  # organisation of the race takes with it.
  defp clean_up_instance_entries(instance_organisation_id, admin_id) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

    Repo.delete_all(
      from e in Apiary.Audit.Entry,
        where: e.organisation_id == ^instance_organisation_id and e.actor_id == ^admin_id
    )

    Ecto.Adapters.SQL.Sandbox.checkin(Repo)
  end
end
