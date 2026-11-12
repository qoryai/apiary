defmodule ApiaryPro.LockOrderRacesTest do
  # A client's leaving its operator, its drop, the acceptance of the arbiter's offer and an
  # operator's acceptance of an organisation offered to it, each against a change paused
  # half way: one that holds the owners and has not written its entry, a policy write that
  # holds the organisation, and a grant to an operator that holds its clients. Each side runs on a connection of
  # its own, outside the SQL sandbox; the first is held half way (`hold/1`), the second
  # started and seen waiting on it (`await_blocked/2`), then the first finishes its second
  # half in the same transaction (`continue/2`): what a deadlock needs, each side waiting
  # on the other. Not async: what these tests commit is visible to every other test while
  # they run, and they delete it again before they end.
  #
  # The rule under test is the lock order of docs/access.md: organisation rows first, a
  # client before its operator, then workspaces, memberships and accounts. Each side
  # takes the rows it needs in that order, so the second waits on the first's first row
  # and holds nothing the first's second half needs: nothing deadlocks, which Postgres's
  # own count of deadlocks shows.
  use ExUnit.Case, async: false
  @before_compile Apiary.TestSetup

  # Offers to an operator and leaving one are shown here, for this process and those it
  # starts (`ApiaryPro.Flags.put_transfers/1`).
  setup do: ApiaryPro.Flags.put_transfers(true)

  import Ecto.Query
  import Apiary.Races
  import ApiaryPro.Races

  alias Apiary.{Audit, Organisations, Policy, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Membership, Organisation, Workspace}
  alias ApiaryPro.{Grants, Suspensions, Tenants, Transfers}
  alias ApiaryPro.Tenants.Tenant

  @moduletag needs: :managed_organisations

  setup_all :clean_up_leftovers
  setup :setup_races

  # An operator, made one as the product makes one, and an instance admin; a client of the
  # operator with its owner and an admin of its own; and an organisation of its own, with
  # a member, offered to the operator by its owner.
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

    Repo.update_all(from(t in Tenant, where: t.organisation_id == ^operator.organisation.id),
      set: [kind: :operator]
    )

    operator_row = Organisation |> Repo.get!(operator.organisation.id) |> Tenants.put()
    {:ok, _features} = Grants.written_out(operator_row, :operator)
    in_operator = scope_in(operator.user, operator_row)

    client = client(in_operator)
    client_admin = member(client.owner.scope, :admin)

    offered = sign_up()
    offered_member = member(offered.scope, :member)
    {:ok, _} = Transfers.offer_to_operator(offered.scope, operator_row.slug)

    %{
      instance_admin: instance_admin,
      operator: operator_row,
      in_operator: in_operator,
      client: client.organisation,
      workspace: client.workspace,
      client_owner: client.owner,
      client_admin: client_admin,
      offered: offered,
      offered_member: offered_member
    }
  end

  describe "a client leaving its operator" do
    test "against a change of a level holding the owners, its entry not yet written", ctx do
      before = deadlocks()
      owner = ctx.client_owner.scope

      {change, change_pid} =
        hold(fn -> level_change_first_half(owner, ctx.client_admin.membership) end)

      leaving = start(fn -> Transfers.leave(owner, ctx.operator.name) end)
      await_blocked(leaving.backend, change_pid)

      assert {:ok, _entry} = continue(change, fn -> level_change_entry(owner, change) end)
      commit(change)

      assert {:ok, %Organisation{edition: %{tenant: %Tenant{operator_id: nil}}}} =
               Task.await(leaving.task)

      assert deadlocks() == before
    end

    @tag needs: [:managed_organisations, :security]
    test "against a policy write by its admin holding the client", ctx do
      before = deadlocks()
      writer = ctx.client_admin.scope
      {write, write_pid} = hold(fn -> policy_write_first_half(writer) end)

      leaving = start(fn -> Transfers.leave(ctx.client_owner.scope, ctx.operator.name) end)
      await_blocked(leaving.backend, write_pid)

      assert {:ok, _rule} = continue(write, fn -> allow(writer) end)
      commit(write)

      assert {:ok, %Organisation{edition: %{tenant: %Tenant{operator_id: nil}}}} =
               Task.await(leaving.task)

      assert deadlocks() == before
    end

    test "against a grant to its operator holding the operator's clients", ctx do
      before = deadlocks()
      {grant, grant_pid} = hold(fn -> lock_clients(ctx.operator) end)

      leaving = start(fn -> Transfers.leave(ctx.client_owner.scope, ctx.operator.name) end)
      await_blocked(leaving.backend, grant_pid)

      assert {:ok, _features} = continue(grant, fn -> narrow(ctx) end)
      commit(grant)

      assert {:ok, %Organisation{edition: %{tenant: %Tenant{operator_id: nil}}}} =
               Task.await(leaving.task)

      assert deadlocks() == before
    end
  end

  describe "an operator dropping a client" do
    @tag needs: [:managed_organisations, :security]
    test "against a policy write by the client's admin holding the client", ctx do
      before = deadlocks()
      writer = ctx.client_admin.scope
      {write, write_pid} = hold(fn -> policy_write_first_half(writer) end)

      drop = start(fn -> Transfers.drop(ctx.in_operator, ctx.client.id, ctx.client.name) end)
      await_blocked(drop.backend, write_pid)

      assert {:ok, _rule} = continue(write, fn -> allow(writer) end)
      commit(write)

      assert {:ok, %Organisation{edition: %{tenant: %Tenant{operator_id: nil}}}} =
               Task.await(drop.task)

      assert deadlocks() == before
    end

    test "against a grant to the operator holding its clients", ctx do
      before = deadlocks()
      {grant, grant_pid} = hold(fn -> lock_clients(ctx.operator) end)

      drop = start(fn -> Transfers.drop(ctx.in_operator, ctx.client.id, ctx.client.name) end)
      await_blocked(drop.backend, grant_pid)

      assert {:ok, _features} = continue(grant, fn -> narrow(ctx) end)
      commit(grant)

      assert {:ok, %Organisation{edition: %{tenant: %Tenant{operator_id: nil}}}} =
               Task.await(drop.task)

      assert deadlocks() == before
    end
  end

  describe "the arbiter's offer, accepted by a client's admin" do
    # The client's owner suspended, the arbiter offers its ownership to a second admin.
    setup ctx do
      recipient = member(ctx.client_owner.scope, :admin)
      {:ok, _} = Suspensions.suspend_account(ctx.instance_admin, ctx.client_owner.user.id)

      {:ok, _} =
        Transfers.arbitrate(
          ctx.instance_admin,
          ctx.client.id,
          recipient.membership.id,
          "Races."
        )

      %{recipient: scope_in(recipient.user, ctx.client, ctx.workspace)}
    end

    test "against a change of a level holding the owners, its entry not yet written", ctx do
      before = deadlocks()
      admin = ctx.client_admin.scope

      {change, change_pid} =
        hold(fn -> level_change_first_half(admin, ctx.client_admin.membership) end)

      acceptance = start(fn -> Transfers.accept(ctx.recipient) end)
      await_blocked(acceptance.backend, change_pid)

      assert {:ok, _entry} = continue(change, fn -> level_change_entry(admin, change) end)
      commit(change)

      assert {:ok, %Organisation{edition: %{tenant: %Tenant{operator_id: operator_id}}}} =
               Task.await(acceptance.task)

      assert operator_id == ctx.operator.id
      assert deadlocks() == before
    end
  end

  describe "an organisation offered to the operator, accepted by its owner" do
    test "against a change of a level there holding the owners, its entry not yet written",
         ctx do
      before = deadlocks()

      {change, change_pid} =
        hold(fn -> level_change_first_half(ctx.offered.scope, ctx.offered_member.membership) end)

      acceptance = start(fn -> accept_client(ctx) end)
      await_blocked(acceptance.backend, change_pid)

      assert {:ok, _entry} =
               continue(change, fn -> level_change_entry(ctx.offered.scope, change) end)

      commit(change)

      assert {:ok, %Organisation{}} = Task.await(acceptance.task)
      assert deadlocks() == before
    end

    test "against set_member_level itself, paused before it commits", ctx do
      before = deadlocks()

      {change, change_pid} =
        hold(fn ->
          Organisations.set_member_level(
            ctx.offered.scope,
            ctx.offered_member.membership.id,
            :admin
          )
        end)

      assert {:ok, %Membership{level: :admin}} = change.result

      acceptance = start(fn -> accept_client(ctx) end)
      await_blocked(acceptance.backend, change_pid)
      commit(change)

      assert {:ok, %Organisation{}} = Task.await(acceptance.task)
      assert deadlocks() == before
    end

    @tag needs: [:managed_organisations, :security]
    test "against a policy write by its owner holding the organisation", ctx do
      before = deadlocks()
      {write, write_pid} = hold(fn -> policy_write_first_half(ctx.offered.scope) end)

      acceptance = start(fn -> accept_client(ctx) end)
      await_blocked(acceptance.backend, write_pid)

      assert {:ok, _rule} = continue(write, fn -> allow(ctx.offered.scope) end)
      commit(write)

      assert {:ok, %Organisation{}} = Task.await(acceptance.task)
      assert deadlocks() == before
    end

    test "against a grant to the operator holding it", ctx do
      before = deadlocks()
      {grant, grant_pid} = hold(fn -> narrow(ctx) end)
      assert {:ok, _features} = grant.result

      acceptance = start(fn -> accept_client(ctx) end)
      await_blocked(acceptance.backend, grant_pid)
      commit(grant)

      assert {:ok, %Organisation{}} = Task.await(acceptance.task)
      assert deadlocks() == before
    end
  end

  ## The first halves, as the product takes them, and their second halves

  # A change of a level, up to its entry: the organisation rows and the owners, then the
  # membership changed (`Apiary.Organisations.set_member_level/3`).
  defp level_change_first_half(scope, %Membership{} = membership) do
    :ok = Organisations.lock_owners(scope)
    level = if membership.level == :member, do: :admin, else: :member

    {:ok, changed} = membership |> Membership.changeset(%{level: level}) |> Repo.update()
    %{before: membership, changed: changed}
  end

  # Its entry, which names the organisation, and so holds it `FOR KEY SHARE`.
  defp level_change_entry(scope, held) do
    %{before: before, changed: changed} = held.result

    Audit.record(Repo, scope, :"member.change_level", changed, %{
      before: %{level: before.level},
      after: %{level: changed.level},
      details: %{user_id: changed.user_id}
    })
  end

  # A policy write, up to its question: the organisation rows, then the workspace
  # (`Apiary.Policy`); its second half is the whole write, whose locks it holds already.
  defp policy_write_first_half(%Scope{workspace: %Workspace{id: workspace_id}} = scope) do
    :ok = Apiary.Access.lock_places(scope)

    Repo.one!(
      from w in Workspace, where: w.id == ^workspace_id, lock: "FOR NO KEY UPDATE", select: w.id
    )

    :ok
  end

  defp allow(scope), do: Policy.allow(scope, nil, %{host: "race#{unique()}.example"})

  # A grant to an operator, up to its own row: its clients (`ApiaryPro.Grants`).
  defp lock_clients(%Organisation{id: operator_id}) do
    Repo.all(
      from o in Organisation,
        join: t in Tenant,
        on: t.organisation_id == o.id,
        where: t.operator_id == ^operator_id,
        order_by: [asc: o.id],
        select: o.id,
        lock: fragment("FOR NO KEY UPDATE OF ?", o)
    )
  end

  defp narrow(ctx),
    do: Grants.set_organisation(ctx.instance_admin, ctx.operator.id, [:observability])

  defp accept_client(ctx),
    do: Transfers.accept_client(ctx.in_operator, ctx.offered.organisation.id)

  ## Helpers

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

  defp unique, do: System.unique_integer([:positive])

  # The instance admin's entries in the instance organisation's trail, which no
  # organisation of the race takes with it.
  defp clean_up_instance_entries(instance_organisation_id, admin_id) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

    Repo.delete_all(
      from e in Apiary.Audit.Entry,
        where: e.organisation_id == ^instance_organisation_id and e.actor_id == ^admin_id
    )

    # The next clean-up checks its own connection out.
    Ecto.Adapters.SQL.Sandbox.checkin(Repo)
  end
end
