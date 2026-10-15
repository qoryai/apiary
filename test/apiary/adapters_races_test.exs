defmodule Apiary.AdaptersRacesTest do
  # The connections of an organisation to the instance's adapters, racing: two presses of
  # Install, a return against the adapter's disconnect, a linked return against a press,
  # a press on a connected connection no listing has named against the first listing, a
  # return, the disconnect, the deletion, another press and a pool naming it, and an
  # adapter's deletion against a pool naming it, before, after and between the pool's
  # locks. Each side runs on a separate
  # connection, outside the SQL sandbox, so each commits and each waits on the other's
  # locks as it would in production. Not async: what these tests commit is visible to
  # every other test while they run, and they delete it again before they end. The
  # adapters, which are the instance's, are named as the races' organisations are, and
  # deleted with what names them, and the entries they left in the trail of the
  # instance's organisation.
  #
  # The rules under test (`Apiary.Adapters.Connections`): one connection that has not
  # ended per organisation and adapter, the second insert waiting on the first's; a press
  # on a connected connection, not yet listed, replacing it; and the lock order, the
  # adapter's row, then its connections, then the pools.
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

  # When the pass in a connect address expires, as its payload says.
  defp expiry(url) do
    [_address, pass] = String.split(url, "state=")
    [payload, _signature] = String.split(pass, ".")
    %{"expires_at" => at} = payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
    {:ok, time, 0} = DateTime.from_iso8601(at)
    time
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

      assert {:ok, second_url, {^public_id, second_nonce}} = Task.await(second.task)
      refute first_nonce == second_nonce

      assert [
               %Connection{
                 public_id: ^public_id,
                 created_by_id: by,
                 pass_nonce: kept,
                 pass_expires_at: kept_expiry
               }
             ] = Repo.all(from c in Connection, where: c.adapter_id == ^adapter.id)

      assert by == other.id
      assert Apiary.Contract.Ed25519.encode(kept) == second_nonce

      # The second read the first's expiry under the row's lock, after the first committed:
      # its pass expires strictly later, and the connection keeps it.
      {:ok, first_url, _session} = first.result
      assert DateTime.compare(expiry(second_url), expiry(first_url)) == :gt
      assert kept_expiry == expiry(second_url)
    end

    test "many at once make one connection" do
      %{scope: scope} = sign_up()
      %{adapter: adapter} = adapter()
      n = sides(6)

      results = together(for _ <- 1..n, do: fn -> Adapters.connect(scope, adapter) end)

      assert Enum.all?(results, &match?({:ok, _url, {_id, _nonce}}, &1))
      assert [_one] = results |> Enum.map(fn {:ok, _, {id, _}} -> id end) |> Enum.uniq()

      assert [%Connection{pass_expires_at: kept_expiry}] =
               Repo.all(from c in Connection, where: c.adapter_id == ^adapter.id)

      # One after another under the row's lock, each pass expires strictly later than the
      # one before it, and the connection keeps the last.
      expiries = Enum.map(results, fn {:ok, url, _session} -> expiry(url) end)
      assert length(Enum.uniq(expiries)) == n
      assert kept_expiry == Enum.max(expiries, DateTime)
    end
  end

  describe "a return and the adapter's disconnect" do
    # A pending connection with a pass, and the return that says it is linked. The
    # adapter's disconnect reaches a connection pending or connected, under its row held
    # `FOR UPDATE`, as the return holds it: whichever comes first, the other waits.
    setup do
      %{scope: scope} = sign_up()
      %{adapter: adapter, pair: pair, access_key: key} = adapter()
      {connection, nonce} = connection_fixture(scope, adapter, :pending)
      token = return_token(pair.secret, connection.public_id, nonce)
      %{scope: scope, connection: connection, nonce: nonce, token: token, key: key}
    end

    test "the return first: the disconnect waits, then ends the connection it connected", ctx do
      {first, first_pid} =
        hold(fn ->
          Connections.complete_return(ctx.scope, ctx.connection.public_id, ctx.token, ctx.nonce)
        end)

      assert first.result == {:ok, :linked}

      second =
        start(fn -> Connections.end_connection(key_scope(ctx.key), ctx.connection.public_id) end)

      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, %Connection{state: :ended, connected_at: %DateTime{}}} =
               Task.await(second.task)

      assert %Connection{state: :ended, ended_reason: :adapter_reported} =
               Repo.get!(Connection, ctx.connection.id)
    end

    test "the disconnect of the pending connection first: the return waits, then is not found",
         ctx do
      {first, first_pid} =
        hold(fn -> Connections.end_connection(key_scope(ctx.key), ctx.connection.public_id) end)

      assert {:ok, %Connection{state: :ended, connected_at: nil}} = first.result

      second =
        start(fn ->
          Connections.complete_return(ctx.scope, ctx.connection.public_id, ctx.token, ctx.nonce)
        end)

      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :not_found}

      assert %Connection{
               state: :ended,
               ended_reason: :adapter_reported,
               connected_at: nil,
               pass_nonce_used_at: nil
             } = Repo.get!(Connection, ctx.connection.id)
    end

    test "the disconnect first: the used return again waits, then finds it ended", ctx do
      assert {:ok, :linked} =
               Connections.complete_return(
                 ctx.scope,
                 ctx.connection.public_id,
                 ctx.token,
                 ctx.nonce
               )

      connected = Repo.get!(Connection, ctx.connection.id)

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

      assert %Connection{state: :ended} = ended = Repo.get!(Connection, ctx.connection.id)

      fields = [:connected_at, :pass_nonce, :pass_nonce_used_at, :created_by_id]
      assert Map.take(ended, fields) == Map.take(connected, fields)
    end
  end

  describe "a linked return and a press of Install" do
    test "the return first: the press waits, then replaces the connection it connected" do
      %{scope: scope} = sign_up()
      %{scope: admin} = member(scope, :admin)
      %{adapter: adapter, pair: pair} = adapter()
      {connection, nonce} = connection_fixture(scope, adapter, :pending)
      token = return_token(pair.secret, connection.public_id, nonce)

      {first, first_pid} =
        hold(fn -> Connections.complete_return(scope, connection.public_id, token, nonce) end)

      assert first.result == {:ok, :linked}

      second = start(fn -> Adapters.connect(admin, adapter) end)
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, _url, {public_id, _nonce}} = Task.await(second.task)
      refute public_id == connection.public_id

      assert %Connection{state: :ended, ended_reason: :replaced, connected_at: %DateTime{}} =
               Repo.get!(Connection, connection.id)

      assert %Connection{state: :pending, connected_at: nil} =
               Repo.get_by!(Connection, public_id: public_id)
    end

    test "the press first: the return waits, then is not found, under the earlier pass" do
      %{scope: scope} = sign_up()
      %{scope: admin} = member(scope, :admin)
      %{adapter: adapter, pair: pair} = adapter()
      {connection, nonce} = connection_fixture(scope, adapter, :pending)
      token = return_token(pair.secret, connection.public_id, nonce)

      {first, first_pid} = hold(fn -> Adapters.connect(admin, adapter) end)
      assert {:ok, _url, {public_id, _nonce}} = first.result
      assert public_id == connection.public_id

      second =
        start(fn -> Connections.complete_return(scope, connection.public_id, token, nonce) end)

      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :not_found}

      assert %Connection{state: :pending, connected_at: nil, pass_nonce_used_at: nil} =
               Repo.get!(Connection, connection.id)
    end
  end

  describe "a press of Install on a connected connection no listing has named" do
    # A connection that a linked return connected, which no listing has named yet: a press
    # ends it (`replaced`), clears the pools it served, and makes a new one in its place,
    # in one transaction, under the adapter's row held `FOR SHARE` and the connection's
    # `FOR UPDATE`.
    setup do
      %{scope: scope} = sign_up()
      %{scope: admin, user: other} = member(scope, :admin)
      %{adapter: adapter, pair: pair, access_key: key} = adapter()
      {connection, nonce} = connection_fixture(scope, adapter, :connected)

      %{
        scope: scope,
        admin: admin,
        other: other,
        adapter: adapter,
        pair: pair,
        key: key,
        connection: connection,
        nonce: nonce
      }
    end

    defp press(ctx, presser \\ :admin),
      do: fn -> Adapters.connect(Map.fetch!(ctx, presser), ctx.adapter) end

    # The adapter's first listing that names the connection: found for its key, then
    # recorded (`Connections.mark_listed/1`).
    defp listing(ctx) do
      fn ->
        with {:ok, connection, _scope} <-
               Connections.connection_for_key(
                 key_scope(ctx.key),
                 ctx.connection.public_id,
                 :"source_item.post"
               ),
             do: Connections.mark_listed(connection)
      end
    end

    defp live(ctx) do
      Repo.all(
        from c in Connection,
          where: c.adapter_id == ^ctx.adapter.id and is_nil(c.ended_at),
          select: c.public_id
      )
    end

    defp all(ctx),
      do: Repo.aggregate(from(c in Connection, where: c.adapter_id == ^ctx.adapter.id), :count)

    # The old connection ended for `reason`, with its pass, its person and the time it
    # connected as they were; the adapter's key, unless the adapter was deleted with its keys,
    # reaches it no more.
    defp ended_as(ctx, reason, deleted? \\ false) do
      assert %Connection{state: :ended, ended_reason: ^reason} =
               ended = Repo.get!(Connection, ctx.connection.id)

      fields = [:connected_at, :pass_nonce, :pass_nonce_used_at, :created_by_id]
      assert Map.take(ended, fields) == Map.take(ctx.connection, fields)

      if not deleted? do
        assert Connections.connection_for_key(
                 key_scope(ctx.key),
                 ctx.connection.public_id,
                 :"source_item.post"
               ) == {:error, :ended}
      end
    end

    # The connection `public_id` is the one live, pending, started by the admin with the
    # pass `nonce`.
    defp replaced_by(ctx, public_id, nonce) do
      assert live(ctx) == [public_id]

      assert %Connection{
               state: :pending,
               connected_at: nil,
               pass_nonce_used_at: nil,
               created_by_id: by,
               pass_nonce: kept
             } = Repo.get_by!(Connection, public_id: public_id)

      assert by == ctx.other.id
      assert Apiary.Contract.Ed25519.encode(kept) == nonce
    end

    test "the first listing first: the press waits, then is refused, and nothing changes",
         ctx do
      {first, first_pid} = hold(listing(ctx))
      assert {:ok, %Connection{state: :connected, listed_at: %DateTime{}}} = first.result

      second = start(press(ctx))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :connected}
      assert live(ctx) == [ctx.connection.public_id]

      assert %Connection{state: :connected, listed_at: %DateTime{}} =
               Repo.get!(Connection, ctx.connection.id)
    end

    test "the press first: the listing waits, then finds it ended, and nothing is listed",
         ctx do
      {first, first_pid} = hold(press(ctx))
      assert {:ok, _url, {public_id, nonce}} = first.result

      # Found before the press commits, then waiting on the row to record the listing.
      second = start(listing(ctx))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :ended}
      ended_as(ctx, :replaced)
      replaced_by(ctx, public_id, nonce)

      assert Repo.aggregate(
               from(c in Connection,
                 where: c.adapter_id == ^ctx.adapter.id and not is_nil(c.listed_at)
               ),
               :count
             ) == 0
    end

    test "a pool named first: the press waits, then replaces the connection and clears the pool",
         ctx do
      pool = pool_fixture(ctx.scope, name: "spot-runners")

      {first, first_pid} =
        hold(fn -> Nodes.update_node(ctx.scope, pool, %{served_by_id: ctx.adapter.id}) end)

      assert {:ok, %Node{}} = first.result

      second = start(press(ctx))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, _url, {public_id, nonce}} = Task.await(second.task)
      ended_as(ctx, :replaced)
      replaced_by(ctx, public_id, nonce)
      assert Repo.get!(Node, pool.id).served_by_id == nil
    end

    test "the press first: a pool's change waits, then is refused", ctx do
      pool = pool_fixture(ctx.scope, name: "spot-runners")
      {first, first_pid} = hold(press(ctx))
      assert {:ok, _url, {public_id, nonce}} = first.result

      second =
        start(fn -> Nodes.update_node(ctx.scope, pool, %{served_by_id: ctx.adapter.id}) end)

      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:error, %Ecto.Changeset{} = changeset} = Task.await(second.task)
      assert {_message, _} = changeset.errors[:served_by_id]
      ended_as(ctx, :replaced)
      replaced_by(ctx, public_id, nonce)
      assert Repo.get!(Node, pool.id).served_by_id == nil
    end

    # A pool's change, or a pool made, holds the connection `FOR SHARE` first; the press,
    # started in between, holds the adapter's row `FOR SHARE` and waits on the connection.
    # The change then takes the adapter's row `FOR KEY SHARE`, as Postgres checks the
    # reference `served_by_id`, which the press's lock lets through.
    for {what, change} <- [
          {"a pool's change", :update},
          {"a pool made with it", :create}
        ] do
      test "#{what} between its two locks goes through, then the press clears it", ctx do
        pool = if unquote(change) == :update, do: pool_fixture(ctx.scope, name: "spot-runners")

        {held, held_pid} =
          hold(fn -> Connections.lock_serving(ctx.scope, %{served_by_id: ctx.adapter.id}) end)

        pressed = start(press(ctx))
        await_waited(pressed.backend, held_pid)

        assert {:ok, %Node{} = pool} =
                 continue(held, fn ->
                   case unquote(change) do
                     :update ->
                       Nodes.update_node(ctx.scope, pool, %{served_by_id: ctx.adapter.id})

                     :create ->
                       Nodes.create_node(ctx.scope, %{
                         kind: "pool",
                         name: "spot-runners",
                         served_by_id: ctx.adapter.id
                       })
                   end
                 end)

        assert pool.served_by_id == ctx.adapter.id
        commit(held)

        assert {:ok, _url, {public_id, nonce}} = Task.await(pressed.task)
        ended_as(ctx, :replaced)
        replaced_by(ctx, public_id, nonce)
        assert Repo.get!(Node, pool.id).served_by_id == nil
      end
    end

    test "the press first: a return for the old connection waits, then changes nothing",
         ctx do
      {first, first_pid} = hold(press(ctx))
      assert {:ok, _url, {public_id, nonce}} = first.result

      token = return_token(ctx.pair.secret, ctx.connection.public_id, ctx.nonce)

      second =
        start(fn ->
          Connections.complete_return(ctx.scope, ctx.connection.public_id, token, ctx.nonce)
        end)

      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :not_found}
      ended_as(ctx, :replaced)
      replaced_by(ctx, public_id, nonce)
    end

    test "the adapter's disconnect first: the press waits, then starts a new one", ctx do
      {first, first_pid} =
        hold(fn -> Connections.end_connection(key_scope(ctx.key), ctx.connection.public_id) end)

      assert {:ok, %Connection{state: :ended}} = first.result

      second = start(press(ctx))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, _url, {public_id, nonce}} = Task.await(second.task)
      refute public_id == ctx.connection.public_id
      ended_as(ctx, :adapter_reported)
      replaced_by(ctx, public_id, nonce)
    end

    test "the disconnect's lock before the press's insert, its end after: the press tries again",
         ctx do
      # The two halves of `Connections.end_connection/2`: the row locked, then ended. The
      # press's insert finds the row live and does nothing; its lock waits on the row, and
      # finds it ended, so no live row; it tries again, and makes a new one.
      {first, first_pid} =
        hold(fn ->
          Repo.one!(from c in Connection, where: c.id == ^ctx.connection.id, lock: "FOR UPDATE")
        end)

      second = start(press(ctx))
      await_blocked(second.backend, first_pid)

      assert {1, _} =
               continue(first, fn ->
                 Repo.update_all(from(c in Connection, where: c.id == ^ctx.connection.id),
                   set: [
                     state: :ended,
                     ended_at: DateTime.utc_now(),
                     ended_reason: :adapter_reported
                   ]
                 )
               end)

      commit(first)

      assert {:ok, _url, {public_id, nonce}} = Task.await(second.task)
      refute public_id == ctx.connection.public_id
      ended_as(ctx, :adapter_reported)
      replaced_by(ctx, public_id, nonce)
    end

    test "the press first: the adapter's disconnect waits, then finds it ended", ctx do
      {first, first_pid} = hold(press(ctx))
      assert {:ok, _url, {public_id, nonce}} = first.result

      second =
        start(fn -> Connections.end_connection(key_scope(ctx.key), ctx.connection.public_id) end)

      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :ended}
      ended_as(ctx, :replaced)
      replaced_by(ctx, public_id, nonce)
    end

    test "the adapter's deletion first: the press waits, then finds no adapter", ctx do
      instance_admin = Apiary.OrganisationsFixtures.instance_admin_scope()
      {first, first_pid} = hold(fn -> Adapters.delete_adapter(instance_admin, ctx.adapter) end)
      assert {:ok, %Node{}} = first.result

      second = start(press(ctx))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :not_found}
      ended_as(ctx, :integration_deleted, true)
      assert live(ctx) == []
    end

    test "the press first: the adapter's deletion waits, then ends the new one", ctx do
      instance_admin = Apiary.OrganisationsFixtures.instance_admin_scope()
      {first, first_pid} = hold(press(ctx))
      assert {:ok, _url, {public_id, _nonce}} = first.result

      second = start(fn -> Adapters.delete_adapter(instance_admin, ctx.adapter) end)
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, %Node{deleted_at: %DateTime{}}} = Task.await(second.task)
      ended_as(ctx, :replaced, true)
      assert live(ctx) == []

      assert %Connection{state: :ended, ended_reason: :integration_deleted} =
               Repo.get_by!(Connection, public_id: public_id)

      assert %Entry{details: details} =
               Repo.one!(
                 from e in Entry,
                   where: e.action == "adapter.delete" and e.subject_id == ^ctx.adapter.id
               )

      assert details["ended_connection_ids"] == [public_id]
    end

    test "two presses: the second waits, then takes the first's new connection", ctx do
      {first, first_pid} = hold(press(ctx, :scope))
      assert {:ok, _url, {public_id, first_nonce}} = first.result
      refute public_id == ctx.connection.public_id

      second = start(press(ctx))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, _url, {^public_id, second_nonce}} = Task.await(second.task)
      refute first_nonce == second_nonce
      ended_as(ctx, :replaced)
      replaced_by(ctx, public_id, second_nonce)

      assert all(ctx) == 2
    end

    test "many at once make one new connection", ctx do
      n = sides(6)
      results = together(for _ <- 1..n, do: press(ctx))

      assert Enum.all?(results, &match?({:ok, _url, {_id, _nonce}}, &1))
      assert [public_id] = results |> Enum.map(fn {:ok, _, {id, _}} -> id end) |> Enum.uniq()
      refute public_id == ctx.connection.public_id
      ended_as(ctx, :replaced)
      assert live(ctx) == [public_id]

      assert all(ctx) == 2
    end
  end

  describe "an adapter's deletion and a pool naming it" do
    setup do
      %{scope: scope} = sign_up()
      %{adapter: adapter} = adapter()
      {connection, _nonce} = connection_fixture(scope, adapter, :listed)
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

  describe "an adapter's deletion between a pool's two locks" do
    # A pool's change takes the connection `FOR SHARE` first, and the adapter's row
    # `FOR KEY SHARE` last, as Postgres checks the reference `served_by_id`; a pool made
    # with one takes the same two, in the same order, in one insert. The deletion, started
    # in between, holds the adapter's row and waits on the connection. Were it to hold the
    # row `FOR UPDATE`, the check would wait on the deletion, and the two on each other
    # (`deadlock_detected`); it holds it `FOR NO KEY UPDATE`, which lets the check
    # through.
    setup do
      %{scope: scope} = sign_up()
      %{adapter: adapter} = adapter()
      {connection, _nonce} = connection_fixture(scope, adapter, :listed)
      admin = Apiary.OrganisationsFixtures.instance_admin_scope()
      %{scope: scope, adapter: adapter, connection: connection, admin: admin}
    end

    # The first lock, the connection `FOR SHARE`, held; the deletion started and waiting
    # on it long enough to be the one Postgres would refuse.
    defp first_lock_then_deletion(ctx) do
      {held, held_pid} =
        hold(fn -> Connections.lock_serving(ctx.scope, %{served_by_id: ctx.adapter.id}) end)

      deletion = start(fn -> Adapters.delete_adapter(ctx.admin, ctx.adapter) end)
      await_waited(deletion.backend, held_pid)
      {held, deletion}
    end

    defp after_deletion(ctx, pool) do
      assert Repo.get!(Node, pool.id).served_by_id == nil
      assert Repo.get!(Connection, ctx.connection.id).state == :ended

      assert %Entry{details: details} =
               Repo.one!(
                 from e in Entry,
                   where: e.action == "adapter.delete" and e.subject_id == ^ctx.adapter.id
               )

      assert details["unserved_pool_ids"] == [pool.public_id]
    end

    test "a pool's change goes through, then the deletion clears it", ctx do
      pool = pool_fixture(ctx.scope, name: "spot-runners")
      {held, deletion} = first_lock_then_deletion(ctx)

      assert {:ok, %Node{}} =
               continue(held, fn ->
                 Nodes.update_node(ctx.scope, pool, %{served_by_id: ctx.adapter.id})
               end)

      commit(held)

      assert {:ok, %Node{deleted_at: %DateTime{}}} = Task.await(deletion.task)
      after_deletion(ctx, pool)
    end

    test "a pool made with it goes through, then the deletion clears it", ctx do
      # `lock_serving/2` takes the lock the insert's trigger takes first, the connection
      # `FOR SHARE`, which the insert then takes again.
      {held, deletion} = first_lock_then_deletion(ctx)

      assert {:ok, %Node{} = pool} =
               continue(held, fn ->
                 Nodes.create_node(ctx.scope, %{
                   kind: "pool",
                   name: "spot-runners",
                   served_by_id: ctx.adapter.id
                 })
               end)

      commit(held)

      assert {:ok, %Node{deleted_at: %DateTime{}}} = Task.await(deletion.task)
      after_deletion(ctx, pool)
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
      {to_a, _} = connection_fixture(scope, a, :listed)
      {to_b, _} = connection_fixture(scope, b, :listed)

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
