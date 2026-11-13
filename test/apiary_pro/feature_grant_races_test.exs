defmodule ApiaryPro.FeatureGrantRacesTest do
  # A write of the security policy racing the withdrawal of `security` from its
  # organisation, by an instance admin. Each side runs on a connection of its own, outside
  # the SQL sandbox, so each commits and each waits on the other's locks as it would in
  # production. Not async: what these tests commit is visible to every other test while
  # they run, and they delete it again before they end.
  #
  # The rule under test (`ApiaryPro.Grants`, `Apiary.Access.reload/2`): a withdrawal
  # locks the organisation `FOR UPDATE` first; a policy write takes the workspace's lock
  # and holds the organisation `FOR KEY SHARE` while it asks, and reads the features after
  # its locks. So a write that holds them is written, and the
  # withdrawal waits for it; a write that comes second waits, and then finds the feature
  # absent. A write never commits on a feature a withdrawal committed before it took away.
  #
  # A grant takes organisation rows only, in the lock order of docs/access.md, and renders
  # nothing: a grant and a write of the organisation's policy, a client's drop, a change
  # of its operator's kind or the operator's suspension wait for each other on those rows,
  # and Postgres breaks no deadlock between them (`deadlocks/0`).
  use ExUnit.Case, async: false

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  @before_compile Apiary.TestSetup

  import Ecto.Query
  import Apiary.Races
  import ApiaryPro.Races

  alias Apiary.{Features, Organisations, Policy, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Membership, Organisation}
  alias Apiary.Policy.{Error, Rule}
  alias ApiaryPro.{Grants, Operators, OrganisationPolicy, Suspensions, Tenants, Transfers}
  alias ApiaryPro.Tenants.Tenant

  @moduletag needs: :security

  setup_all :clean_up_leftovers
  setup :setup_races

  # An organisation of a fresh owner, and an instance admin's scope in the instance
  # organisation, whose membership is inserted as it is and goes with their account.
  setup do
    %{scope: owner} = sign_up()
    admin = sign_up()
    instance_organisation = ApiaryPro.Organisations.instance_organisation()

    Repo.insert!(%Membership{
      organisation_id: instance_organisation.id,
      user_id: admin.user.id,
      level: :owner
    })

    {:ok, instance_admin} =
      Organisations.resolve_scope(Scope.for_user(admin.user), instance_organisation.slug)

    %{owner: owner, instance_admin: instance_admin}
  end

  # Every feature the organisation's page shows, but `features`.
  defp without(ctx, features) do
    shown = Grants.shown(Repo.get!(Organisation, ctx.owner.organisation.id))
    Grants.set_organisation(ctx.instance_admin, ctx.owner.organisation.id, shown -- features)
  end

  # What is left once `security` is taken away, and what needs it with it: everything
  # else a page shows.
  defp without_security,
    do: Features.closed(Enum.filter(Features.enabled(), &(&1 in Features.built())) -- [:security])

  @tag :feature_sets
  test "its organisation: the write first commits, and the withdrawal waits for it", ctx do
    {write, write_pid} = hold(fn -> allow(ctx.owner) end)
    assert {:ok, _} = write.result

    withdrawal = start(fn -> withdraw(ctx) end)
    await_blocked(withdrawal.backend, write_pid)
    commit(write)

    assert {:ok, _features} = Task.await(withdrawal.task)
    assert rule?(ctx.owner)
    refute :security in ApiaryPro.Features.of(reloaded(ctx.owner))
  end

  @tag :feature_sets
  test "its organisation: the withdrawal first, the write waits for it and finds the feature gone",
       ctx do
    {withdrawal, withdrawal_pid} = hold(fn -> withdraw(ctx) end)
    assert {:ok, _features} = withdrawal.result

    write = start(fn -> allow(ctx.owner) end)
    await_blocked(write.backend, withdrawal_pid)
    commit(withdrawal)

    assert {:error, %Error{reason: :not_found}} = Task.await(write.task)
    refute rule?(ctx.owner)
  end

  describe "an operator narrowed while its client changes" do
    # An operator, made one as the product makes one, and a client of it; the client's owner
    # writes the client's policy, or the operator's owner grants the client its features,
    # while an instance admin narrows the operator. The narrowing locks the operator's clients
    # first, then the operator; a write in the client holds the client `FOR KEY SHARE`,
    # and a grant to the client locks it for update: whichever comes second waits for
    # the first, and then sees it.
    @describetag needs: [:managed_organisations, :security]

    setup ctx do
      %{scope: operator_owner, organisation: operator} = sign_up()

      Repo.update_all(from(t in Tenant, where: t.organisation_id == ^operator.id),
        set: [kind: :operator]
      )

      operator = Repo.get!(Organisation, operator.id)
      {:ok, _features} = Grants.written_out(operator, :operator)

      {:ok, in_operator} =
        Organisations.resolve_scope(Scope.for_user(operator_owner.user), operator.slug)

      client = client(in_operator)

      Map.merge(ctx, %{
        operator: operator,
        in_operator: in_operator,
        client: client.organisation,
        in_client: client.owner.scope
      })
    end

    @tag :feature_sets
    test "the client's policy write first: the narrowing waits for it", ctx do
      {write, write_pid} = hold(fn -> allow(ctx.in_client) end)
      assert {:ok, _} = write.result

      narrowing = start(fn -> narrow(ctx) end)
      await_blocked(narrowing.backend, write_pid)
      commit(write)

      assert {:ok, _features} = Task.await(narrowing.task)
      assert rule?(ctx.in_client)
      refute :security in ApiaryPro.Features.of(Repo.get!(Organisation, ctx.client.id))
    end

    test "the narrowing first: the client's policy write waits, and finds the feature gone",
         ctx do
      {narrowing, narrowing_pid} = hold(fn -> narrow(ctx) end)
      assert {:ok, _features} = narrowing.result

      write = start(fn -> allow(ctx.in_client) end)
      await_blocked(write.backend, narrowing_pid)
      commit(narrowing)

      assert {:error, %Error{reason: :not_found}} = Task.await(write.task)
      refute rule?(ctx.in_client)
    end

    @tag :feature_sets
    test "the grant to the client first: the narrowing waits, and clips it", ctx do
      {grant, grant_pid} = hold(fn -> grant_client(ctx) end)
      assert {:ok, _features} = grant.result

      narrowing = start(fn -> narrow(ctx) end)
      await_blocked(narrowing.backend, grant_pid)
      commit(grant)

      assert {:ok, _features} = Task.await(narrowing.task)
      refute :security in ApiaryPro.Features.of(Repo.get!(Organisation, ctx.client.id))
    end

    test "the narrowing first: the grant to the client waits, and may not grant what is gone",
         ctx do
      {narrowing, narrowing_pid} = hold(fn -> narrow(ctx) end)
      assert {:ok, _features} = narrowing.result

      grant = start(fn -> grant_client(ctx) end)
      await_blocked(grant.backend, narrowing_pid)
      commit(narrowing)

      assert {:error, :above} = Task.await(grant.task)
    end
  end

  describe "a grant and a write of the organisation's policy" do
    # The organisation has a policy that denies paste.example, rendered in its workspace
    # Main; an instance admin takes `organisation_policy` away from it while its owner
    # writes the policy. The grant holds the organisation `FOR NO KEY UPDATE`, the write
    # holds it `FOR SHARE` and then its workspaces: whichever comes second waits for the
    # first on the organisation's row. The grant writes nothing to a workspace's History.
    @describetag needs: :organisation_policy

    setup ctx do
      {:ok, _} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})
      :ok
    end

    test "the grant first: the write waits, and finds the feature gone", ctx do
      before = deadlocks()
      changes = history(ctx.owner)

      {grant, grant_pid} = hold(fn -> without(ctx, [:organisation_policy]) end)
      assert {:ok, _features} = grant.result

      write = start(fn -> OrganisationPolicy.deny(ctx.owner, %{host: "pastebin.example"}) end)
      await_blocked(write.backend, grant_pid)
      commit(grant)

      assert {:error, %Error{reason: :not_found}} = Task.await(write.task)
      assert deadlocks() == before
      assert history(ctx.owner) == changes
    end

    test "the write first: the grant waits for it, and writes no History", ctx do
      before = deadlocks()

      {write, write_pid} =
        hold(fn -> OrganisationPolicy.deny(ctx.owner, %{host: "pastebin.example"}) end)

      assert {:ok, _rule} = write.result

      grant = start(fn -> without(ctx, [:organisation_policy]) end)
      await_blocked(grant.backend, write_pid)
      commit(write)

      assert {:ok, features} = Task.await(grant.task)
      refute :organisation_policy in features
      assert deadlocks() == before

      user_id = ctx.owner.user.id
      assert [%{action: "above_changed", changed_by_id: ^user_id} | _] = history(ctx.owner)

      # The version 1 of the workspace's creation is the one change by nobody.
      refute Enum.any?(
               history(ctx.owner),
               &(is_nil(&1.changed_by_id) and &1.action != "first_version")
             )
    end
  end

  describe "a grant to a client, and its operator's changes" do
    # An operator, made one as the product makes one, and a client of it. A grant to the
    # client locks it `FOR NO KEY UPDATE` and holds its operator `FOR SHARE`, at one point;
    # a drop takes the same rows the same way, a change of the operator's kind locks the
    # operator `FOR UPDATE` first and alone, and its suspension locks it too.
    @describetag needs: [:managed_organisations, :security]

    setup ctx do
      operator = sign_up()

      {:ok, _} =
        Operators.change_kind(ctx.instance_admin, operator.organisation.id, :operator)

      {:ok, in_operator} =
        Organisations.resolve_scope(
          Scope.for_user(operator.user),
          Repo.get!(Organisation, operator.organisation.id).slug
        )

      client = client(in_operator)

      Map.merge(ctx, %{
        operator: Repo.get!(Organisation, operator.organisation.id),
        operator_user: operator.user,
        in_operator: in_operator,
        client: client.organisation
      })
    end

    test "the client given a feature first: its drop waits for it", ctx do
      {:ok, _} = take_from_client(ctx)
      before = deadlocks()

      {grant, grant_pid} = hold(fn -> client_first_half(ctx) end)

      drop = start(fn -> drop(ctx) end)
      await_blocked(drop.backend, grant_pid)
      assert {:ok, _} = continue(grant, fn -> give_client(ctx) end)
      commit(grant)

      assert {:ok, _} = Task.await(drop.task)
      assert deadlocks() == before
      assert Tenants.operator_id(Repo.get!(Organisation, ctx.client.id)) == nil
    end

    test "the client dropped first: its grant waits, and finds it no client", ctx do
      {:ok, _} = take_from_client(ctx)
      before = deadlocks()

      {drop, drop_pid} = hold(fn -> client_first_half(ctx) end)

      grant = start(fn -> give_client(ctx) end)
      await_blocked(grant.backend, drop_pid)
      assert {:ok, _} = continue(drop, fn -> drop(ctx) end)
      commit(drop)

      assert {:error, :not_found} = Task.await(grant.task)
      assert deadlocks() == before
    end

    @tag :feature_sets
    test "the client's grant first: a change of the operator's kind waits, and is refused",
         ctx do
      {:ok, _} = take_from_client(ctx)
      before = deadlocks()

      {grant, grant_pid} = hold(fn -> client_first_half(ctx) end)

      change =
        start(fn -> Operators.change_kind(ctx.instance_admin, ctx.operator.id, :organisation) end)

      await_blocked(change.backend, grant_pid)
      assert {:ok, _} = continue(grant, fn -> give_client(ctx) end)
      commit(grant)

      assert {:error, :has_clients} = Task.await(change.task)
      assert deadlocks() == before
      assert :security in ApiaryPro.Features.of(Repo.get!(Organisation, ctx.client.id))
    end

    @tag :feature_sets
    test "a change of the operator's kind first: the client's grant waits for it", ctx do
      {:ok, _} = take_from_client(ctx)
      before = deadlocks()

      # A change of kind locks the organisation `FOR UPDATE` first and alone, and takes
      # nothing more of the client's.
      {change, change_pid} =
        hold(fn -> Tenants.lock_organisation(ctx.operator.id, "FOR UPDATE") && :ok end)

      grant = start(fn -> give_client(ctx) end)
      await_blocked(grant.backend, change_pid)
      commit(change)

      assert {:ok, _} = Task.await(grant.task)
      assert deadlocks() == before
      assert :security in ApiaryPro.Features.of(Repo.get!(Organisation, ctx.client.id))

      assert {:error, :has_clients} =
               Operators.change_kind(ctx.instance_admin, ctx.operator.id, :organisation)
    end

    @tag :feature_sets
    test "the client's grant first: the operator's suspension waits for it", ctx do
      {:ok, _} = take_from_client(ctx)
      before = deadlocks()

      {grant, grant_pid} = hold(fn -> give_client(ctx) end)
      assert {:ok, granted} = grant.result

      suspension = start(fn -> suspend_operator(ctx) end)
      await_blocked(suspension.backend, grant_pid)
      commit(grant)

      assert {:ok, _} = Task.await(suspension.task)
      assert deadlocks() == before
      assert :security in granted
      assert ApiaryPro.Features.of(Repo.get!(Organisation, ctx.client.id)) == granted
    end

    @tag :feature_sets
    test "the operator's suspension first: the client's grant waits, and is refused as before it",
         ctx do
      {:ok, _} = take_from_client(ctx)
      had = ApiaryPro.Features.of(Repo.get!(Organisation, ctx.client.id))
      recorded = grants_recorded(ctx)
      before = deadlocks()

      {suspension, suspension_pid} = hold(fn -> suspend_operator(ctx) end)
      assert {:ok, _} = suspension.result

      # Asked before the suspension commits, the grant is allowed, and waits for the
      # operator's row.
      grant = start(fn -> give_client(ctx) end)
      await_blocked(grant.backend, suspension_pid)
      commit(suspension)

      refused = Task.await(grant.task)
      assert deadlocks() == before

      # Refused as a grant asked after the suspension is, which the Clients page says in
      # its words for a refusal.
      assert {:error, :forbidden} = refused
      assert give_client(ctx) == refused

      # Nothing written: the client's features and its trail as they were.
      assert ApiaryPro.Features.of(Repo.get!(Organisation, ctx.client.id)) == had
      refute :security in had
      assert grants_recorded(ctx) == recorded
    end

    @tag :feature_sets
    test "a client created between the read of the clients and their lock is taken too", ctx do
      before = deadlocks()

      # A new client, made while the operator's row is held as a creation holds it.
      {creation, creation_pid} = hold(fn -> new_client(ctx) end)
      newcomer = creation.result
      created(%{organisation: newcomer, user: ctx.operator_user})

      # The narrowing reads the operator's clients, which do not hold the newcomer yet,
      # then waits for the operator's row; it stops once written, before its commit.
      narrowing = start_held(fn -> narrow(ctx) end)
      await_blocked(narrowing.backend, creation_pid)
      commit(creation)
      assert {:ok, _} = narrowed(narrowing)

      # It read the clients again once it held them, and holds the newcomer's row too:
      # a third connection may not take it `FOR SHARE`.
      assert %Postgrex.Error{postgres: %{code: :lock_not_available}} =
               Repo.query(
                 "SELECT id FROM organisations WHERE id = $1 FOR SHARE NOWAIT",
                 [Ecto.UUID.dump!(newcomer.id)]
               )
               |> elem(1)

      commit_held(narrowing)
      assert deadlocks() == before
      refute :security in ApiaryPro.Features.of(Repo.get!(Organisation, newcomer.id))
    end
  end

  # `fun` in a transaction on a connection of its own, its backend known before `fun`
  # starts, held open once `fun` answers until `commit_held/1`: for a side that waits on
  # another and must stop before its commit.
  defp start_held(fun) do
    parent = self()

    task =
      Task.async(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(parent, {:backend, self(), backend})

        Repo.transaction(fn ->
          send(parent, {:answered, self(), fun.()})

          receive do
            :commit -> :ok
          end
        end)
      end)

    receive do
      {:backend, pid, backend} -> %{task: task, pid: pid, backend: backend}
    after
      15_000 -> flunk("the second side did not start")
    end
  end

  defp narrowed(%{pid: pid}) do
    receive do
      {:answered, ^pid, result} -> result
    after
      15_000 -> flunk("the second side did not finish its change")
    end
  end

  defp commit_held(%{task: task, pid: pid}) do
    send(pid, :commit)
    assert {:ok, :ok} = Task.await(task, 15_000)
  end

  # The operator narrowed to `observability`: its clients lose the security policy.
  defp narrow(ctx),
    do: Grants.set_organisation(ctx.instance_admin, ctx.operator.id, [:observability])

  defp grant_client(ctx),
    do: Grants.set_client(ctx.in_operator, ctx.client.id, [:observability, :security])

  defp withdraw(ctx),
    do:
      Grants.set_organisation(
        ctx.instance_admin,
        ctx.owner.organisation.id,
        without_security()
      )

  defp allow(scope), do: Policy.allow(scope, nil, %{host: "race.example"})

  defp rule?(scope),
    do:
      Repo.exists?(
        from r in Rule, where: r.workspace_id == ^scope.workspace.id and r.host == "race.example"
      )

  defp reloaded(scope), do: Repo.get!(Apiary.Organisations.Organisation, scope.organisation.id)

  defp take_from_client(ctx),
    do: Grants.set_client(ctx.in_operator, ctx.client.id, [:observability])

  defp give_client(ctx),
    do: Grants.set_client(ctx.in_operator, ctx.client.id, [:observability, :security])

  defp drop(ctx), do: Transfers.drop(ctx.in_operator, ctx.client.id, ctx.client.name)

  defp suspend_operator(ctx),
    do: Suspensions.suspend_organisation(ctx.instance_admin, ctx.operator.id)

  # A client of the operator created as the product creates one.
  defp new_client(ctx) do
    {:ok, %{organisation: newcomer}} =
      Operators.create_client(
        ctx.in_operator,
        %{"name" => Apiary.Races.name("client"), "email" => email()},
        fn token -> "http://localhost/invitations/#{token}" end
      )

    newcomer
  end

  # A grant to the client's and its drop's first half, as `ApiaryPro.Grants` and
  # `ApiaryPro.Transfers` take their locks: the client `FOR NO KEY UPDATE`, its operator
  # `FOR SHARE`, at one point.
  defp client_first_half(ctx) do
    client_id = ctx.client.id

    {:ok, _held} =
      Tenants.lock_organisations([client_id, ctx.operator.id], fn
        ^client_id -> :no_key_update
        _operator -> :share
      end)

    :ok
  end

  # The newest page of the workspace's policy History.
  defp history(scope), do: Policy.list_changes(scope, nil, 1).items

  # How many grants to the client its trail records.
  defp grants_recorded(ctx),
    do:
      Repo.aggregate(
        from(e in Apiary.Audit.Entry,
          where: e.organisation_id == ^ctx.client.id and e.action == "client.grant_features"
        ),
        :count
      )

  # Postgres's count of the deadlocks it broke in this database.
  defp deadlocks do
    %{rows: [[count]]} =
      Repo.query!("SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()")

    count
  end
end
