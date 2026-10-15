defmodule Apiary.AdaptersRacesTest do
  # The connections of an organisation to the instance's adapters, racing: two presses of
  # Install, a return against the adapter's disconnect, and an adapter's deletion against
  # a pool naming it. Each side runs on a separate connection, outside the SQL sandbox, so
  # each commits and each waits on the other's locks as it would in production. Not async:
  # what these tests commit is visible to every other test while they run, and they delete
  # it again before they end. The adapters, which are the instance's, are named as the
  # races' organisations are, and deleted with what names them, and the entries they left
  # in the trail of the instance's organisation.
  #
  # The rules under test (`Apiary.Adapters.Connections`): one connection that has not
  # ended per organisation and adapter, the second insert waiting on the first's; and the
  # lock order, the adapter's row, then its connections, then the pools.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.Races

  alias Apiary.{Adapters, Edition, Nodes, Repo}
  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Connection, Connections}
  alias Apiary.Audit.Entry
  alias Apiary.Nodes.Node
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag needs: :factory

  setup_all do
    clean_up_leftovers(%{})
    :ok = Sandbox.checkout(Repo, sandbox: false)
    delete_adapters(from(n in Node, where: n.kind == :adapter and like(n.name, "Races %")))
    Sandbox.checkin(Repo)
    :ok
  end

  setup :setup_races

  setup do
    started = DateTime.utc_now()
    {:ok, made} = Agent.start(fn -> [] end)
    Process.put(:race_adapters, made)

    # Registered after the setup of `Apiary.Races`, so it runs before that one: the
    # adapters and what names them first, then the organisations.
    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      ids = Agent.get(made, & &1)
      Agent.stop(made)
      delete_adapters(from(n in Node, where: n.id in ^ids))

      Repo.delete_all(
        from e in Entry,
          where: e.organisation_id == ^Edition.instance_organisation_id(),
          where: e.inserted_at >= ^started
      )

      Sandbox.checkin(Repo)
    end)

    :ok
  end

  defp delete_adapters(query) do
    ids = Repo.all(select(query, [n], n.id))
    Repo.delete_all(from c in Connection, where: c.adapter_id in ^ids)
    Repo.update_all(from(n in Node, where: n.served_by_id in ^ids), set: [served_by_id: nil])
    Repo.delete_all(from k in AccessKey, where: k.node_id in ^ids)
    Repo.delete_all(from c in EnrolmentCode, where: c.node_id in ^ids)
    Repo.delete_all(from n in Node, where: n.id in ^ids)
  end

  # An adapter of the instance, connectable, remembered for `on_exit`.
  defp adapter do
    made = connectable_adapter_fixture(%{name: name("adapter")})
    Agent.update(Process.get(:race_adapters), &[made.adapter.id | &1])
    made
  end

  defp key_scope(key) do
    {:ok, verified} = AccessKeys.fetch_for_verification(key.key_id)
    Scope.for_access_key(verified)
  end

  describe "two presses of Install" do
    test "the second waits for the first's connection, and takes it with a new pass" do
      %{scope: scope} = sign_up()
      %{scope: admin, user: other} = member(scope, :admin)
      %{adapter: adapter} = adapter()

      {first, first_pid} = hold(fn -> Adapters.connect(scope, adapter) end)
      assert {:ok, _url, {public_id, first_nonce}} = first.result

      second = start(fn -> Adapters.connect(admin, adapter) end)
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, _url, {^public_id, second_nonce}} = Task.await(second.task)
      refute first_nonce == second_nonce

      assert [%Connection{public_id: ^public_id, created_by_id: by, pass_nonce: kept}] =
               Repo.all(from c in Connection, where: c.adapter_id == ^adapter.id)

      assert by == other.id
      assert Apiary.Contract.Ed25519.encode(kept) == second_nonce
    end

    test "many at once make one connection" do
      %{scope: scope} = sign_up()
      %{adapter: adapter} = adapter()
      n = sides(6)

      results = together(for _ <- 1..n, do: fn -> Adapters.connect(scope, adapter) end)

      assert Enum.all?(results, &match?({:ok, _url, {_id, _nonce}}, &1))
      assert [_one] = results |> Enum.map(fn {:ok, _, {id, _}} -> id end) |> Enum.uniq()

      assert Repo.aggregate(from(c in Connection, where: c.adapter_id == ^adapter.id), :count) ==
               1
    end
  end

  describe "a return and the adapter's disconnect" do
    setup do
      %{scope: scope} = sign_up()
      %{adapter: adapter, pair: pair, access_key: key} = adapter()
      {connection, _nonce} = connection_fixture(scope, adapter, :activated)
      # A second press while it is pending: a new pass, whose return comes back.
      {:ok, _url, {_id, nonce}} = Adapters.connect(scope, adapter)
      token = return_token(pair.secret, connection.public_id, nonce)
      %{scope: scope, connection: connection, nonce: nonce, token: token, key: key}
    end

    test "the return first: the disconnect waits, then ends it", ctx do
      {first, first_pid} =
        hold(fn ->
          Connections.complete_return(ctx.scope, ctx.connection.public_id, ctx.token, ctx.nonce)
        end)

      assert first.result == {:ok, :linked}

      second =
        start(fn -> Connections.end_connection(key_scope(ctx.key), ctx.connection.public_id) end)

      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, %Connection{state: :ended}} = Task.await(second.task)
    end

    test "the disconnect first: the return waits, then finds it ended", ctx do
      {first, first_pid} =
        hold(fn -> Connections.end_connection(key_scope(ctx.key), ctx.connection.public_id) end)

      assert {:ok, %Connection{state: :ended}} = first.result

      second =
        start(fn ->
          Connections.complete_return(ctx.scope, ctx.connection.public_id, ctx.token, ctx.nonce)
        end)

      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :not_found}

      assert %Connection{state: :ended, pass_nonce_used_at: nil} =
               Repo.get!(Connection, ctx.connection.id)
    end
  end

  describe "an adapter's deletion and a pool naming it" do
    setup do
      %{scope: scope} = sign_up()
      %{adapter: adapter} = adapter()
      {connection, _nonce} = connection_fixture(scope, adapter, :connected)
      pool = pool_fixture(scope, name: "spot-runners")
      admin = Apiary.OrganisationsFixtures.instance_admin_scope()
      %{scope: scope, adapter: adapter, connection: connection, pool: pool, admin: admin}
    end

    test "the pool named first: the deletion waits, then ends the connection and clears the pool",
         ctx do
      {first, first_pid} =
        hold(fn -> Nodes.update_node(ctx.scope, ctx.pool, %{served_by_id: ctx.adapter.id}) end)

      assert {:ok, %Node{}} = first.result

      second = start(fn -> Adapters.delete_adapter(ctx.admin, ctx.adapter) end)
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, %Node{deleted_at: %DateTime{}}} = Task.await(second.task)
      assert Repo.get!(Node, ctx.pool.id).served_by_id == nil
      assert Repo.get!(Connection, ctx.connection.id).state == :ended

      assert %Entry{details: details} =
               Repo.one!(
                 from e in Entry,
                   where: e.action == "adapter.delete" and e.subject_id == ^ctx.adapter.id
               )

      assert details["unserved_pool_ids"] == [ctx.pool.public_id]
      assert details["ended_connection_ids"] == [ctx.connection.public_id]
    end

    test "the deletion first: the pool's change waits, then is refused", ctx do
      {first, first_pid} = hold(fn -> Adapters.delete_adapter(ctx.admin, ctx.adapter) end)
      assert {:ok, %Node{}} = first.result

      second =
        start(fn -> Nodes.update_node(ctx.scope, ctx.pool, %{served_by_id: ctx.adapter.id}) end)

      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:error, %Ecto.Changeset{} = changeset} = Task.await(second.task)
      assert {_message, _} = changeset.errors[:served_by_id]
      assert Repo.get!(Node, ctx.pool.id).served_by_id == nil
    end
  end

  describe "ends and pools crossing over" do
    # Two connections of one organisation, each ending (its row locked first, the pools
    # it served cleared after), and two pools crossing over to the other's adapter. Were a
    # pool's change to lock its pool before the connection it names, the four would wait
    # in a ring: each end on the pool the other change holds, each change on the
    # connection the other end holds. A change takes the connection first
    # (`Apiary.Adapters.lock_serving/2`), so it waits holding nothing, and each end's
    # second half goes through.
    test "each end's second half goes through while the pools' changes wait" do
      %{scope: scope, user: user} = sign_up()
      %{adapter: a} = adapter()
      %{adapter: b} = adapter()
      {to_a, _} = connection_fixture(scope, a, :connected)
      {to_b, _} = connection_fixture(scope, b, :connected)

      # Each pool in a separate workspace, so the changes of the two do not take turns
      # on one workspace's lock (`Apiary.Gateways.lock/1`).
      other =
        Apiary.OrganisationsFixtures.workspace_scope(
          user,
          Apiary.OrganisationsFixtures.workspace_fixture(scope.organisation)
        )

      on_a = pool_fixture(scope)
      on_b = pool_fixture(other)
      {:ok, _} = Nodes.update_node(scope, on_a, %{served_by_id: a.id})
      {:ok, _} = Nodes.update_node(other, on_b, %{served_by_id: b.id})

      # The first half of an end: the connection's row, locked and ended.
      first_half = fn connection ->
        fn ->
          Repo.one!(from c in Connection, where: c.id == ^connection.id, lock: "FOR UPDATE")

          Repo.update_all(from(c in Connection, where: c.id == ^connection.id),
            set: [state: :ended, ended_at: DateTime.utc_now(), ended_reason: :adapter_reported]
          )
        end
      end

      # The second half: the pools of the organisation the adapter served.
      second_half = fn adapter ->
        fn ->
          Repo.update_all(
            from(n in Node,
              where: n.organisation_id == ^scope.organisation.id and n.served_by_id == ^adapter.id
            ),
            set: [served_by_id: nil]
          )
        end
      end

      {end_a, end_a_pid} = hold(first_half.(to_a))
      {end_b, end_b_pid} = hold(first_half.(to_b))

      a_to_b = start(fn -> Nodes.update_node(scope, on_a, %{served_by_id: b.id}) end)
      await_blocked(a_to_b.backend, end_b_pid)
      b_to_a = start(fn -> Nodes.update_node(other, on_b, %{served_by_id: a.id}) end)
      await_blocked(b_to_a.backend, end_a_pid)

      assert {1, _} = continue(end_a, second_half.(a))
      assert {1, _} = continue(end_b, second_half.(b))
      commit(end_a)
      commit(end_b)

      assert {:error, %Ecto.Changeset{}} = Task.await(a_to_b.task)
      assert {:error, %Ecto.Changeset{}} = Task.await(b_to_a.task)

      for pool <- [on_a, on_b], do: assert(Repo.get!(Node, pool.id).served_by_id == nil)
    end
  end
end
