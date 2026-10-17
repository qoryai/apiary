defmodule Apiary.Adapters.Collections do
  # The collections an organisation's connection to an adapter reaches
  # (`Apiary.Adapters.Collection`, `sc_…`), as the adapter's listing names them, each
  # linked to one workspace or to none; and the refs that name them at the server
  # contract. A collection is an engine word (docs/lingo.md).
  #
  # **The listing** (`post_listing/2`, `POST /v1/source-collections`) comes in parts, each
  # naming its connection, the listing's id, its part number, its `started_at` and whether
  # it is the last part (`complete`). Each part is taken under the connection's row held
  # `FOR UPDATE`, so one connection's parts, of any listing, are taken one at a time, and
  # never beside the end of that connection. A part records the connection's first listing
  # (`Apiary.Adapters.Connections.mark_listed/1`), then adds its number to the listing's
  # bookkeeping (`source_collection_listings`), then makes each collection it names live
  # under the connection, or updates the one live: its `url`, `title` and target, and
  # `last_listed_at`, the listing's `started_at`, unless a newer listing named it already.
  # A ref live under another connection of the adapter stays with that connection. A part
  # that disagrees with the parts before it (another `started_at`, a second last part, a
  # part after the last) is refused and changes nothing. Once every part from 1 to the last
  # has arrived, the listing is complete: every live collection of the connection whose
  # `last_listed_at` is before its `started_at` ends (`not_listed`), once, and the
  # connection keeps the time (`listing_completed_at`, the listing-complete marker). The
  # bookkeeping is deleted a day after a listing's first part (`purge_listings/1`).
  #
  # **Auto-assign**: while the organisation has exactly one workspace that is not marked
  # for deletion, a collection a part makes is linked to it as it is made, with the feed's
  # `linked` entry, in the part's transaction; one the part only updates keeps its link.
  # With two workspaces or more, a new collection is linked to none, until a person
  # assigns it.
  #
  # **The end of a collection** is final: by `POST /v1/sources/disconnect`
  # (`disconnect/2`), by a complete listing that leaves it out, or with its connection
  # (`end_for_connections/2`, which `Apiary.Adapters.Connections` calls in each end's
  # transaction). Each end of a collection linked to a workspace writes the feed's entry
  # `%{kind: "collection", collection_ref: ref, status: "unlinked"}`
  # (`Apiary.Adapters.Feed`), in the same transaction; a workspace's purge unlinks its
  # collections so too (`unlink_workspace/2`), and they stay with their organisation.
  #
  # **A ref** names a collection of the key's adapter (`resolve/3`): the live one with that
  # ref, or, when none is live, the one with that ref that ended last.
  #
  # **For people**, each read asks `adapter.read` of the scope's organisation (members), and
  # answers nothing to anyone else, and nothing of a connection of another organisation:
  # `list_collections/3`, a connection's collections a page at a time; `counts/2` and
  # `count_unassigned/2`. `assign_collections/4` assigns collections to a workspace, or to
  # none (`collection.assign`, owners and admins), by the ids Qory Apiary gives them,
  # never by refs, with the feed's `linked` entry for each it links from none and its
  # `unlinked` entry for each it unlinks, in its transaction; a move from one workspace
  # to another writes none.
  #
  # **Broadcasts**, after the change commits, carry ids only, on the organisation's topic
  # (`topic/1`, `"adapter_collections:"` and the organisation's id), which `subscribe/1`
  # and `subscribe/2` join for a person who may read the organisation's adapters:
  #
  #   * `{:collections_changed, %{connection_id: id, collection_ids: ids}}`, the ids of the
  #     collections of the connection `id` that a listing's part made, updated or ended,
  #     or that an assign linked, moved or unlinked; one message per part that changed
  #     any, and per assign that changed any, none for one that changed none;
  #   * `{:connection_changed, %{connection_id: id, adapter_id: id}}`, when the connection
  #     changes as its page shows it (`broadcast_connection/1`): a press of Install that
  #     takes or makes it, or that replaces it (its end), its return that connects it, its
  #     end by the adapter, by the adapter's deletion or by its organisation's purge, the
  #     first listing that names it and each listing of it that completes.
  #
  # Locks: the connection, then the workspace a collection is linked to (`FOR SHARE`), then
  # the collections, by id for an assign and by ref for a listing's part, then the
  # adapter's feed counter, which is the last.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, PublicId, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Connection, Connections, Feed, Wire}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}

  @listing_action :"source_item.post"
  @disconnect_action :"adapter.disconnect"
  @live_index "(adapter_id, external_ref) WHERE ended_at IS NULL"
  @listings "source_collection_listings"
  # How long a listing's bookkeeping is kept after its first part, in seconds.
  @listing_seconds 24 * 60 * 60
  # The rows a page of collections holds; the characters a search holds at most, a title's
  # most; the ids one assign takes at most.
  @page_size 50
  @max_search 1024
  @max_assign 10_000

  @typedoc """
  A collection a connection reaches, as a page lists it: its id and public id, its title
  (`name`) and address, its workspace, when it was added and last listed, when and why it
  ended (nil while live), and its open tickets.
  """
  @type row :: %{
          id: Ecto.UUID.t(),
          public_id: String.t(),
          name: String.t(),
          url: String.t(),
          workspace: Workspace.t() | nil,
          added_at: DateTime.t(),
          last_listed_at: DateTime.t(),
          ended_at: DateTime.t() | nil,
          ended_reason: Collection.ended_reason() | nil,
          open_tickets: non_neg_integer
        }

  @typedoc "How many live collections a connection reaches: all, unassigned, by workspace id."
  @type counts :: %{
          total: non_neg_integer,
          unassigned: non_neg_integer,
          by_workspace: %{Ecto.UUID.t() => pos_integer}
        }

  @typedoc "Why a ref is refused for items and comments, in the contract's order."
  @type refusal :: :forbidden | :ended | :suspended | :not_linked

  ## At the server contract

  @doc false
  # post_listing/2 takes one part of a listing of collections
  # (`Apiary.Adapters.Wire.listing/1`) from the adapter's key of `key_scope`
  # (`source_item.post`), as the module says. `{:ok, :accepted}`; else, in this order:
  # `{:error, :forbidden}` for a request outside the key's rights; `{:error, :unknown}`
  # for a connection the core does not hold for the key's adapter, or one pending;
  # `{:error, :ended}` for one that ended; `{:error, :suspended}` while its organisation is
  # out of use (`Apiary.Adapters.Connections.connection_for_key/3`); `{:error, :invalid}`
  # for a part that disagrees with the listing's parts before it. Each refusal changes
  # nothing.
  @spec post_listing(Scope.t() | nil, Wire.listing()) ::
          {:ok, :accepted} | {:error, :forbidden | :unknown | :ended | :suspended | :invalid}
  def post_listing(key_scope, %{
        connection_id: public_id,
        collections: collections,
        listing: part
      }) do
    Repo.transact(fn ->
      with {:ok, found, _scope} <-
             Connections.connection_for_key(key_scope, public_id, @listing_action),
           {:ok, connection} <- Connections.mark_listed(found),
           {:ok, listing} <- record_part(connection, part) do
        now = DateTime.utc_now()
        put = put_collections(connection, collections, part.started_at, now)
        {ended, completed?} = complete(connection, listing, now)
        {:ok, {connection, put ++ ended, is_nil(found.listed_at) or completed?}}
      end
    end)
    |> case do
      {:ok, {connection, collection_ids, connection_changed?}} ->
        :ok = broadcast_collections(connection, collection_ids)
        if connection_changed?, do: :ok = broadcast_connection(connection)
        {:ok, :accepted}

      {:error, _reason} = refused ->
        refused
    end
  end

  # Adds the part's number to its listing's bookkeeping, under the connection's lock:
  # `{:ok, listing}`, as it now stands, or `{:error, :invalid}` for a part that disagrees
  # with the parts before it.
  defp record_part(%Connection{} = connection, part) do
    case Repo.one(
           from l in @listings,
             where: l.connection_id == type(^connection.id, :binary_id),
             where: l.external_id == ^part.id,
             select: %{
               id: type(l.id, :binary_id),
               started_at: type(l.started_at, :utc_datetime),
               parts: l.parts,
               last_part: l.last_part,
               completed_at: l.completed_at
             }
         ) do
      nil ->
        listing = %{
          id: Ecto.UUID.generate(),
          started_at: part.started_at,
          parts: [part.part],
          last_part: if(part.complete, do: part.part),
          completed_at: nil
        }

        {1, _} =
          Repo.insert_all(@listings, [
            %{
              id: Ecto.UUID.dump!(listing.id),
              organisation_id: Ecto.UUID.dump!(connection.organisation_id),
              connection_id: Ecto.UUID.dump!(connection.id),
              external_id: part.id,
              started_at: part.started_at,
              parts: listing.parts,
              last_part: listing.last_part,
              inserted_at: DateTime.utc_now()
            }
          ])

        {:ok, listing}

      %{} = listing ->
        with :ok <- agrees(listing, part) do
          parts = Enum.sort(Enum.uniq([part.part | listing.parts]))
          last_part = if part.complete, do: part.part, else: listing.last_part

          {1, _} =
            Repo.update_all(
              from(l in @listings, where: l.id == type(^listing.id, :binary_id)),
              set: [parts: parts, last_part: last_part]
            )

          {:ok, %{listing | parts: parts, last_part: last_part}}
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

  # Makes each collection live under `connection`, or updates the one live under it, as
  # the module says, by ref, so two parts naming the same refs lock their rows in the same
  # order. A ref live under another connection of the adapter is left as it is. A
  # collection made here is linked to the organisation's only workspace, when it has one
  # (`only_workspace/1`), with the feed's `linked` entry. The ids of the collections made
  # or updated.
  defp put_collections(_connection, [], _started_at, _now), do: []

  defp put_collections(%Connection{} = connection, collections, started_at, now) do
    workspace_id = only_workspace(connection.organisation_id)

    rows =
      for collection <- Enum.sort_by(collections, & &1.ref) do
        %{
          id: Ecto.UUID.generate(),
          public_id: PublicId.generate(Collection.prefix()),
          organisation_id: connection.organisation_id,
          adapter_id: connection.adapter_id,
          connection_id: connection.id,
          workspace_id: workspace_id,
          external_ref: collection.ref,
          url: collection.url,
          title: collection.title,
          target_system: collection.target && collection.target.system,
          target_path: collection.target && collection.target.path,
          last_listed_at: started_at,
          inserted_at: now,
          updated_at: now
        }
      end

    made = MapSet.new(rows, & &1.id)

    newer =
      from c in Collection,
        where: c.connection_id == fragment("EXCLUDED.connection_id"),
        where: c.last_listed_at <= fragment("EXCLUDED.last_listed_at"),
        update: [
          set: [
            url: fragment("EXCLUDED.url"),
            title: fragment("EXCLUDED.title"),
            target_system: fragment("EXCLUDED.target_system"),
            target_path: fragment("EXCLUDED.target_path"),
            last_listed_at: fragment("EXCLUDED.last_listed_at"),
            updated_at: fragment("EXCLUDED.updated_at")
          ]
        ]

    {_count, put} =
      Repo.insert_all(Collection, rows,
        on_conflict: newer,
        conflict_target: {:unsafe_fragment, @live_index},
        returning: [:id, :adapter_id, :external_ref, :workspace_id]
      )

    # The update of one live already leaves its link as it was: only one made here is
    # linked by it.
    :ok = tell(Enum.filter(put, &(&1.workspace_id && MapSet.member?(made, &1.id))), "linked")
    Enum.map(put, & &1.id)
  end

  # The id of the organisation's only workspace not marked for deletion, held `FOR SHARE`
  # so that it is not marked before the transaction ends; nil while it has none, or two or
  # more.
  defp only_workspace(organisation_id) do
    case Repo.all(
           from w in Workspace,
             where: w.organisation_id == ^organisation_id and is_nil(w.deletion_marked_at),
             select: w.id,
             limit: 2
         ) do
      [id] -> lock_workspace(organisation_id, id)
      _none_or_more -> nil
    end
  end

  # The workspace `id` of the organisation `organisation_id`, held `FOR SHARE`, while it is
  # not marked for deletion nor claimed by a purge: its id; nil otherwise. A marking or a
  # purge's claim of it waits for the transaction that holds it.
  defp lock_workspace(organisation_id, id) do
    Repo.one(
      from w in Workspace,
        where: w.id == ^id and w.organisation_id == ^organisation_id,
        where: is_nil(w.deletion_marked_at) and is_nil(w.purge_started_at),
        select: w.id,
        lock: "FOR SHARE"
    )
  end

  # Once every part from 1 to the last has arrived, and only the first time: ends every
  # live collection of `connection` that the listing did not name, and that no newer
  # listing named (`last_listed_at` before the listing's `started_at`), and marks the
  # connection's listing complete (`listing_completed_at`). `{ended_ids, completed?}`.
  defp complete(%Connection{} = connection, listing, now) do
    if is_nil(listing.completed_at) and is_integer(listing.last_part) and
         length(listing.parts) == listing.last_part do
      {_count, ended} =
        Repo.update_all(
          from(c in Collection,
            where: c.connection_id == ^connection.id and is_nil(c.ended_at),
            where: c.last_listed_at < ^listing.started_at,
            select: c
          ),
          set: [ended_at: now, ended_reason: :not_listed, updated_at: now]
        )

      {1, _} =
        Repo.update_all(
          from(l in @listings, where: l.id == type(^listing.id, :binary_id)),
          set: [completed_at: now]
        )

      {1, _} =
        Repo.update_all(
          from(c in Connection, where: c.id == ^connection.id),
          set: [listing_completed_at: now, updated_at: now]
        )

      :ok = tell_unlinked(ended)
      {Enum.map(ended, & &1.id), true}
    else
      {[], false}
    end
  end

  @doc false
  # disconnect/2 ends the live collection of the key's adapter named by `collection_ref`
  # (`Apiary.Adapters.Wire.source_disconnect/1`), for the adapter's key of `key_scope`
  # (`adapter.disconnect`), as `POST /v1/sources/disconnect` asks, with the feed's
  # `unlinked` entry when it is linked to a workspace. In this order: `{:error,
  # :forbidden}` for a request outside the key's rights, decided before any collection is
  # looked up; `{:ok, :unchanged}` for a ref with no live collection, which changes
  # nothing and writes no entry (never seen, disconnected already, left out by a complete
  # listing, ended with its connection); `{:error, :suspended}` for a live collection
  # whose organisation is out of use, which changes nothing; `{:ok, :disconnected}`.
  @spec disconnect(Scope.t() | nil, Wire.source_disconnect()) ::
          {:ok, :disconnected | :unchanged} | {:error, :forbidden | :suspended}
  def disconnect(key_scope, %{collection_ref: ref}) do
    with {:ok, adapter_id} <- Connections.key_rights(key_scope, @disconnect_action) do
      Repo.transact(fn ->
        case lock_live(adapter_id, ref) do
          nil ->
            {:ok, :unchanged}

          %Collection{} = collection ->
            with {:ok, _scope} <-
                   Connections.in_use(key_scope, collection.connection, @disconnect_action) do
              now = DateTime.utc_now()

              {1, ended} =
                Repo.update_all(
                  from(c in Collection, where: c.id == ^collection.id, select: c),
                  set: [ended_at: now, ended_reason: :disconnected, updated_at: now]
                )

              :ok = tell_unlinked(ended)
              {:ok, :disconnected}
            end
        end
      end)
    end
  end

  defp lock_live(adapter_id, ref) do
    Repo.one(
      from c in Collection,
        where: c.adapter_id == ^adapter_id and c.external_ref == ^ref and is_nil(c.ended_at),
        lock: "FOR UPDATE",
        preload: [connection: :organisation]
    )
  end

  @doc false
  # resolve/3 is the collection of the key's adapter that answers a request naming
  # `collection_ref`, as items do (`source_item.post`, `action`): the live collection with
  # that ref, or, when none is live, the one with that ref that ended last (`lookup/2`);
  # then `verdict/3` of it. Never `connection_unknown`: a ref names no connection.
  @spec resolve(Scope.t() | nil, term, Access.action()) ::
          {:ok, Collection.t(), Scope.t()} | {:error, refusal}
  def resolve(key_scope, collection_ref, action) do
    with {:ok, adapter_id} <- Connections.key_rights(key_scope, action) do
      judge(key_scope, lookup(adapter_id, collection_ref), action)
    end
  end

  @doc false
  # verdict/3 answers a request of the key of `key_scope` for `action` that `collection`
  # answers (its connection and organisation preloaded, or loaded here), as for comments,
  # whose collection is their item's: the live one, or the one that ended last; `nil` for
  # none. In the contract's order:
  #
  #   * `{:error, :forbidden}` for a request outside the key's rights
  #     (`Apiary.Adapters.Connections.key_rights/2`), whatever the collection;
  #   * `{:error, :ended}` (`connection_ended`) for a collection that ended with its
  #     connection;
  #   * `{:error, :suspended}` (`connection_suspended`) for a live collection whose
  #     organisation is out of use;
  #   * `{:error, :not_linked}` (`collection_not_linked`) for none, a collection of
  #     another adapter, one ended otherwise, and a live one linked to no workspace;
  #   * `{:ok, collection, scope}`, a live collection linked to a workspace, and the key's
  #     scope narrowed to its organisation.
  @spec verdict(Scope.t() | nil, Collection.t() | nil, Access.action()) ::
          {:ok, Collection.t(), Scope.t()} | {:error, refusal}
  def verdict(key_scope, collection, action) do
    with {:ok, adapter_id} <- Connections.key_rights(key_scope, action) do
      case collection do
        %Collection{adapter_id: ^adapter_id} -> judge(key_scope, collection, action)
        _other -> judge(key_scope, nil, action)
      end
    end
  end

  defp judge(_key_scope, nil, _action), do: {:error, :not_linked}

  defp judge(_key_scope, %Collection{ended_at: %DateTime{}} = collection, _action) do
    if collection.ended_reason == :connection_ended,
      do: {:error, :ended},
      else: {:error, :not_linked}
  end

  defp judge(key_scope, %Collection{} = collection, action) do
    collection = Repo.preload(collection, connection: :organisation)

    with {:ok, scope} <- Connections.in_use(key_scope, collection.connection, action) do
      if collection.workspace_id,
        do: {:ok, collection, scope},
        else: {:error, :not_linked}
    end
  end

  @doc false
  # lookup/2 is the collection of the adapter `adapter_id` with the ref `collection_ref`:
  # the live one, or, when none is live, the one that ended last, with its connection and
  # organisation; `nil` for none.
  @spec lookup(Ecto.UUID.t(), term) :: Collection.t() | nil
  def lookup(adapter_id, collection_ref) when is_binary(collection_ref) do
    Repo.one(
      from c in Collection,
        where: c.adapter_id == ^adapter_id and c.external_ref == ^collection_ref,
        order_by: [desc_nulls_first: c.ended_at, desc: c.inserted_at, desc: c.id],
        limit: 1,
        preload: [connection: :organisation]
    )
  end

  def lookup(_adapter_id, _collection_ref), do: nil

  ## Ends

  @doc false
  # Inside the transaction of a connection's end, under the connection's row
  # (`Apiary.Adapters.Connections`): ends every live collection of the connections
  # `connection_ids` (`connection_ended`), with the feed's `unlinked` entry for each linked
  # to a workspace. The number ended.
  @spec end_for_connections([Ecto.UUID.t()], DateTime.t()) :: non_neg_integer
  def end_for_connections([], _now), do: 0

  def end_for_connections(connection_ids, %DateTime{} = now) when is_list(connection_ids) do
    {count, ended} =
      Repo.update_all(
        from(c in Collection,
          where: c.connection_id in ^connection_ids and is_nil(c.ended_at),
          select: c
        ),
        set: [ended_at: now, ended_reason: :connection_ended, updated_at: now]
      )

    :ok = tell_unlinked(ended)
    count
  end

  @doc false
  # Before a workspace's purge deletes its rows (`Apiary.Deletion`): links every
  # collection linked to the workspace `workspace_id` of the organisation
  # `organisation_id` to none, with the feed's `unlinked` entry for each live one. The
  # number unlinked. Run again, it unlinks nothing more.
  @spec unlink_workspace(Ecto.UUID.t(), Ecto.UUID.t()) :: non_neg_integer
  def unlink_workspace(organisation_id, workspace_id) do
    {:ok, count} =
      Repo.transact(fn ->
        # Held by id first, as an assign holds them, so the two never wait on each other
        # in turn.
        ids =
          Repo.all(
            from c in Collection,
              where: c.organisation_id == ^organisation_id and c.workspace_id == ^workspace_id,
              order_by: c.id,
              select: c.id,
              lock: "FOR UPDATE"
          )

        {count, unlinked} =
          Repo.update_all(
            from(c in Collection,
              where: c.id in ^ids and c.workspace_id == ^workspace_id,
              select: c
            ),
            set: [workspace_id: nil, updated_at: DateTime.utc_now()]
          )

        :ok =
          for(
            %Collection{ended_at: nil} = live <- unlinked,
            do: %{live | workspace_id: workspace_id}
          )
          |> tell_unlinked()

        {:ok, count}
      end)

    count
  end

  # The feed's `unlinked` entry for each of `collections`, as they were before they ended
  # or lost their workspace, that was linked to a workspace.
  defp tell_unlinked(collections),
    do: tell(Enum.filter(collections, & &1.workspace_id), "unlinked")

  # The feed's entry of `status`, `"linked"` or `"unlinked"`, for each of `collections`:
  # by adapter, then by ref.
  defp tell(collections, status) do
    collections
    |> Enum.sort_by(&{&1.adapter_id, &1.external_ref})
    |> Enum.chunk_by(& &1.adapter_id)
    |> Enum.each(fn [%Collection{adapter_id: adapter_id} | _] = told ->
      adapter = Repo.get!(Node, adapter_id)

      for %Collection{external_ref: ref} <- told do
        {:ok, _seq} =
          Feed.append(adapter, %{kind: "collection", collection_ref: ref, status: status})
      end
    end)
  end

  @doc false
  # Deletes the bookkeeping of listings whose first part arrived more than a day before
  # `now`. The number deleted. Run twice, the second run deletes nothing more.
  @spec purge_listings(DateTime.t()) :: non_neg_integer
  def purge_listings(%DateTime{} = now) do
    before = DateTime.add(now, -@listing_seconds, :second)
    {count, _} = Repo.delete_all(from l in @listings, where: l.inserted_at < ^before)
    count
  end

  ## For people

  @doc false
  # list_collections/3 is a page of the collections of `connection`, of the scope's
  # organisation, to a person who may read the instance's adapters there (`adapter.read`):
  # at most `page_size/0` rows, by title, then id; `[]` to anyone else, and for a
  # connection of another organisation. `opts`:
  #
  #   * `view:` `:all` (the default): each ref the connection's listings named once, its
  #     live collection, or, when none is live, the one that ended last; `:unassigned`,
  #     the live ones linked to no workspace; `:assigned`, the live ones linked to one;
  #   * `search:` text the title holds, any case, `%`, `_` and `\` as they are, the
  #     spaces around it left out; at most 1,024 characters, a title's most, of valid
  #     UTF-8 with no NUL, else nothing matches;
  #   * `workspace:` a workspace of the organisation, or its id: those linked to it;
  #   * `after:` the public id (`sc_…`) of the last row of the page before, for the next;
  #     one that names no collection of the connection gives `[]`.
  #
  # A page of `page_size/0` rows may have more after it; a shorter one is the last.
  @spec list_collections(Scope.t(), Connection.t(), keyword) :: [row]
  def list_collections(scope, connection, opts \\ [])

  def list_collections(%Scope{} = scope, %Connection{} = connection, opts) when is_list(opts) do
    if readable?(scope, connection) do
      rows =
        connection
        |> page_query(opts)
        |> Repo.all()

      tickets = open_tickets(Enum.map(rows, & &1.id))
      Enum.map(rows, &row(&1, tickets))
    else
      []
    end
  end

  # The rows a page holds, at most `page_size/0` of them.
  @doc false
  @spec page_size() :: pos_integer
  def page_size, do: @page_size

  defp page_query(%Connection{id: connection_id} = connection, opts) do
    from(c in Collection, where: c.connection_id == ^connection_id)
    |> view(Keyword.get(opts, :view, :all), connection_id)
    |> search(Keyword.get(opts, :search))
    |> in_workspace(Keyword.get(opts, :workspace))
    |> after_row(connection, Keyword.get(opts, :after))
    |> join(:left, [c], w in assoc(c, :workspace))
    |> order_by([c], asc: c.title, asc: c.id)
    |> limit(@page_size)
    |> preload([_c, w], workspace: w)
  end

  defp view(query, :all, connection_id) do
    # Per ref, the live one first, then the one that ended last.
    shown =
      from c in Collection,
        where: c.connection_id == ^connection_id,
        distinct: c.external_ref,
        order_by: [desc_nulls_first: c.ended_at, desc: c.inserted_at, desc: c.id],
        select: c.id

    where(query, [c], c.id in subquery(shown))
  end

  defp view(query, :unassigned, _connection_id),
    do: where(query, [c], is_nil(c.ended_at) and is_nil(c.workspace_id))

  defp view(query, :assigned, _connection_id),
    do: where(query, [c], is_nil(c.ended_at) and not is_nil(c.workspace_id))

  defp view(_query, _view, _connection_id),
    do: raise(ArgumentError, "a view is :all, :unassigned or :assigned")

  # The title holds `text`, any case, its `%`, `_` and `\` as they are. Its size is bounded
  # before anything else reads it.
  defp search(query, nil), do: query

  defp search(query, text) when is_binary(text) and byte_size(text) <= @max_search * 4 do
    text = String.trim(text)

    cond do
      text == "" ->
        query

      not String.valid?(text) or String.contains?(text, <<0>>) or
          String.length(text) > @max_search ->
        where(query, false)

      true ->
        pattern = "%" <> String.replace(text, ~r/[\\%_]/, "\\\\\\0") <> "%"
        where(query, [c], ilike(c.title, ^pattern))
    end
  end

  defp search(query, _text), do: where(query, false)

  defp in_workspace(query, nil), do: query
  defp in_workspace(query, %Workspace{id: id}), do: in_workspace(query, id)

  defp in_workspace(query, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> where(query, [c], c.workspace_id == ^id)
      :error -> where(query, false)
    end
  end

  defp after_row(query, _connection, nil), do: query

  defp after_row(query, %Connection{id: connection_id}, public_id) do
    with true <- Collection.public_id?(public_id),
         {title, id} <-
           Repo.one(
             from c in Collection,
               where: c.public_id == ^public_id and c.connection_id == ^connection_id,
               select: {c.title, c.id}
           ) do
      where(
        query,
        [c],
        fragment("(?, ?) > (?, ?)", c.title, c.id, ^title, type(^id, :binary_id))
      )
    else
      _none -> where(query, false)
    end
  end

  defp row(%Collection{} = collection, tickets) do
    %{
      id: collection.id,
      public_id: collection.public_id,
      name: collection.title,
      url: collection.url,
      workspace: collection.workspace,
      added_at: collection.inserted_at,
      last_listed_at: collection.last_listed_at,
      ended_at: collection.ended_at,
      ended_reason: collection.ended_reason,
      open_tickets: Map.get(tickets, collection.id, 0)
    }
  end

  # The open tickets of each of the collections `ids`, by id; one with none is left out.
  # The tickets are not kept yet, so each has none: the count is 0 until they are.
  defp open_tickets(_ids), do: %{}

  @doc false
  # counts/2 is how many live collections `connection` reaches, to a person who may read
  # the instance's adapters in the scope's organisation (`adapter.read`): `total`, those
  # linked to no workspace (`unassigned`), and those linked to each workspace, by its id
  # (`by_workspace`, a workspace with none left out). All 0 to anyone else, and for a
  # connection of another organisation. An ended collection is counted nowhere.
  @spec counts(Scope.t(), Connection.t()) :: counts
  def counts(%Scope{} = scope, %Connection{id: connection_id} = connection) do
    by_workspace =
      if readable?(scope, connection) do
        Repo.all(
          from c in Collection,
            where: c.connection_id == ^connection_id and is_nil(c.ended_at),
            group_by: c.workspace_id,
            select: {c.workspace_id, count(c.id)}
        )
      else
        []
      end

    {unassigned, assigned} = Enum.split_with(by_workspace, &is_nil(elem(&1, 0)))

    %{
      total: by_workspace |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
      unassigned: unassigned |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
      by_workspace: Map.new(assigned)
    }
  end

  @doc false
  # count_unassigned/2 is how many live collections `connection` reaches that are linked to
  # no workspace, as `counts/2` counts them.
  @spec count_unassigned(Scope.t(), Connection.t()) :: non_neg_integer
  def count_unassigned(%Scope{} = scope, %Connection{} = connection),
    do: counts(scope, connection).unassigned

  @doc false
  # listing_complete?/1 says whether a listing of `connection` has been complete
  # (`listing_completed_at`): until then, its collections may be named by parts still to
  # come.
  @spec listing_complete?(Connection.t()) :: boolean
  def listing_complete?(%Connection{listing_completed_at: at}), do: not is_nil(at)

  # The scope's person may read the instance's adapters in the scope's organisation, and
  # `connection` is of that organisation.
  defp readable?(
         %Scope{organisation: %Organisation{id: organisation_id} = organisation} = scope,
         %Connection{organisation_id: organisation_id}
       ),
       do: Access.can?(scope, :"adapter.read", organisation)

  defp readable?(_scope, _connection), do: false

  @doc false
  # assign_collections/4 links the collections of `connection` whose ids, the ids Qory
  # Apiary gives them (`id`, never a ref), are `ids` to `workspace`, of the scope's
  # organisation, or to none for `nil` (`collection.assign`, owners and admins, asked of
  # the organisation), in one transaction. In this order:
  #
  #   * `Apiary.Access`'s refusal, before anything is read;
  #   * `{:error, :invalid}` for more than 10,000 ids;
  #   * `{:error, :not_found}` for a connection of another organisation, and for a
  #     workspace that is not the organisation's, or that is marked for deletion or
  #     claimed by its purge;
  #   * `{:error, :ended}` for a connection that ended;
  #   * `{:error, :not_found}` for an id that names no live collection of the connection:
  #     of another connection or organisation, ended, or none;
  #   * `{:ok, count}`, how many changed their link: the others are as asked already.
  #
  # It holds the connection `FOR SHARE`, so the connection does not end meanwhile, and the
  # workspace `FOR SHARE`, so it is not marked nor claimed meanwhile; then the collections,
  # by id, so two assigns never wait on each other in turn; then the adapter's feed
  # counter, last. One linked to a workspace from none writes the feed's `linked` entry,
  # one linked to none from a workspace its `unlinked` entry; one moved from a workspace
  # to another keeps its link state, and writes none. The entry of `collection.assign`,
  # the organisation's, is about the workspace, or the organisation when it unlinks, with
  # the count, the connection's public id and the workspace's id (nil when it unlinks);
  # none when nothing changed. After the commit, the collections changed are broadcast.
  @spec assign_collections(Scope.t(), Connection.t(), [Ecto.UUID.t()], Workspace.t() | nil) ::
          {:ok, non_neg_integer} | {:error, :invalid | :ended | Access.reason()}
  def assign_collections(%Scope{} = scope, %Connection{} = connection, ids, workspace)
      when is_list(ids) and (is_nil(workspace) or is_struct(workspace, Workspace)) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"collection.assign", scope.organisation),
           {:ok, ids, every_id?} <- cast_ids(ids),
           organisation_id = scope.organisation.id,
           :ok <- lock_connection(organisation_id, connection),
           {:ok, workspace_id} <- lock_target(organisation_id, workspace),
           true <- every_id? || {:error, :not_found},
           {:ok, collections} <- lock_collections(organisation_id, connection, ids) do
        changed = Enum.reject(collections, &(&1.workspace_id == workspace_id))
        :ok = relink(scope, connection, changed, workspace, workspace_id)
        {:ok, Enum.map(changed, & &1.id)}
      end
    end)
    |> case do
      {:ok, changed} ->
        :ok = broadcast_collections(connection, changed)
        {:ok, length(changed)}

      {:error, _reason} = refused ->
        refused
    end
  end

  # At most 10,000 ids (`@max_assign`): those that are UUIDs, once each and sorted, and
  # whether every one is; one that is not names no collection.
  defp cast_ids(ids) when length(ids) > @max_assign, do: {:error, :invalid}

  defp cast_ids(ids) do
    cast = Enum.map(ids, &Ecto.UUID.cast/1)
    uuids = for {:ok, id} <- cast, do: id
    {:ok, uuids |> Enum.uniq() |> Enum.sort(), length(uuids) == length(cast)}
  end

  defp lock_connection(organisation_id, %Connection{id: id}) do
    case Repo.one(
           from c in Connection,
             where: c.id == ^id and c.organisation_id == ^organisation_id,
             lock: "FOR SHARE"
         ) do
      nil -> {:error, :not_found}
      %Connection{state: :ended} -> {:error, :ended}
      %Connection{} -> :ok
    end
  end

  defp lock_target(_organisation_id, nil), do: {:ok, nil}

  defp lock_target(organisation_id, %Workspace{id: id}) do
    case lock_workspace(organisation_id, id) do
      nil -> {:error, :not_found}
      id -> {:ok, id}
    end
  end

  # The live collections of `connection` whose ids are `ids`, sorted, each held
  # `FOR UPDATE` in that order; `{:error, :not_found}` unless every one is.
  defp lock_collections(organisation_id, %Connection{id: connection_id}, ids) do
    collections =
      Repo.all(
        from c in Collection,
          where: c.id in ^ids,
          where: c.connection_id == ^connection_id and c.organisation_id == ^organisation_id,
          order_by: c.id,
          lock: "FOR UPDATE"
      )

    if length(collections) == length(ids) and Enum.all?(collections, &is_nil(&1.ended_at)),
      do: {:ok, collections},
      else: {:error, :not_found}
  end

  # Links `changed`, held, to `workspace_id`, or to none, with its entry, then the feed's
  # entries, the adapter's feed counter last.
  defp relink(_scope, _connection, [], _workspace, _workspace_id), do: :ok

  defp relink(scope, connection, changed, workspace, workspace_id) do
    now = DateTime.utc_now()
    ids = Enum.map(changed, & &1.id)

    {_count, _} =
      Repo.update_all(from(c in Collection, where: c.id in ^ids),
        set: [workspace_id: workspace_id, updated_at: now]
      )

    {:ok, _entry} =
      Audit.record(
        Repo,
        scope,
        :"collection.assign",
        workspace || scope.organisation,
        %{
          details: %{
            count: length(changed),
            connection_id: connection.public_id,
            workspace_id: workspace_id
          }
        },
        place: :organisation
      )

    if workspace_id do
      tell(Enum.filter(changed, &is_nil(&1.workspace_id)), "linked")
    else
      tell_unlinked(changed)
    end
  end

  ## Broadcasts

  @doc false
  # topic/1 is the topic of the organisation `organisation_id`'s collections and
  # connections, whose messages the module names.
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(organisation_id), do: "adapter_collections:" <> organisation_id

  @doc false
  # subscribe/1 subscribes the caller to the topic of the scope's organisation
  # (`topic/1`), for a person who may read the instance's adapters there (`adapter.read`,
  # asked of the person as they are now): `:ok`, or `Apiary.Access`'s refusal.
  @spec subscribe(Scope.t()) :: :ok | {:error, Access.reason()}
  def subscribe(%Scope{organisation: %Organisation{id: organisation_id} = organisation} = scope) do
    with :ok <- Access.authorize(scope, :"adapter.read", organisation),
         do: Phoenix.PubSub.subscribe(Apiary.PubSub, topic(organisation_id))
  end

  def subscribe(%Scope{}), do: {:error, :not_found}

  @doc false
  # subscribe/2 subscribes the caller to the topic of the organisation of `connection`,
  # one of the scope's organisation, as `subscribe/1` does; its messages name their
  # connection. `{:error, :not_found}` for a connection of another organisation.
  @spec subscribe(Scope.t(), Connection.t()) :: :ok | {:error, Access.reason()}
  def subscribe(
        %Scope{organisation: %Organisation{id: organisation_id}} = scope,
        %Connection{organisation_id: organisation_id}
      ),
      do: subscribe(scope)

  def subscribe(%Scope{}, %Connection{}), do: {:error, :not_found}

  @doc false
  # broadcast_connection/1 tells the organisation of `connection`, after the change
  # commits, that the connection changed: `{:connection_changed, %{connection_id: id,
  # adapter_id: id}}`.
  @spec broadcast_connection(%{
          id: Ecto.UUID.t(),
          organisation_id: Ecto.UUID.t(),
          adapter_id: Ecto.UUID.t()
        }) :: :ok
  def broadcast_connection(%{id: id, organisation_id: organisation_id, adapter_id: adapter_id}),
    do:
      broadcast(
        organisation_id,
        {:connection_changed, %{connection_id: id, adapter_id: adapter_id}}
      )

  # Tells the organisation of `connection` which of its collections changed, after the
  # change commits; nothing when none did.
  defp broadcast_collections(_connection, []), do: :ok

  defp broadcast_collections(%Connection{id: id, organisation_id: organisation_id}, ids),
    do:
      broadcast(
        organisation_id,
        {:collections_changed, %{connection_id: id, collection_ids: Enum.uniq(ids)}}
      )

  # The change has committed already: a message that cannot be sent is dropped, and the
  # change still answers as it went.
  defp broadcast(organisation_id, message) do
    _sent = Phoenix.PubSub.broadcast(Apiary.PubSub, topic(organisation_id), message)
    :ok
  end
end
