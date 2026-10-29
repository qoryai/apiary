defmodule Apiary.Adapters.CollectionsRacesTest do
  # The collections of a connection, racing: two listings of one connection, a
  # listing against the connection's end, a disconnect against the connection's end,
  # two organisations' listings naming one ref at once, two assigns of the same
  # collections in opposite orders, an assign against a listing's part, a Backlog
  # switch and a workspace's unlink against a listing's part over collections whose
  # refs run against their ids, a Backlog switch against a part of another connection
  # of the adapter that names the switch's refs and moves them, a collection's
  # Backlog switch against two connections' parts naming its ref, a disconnect
  # against a part that completes its listing, a move against a disconnect that names
  # the connection the ref moves away from, a listing's part against a restore and
  # a marking of the workspace of its grant's rule, a start that changes the adapter's items against a
  # listing's part, a Backlog switch and an assign, and a collection's Backlog
  # switch, by its id, against a listing's part, its target's switch, a start and an
  # assign. Each side runs on a separate connection, outside the SQL sandbox, so each
  # commits and each waits on the other's locks as it would in production. Not async:
  # what these tests commit is visible to every other test while they run, and they
  # delete it again before they end.
  #
  # The rules under test (`Apiary.Adapters.Collections`): one connection's parts are
  # taken one at a time, under its row; a listing never makes a collection live under
  # a connection that ended; a collection ends once, with one `unlinked` entry; one
  # live collection per adapter and ref; an assign, a switch and an unlink hold the
  # collections by id, after their connections, so none of them and a listing's part,
  # which holds the live collections of its connection by ref under that connection,
  # wait on each other in turn; a listing's part holds no collection of another
  # connection in its transaction, and moves a ref live under another connection
  # after it commits, one collection at a time, each ended as a disconnect ends it,
  # with its entry in the trail of the organisation it left; a listing's part writes
  # every collection it writes, its ends included, before it takes the adapter's feed
  # counter; a listing's part holds every workspace it holds in one statement, by id,
  # as a marking holds them; a start that changes the adapter's items holds the
  # adapter's row first, then its connections, then every live collection of theirs,
  # and a listing's part holds the adapter's row `FOR SHARE` before its connection,
  # so the two come one after the other; a switch reads the adapters again once it
  # holds its collections, and a collection's switch reads the collection's workspace
  # again once it holds it.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.Races
  import Apiary.DescriptionFixtures, only: [read_description: 1]

  alias Apiary.{AccessKeys, Deletion, Edition, Repo}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry
  alias Apiary.Adapters.{Collection, Collections, Connection, Connections, Feed}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Workspace
  alias Apiary.Runs.Target
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag needs: :factory

  @started ~U[2026-10-15 11:00:00Z]
  @shop %{system: "code.example.com", path: "acme/shop"}

  setup_all do
    clean_up_leftovers(%{})
    :ok = Sandbox.checkout(Repo, sandbox: false)
    delete_adapters(from(n in Node, where: n.kind == :adapter and like(n.name, "Races %")))
    Sandbox.checkin(Repo)
    :ok
  end

  setup :setup_races

  setup do
    started = database_now()
    {:ok, made} = Agent.start(fn -> [] end)
    Process.put(:race_adapters, made)

    # Registered after the setup of `Apiary.Races`, so it runs before that one: the
    # adapters and what names them first, then the organisations.
    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      ids = Agent.get(made, & &1)
      Agent.stop(made)
      delete_adapters(from(n in Node, where: n.id in ^ids))

      # The entries making the adapters and their keys left in the instance's trail.
      Repo.delete_all(
        from e in Entry,
          where: e.organisation_id == ^Edition.instance_organisation_id(),
          where: e.inserted_at >= ^started
      )

      Sandbox.checkin(Repo)
    end)

    %{scope: scope} = sign_up()
    # A second workspace, for assigns and markings. The grant has no rule, so a
    # collection is linked to none as it is made.
    other_workspace = Apiary.OrganisationsFixtures.workspace_fixture(scope.organisation)
    made = connectable_adapter_fixture(%{name: name("adapter")})
    Agent.update(Process.get(:race_adapters), &[made.adapter.id | &1])
    {connection, _nonce} = connection_fixture(scope, made.adapter, :connected)
    _ref = listing_grant(connection)

    %{
      scope: scope,
      other_workspace: other_workspace,
      adapter: made.adapter,
      key_scope: key_scope(made.access_key),
      connection: connection
    }
  end

  defp delete_adapters(query) do
    ids = Repo.all(select(query, [n], n.id))
    connections = from c in Connection, where: c.adapter_id in ^ids, select: c.id

    Repo.delete_all(
      from l in "source_collection_listings", where: l.connection_id in subquery(connections)
    )

    Repo.delete_all(from c in Collection, where: c.adapter_id in ^ids)
    Repo.delete_all(from g in Apiary.Adapters.Grant, where: g.adapter_id in ^ids)
    Repo.delete_all(from c in Connection, where: c.adapter_id in ^ids)
    Repo.delete_all(from k in AccessKey, where: k.node_id in ^ids)
    Repo.delete_all(from c in EnrolmentCode, where: c.node_id in ^ids)
    Repo.delete_all(from n in Node, where: n.id in ^ids)
  end

  defp key_scope(key) do
    {:ok, verified} = AccessKeys.fetch_for_verification(key.key_id)
    Scope.for_access_key(verified)
  end

  # Each collection's `grant_ref` is the live grant that the setup made for the
  # connection (`listing_grant/1`), written here without a query, as a part runs in a
  # racing process.
  defp part(connection, refs, id, started_at, target \\ nil) do
    %{
      time: DateTime.utc_now(:second),
      connection_id: connection.public_id,
      collections:
        for(
          ref <- refs,
          do: %{
            ref: ref,
            url: "https://t.example/" <> ref,
            title: ref,
            grant_ref: "G_" <> connection.public_id,
            target: target
          }
        ),
      listing: %{id: id, part: 1, started_at: started_at, complete: true}
    }
  end

  defp listing(ctx, refs, id, started_at),
    do: fn ->
      Collections.post_listing(ctx.key_scope, part(ctx.connection, refs, id, started_at))
    end

  defp live(connection) do
    Repo.all(
      from c in Collection,
        where: c.connection_id == ^connection.id and is_nil(c.ended_at),
        order_by: c.external_ref,
        select: c.external_ref
    )
  end

  defp unlinked_refs(adapter),
    do:
      for(%{kind: "collection", data: data} <- Feed.entries(adapter), do: data["collection_ref"])

  test "two listings of one connection: the second waits for the first, and each completes in turn",
       ctx do
    later = DateTime.add(@started, 60)

    {first, first_pid} = hold(listing(ctx, ["OLD", "BOTH"], "first", @started))
    assert first.result == {:ok, :accepted}

    second = start(listing(ctx, ["NEW", "BOTH"], "second", later))
    await_blocked(second.backend, first_pid)
    commit(first)
    assert Task.await(second.task) == {:ok, :accepted}

    assert live(ctx.connection) == ["BOTH", "NEW"]

    # The older listing, last: it ends nothing a newer listing named, and makes the one it names.
    {older, older_pid} = hold(listing(ctx, ["NEW"], "newest", DateTime.add(later, 60)))
    stale = start(listing(ctx, ["OLD"], "stale", @started))
    await_blocked(stale.backend, older_pid)
    commit(older)
    assert older.result == {:ok, :accepted}
    assert Task.await(stale.task) == {:ok, :accepted}
    assert live(ctx.connection) == ["NEW", "OLD"]
  end

  test "a listing waiting on the connection's end is refused ended, and makes nothing", ctx do
    {ended, ended_pid} =
      hold(fn -> Connections.end_connection(ctx.key_scope, ctx.connection.public_id) end)

    assert {:ok, %Connection{state: :ended}} = ended.result

    listing = start(listing(ctx, ["TRK"], "late", @started))
    await_blocked(listing.backend, ended_pid)
    commit(ended)

    assert Task.await(listing.task) == {:error, :ended}

    assert Repo.aggregate(from(c in Collection, where: c.adapter_id == ^ctx.adapter.id), :count) ==
             0
  end

  test "the connection's end waiting on a listing ends what the listing made", ctx do
    {listed, listed_pid} = hold(listing(ctx, ["TRK"], "first", @started))
    assert listed.result == {:ok, :accepted}

    ended = start(fn -> Connections.end_connection(ctx.key_scope, ctx.connection.public_id) end)
    await_blocked(ended.backend, listed_pid)
    commit(listed)

    assert {:ok, %Connection{}} = Task.await(ended.task)
    assert live(ctx.connection) == []

    assert Repo.one!(from c in Collection, where: c.connection_id == ^ctx.connection.id).ended_reason ==
             :connection_ended
  end

  test "a disconnect waiting on the connection's end: one end, one unlinked entry", ctx do
    {:ok, :accepted} = listing(ctx, ["TRK"], "first", @started).()
    trk = Repo.one!(from c in Collection, where: c.connection_id == ^ctx.connection.id)
    {:ok, _} = set_collection_workspace(trk, ctx.scope.workspace)

    {ended, ended_pid} =
      hold(fn -> Connections.end_connection(ctx.key_scope, ctx.connection.public_id) end)

    disconnect =
      start(fn ->
        Collections.disconnect(ctx.key_scope, %{
          connection_id: ctx.connection.public_id,
          collection_ref: "TRK"
        })
      end)

    await_blocked(disconnect.backend, ended_pid)
    commit(ended)

    assert Task.await(disconnect.task) == {:ok, :unchanged}
    assert Repo.get!(Collection, trk.id).ended_reason == :connection_ended
    assert unlinked_refs(ctx.adapter) == ["TRK"]
  end

  test "the connection's end waiting on a disconnect: one end, one unlinked entry", ctx do
    {:ok, :accepted} = listing(ctx, ["TRK"], "first", @started).()
    trk = Repo.one!(from c in Collection, where: c.connection_id == ^ctx.connection.id)
    {:ok, _} = set_collection_workspace(trk, ctx.scope.workspace)

    {disconnected, disconnect_pid} =
      hold(fn ->
        Collections.disconnect(ctx.key_scope, %{
          connection_id: ctx.connection.public_id,
          collection_ref: "TRK"
        })
      end)

    assert disconnected.result == {:ok, :disconnected}

    ended = start(fn -> Connections.end_connection(ctx.key_scope, ctx.connection.public_id) end)
    await_blocked(ended.backend, disconnect_pid)
    commit(disconnected)

    assert {:ok, %Connection{}} = Task.await(ended.task)
    assert Repo.get!(Collection, trk.id).ended_reason == :disconnected
    assert unlinked_refs(ctx.adapter) == ["TRK"]
  end

  test "two organisations' listings name one ref at once: one live collection, both accepted",
       ctx do
    %{scope: other} = sign_up()
    {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)
    _ref = listing_grant(theirs)

    answers =
      together([
        fn ->
          Collections.post_listing(ctx.key_scope, part(ctx.connection, ["TRK"], "a", @started))
        end,
        fn -> Collections.post_listing(ctx.key_scope, part(theirs, ["TRK"], "b", @started)) end
      ])

    assert answers == [{:ok, :accepted}, {:ok, :accepted}]

    assert [_one] =
             Repo.all(
               from c in Collection,
                 where: c.adapter_id == ^ctx.adapter.id and c.external_ref == "TRK",
                 where: is_nil(c.ended_at)
             )
  end

  defp ids(connection, refs) do
    for ref <- refs do
      Repo.one!(
        from c in Collection,
          where: c.connection_id == ^connection.id and c.external_ref == ^ref,
          where: is_nil(c.ended_at),
          select: c.id
      )
    end
  end

  defp collection_entries(adapter),
    do: for(%{kind: "collection", data: data} <- Feed.entries(adapter), do: data)

  defp assign(ctx, ids, workspace),
    do: fn -> Collections.assign_collections(ctx.scope, ctx.connection, ids, workspace) end

  test "two assigns of the same collections in opposite orders: the second waits, neither deadlocks",
       ctx do
    {:ok, :accepted} = listing(ctx, ["X", "Y"], "first", @started).()
    [x, y] = ids(ctx.connection, ["X", "Y"])

    {first, first_pid} = hold(assign(ctx, [y, x], ctx.scope.workspace))
    assert first.result == {:ok, 2}

    second = start(assign(ctx, [x, y], ctx.other_workspace))
    await_blocked(second.backend, first_pid)
    commit(first)
    assert Task.await(second.task) == {:ok, 2}

    workspaces =
      Repo.all(
        from c in Collection, where: c.id in ^[x, y], select: c.workspace_id, distinct: true
      )

    assert workspaces == [ctx.other_workspace.id]

    # Let go at once, again and again: every one answers.
    for _round <- 1..5 do
      answers =
        together([
          assign(ctx, [x, y], ctx.scope.workspace),
          assign(ctx, [y, x], nil)
        ])

      assert Enum.all?(answers, &match?({:ok, _count}, &1)), inspect(answers)
    end

    # Each link and unlink wrote its entry: they alternate, per ref.
    for ref <- ["X", "Y"] do
      statuses =
        for %{"collection_ref" => ^ref, "status" => status} <- collection_entries(ctx.adapter),
            do: status

      assert statuses |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> a != b end)
      assert hd(statuses) == "linked"
    end
  end

  test "an assign waiting on a listing's part that ends the collection is refused, and links nothing",
       ctx do
    {:ok, :accepted} = listing(ctx, ["X", "Y"], "first", @started).()
    [x] = ids(ctx.connection, ["X"])

    {listed, listed_pid} = hold(listing(ctx, ["Y"], "second", DateTime.add(@started, 60)))
    assert listed.result == {:ok, :accepted}

    assigned = start(assign(ctx, [x], ctx.scope.workspace))
    await_blocked(assigned.backend, listed_pid)
    commit(listed)

    assert Task.await(assigned.task) == {:error, :not_found}
    assert Repo.get!(Collection, x).ended_reason == :not_listed
    assert Repo.get!(Collection, x).workspace_id == nil
    assert collection_entries(ctx.adapter) == []
  end

  test "a listing's part waiting on an assign ends the collection it linked, with its unlinked entry",
       ctx do
    {:ok, :accepted} = listing(ctx, ["X", "Y"], "first", @started).()
    [x] = ids(ctx.connection, ["X"])

    {assigned, assigned_pid} = hold(assign(ctx, [x], ctx.scope.workspace))
    assert assigned.result == {:ok, 1}

    listed = start(listing(ctx, ["Y"], "second", DateTime.add(@started, 60)))
    await_blocked(listed.backend, assigned_pid)
    commit(assigned)

    assert Task.await(listed.task) == {:ok, :accepted}
    assert Repo.get!(Collection, x).ended_reason == :not_listed

    assert collection_entries(ctx.adapter) == [
             %{"collection_ref" => "X", "status" => "linked"},
             %{"collection_ref" => "X", "status" => "unlinked"}
           ]
  end

  ## A switch and an unlink against a listing's part

  # Three collections of the connection with the target `@shop`, assigned to the scope's
  # workspace, whose refs run against their ids: `A`, `B` and `C`, by ref, are the
  # largest id, the middle one and the smallest. A part holds them by ref, `A` first; a
  # change that holds them by id holds `C` first.
  defp against_ids(ctx) do
    {:ok, :accepted} = targeted(ctx, "made", @started).()

    ids =
      Repo.all(
        from c in Collection,
          where: c.connection_id == ^ctx.connection.id,
          order_by: [desc: c.id],
          select: c.id
      )

    for {id, ref} <- Enum.zip(ids, ["A", "B", "C"]) do
      Repo.update_all(from(c in Collection, where: c.id == ^id), set: [external_ref: "T" <> ref])
    end

    for {id, ref} <- Enum.zip(ids, ["A", "B", "C"]) do
      Repo.update_all(from(c in Collection, where: c.id == ^id), set: [external_ref: ref])
    end

    {:ok, 3} = assign(ctx, ids, ctx.scope.workspace).()
    :ok = Target.insert_new(ctx.scope.organisation.id, ctx.scope.workspace.id, [@shop])
    [a, b, c] = ids

    %{
      a: a,
      b: b,
      c: c,
      target:
        Repo.get_by!(Target,
          workspace_id: ctx.scope.workspace.id,
          system: @shop.system,
          path: @shop.path
        )
    }
  end

  # A part naming `A`, `B` and `C` with the target `@shop`, started `started_at`.
  defp targeted(ctx, id, started_at),
    do: fn ->
      Collections.post_listing(
        ctx.key_scope,
        part(ctx.connection, ["A", "B", "C"], id, started_at, @shop)
      )
    end

  defp switch(ctx, target, on),
    do: fn -> Collections.set_backlog(ctx.scope, target, on) end

  defp unlink(ctx),
    do: fn ->
      Collections.unlink_workspace(ctx.scope.organisation.id, ctx.scope.workspace.id)
    end

  defp lock_row(id),
    do: fn -> Repo.one!(from c in Collection, where: c.id == ^id, lock: "FOR UPDATE") end

  # What `fun` answers, or `{:raised, message}`: a deadlock fails the assertion, not the
  # process.
  defp safely(fun) do
    fn ->
      try do
        fun.()
      rescue
        error -> {:raised, Exception.message(error)}
      end
    end
  end

  # Waits, in the database, until the backend `waiter` waits on any lock; five seconds at
  # most, which fails the test.
  defp await_waiting(waiter) do
    Repo.query!("""
    DO $$
    BEGIN
      FOR i IN 1..500 LOOP
        IF cardinality(pg_blocking_pids(#{waiter})) > 0 THEN
          RETURN;
        END IF;
        PERFORM pg_sleep(0.01);
      END LOOP;
      RAISE EXCEPTION 'backend % did not wait', #{waiter};
    END
    $$
    """)
  end

  # The middle collection held, a part waits on it holding `A`; then `change`, which
  # holds the collections by id, `C` first, starts and waits. A change that took `C`
  # would wait on `B`, and once `B` is let go the two would wait on each other in turn
  # (`deadlock_detected`); it waits on the part's connection instead, and each answers.
  defp through_the_middle(ctx, rows, change) do
    {held, held_pid} = hold(lock_row(rows.b))
    listed = start(safely(targeted(ctx, "second", DateTime.add(@started, 60))))
    await_blocked(listed.backend, held_pid)

    changed = start(safely(change))
    await_waiting(changed.backend)
    commit(held)

    {Task.await(listed.task), Task.await(changed.task)}
  end

  test "a part holding collections by ref, then a switch holding them by id: the switch waits for the part",
       ctx do
    rows = against_ids(ctx)

    assert through_the_middle(ctx, rows, switch(ctx, rows.target, false)) ==
             {{:ok, :accepted}, {:ok, 3}}

    assert Repo.all(
             from c in Collection,
               where: c.id in ^[rows.a, rows.b, rows.c],
               select: c.backlog,
               distinct: true
           ) == [false]
  end

  test "a switch held, then a part: the part waits for the switch, and each answers", ctx do
    rows = against_ids(ctx)

    {switched, switch_pid} = hold(switch(ctx, rows.target, false))
    assert switched.result == {:ok, 3}

    listed = start(safely(targeted(ctx, "second", DateTime.add(@started, 60))))
    await_blocked(listed.backend, switch_pid)
    commit(switched)

    assert Task.await(listed.task) == {:ok, :accepted}
    assert {:ok, 3} = Collections.set_backlog(ctx.scope, rows.target, true)
  end

  test "a part holding collections by ref, then a workspace's unlink holding them by id: the unlink waits for the part",
       ctx do
    rows = against_ids(ctx)

    assert through_the_middle(ctx, rows, unlink(ctx)) == {{:ok, :accepted}, 3}

    assert Repo.all(
             from c in Collection,
               where: c.id in ^[rows.a, rows.b, rows.c],
               select: c.workspace_id,
               distinct: true
           ) == [nil]
  end

  test "a workspace's unlink held, then a part: the part waits for the unlink, and each answers",
       ctx do
    against_ids(ctx)

    {unlinked, unlink_pid} = hold(unlink(ctx))
    assert unlinked.result == 3

    listed = start(safely(targeted(ctx, "second", DateTime.add(@started, 60))))
    await_blocked(listed.backend, unlink_pid)
    commit(unlinked)

    assert Task.await(listed.task) == {:ok, :accepted}

    unlinked =
      for %{"collection_ref" => ref, "status" => "unlinked"} <- collection_entries(ctx.adapter),
          do: ref

    assert Enum.sort(unlinked) == ["A", "B", "C"]
  end

  test "parts, switches, unlinks and assigns at once over collections whose refs run against their ids: none deadlocks",
       ctx do
    rows = against_ids(ctx)
    ids = [rows.a, rows.b, rows.c]
    # A part of another connection of the adapter names the same refs each round, so
    # they move back and forth.
    theirs = other_side(ctx)

    answers =
      for round <- 1..20 do
        started = DateTime.add(@started, 60 * round)

        changes = [
          targeted(ctx, "round #{round}", started),
          switch(ctx, rows.target, rem(round, 2) == 0),
          targeted(theirs, "theirs #{round}", started),
          if(rem(round, 3) == 0, do: unlink(ctx), else: switch(ctx, rows.target, true)),
          assign(ctx, Enum.shuffle(ids), ctx.scope.workspace)
        ]

        together(Enum.map(Enum.take(changes, sides(5)), &safely/1))
      end
      |> List.flatten()

    assert for({:raised, message} <- answers, do: message) == []

    # Each ref moved between the two connections as their parts named it: it is live
    # under one of them, once.
    assert Enum.sort(live(ctx.connection) ++ live(theirs.connection)) == ["A", "B", "C"]

    # Each link and unlink wrote its entry: they alternate, per ref, and the last says
    # how the live collection with that ref stands.
    for ref <- ["A", "B", "C"] do
      statuses =
        for %{"collection_ref" => ^ref, "status" => status} <- collection_entries(ctx.adapter),
            do: status

      assert statuses |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> a != b end)

      linked? = ctx.adapter |> live_with(ref) |> Repo.preload(:adapter) |> Collection.linked?()
      assert List.last(statuses) == if(linked?, do: "linked", else: "unlinked")
    end
  end

  # The live collection of `adapter` with the ref `ref`.
  defp live_with(adapter, ref) do
    Repo.one!(
      from c in Collection,
        where: c.adapter_id == ^adapter.id and c.external_ref == ^ref,
        where: is_nil(c.ended_at)
    )
  end

  test "a disconnect holding a linked collection, then a part that completes the listing and links another: neither waits on the other in turn",
       ctx do
    # The grant's rule assigns what a part makes to the workspace, so the part links it.
    grant_rule_fixture(ctx.connection, ctx.scope.workspace)

    {:ok, :accepted} = listing(ctx, ["Z"], "first", @started).()
    [z] = ids(ctx.connection, ["Z"])

    # The disconnect's first step: it holds `Z`, by adapter, connection and ref, and no
    # connection's row.
    {held, held_pid} = hold(lock_row(z))

    # The part makes `N`, linked, and ends `Z`, which the first listing named: it waits
    # on `Z`. A part that took the feed counter for `N` before it ended `Z` would keep
    # the disconnect's entry waiting on it in turn.
    listed = start(safely(listing(ctx, ["N"], "second", DateTime.add(@started, 60))))
    await_blocked(listed.backend, held_pid)

    disconnect = fn ->
      Collections.disconnect(ctx.key_scope, %{
        connection_id: ctx.connection.public_id,
        collection_ref: "Z"
      })
    end

    assert continue(held, safely(disconnect)) == {:ok, :disconnected}
    commit(held)

    assert Task.await(listed.task) == {:ok, :accepted}
    assert Repo.get!(Collection, z).ended_reason == :disconnected
    assert live(ctx.connection) == ["N"]

    assert collection_entries(ctx.adapter) == [
             %{"collection_ref" => "Z", "status" => "linked"},
             %{"collection_ref" => "Z", "status" => "unlinked"},
             %{"collection_ref" => "N", "status" => "linked"}
           ]
  end

  ## A switch against a part of another connection of the adapter, which moves the refs

  # The same adapter's connection in another organisation, whose grant has no rule, so
  # nothing is linked as it is made: the context as that organisation's owner sees it.
  defp other_side(ctx) do
    %{scope: scope} = sign_up()
    other_workspace = Apiary.OrganisationsFixtures.workspace_fixture(scope.organisation)
    {connection, _nonce} = connection_fixture(scope, ctx.adapter, :connected)
    _ref = listing_grant(connection)
    %{ctx | scope: scope, other_workspace: other_workspace, connection: connection}
  end

  # How the refs `A`, `B` and `C` stand once a part of `ctx` moved them from `theirs`:
  # live under `ctx`'s connection, new, with nothing of the ended ones, which ended as a
  # disconnect ends a collection, each with its entry in `theirs`'s trail.
  defp assert_moved(ctx, theirs, rows) do
    assert live(ctx.connection) == ["A", "B", "C"]
    assert live(theirs.connection) == []

    for id <- [rows.a, rows.b, rows.c] do
      assert Repo.get!(Collection, id).ended_reason == :disconnected
    end

    for id <- ids(ctx.connection, ["A", "B", "C"]) do
      assert %Collection{workspace_id: nil, backlog: true} = Repo.get!(Collection, id)
    end

    assert Enum.sort(moves(theirs)) == Enum.sort([rows.a, rows.b, rows.c])
  end

  # The collections of the entries `collection.move` in the trail of `side`'s
  # organisation.
  defp moves(side) do
    Repo.all(
      from e in Entry,
        where: e.organisation_id == ^side.scope.organisation.id,
        where: e.action == "collection.move",
        select: e.subject_id
    )
  end

  test "a part naming refs live under another connection, beside a row of theirs held: the part's transaction holds none of them, its move waits on that row alone, and each answers",
       ctx do
    theirs = other_side(ctx)
    rows = against_ids(theirs)

    # The middle collection held. The part's transaction holds none of the three, and
    # commits; its move ends `A`, alone in a transaction, then waits on `B`. A switch
    # holding them by id, `C` first, waits on `B` too, behind the move; once `B` is let
    # go neither waits on the other in turn, since the move holds one row at a time. The
    # move takes `B` first and ends it, so the switch, which read `A` ended already,
    # holds and turns off `C` alone, then the move ends `C`.
    {held, held_pid} = hold(lock_row(rows.b))
    listed = start(safely(targeted(ctx, "mine", @started)))
    await_blocked(listed.backend, held_pid)
    assert Repo.get!(Collection, rows.a).ended_reason == :disconnected

    switched = start(safely(switch(theirs, rows.target, false)))
    await_waiting(switched.backend)
    commit(held)

    assert Task.await(listed.task) == {:ok, :accepted}
    assert Task.await(switched.task) == {:ok, 1}
    assert_moved(ctx, theirs, rows)
  end

  test "a part and its move held in one transaction, then a switch of the refs it moved: the switch waits, and each answers",
       ctx do
    theirs = other_side(ctx)
    rows = against_ids(theirs)

    {listed, listed_pid} = hold(targeted(ctx, "mine", @started))
    assert listed.result == {:ok, :accepted}

    switched = start(safely(switch(theirs, rows.target, false)))
    await_blocked(switched.backend, listed_pid)
    commit(listed)

    # Every collection of the target ended before the switch held it.
    assert Task.await(switched.task) == {:error, :not_found}
    assert_moved(ctx, theirs, rows)
  end

  test "a switch held on another connection's collections, then a part naming their refs: the part waits, then moves them, with nothing of the switch",
       ctx do
    theirs = other_side(ctx)
    rows = against_ids(theirs)

    {switched, switch_pid} = hold(switch(theirs, rows.target, false))
    assert switched.result == {:ok, 3}

    # The part's insert meets rows the switch wrote: it waits for the switch to end, and
    # holds none of them.
    listed = start(safely(targeted(ctx, "mine", @started)))
    await_blocked(listed.backend, switch_pid)
    commit(switched)

    assert Task.await(listed.task) == {:ok, :accepted}
    assert_moved(ctx, theirs, rows)
  end

  ## Two connections' parts naming one ref, against a collection's Backlog switch

  # `Z`, listed by `theirs` at `@started` and assigned to its workspace, so it is linked:
  # its id.
  defp linked_z(theirs) do
    {:ok, :accepted} = listing(theirs, ["Z"], "first", @started).()
    [z] = ids(theirs.connection, ["Z"])
    {:ok, _} = set_collection_workspace(Repo.get!(Collection, z), theirs.scope.workspace)
    z
  end

  defp switch_one(side, id, on),
    do: fn -> Collections.set_collection_backlog(side.scope, side.connection, id, on) end

  test "a switch of a collection held, then a part of another connection and a part of that collection's connection naming its ref: none deadlocks, and the ref ends live once, under the newer listing's connection",
       ctx do
    theirs = other_side(ctx)
    z = linked_z(theirs)

    # The switch holds `theirs`'s connection `FOR SHARE`, then `Z`, which it writes.
    {switched, switch_pid} = hold(switch_one(theirs, z, false))
    assert switched.result == {:ok, 1}

    # This part's insert meets `Z`, written: it waits. The part of `theirs`, an older
    # listing, waits on its connection.
    mine = start(safely(listing(ctx, ["Z"], "mine", DateTime.add(@started, 60))))
    await_blocked(mine.backend, switch_pid)
    their_part = start(safely(listing(theirs, ["Z"], "theirs", @started)))
    await_blocked(their_part.backend, switch_pid)
    commit(switched)

    assert Task.await(mine.task) == {:ok, :accepted}
    assert Task.await(their_part.task) == {:ok, :accepted}

    # Whichever went first, the newer listing's connection holds `Z`: a collection of
    # `theirs` it met was ended, each with its entry in `theirs`'s trail.
    assert live(ctx.connection) == ["Z"]
    assert live(theirs.connection) == []
    assert Repo.get!(Collection, z).ended_reason == :disconnected

    ended =
      Repo.all(
        from c in Collection,
          where: c.connection_id == ^theirs.connection.id and c.external_ref == "Z",
          select: {c.id, c.ended_reason}
      )

    assert Enum.all?(ended, &(elem(&1, 1) == :disconnected))
    assert Enum.sort(moves(theirs)) == Enum.sort(Enum.map(ended, &elem(&1, 0)))
    assert moves(ctx) == []

    # The switch turned `Z` off, with its `unlinked` entry, so its end wrote none; the
    # new one is linked to no workspace and writes none either.
    assert [%Collection{workspace_id: nil, backlog: true}] =
             Repo.all(from c in Collection, where: c.connection_id == ^ctx.connection.id)

    assert collection_entries(ctx.adapter) == [
             %{"collection_ref" => "Z", "status" => "unlinked"}
           ]
  end

  test "a part held, then a switch of the collection it moves and a part of that collection's connection: none deadlocks",
       ctx do
    theirs = other_side(ctx)
    z = linked_z(theirs)

    # This part and its move in one transaction: it holds `Z`, ended, and the new one.
    {mine, mine_pid} = hold(listing(ctx, ["Z"], "mine", DateTime.add(@started, 60)))
    assert mine.result == {:ok, :accepted}

    switched = start(safely(switch_one(theirs, z, false)))
    await_blocked(switched.backend, mine_pid)
    their_part = start(safely(listing(theirs, ["Z"], "theirs", @started)))
    await_waiting(their_part.backend)
    commit(mine)

    # `Z` ended before the switch held it: there is nothing to switch.
    assert Task.await(switched.task) == {:error, :not_found}
    assert Task.await(their_part.task) == {:ok, :accepted}
    assert live(ctx.connection) == ["Z"]
    assert live(theirs.connection) == []
    assert moves(theirs) == [z]
  end

  test "a move whose second step is refused, the part's connection ended after the first: the collection ends, none is made, and the part is accepted",
       ctx do
    theirs = other_side(ctx)
    z = linked_z(theirs)

    # The move's first step waits on `Z`, held; the part's transaction has committed.
    {held, held_pid} = hold(lock_row(z))
    listed = start(safely(listing(ctx, ["Z"], "mine", DateTime.add(@started, 60))))
    await_blocked(listed.backend, held_pid)

    # The part's connection ends meanwhile; then the first step goes on.
    {:ok, %Connection{state: :ended}} =
      Connections.end_connection(ctx.key_scope, ctx.connection.public_id)

    commit(held)

    assert Task.await(listed.task) == {:ok, :accepted}
    assert Repo.get!(Collection, z).ended_reason == :disconnected
    assert moves(theirs) == [z]

    # The second step is refused for the ended connection: the ref is live nowhere.
    assert Repo.all(
             from c in Collection,
               where: c.adapter_id == ^ctx.adapter.id and c.external_ref == "Z",
               where: is_nil(c.ended_at)
           ) == []

    assert Repo.all(from c in Collection, where: c.connection_id == ^ctx.connection.id) == []
  end

  test "a move's first step waiting on a ref, then the old connection's disconnect of it: the disconnect waits behind the move, changes nothing, and the moved ref stays live",
       ctx do
    theirs = other_side(ctx)
    z = linked_z(theirs)
    unlinked_before = unlinked_refs(ctx.adapter)

    # The move's first step waits on `Z`, held; then the disconnect that names their
    # connection waits on the same row, behind it.
    {held, held_pid} = hold(lock_row(z))
    listed = start(safely(listing(ctx, ["Z"], "mine", DateTime.add(@started, 60))))
    await_blocked(listed.backend, held_pid)

    disconnect =
      start(
        safely(fn ->
          Collections.disconnect(ctx.key_scope, %{
            connection_id: theirs.connection.public_id,
            collection_ref: "Z"
          })
        end)
      )

    await_waiting(disconnect.backend)
    commit(held)

    assert Task.await(listed.task) == {:ok, :accepted}
    assert Task.await(disconnect.task) == {:ok, :unchanged}
    assert Repo.get!(Collection, z).ended_reason == :disconnected
    assert moves(theirs) == [z]
    assert live(ctx.connection) == ["Z"]
    assert live(theirs.connection) == []

    # One end of `Z` under their connection, with its one `unlinked` entry, by the move.
    assert unlinked_refs(ctx.adapter) == unlinked_before ++ ["Z"]

    # A late disconnect that names their connection again leaves the moved one live.
    assert Collections.disconnect(ctx.key_scope, %{
             connection_id: theirs.connection.public_id,
             collection_ref: "Z"
           }) == {:ok, :unchanged}

    assert live(ctx.connection) == ["Z"]
  end

  test "two connections' parts naming one ref and a switch of the live one, let go at once, again and again: none deadlocks, and the ref is live once",
       ctx do
    theirs = other_side(ctx)
    _z = linked_z(theirs)

    answers =
      for round <- 1..10 do
        started = DateTime.add(@started, 60 * round)

        [live] =
          Repo.all(
            from c in Collection,
              where:
                c.adapter_id == ^ctx.adapter.id and c.external_ref == "Z" and is_nil(c.ended_at)
          )

        owner = if live.connection_id == theirs.connection.id, do: theirs, else: ctx
        # Assigned, so the switch holds it.
        {:ok, live} = set_collection_workspace(live, owner.scope.workspace)

        changes = [
          listing(ctx, ["Z"], "mine #{round}", started),
          listing(theirs, ["Z"], "theirs #{round}", started),
          switch_one(owner, live.id, rem(round, 2) == 0)
        ]

        together(Enum.map(Enum.take(changes, sides(3)), &safely/1))
      end
      |> List.flatten()

    assert for({:raised, message} <- answers, do: message) == []
    assert length(live(ctx.connection) ++ live(theirs.connection)) == 1

    # Every collection of `Z` but the live one ended once, as a disconnect ends one, with
    # its entry in the trail of the organisation it left.
    ended =
      Repo.all(
        from c in Collection,
          where: c.adapter_id == ^ctx.adapter.id and not is_nil(c.ended_at),
          select: c.ended_reason
      )

    assert Enum.all?(ended, &(&1 == :disconnected))
    assert length(moves(ctx)) + length(moves(theirs)) == length(ended)
  end

  ## A listing's part against a restore and a marking

  # The task's answer once it has one, or `:blocked` once its backend waits on `holder`;
  # five seconds at most, which fails the test.
  defp done_or_blocked(%{task: task, backend: backend}, holder, tries \\ 500) do
    case Task.yield(task, 0) do
      {:ok, answer} ->
        {:done, answer}

      nil ->
        %{rows: [[blocked?]]} =
          Repo.query!("SELECT $1::int = ANY (pg_blocking_pids($2::int))", [holder, backend])

        cond do
          blocked? ->
            :blocked

          tries == 0 ->
            flunk("the change neither finished nor waited")

          true ->
            Process.sleep(10)
            done_or_blocked(%{task: task, backend: backend}, holder, tries - 1)
        end
    end
  end

  test "a restore committed while a part runs, then a marking: the part holds its workspaces in one statement, and neither waits on the other in turn",
       ctx do
    [low, high] = Enum.sort_by([ctx.scope.workspace, ctx.other_workspace], & &1.id)
    {:ok, :accepted} = listing(ctx, ["OLD"], "first", @started).()
    [old] = ids(ctx.connection, ["OLD"])
    {:ok, 1} = assign(ctx, [old], low).()
    grant_rule_fixture(ctx.connection, high)
    {:ok, _marked} = Deletion.delete_workspace(ctx.scope, low.id, low.slug)

    # The collections' table held, the part stops after it read its grant's rule, whose
    # workspace is `high`, and before it holds its workspaces.
    {held, held_pid} =
      hold(fn -> Repo.query!("LOCK TABLE source_collections IN ACCESS EXCLUSIVE MODE") end)

    listed = start(safely(listing(ctx, ["OLD", "NEW"], "second", DateTime.add(@started, 60))))
    await_blocked(listed.backend, held_pid)

    # Meanwhile the lower workspace is restored, and a marking of the higher one holds
    # every workspace in use, in order of id.
    {:ok, %Workspace{}} = Deletion.restore_workspace(ctx.scope, low.id)
    marked = start(safely(fn -> Deletion.delete_workspace(ctx.scope, high.id, high.slug) end))
    marking = done_or_blocked(marked, listed.backend)
    commit(held)

    marking =
      case marking do
        {:done, answer} -> answer
        :blocked -> Task.await(marked.task)
      end

    assert {:ok, %Workspace{}} = marking
    assert Task.await(listed.task) == {:ok, :accepted}
    # Marked meanwhile, the rule's workspace is not held: `NEW` is linked to none.
    [new] = ids(ctx.connection, ["NEW"])
    assert Repo.get!(Collection, new).workspace_id == nil
  end

  test "a part held on the workspace of its grant's rule, then a marking of it: the marking waits for the part",
       ctx do
    grant_rule_fixture(ctx.connection, ctx.scope.workspace)

    {listed, listed_pid} = hold(listing(ctx, ["NEW"], "first", @started))
    assert listed.result == {:ok, :accepted}

    marked =
      start(
        safely(fn ->
          Deletion.delete_workspace(ctx.scope, ctx.scope.workspace.id, ctx.scope.workspace.slug)
        end)
      )

    await_blocked(marked.backend, listed_pid)
    commit(listed)

    assert {:ok, %Workspace{}} = Task.await(marked.task)
    [new] = ids(ctx.connection, ["NEW"])
    assert Repo.get!(Collection, new).workspace_id == ctx.scope.workspace.id
  end

  ## A start that changes the adapter's items

  # A start of the adapter with the description fixture `name`
  # (`Apiary.Adapters.declare/2`): `example-projects.json` says it has no items,
  # `example-tracker.json` that it has.
  defp start_with(ctx, name),
    do: fn ->
      Apiary.Adapters.declare(ctx.key_scope, %{
        time: DateTime.utc_now(:second),
        connect_url: "https://tracker-adapter.acme.example/connect",
        default_interval: 900,
        minimum_interval: 300,
        sends_changes: false,
        description: read_description(name)
      })
    end

  # A part naming `ref`, with `items` false or true, and `target`.
  defp items_part(ctx, ref, items, id, started_at, target),
    do: fn ->
      Collections.post_listing(ctx.key_scope, %{
        time: DateTime.utc_now(:second),
        connection_id: ctx.connection.public_id,
        collections: [
          %{
            ref: ref,
            url: "https://t.example/" <> ref,
            title: ref,
            grant_ref: "G_" <> ctx.connection.public_id,
            target: target,
            items: items
          }
        ],
        listing: %{id: id, part: 1, started_at: started_at, complete: false}
      })
    end

  # `SHOP`, with the target `@shop`, assigned to the scope's workspace, with no items as
  # its listing says: not linked, and no entry.
  defp itemless_shop(ctx) do
    {:ok, :accepted} = items_part(ctx, "SHOP", false, "first", @started, @shop).()
    [shop] = ids(ctx.connection, ["SHOP"])
    {:ok, 1} = assign(ctx, [shop], ctx.scope.workspace).()
    assert collection_entries(ctx.adapter) == []
    shop
  end

  defp statuses(ctx, ref),
    do:
      for(
        %{"collection_ref" => ^ref, "status" => status} <- collection_entries(ctx.adapter),
        do: status
      )

  test "a start that turns items off held, then a part that gives a collection items: the part waits on the adapter's row, and links nothing",
       ctx do
    shop = itemless_shop(ctx)

    {started, start_pid} = hold(start_with(ctx, "example-projects.json"))
    assert {:ok, %Node{items: false}} = started.result

    listed = start(items_part(ctx, "SHOP", true, "second", DateTime.add(@started, 60), @shop))
    await_blocked(listed.backend, start_pid)
    commit(started)

    assert Task.await(listed.task) == {:ok, :accepted}
    assert Repo.get!(Collection, shop).items
    assert statuses(ctx, "SHOP") == []
  end

  test "a part that gives a collection items held, then a start that turns items off: the start waits, and unlinks what the part linked",
       ctx do
    shop = itemless_shop(ctx)

    {listed, listed_pid} =
      hold(items_part(ctx, "SHOP", true, "second", DateTime.add(@started, 60), @shop))

    assert listed.result == {:ok, :accepted}

    started = start(start_with(ctx, "example-projects.json"))
    await_blocked(started.backend, listed_pid)
    commit(listed)

    assert {:ok, %Node{items: false}} = Task.await(started.task)
    assert statuses(ctx, "SHOP") == ["linked", "unlinked"]

    refute Collection |> Repo.get!(shop) |> Repo.preload(:adapter) |> Collection.linked?()
  end

  test "a start that turns items off held, then a switch that read the adapter before it: the switch reads it again once it holds the collection, and turns on nothing",
       ctx do
    {:ok, :accepted} = items_part(ctx, "SHOP", true, "first", @started, @shop).()
    [shop] = ids(ctx.connection, ["SHOP"])
    {:ok, 1} = assign(ctx, [shop], ctx.scope.workspace).()

    target =
      Repo.get_by!(Target,
        workspace_id: ctx.scope.workspace.id,
        system: @shop.system,
        path: @shop.path
      )

    {:ok, 1} = switch(ctx, target, false).()
    assert statuses(ctx, "SHOP") == ["linked", "unlinked"]

    {started, start_pid} = hold(start_with(ctx, "example-projects.json"))
    assert {:ok, %Node{items: false}} = started.result

    # The switch finds the collection, its adapter with items still, with no lock, then
    # waits on the collection the start holds.
    switched = start(switch(ctx, target, true))
    await_blocked(switched.backend, start_pid)
    commit(started)

    assert Task.await(switched.task) == {:error, :not_found}
    refute Repo.get!(Collection, shop).backlog
    assert statuses(ctx, "SHOP") == ["linked", "unlinked"]
  end

  test "a switch held, then a start that turns items off: the start waits for the switch, and unlinks what it linked",
       ctx do
    {:ok, :accepted} = items_part(ctx, "SHOP", true, "first", @started, @shop).()
    [shop] = ids(ctx.connection, ["SHOP"])
    {:ok, 1} = assign(ctx, [shop], ctx.scope.workspace).()

    target =
      Repo.get_by!(Target,
        workspace_id: ctx.scope.workspace.id,
        system: @shop.system,
        path: @shop.path
      )

    {:ok, 1} = switch(ctx, target, false).()

    {switched, switch_pid} = hold(switch(ctx, target, true))
    assert switched.result == {:ok, 1}

    started = start(start_with(ctx, "example-projects.json"))
    await_blocked(started.backend, switch_pid)
    commit(switched)

    assert {:ok, %Node{items: false}} = Task.await(started.task)
    assert statuses(ctx, "SHOP") == ["linked", "unlinked", "linked", "unlinked"]
  end

  test "starts that turn items off and on, parts, switches and assigns at once: none deadlocks, and the last entry says how each collection stands",
       ctx do
    rows = against_ids(ctx)
    ids = [rows.a, rows.b, rows.c]

    answers =
      for round <- 1..20 do
        started = DateTime.add(@started, 60 * round)

        changes = [
          start_with(
            ctx,
            if(rem(round, 2) == 0, do: "example-tracker.json", else: "example-projects.json")
          ),
          targeted(ctx, "round #{round}", started),
          switch(ctx, rows.target, rem(round, 3) != 0),
          assign(ctx, Enum.shuffle(ids), ctx.scope.workspace),
          start_with(
            ctx,
            if(rem(round, 2) == 0, do: "example-projects.json", else: "example-tracker.json")
          )
        ]

        together(Enum.map(Enum.take(changes, sides(5)), &safely/1))
      end
      |> List.flatten()

    assert for({:raised, message} <- answers, do: message) == []

    for {ref, id} <- Enum.zip(["A", "B", "C"], ids) do
      statuses = statuses(ctx, ref)
      assert statuses |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> a != b end)

      linked? = Collection |> Repo.get!(id) |> Repo.preload(:adapter) |> Collection.linked?()
      assert List.last(statuses) == if(linked?, do: "linked", else: "unlinked")
    end
  end

  ## A collection's switch, by its id

  defp by_id(ctx, id, on),
    do: fn -> Collections.set_collection_backlog(ctx.scope, ctx.connection, id, on) end

  defp switch_entries(ctx) do
    Repo.all(
      from e in Entry,
        where: e.organisation_id == ^ctx.scope.organisation.id,
        where: e.action == "collection.set_backlog",
        order_by: [asc: e.inserted_at, asc: e.id],
        select: {e.subject_kind, e.details["count"]}
    )
  end

  test "a part holding collections by ref, then a collection's switch: the switch waits for the part",
       ctx do
    rows = against_ids(ctx)

    assert through_the_middle(ctx, rows, by_id(ctx, rows.c, false)) ==
             {{:ok, :accepted}, {:ok, 1}}

    refute Repo.get!(Collection, rows.c).backlog
    assert statuses(ctx, "C") == ["linked", "unlinked"]
  end

  test "a collection's switch held, then a part: the part waits for the switch, and each answers",
       ctx do
    rows = against_ids(ctx)

    {switched, switch_pid} = hold(by_id(ctx, rows.b, false))
    assert switched.result == {:ok, 1}

    listed = start(safely(targeted(ctx, "second", DateTime.add(@started, 60))))
    await_blocked(listed.backend, switch_pid)
    commit(switched)

    assert Task.await(listed.task) == {:ok, :accepted}
    refute Repo.get!(Collection, rows.b).backlog
    assert statuses(ctx, "B") == ["linked", "unlinked"]
  end

  test "a collection's switch held, then its target's switch: the target's waits, turns the others, and each writes one entry",
       ctx do
    rows = against_ids(ctx)

    {by_collection, held_pid} = hold(by_id(ctx, rows.b, false))
    assert by_collection.result == {:ok, 1}

    by_target = start(safely(switch(ctx, rows.target, false)))
    await_blocked(by_target.backend, held_pid)
    commit(by_collection)

    assert Task.await(by_target.task) == {:ok, 2}
    assert switch_entries(ctx) == [{"collection", 1}, {"target", 2}]

    for ref <- ["A", "B", "C"], do: assert(statuses(ctx, ref) == ["linked", "unlinked"])
  end

  test "a target's switch held, then a collection's switch of one of its collections: it waits, finds it as asked, and writes nothing",
       ctx do
    rows = against_ids(ctx)

    {by_target, held_pid} = hold(switch(ctx, rows.target, false))
    assert by_target.result == {:ok, 3}

    by_collection = start(safely(by_id(ctx, rows.a, false)))
    await_blocked(by_collection.backend, held_pid)
    commit(by_target)

    assert Task.await(by_collection.task) == {:ok, 0}
    assert switch_entries(ctx) == [{"target", 3}]
    assert statuses(ctx, "A") == ["linked", "unlinked"]
  end

  test "a start that turns items off held, then a collection's switch: it reads the adapter once it holds the collection, and turns on nothing",
       ctx do
    {:ok, :accepted} = items_part(ctx, "SHOP", true, "first", @started, nil).()
    [shop] = ids(ctx.connection, ["SHOP"])
    {:ok, 1} = assign(ctx, [shop], ctx.scope.workspace).()
    {:ok, 1} = by_id(ctx, shop, false).()

    {started, start_pid} = hold(start_with(ctx, "example-projects.json"))
    assert {:ok, %Node{items: false}} = started.result

    switched = start(by_id(ctx, shop, true))
    await_blocked(switched.backend, start_pid)
    commit(started)

    assert Task.await(switched.task) == {:error, :not_found}
    refute Repo.get!(Collection, shop).backlog
    assert statuses(ctx, "SHOP") == ["linked", "unlinked"]
  end

  # `SHOP`, with items, assigned to the scope's workspace, its Backlog on: linked.
  defp assigned_shop(ctx) do
    {:ok, :accepted} = items_part(ctx, "SHOP", true, "first", @started, nil).()
    [shop] = ids(ctx.connection, ["SHOP"])
    {:ok, 1} = assign(ctx, [shop], ctx.scope.workspace).()
    assert statuses(ctx, "SHOP") == ["linked"]
    shop
  end

  test "an assign that moves the collection to another workspace held, then a collection's switch: it reads the workspace again once it holds the collection, and turns nothing",
       ctx do
    shop = assigned_shop(ctx)

    {assigned, assign_pid} = hold(assign(ctx, [shop], ctx.other_workspace))
    assert assigned.result == {:ok, 1}

    # The switch finds the collection in the scope's workspace with no lock, then waits
    # on the collection the assign holds.
    switched = start(by_id(ctx, shop, false))
    await_blocked(switched.backend, assign_pid)
    commit(assigned)

    assert Task.await(switched.task) == {:error, :not_found}
    assert Repo.get!(Collection, shop).backlog
    assert Repo.get!(Collection, shop).workspace_id == ctx.other_workspace.id
    assert statuses(ctx, "SHOP") == ["linked"]
    assert switch_entries(ctx) == []
  end

  test "an assign that unlinks the collection held, then a collection's switch: it reads the workspace again once it holds the collection, and turns nothing",
       ctx do
    shop = assigned_shop(ctx)

    {assigned, assign_pid} = hold(assign(ctx, [shop], nil))
    assert assigned.result == {:ok, 1}

    switched = start(by_id(ctx, shop, false))
    await_blocked(switched.backend, assign_pid)
    commit(assigned)

    assert Task.await(switched.task) == {:error, :not_found}
    assert Repo.get!(Collection, shop).backlog
    assert Repo.get!(Collection, shop).workspace_id == nil
    assert statuses(ctx, "SHOP") == ["linked", "unlinked"]
    assert switch_entries(ctx) == []
  end

  test "parts, collections' and targets' switches, assigns and starts at once: none deadlocks, and the last entry says how each collection stands",
       ctx do
    rows = against_ids(ctx)
    ids = [rows.a, rows.b, rows.c]

    answers =
      for round <- 1..20 do
        started = DateTime.add(@started, 60 * round)

        changes = [
          by_id(ctx, Enum.random(ids), rem(round, 2) == 0),
          targeted(ctx, "round #{round}", started),
          switch(ctx, rows.target, rem(round, 3) != 0),
          by_id(ctx, Enum.random(ids), rem(round, 3) == 0),
          assign(ctx, Enum.shuffle(ids), ctx.scope.workspace),
          start_with(
            ctx,
            if(rem(round, 4) == 0, do: "example-projects.json", else: "example-tracker.json")
          )
        ]

        together(Enum.map(Enum.take(changes, sides(6)), &safely/1))
      end
      |> List.flatten()

    assert for({:raised, message} <- answers, do: message) == []

    for {ref, id} <- Enum.zip(["A", "B", "C"], ids) do
      statuses = statuses(ctx, ref)
      assert statuses |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> a != b end)

      linked? = Collection |> Repo.get!(id) |> Repo.preload(:adapter) |> Collection.linked?()
      assert List.last(statuses) == if(linked?, do: "linked", else: "unlinked")
    end
  end
end
