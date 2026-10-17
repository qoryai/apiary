defmodule Apiary.Adapters.CollectionsTest do
  # The collections an adapter's listing names through a connection: the listing in
  # parts, a complete listing ending the collections it left out, parts out of order or
  # sent again, a part that disagrees with the ones before it; the disconnect of a
  # collection, which changes nothing for a ref with no live collection; the ref's
  # resolution for items and comments, in the contract's order; the end of a collection
  # with its connection, by every end, with the feed's `unlinked` entry for each linked
  # one; a workspace's and an organisation's purge; and the bookkeeping's purge.
  use Apiary.DataCase, async: true
  use Oban.Testing, repo: Apiary.Repo

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Adapters, Deletion, Edition, EditionStubs, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Collections, Connection, Connections, Feed}
  alias Apiary.Organisations.{Organisation, Workspace}

  @moduletag needs: :factory

  @started ~U[2026-10-15 11:00:00Z]

  setup do
    %{scope: scope} = sign_up_fixture()
    connectable = connectable_adapter_fixture(%{name: "Acme tracker"})
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
            target: Keyword.get(opts, :target)
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
    {:ok, linked} = Collections.set_workspace(collection(connection, ref), workspace)
    linked
  end

  defp unlinked_entries(adapter) do
    for %{kind: "collection", data: data} <- Feed.entries(adapter), do: data
  end

  defp unlinked(ref), do: %{"collection_ref" => ref, "status" => "unlinked"}

  defp disconnect(ctx, ref), do: Collections.disconnect(ctx.key_scope, %{collection_ref: ref})

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

    test "a ref live under another connection of the adapter stays with it", ctx do
      %{scope: other} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)
      {:ok, :accepted} = Collections.post_listing(ctx.key_scope, part(theirs, ["TRK"]))

      assert post(ctx, ["TRK", "OPS"]) == {:ok, :accepted}
      assert live(theirs) == ["TRK"]
      assert live(ctx.connection) == ["OPS"]
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

      assert Collections.disconnect(key_scope(other.access_key), %{collection_ref: "TRK"}) ==
               {:ok, :unchanged}

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

      assert Collections.disconnect(ctx.scope, %{collection_ref: "TRK"}) == {:error, :forbidden}
      assert live(ctx.connection) == ["TRK"]
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

      # Disconnected after: the last to end ended otherwise.
      {:ok, :disconnected} = disconnect(ctx, "TRK")

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

  describe "a press of Install that replaces a connection" do
    test "ends a connected one no listing named, which has no collections", ctx do
      {:ok, _url, {public_id, _}} = Adapters.connect(ctx.scope, ctx.adapter)
      refute public_id == ctx.connection.public_id
      assert Repo.get!(Connection, ctx.connection.id).ended_reason == :replaced
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
            {%{external_ref: "A", ended_at: DateTime.utc_now()}, "ended"}
          ] do
        assert_raise Ecto.ConstraintError, ~r/source_collections_#{constraint}_check/, fn ->
          insert.(attrs)
        end
      end

      assert {:ok, _} = insert.(%{external_ref: String.duplicate("é", 200)})
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
