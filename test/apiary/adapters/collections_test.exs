defmodule Apiary.Adapters.CollectionsTest do
  # The collections an adapter's listing names through a connection: the listing in
  # parts, a complete listing ending the collections it left out, parts out of order or
  # sent again, a part that disagrees with the ones before it, a ref live under another
  # connection of the adapter that moves to the listing's; the disconnect of a
  # collection, by its ref and its connection, which changes nothing for a ref with no
  # live collection under that connection; the ref's
  # resolution for items and comments, in the contract's order; the end of a collection
  # with its connection, by every end, with the feed's `unlinked` entry for each linked
  # one; a workspace's and an organisation's purge; and the bookkeeping's purge.
  use Apiary.DataCase, async: true
  use Oban.Testing, repo: Apiary.Repo

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures, only: [source_item_fixture: 2]

  alias Apiary.{AccessKeys, Adapters, Deletion, Edition, EditionStubs, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Collections, Connection, Connections, Feed}
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Sources.Item

  @moduletag needs: :factory

  @started ~U[2026-10-15 11:00:00Z]

  setup do
    %{scope: scope} = sign_up_fixture()
    # A second workspace, so a collection is linked to none as it is made
    # (`Apiary.Adapters.CollectionsAssignTest` has the organisation with one).
    workspace_fixture(scope.organisation)
    connectable = connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})
    {connection, _nonce} = connection_fixture(scope, connectable.adapter, :connected)

    %{
      scope: scope,
      adapter: connectable.adapter,
      key: connectable.access_key,
      key_scope: key_scope(connectable.access_key),
      connection: connection
    }
  end

  # The verified key's scope, as a signed request carries it.
  defp key_scope(key) do
    {:ok, verified} = AccessKeys.fetch_for_verification(key.key_id)
    Scope.for_access_key(verified)
  end

  # One part of a listing, as `Apiary.Adapters.Wire.listing/1` reads it.
  defp part(connection, refs, opts \\ []) do
    %{
      time: DateTime.utc_now(:second),
      connection_id: connection.public_id,
      collections:
        for ref <- refs do
          %{
            ref: ref,
            url: "https://tracker.acme.example/" <> ref,
            title: Keyword.get(opts, :title, "Title of " <> ref),
            grant_ref: Keyword.get_lazy(opts, :grant_ref, fn -> listing_grant(connection) end),
            target: Keyword.get(opts, :target),
            environment_ref: Keyword.get(opts, :environment_ref)
          }
        end,
      listing: %{
        id: Keyword.get(opts, :id, "listing-1"),
        part: Keyword.get(opts, :part, 1),
        started_at: Keyword.get(opts, :started_at, @started),
        complete: Keyword.get(opts, :complete, true)
      }
    }
  end

  defp post(ctx, refs, opts \\ []),
    do: Collections.post_listing(ctx.key_scope, part(ctx.connection, refs, opts))

  defp live(connection) do
    Repo.all(
      from c in Collection,
        where: c.connection_id == ^connection.id and is_nil(c.ended_at),
        order_by: c.external_ref,
        select: c.external_ref
    )
  end

  defp collection(connection, ref) do
    Repo.one!(
      from c in Collection,
        where: c.connection_id == ^connection.id and c.external_ref == ^ref,
        order_by: [desc: c.inserted_at],
        limit: 1
    )
  end

  defp link(connection, ref, %Workspace{} = workspace) do
    {:ok, linked} = set_collection_workspace(collection(connection, ref), workspace)
    linked
  end

  defp unlinked_entries(adapter) do
    for %{kind: "collection", data: data} <- Feed.entries(adapter), do: data
  end

  defp unlinked(ref), do: %{"collection_ref" => ref, "status" => "unlinked"}

  # A disconnect of `ref`, naming the connection `connection_id` (this test's, by default).
  defp disconnect(ctx, ref), do: disconnect(ctx, ctx.connection.public_id, ref)

  defp disconnect(ctx, connection_id, ref),
    do:
      Collections.disconnect(ctx.key_scope, %{connection_id: connection_id, collection_ref: ref})

  # Everything a disconnect that changes nothing leaves as it was: the collections, the
  # items, the adapter's change feed and the trails.
  defp state(adapter) do
    {Repo.all(from c in Collection, order_by: c.id), Repo.all(from i in Item, order_by: i.id),
     Feed.entries(adapter), Repo.all(from e in Apiary.Audit.Entry, order_by: e.id)}
  end

  describe "the listing" do
    test "one complete part makes its collections live, under its connection, and records the listing",
         ctx do
      target = %{system: "code.example.com", path: "acme/shop"}
      assert post(ctx, ["OPS", "TRK"], target: target) == {:ok, :accepted}
      assert live(ctx.connection) == ["OPS", "TRK"]

      assert %Collection{
               organisation_id: organisation_id,
               adapter_id: adapter_id,
               url: "https://tracker.acme.example/TRK",
               title: "Title of TRK",
               target_system: "code.example.com",
               target_path: "acme/shop",
               last_listed_at: @started,
               workspace_id: nil,
               ended_reason: nil
             } = trk = collection(ctx.connection, "TRK")

      assert {organisation_id, adapter_id} == {ctx.scope.organisation.id, ctx.adapter.id}
      assert Collection.public_id?(trk.public_id)
      assert %DateTime{} = Repo.get!(Connection, ctx.connection.id).listed_at
    end

    test "an empty complete listing names none, and leaves none", ctx do
      {:ok, :accepted} = post(ctx, ["TRK"], id: "first")

      assert post(ctx, [], id: "second", started_at: DateTime.add(@started, 60)) ==
               {:ok, :accepted}

      assert live(ctx.connection) == []
      assert collection(ctx.connection, "TRK").ended_reason == :not_listed
    end

    test "a listing in parts ends what it left out only once every part has arrived", ctx do
      {:ok, :accepted} = post(ctx, ["OLD", "TRK"], id: "first")
      later = DateTime.add(@started, 600)

      {:ok, :accepted} =
        post(ctx, ["TRK"], id: "second", part: 1, complete: false, started_at: later)

      assert live(ctx.connection) == ["OLD", "TRK"]

      {:ok, :accepted} = post(ctx, ["OPS"], id: "second", part: 2, started_at: later)
      assert live(ctx.connection) == ["OPS", "TRK"]
      assert collection(ctx.connection, "OLD").ended_reason == :not_listed
    end

    test "parts out of order: the last part first waits for the others", ctx do
      {:ok, :accepted} = post(ctx, ["OLD"], id: "first")
      later = DateTime.add(@started, 600)

      {:ok, :accepted} = post(ctx, ["C"], id: "second", part: 3, started_at: later)
      assert live(ctx.connection) == ["C", "OLD"]

      {:ok, :accepted} =
        post(ctx, ["A"], id: "second", part: 1, complete: false, started_at: later)

      assert live(ctx.connection) == ["A", "C", "OLD"]

      {:ok, :accepted} =
        post(ctx, ["B"], id: "second", part: 2, complete: false, started_at: later)

      assert live(ctx.connection) == ["A", "B", "C"]
    end

    test "a part sent again is taken again, and the listing completes once", ctx do
      later = DateTime.add(@started, 600)

      for _ <- 1..2 do
        assert {:ok, :accepted} =
                 post(ctx, ["A"], id: "l", part: 1, complete: false, started_at: later)
      end

      {:ok, :accepted} = post(ctx, ["B"], id: "l", part: 2, started_at: later)
      assert live(ctx.connection) == ["A", "B"]

      # A collection a later listing makes, then the last part sent again: nothing ends.
      {:ok, :accepted} =
        post(ctx, ["C"], id: "newer", part: 1, complete: false, started_at: @started)

      {:ok, :accepted} = post(ctx, ["B"], id: "l", part: 2, started_at: later)
      assert live(ctx.connection) == ["A", "B", "C"]

      assert [%{parts: [1, 2], last_part: 2, completed: true}] =
               Repo.all(
                 from l in "source_collection_listings",
                   where: l.external_id == "l",
                   select: %{
                     parts: l.parts,
                     last_part: l.last_part,
                     completed: not is_nil(l.completed_at)
                   }
               )
    end

    test "a part that disagrees with the listing's parts before it is refused, and changes nothing",
         ctx do
      later = DateTime.add(@started, 600)

      {:ok, :accepted} =
        post(ctx, ["A"], id: "l", part: 2, complete: false, started_at: later)

      # Another started_at.
      assert post(ctx, ["X"], id: "l", part: 1, complete: false) == {:error, :invalid}
      # A last part before a part already in.
      assert post(ctx, ["X"], id: "l", part: 1, started_at: later) == {:error, :invalid}

      {:ok, :accepted} = post(ctx, ["B"], id: "l", part: 3, started_at: later)

      # A second last part, a part after the last, the last part saying it is not.
      assert post(ctx, ["X"], id: "l", part: 4, started_at: later) == {:error, :invalid}

      assert post(ctx, ["X"], id: "l", part: 4, complete: false, started_at: later) ==
               {:error, :invalid}

      assert post(ctx, ["X"], id: "l", part: 3, complete: false, started_at: later) ==
               {:error, :invalid}

      assert live(ctx.connection) == ["A", "B"]
    end

    test "a part names a collection again: the newer listing's text stands", ctx do
      {:ok, :accepted} = post(ctx, ["TRK"], id: "new", title: "New", started_at: @started)

      {:ok, :accepted} =
        post(ctx, ["TRK"],
          id: "old",
          title: "Old",
          complete: false,
          started_at: DateTime.add(@started, -60)
        )

      assert %Collection{title: "New", last_listed_at: @started} =
               collection(ctx.connection, "TRK")

      {:ok, :accepted} =
        post(ctx, ["TRK"], id: "newest", title: "Newest", started_at: DateTime.add(@started, 1))

      assert %Collection{title: "Newest"} = collection(ctx.connection, "TRK")
      assert Repo.aggregate(Collection, :count) == 1
    end

    test "a collection's environment_ref is the newest listing's, and none when it names none",
         ctx do
      {:ok, :accepted} = post(ctx, ["APP"], id: "first", environment_ref: "env-1")
      assert %Collection{environment_ref: "env-1"} = collection(ctx.connection, "APP")

      # An older listing changes nothing, its environment_ref included.
      {:ok, :accepted} =
        post(ctx, ["APP"],
          id: "older",
          complete: false,
          environment_ref: "env-old",
          started_at: DateTime.add(@started, -60)
        )

      assert %Collection{environment_ref: "env-1"} = collection(ctx.connection, "APP")

      {:ok, :accepted} =
        post(ctx, ["APP"],
          id: "second",
          environment_ref: "env-2",
          started_at: DateTime.add(@started, 1)
        )

      assert %Collection{environment_ref: "env-2"} = collection(ctx.connection, "APP")

      # Named without one: the collection has none.
      {:ok, :accepted} = post(ctx, ["APP"], id: "third", started_at: DateTime.add(@started, 2))
      assert %Collection{environment_ref: nil} = collection(ctx.connection, "APP")
      assert Repo.aggregate(Collection, :count) == 1
    end

    test "a listing that is not complete and leaves a collection out changes neither it nor its environment_ref",
         ctx do
      {:ok, :accepted} = post(ctx, ["APP", "DOCS"], id: "first", environment_ref: "env-1")
      app = collection(ctx.connection, "APP")

      # As an adapter that cannot read APP's environment definition lists: APP left out of
      # every part, the last part not complete.
      later = DateTime.add(@started, 60)

      {:ok, :accepted} =
        post(ctx, ["DOCS"], id: "second", part: 1, complete: false, started_at: later)

      assert live(ctx.connection) == ["APP", "DOCS"]
      assert collection(ctx.connection, "APP") == app
      assert %Collection{environment_ref: nil} = collection(ctx.connection, "DOCS")
    end

    test "a complete listing leaves alone what a newer listing named, and another connection's",
         ctx do
      %{scope: other} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)
      {:ok, :accepted} = Collections.post_listing(ctx.key_scope, part(theirs, ["THEIRS"]))

      {:ok, :accepted} =
        post(ctx, ["NEW"], id: "newer", complete: false, started_at: DateTime.add(@started, 60))

      {:ok, :accepted} = post(ctx, [], id: "older")

      assert live(ctx.connection) == ["NEW"]
      assert live(theirs) == ["THEIRS"]
    end

    test "a ref live under another connection of the adapter moves: that collection ends as a disconnect ends it, and a new one is made, with nothing of the old",
         ctx do
      # Another organisation whose grant's rule assigns what its listing makes to its
      # workspace, linked.
      %{scope: other} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)
      grant_rule_fixture(theirs, other.workspace)
      {:ok, :accepted} = Collections.post_listing(ctx.key_scope, part(theirs, ["DOC", "TRK"]))
      old_trk = collection(theirs, "TRK")
      old_doc = collection(theirs, "DOC")
      assert old_trk.workspace_id == other.workspace.id

      {1, _} =
        Repo.update_all(from(c in Collection, where: c.id == ^old_doc.id), set: [backlog: false])

      Phoenix.PubSub.subscribe(Apiary.PubSub, Collections.topic(other.organisation.id))
      Phoenix.PubSub.subscribe(Apiary.PubSub, Collections.topic(ctx.scope.organisation.id))

      assert post(ctx, ["DOC", "TRK", "OPS"]) == {:ok, :accepted}
      assert live(theirs) == []
      assert live(ctx.connection) == ["DOC", "OPS", "TRK"]

      for old <- [old_trk, old_doc] do
        assert %Collection{ended_reason: :disconnected, ended_at: %DateTime{}} =
                 Repo.get!(Collection, old.id)

        new = collection(ctx.connection, old.external_ref)
        refute new.id == old.id
        refute new.public_id == old.public_id
        # This organisation has two workspaces: the new one is assigned to none, with its
        # Backlog switch as any new one has it.
        assert %Collection{workspace_id: nil, backlog: true, last_listed_at: @started} = new
        refute Collection.linked?(Repo.preload(new, :adapter))
      end

      # The linked one's end wrote its `unlinked` entry, as a disconnect does; the other,
      # its Backlog turned off, was not linked.
      assert unlinked_entries(ctx.adapter) == [
               %{"collection_ref" => "DOC", "status" => "linked"},
               %{"collection_ref" => "TRK", "status" => "linked"},
               unlinked("TRK")
             ]

      # Each end is broadcast to the organisation it left, and what the part made, then
      # what the move made, to this one.
      theirs_id = theirs.id

      for old <- [old_doc, old_trk] do
        id = old.id

        assert_receive {:collections_changed, %{connection_id: ^theirs_id, collection_ids: [^id]}}
      end

      mine_id = ctx.connection.id
      ops = [collection(ctx.connection, "OPS").id]
      made = [collection(ctx.connection, "DOC").id, collection(ctx.connection, "TRK").id]
      assert_receive {:collections_changed, %{connection_id: ^mine_id, collection_ids: ^ops}}
      assert_receive {:collections_changed, %{connection_id: ^mine_id, collection_ids: got}}
      assert Enum.sort(got) == Enum.sort(made)

      # The organisation it left has one entry for each, by the instance, about the
      # collection; this one has none. Both entries have the same time, so sort by subject.
      moves =
        Repo.all(
          from e in Apiary.Audit.Entry,
            where: e.action == "collection.move",
            select: {e.organisation_id, e.actor_kind, e.subject_id, e.details}
        )

      by_subject = &elem(&1, 2)

      assert Enum.sort_by(moves, by_subject) ==
               Enum.sort_by(
                 [
                   {other.organisation.id, :instance, old_doc.id,
                    %{
                      "name" => "Title of DOC",
                      "connection_id" => theirs.public_id,
                      "integration" => ctx.adapter.name
                    }},
                   {other.organisation.id, :instance, old_trk.id,
                    %{
                      "name" => "Title of TRK",
                      "connection_id" => theirs.public_id,
                      "integration" => ctx.adapter.name
                    }}
                 ],
                 by_subject
               )
    end

    test "a moved ref's new collection is assigned by its grant's rule, as any new one",
         ctx do
      {:ok, :accepted} = post(ctx, ["TRK"])
      old = collection(ctx.connection, "TRK")

      # Another organisation, whose grant's rule assigns new collections to its workspace.
      %{scope: other} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)
      grant_rule_fixture(theirs, other.workspace)
      {:ok, :accepted} = Collections.post_listing(ctx.key_scope, part(theirs, ["TRK"]))

      assert Repo.get!(Collection, old.id).ended_reason == :disconnected
      assert %Collection{workspace_id: workspace_id} = collection(theirs, "TRK")
      assert workspace_id == other.workspace.id

      # Linked as it is made, with its `linked` entry; the old one was not linked.
      assert unlinked_entries(ctx.adapter) == [%{"collection_ref" => "TRK", "status" => "linked"}]
    end

    test "a move's entry names the adapter by its title then, else by its name", ctx do
      %{scope: other} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)
      {:ok, :accepted} = Collections.post_listing(ctx.key_scope, part(theirs, ["DOC", "TRK"]))
      doc = collection(theirs, "DOC").id
      trk = collection(theirs, "TRK").id

      # Without a title, the name; with one, the title as it was at the move.
      assert post(ctx, ["DOC"], id: "first") == {:ok, :accepted}
      Apiary.NodesFixtures.describe_title(ctx.adapter, "Acme Tracker")
      assert post(ctx, ["DOC", "TRK"], id: "second") == {:ok, :accepted}

      # By collection, not by time: the test's one transaction gives both the same time.
      moves =
        Repo.all(
          from e in Apiary.Audit.Entry,
            where: e.action == "collection.move",
            select: {e.subject_id, e.details["integration"]}
        )

      assert length(moves) == 2
      assert Map.new(moves) == %{doc => ctx.adapter.name, trk => "Acme Tracker"}
    end

    test "a ref live under another connection that a newer listing named stays with it",
         ctx do
      %{scope: other} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)

      {:ok, :accepted} =
        Collections.post_listing(
          ctx.key_scope,
          part(theirs, ["TRK"], started_at: DateTime.add(@started, 60))
        )

      assert post(ctx, ["TRK", "OPS"]) == {:ok, :accepted}
      assert live(theirs) == ["TRK"]
      assert live(ctx.connection) == ["OPS"]
      refute Repo.exists?(from e in Apiary.Audit.Entry, where: e.action == "collection.move")
    end

    test "a ref named again after its collection ended makes a new collection", ctx do
      {:ok, :accepted} = post(ctx, ["TRK"])
      first = collection(ctx.connection, "TRK")
      {:ok, :disconnected} = disconnect(ctx, "TRK")
      {:ok, :accepted} = post(ctx, ["TRK"], id: "again")

      second = collection(ctx.connection, "TRK")
      refute second.id == first.id
      refute second.public_id == first.public_id
      assert Repo.get!(Collection, first.id).ended_reason == :disconnected
    end

    test "the order of refusals: forbidden, unknown, ended, suspended; each changes nothing",
         ctx do
      # Pending: unknown.
      %{scope: second} = sign_up_fixture()
      {pending, _nonce} = connection_fixture(second, ctx.adapter, :pending)

      assert Collections.post_listing(ctx.key_scope, part(pending, ["A"])) ==
               {:error, :unknown}

      # Another adapter's key, and an id no connection has: unknown.
      other = connectable_adapter_fixture()

      assert Collections.post_listing(key_scope(other.access_key), part(ctx.connection, ["A"])) ==
               {:error, :unknown}

      assert Collections.post_listing(
               ctx.key_scope,
               part(%{ctx.connection | public_id: "ac_0000000000000000"}, ["A"])
             ) == {:error, :unknown}

      # Suspended.
      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [ctx.scope.organisation.id])
      assert post(ctx, ["A"]) == {:error, :suspended}
      assert Repo.get!(Connection, ctx.connection.id).listed_at == nil

      # Ended, before suspended.
      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)
      assert post(ctx, ["A"]) == {:error, :ended}

      # Forbidden before all: a scope of no adapter's key.
      assert Collections.post_listing(ctx.scope, part(ctx.connection, ["A"])) ==
               {:error, :forbidden}

      assert Collections.post_listing(nil, part(pending, ["A"])) == {:error, :forbidden}
      assert Repo.aggregate(Collection, :count) == 0
      assert Repo.aggregate("source_collection_listings", :count) == 0
    end
  end

  describe "the disconnect" do
    test "ends the live collection, with an unlinked entry when it is linked", ctx do
      {:ok, :accepted} = post(ctx, ["TRK", "OPS"])
      link(ctx.connection, "TRK", ctx.scope.workspace)

      assert disconnect(ctx, "TRK") == {:ok, :disconnected}
      assert disconnect(ctx, "OPS") == {:ok, :disconnected}
      assert live(ctx.connection) == []
      assert collection(ctx.connection, "TRK").ended_reason == :disconnected
      assert unlinked_entries(ctx.adapter) == [unlinked("TRK")]
    end

    test "a ref with no live collection changes nothing and writes no entry, in every case",
         ctx do
      {:ok, :accepted} = post(ctx, ["GONE", "LEFT", "KEPT"], id: "first")

      for ref <- ["GONE", "LEFT", "KEPT"],
          do: link(ctx.connection, ref, ctx.scope.workspace)

      # Disconnected already.
      {:ok, :disconnected} = disconnect(ctx, "GONE")

      # Closed by a complete listing that left it out.
      {:ok, :accepted} =
        post(ctx, ["KEPT"], id: "second", started_at: DateTime.add(@started, 60))

      before = {Repo.all(Collection), Feed.entries(ctx.adapter)}

      for ref <- ["GONE", "LEFT", "NEVER", String.duplicate("x", 200)] do
        assert disconnect(ctx, ref) == {:ok, :unchanged}, ref
      end

      assert {Repo.all(Collection), Feed.entries(ctx.adapter)} == before

      # Ended with its connection.
      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)
      before = {Repo.all(Collection), Feed.entries(ctx.adapter)}
      assert disconnect(ctx, "KEPT") == {:ok, :unchanged}
      assert {Repo.all(Collection), Feed.entries(ctx.adapter)} == before
    end

    test "another adapter's key reaches none of this adapter's collections", ctx do
      {:ok, :accepted} = post(ctx, ["TRK"])
      other = connectable_adapter_fixture()

      assert Collections.disconnect(key_scope(other.access_key), %{
               connection_id: ctx.connection.public_id,
               collection_ref: "TRK"
             }) == {:ok, :unchanged}

      assert live(ctx.connection) == ["TRK"]
    end

    test "rights first, then suspended for a live collection only", ctx do
      {:ok, :accepted} = post(ctx, ["TRK"])

      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [ctx.scope.organisation.id])
      assert disconnect(ctx, "TRK") == {:error, :suspended}
      assert disconnect(ctx, "NEVER") == {:ok, :unchanged}
      assert live(ctx.connection) == ["TRK"]

      Edition.put_test_stub(EditionStubs.NoDisconnect)

      for ref <- ["TRK", "NEVER"] do
        assert disconnect(ctx, ref) == {:error, :forbidden}
      end

      assert Collections.disconnect(ctx.scope, %{
               connection_id: ctx.connection.public_id,
               collection_ref: "TRK"
             }) == {:error, :forbidden}

      assert live(ctx.connection) == ["TRK"]
    end

    test "after a move, the old connection's disconnect of the ref changes nothing; the holding connection's ends it",
         ctx do
      {:ok, :accepted} = post(ctx, ["TRK"])
      old = collection(ctx.connection, "TRK")

      # Another organisation, whose grant's rule links what its listing makes.
      %{scope: other} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)
      grant_rule_fixture(theirs, other.workspace)
      {:ok, :accepted} = Collections.post_listing(ctx.key_scope, part(theirs, ["TRK"]))
      assert Repo.get!(Collection, old.id).ended_reason == :disconnected
      moved = collection(theirs, "TRK")
      item = source_item_fixture(other, collection: moved)
      before = state(ctx.adapter)

      # A late disconnect from the connection the ref moved away from: the signed 204's
      # answer, and the collection stays live under the connection that holds it.
      assert disconnect(ctx, "TRK") == {:ok, :unchanged}
      assert state(ctx.adapter) == before
      assert live(theirs) == ["TRK"]
      assert %Item{disconnected_at: nil} = Repo.get!(Item, item.id)
      assert unlinked_entries(ctx.adapter) == [%{"collection_ref" => "TRK", "status" => "linked"}]

      # A disconnect naming the connection that holds it ends it, as any disconnect.
      assert disconnect(ctx, theirs.public_id, "TRK") == {:ok, :disconnected}
      assert live(theirs) == []
      assert Repo.get!(Collection, moved.id).ended_reason == :disconnected

      assert unlinked_entries(ctx.adapter) == [
               %{"collection_ref" => "TRK", "status" => "linked"},
               unlinked("TRK")
             ]
    end

    test "a connection_id unknown, of another adapter, pending or ended has no live collection: unchanged",
         ctx do
      {:ok, :accepted} = post(ctx, ["TRK"])

      # Another adapter's connection, of this organisation, with the same ref live.
      another = connectable_adapter_fixture()
      {another_connection, _nonce} = connection_fixture(ctx.scope, another.adapter, :connected)

      {:ok, :accepted} =
        Collections.post_listing(key_scope(another.access_key), part(another_connection, ["TRK"]))

      # A pending connection of this adapter, and one that ended with a collection.
      %{scope: second} = sign_up_fixture()
      {pending, _nonce} = connection_fixture(second, ctx.adapter, :pending)
      %{scope: third} = sign_up_fixture()
      {ended, _nonce} = connection_fixture(third, ctx.adapter, :connected)
      {:ok, :accepted} = Collections.post_listing(ctx.key_scope, part(ended, ["GONE"]))
      {:ok, _} = Connections.end_connection(ctx.key_scope, ended.public_id)

      ids = [
        "ac_0000000000000000",
        another_connection.public_id,
        pending.public_id,
        ended.public_id
      ]

      before = state(ctx.adapter)

      for id <- ids, ref <- ["TRK", "GONE", "NEVER"] do
        assert disconnect(ctx, id, ref) == {:ok, :unchanged}, "#{id} #{ref}"
      end

      # Whatever the organisations' state.
      Edition.put_test_stub(EditionStubs.OutOfUse)

      Process.put(:out_of_use, [
        ctx.scope.organisation.id,
        second.organisation.id,
        third.organisation.id
      ])

      for id <- ids, ref <- ["TRK", "GONE", "NEVER"] do
        assert disconnect(ctx, id, ref) == {:ok, :unchanged}, "#{id} #{ref}"
      end

      assert state(ctx.adapter) == before
      assert live(ctx.connection) == ["TRK"]
      assert live(another_connection) == ["TRK"]
    end

    test "suspended only for a live collection under the connection named, never for a ref live under another",
         ctx do
      {:ok, :accepted} = post(ctx, ["OPS"])
      %{scope: other} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)
      {:ok, :accepted} = Collections.post_listing(ctx.key_scope, part(theirs, ["TRK"]))

      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [other.organisation.id])
      before = state(ctx.adapter)

      # `TRK` is live under their connection, whose organisation is out of use; named under
      # this connection it has no live collection.
      assert disconnect(ctx, "TRK") == {:ok, :unchanged}
      assert disconnect(ctx, theirs.public_id, "OPS") == {:ok, :unchanged}
      assert disconnect(ctx, theirs.public_id, "TRK") == {:error, :suspended}
      assert state(ctx.adapter) == before

      assert disconnect(ctx, "OPS") == {:ok, :disconnected}
      assert live(ctx.connection) == []
      assert live(theirs) == ["TRK"]
    end
  end

  describe "a ref's resolution" do
    test "the live collection, linked: the collection and the narrowed scope", ctx do
      {:ok, :accepted} = post(ctx, ["TRK"])
      linked = link(ctx.connection, "TRK", ctx.scope.workspace)

      assert {:ok, %Collection{id: id}, %Scope{} = narrowed} =
               Collections.resolve(ctx.key_scope, "TRK", :"source_item.post")

      assert id == linked.id
      assert narrowed.organisation.id == ctx.scope.organisation.id
    end

    test "not linked: a live collection linked to none, an unknown ref, one ended otherwise",
         ctx do
      {:ok, :accepted} = post(ctx, ["OPEN", "GONE", "LEFT"], id: "first")
      for ref <- ["GONE", "LEFT"], do: link(ctx.connection, ref, ctx.scope.workspace)
      {:ok, :disconnected} = disconnect(ctx, "GONE")

      {:ok, :accepted} =
        post(ctx, ["OPEN", "GONE"], id: "second", started_at: DateTime.add(@started, 60))

      # GONE is live again, under a new collection linked to none; LEFT was left out.
      for ref <- ["OPEN", "GONE", "LEFT", "NEVER", 12, nil] do
        assert Collections.resolve(ctx.key_scope, ref, :"source_item.post") ==
                 {:error, :not_linked},
               inspect(ref)
      end
    end

    test "connection_ended for a ref whose collection ended last with its connection", ctx do
      {:ok, :accepted} = post(ctx, ["TRK"])
      link(ctx.connection, "TRK", ctx.scope.workspace)
      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)

      assert Collections.resolve(ctx.key_scope, "TRK", :"source_item.post") ==
               {:error, :ended}

      # A newer connection of the organisation lists it again, and it is live.
      {:ok, _url, {public_id, _}} = Adapters.connect(ctx.scope, ctx.adapter)

      Repo.update_all(from(c in Connection, where: c.public_id == ^public_id),
        set: [state: :connected, connected_at: DateTime.utc_now()]
      )

      newer = Repo.get_by!(Connection, public_id: public_id)
      {:ok, :accepted} = Collections.post_listing(ctx.key_scope, part(newer, ["TRK"]))

      assert Collections.resolve(ctx.key_scope, "TRK", :"source_item.post") ==
               {:error, :not_linked}

      # Disconnected after, under the newer connection: the last to end ended otherwise.
      {:ok, :disconnected} = disconnect(ctx, newer.public_id, "TRK")

      assert Collections.resolve(ctx.key_scope, "TRK", :"source_item.post") ==
               {:error, :not_linked}
    end

    test "the order: forbidden, ended, suspended, not linked; never connection_unknown", ctx do
      {:ok, :accepted} = post(ctx, ["LINKED", "OPEN", "ENDED"])
      link(ctx.connection, "LINKED", ctx.scope.workspace)

      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [ctx.scope.organisation.id])

      # Suspended comes before not linked, for a live collection.
      for ref <- ["LINKED", "OPEN"] do
        assert Collections.resolve(ctx.key_scope, ref, :"source_item.post") ==
                 {:error, :suspended}
      end

      assert Collections.resolve(ctx.key_scope, "NEVER", :"source_item.post") ==
               {:error, :not_linked}

      # Ended comes before suspended.
      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)

      assert Collections.resolve(ctx.key_scope, "LINKED", :"source_item.post") ==
               {:error, :ended}

      # Forbidden before all: an action the key does not take, a scope of no key.
      for ref <- ["LINKED", "NEVER"] do
        assert Collections.resolve(ctx.key_scope, ref, :"adapter.read") == {:error, :forbidden}
        assert Collections.resolve(ctx.scope, ref, :"source_item.post") == {:error, :forbidden}
      end
    end

    test "verdict/3, for comments: the collection given, the same order", ctx do
      {:ok, :accepted} = post(ctx, ["LINKED", "OPEN"])
      linked = link(ctx.connection, "LINKED", ctx.scope.workspace)
      open = collection(ctx.connection, "OPEN")

      assert {:ok, %Collection{}, %Scope{}} =
               Collections.verdict(ctx.key_scope, linked, :"source_item.post")

      assert Collections.verdict(ctx.key_scope, open, :"source_item.post") ==
               {:error, :not_linked}

      assert Collections.verdict(ctx.key_scope, nil, :"source_item.post") ==
               {:error, :not_linked}

      # Another adapter's key: its collection is none of that key's.
      other = key_scope(connectable_adapter_fixture().access_key)
      assert Collections.verdict(other, linked, :"source_item.post") == {:error, :not_linked}

      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [ctx.scope.organisation.id])

      assert Collections.verdict(ctx.key_scope, linked, :"source_item.post") ==
               {:error, :suspended}

      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)
      ended = Repo.get!(Collection, linked.id)
      assert Collections.verdict(ctx.key_scope, ended, :"source_item.post") == {:error, :ended}

      assert Collections.verdict(ctx.key_scope, ended, :"adapter.read") == {:error, :forbidden}
    end
  end

  describe "a connection's end ends its collections" do
    setup ctx do
      {:ok, :accepted} = post(ctx, ["LINKED", "OPEN", "GONE"])
      link(ctx.connection, "LINKED", ctx.scope.workspace)
      link(ctx.connection, "GONE", ctx.scope.workspace)
      {:ok, :disconnected} = disconnect(ctx, "GONE")
      :ok
    end

    defp ended_with_connection?(connection) do
      live(connection) == [] and
        Repo.all(
          from c in Collection,
            where: c.connection_id == ^connection.id,
            order_by: c.external_ref,
            select: {c.external_ref, c.ended_reason}
        ) == [
          {"GONE", :disconnected},
          {"LINKED", :connection_ended},
          {"OPEN", :connection_ended}
        ]
    end

    test "the adapter's end of the connection", ctx do
      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)
      assert ended_with_connection?(ctx.connection)
      assert unlinked_entries(ctx.adapter) == [unlinked("GONE"), unlinked("LINKED")]
    end

    test "the adapter's deletion", ctx do
      {:ok, _} = Adapters.delete_adapter(instance_admin_scope(), ctx.adapter)
      assert ended_with_connection?(ctx.connection)
      assert unlinked_entries(ctx.adapter) == [unlinked("GONE"), unlinked("LINKED")]
    end

    test "the organisation's end, in its purge", ctx do
      assert Connections.end_for_organisation(ctx.scope.organisation.id) == 1
      assert ended_with_connection?(ctx.connection)
      assert unlinked_entries(ctx.adapter) == [unlinked("GONE"), unlinked("LINKED")]
    end

    test "the end of a replaced connection, and the end of another's leaves these", ctx do
      %{scope: other} = sign_up_fixture()
      workspace_fixture(other.organisation)
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)
      {:ok, :accepted} = Collections.post_listing(ctx.key_scope, part(theirs, ["THEIRS"]))
      {:ok, _} = Connections.end_connection(ctx.key_scope, theirs.public_id)

      assert live(ctx.connection) == ["LINKED", "OPEN"]
      assert unlinked_entries(ctx.adapter) == [unlinked("GONE")]
    end

    test "the entry for each is in the contract's shape", ctx do
      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)

      fixture =
        "../../fixtures/integration-contract/adapter/changes/feed.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      [%{"kind" => "collection", "status" => "unlinked"} = entry] =
        Enum.filter(fixture["changes"], &(&1["status"] == "unlinked"))

      [%{kind: kind, data: data} | _] =
        for %{kind: "collection"} = e <- Feed.entries(ctx.adapter), do: e

      assert Map.put(data, "kind", kind) |> Map.keys() |> Enum.sort() ==
               entry |> Map.keys() |> Enum.sort()

      assert data["status"] == entry["status"]
    end
  end

  describe "a press of Install on a connected connection" do
    test "gives it a new pass, and leaves it connected, with no collections", ctx do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      {1, _} =
        Repo.update_all(from(c in Connection, where: c.id == ^ctx.connection.id),
          set: [pass_expires_at: past]
        )

      {:ok, _url, {public_id, _}} = Adapters.connect(ctx.scope, ctx.adapter)
      assert public_id == ctx.connection.public_id
      assert %{state: :connected, ended_at: nil} = Repo.get!(Connection, ctx.connection.id)
      assert Repo.aggregate(Collection, :count) == 0
    end
  end

  describe "the purges" do
    test "a workspace's purge unlinks its collections, which stay with the organisation", ctx do
      workspace = workspace_fixture(ctx.scope.organisation)
      {:ok, :accepted} = post(ctx, ["LIVE", "GONE", "OTHER"])
      link(ctx.connection, "LIVE", workspace)
      link(ctx.connection, "GONE", workspace)
      link(ctx.connection, "OTHER", ctx.scope.workspace)
      {:ok, :disconnected} = disconnect(ctx, "GONE")

      {:ok, _} = Deletion.delete_workspace(ctx.scope, workspace.id, workspace.slug)

      Repo.update_all(from(w in Workspace, where: w.id == ^workspace.id),
        set: [purge_after: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      instance = Scope.for_instance(ctx.scope.organisation, Repo.get!(Workspace, workspace.id))
      assert {:ok, :purged} = Deletion.purge_workspace(instance)

      assert live(ctx.connection) == ["LIVE", "OTHER"]
      assert collection(ctx.connection, "LIVE").workspace_id == nil
      assert collection(ctx.connection, "GONE").workspace_id == nil
      assert collection(ctx.connection, "OTHER").workspace_id == ctx.scope.workspace.id
      assert unlinked_entries(ctx.adapter) == [unlinked("GONE"), unlinked("LIVE")]

      # Run again, it unlinks nothing more.
      assert Collections.unlink_workspace(ctx.scope.organisation.id, workspace.id) == 0
    end

    test "an organisation's purge ends its collections, then deletes them and the bookkeeping",
         ctx do
      {:ok, :accepted} = post(ctx, ["LINKED", "OPEN"], complete: false)
      link(ctx.connection, "LINKED", ctx.scope.workspace)

      %{scope: other} = sign_up_fixture()
      workspace_fixture(other.organisation)
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)
      {:ok, :accepted} = Collections.post_listing(ctx.key_scope, part(theirs, ["THEIRS"]))

      {:ok, _} = Deletion.delete_organisation(ctx.scope, ctx.scope.organisation.slug)

      Repo.update_all(from(o in Organisation, where: o.id == ^ctx.scope.organisation.id),
        set: [purge_after: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      assert {:ok, :purged} =
               Deletion.purge_organisation(Scope.for_instance(ctx.scope.organisation))

      assert Repo.all(from c in Collection, select: c.external_ref) == ["THEIRS"]

      assert Repo.all(from l in "source_collection_listings", select: l.connection_id) ==
               [Ecto.UUID.dump!(theirs.id)]

      assert unlinked_entries(ctx.adapter) == [unlinked("LINKED")]
    end

    test "the bookkeeping of a listing goes a day after its first part", ctx do
      {:ok, :accepted} = post(ctx, ["A"], id: "old", complete: false)
      {:ok, :accepted} = post(ctx, ["B"], id: "new", complete: false)

      Repo.update_all(
        from(l in "source_collection_listings", where: l.external_id == "old"),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -86_401, :second)]
      )

      assert Collections.purge_listings(DateTime.utc_now()) == 1
      assert Collections.purge_listings(DateTime.utc_now()) == 0

      assert Repo.all(from l in "source_collection_listings", select: l.external_id) == ["new"]
      assert live(ctx.connection) == ["A", "B"]

      # The job that purges the seen requests purges it too.
      Repo.update_all("source_collection_listings",
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -86_401, :second)]
      )

      assert :ok = perform_job(Apiary.Adapters.SeenRequestsPurge, %{})
      assert Repo.aggregate("source_collection_listings", :count) == 0
    end
  end

  describe "the table's rules" do
    test "one live collection per adapter and ref; the bounds of its text", ctx do
      {:ok, :accepted} = post(ctx, ["TRK"])
      trk = collection(ctx.connection, "TRK")

      copy =
        trk
        |> Map.take([
          :organisation_id,
          :adapter_id,
          :connection_id,
          :url,
          :title,
          :last_listed_at
        ])
        |> Map.merge(%{public_id: Apiary.PublicId.generate("sc")})

      insert = fn attrs -> Repo.insert(struct(Collection, Map.merge(copy, attrs))) end

      assert_raise Ecto.ConstraintError, ~r/source_collections_live_index/, fn ->
        insert.(%{external_ref: "TRK"})
      end

      for {attrs, constraint} <- [
            {%{external_ref: String.duplicate("x", 201)}, "external_ref"},
            {%{external_ref: "A", url: "http://x.example"}, "url"},
            {%{external_ref: "A", title: ""}, "title"},
            {%{external_ref: "A", target_system: "Bad Host", target_path: "p"}, "target"},
            {%{external_ref: "A", target_system: "x.example"}, "target"},
            {%{external_ref: "A", public_id: "ac_0000000000000000"}, "public_id"},
            {%{external_ref: "A", environment_ref: ""}, "environment_ref"},
            {%{external_ref: "A", environment_ref: String.duplicate("e", 201)},
             "environment_ref"},
            {%{external_ref: "A", ended_at: DateTime.utc_now()}, "ended"}
          ] do
        assert_raise Ecto.ConstraintError, ~r/source_collections_#{constraint}_check/, fn ->
          insert.(attrs)
        end
      end

      assert {:ok, _} = insert.(%{external_ref: String.duplicate("é", 200)})

      assert {:ok, _} =
               insert.(%{
                 external_ref: "B",
                 public_id: Apiary.PublicId.generate("sc"),
                 environment_ref: String.duplicate("é", 200)
               })
    end

    test "a collection keeps its connection's organisation and adapter", ctx do
      {:ok, :accepted} = post(ctx, ["TRK"])
      trk = collection(ctx.connection, "TRK")
      %{scope: other} = sign_up_fixture()

      assert_raise Postgrex.Error, ~r/foreign_key_violation/, fn ->
        Repo.update_all(from(c in Collection, where: c.id == ^trk.id),
          set: [organisation_id: other.organisation.id]
        )
      end

      # A workspace of another organisation is refused too.
      assert_raise Postgrex.Error, ~r/foreign_key_violation/, fn ->
        Repo.update_all(from(c in Collection, where: c.id == ^trk.id),
          set: [workspace_id: other.workspace.id]
        )
      end
    end
  end
end
