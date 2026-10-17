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
  # `last_listed_at` is before its `started_at` ends (`not_listed`), once. The bookkeeping
  # is deleted a day after a listing's first part (`purge_listings/1`).
  #
  # **The end of a collection** is final: by `POST /v1/sources/disconnect`
  # (`disconnect/2`), by a complete listing that leaves it out, or with its connection
  # (`end_for_connections/2`, which `Apiary.Adapters.Connections` calls in each end's
  # transaction). Each end of a collection linked to a workspace writes the feed's entry
  # `%{kind: "collection", collection_ref: ref, status: "unlinked"}`
  # (`Apiary.Adapters.Feed`), in the same transaction; a workspace's purge unlinks its
  # collections so too (`unlink_workspace/2`).
  #
  # **A ref** names a collection of the key's adapter (`resolve/3`): the live one with that
  # ref, or, when none is live, the one with that ref that ended last.
  #
  # Locks: the connection, then its collections, then the adapter's feed counter.
  #
  # Not built: the reads and the assigning for people (`list_collections/2`,
  # `count_unassigned/2`, `assign_collections/4`, `subscribe/2`) answer
  # `{:error, :not_built}`.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{Access, PublicId, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Connection, Connections, Feed, Wire}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Workspace

  @listing_action :"source_item.post"
  @disconnect_action :"adapter.disconnect"
  @live_index "(adapter_id, external_ref) WHERE ended_at IS NULL"
  @listings "source_collection_listings"
  # How long a listing's bookkeeping is kept after its first part, in seconds.
  @listing_seconds 24 * 60 * 60

  @typedoc "A collection a connection reaches, with its workspace and when it was added."
  @type row :: %{
          id: Ecto.UUID.t(),
          name: String.t(),
          workspace: Workspace.t() | nil,
          added_at: DateTime.t()
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
        :ok = put_collections(connection, collections, part.started_at, now)
        :ok = complete(connection, listing, now)
        {:ok, :accepted}
      end
    end)
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
  # the module says. A ref live under another connection of the adapter is left as it is.
  defp put_collections(_connection, [], _started_at, _now), do: :ok

  defp put_collections(%Connection{} = connection, collections, started_at, now) do
    rows =
      for collection <- collections do
        %{
          id: Ecto.UUID.generate(),
          public_id: PublicId.generate(Collection.prefix()),
          organisation_id: connection.organisation_id,
          adapter_id: connection.adapter_id,
          connection_id: connection.id,
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

    {_count, _} =
      Repo.insert_all(Collection, rows,
        on_conflict: newer,
        conflict_target: {:unsafe_fragment, @live_index}
      )

    :ok
  end

  # Once every part from 1 to the last has arrived, and only the first time: ends every
  # live collection of `connection` that the listing did not name, and that no newer
  # listing named (`last_listed_at` before the listing's `started_at`).
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

      :ok = tell_unlinked(ended)

      {1, _} =
        Repo.update_all(
          from(l in @listings, where: l.id == type(^listing.id, :binary_id)),
          set: [completed_at: now]
        )
    end

    :ok
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
        {count, unlinked} =
          Repo.update_all(
            from(c in Collection,
              where: c.organisation_id == ^organisation_id and c.workspace_id == ^workspace_id,
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
  # or lost their workspace, that was linked to a workspace: by adapter, then by ref.
  defp tell_unlinked(collections) do
    collections
    |> Enum.filter(& &1.workspace_id)
    |> Enum.sort_by(&{&1.adapter_id, &1.external_ref})
    |> Enum.chunk_by(& &1.adapter_id)
    |> Enum.each(fn [%Collection{adapter_id: adapter_id} | _] = linked ->
      adapter = Repo.get!(Node, adapter_id)

      for %Collection{external_ref: ref} <- linked do
        {:ok, _seq} =
          Feed.append(adapter, %{kind: "collection", collection_ref: ref, status: "unlinked"})
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

  @doc false
  # For tests: links `collection` to `workspace`, of the same organisation, or to none, and
  # writes no feed entry. `{:ok, collection}`.
  @spec set_workspace(Collection.t(), Workspace.t() | nil) :: {:ok, Collection.t()}
  def set_workspace(%Collection{} = collection, workspace) do
    collection
    |> Ecto.Changeset.change(workspace_id: workspace && workspace.id)
    |> Repo.update()
  end

  ## For people (not built)

  @doc false
  # The collections `connection` reaches, by name, to a person who may read the instance's
  # adapters in its organisation (`adapter.read`). Not built: `{:error, :not_built}`.
  @spec list_collections(Scope.t(), Connection.t()) :: [row] | {:error, :not_built}
  def list_collections(%Scope{}, %Connection{}), do: {:error, :not_built}

  @doc false
  # How many of the collections `connection` reaches are assigned to no workspace. Not
  # built: `{:error, :not_built}`.
  @spec count_unassigned(Scope.t(), Connection.t()) :: non_neg_integer | {:error, :not_built}
  def count_unassigned(%Scope{}, %Connection{}), do: {:error, :not_built}

  @doc false
  # Assigns the collections of `connection` whose ids are `ids` to `workspace`
  # (`collection.assign`): `{:ok, count}`, how many moved. Not built: `{:error, :not_built}`.
  @spec assign_collections(Scope.t(), Connection.t(), [Ecto.UUID.t()], Workspace.t()) ::
          {:ok, non_neg_integer} | {:error, :not_built | Access.reason()}
  def assign_collections(%Scope{}, %Connection{}, ids, %Workspace{}) when is_list(ids),
    do: {:error, :not_built}

  @doc false
  # Subscribes the caller to `connection`'s listing, a message as each part of it is
  # accepted. Not built: `{:error, :not_built}`.
  @spec subscribe(Scope.t(), Connection.t()) :: :ok | {:error, :not_built | Access.reason()}
  def subscribe(%Scope{}, %Connection{}), do: {:error, :not_built}
end
