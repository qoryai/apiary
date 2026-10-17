defmodule Apiary.Sources.IngestRacesTest do
  # The items and comments an adapter posts, racing: two writes of one ref, a listing
  # beside an event, a complete listing beside a disconnect of its collection, two
  # connections' listings naming one ref, a complete listing beside another connection's
  # write of a ref it leaves out, and comments beside a write that takes their item's ref
  # and beside the end of their collection. Each side runs on a separate connection,
  # outside the SQL sandbox, so each commits and each waits on the other's locks as it
  # would in production. Not async: what these tests commit is visible to every other test
  # while they run, and they delete it again before they end.
  #
  # The rules under test (`Apiary.Sources.Ingest`): one connection's posts are taken one
  # at a time, under its row; a post decides its answer again on its collection as it holds
  # it, so it never writes to a collection that ended meanwhile; two posts naming one ref
  # in the adapter, of any connections, are taken one at a time, and the newer item holds
  # the ref; a write of a ref reads the items it may take it from as they are held, so it
  # waits for a listing closing one; comments go to the item that holds their ref once
  # the ref and its collection are held, never to one that ended.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.Races
  import Apiary.SourcesFixtures

  alias Apiary.{Edition, Repo, Sources}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Audit.Entry
  alias Apiary.Adapters.{Collection, Collections, Connection, Connections}
  alias Apiary.Nodes.Node
  alias Apiary.Sources.{Comment, Item, Listing}
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
    adapter = connectable_adapter_fixture(%{name: name("adapter")})
    Agent.update(made, &[adapter.adapter.id | &1])
    {connection, _nonce} = connection_fixture(scope, adapter.adapter, :connected)

    %{
      scope: scope,
      adapter: adapter.adapter,
      key_scope: key_scope(adapter.access_key),
      connection: connection,
      trk: collection(scope, connection, "TRK")
    }
  end

  defp delete_adapters(query) do
    ids = Repo.all(select(query, [n], n.id))
    connections = from c in Connection, where: c.adapter_id in ^ids, select: c.id
    collections = from c in Collection, where: c.adapter_id in ^ids, select: c.id

    Repo.delete_all(from l in Listing, where: l.collection_id in subquery(collections))
    Repo.delete_all(from i in Item, where: i.adapter_id in ^ids)

    Repo.delete_all(
      from l in "source_collection_listings", where: l.connection_id in subquery(connections)
    )

    Repo.delete_all(from c in Collection, where: c.adapter_id in ^ids)
    Repo.delete_all(from c in Connection, where: c.adapter_id in ^ids)
    Repo.delete_all(from k in AccessKey, where: k.node_id in ^ids)
    Repo.delete_all(from c in EnrolmentCode, where: c.node_id in ^ids)
    Repo.delete_all(from n in Node, where: n.id in ^ids)
  end

  # A live collection of `connection`, linked to the scope's workspace.
  defp collection(scope, connection, ref) do
    Repo.insert!(%Collection{
      public_id: Apiary.PublicId.generate(Collection.prefix()),
      organisation_id: connection.organisation_id,
      adapter_id: connection.adapter_id,
      connection_id: connection.id,
      workspace_id: scope.workspace.id,
      external_ref: ref,
      url: "https://tracker.example.com/" <> ref,
      title: ref,
      last_listed_at: DateTime.utc_now(:second)
    })
  end

  defp later(seconds), do: DateTime.add(at(), seconds, :second)

  defp posting(key_scope, collection_ref, items, opts \\ []),
    do: fn -> Sources.post_items(key_scope, items_body(collection_ref, items, opts)) end

  defp commenting(key_scope, item_ref, comments),
    do: fn -> Sources.post_comments(key_scope, comments_body(item_ref, comments)) end

  # The refs of the comments on `item`.
  defp comments_on(%Item{id: item_id}),
    do: Repo.all(from c in Comment, where: c.item_id == ^item_id, select: c.external_ref)

  defp ticket(%Collection{id: collection_id}, ref),
    do: Repo.get_by!(Item, collection_id: collection_id, external_ref: ref)

  # The items of the adapter with `ref` that hold it: of a live collection, not ended.
  defp holders(adapter, ref) do
    Repo.all(
      from i in Item,
        join: c in assoc(i, :collection),
        where: i.adapter_id == ^adapter.id and i.external_ref == ^ref,
        where: is_nil(i.disconnected_at) and is_nil(c.ended_at),
        select: i.collection_id
    )
  end

  test "two writes of one ref: the second waits for the first; one ticket, the newer kept",
       ctx do
    {newer, newer_pid} =
      hold(posting(ctx.key_scope, "TRK", [item("R", title: "Newer", updated_at: later(60))]))

    assert newer.result == {:ok, :accepted}

    older = start(posting(ctx.key_scope, "TRK", [item("R", title: "Older")]))
    await_blocked(older.backend, newer_pid)
    commit(newer)

    assert Task.await(older.task) == {:ok, :accepted}
    assert ticket(ctx.trk, "R").title == "Newer"

    # Let go at once, each answers, and the newest is kept.
    answers =
      together([
        posting(ctx.key_scope, "TRK", [item("R", title: "Newest", updated_at: later(120))]),
        posting(ctx.key_scope, "TRK", [item("R", title: "Late", updated_at: later(90))])
      ])

    assert answers == [{:ok, :accepted}, {:ok, :accepted}]
    assert ticket(ctx.trk, "R").title == "Newest"
    assert Repo.aggregate(from(i in Item, where: i.adapter_id == ^ctx.adapter.id), :count) == 1
  end

  test "a complete listing beside an event: an item written after the listing began stays open",
       ctx do
    started = later(60)
    {:ok, :accepted} = posting(ctx.key_scope, "TRK", [item("EVENT"), item("LISTING")]).()
    listing = [listing: %{id: "l1", started_at: started}]

    # The event first: the listing, waiting on it, leaves out what it wrote.
    {event, event_pid} =
      hold(posting(ctx.key_scope, "TRK", [item("EVENT", updated_at: later(120))]))

    waiting = start(posting(ctx.key_scope, "TRK", [], listing))
    await_blocked(waiting.backend, event_pid)
    commit(event)

    assert event.result == {:ok, :accepted}
    assert Task.await(waiting.task) == {:ok, :accepted}
    assert ticket(ctx.trk, "EVENT").state == :open
    assert %Item{state: :closed, closed_by_listing_at: %DateTime{}} = ticket(ctx.trk, "LISTING")

    # The listing first: the event, waiting on it, writes over what it closed.
    listing = [listing: %{id: "l2", started_at: later(180)}]
    {closing, closing_pid} = hold(posting(ctx.key_scope, "TRK", [], listing))
    assert closing.result == {:ok, :accepted}

    waiting =
      start(posting(ctx.key_scope, "TRK", [item("LISTING", updated_at: later(240))]))

    await_blocked(waiting.backend, closing_pid)
    commit(closing)

    assert Task.await(waiting.task) == {:ok, :accepted}
    assert %Item{state: :open, closed_by_listing_at: nil} = ticket(ctx.trk, "LISTING")
    assert %Item{state: :closed} = ticket(ctx.trk, "EVENT")
  end

  test "a complete listing waiting on its collection's disconnect is not linked, and closes nothing",
       ctx do
    {:ok, :accepted} = posting(ctx.key_scope, "TRK", [item("A")]).()

    {disconnected, disconnect_pid} =
      hold(fn -> Collections.disconnect(ctx.key_scope, %{collection_ref: "TRK"}) end)

    assert disconnected.result == {:ok, :disconnected}

    listing = start(posting(ctx.key_scope, "TRK", [], listing: %{id: "l", started_at: later(60)}))
    await_blocked(listing.backend, disconnect_pid)
    commit(disconnected)

    assert Task.await(listing.task) == {:error, :not_linked}
    assert ticket(ctx.trk, "A").state == :open
    assert Repo.all(from l in Listing, where: l.collection_id == ^ctx.trk.id) == []
  end

  test "a disconnect waiting on a complete listing ends the collection the listing closed",
       ctx do
    {:ok, :accepted} = posting(ctx.key_scope, "TRK", [item("A")]).()

    {listed, listed_pid} =
      hold(posting(ctx.key_scope, "TRK", [], listing: %{id: "l", started_at: later(60)}))

    assert listed.result == {:ok, :accepted}

    disconnect = start(fn -> Collections.disconnect(ctx.key_scope, %{collection_ref: "TRK"}) end)
    await_blocked(disconnect.backend, listed_pid)
    commit(listed)

    assert Task.await(disconnect.task) == {:ok, :disconnected}
    assert ticket(ctx.trk, "A").state == :closed
    assert Repo.get!(Collection, ctx.trk.id).ended_reason == :disconnected
  end

  test "two connections' listings naming one ref: taken one at a time; the newer holds it",
       ctx do
    %{scope: other} = sign_up()
    {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)
    ops = collection(other, theirs, "OPS")

    # Ours first, older: theirs waits on the ref, then takes it.
    {ours, ours_pid} =
      hold(posting(ctx.key_scope, "TRK", [item("R")], listing: %{id: "a", started_at: later(30)}))

    assert ours.result == {:ok, :accepted}

    waiting =
      start(
        posting(ctx.key_scope, "OPS", [item("R", updated_at: later(60))],
          listing: %{id: "b", started_at: later(90)}
        )
      )

    await_blocked(waiting.backend, ours_pid)
    commit(ours)

    assert Task.await(waiting.task) == {:ok, :accepted}
    assert holders(ctx.adapter, "R") == [ops.id]
    assert %DateTime{} = ticket(ctx.trk, "R").disconnected_at

    # Let go at once: both answer, and one item holds each ref, the newer.
    answers =
      together([
        posting(ctx.key_scope, "TRK", [item("S", updated_at: later(300)), item("T")],
          listing: %{id: "c", started_at: later(400)}
        ),
        posting(ctx.key_scope, "OPS", [item("S"), item("T", updated_at: later(300))],
          listing: %{id: "d", started_at: later(400)}
        )
      ])

    assert answers == [{:ok, :accepted}, {:ok, :accepted}]
    assert holders(ctx.adapter, "S") == [ctx.trk.id]
    assert holders(ctx.adapter, "T") == [ops.id]
  end

  test "a complete listing beside another connection's write of a ref it leaves out: the write waits, and reads what it closed",
       ctx do
    %{scope: other} = sign_up()
    {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)
    ops = collection(other, theirs, "OPS")
    {:ok, :accepted} = posting(ctx.key_scope, "TRK", [item("R")]).()

    # The listing names nothing, so the two meet only on the row of the item it closes.
    {listed, listed_pid} =
      hold(posting(ctx.key_scope, "TRK", [], listing: %{id: "l", started_at: later(60)}))

    assert listed.result == {:ok, :accepted}

    waiting = start(posting(ctx.key_scope, "OPS", [item("R")]))
    await_blocked(waiting.backend, listed_pid)
    commit(listed)

    # At the same time, open against what the listing closed: it takes the ref.
    assert Task.await(waiting.task) == {:ok, :accepted}
    assert holders(ctx.adapter, "R") == [ops.id]
    assert %Item{state: :closed, disconnected_at: %DateTime{}} = ticket(ctx.trk, "R")
  end

  test "comments waiting on a write that takes their item's ref go to the item that holds it now",
       ctx do
    ops = collection(ctx.scope, ctx.connection, "OPS")
    {:ok, :accepted} = posting(ctx.key_scope, "TRK", [item("R")]).()
    old = ticket(ctx.trk, "R")

    {taken, taken_pid} = hold(posting(ctx.key_scope, "OPS", [item("R", updated_at: later(60))]))
    assert taken.result == {:ok, :accepted}

    waiting = start(commenting(ctx.key_scope, "R", [comment("C")]))
    await_blocked(waiting.backend, taken_pid)
    commit(taken)

    assert Task.await(waiting.task) == {:ok, :accepted}
    assert %DateTime{} = Repo.get!(Item, old.id).disconnected_at
    assert comments_on(old) == []
    assert comments_on(ticket(ops, "R")) == ["C"]
  end

  test "comments waiting on the end of their item's collection write nothing, and answer as it ended",
       ctx do
    ops = collection(ctx.scope, ctx.connection, "OPS")
    {:ok, :accepted} = posting(ctx.key_scope, "TRK", [item("R")]).()
    {:ok, :accepted} = posting(ctx.key_scope, "OPS", [item("S")]).()

    # Its collection disconnected: not linked.
    {disconnected, disconnect_pid} =
      hold(fn -> Collections.disconnect(ctx.key_scope, %{collection_ref: "TRK"}) end)

    assert disconnected.result == {:ok, :disconnected}

    waiting = start(commenting(ctx.key_scope, "R", [comment("C")]))
    await_blocked(waiting.backend, disconnect_pid)
    commit(disconnected)

    assert Task.await(waiting.task) == {:error, :not_linked}
    assert comments_on(ticket(ctx.trk, "R")) == []

    # Its connection ended: connection ended.
    {ended, end_pid} =
      hold(fn -> Connections.end_connection(ctx.key_scope, ctx.connection.public_id) end)

    assert {:ok, _connection} = ended.result

    waiting = start(commenting(ctx.key_scope, "S", [comment("C")]))
    await_blocked(waiting.backend, end_pid)
    commit(ended)

    assert Task.await(waiting.task) == {:error, :ended}
    assert comments_on(ticket(ops, "S")) == []
  end
end
