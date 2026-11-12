defmodule ApiaryPro.GatewayRacesTest do
  # An operator's organisation-level gateways, which serve its clients' workspaces while
  # the operator owns its clients (`ApiaryPro.Flags.operator_infrastructure?/0`), racing
  # what a client's workspace does with them, and the edition's changes of the operator and its
  # clients. Each side runs on a connection of its own, outside the SQL sandbox, so each
  # commits and each waits on the other's locks as it would in production. Not async: what
  # these tests commit is visible to every other test while they run, and they delete it
  # again before they end.
  #
  # The rule under test (`Apiary.Gateways.lock/1`, docs/access.md, The lock order): a
  # change of an operator's organisation-level gateway holds its clients `FOR SHARE` and
  # the operator `FOR NO KEY UPDATE`, in one statement, in the lock order; a change at a
  # client's workspace, a node's or a pool's among it, holds the client and its operator
  # `FOR SHARE`, then the workspace. So the two take turns on the operator's row, and the
  # second sees what the first did. A registration through the gateway and an attach by
  # it hold the gateway's row `FOR SHARE`, which its deletion locks for update. The edition's
  # changes of the operator and its clients take the same rows in the same order, so
  # nothing deadlocks.
  #
  # Each test holds the first side's transaction open until the second side is seen, in
  # the database, waiting on a lock the first side holds (`pg_blocking_pids`), and checks
  # Postgres's count of deadlocks has not moved.
  use ExUnit.Case, async: false
  @before_compile Apiary.TestSetup

  import Ecto.Query
  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.Races
  import ApiaryPro.Races

  alias Apiary.{Gateways, Nodes, Organisations, Policy, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Membership, Organisation}
  alias Apiary.Policy.Rule
  alias Apiary.Runs.{Attach, Run}
  alias ApiaryPro.{Flags, Grants, Operators}
  alias ApiaryPro.Tenants.Tenant
  alias Ecto.Adapters.SQL.Sandbox

  # An operator is `managed_organisations`': left out of a run without it.
  @moduletag needs: :managed_organisations

  setup_all :clean_up_leftovers
  setup :setup_races

  # An operator, made one as the product makes one, with a client, whose owner the
  # operator invited; the flag on for this test's processes; the operator's gateway G, its
  # default, and the instance admin's scope in the instance organisation, whose membership
  # is inserted as it is and goes with their account.
  setup do
    Flags.put_operator_infrastructure(true)

    %{scope: operator_owner, organisation: operator} = sign_up()

    Repo.update_all(from(t in Tenant, where: t.organisation_id == ^operator.id),
      set: [kind: :operator]
    )

    operator = Repo.get!(Organisation, operator.id)
    {:ok, _features} = Grants.written_out(operator, :operator)

    in_operator = scope_in(operator_owner.user, operator.slug)
    client = client(in_operator)

    admin = sign_up()
    instance_organisation = ApiaryPro.Organisations.instance_organisation()

    Repo.insert!(%Membership{
      organisation_id: instance_organisation.id,
      user_id: admin.user.id,
      level: :owner
    })

    gateway = organisation_gateway_fixture(in_operator, name: "edge-1")
    assert gateway.default_gateway

    %{
      operator: operator,
      in_operator: in_operator,
      client: client,
      in_client: client.scope,
      gateway: gateway,
      instance_admin: scope_in(admin.user, instance_organisation.slug)
    }
  end

  defp scope_in(user, slug) do
    {:ok, scope} = Organisations.resolve_scope(Scope.for_user(user), slug)
    scope
  end

  defp reload(%Node{id: id}), do: Repo.get!(Node, id)

  defp pool_on_default(ctx),
    do:
      Nodes.create_node(ctx.in_client, %{
        kind: "pool",
        name: unique_node_name(),
        gateway_choice: "default"
      })

  defp pool_naming(ctx, gateway),
    do:
      Nodes.create_node(ctx.in_client, %{
        kind: "pool",
        name: unique_node_name(),
        gateway_choice: "named",
        gateway_id: gateway.id
      })

  defp errors(changeset), do: Apiary.DataCase.errors_on(changeset)

  # Postgres's own count of deadlocks it broke in this database. A hint only: the count
  # is flushed to `pg_stat_database` some time after the fact. What catches a deadlock is
  # the other assertions: the result each side answers, and the rows it leaves.
  defp deadlocks do
    %{rows: [[count]]} =
      Repo.query!("SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()")

    count
  end

  # The first side held, the second started and seen waiting on it, then the first
  # committed: the first's result and the second's.
  defp race(first, second) do
    before = deadlocks()
    {held, held_pid} = hold(first)
    waiting = start(second)
    await_blocked(waiting.backend, held_pid)
    commit(held)
    answer = Task.await(waiting.task)
    assert deadlocks() == before
    {held.result, answer}
  end

  describe "R1: the operator deletes its default gateway while a pool is made on Default in the client" do
    test "the deletion first: the pool finds no default", ctx do
      {deleted, made} =
        race(fn -> Nodes.delete_node(ctx.in_operator, ctx.gateway) end, fn ->
          pool_on_default(ctx)
        end)

      assert {:ok, %Node{deleted_at: %DateTime{}}} = deleted
      assert {:error, changeset} = made
      assert "has no default gateway" in errors(changeset).gateway_choice
    end

    test "the deletion first, with a second gateway: the pool finds it the default", ctx do
      second = organisation_gateway_fixture(ctx.in_operator, name: "edge-2")

      {deleted, made} =
        race(fn -> Nodes.delete_node(ctx.in_operator, ctx.gateway) end, fn ->
          pool_on_default(ctx)
        end)

      assert {:ok, _deleted} = deleted
      assert {:ok, %Node{gateway_choice: :default} = pool} = made
      assert Gateways.chosen(pool).id == second.id
    end

    test "the pool first: the deletion waits, and the pool stops it", ctx do
      {made, deleted} =
        race(fn -> pool_on_default(ctx) end, fn ->
          Nodes.delete_node(ctx.in_operator, ctx.gateway)
        end)

      assert {:ok, %Node{id: id}} = made
      assert {:error, {:gateway_in_use, %{nodes: [%Node{id: ^id}]}}} = deleted
      refute reload(ctx.gateway).deleted_at
    end
  end

  describe "R2: the operator deletes its gateway while a pool in the client names it" do
    test "the deletion first: the pool may not name it", ctx do
      {deleted, made} =
        race(fn -> Nodes.delete_node(ctx.in_operator, ctx.gateway) end, fn ->
          pool_naming(ctx, ctx.gateway)
        end)

      assert {:ok, _deleted} = deleted
      assert {:error, changeset} = made
      assert "is not a gateway this machine may use" in errors(changeset).gateway_id
    end

    test "the pool first: the deletion is refused, naming it", ctx do
      {made, deleted} =
        race(fn -> pool_naming(ctx, ctx.gateway) end, fn ->
          Nodes.delete_node(ctx.in_operator, ctx.gateway)
        end)

      assert {:ok, %Node{id: id}} = made
      assert {:error, {:gateway_in_use, %{nodes: [%Node{id: ^id}]}}} = deleted
    end
  end

  describe "R3: the operator makes another gateway its default while a pool is made on Default" do
    setup ctx, do: %{second: organisation_gateway_fixture(ctx.in_operator, name: "edge-2")}

    test "the mark first: the pool is made on Default, which is the new default", ctx do
      {marked, made} =
        race(fn -> Nodes.make_default_gateway(ctx.in_operator, ctx.second) end, fn ->
          pool_on_default(ctx)
        end)

      assert {:ok, %Node{default_gateway: true}} = marked
      assert {:ok, %Node{gateway_choice: :default} = pool} = made
      assert Gateways.chosen(pool).id == ctx.second.id
    end

    test "the pool first: it stays on Default, which follows the mark", ctx do
      {made, marked} =
        race(fn -> pool_on_default(ctx) end, fn ->
          Nodes.make_default_gateway(ctx.in_operator, ctx.second)
        end)

      assert {:ok, %Node{gateway_choice: :default} = pool} = made
      assert {:ok, %Node{default_gateway: true}} = marked
      assert reload(pool).gateway_choice == :default
      assert Gateways.chosen(reload(pool)).id == ctx.second.id
    end
  end

  describe "R4: the operator's first gateway while the client's first organisation-level gateway is made" do
    # A node of the client's on Default, which resolved to the operator's gateway of the
    # setup; that gateway deleted while the flag was off, when the client's node did not
    # hold it. So the node is on Default and resolves to none, and each side makes the
    # first gateway of its level: the first made is the node's, and the second moves it
    # nowhere.
    setup ctx do
      node = node_fixture(ctx.in_client, name: unique_node_name(), gateway_choice: "default")
      assert Gateways.chosen(node).id == ctx.gateway.id

      Flags.put_operator_infrastructure(false)
      {:ok, _} = Nodes.delete_node(ctx.in_operator, ctx.gateway)
      Flags.put_operator_infrastructure(true)

      node = reload(node)
      assert node.gateway_choice == :default
      assert Gateways.chosen(node) == nil
      %{node: node}
    end

    test "the operator's first: it is the default, the node's, and the client's is not", ctx do
      {operators, clients} =
        race(
          fn -> Nodes.create_organisation_gateway(ctx.in_operator, gateway_attrs("edge-o")) end,
          fn -> Nodes.create_organisation_gateway(ctx.in_client, gateway_attrs("edge-c")) end
        )

      assert {:ok, %Node{default_gateway: true} = operator_gateway} = operators
      assert {:ok, %Node{default_gateway: false}} = clients
      assert Gateways.chosen(reload(ctx.node)).id == operator_gateway.id
    end

    test "the client's first: it is the default and the node's, and the operator's moves no node",
         ctx do
      {clients, operators} =
        race(
          fn -> Nodes.create_organisation_gateway(ctx.in_client, gateway_attrs("edge-c")) end,
          fn -> Nodes.create_organisation_gateway(ctx.in_operator, gateway_attrs("edge-o")) end
        )

      assert {:ok, %Node{default_gateway: true} = client_gateway} = clients
      assert {:ok, %Node{default_gateway: true}} = operators
      assert Gateways.default_gateway_for(ctx.client.workspace).id == client_gateway.id
      assert Gateways.chosen(reload(ctx.node)).id == client_gateway.id
    end
  end

  describe "R5: the operator deletes its gateway while a client's run registers through it" do
    setup ctx, do: through_gateway(ctx)

    test "the deletion first: the registration finds the gateway gone", ctx do
      run_id = Ecto.UUID.generate()

      {deleted, registered} =
        race(
          fn ->
            {:ok, _} = Nodes.update_node(ctx.in_client, ctx.node, %{gateway_choice: "direct"})
            Nodes.delete_node(ctx.in_operator, ctx.gateway)
          end,
          fn -> register_run(ctx.key, gateway_registration(run_id), instance_id()) end
        )

      assert {:ok, _deleted} = deleted
      assert {:error, :gateway_not_serving} = registered
      refute Repo.exists?(from r in Run, where: r.node_run_id == ^run_id)
    end

    test "the registration first: the deletion finds its run", ctx do
      # The node goes directly once its key is verified: only the run will hold the gateway.
      {:ok, _} = Nodes.update_node(ctx.in_client, ctx.node, %{gateway_choice: "direct"})
      run_id = Ecto.UUID.generate()
      before = deadlocks()

      # A row of the same run id, inserted and not committed: the registration's insert
      # waits for it, with the gateway's row held `FOR SHARE`, until it rolls back.
      {holder, holder_backend} = held_run(ctx, run_id)

      registration =
        start(fn -> register_run(ctx.key, gateway_registration(run_id), instance_id()) end)

      await_blocked(registration.backend, holder_backend)

      # The deletion waits for the gateway's row, held by the registration.
      deletion = start(fn -> Nodes.delete_node(ctx.in_operator, ctx.gateway) end)
      await_blocked(deletion.backend, registration.backend)
      send(holder.pid, :release)
      assert {:error, :released} = Task.await(holder)

      assert {:ok, %{run: %Run{id: id}}} = Task.await(registration.task)

      assert {:error, {:gateway_in_use, %{nodes: [], runs: [%Run{id: ^id}]}}} =
               Task.await(deletion.task)

      refute reload(ctx.gateway).deleted_at
      assert deadlocks() == before
    end
  end

  describe "R6: the operator deletes its gateway while it attaches a client's run" do
    # One order only: a deletion that comes first is refused while the run waits for its
    # attach, and refused it holds nothing; one that goes through comes once the run's
    # window has closed, and the attach is then refused as expired whatever the deletion
    # did.
    setup ctx do
      ctx = Map.merge(ctx, through_gateway(ctx))

      {:ok, %{run: run, run_key: run_key}} =
        register_run(ctx.key, gateway_registration(), instance_id())

      {:ok, _} = Nodes.update_node(ctx.in_client, ctx.node, %{gateway_choice: "direct"})
      {:ok, body} = Attach.parse(attach_body(run_key))
      Map.merge(ctx, %{run: run, body: body})
    end

    test "the attach first: the deletion finds the run attached", ctx do
      {attached, deleted} =
        race(
          fn -> Attach.attach(ctx.gateway_key, ctx.run.node_run_id, ctx.body, %{}) end,
          fn -> Nodes.delete_node(ctx.in_operator, ctx.gateway) end
        )

      assert {:ok, %{run: %Run{id: id, attached_at: %DateTime{}}}} = attached
      assert {:error, {:gateway_in_use, %{runs: [%Run{id: ^id}]}}} = deleted
      refute reload(ctx.gateway).deleted_at
    end
  end

  describe "R7: a change of the operator's gateways" do
    @tag :feature_sets
    test "first, a grant of the operator's features waits for it", ctx do
      {made, granted} = race(fn -> new_gateway(ctx) end, fn -> regrant(ctx) end)
      assert {:ok, %Node{}} = made
      assert {:ok, _features} = granted
    end

    @tag :feature_sets
    test "after a grant of the operator's features, waits for it", ctx do
      {granted, made} = race(fn -> regrant(ctx) end, fn -> new_gateway(ctx) end)
      assert {:ok, _features} = granted
      assert {:ok, %Node{}} = made
    end

    test "first, a new client waits for it", ctx do
      {made, created} = race(fn -> new_gateway(ctx) end, fn -> new_client(ctx) end)
      assert {:ok, %Node{}} = made
      assert {:ok, %{organisation: %Organisation{} = client}} = created
      remember(client)
    end

    test "after a new client, waits for it, and the new client holds no node", ctx do
      {created, made} = race(fn -> new_client(ctx) end, fn -> new_gateway(ctx) end)
      assert {:ok, %{organisation: %Organisation{id: id} = client}} = created
      remember(client)
      assert {:ok, %Node{}} = made
      refute Repo.exists?(from n in Node, where: n.organisation_id == ^id)
    end

    @tag needs: [:managed_organisations, :security]
    test "first, a policy write in the client waits for it", ctx do
      {made, written} = race(fn -> new_gateway(ctx) end, fn -> allow(ctx.client.owner.scope) end)
      assert {:ok, %Node{}} = made
      assert {:ok, %Rule{}} = written
    end

    @tag needs: [:managed_organisations, :security]
    test "after a policy write in the client, waits for it", ctx do
      {written, made} = race(fn -> allow(ctx.client.owner.scope) end, fn -> new_gateway(ctx) end)
      assert {:ok, %Rule{}} = written
      assert {:ok, %Node{}} = made
    end

    test "first, a node made in the client waits for it", ctx do
      {made, node} = race(fn -> new_gateway(ctx) end, fn -> pool_on_default(ctx) end)
      assert {:ok, %Node{}} = made
      assert {:ok, %Node{gateway_choice: :default}} = node
    end

    test "after a node made in the client, waits for it", ctx do
      {node, made} = race(fn -> pool_on_default(ctx) end, fn -> new_gateway(ctx) end)
      assert {:ok, %Node{gateway_choice: :default}} = node
      assert {:ok, %Node{}} = made
    end
  end

  describe "R8: a node made in the client while the operator grants the client its features" do
    @tag :feature_sets
    test "the node first: the grant waits for it", ctx do
      {node, granted} = race(fn -> pool_on_default(ctx) end, fn -> grant_client(ctx) end)
      assert {:ok, %Node{}} = node
      assert {:ok, _features} = granted
    end

    @tag :feature_sets
    test "the grant first: the node waits for it", ctx do
      {granted, node} = race(fn -> grant_client(ctx) end, fn -> pool_on_default(ctx) end)
      assert {:ok, _features} = granted
      assert {:ok, %Node{}} = node
    end
  end

  # A node in the client's workspace that names the operator's gateway, with its key, and
  # the gateway's key, each as a verified request carries it.
  defp through_gateway(ctx) do
    node =
      node_fixture(ctx.in_client,
        name: unique_node_name(),
        gateway_choice: "named",
        gateway_id: ctx.gateway.id
      )

    %{access_key: key} = contract_key_fixture(ctx.in_client, node: node)
    %{access_key: gateway_key} = contract_key_fixture(ctx.in_operator, node: ctx.gateway)
    %{node: node, key: key, gateway_key: gateway_key}
  end

  # A run of `run_id` in the client's workspace, inserted on a connection of its own and
  # held uncommitted until the test sends `:release`, which rolls it back: the task and
  # its backend.
  defp held_run(ctx, run_id) do
    test = self()

    holder =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")

        Repo.transaction(fn ->
          Repo.insert!(%Run{
            organisation_id: ctx.client.organisation.id,
            workspace_id: ctx.client.workspace.id,
            node_run_id: run_id
          })

          send(test, {:held_run, backend})
          receive do: (:release -> Repo.rollback(:released))
        end)
      end)

    receive do
      {:held_run, backend} -> {holder, backend}
    after
      10_000 -> flunk("the run was not held")
    end
  end

  defp gateway_attrs(name), do: %{name: name, url: "https://#{name}.example"}

  defp new_gateway(ctx),
    do:
      Nodes.create_organisation_gateway(
        ctx.in_operator,
        gateway_attrs("edge-#{System.unique_integer([:positive])}")
      )

  # The operator's features granted again as they are: its rows locked as for any grant.
  defp regrant(ctx) do
    features = form(Repo.get!(Organisation, ctx.operator.id)) -- [:managed_organisations]
    Grants.set_organisation(ctx.instance_admin, ctx.operator.id, features)
  end

  defp grant_client(ctx) do
    features = form(Repo.get!(Organisation, ctx.client.organisation.id))
    Grants.set_client(ctx.in_operator, ctx.client.organisation.id, features)
  end

  # What a Features form names of what the organisation is shown: the built features, as
  # its boxes are, without one no box offers, such as `secrets`, which only the instance
  # switches.
  defp form(organisation) do
    offered = Apiary.Features.built() -- ApiaryPro.Features.instance_switched()
    Enum.filter(ApiaryPro.Features.of(organisation), &(&1 in offered))
  end

  defp new_client(ctx) do
    email = email()

    Operators.create_client(
      ctx.in_operator,
      %{"name" => name("client"), "email" => email},
      &"http://localhost/invitations/#{&1}"
    )
  end

  # A client the race made, whose first owner has not joined: deleted with the race's
  # organisations, before its operator.
  defp remember(%Organisation{id: id}) do
    Agent.update(Process.get(Apiary.Races), fn created ->
      %{created | organisations: [id | created.organisations]}
    end)
  end

  defp allow(scope), do: Policy.allow(scope, nil, %{host: "race.example"})
end
