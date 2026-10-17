defmodule Apiary.Sources.Ingest do
  # How `Apiary.Sources` keeps the items and the comments an adapter posts: each post in
  # one transaction, which answers the workspaces whose Backlog it changed, by id, with the
  # public ids of the tickets it changed there, for `Apiary.Sources` to broadcast once it
  # commits.
  #
  # **Refusals**, in the contract's order (`refusal.schema.json`), each changing nothing:
  # `:forbidden`, a request outside the key's rights (`source_item.post`), decided from the
  # key and the action alone; then `:ended`, `:suspended` and `:not_linked`, as
  # `Apiary.Adapters.Collections.resolve/3` decides them for items, by the body's
  # `collection_ref`, and `Apiary.Adapters.Collections.verdict/3` for comments, of the
  # collection that answers for the body's `item_ref`: the collection of the item that
  # holds the ref, or, when none does, the collection that ended last of those with an
  # item with that ref; an `item_ref` the adapter has no item for is `:not_linked`. A ref
  # that is not a text of 1 to 200 characters names nothing, and is not looked up. Before
  # all of these, `:invalid` for an entry the tables would not hold
  # (`Apiary.Sources.Item.changeset/2`, `Apiary.Sources.Comment.changeset/2`), which a
  # body `Apiary.Sources.Wire` read never is; and, after them, for a listing's part that
  # disagrees with the parts before it.
  #
  # **Items.** Each is upserted on its collection and its ref, and is written when its
  # `updated_at` is at or after the time kept: the later of its `source_updated_at` and,
  # for an item a complete listing closed, that listing's `started_at`
  # (`closed_by_listing_at`). The close counts as a write at `started_at`, so an event
  # sent again, or one updated before the listing began, leaves the item closed. Of two
  # with the same time the later post wins, as the decoder keeps the last named of two in
  # one body. A `comment_count` past what a bigint holds is kept as that most: the
  # contract bounds it by nothing, so a body it allows is not refused, and no source has
  # so many. A written item is no longer one a listing closed.
  #
  # **A ref held in another collection.** An item's ref is unique among the items of the
  # adapter's live collections, which no index holds: it is held here. Where an item
  # written to a collection has a ref that an item of another live collection of the same
  # adapter holds, the write takes the ref when it is newer: an `updated_at` after the
  # time the holder is kept at, as above, where a listing's close counts as a write at its
  # `started_at`; or, at that time, open against closed. A closed write never takes the
  # ref from an open item: the contract sends an item moved out of a collection as
  # closed, so a "closed" says the item is no longer in that collection. When the write
  # takes the ref, the item that held it ends where it is, in its collection
  # (`disconnected_at`), and leaves every Backlog; the one written is a ticket of the
  # collection it was written to, a new row with a new `tk_` id where that collection had
  # none. Nothing moves between collections, and no work item changes. An item whose
  # write does not take the ref is kept in its collection, ended there. One that ended so
  # takes the ref back when a later write of it to its collection takes the ref.
  #
  # **Listings.** A part of a listing adds its number to the listing's bookkeeping
  # (`Apiary.Sources.Listing`), as `Apiary.Adapters.Collections` keeps a listing of
  # collections: a part with another `started_at` than the ones before it, a second last
  # part, or a part after the last is refused. Each item a part names keeps the
  # listing's `started_at` (`last_listed_at`, the newest). Once every part from 1 to the
  # last has arrived, and only then, the listing is complete: every open item of the
  # collection that it left out, whose `last_listed_at` and `source_updated_at` are before
  # its `started_at`, and that has not ended, is closed, and keeps that `started_at`
  # (`closed_by_listing_at`). A partial listing only upserts. The bookkeeping goes a day
  # after its first part (`purge_listings/1`).
  #
  # **Comments** go to the item that holds the body's `item_ref`, of a live collection
  # and not ended, decided under the locks below; never to an item that ended. Each is
  # upserted on its item and its ref, and is written when its `updated_at` is at or after
  # the time kept: the later of its `source_updated_at` and, for a comment a complete set
  # marked deleted, that set's `complete.since` (`deleted_by_complete_at`). The mark
  # counts as a write at `complete.since`, as a listing's close does for items. One sent
  # `deleted` keeps the time it was first marked (`deleted_at`); one sent again without
  # it is no longer marked. With `complete`, every other comment of the item that is not
  # marked and was updated before `complete.since` is marked deleted, and keeps
  # `complete.since`.
  #
  # **Locks.** For items, in this order: the collection's connection, `FOR UPDATE`, so
  # that one connection's posts and listings of collections are taken one at a time and
  # never beside its end; the collection, `FOR SHARE`, so that it does not end meanwhile,
  # and the answer is decided again on it as it is held; a transaction lock on each ref
  # the body names, in the adapter (`pg_advisory_xact_lock`), by key, so that two
  # connections never hold one ref at once; then the items of the adapter's live
  # collections with those refs, and those a completing listing may close, `FOR UPDATE`,
  # by ref, then id. For comments, in this order: the lock on the `item_ref` in the
  # adapter, so that no write takes the ref meanwhile, under which the item that holds it
  # is looked up; its collection, `FOR SHARE`, so that it does not end meanwhile, and the
  # answer is decided again on it as it is held, or, should it have ended, decided again
  # from the start; the item; then the comments. Comments take no connection's row: they
  # take the ref's lock first, and a post of items holds its connection's row while it
  # waits for that lock, so each would wait on the other. Nothing here writes the
  # adapter's feed.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.Repo
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Collections, Connection, Connections}
  alias Apiary.Sources.{Comment, Item, Listing, Wire}

  @action :"source_item.post"
  @max_ref 200
  # The most a bigint column holds.
  @max_count 9_223_372_036_854_775_807
  # How long a listing's bookkeeping is kept after its first part, in seconds.
  @listing_seconds 24 * 60 * 60

  @typedoc "Why a post is refused."
  @type refusal :: Collections.refusal() | :invalid

  @typedoc "The public ids of the tickets a post changed, by the id of their workspace."
  @type changed :: %{Ecto.UUID.t() => [String.t()]}

  ## Items

  @doc false
  # items/2 keeps the items of a body of `POST /v1/source-items`, as the module says:
  # `{:ok, changed}` once it commits, or `{:error, refusal}`.
  @spec items(Scope.t() | nil, Wire.items()) :: {:ok, changed} | {:error, refusal}
  def items(key_scope, %{collection_ref: ref, items: items, listing: part}) do
    with {:ok, rows} <- item_rows(items) do
      Repo.transact(fn ->
        with {:ok, found, _scope} <- Collections.resolve(key_scope, bounded(ref), @action),
             {:ok, collection} <- hold(key_scope, found),
             {:ok, listing} <- record_part(collection, part) do
          {:ok, put_items(collection, rows, listing)}
        end
      end)
    end
  end

  # The items as the tables hold them, by ref; `{:error, :invalid}` for one they would
  # not hold.
  defp item_rows(items) do
    items
    |> Enum.map(fn item ->
      Item.changeset(%Item{}, %{
        external_ref: item.ref,
        key: item.key,
        url: item.url,
        title: item.title,
        body: item.body,
        body_format: item.body_format,
        filed_by_name: item.filed_by.name,
        filed_by_kind: item.filed_by.kind,
        labels: item.labels,
        state: item.state,
        state_reason: item.state_reason,
        type: item.type,
        target_system: item.target && item.target.system,
        target_path: item.target && item.target.path,
        truncated: item.truncated,
        comment_count: min(item.comment_count, @max_count),
        source_created_at: item.created_at,
        source_updated_at: item.updated_at
      })
    end)
    |> valid_rows()
  end

  defp valid_rows(changesets) do
    if Enum.all?(changesets, & &1.valid?),
      do: {:ok, changesets |> Enum.map(&Ecto.Changeset.apply_changes/1) |> by_ref()},
      else: {:error, :invalid}
  end

  # By ref, in the order of its bytes, as the rows are locked (`lock_items/3`).
  defp by_ref(rows), do: Enum.sort_by(rows, & &1.external_ref)

  # A ref the contract allows, else nil, which names nothing.
  defp bounded(ref), do: if(Apiary.Adapters.Wire.text?(ref, 1, @max_ref), do: ref)

  # Holds the connection of `found` `FOR UPDATE`, then `found` `FOR SHARE`, and decides
  # the answer again on it as it is held: `{:ok, collection}`, live and linked to a
  # workspace, or the refusal.
  defp hold(key_scope, %Collection{id: id, connection_id: connection_id}) do
    _connection =
      Repo.one(from c in Connection, where: c.id == ^connection_id, lock: "FOR UPDATE")

    held = Repo.one(from c in Collection, where: c.id == ^id, lock: "FOR SHARE")

    with {:ok, collection, _scope} <- Collections.verdict(key_scope, held, @action),
         do: {:ok, collection}
  end

  # Adds the part's number to its listing's bookkeeping, held `FOR UPDATE`, so that the
  # purge does not delete it meanwhile: `{:ok, listing}`, as it now stands, `{:ok, nil}`
  # for an event, or `{:error, :invalid}` for a part that disagrees with the parts before
  # it. A part whose bookkeeping the purge deleted starts it again.
  defp record_part(_collection, nil), do: {:ok, nil}

  defp record_part(%Collection{id: collection_id} = collection, part) do
    case Repo.one(
           from l in Listing,
             where: l.collection_id == ^collection_id and l.external_id == ^part.id,
             lock: "FOR UPDATE"
         ) do
      nil ->
        {:ok,
         Repo.insert!(%Listing{
           organisation_id: collection.organisation_id,
           collection_id: collection.id,
           external_id: part.id,
           started_at: part.started_at,
           parts: [part.part],
           last_part: if(part.complete, do: part.part),
           inserted_at: DateTime.utc_now()
         })}

      %Listing{} = listing ->
        with :ok <- agrees(listing, part) do
          {:ok,
           listing
           |> Ecto.Changeset.change(
             parts: Enum.sort(Enum.uniq([part.part | listing.parts])),
             last_part: if(part.complete, do: part.part, else: listing.last_part)
           )
           |> Repo.update!()}
        end
    end
  end

  # A part agrees with its listing's parts before it: the same `started_at`; and, once a
  # part said it is the last, no part after it, and no other part saying it is the last.
  defp agrees(listing, part) do
    cond do
      DateTime.compare(listing.started_at, part.started_at) != :eq ->
        {:error, :invalid}

      part.complete and Enum.max(listing.parts) > part.part ->
        {:error, :invalid}

      part.complete and listing.last_part not in [nil, part.part] ->
        {:error, :invalid}

      not part.complete and listing.last_part != nil and part.part >= listing.last_part ->
        {:error, :invalid}

      true ->
        :ok
    end
  end

  # Whether `listing` became complete with this part: every part from 1 to the last has
  # arrived, and it was not complete before.
  defp completing?(nil), do: false

  defp completing?(%Listing{} = listing),
    do:
      is_nil(listing.completed_at) and is_integer(listing.last_part) and
        length(listing.parts) == listing.last_part

  defp put_items(%Collection{} = collection, rows, listing) do
    now = DateTime.utc_now()
    refs = Enum.map(rows, & &1.external_ref)
    closing_from = if completing?(listing), do: listing.started_at

    :ok = lock_refs(collection.adapter_id, refs)
    held = lock_items(collection, refs, closing_from)

    {mine, others} =
      Enum.split_with(held, fn {item, _ws} -> item.collection_id == collection.id end)

    mine = Map.new(mine, fn {item, _ws} -> {item.external_ref, item} end)

    holders =
      for {%Item{disconnected_at: nil} = item, _ws} = holder <- others,
          reduce: %{},
          do: (acc -> Map.update(acc, item.external_ref, [holder], &[holder | &1]))

    {put, ended} =
      Enum.reduce(rows, {[], []}, fn row, {put, ended} ->
        kept = Map.get(mine, row.external_ref)
        held_by = Map.get(holders, row.external_ref, [])

        cond do
          not newer_or_same?(row, kept) ->
            {put, ended}

          Enum.all?(held_by, fn {holder, _ws} -> takes_ref?(row, holder) end) ->
            {[item_row(collection, row, nil, now) | put], held_by ++ ended}

          true ->
            ended_at = (kept && kept.disconnected_at) || now
            {[item_row(collection, row, ended_at, now) | put], ended}
        end
      end)

    ended_changed = end_items(ended, now)
    written = upsert_items(Enum.reverse(put))
    if listing, do: mark_listed(collection, refs, listing.started_at)
    closed = if closing_from, do: close_left_out(collection, listing, now), else: []

    ended_changed
    |> add(collection.workspace_id, written ++ closed)
  end

  # A transaction lock on each of `refs` in the adapter, by key, each once: held until the
  # transaction ends, so that another post naming one of them, of any connection of the
  # adapter, waits for it.
  defp lock_refs(_adapter_id, []), do: :ok

  defp lock_refs(adapter_id, refs) do
    Repo.query!(
      """
      SELECT pg_advisory_xact_lock(keys.key) FROM (
        SELECT DISTINCT hashtextextended('apiary:source-item:' || $1 || ':' || t.ref, 0) AS key
        FROM unnest($2::text[]) AS t(ref)
        ORDER BY key
      ) AS keys
      """,
      [adapter_id, refs]
    )

    :ok
  end

  # The items of the adapter's live collections with `refs`, and, when `closing_from` is a
  # listing's `started_at`, the items of `collection` that its completion may close, each
  # with the workspace of its collection, held `FOR UPDATE` by ref, then id.
  defp lock_items(%Collection{} = collection, refs, closing_from) do
    named = dynamic([i], i.external_ref in ^refs)

    which =
      if closing_from,
        do: dynamic([i], ^named or ^closable(collection, closing_from)),
        else: named

    if refs == [] and is_nil(closing_from) do
      []
    else
      Repo.all(
        from i in Item,
          join: c in Collection,
          on: c.id == i.collection_id,
          where: c.adapter_id == ^collection.adapter_id and is_nil(c.ended_at),
          where: i.adapter_id == ^collection.adapter_id,
          where: ^which,
          order_by: [asc: fragment("? COLLATE \"C\"", i.external_ref), asc: i.id],
          lock: "FOR UPDATE OF s0",
          select: {i, c.workspace_id}
      )
    end
  end

  # The open items of `collection` that a listing started at `started_at` left out, and
  # that no newer write or listing names, and that have not ended.
  defp closable(%Collection{id: collection_id}, started_at) do
    dynamic(
      [i],
      i.collection_id == ^collection_id and i.state == :open and is_nil(i.disconnected_at) and
        i.source_updated_at < ^started_at and
        (is_nil(i.last_listed_at) or i.last_listed_at < ^started_at)
    )
  end

  # The write is at or after the time kept (`kept_at/1`), or none is kept: as
  # `upsert_items/1` decides it.
  defp newer_or_same?(_row, nil), do: true

  defp newer_or_same?(row, %Item{} = kept),
    do: DateTime.compare(row.source_updated_at, kept_at(kept)) != :lt

  # The time an item is kept at: the later of its `source_updated_at` and, for one a
  # complete listing closed, that listing's `started_at` (`closed_by_listing_at`), as
  # `GREATEST`, which passes over NULL, takes them in `upsert_items/1`.
  defp kept_at(%Item{source_updated_at: updated_at, closed_by_listing_at: nil}), do: updated_at

  defp kept_at(%Item{source_updated_at: updated_at, closed_by_listing_at: closed_at}),
    do: if(DateTime.compare(closed_at, updated_at) == :gt, do: closed_at, else: updated_at)

  # The write takes its ref from `holder`, an item of another live collection: never a
  # closed write from an open holder; otherwise when it is newer than the time the holder
  # is kept at (`kept_at/1`), or, at that time, when it is open and the holder closed.
  defp takes_ref?(%Item{state: :closed}, %Item{state: :open}), do: false

  defp takes_ref?(row, %Item{} = holder) do
    case DateTime.compare(row.source_updated_at, kept_at(holder)) do
      :gt -> true
      :eq -> row.state == :open and holder.state == :closed
      :lt -> false
    end
  end

  defp item_row(%Collection{} = collection, %Item{} = row, ended_at, now) do
    %{
      id: Ecto.UUID.generate(),
      organisation_id: collection.organisation_id,
      adapter_id: collection.adapter_id,
      collection_id: collection.id,
      external_ref: row.external_ref,
      key: row.key,
      url: row.url,
      title: row.title,
      body: row.body,
      body_format: row.body_format,
      filed_by_name: row.filed_by_name,
      filed_by_kind: row.filed_by_kind,
      labels: row.labels,
      state: row.state,
      state_reason: row.state_reason,
      type: row.type,
      target_system: row.target_system,
      target_path: row.target_path,
      truncated: row.truncated,
      comment_count: row.comment_count,
      source_created_at: row.source_created_at,
      source_updated_at: row.source_updated_at,
      disconnected_at: ended_at,
      inserted_at: now,
      updated_at: now
    }
  end

  # Ends each of `held`, items of other collections whose ref a write took, where they
  # are: the changed public ids by workspace.
  defp end_items([], _now), do: %{}

  defp end_items(held, now) do
    ids = held |> Enum.map(fn {item, _ws} -> item.id end) |> Enum.uniq()

    {_count, _} =
      Repo.update_all(from(i in Item, where: i.id in ^ids),
        set: [disconnected_at: now, updated_at: now]
      )

    Enum.reduce(held, %{}, fn {item, workspace_id}, changed ->
      add(changed, workspace_id, [item.public_id])
    end)
  end

  # One statement for the body's items: each made, or written over the one kept when it
  # is at or after the time kept (`kept_at/1`). The public ids of those written.
  defp upsert_items([]), do: []

  defp upsert_items(rows) do
    newer =
      from i in Item,
        where:
          fragment(
            "EXCLUDED.source_updated_at >= GREATEST(?, ?)",
            i.source_updated_at,
            i.closed_by_listing_at
          ),
        update: [
          set: [
            key: fragment("EXCLUDED.key"),
            url: fragment("EXCLUDED.url"),
            title: fragment("EXCLUDED.title"),
            body: fragment("EXCLUDED.body"),
            body_format: fragment("EXCLUDED.body_format"),
            filed_by_name: fragment("EXCLUDED.filed_by_name"),
            filed_by_kind: fragment("EXCLUDED.filed_by_kind"),
            labels: fragment("EXCLUDED.labels"),
            state: fragment("EXCLUDED.state"),
            state_reason: fragment("EXCLUDED.state_reason"),
            type: fragment("EXCLUDED.type"),
            target_system: fragment("EXCLUDED.target_system"),
            target_path: fragment("EXCLUDED.target_path"),
            truncated: fragment("EXCLUDED.truncated"),
            comment_count: fragment("EXCLUDED.comment_count"),
            source_created_at: fragment("EXCLUDED.source_created_at"),
            source_updated_at: fragment("EXCLUDED.source_updated_at"),
            disconnected_at: fragment("EXCLUDED.disconnected_at"),
            closed_by_listing_at: nil,
            updated_at: fragment("EXCLUDED.updated_at")
          ]
        ]

    {_count, written} =
      Repo.insert_all(Item, rows,
        on_conflict: newer,
        conflict_target: [:collection_id, :external_ref],
        returning: [:public_id]
      )

    Enum.map(written, & &1.public_id)
  end

  # Each item of `collection` with one of `refs` keeps `started_at` as the newest listing
  # that named it.
  defp mark_listed(_collection, [], _started_at), do: :ok

  defp mark_listed(%Collection{id: collection_id}, refs, started_at) do
    {_count, _} =
      Repo.update_all(
        from(i in Item,
          where: i.collection_id == ^collection_id and i.external_ref in ^refs,
          where: is_nil(i.last_listed_at) or i.last_listed_at < ^started_at
        ),
        set: [last_listed_at: started_at]
      )

    :ok
  end

  # Closes what the complete `listing` left out (`closable/2`), each keeping the listing's
  # `started_at`, and marks the listing complete: the public ids of those closed.
  defp close_left_out(%Collection{} = collection, %Listing{} = listing, now) do
    {_count, closed} =
      Repo.update_all(
        from(i in Item, where: ^closable(collection, listing.started_at), select: i.public_id),
        set: [
          state: :closed,
          closed_by_listing_at: %{listing.started_at | microsecond: {0, 6}},
          updated_at: now
        ]
      )

    {1, _} =
      Repo.update_all(from(l in Listing, where: l.id == ^listing.id),
        set: [completed_at: now]
      )

    closed
  end

  defp add(changed, nil, _ids), do: changed
  defp add(changed, _workspace_id, []), do: changed
  defp add(changed, workspace_id, ids), do: Map.update(changed, workspace_id, ids, &(&1 ++ ids))

  ## Comments

  @doc false
  # comments/2 keeps the comments of a body of `POST /v1/source-items/comments`, as the
  # module says: `{:ok, changed}` once it commits, or `{:error, refusal}`.
  @spec comments(Scope.t() | nil, Wire.comments()) :: {:ok, changed} | {:error, refusal}
  def comments(key_scope, %{item_ref: ref, comments: comments, complete: complete}) do
    with {:ok, rows} <- comment_rows(comments) do
      Repo.transact(fn ->
        with {:ok, adapter_id} <- Connections.key_rights(key_scope, @action),
             {:ok, collection, item} <- hold_item(key_scope, adapter_id, bounded(ref)) do
          {:ok, put_comments(collection, item, rows, complete)}
        end
      end)
    end
  end

  # The comments as the table holds them, each with whether it was sent deleted, by ref;
  # `{:error, :invalid}` for one it would not hold.
  defp comment_rows(comments) do
    changesets =
      Enum.map(comments, fn comment ->
        {Comment.changeset(%Comment{}, %{
           external_ref: comment.ref,
           url: comment.url,
           author_name: comment.author.name,
           author_kind: comment.author.kind,
           body: comment.body,
           body_format: comment.body_format,
           truncated: comment.truncated,
           source_created_at: comment.created_at,
           source_updated_at: comment.updated_at
         }), comment.deleted}
      end)

    if Enum.all?(changesets, fn {changeset, _deleted} -> changeset.valid? end),
      do:
        {:ok,
         changesets
         |> Enum.map(fn {changeset, deleted} ->
           {Ecto.Changeset.apply_changes(changeset), deleted}
         end)
         |> Enum.sort_by(fn {row, _deleted} -> row.external_ref end)},
      else: {:error, :invalid}
  end

  # Under the lock on `ref` in the adapter `adapter_id` (`lock_refs/2`): `{:ok,
  # collection, item}`, the item that holds `ref` and its collection, both held, the
  # answer decided again on the collection as it is held; or the refusal of the
  # collection that answers (`answering_item/2`). A ref that names nothing is not linked.
  defp hold_item(_key_scope, _adapter_id, nil), do: {:error, :not_linked}

  defp hold_item(key_scope, adapter_id, ref) do
    :ok = lock_refs(adapter_id, [ref])
    hold_answering(key_scope, adapter_id, ref)
  end

  # While the ref's lock is held, no write takes the ref, and no item comes to hold it;
  # only the collection of the one that holds it may end, until it is held `FOR SHARE`.
  # Should it have ended meanwhile, the answer is decided again from the start: by the
  # collection that ended last, as no item holds the ref now. Should it be gone, as its
  # organisation's purge deletes it, `{:error, :not_linked}`.
  defp hold_answering(key_scope, adapter_id, ref) do
    item = answering_item(adapter_id, ref)

    with {:ok, _collection, _scope} <-
           Collections.verdict(key_scope, item && item.collection, @action) do
      case Repo.one(from c in Collection, where: c.id == ^item.collection_id, lock: "FOR SHARE") do
        %Collection{ended_at: nil} = held ->
          with {:ok, collection, _scope} <- Collections.verdict(key_scope, held, @action),
               %Item{} = item <- lock_item(item),
               do: {:ok, collection, item}

        %Collection{} ->
          hold_answering(key_scope, adapter_id, ref)

        nil ->
          {:error, :not_linked}
      end
    end
  end

  # The item of the adapter `adapter_id` with the ref `ref` whose collection answers for
  # it, with that collection: the one that holds the ref, of a live collection and not
  # ended; or, when none does, the one of the collection that ended last; nil for none.
  # An item that ended in a live collection answers for nothing: the item that took its
  # ref holds it, or is of a collection that ended since.
  defp answering_item(adapter_id, ref) do
    Repo.one(
      from i in Item,
        join: c in assoc(i, :collection),
        where: c.adapter_id == ^adapter_id and i.adapter_id == ^adapter_id,
        where: i.external_ref == ^ref,
        where: not is_nil(c.ended_at) or is_nil(i.disconnected_at),
        order_by: [desc_nulls_first: c.ended_at, desc: c.inserted_at, desc: c.id],
        limit: 1,
        preload: [collection: c]
    )
  end

  # The item, held `FOR UPDATE`, once its collection is held; `{:error, :not_linked}` when
  # it is gone, as its organisation's purge deletes it.
  defp lock_item(%Item{id: id}) do
    Repo.one(from i in Item, where: i.id == ^id, lock: "FOR UPDATE") || {:error, :not_linked}
  end

  defp put_comments(%Collection{} = collection, %Item{} = item, rows, complete) do
    now = DateTime.utc_now()
    written = upsert_comments(item, rows, now)
    marked = if complete, do: mark_others(item, rows, complete.since, now), else: 0

    if written > 0 or marked > 0,
      do: add(%{}, collection.workspace_id, [item.public_id]),
      else: %{}
  end

  # One statement for the body's comments: each made, or written over the one kept when
  # it is at or after the time kept, the later of its `source_updated_at` and
  # `deleted_by_complete_at`. How many were written.
  defp upsert_comments(_item, [], _now), do: 0

  defp upsert_comments(%Item{} = item, rows, now) do
    rows =
      for {%Comment{} = row, deleted} <- rows do
        %{
          id: Ecto.UUID.generate(),
          organisation_id: item.organisation_id,
          item_id: item.id,
          external_ref: row.external_ref,
          url: row.url,
          author_name: row.author_name,
          author_kind: row.author_kind,
          body: row.body,
          body_format: row.body_format,
          truncated: row.truncated,
          source_created_at: row.source_created_at,
          source_updated_at: row.source_updated_at,
          deleted_at: if(deleted, do: now),
          inserted_at: now,
          updated_at: now
        }
      end

    newer =
      from c in Comment,
        where:
          fragment(
            "EXCLUDED.source_updated_at >= GREATEST(?, ?)",
            c.source_updated_at,
            c.deleted_by_complete_at
          ),
        update: [
          set: [
            url: fragment("EXCLUDED.url"),
            author_name: fragment("EXCLUDED.author_name"),
            author_kind: fragment("EXCLUDED.author_kind"),
            body: fragment("EXCLUDED.body"),
            body_format: fragment("EXCLUDED.body_format"),
            truncated: fragment("EXCLUDED.truncated"),
            source_created_at: fragment("EXCLUDED.source_created_at"),
            source_updated_at: fragment("EXCLUDED.source_updated_at"),
            deleted_at:
              fragment(
                "CASE WHEN EXCLUDED.deleted_at IS NULL THEN NULL ELSE COALESCE(?, EXCLUDED.deleted_at) END",
                c.deleted_at
              ),
            deleted_by_complete_at: nil,
            updated_at: fragment("EXCLUDED.updated_at")
          ]
        ]

    {count, _} =
      Repo.insert_all(Comment, rows,
        on_conflict: newer,
        conflict_target: [:item_id, :external_ref]
      )

    count
  end

  # Marks deleted every comment of `item` the body did not name, not marked yet, and
  # updated before `since`, each keeping `since`. How many were marked.
  defp mark_others(%Item{id: item_id}, rows, since, now) do
    refs = Enum.map(rows, fn {row, _deleted} -> row.external_ref end)

    {count, _} =
      Repo.update_all(
        from(c in Comment,
          where: c.item_id == ^item_id and is_nil(c.deleted_at),
          where: c.source_updated_at < ^since and c.external_ref not in ^refs
        ),
        set: [deleted_at: now, deleted_by_complete_at: since, updated_at: now]
      )

    count
  end

  ## Purge

  @doc false
  # purge_listings/1 deletes the bookkeeping of items listings whose first part arrived
  # more than a day before `now`. The number deleted.
  @spec purge_listings(DateTime.t()) :: non_neg_integer
  def purge_listings(%DateTime{} = now) do
    before = DateTime.add(now, -@listing_seconds, :second)
    {count, _} = Repo.delete_all(from l in Listing, where: l.inserted_at < ^before)
    count
  end
end
