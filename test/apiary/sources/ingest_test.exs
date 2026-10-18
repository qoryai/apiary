defmodule Apiary.Sources.IngestTest do
  # The items and comments an adapter posts, kept as tickets (`Apiary.Sources`): the
  # refusals in the contract's order; an item written when it is newer than the one kept or
  # as new; complete and partial listings, a listing's close counting as a write at its
  # `started_at`, and the purge of their bookkeeping; comments, with `complete.since`, its
  # mark counting as a write at that time, and `deleted`; a `comment_count` at the most
  # the contract allows; a ref another live collection of the adapter holds, and the collection
  # that answers for comments; another adapter's key; and the ids the Backlog is sent.
  use Apiary.DataCase, async: true
  use Oban.Testing, repo: Apiary.Repo

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SourcesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Edition, EditionStubs, Sources}
  alias Apiary.Adapters.{Collection, Collections, Connections}
  alias Apiary.Sources.{Comment, Item, Listing, Topic}
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  # refusal.schema.json at the contract's commit, word for word: the order the control
  # plane decides refusals in.
  @rights_first "the control plane decides rights first, from the access key and the " <>
                  "action alone, before it looks up any connection: a request the key may " <>
                  "not make is answered 403 forbidden whatever its connection_id"
  @then "it then decides 403 connection_unknown, for a request naming a connection_id, " <>
          "then connection_ended, then connection_suspended, then collection_not_linked"

  # The refusal each answer is sent as.
  @codes %{
    forbidden: "forbidden",
    ended: "connection_ended",
    suspended: "connection_suspended",
    not_linked: "collection_not_linked"
  }

  # `$defs/item/comment_count`'s maximum, 2^53 - 1.
  @max_comment_count 9_007_199_254_740_991

  setup do
    %{scope: scope} = sign_up_fixture()
    other_workspace = workspace_fixture(scope.organisation)
    connectable = connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})
    {connection, _nonce} = connection_fixture(scope, connectable.adapter, :connected)

    %{
      scope: scope,
      other_workspace: other_workspace,
      adapter: connectable.adapter,
      key_scope: key_scope(connectable.access_key),
      connection: connection,
      trk: source_collection_fixture(scope, connection, %{external_ref: "TRK"})
    }
  end

  # A disconnect of `ref` under this test's connection, as the wire reads one.
  defp disconnect(ctx, ref),
    do:
      Collections.disconnect(ctx.key_scope, %{
        connection_id: ctx.connection.public_id,
        collection_ref: ref
      })

  defp post(ctx, collection_ref, items, opts \\ []),
    do: Sources.post_items(ctx.key_scope, items_body(collection_ref, items, opts))

  defp post_comments(ctx, item_ref, comments, opts \\ []),
    do: Sources.post_comments(ctx.key_scope, comments_body(item_ref, comments, opts))

  defp ticket(%Collection{id: collection_id}, ref),
    do: Repo.get_by!(Item, collection_id: collection_id, external_ref: ref)

  defp open_refs(%Collection{id: collection_id}) do
    Repo.all(
      from i in Item,
        where: i.collection_id == ^collection_id and i.state == :open,
        order_by: i.external_ref,
        select: i.external_ref
    )
  end

  # The items that hold the ref of `work_item` in its adapter: of a live collection, not
  # ended.
  defp holders(work_item) do
    Repo.all(
      from i in Item,
        join: c in assoc(i, :collection),
        where: i.organisation_id == ^work_item.organisation_id,
        where: i.adapter_id == ^work_item.adapter_id,
        where: i.external_ref == ^work_item.external_ref,
        where: is_nil(i.disconnected_at) and is_nil(c.ended_at),
        select: i.id
    )
  end

  defp comment_of(%Item{id: item_id}, ref),
    do: Repo.get_by!(Comment, item_id: item_id, external_ref: ref)

  defp later(seconds), do: DateTime.add(at(), seconds, :second)

  defp count(schema), do: Repo.aggregate(schema, :count)

  defp ids_only?(ids), do: is_list(ids) and ids != [] and Enum.all?(ids, &Item.public_id?/1)

  describe "the refusals" do
    test "are the contract's codes, in its order" do
      decided = for [_, code] <- Regex.scan(~r/, then ([a-z_]+)/, @then), do: code
      assert decided == ["connection_ended", "connection_suspended", "collection_not_linked"]
      assert @rights_first =~ "403 forbidden"

      assert Enum.map([:forbidden, :ended, :suspended, :not_linked], &@codes[&1]) ==
               ["forbidden" | decided]

      for code <- decided do
        path = "test/fixtures/integration-contract/adapter/refusal/"
        file = path <> String.replace(code, "_", "-") <> ".json"
        assert %{"error" => ^code} = file |> File.read!() |> Jason.decode!()
      end
    end

    test "items: forbidden, then ended, then suspended, then not linked; each changes nothing",
         ctx do
      open = source_collection_fixture(ctx.scope, ctx.connection, %{workspace_id: nil})
      {:ok, :accepted} = post(ctx, "TRK", [item("R")])
      before = Repo.all(Item)

      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [ctx.scope.organisation.id])

      # Suspended comes before not linked, for a live collection; a ref with none is not linked.
      assert post(ctx, "TRK", [item("A")]) == {:error, :suspended}
      assert post(ctx, open.external_ref, [item("A")]) == {:error, :suspended}
      assert post(ctx, "NEVER", [item("A")]) == {:error, :not_linked}

      # Ended comes before suspended.
      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)
      assert post(ctx, "TRK", [item("A")]) == {:error, :ended}

      # Forbidden before all: a scope of no key, and none.
      body = items_body("TRK", [item("A")])
      assert Sources.post_items(ctx.scope, body) == {:error, :forbidden}
      assert Sources.post_items(nil, body) == {:error, :forbidden}

      assert Repo.all(Item) == before
      assert count(Listing) == 0
    end

    test "not linked: a live collection linked to no workspace, one with its Backlog off, a ref with none, an ended one",
         ctx do
      open = source_collection_fixture(ctx.scope, ctx.connection, %{workspace_id: nil})
      off = source_collection_fixture(ctx.scope, ctx.connection, %{backlog: false})
      gone = source_collection_fixture(ctx.scope, ctx.connection)

      {:ok, :disconnected} =
        disconnect(ctx, gone.external_ref)

      for ref <- [open.external_ref, off.external_ref, gone.external_ref, "NEVER"] do
        assert post(ctx, ref, [item("A")]) == {:error, :not_linked}, ref
      end

      # A ref that is no text of 1 to 200 characters names nothing.
      long = String.duplicate("x", 201)
      body = %{items_body("TRK", [item("A")]) | collection_ref: long}
      assert Sources.post_items(ctx.key_scope, body) == {:error, :not_linked}
      assert count(Item) == 0
    end

    test "comments: forbidden, then ended, then suspended, then not linked; each changes nothing",
         ctx do
      open = source_collection_fixture(ctx.scope, ctx.connection, %{workspace_id: nil})
      off = source_collection_fixture(ctx.scope, ctx.connection, %{backlog: false})
      {:ok, :accepted} = post(ctx, "TRK", [item("R")])
      source_item_fixture(ctx.scope, collection: open, external_ref: "UNLINKED")
      source_item_fixture(ctx.scope, collection: off, external_ref: "OFF")

      # An item_ref the adapter has no item for, an item of a collection linked to none, and
      # one of a collection with its Backlog off.
      assert post_comments(ctx, "NEVER", [comment("C")]) == {:error, :not_linked}
      assert post_comments(ctx, "UNLINKED", [comment("C")]) == {:error, :not_linked}
      assert post_comments(ctx, "OFF", [comment("C")]) == {:error, :not_linked}

      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [ctx.scope.organisation.id])

      assert post_comments(ctx, "R", [comment("C")]) == {:error, :suspended}
      assert post_comments(ctx, "UNLINKED", [comment("C")]) == {:error, :suspended}
      assert post_comments(ctx, "NEVER", [comment("C")]) == {:error, :not_linked}

      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)
      assert post_comments(ctx, "R", [comment("C")]) == {:error, :ended}

      body = comments_body("R", [comment("C")])
      assert Sources.post_comments(ctx.scope, body) == {:error, :forbidden}
      assert Sources.post_comments(nil, body) == {:error, :forbidden}

      assert count(Comment) == 0
    end

    test "another adapter's key reaches none of this adapter's collections or items", ctx do
      {:ok, :accepted} = post(ctx, "TRK", [item("R")])
      kept = ticket(ctx.trk, "R")

      other = connectable_adapter_fixture(%{name: unique_adapter_name("Other tracker")})
      {theirs, _nonce} = connection_fixture(ctx.scope, other.adapter, :connected)
      other_key = key_scope(other.access_key)

      assert Sources.post_items(other_key, items_body("TRK", [item("R", updated_at: later(60))])) ==
               {:error, :not_linked}

      assert Sources.post_comments(other_key, comments_body("R", [comment("C")])) ==
               {:error, :not_linked}

      # A collection of that adapter holds the same ref apart: this adapter's ticket keeps it.
      their_collection = source_collection_fixture(ctx.scope, theirs, %{external_ref: "THEIRS"})

      assert Sources.post_items(
               other_key,
               items_body("THEIRS", [item("R", updated_at: later(60))])
             ) ==
               {:ok, :accepted}

      assert ticket(their_collection, "R").disconnected_at == nil
      assert Repo.get!(Item, kept.id) == kept
      assert count(Comment) == 0
    end
  end

  describe "items" do
    test "are made with the contract's fields, a tk_ id, and the collection's ids", ctx do
      target = %{"system" => "code.example.com", "path" => "acme/shop"}
      raw = item("R") |> Map.put("key", "#12") |> Map.put("target", target)
      assert post(ctx, "TRK", [raw]) == {:ok, :accepted}

      assert %Item{
               key: "#12",
               url: "https://tracker.example.com/items/R",
               title: "Title of R",
               body: "The text of R",
               body_format: "markdown",
               filed_by_name: "Avery Example",
               filed_by_kind: :person,
               labels: ["bug"],
               state: :open,
               target_system: "code.example.com",
               target_path: "acme/shop",
               comment_count: 0,
               closed_by_listing_at: nil,
               disconnected_at: nil,
               last_listed_at: nil
             } = written = ticket(ctx.trk, "R")

      assert Item.public_id?(written.public_id)
      assert written.source_updated_at == at()

      assert {written.organisation_id, written.adapter_id} ==
               {ctx.scope.organisation.id, ctx.adapter.id}
    end

    test "the newer updated_at wins, and the same one applies", ctx do
      {:ok, :accepted} = post(ctx, "TRK", [item("R", title: "First", updated_at: later(60))])
      first = ticket(ctx.trk, "R")

      # Older: nothing changes.
      {:ok, :accepted} = post(ctx, "TRK", [item("R", title: "Older", updated_at: later(0))])
      assert ticket(ctx.trk, "R") == first

      # The same time: the later post wins, as the decoder keeps the last named of two.
      {:ok, :accepted} = post(ctx, "TRK", [item("R", title: "Same", updated_at: later(60))])
      assert %Item{title: "Same", id: id, public_id: public_id} = ticket(ctx.trk, "R")
      assert {id, public_id} == {first.id, first.public_id}

      {:ok, :accepted} =
        post(ctx, "TRK", [item("R", title: "Newer", state: "closed", updated_at: later(120))])

      assert %Item{title: "Newer", state: :closed} = ticket(ctx.trk, "R")
      assert count(Item) == 1
    end

    test "a comment_count at the most the contract allows, 2^53 - 1, is kept as sent", ctx do
      assert post(ctx, "TRK", [item("MOST", comment_count: @max_comment_count)]) ==
               {:ok, :accepted}

      assert ticket(ctx.trk, "MOST").comment_count == @max_comment_count
    end
  end

  describe "listings" do
    test "a complete listing closes the open items it left out that are older than it", ctx do
      started = later(3600)

      {:ok, :accepted} =
        post(ctx, "TRK", [item("KEPT"), item("LEFT"), item("LATE"), item("SHUT", state: "closed")])

      # Changed after the listing began, and not named by it.
      {:ok, :accepted} = post(ctx, "TRK", [item("NEWER", updated_at: DateTime.add(started, 60))])

      listing = %{id: "first", part: 1, started_at: started, complete: false}
      assert post(ctx, "TRK", [item("KEPT")], listing: listing) == {:ok, :accepted}

      # A part is missing: nothing is closed.
      assert open_refs(ctx.trk) == ["KEPT", "LATE", "LEFT", "NEWER"]
      assert ticket(ctx.trk, "KEPT").last_listed_at == started

      listing = %{listing | part: 2, complete: true}
      assert post(ctx, "TRK", [item("LATE")], listing: listing) == {:ok, :accepted}

      assert open_refs(ctx.trk) == ["KEPT", "LATE", "NEWER"]
      assert %Item{state: :closed, closed_by_listing_at: %DateTime{}} = ticket(ctx.trk, "LEFT")
      assert ticket(ctx.trk, "SHUT").closed_by_listing_at == nil

      assert %Listing{parts: [1, 2], last_part: 2, completed_at: %DateTime{}} =
               Repo.get_by!(Listing, collection_id: ctx.trk.id, external_id: "first")

      # A part sent again after completion closes nothing more.
      {:ok, :accepted} = post(ctx, "TRK", [item("LEFT2")])
      assert post(ctx, "TRK", [item("LATE")], listing: listing) == {:ok, :accepted}
      assert "LEFT2" in open_refs(ctx.trk)

      # Written again, an item is no longer one a listing closed.
      {:ok, :accepted} = post(ctx, "TRK", [item("LEFT", updated_at: later(7200))])
      assert %Item{state: :open, closed_by_listing_at: nil} = ticket(ctx.trk, "LEFT")
    end

    test "its close counts as a write at its started_at: only a write at or after it reopens",
         ctx do
      started = later(600)
      {:ok, :accepted} = post(ctx, "TRK", [item("SAME"), item("AFTER")])
      {:ok, :accepted} = post(ctx, "TRK", [], listing: %{id: "l", started_at: started})

      for ref <- ["SAME", "AFTER"] do
        assert %Item{state: :closed, closed_by_listing_at: closed_at} = ticket(ctx.trk, ref)
        assert DateTime.compare(closed_at, started) == :eq
      end

      # The event sent again at the same updated_at, and one between that and started_at.
      for updated_at <- [at(), later(300)] do
        {:ok, :accepted} = post(ctx, "TRK", [item("SAME", updated_at: updated_at)])
        assert %Item{state: :closed, source_updated_at: kept} = ticket(ctx.trk, "SAME")
        assert kept == at()
      end

      # At started_at, and after it: written, open, and no longer one the listing closed.
      {:ok, :accepted} = post(ctx, "TRK", [item("SAME", updated_at: started)])
      {:ok, :accepted} = post(ctx, "TRK", [item("AFTER", updated_at: later(601))])

      for ref <- ["SAME", "AFTER"],
          do: assert(%Item{state: :open, closed_by_listing_at: nil} = ticket(ctx.trk, ref))
    end

    test "a partial listing only upserts", ctx do
      {:ok, :accepted} = post(ctx, "TRK", [item("OLD")])
      started = later(3600)

      # The last part, with the first missing.
      listing = %{id: "partial", part: 2, started_at: started, complete: true}
      assert post(ctx, "TRK", [item("NEW")], listing: listing) == {:ok, :accepted}

      # A listing whose last part says it is not complete.
      listing = %{id: "unfinished", part: 1, started_at: started, complete: false}
      assert post(ctx, "TRK", [item("NEW2")], listing: listing) == {:ok, :accepted}

      assert open_refs(ctx.trk) == ["NEW", "NEW2", "OLD"]
      assert Repo.all(from l in Listing, where: not is_nil(l.completed_at)) == []
    end

    test "an empty complete listing closes every open item older than it", ctx do
      {:ok, :accepted} = post(ctx, "TRK", [item("A"), item("B")])
      listing = %{id: "empty", started_at: later(60)}
      assert post(ctx, "TRK", [], listing: listing) == {:ok, :accepted}
      assert open_refs(ctx.trk) == []
    end

    test "an item a newer listing named is not closed by an older one", ctx do
      {:ok, :accepted} = post(ctx, "TRK", [item("A"), item("B")])
      older = later(60)
      newer = later(120)

      {:ok, :accepted} =
        post(ctx, "TRK", [item("A")], listing: %{id: "newer", started_at: newer, complete: false})

      {:ok, :accepted} = post(ctx, "TRK", [item("B")], listing: %{id: "older", started_at: older})

      assert open_refs(ctx.trk) == ["A", "B"]
    end

    test "a part that disagrees with the parts before it is refused, and changes nothing",
         ctx do
      first = %{id: "l", part: 1, started_at: later(60), complete: false}
      {:ok, :accepted} = post(ctx, "TRK", [item("A")], listing: first)

      {:ok, :accepted} =
        post(ctx, "TRK", [item("B")], listing: %{first | part: 3, complete: true})

      # Another started_at, a part after the last, a second last part.
      for listing <- [
            %{first | part: 2, started_at: later(61)},
            %{first | part: 4},
            %{first | part: 2, complete: true}
          ] do
        assert post(ctx, "TRK", [item("C")], listing: listing) == {:error, :invalid}
      end

      assert %Listing{parts: [1, 3], last_part: 3, completed_at: nil} =
               Repo.get_by!(Listing, external_id: "l")

      refute Repo.get_by(Item, external_ref: "C")
    end

    test "the bookkeeping goes a day after a listing's first part, with the job that purges",
         ctx do
      {:ok, :accepted} = post(ctx, "TRK", [item("A")], listing: %{id: "old", complete: false})
      {:ok, :accepted} = post(ctx, "TRK", [item("B")], listing: %{id: "new", complete: false})

      Repo.update_all(from(l in Listing, where: l.external_id == "old"),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -86_401, :second)]
      )

      assert Sources.purge_listings(DateTime.utc_now()) == 1
      assert Sources.purge_listings(DateTime.utc_now()) == 0
      assert Repo.all(from l in Listing, select: l.external_id) == ["new"]
      assert open_refs(ctx.trk) == ["A", "B"]

      Repo.update_all(Listing,
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -86_401, :second)]
      )

      assert :ok = perform_job(Apiary.Adapters.SeenRequestsPurge, %{})
      assert count(Listing) == 0
    end
  end

  describe "comments" do
    setup ctx do
      {:ok, :accepted} = post(ctx, "TRK", [item("R")])
      %{item: ticket(ctx.trk, "R")}
    end

    test "are upserted on their item, the newer winning, and one sent deleted is marked",
         ctx do
      assert post_comments(ctx, "R", [comment("C1"), comment("C2", deleted: true)]) ==
               {:ok, :accepted}

      assert %Comment{
               deleted_at: nil,
               author_name: "Robin Example",
               author_kind: :person,
               body: "A comment, C1",
               organisation_id: organisation_id
             } = comment_of(ctx.item, "C1")

      assert organisation_id == ctx.scope.organisation.id
      assert %DateTime{} = marked = comment_of(ctx.item, "C2").deleted_at

      # Older: nothing changes. The same time: it applies.
      {:ok, :accepted} =
        post_comments(ctx, "R", [comment("C1", body: "old", updated_at: later(-60))])

      assert comment_of(ctx.item, "C1").body == "A comment, C1"
      {:ok, :accepted} = post_comments(ctx, "R", [comment("C1", body: "same")])
      assert comment_of(ctx.item, "C1").body == "same"

      # Sent deleted again, it keeps when it was first marked; sent without, it is not.
      {:ok, :accepted} =
        post_comments(ctx, "R", [comment("C2", deleted: true, updated_at: later(1))])

      assert comment_of(ctx.item, "C2").deleted_at == marked
      {:ok, :accepted} = post_comments(ctx, "R", [comment("C2", updated_at: later(2))])
      assert comment_of(ctx.item, "C2").deleted_at == nil
    end

    test "complete marks the item's other comments deleted, except those updated at or after since",
         ctx do
      since = later(600)

      {:ok, :accepted} =
        post_comments(ctx, "R", [
          comment("OLD"),
          comment("AT", updated_at: since),
          comment("AFTER", updated_at: later(900)),
          comment("NAMED")
        ])

      assert post_comments(ctx, "R", [comment("NAMED")], since: since) == {:ok, :accepted}

      assert %DateTime{} = comment_of(ctx.item, "OLD").deleted_at

      for ref <- ["AT", "AFTER", "NAMED"],
          do: assert(comment_of(ctx.item, ref).deleted_at == nil, ref)

      # With no comments, every one updated before since.
      assert post_comments(ctx, "R", [], since: later(1000)) == {:ok, :accepted}

      assert Repo.all(from c in Comment, where: is_nil(c.deleted_at)) == []
    end

    test "complete's mark counts as a write at since: only a write at or after it brings one back",
         ctx do
      since = later(600)
      {:ok, :accepted} = post_comments(ctx, "R", [comment("SAME"), comment("AFTER")])
      {:ok, :accepted} = post_comments(ctx, "R", [], since: since)

      for ref <- ["SAME", "AFTER"] do
        assert %Comment{deleted_at: %DateTime{}, deleted_by_complete_at: ^since} =
                 comment_of(ctx.item, ref)
      end

      # The comment sent again at the same updated_at, and one between that and since.
      for updated_at <- [at(), later(300)] do
        {:ok, :accepted} =
          post_comments(ctx, "R", [comment("SAME", body: "again", updated_at: updated_at)])

        assert %Comment{deleted_at: %DateTime{}, body: "A comment, SAME"} =
                 comment_of(ctx.item, "SAME")
      end

      # At since, and after it: written, and no longer marked.
      {:ok, :accepted} = post_comments(ctx, "R", [comment("SAME", updated_at: since)])
      {:ok, :accepted} = post_comments(ctx, "R", [comment("AFTER", updated_at: later(601))])

      for ref <- ["SAME", "AFTER"] do
        assert %Comment{deleted_at: nil, deleted_by_complete_at: nil} =
                 comment_of(ctx.item, ref)
      end
    end
  end

  describe "a ref another live collection of the adapter holds" do
    setup ctx do
      ops =
        source_collection_fixture(ctx.scope, ctx.connection, %{
          external_ref: "OPS",
          workspace_id: ctx.other_workspace.id
        })

      %{ops: ops}
    end

    test "a moved item: the new collection's write takes the ref, the old one's closed after it does not",
         ctx do
      {:ok, :accepted} = post(ctx, "TRK", [item("R")])
      old = ticket(ctx.trk, "R")

      work_item =
        work_item_fixture(ctx.scope, %{
          connection_id: ctx.connection.id,
          item_id: old.id,
          external_ref: "R"
        })

      assert post(ctx, "OPS", [item("R", updated_at: later(60))]) == {:ok, :accepted}

      # The old record stays on its collection, ended.
      ended = Repo.get!(Item, old.id)
      assert %DateTime{} = ended.disconnected_at

      assert {ended.collection_id, ended.public_id, ended.state} ==
               {ctx.trk.id, old.public_id, :open}

      # The new collection has a new record, with a new tk_ id.
      new = ticket(ctx.ops, "R")
      assert new.id != old.id
      assert new.public_id != old.public_id and Item.public_id?(new.public_id)
      assert {new.state, new.disconnected_at} == {:open, nil}

      # The work item is untouched; its key finds the ticket that holds the ref now.
      kept = [:item_id, :connection_id, :adapter_id, :external_ref, :state, :updated_at]
      assert Map.take(Repo.get!(WorkItem, work_item.id), kept) == Map.take(work_item, kept)
      assert holders(work_item) == [new.id]

      # The "closed" the source sends to the collection it moved out of, with a later
      # updated_at, is kept there, ended; the new ticket stays open and live, in the Backlog
      # of the workspace its collection is linked to.
      assert post(ctx, "TRK", [item("R", state: "closed", updated_at: later(120))]) ==
               {:ok, :accepted}

      assert %Item{state: :closed, disconnected_at: at} = Repo.get!(Item, old.id)
      assert at == ended.disconnected_at
      assert %Item{state: :open, disconnected_at: nil} = Repo.get!(Item, new.id)
      assert holders(work_item) == [new.id]
      assert Repo.get!(Collection, ctx.ops.id).workspace_id == ctx.other_workspace.id

      # Its comments go to the ticket that holds the ref.
      {:ok, :accepted} = post_comments(ctx, "R", [comment("C")])
      assert comment_of(new, "C")
      refute Repo.get_by(Comment, item_id: old.id)
    end

    test "a closed write never takes the ref from an open item; an open one with a later updated_at does",
         ctx do
      {:ok, :accepted} = post(ctx, "OPS", [item("R", updated_at: later(60))])

      # Closed, later: kept in its collection, ended there.
      {:ok, :accepted} = post(ctx, "TRK", [item("R", state: "closed", updated_at: later(120))])
      assert %Item{state: :closed, disconnected_at: %DateTime{}} = ticket(ctx.trk, "R")
      assert %Item{state: :open, disconnected_at: nil} = ticket(ctx.ops, "R")

      # Open, later still: it takes the ref, on the record there.
      {:ok, :accepted} = post(ctx, "TRK", [item("R", updated_at: later(180))])
      assert %Item{state: :open, disconnected_at: nil} = ticket(ctx.trk, "R")
      assert %DateTime{} = ticket(ctx.ops, "R").disconnected_at

      # A closed write takes it from a closed item, when it is newer.
      {:ok, :accepted} = post(ctx, "TRK", [item("R", state: "closed", updated_at: later(240))])
      {:ok, :accepted} = post(ctx, "OPS", [item("R", state: "closed", updated_at: later(300))])
      assert ticket(ctx.ops, "R").disconnected_at == nil
      assert %DateTime{} = ticket(ctx.trk, "R").disconnected_at
    end

    test "a holder a listing closed is kept at the listing's started_at, and so is a write of it after it lost the ref",
         ctx do
      started = later(600)
      dev = source_collection_fixture(ctx.scope, ctx.connection, %{external_ref: "DEV"})
      {:ok, :accepted} = post(ctx, "TRK", [item("R")])
      {:ok, :accepted} = post(ctx, "TRK", [], listing: %{id: "l", started_at: started})
      closed = ticket(ctx.trk, "R")
      assert %Item{state: :closed, disconnected_at: nil} = closed

      # Updated after the one kept but before started_at: it does not take the ref.
      {:ok, :accepted} = post(ctx, "OPS", [item("R", updated_at: later(300))])
      assert %DateTime{} = ticket(ctx.ops, "R").disconnected_at
      assert Repo.get!(Item, closed.id) == closed

      # After started_at, it does; then its collection is disconnected, and a third
      # collection's write, updated before started_at, holds the ref, as none does.
      {:ok, :accepted} = post(ctx, "OPS", [item("R", updated_at: later(700))])
      assert %DateTime{} = Repo.get!(Item, closed.id).disconnected_at
      {:ok, :disconnected} = disconnect(ctx, "OPS")
      {:ok, :accepted} = post(ctx, "DEV", [item("R", updated_at: later(100))])
      holder = ticket(dev, "R")
      assert holder.disconnected_at == nil

      # A write to the closed one, between what it kept and started_at: newer than the
      # holder, but not written, so it takes nothing, and the holder stays live.
      {:ok, :accepted} = post(ctx, "TRK", [item("R", title: "Late", updated_at: later(300))])
      assert %Item{state: :closed, title: "Title of R"} = Repo.get!(Item, closed.id)
      assert Repo.get!(Item, holder.id) == holder
    end

    test "at the same time an open item takes the ref from a closed one; an older one never does",
         ctx do
      {:ok, :accepted} = post(ctx, "TRK", [item("R", state: "closed", updated_at: later(60))])
      old = ticket(ctx.trk, "R")

      # Older than the one that holds it: kept in its collection, ended there.
      {:ok, :accepted} = post(ctx, "OPS", [item("R", updated_at: later(0))])
      assert %DateTime{} = ticket(ctx.ops, "R").disconnected_at
      assert Repo.get!(Item, old.id).disconnected_at == nil

      # The same time, open against closed: it takes the ref.
      {:ok, :accepted} = post(ctx, "OPS", [item("R", updated_at: later(60))])
      assert ticket(ctx.ops, "R").disconnected_at == nil
      assert %DateTime{} = Repo.get!(Item, old.id).disconnected_at

      # A newer write to the collection it left takes it back, on the record there.
      {:ok, :accepted} = post(ctx, "TRK", [item("R", updated_at: later(120))])
      assert %Item{disconnected_at: nil, public_id: public_id} = Repo.get!(Item, old.id)
      assert public_id == old.public_id
      assert %DateTime{} = ticket(ctx.ops, "R").disconnected_at
      assert count(Item) == 2
    end

    test "a ref in an ended collection is held by none", ctx do
      {:ok, :accepted} = post(ctx, "OPS", [item("R")])
      {:ok, :disconnected} = disconnect(ctx, "OPS")

      {:ok, :accepted} = post(ctx, "TRK", [item("R", updated_at: later(-60))])
      assert ticket(ctx.trk, "R").disconnected_at == nil
      assert ticket(ctx.ops, "R").disconnected_at == nil
    end

    test "comments, with no item holding the ref: the collection that ended last answers, and no ended item is written to",
         ctx do
      {:ok, :accepted} = post(ctx, "TRK", [item("R")])
      old = ticket(ctx.trk, "R")
      {:ok, :accepted} = post(ctx, "OPS", [item("R", updated_at: later(60))])

      # The collection of the item that holds it is disconnected: the old one, ended in a
      # live collection, answers for nothing, and the one that ended last is not linked.
      {:ok, :disconnected} = disconnect(ctx, "OPS")
      assert post_comments(ctx, "R", [comment("C")]) == {:error, :not_linked}

      # The connection's end ends the old one's collection after it: connection ended.
      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)
      assert post_comments(ctx, "R", [comment("C")]) == {:error, :ended}

      assert %DateTime{} = Repo.get!(Item, old.id).disconnected_at
      assert count(Comment) == 0
    end

    test "comments, the organisation out of use: the collection of the item that holds the ref is suspended",
         ctx do
      {:ok, :accepted} = post(ctx, "TRK", [item("R")])
      {:ok, :accepted} = post(ctx, "OPS", [item("R", updated_at: later(60))])

      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [ctx.scope.organisation.id])

      assert post_comments(ctx, "R", [comment("C")]) == {:error, :suspended}
      assert count(Comment) == 0
    end

    test "comments, the only item with the ref ended: not linked, and nothing is written", ctx do
      {:ok, :accepted} = post(ctx, "TRK", [item("R")])
      {:ok, :disconnected} = disconnect(ctx, "TRK")
      assert post_comments(ctx, "R", [comment("C")]) == {:error, :not_linked}

      # An item ended in a live collection answers for nothing, even with no other item
      # with its ref, which the rules above never leave.
      {:ok, :accepted} = post(ctx, "OPS", [item("S")])
      Repo.update_all(Item, set: [disconnected_at: DateTime.utc_now()])
      assert post_comments(ctx, "S", [comment("C")]) == {:error, :not_linked}
      assert count(Comment) == 0

      # A write of the ref to a live collection holds it again, and takes its comments.
      {:ok, :accepted} = post(ctx, "OPS", [item("R")])
      assert {:ok, :accepted} = post_comments(ctx, "R", [comment("C")])
      assert comment_of(ticket(ctx.ops, "R"), "C")
    end
  end

  describe "broadcasts" do
    setup ctx do
      Phoenix.PubSub.subscribe(Apiary.PubSub, Topic.topic(ctx.scope.workspace.id))
      Phoenix.PubSub.subscribe(Apiary.PubSub, Topic.topic(ctx.other_workspace.id))
      :ok
    end

    test "carry the public ids of the tickets changed, to their workspace, and nothing else",
         ctx do
      {:ok, :accepted} = post(ctx, "TRK", [item("A"), item("B")])
      assert_receive {:tickets_changed, ids}
      assert ids_only?(ids)

      assert Enum.sort(ids) ==
               Enum.sort([ticket(ctx.trk, "A").public_id, ticket(ctx.trk, "B").public_id])

      # A write that changes nothing, and a refusal, send nothing.
      {:ok, :accepted} = post(ctx, "TRK", [item("A", updated_at: later(-60))])
      {:error, :not_linked} = post(ctx, "NEVER", [item("A")])
      refute_receive {:tickets_changed, _}

      # Comments: their item's id.
      {:ok, :accepted} = post_comments(ctx, "A", [comment("C")])
      a = ticket(ctx.trk, "A").public_id
      assert_receive {:tickets_changed, [^a]}

      # A complete listing: those it closed.
      {:ok, :accepted} = post(ctx, "TRK", [], listing: %{id: "l", started_at: later(60)})
      assert_receive {:tickets_changed, closed}
      assert Enum.sort(closed) == Enum.sort([a, ticket(ctx.trk, "B").public_id])
    end

    test "a ref taken from another collection: each workspace is sent its ticket's id", ctx do
      ops =
        source_collection_fixture(ctx.scope, ctx.connection, %{
          external_ref: "OPS",
          workspace_id: ctx.other_workspace.id
        })

      {:ok, :accepted} = post(ctx, "TRK", [item("R")])
      old = ticket(ctx.trk, "R").public_id
      assert_receive {:tickets_changed, [^old]}

      {:ok, :accepted} = post(ctx, "OPS", [item("R", updated_at: later(60))])
      new = ticket(ops, "R").public_id

      messages =
        for _ <- 1..2 do
          assert_receive {:tickets_changed, ids}
          ids
        end

      assert Enum.sort(messages) == Enum.sort([[old], [new]])
      refute_receive {:tickets_changed, _}
    end
  end
end
