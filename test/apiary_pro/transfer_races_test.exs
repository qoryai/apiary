defmodule ApiaryPro.TransferRacesTest do
  # An organisation offered to an operator accepted while the offer is withdrawn, while its
  # people change, and while the operator is made an organisation or suspended; a client
  # leaving its operator while its policy is written; and an operator dropping a client
  # while one of its people reads it. Each side runs on a connection of its own, outside
  # the SQL sandbox, so each commits and each waits on the other's locks as it would in
  # production. Not async: what these tests commit is visible to every other test while
  # they run, and they delete it again before they end.
  #
  # The rules under test (`ApiaryPro.Transfers`): an acceptance and a withdrawal lock the
  # organisation offered first, then the pending offer, so exactly one of them happens.
  # Accepting an organisation offered to an operator, a client's leaving and its drop lock
  # the client's row `FOR NO KEY UPDATE`, then hold the operator's `FOR SHARE`; a change
  # of the operator's kind and its suspension lock that row for update, and a write that
  # must stay allowed while it is written, the policy's, and a locked read of the reach
  # hold the client's row `FOR SHARE`. Whichever comes second waits for the first, and then
  # sees it. An operator never takes on a client once it is an organisation or suspended,
  # an operator with a client it took on does not become an organisation, and a client
  # that left or was dropped is read by the operator's people no more.
  #
  # Each test holds the first side's transaction open until the second side is seen, in
  # the database, waiting on a lock the first side holds (`pg_blocking_pids`).
  use ExUnit.Case, async: false

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  @before_compile Apiary.TestSetup

  # Offers to an operator and leaving one are shown here, for this process and those it
  # starts (`ApiaryPro.Flags.put_transfers/1`).
  setup do: ApiaryPro.Flags.put_transfers(true)

  import Ecto.Query
  import Apiary.Races
  import ApiaryPro.Races

  alias Apiary.{Access, Organisations, Policy, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.{Membership, Organisation}
  alias ApiaryPro.{Operators, Suspensions, Transfers}
  alias ApiaryPro.Transfers.Transfer
  alias Ecto.Adapters.SQL.Sandbox
  alias ApiaryPro.Tenants.Tenant

  # An operator and its clients are `managed_organisations`': left out of a run without it.
  @moduletag needs: :managed_organisations

  setup_all :clean_up_leftovers
  setup :setup_races

  # An operator, made one by an instance admin as the product makes one, with its owner's
  # scope in it, and the instance admin's scope in the instance organisation. The instance
  # admin's membership is inserted as it is, and goes with their account; the entries of
  # the instance organisation's trail are deleted when the test ends.
  setup do
    admin = sign_up()
    instance_organisation = ApiaryPro.Organisations.instance_organisation()

    Repo.insert!(%Membership{
      organisation_id: instance_organisation.id,
      user_id: admin.user.id,
      level: :owner
    })

    on_exit(fn -> clean_up_instance_entries(instance_organisation.id, admin.user.id) end)
    instance_admin = scope_in(admin.user, instance_organisation)

    operator = sign_up()

    {:ok, _operator} =
      Operators.change_kind(instance_admin, operator.organisation.id, :operator)

    %{
      operator: operator,
      owner: scope_in(operator.user, operator.organisation),
      instance_admin: instance_admin
    }
  end

  describe "an acceptance racing the offer's withdrawal" do
    # An organisation of its own, offered to the operator by its owner.
    setup ctx do
      offered = sign_up()

      {:ok, _transfer} =
        Transfers.offer_to_operator(offered.scope, ctx.operator.organisation.slug)

      %{offered: offered}
    end

    test "accepted first: the withdrawal waits, and finds nothing to withdraw", ctx do
      {acceptance, acceptance_pid} = hold(fn -> accept_client(ctx) end)
      assert {:ok, %Organisation{}} = acceptance.result

      withdrawal = start(fn -> Transfers.withdraw(ctx.offered.scope) end)
      await_blocked(withdrawal.backend, acceptance_pid)
      commit(acceptance)

      assert {:error, :not_found} = Task.await(withdrawal.task)
      assert client?(ctx)
      assert owner?(ctx.offered)
      refute pending?(ctx.offered.organisation)
      assert actions(ctx.offered.organisation) == []
    end

    test "withdrawn first: the acceptance waits, and finds no offer", ctx do
      {withdrawal, withdrawal_pid} = hold(fn -> Transfers.withdraw(ctx.offered.scope) end)
      assert {:ok, %Transfer{}} = withdrawal.result

      acceptance = start(fn -> accept_client(ctx) end)
      await_blocked(acceptance.backend, withdrawal_pid)
      commit(withdrawal)

      assert {:error, :not_found} = Task.await(acceptance.task)
      refute client?(ctx)
      refute pending?(ctx.offered.organisation)
      assert actions(ctx.offered.organisation) == ["organisation.withdraw_transfer"]
    end
  end

  describe "an offer and its acceptance against a change that takes both organisations in the lock order" do
    # Two fresh organisations: the one with the lower id is made the operator, so the lock
    # order takes the operator first and then the organisation offered, as neither is a
    # client. The other change holds the operator's row `FOR NO KEY UPDATE`, as a change
    # of its own does, and then the organisation's `FOR SHARE`, paused between the two.
    setup ctx do
      [operator, offered] = Enum.sort_by([sign_up(), sign_up()], & &1.organisation.id)

      {:ok, _operator} =
        Operators.change_kind(ctx.instance_admin, operator.organisation.id, :operator)

      %{
        operator: operator,
        owner: scope_in(operator.user, operator.organisation),
        offered: offered
      }
    end

    test "the offer waits at the operator, holding nothing, and nothing deadlocks", ctx do
      before = deadlocks()
      {other, other_pid} = hold(fn -> locked(ctx.operator.organisation.id, :no_key_update) end)

      offer =
        start(fn ->
          Transfers.offer_to_operator(ctx.offered.scope, ctx.operator.organisation.slug)
        end)

      await_blocked(offer.backend, other_pid)
      assert continue(other, fn -> locked(ctx.offered.organisation.id, :share) end)
      commit(other)

      assert {:ok, %Transfer{}} = Task.await(offer.task)
      assert pending?(ctx.offered.organisation)
      assert deadlocks() == before
    end

    test "the acceptance waits at the operator, holding nothing, and nothing deadlocks",
         ctx do
      {:ok, _transfer} =
        Transfers.offer_to_operator(ctx.offered.scope, ctx.operator.organisation.slug)

      before = deadlocks()
      {other, other_pid} = hold(fn -> locked(ctx.operator.organisation.id, :no_key_update) end)

      acceptance = start(fn -> accept_client(ctx) end)
      await_blocked(acceptance.backend, other_pid)
      assert continue(other, fn -> locked(ctx.offered.organisation.id, :share) end)
      commit(other)

      assert {:ok, %Organisation{}} = Task.await(acceptance.task)
      assert client?(ctx)
      assert deadlocks() == before
    end
  end

  describe "a client leaving its operator while its policy is written" do
    # A client of the operator, with its owner and an admin of its own, who writes its
    # policy while the owner takes it away from the operator.
    @describetag needs: [:managed_organisations, :security]

    setup ctx do
      client = client(ctx.owner)
      admin = member(client.owner.scope, :admin)
      %{client: client, writer: admin.scope}
    end

    test "the write first: the leaving waits, and both commit", ctx do
      {write, write_pid} = hold(fn -> write(ctx.writer) end)
      assert {:ok, _rule} = write.result

      leaving = start(fn -> leave(ctx) end)
      await_blocked(leaving.backend, write_pid)
      commit(write)

      assert {:ok, %Organisation{edition: %{tenant: %Tenant{operator_id: nil}}}} =
               Task.await(leaving.task)

      assert Repo.get!(Tenant, ctx.client.organisation.id).operator_id == nil
    end

    test "the leaving first: the write waits, and is written in a client with no operator",
         ctx do
      {leaving, leaving_pid} = hold(fn -> leave(ctx) end)
      assert {:ok, %Organisation{edition: %{tenant: %Tenant{operator_id: nil}}}} = leaving.result

      write = start(fn -> write(ctx.writer) end)
      await_blocked(write.backend, leaving_pid)
      commit(leaving)

      assert {:ok, _rule} = Task.await(write.task)
      assert Repo.get!(Tenant, ctx.client.organisation.id).operator_id == nil
    end
  end

  describe "an operator dropping a client while one of its people reads it" do
    # A client of the operator, read by an admin of the operator through a locked reload,
    # as a write that must stay allowed reads the reach, while the operator's owner drops
    # the client.
    setup ctx do
      client = client(ctx.owner)
      admin = member(ctx.owner, :admin)

      %{
        client: client,
        reader: scope_in(admin.user, client.organisation, client.workspace)
      }
    end

    test "the read first: the drop waits, and the read saw the client as its operator's",
         ctx do
      {read, read_pid} = hold(fn -> Access.reload(ctx.reader, lock: :share) end)
      assert {:operator, _via} = read.result.reach
      assert Access.check(read.result, :"run.read", ctx.client.workspace) == :ok

      drop = start(fn -> drop(ctx) end)
      await_blocked(drop.backend, read_pid)
      commit(read)

      assert {:ok, %Organisation{edition: %{tenant: %Tenant{operator_id: nil}}}} =
               Task.await(drop.task)

      assert Access.authorize(ctx.reader, :"run.read", ctx.client.workspace) ==
               {:error, :forbidden}
    end

    test "the drop first: the read waits, and reaches the client no more", ctx do
      {drop, drop_pid} = hold(fn -> drop(ctx) end)
      assert {:ok, %Organisation{edition: %{tenant: %Tenant{operator_id: nil}}}} = drop.result

      read = start(fn -> Repo.transaction(fn -> Access.reload(ctx.reader, lock: :share) end) end)
      await_blocked(read.backend, drop_pid)
      commit(drop)

      assert {:ok, reloaded} = Task.await(read.task)
      assert reloaded.reach == nil
      assert Access.check(reloaded, :"run.read", ctx.client.workspace) == {:error, :forbidden}
    end
  end

  describe "an organisation offered to the operator, accepted while its people change" do
    # An organisation of its own with a member, offered to the operator by its owner. The
    # acceptance locks the organisation's row for the change of its operator; a change of a
    # level, a removal and a suspension there hold the row `FOR SHARE` first, then lock the
    # owners. Whichever comes second waits for the first; both commit, and its owners stay
    # its owners.
    setup ctx do
      offered = sign_up()
      person = member(offered.scope, :member)

      {:ok, _transfer} =
        Transfers.offer_to_operator(offered.scope, ctx.operator.organisation.slug)

      %{offered: offered, person: person}
    end

    for change <- [:level, :removal, :suspension] do
      @change change

      test "the #{change} first: the acceptance waits, and makes the organisation a client",
           ctx do
        {first, first_pid} = hold(fn -> people_change(@change, ctx.offered.scope, ctx.person) end)
        assert {:ok, %Membership{}} = first.result

        acceptance = start(fn -> accept_client(ctx) end)
        await_blocked(acceptance.backend, first_pid)
        commit(first)

        assert {:ok, %Organisation{}} = Task.await(acceptance.task)
        assert client?(ctx)
        assert owner?(ctx.offered)
      end

      test "accepted first: the #{change} waits, and is made by its owner as before", ctx do
        {acceptance, acceptance_pid} = hold(fn -> accept_client(ctx) end)
        assert {:ok, %Organisation{}} = acceptance.result

        second = start(fn -> people_change(@change, ctx.offered.scope, ctx.person) end)
        await_blocked(second.backend, acceptance_pid)
        commit(acceptance)

        assert {:ok, %Membership{}} = Task.await(second.task)
        assert client?(ctx)
        assert owner?(ctx.offered)
      end
    end
  end

  describe "an organisation offered to the operator, accepted while the operator changes" do
    # An organisation of its own, offered to the operator by its owner.
    setup ctx do
      offered = sign_up()

      {:ok, _transfer} =
        Transfers.offer_to_operator(offered.scope, ctx.operator.organisation.slug)

      %{offered: offered}
    end

    test "made an organisation first: the acceptance waits, and is not found", ctx do
      {change, change_pid} = hold(fn -> make_organisation(ctx) end)

      assert {:ok, %Organisation{edition: %{tenant: %Tenant{kind: :organisation}}}} =
               change.result

      acceptance = start(fn -> accept_client(ctx) end)
      await_blocked(acceptance.backend, change_pid)
      commit(change)

      assert {:error, :not_found} = Task.await(acceptance.task)
      refute client?(ctx)
      assert owner?(ctx.offered)
    end

    test "accepted first: making the operator an organisation waits, and is refused", ctx do
      {acceptance, acceptance_pid} = hold(fn -> accept_client(ctx) end)
      assert {:ok, %Organisation{}} = acceptance.result

      change = start(fn -> make_organisation(ctx) end)
      await_blocked(change.backend, acceptance_pid)
      commit(acceptance)

      assert {:error, :has_clients} = Task.await(change.task)
      assert Repo.get!(Tenant, ctx.operator.organisation.id).kind == :operator
      assert client?(ctx)
      assert owner?(ctx.offered)
    end

    test "suspended first: the acceptance waits, and is refused", ctx do
      {suspension, suspension_pid} = hold(fn -> suspend_operator(ctx) end)

      assert {:ok, %Organisation{edition: %{tenant: %Tenant{suspended_at: %DateTime{}}}}} =
               suspension.result

      acceptance = start(fn -> accept_client(ctx) end)
      await_blocked(acceptance.backend, suspension_pid)
      commit(suspension)

      # A suspended operator is read-only: its owner accepts nothing, and the offer to it
      # was withdrawn with the suspension.
      assert {:error, :forbidden} = Task.await(acceptance.task)
      refute client?(ctx)
      assert owner?(ctx.offered)
      refute pending?(ctx.offered.organisation)
    end

    test "accepted first: the suspension waits, and suspends an operator with its new client",
         ctx do
      {acceptance, acceptance_pid} = hold(fn -> accept_client(ctx) end)
      assert {:ok, %Organisation{}} = acceptance.result

      suspension = start(fn -> suspend_operator(ctx) end)
      await_blocked(suspension.backend, acceptance_pid)
      commit(acceptance)

      assert {:ok, %Organisation{edition: %{tenant: %Tenant{suspended_at: %DateTime{}}}}} =
               Task.await(suspension.task)

      assert client?(ctx)
      assert owner?(ctx.offered)
      refute pending?(ctx.offered.organisation)
    end
  end

  # A change of the person's membership by `scope`: to admin from member, or to member from
  # admin; a removal; a suspension.
  defp people_change(:level, scope, %{membership: membership}) do
    level = if membership.level == :member, do: :admin, else: :member
    Organisations.set_member_level(scope, membership.id, level)
  end

  defp people_change(:removal, scope, %{membership: membership}),
    do: Organisations.remove_member(scope, membership.id)

  defp people_change(:suspension, scope, %{membership: membership}),
    do: Organisations.suspend_member(scope, membership.id)

  # The organisation's row held in `mode`: its id.
  defp locked(id, :no_key_update),
    do:
      Repo.one(
        from o in Organisation, where: o.id == ^id, select: o.id, lock: "FOR NO KEY UPDATE"
      )

  defp locked(id, :share),
    do: Repo.one(from o in Organisation, where: o.id == ^id, select: o.id, lock: "FOR SHARE")

  # Postgres's own count of deadlocks it broke in this database. A hint only: the count
  # is flushed to `pg_stat_database` some time after the fact, and a deadlock the core's
  # retry under a savepoint absorbs is counted only once its transaction ends. What
  # catches a deadlock is the other assertions: the result each side answers, and the
  # rows it leaves.
  defp deadlocks do
    %{rows: [[count]]} =
      Repo.query!("SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()")

    count
  end

  defp leave(ctx), do: Transfers.leave(ctx.client.owner.scope, ctx.operator.organisation.name)

  defp drop(ctx),
    do: Transfers.drop(ctx.owner, ctx.client.organisation.id, ctx.client.organisation.name)

  defp write(scope),
    do: Policy.allow(scope, nil, %{host: "race#{System.unique_integer([:positive])}.example"})

  defp accept_client(ctx), do: Transfers.accept_client(ctx.owner, ctx.offered.organisation.id)

  defp make_organisation(ctx),
    do: Operators.change_kind(ctx.instance_admin, ctx.operator.organisation.id, :organisation)

  defp suspend_operator(ctx),
    do: Suspensions.suspend_organisation(ctx.instance_admin, ctx.operator.organisation.id)

  defp scope_in(user, organisation, workspace \\ nil) do
    {:ok, scope} =
      Organisations.resolve_scope(
        Scope.for_user(user),
        organisation.slug,
        workspace && workspace.slug
      )

    scope
  end

  # Whether the organisation offered became the operator's client.
  defp client?(ctx),
    do:
      Repo.get!(Tenant, ctx.offered.organisation.id).operator_id ==
        ctx.operator.organisation.id

  # Whether the organisation offered's owner is an owner still.
  defp owner?(%{membership: %Membership{id: id}}), do: Repo.get!(Membership, id).level == :owner

  defp pending?(%Organisation{id: id}),
    do: Repo.exists?(from t in Transfer, where: t.organisation_id == ^id)

  # The organisation's trail since the offer, oldest first: what of the race happened.
  defp actions(%Organisation{id: id}) do
    Repo.all(
      from e in Entry,
        where: e.organisation_id == ^id,
        where: e.action in ["organisation.accept_transfer", "organisation.withdraw_transfer"],
        order_by: [asc: e.inserted_at, asc: e.id],
        select: e.action
    )
  end

  # The instance admin's entries in the instance organisation's trail, which is not
  # deleted with the race's organisations.
  defp clean_up_instance_entries(instance_organisation_id, admin_id) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    Repo.delete_all(
      from e in Entry,
        where: e.organisation_id == ^instance_organisation_id and e.actor_id == ^admin_id
    )

    # The next clean-up checks its own connection out.
    Sandbox.checkin(Repo)
  end
end
