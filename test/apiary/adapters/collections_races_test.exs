defmodule Apiary.Adapters.CollectionsRacesTest do
  # The collections of a connection, racing: two listings of one connection, a listing
  # against the connection's end, a disconnect against the connection's end, and two
  # organisations' listings naming one ref at once. Each side runs on a separate
  # connection, outside the SQL sandbox, so each commits and each waits on the other's
  # locks as it would in production. Not async: what these tests commit is visible to
  # every other test while they run, and they delete it again before they end.
  #
  # The rules under test (`Apiary.Adapters.Collections`): one connection's parts are taken
  # one at a time, under its row; a listing never makes a collection live under a
  # connection that ended; a collection ends once, with one `unlinked` entry; one live
  # collection per adapter and ref.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.Races

  alias Apiary.{AccessKeys, Edition, Repo}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry
  alias Apiary.Adapters.{Collection, Collections, Connection, Connections, Feed}
  alias Apiary.Nodes.Node
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag needs: :factory

  @started ~U[2026-10-15 11:00:00Z]

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

      # The entries making the adapters and their keys left in the instance's trail.
      Repo.delete_all(
        from e in Entry,
          where: e.organisation_id == ^Edition.instance_organisation_id(),
          where: e.inserted_at >= ^started
      )

      Sandbox.checkin(Repo)
    end)

    %{scope: scope} = sign_up()
    made = connectable_adapter_fixture(%{name: name("adapter")})
    Agent.update(Process.get(:race_adapters), &[made.adapter.id | &1])
    {connection, _nonce} = connection_fixture(scope, made.adapter, :connected)

    %{
      scope: scope,
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
    Repo.delete_all(from c in Connection, where: c.adapter_id in ^ids)
    Repo.delete_all(from k in AccessKey, where: k.node_id in ^ids)
    Repo.delete_all(from c in EnrolmentCode, where: c.node_id in ^ids)
    Repo.delete_all(from n in Node, where: n.id in ^ids)
  end

  defp key_scope(key) do
    {:ok, verified} = AccessKeys.fetch_for_verification(key.key_id)
    Scope.for_access_key(verified)
  end

  defp part(connection, refs, id, started_at) do
    %{
      time: DateTime.utc_now(:second),
      connection_id: connection.public_id,
      collections:
        for(
          ref <- refs,
          do: %{ref: ref, url: "https://t.example/" <> ref, title: ref, target: nil}
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

    # The older listing, last: it ends nothing a newer listing named, and makes its own.
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
    {:ok, _} = Collections.set_workspace(trk, ctx.scope.workspace)

    {ended, ended_pid} =
      hold(fn -> Connections.end_connection(ctx.key_scope, ctx.connection.public_id) end)

    disconnect = start(fn -> Collections.disconnect(ctx.key_scope, %{collection_ref: "TRK"}) end)
    await_blocked(disconnect.backend, ended_pid)
    commit(ended)

    assert Task.await(disconnect.task) == {:ok, :unchanged}
    assert Repo.get!(Collection, trk.id).ended_reason == :connection_ended
    assert unlinked_refs(ctx.adapter) == ["TRK"]
  end

  test "the connection's end waiting on a disconnect: one end, one unlinked entry", ctx do
    {:ok, :accepted} = listing(ctx, ["TRK"], "first", @started).()
    trk = Repo.one!(from c in Collection, where: c.connection_id == ^ctx.connection.id)
    {:ok, _} = Collections.set_workspace(trk, ctx.scope.workspace)

    {disconnected, disconnect_pid} =
      hold(fn -> Collections.disconnect(ctx.key_scope, %{collection_ref: "TRK"}) end)

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
end
