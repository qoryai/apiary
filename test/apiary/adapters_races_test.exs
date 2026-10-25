defmodule Apiary.AdaptersRacesTest do
  # The connections of an organisation to the instance's adapters, racing: two presses of
  # Install, a return against the adapter's disconnect, a linked return against a press,
  # and a press on a connected connection no listing has named against the first listing,
  # a return, the disconnect, the deletion and another press. Each side runs on a separate
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
  # adapter's row, then its connections. And two organisations' reports of one grant at
  # once: one wins (`Apiary.Adapters.Grants.report/2`).
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.Races

  alias Apiary.{Adapters, Edition, Repo}
  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{ConnectPass, Connection, Connections, Grant, Grants}
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
    Repo.delete_all(from g in Grant, where: g.adapter_id in ^ids)
    Repo.delete_all(from c in Connection, where: c.adapter_id in ^ids)
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

  # A press of Install made at `now`, as `Apiary.Adapters.connect/2` makes it, with the
  # adapter's row held `FOR SHARE`: `{:ok, {connection, pass}}`.
  defp press_at(scope, adapter, now) do
    fn ->
      Repo.transact(fn ->
        current = Repo.one!(from n in Node, where: n.id == ^adapter.id, lock: "FOR SHARE")

        with {:ok, connection, pass, _replaced} <-
               Connections.start(scope, current, ConnectPass.new_nonce(), now: now),
             do: {:ok, {connection, pass}}
      end)
    end
  end

  # When a pass expires, as its payload says.
  defp pass_expiry(pass), do: expiry("state=" <> pass)

  # The nonce of a pass, in base64url, as the person's session keeps it.
  defp nonce_of(pass) do
    [payload, _signature] = String.split(pass, ".")
    (payload |> Base.url_decode64!(padding: false) |> Jason.decode!())["nonce"]
  end

  # Every pass in `urls` verifies at `at`, a time after each was made, and expires no
  # later than `ConnectPass.validity/0` seconds after `at`, truncated to the second.
  defp all_good_at(urls, at) do
    latest = at |> DateTime.truncate(:second) |> DateTime.add(ConnectPass.validity(), :second)

    for url <- urls do
      [_address, pass] = String.split(url, "state=")
      assert {:ok, _pass} = ConnectPass.verify(pass, Apiary.SigningKey.public_key(), now: at)
      refute DateTime.compare(expiry(url), latest) == :gt
    end
  end

  # The adapter's one live connection, pending, is one the passes in `urls` name, and every
  # other they name ended, replaced. Within each connection, each pass expires at a different time, and
  # the connection keeps the latest.
  defp one_live_and_the_rest_replaced(adapter, urls) do
    by_connection =
      Enum.group_by(
        urls,
        fn url ->
          [_address, pass] = String.split(url, "state=")
          [payload, _signature] = String.split(pass, ".")
          (payload |> Base.url_decode64!(padding: false) |> Jason.decode!())["connection_id"]
        end,
        &expiry/1
      )

    ids = Map.keys(by_connection)

    live =
      Repo.all(from c in Connection, where: c.adapter_id == ^adapter.id and is_nil(c.ended_at))

    assert [%Connection{state: :pending, public_id: live_id}] = live
    assert live_id in ids

    rows =
      Repo.all(from c in Connection, where: c.adapter_id == ^adapter.id and c.public_id in ^ids)

    assert length(rows) == length(ids)

    for %Connection{} = row <- rows do
      expiries = Map.fetch!(by_connection, row.public_id)
      assert length(Enum.uniq(expiries)) == length(expiries)
      assert row.pass_expires_at == Enum.max(expiries, DateTime)

      if row.ended_at,
        do: assert(%Connection{state: :ended, ended_reason: :replaced} = row)
    end

    rows
  end

  describe "two presses of Install" do
    @at ~U[2026-10-16 12:00:00.250000Z]

    test "in the same second: the second waits for the first's connection, then replaces it" do
      %{scope: scope} = sign_up()
      %{scope: admin, user: other} = member(scope, :admin)
      %{adapter: adapter} = adapter()

      {first, first_pid} = hold(press_at(scope, adapter, @at))
      assert {:ok, {first_connection, first_pass}} = first.result

      second = start(press_at(admin, adapter, DateTime.add(@at, 500, :millisecond)))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, {second_connection, second_pass}} = Task.await(second.task)
      refute second_connection.public_id == first_connection.public_id

      # The first is kept, ended, with its pass and its person as they were.
      assert %Connection{state: :ended, ended_reason: :replaced} =
               ended = Repo.get!(Connection, first_connection.id)

      fields = [:pass_nonce, :pass_nonce_used_at, :pass_expires_at, :created_by_id]
      assert Map.take(ended, fields) == Map.take(first_connection, fields)

      assert %Connection{state: :pending, created_by_id: by, pass_expires_at: kept_expiry} =
               Repo.get!(Connection, second_connection.id)

      assert by == other.id
      assert kept_expiry == pass_expiry(second_pass)

      # Neither pass expires more than validity/0 seconds after now.
      assert pass_expiry(first_pass) == ~U[2026-10-16 12:15:00Z]
      assert pass_expiry(second_pass) == ~U[2026-10-16 12:15:00Z]
    end

    test "a second apart: the second waits for the first's connection, and takes it with a new pass" do
      %{scope: scope} = sign_up()
      %{scope: admin, user: other} = member(scope, :admin)
      %{adapter: adapter} = adapter()

      {first, first_pid} = hold(press_at(scope, adapter, @at))
      assert {:ok, {first_connection, first_pass}} = first.result

      second = start(press_at(admin, adapter, DateTime.add(@at, 1, :second)))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, {second_connection, second_pass}} = Task.await(second.task)
      assert second_connection.id == first_connection.id
      refute second_connection.pass_nonce == first_connection.pass_nonce

      assert [%Connection{created_by_id: by, pass_expires_at: kept_expiry}] =
               Repo.all(from c in Connection, where: c.adapter_id == ^adapter.id)

      # The second read the first's expiry under the row's lock, after the first committed:
      # its pass expires strictly later, and the connection keeps it.
      assert by == other.id
      assert pass_expiry(second_pass) == ~U[2026-10-16 12:15:01Z]
      assert DateTime.compare(pass_expiry(second_pass), pass_expiry(first_pass)) == :gt
      assert kept_expiry == pass_expiry(second_pass)
    end

    test "many at once in the same second: one after another, each replaces the one before it" do
      %{scope: scope} = sign_up()
      %{adapter: adapter} = adapter()
      n = sides(6)

      results = together(for _ <- 1..n, do: press_at(scope, adapter, @at))

      assert Enum.all?(results, &match?({:ok, {%Connection{}, _pass}}, &1))
      ids = Enum.map(results, fn {:ok, {connection, _pass}} -> connection.public_id end)
      assert length(Enum.uniq(ids)) == n

      for {:ok, {_connection, pass}} <- results,
          do: assert(pass_expiry(pass) == ~U[2026-10-16 12:15:00Z])

      rows =
        one_live_and_the_rest_replaced(
          adapter,
          for({:ok, {_connection, pass}} <- results, do: "state=" <> pass)
        )

      assert length(rows) == n
    end

    test "many at once, as they come: none past validity/0, one live, and each connection's passes expire apart" do
      %{scope: scope} = sign_up()
      %{adapter: adapter} = adapter()
      n = sides(6)

      results = together(for _ <- 1..n, do: fn -> Adapters.connect(scope, adapter) end)
      finished = DateTime.utc_now()

      assert Enum.all?(results, &match?({:ok, _url, {_id, _nonce}}, &1))
      urls = for {:ok, url, _session} <- results, do: url
      all_good_at(urls, finished)
      rows = one_live_and_the_rest_replaced(adapter, urls)

      assert Repo.aggregate(from(c in Connection, where: c.adapter_id == ^adapter.id), :count) ==
               length(rows)
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

  describe "two organisations' reports of one grant" do
    test "the first holds the ref; the second waits on the live index, then is refused" do
      %{scope: mine} = sign_up()
      %{scope: theirs} = sign_up()
      %{adapter: adapter, access_key: key} = adapter()
      {first_connection, _nonce} = connection_fixture(mine, adapter, :connected)
      {second_connection, _nonce} = connection_fixture(theirs, adapter, :connected)

      report = fn connection ->
        fn ->
          Grants.report(key_scope(key), %{
            connection_id: connection.public_id,
            grant_ref: "G_raced",
            account: %{ref: "1001", title: "acme"},
            pass_nonce: connection.pass_nonce
          })
        end
      end

      {first, first_pid} = hold(report.(first_connection))
      assert {:ok, %Grant{}} = first.result

      second = start(report.(second_connection))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :grant_taken}

      assert Repo.all(
               from g in Grant,
                 where: g.adapter_id == ^adapter.id and g.state == :live,
                 select: g.connection_id
             ) == [first_connection.id]

      # The second's pass is not spent: once the first's connection ends, it reports.
      {:ok, _} = Connections.end_connection(key_scope(key), first_connection.public_id)
      assert {:ok, %Grant{}} = report.(second_connection).()
    end
  end

  describe "two reports under one pass" do
    test "the first takes the pass; the second waits on the connection, then is refused" do
      %{scope: mine} = sign_up()
      %{adapter: adapter, access_key: key} = adapter()
      {connection, _nonce} = connection_fixture(mine, adapter, :connected)

      report = fn ref ->
        fn ->
          Grants.report(key_scope(key), %{
            connection_id: connection.public_id,
            grant_ref: ref,
            account: %{ref: "1001", title: "acme"},
            pass_nonce: connection.pass_nonce
          })
        end
      end

      {first, first_pid} = hold(report.("G_first"))
      assert {:ok, %Grant{}} = first.result

      second = start(report.("G_second"))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :pass_unknown}

      assert Repo.all(
               from g in Grant,
                 where: g.connection_id == ^connection.id and g.state == :live,
                 select: g.grant_ref
             ) == ["G_first"]
    end
  end

  describe "a grant report and the end of its connection" do
    test "the end first: the report waits on the connection, then finds it ended" do
      %{scope: mine} = sign_up()
      %{adapter: adapter, access_key: key} = adapter()
      {connection, _nonce} = connection_fixture(mine, adapter, :connected)

      {ending, ending_pid} =
        hold(fn -> Connections.end_connection(key_scope(key), connection.public_id) end)

      assert {:ok, _} = ending.result

      report =
        start(fn ->
          Grants.report(key_scope(key), %{
            connection_id: connection.public_id,
            grant_ref: "G_late",
            account: %{ref: "1001", title: "acme"},
            pass_nonce: connection.pass_nonce
          })
        end)

      await_blocked(report.backend, ending_pid)
      commit(ending)

      assert Task.await(report.task) == {:error, :ended}
      assert Repo.all(from g in Grant, where: g.connection_id == ^connection.id) == []
    end
  end

  describe "a linked return and a press of Install" do
    test "the return first: the press waits, then gives the connection it connected a new pass" do
      %{scope: scope} = sign_up()
      %{scope: admin} = member(scope, :admin)
      %{adapter: adapter, pair: pair} = adapter()
      {connection, nonce} = connection_fixture(scope, adapter, :pending)
      token = return_token(pair.secret, connection.public_id, nonce)
      :ok = pass_made_earlier(connection.public_id)

      {first, first_pid} =
        hold(fn -> Connections.complete_return(scope, connection.public_id, token, nonce) end)

      assert first.result == {:ok, :linked}

      second = start(fn -> Adapters.connect(admin, adapter) end)
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, _url, {public_id, next}} = Task.await(second.task)
      assert public_id == connection.public_id

      assert %Connection{
               state: :connected,
               connected_at: %DateTime{},
               pass_nonce_used_at: nil,
               pass_nonce: kept
             } = Repo.get!(Connection, connection.id)

      assert Apiary.Contract.Ed25519.encode(kept) == next

      assert [linked] =
               Repo.all(
                 from p in Apiary.Adapters.LinkedPass,
                   where: p.connection_id == ^connection.id,
                   select: p.nonce
               )

      assert Apiary.Contract.Ed25519.encode(linked) == nonce
    end

    test "the press first: the return waits, then is not found, under the earlier pass" do
      %{scope: scope} = sign_up()
      %{scope: admin} = member(scope, :admin)
      %{adapter: adapter, pair: pair} = adapter()
      {connection, nonce} = connection_fixture(scope, adapter, :pending)
      token = return_token(pair.secret, connection.public_id, nonce)
      :ok = pass_made_earlier(connection.public_id)

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

  describe "a press of Install on a connected connection" do
    # A connection that a linked return connected: a press gives it a new pass, for an
    # external account the person adds to it, in one transaction, under the adapter's row
    # held `FOR SHARE` and the connection's `FOR UPDATE`. It stays connected, and is never
    # replaced.
    setup do
      %{scope: scope} = sign_up()
      %{scope: admin, user: other} = member(scope, :admin)
      %{adapter: adapter, pair: pair, access_key: key} = adapter()
      {connection, nonce} = connection_fixture(scope, adapter, :connected)
      :ok = pass_made_earlier(connection.public_id)

      %{
        scope: scope,
        admin: admin,
        other: other,
        adapter: adapter,
        pair: pair,
        key: key,
        connection: Repo.get!(Connection, connection.id),
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

    # The connection, still connected, took the pass `nonce`, started by the admin, with
    # the time it connected and the person whose pass connected it as they were.
    defp took_pass(ctx, nonce) do
      assert live(ctx) == [ctx.connection.public_id]

      assert %Connection{
               state: :connected,
               pass_nonce_used_at: nil,
               pass_started_by_id: by,
               pass_nonce: kept
             } = taken = Repo.get!(Connection, ctx.connection.id)

      assert by == ctx.other.id
      assert Apiary.Contract.Ed25519.encode(kept) == nonce

      fields = [:connected_at, :created_by_id]
      assert Map.take(taken, fields) == Map.take(ctx.connection, fields)
    end

    # The connection ended for `reason`, connected before; the adapter's key, unless the
    # adapter was deleted with its keys, reaches it no more.
    defp ended_as(ctx, reason, deleted? \\ false) do
      assert %Connection{state: :ended, ended_reason: ^reason, connected_at: %DateTime{}} =
               Repo.get!(Connection, ctx.connection.id)

      if not deleted? do
        assert Connections.connection_for_key(
                 key_scope(ctx.key),
                 ctx.connection.public_id,
                 :"source_item.post"
               ) == {:error, :ended}
      end
    end

    test "the first listing first: the press waits, then gives the listed connection a pass",
         ctx do
      {first, first_pid} = hold(listing(ctx))
      assert {:ok, %Connection{state: :connected, listed_at: %DateTime{}}} = first.result

      second = start(press(ctx))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, _url, {public_id, nonce}} = Task.await(second.task)
      assert public_id == ctx.connection.public_id
      took_pass(ctx, nonce)

      assert %Connection{listed_at: %DateTime{}} = Repo.get!(Connection, ctx.connection.id)
    end

    test "the press first: the listing waits, then records the first listing", ctx do
      {first, first_pid} = hold(press(ctx))
      assert {:ok, _url, {public_id, nonce}} = first.result
      assert public_id == ctx.connection.public_id

      second = start(listing(ctx))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, %Connection{state: :connected, listed_at: %DateTime{}}} =
               Task.await(second.task)

      took_pass(ctx, nonce)
    end

    test "the press first: a return under the pass that connected it waits, then is not found",
         ctx do
      {first, first_pid} = hold(press(ctx))
      assert {:ok, _url, {_public_id, nonce}} = first.result

      token = return_token(ctx.pair.secret, ctx.connection.public_id, ctx.nonce)

      second =
        start(fn ->
          Connections.complete_return(ctx.scope, ctx.connection.public_id, token, ctx.nonce)
        end)

      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :not_found}
      took_pass(ctx, nonce)
    end

    test "the adapter's disconnect first: the press waits, then starts a new one", ctx do
      {first, first_pid} =
        hold(fn -> Connections.end_connection(key_scope(ctx.key), ctx.connection.public_id) end)

      assert {:ok, %Connection{state: :ended}} = first.result

      second = start(press(ctx))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, _url, {public_id, _nonce}} = Task.await(second.task)
      refute public_id == ctx.connection.public_id
      ended_as(ctx, :adapter_reported)
      assert live(ctx) == [public_id]

      assert %Connection{state: :pending} = Repo.get_by!(Connection, public_id: public_id)
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

      assert {:ok, _url, {public_id, _nonce}} = Task.await(second.task)
      refute public_id == ctx.connection.public_id
      ended_as(ctx, :adapter_reported)
      assert live(ctx) == [public_id]
    end

    test "the press first: the adapter's disconnect waits, then ends the connection", ctx do
      {first, first_pid} = hold(press(ctx))
      assert {:ok, _url, {public_id, _nonce}} = first.result
      assert public_id == ctx.connection.public_id

      second =
        start(fn -> Connections.end_connection(key_scope(ctx.key), ctx.connection.public_id) end)

      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, %Connection{state: :ended}} = Task.await(second.task)
      ended_as(ctx, :adapter_reported)
      assert live(ctx) == []
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

    test "the press first: the adapter's deletion waits, then ends the connection", ctx do
      instance_admin = Apiary.OrganisationsFixtures.instance_admin_scope()
      {first, first_pid} = hold(press(ctx))
      assert {:ok, _url, {public_id, _nonce}} = first.result
      assert public_id == ctx.connection.public_id

      second = start(fn -> Adapters.delete_adapter(instance_admin, ctx.adapter) end)
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, %Node{deleted_at: %DateTime{}}} = Task.await(second.task)
      ended_as(ctx, :integration_deleted, true)
      assert live(ctx) == []

      assert %Entry{details: details} =
               Repo.one!(
                 from e in Entry,
                   where: e.action == "adapter.delete" and e.subject_id == ^ctx.adapter.id
               )

      assert details["ended_connection_ids"] == [public_id]
    end

    test "two presses in the same second: the second waits, then is too soon, and changes nothing",
         ctx do
      at = ~U[2026-10-16 12:00:00.250000Z]

      Repo.update_all(from(c in Connection, where: c.id == ^ctx.connection.id),
        set: [pass_expires_at: ~U[2026-10-16 12:14:00Z]]
      )

      {first, first_pid} = hold(press_at(ctx.admin, ctx.adapter, at))
      assert {:ok, {first_connection, first_pass}} = first.result
      assert first_connection.id == ctx.connection.id

      second = start(press_at(ctx.scope, ctx.adapter, at))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert Task.await(second.task) == {:error, :too_soon}

      assert %Connection{state: :connected, pass_expires_at: ~U[2026-10-16 12:15:00Z]} =
               Repo.get!(Connection, ctx.connection.id)

      took_pass(ctx, nonce_of(first_pass))
      assert all(ctx) == 1
    end

    test "two presses a second apart: the second waits, then takes the connection with a later pass",
         ctx do
      at = ~U[2026-10-16 12:00:00.250000Z]

      Repo.update_all(from(c in Connection, where: c.id == ^ctx.connection.id),
        set: [pass_expires_at: ~U[2026-10-16 12:14:00Z]]
      )

      {first, first_pid} = hold(press_at(ctx.scope, ctx.adapter, at))
      assert {:ok, {first_connection, first_pass}} = first.result
      assert first_connection.id == ctx.connection.id

      second = start(press_at(ctx.admin, ctx.adapter, DateTime.add(at, 1, :second)))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, {second_connection, second_pass}} = Task.await(second.task)
      assert second_connection.id == ctx.connection.id
      assert pass_expiry(second_pass) == DateTime.add(pass_expiry(first_pass), 1, :second)
      took_pass(ctx, nonce_of(second_pass))
      assert all(ctx) == 1
    end

    test "many at once: none past validity/0, the connection kept, each pass later than the one before",
         ctx do
      n = sides(6)
      results = together(for _ <- 1..n, do: press(ctx))
      finished = DateTime.utc_now()

      # Each press took a pass, or, in the same second as the one before it, was too soon.
      assert Enum.all?(
               results,
               &(match?({:ok, _url, {_id, _nonce}}, &1) or &1 == {:error, :too_soon})
             )

      urls = for {:ok, url, _session} <- results, do: url
      assert urls != []
      all_good_at(urls, finished)

      assert live(ctx) == [ctx.connection.public_id]
      assert all(ctx) == 1

      expiries = Enum.map(urls, &expiry/1)
      assert length(Enum.uniq(expiries)) == length(expiries)

      assert %Connection{state: :connected, pass_expires_at: latest} =
               Repo.get!(Connection, ctx.connection.id)

      assert latest == Enum.max(expiries, DateTime)
    end
  end
end
