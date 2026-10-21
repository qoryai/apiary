defmodule Apiary.Adapters.Collections do
  # The collections an organisation's connection to an adapter reaches
  # (`Apiary.Adapters.Collection`, `sc_…`), as the adapter's listing names them, each
  # assigned to one workspace or to none; and the refs that name them at the server
  # contract. A collection is an engine word (docs/lingo.md).
  #
  # **The listing** (`post_listing/2`, `POST /v1/source-collections`) comes in parts, each
  # naming its connection, the listing's id, its part number, its `started_at` and whether
  # it is the last part (`complete`). Each part is taken under the connection's row held
  # `FOR UPDATE`, so one connection's parts, of any listing, are taken one at a time, and
  # never beside the end of that connection. A part records the connection's first listing
  # (`Apiary.Adapters.Connections.mark_listed/1`), then adds its number to the listing's
  # bookkeeping (`source_collection_listings`), then makes each collection it names live
  # under the connection, or updates the one live: its `url`, `title`, target, `items`
  # (false when the part says `items: false`, true when it says nothing) and
  # `environment_ref`, and `last_listed_at`, the listing's `started_at`, unless a newer
  # listing named it already; a collection a part leaves out keeps its `items`. A
  # collection named without `environment_ref` has none; one a listing leaves out keeps
  # its record and its `environment_ref` as they are, and only a complete listing ends it
  # (below). A ref live under another connection of the adapter, which no listing newer
  # than the part named there, moves to the part's connection once the part commits
  # (`move_here/5`, three rounds at most, should another connection make it live again
  # in between): that connection's collection ends as a disconnect ends it, its
  # organisation's trail gets the entry `collection.move`, and a new collection is made
  # under the part's connection, as any collection a part makes, with nothing of the
  # ended one. The end and the new collection are separate transactions: between them the
  # ref is live nowhere, and if the second is refused (the part's connection ended, or
  # its organisation is out of use, by then), the ref stays ended until a later listing
  # names it. A part that disagrees with the parts before it (another `started_at`, a
  # second last part, a part after the last) is refused and changes nothing. Once every
  # part from 1 to the last has arrived, the listing is complete: every live collection
  # of the connection whose `last_listed_at` is before its `started_at` ends
  # (`not_listed`), once, and the connection keeps the time (`listing_completed_at`, the
  # listing-complete marker). The bookkeeping is deleted a day after a listing's first
  # part (`purge_listings/1`).
  #
  # **Linked.** A collection is linked while it is assigned to a workspace, its items come
  # into that workspace's Backlog (`backlog`, on unless a person turned it off), and it
  # has items, as its adapter does (`items`, the collection's from its latest listing,
  # the adapter's from its description's source role;
  # `Apiary.Adapters.Collection.linked?/1`). The feed's `linked` entry says a live
  # collection became linked, its `unlinked` entry that it stopped being linked or ended
  # while linked; a move from one workspace to another while it stays linked writes none.
  # A part that turns a linked collection's `items` to false writes its `unlinked` entry,
  # and one that turns it back to true writes its `linked` entry, while it is assigned
  # and its Backlog is on; neither leaves an entry in the organisation's trail, and
  # neither changes `backlog`. A start of the adapter whose description changes its
  # `items` writes the same entries for each of its live collections that is assigned, has
  # its Backlog on and has items (`relink_adapter/2`), with no entry in any trail either.
  # A collection with no items, or of an adapter with none, is never linked, so its
  # assign, move, unassign or end writes no entry either.
  #
  # **Auto-assign**: while the organisation has exactly one workspace that is not marked
  # for deletion, a collection a part makes is assigned to it as it is made, with the
  # feed's `linked` entry when that links it, in the part's transaction; one the part only
  # updates keeps its workspace.
  # A collection so assigned that has a target makes that target in the workspace, in the
  # same transaction, as an assign makes it (`Apiary.Runs.Target.insert_new/3`), so the
  # target is there before its first run. With two workspaces or more, a new collection
  # is linked to none, until a person assigns it.
  #
  # **A changed target**: a part that changes the target of a collection assigned to a
  # workspace makes the new target there, in the part's transaction, as an assign makes
  # it; the old target stays, as on a move. No target is made in a workspace marked for
  # deletion.
  #
  # **Prebuilds**: a part applies the trigger of `Apiary.Environments.trigger/2` to the
  # collections it made or updated, and an assign to those it assigned or moved to a
  # workspace, in its transaction: a prebuild is queued for each live node pool of the
  # collection's workspace whose record of it is missing, was queued for another
  # `environment_ref`, or was retired after it was last queued, and a collection named
  # without one retires its records.
  #
  # **The end of a collection** is final: by `POST /v1/sources/disconnect`
  # (`disconnect/2`), by a listing of another connection of the adapter that names its
  # ref (`move_here/5`, ended as a disconnect ends it), by a complete listing that leaves
  # it out, or with its connection (`end_for_connections/2`, which
  # `Apiary.Adapters.Connections` calls in each end's transaction). Each end of a linked
  # collection writes the feed's entry `%{kind: "collection", collection_ref: ref,
  # status: "unlinked"}` (`Apiary.Adapters.Feed`), in the same transaction; a workspace's
  # purge unlinks its collections so too (`unlink_workspace/2`), and they stay with their
  # organisation.
  #
  # **A ref** names a collection of the key's adapter (`resolve/3`): the live one with that
  # ref, or, when none is live, the one with that ref that ended last. A disconnect names
  # one by its ref and its connection: only the live one with that ref under that
  # connection (`disconnect/2`).
  #
  # **For people**, each read asks `adapter.read` of the scope's organisation (members), and
  # answers nothing to anyone else, and nothing of a connection of another organisation:
  # `list_collections/3`, a connection's collections a page at a time; `counts/2` and
  # `count_unassigned/2`; `backlog_switch/2`, whether a target's items come into the
  # Backlog, to a person who may read the workspace's work items. Each row of
  # `list_collections/3` says too whether the collection's items come into the Backlog,
  # where it has a switch.
  #
  # `assign_collections/4` assigns collections to a workspace, or to none
  # (`collection.assign`, owners and admins), by the ids Qory Apiary gives them, never by
  # refs, with the feed's `linked` entry for each it links and its `unlinked` entry for
  # each it unlinks, in its transaction; a move from one workspace to another writes none.
  # `assign_collections/4` makes the target of each collection it assigns to a workspace,
  # when the collection has one, unless the workspace has it already
  # (`Apiary.Runs.Target.insert_new/3`), so the target is there before its first run; an
  # unlink, a move away or an end leaves the target as it is. `set_backlog/3` turns the
  # Backlog of a workspace's target on or off (`collection.set_backlog`, owners and
  # admins): its live collections assigned to the workspace with that target that have
  # items, as their adapters do, with the feed's `linked` or `unlinked` entry for each it
  # changes; `set_backlog/3` makes no target. `set_collection_backlog/4` turns the Backlog
  # of one collection assigned to a workspace on or off, by the id Qory Apiary gives it,
  # with or without a target (`collection.set_backlog` too), with the same feed entries;
  # it makes no target either. The two write the switch the same way
  # (`switch_backlog/2`), and each writes one entry, about what its press named: the
  # target, or the collection.
  #
  # **Broadcasts**, after the change commits, carry ids only, on the organisation's topic
  # (`topic/1`, `"adapter_collections:"` and the organisation's id), which `subscribe/1`
  # and `subscribe/2` join for a person who may read the organisation's adapters:
  #
  #   * `{:collections_changed, %{connection_id: id, collection_ids: ids}}`, the ids of the
  #     collections of the connection `id` that a listing's part made, updated or ended,
  #     that an assign linked, moved or unlinked, that a Backlog switch turned on or off,
  #     or whose link a start of their adapter changed; one message per part that changed
  #     any, and per assign, switch or start that changed any of the connection's, none
  #     for one that changed none;
  #   * `{:connection_changed, %{connection_id: id, adapter_id: id}}`, when the connection
  #     changes as its page shows it (`broadcast_connection/1`): a press of Install that
  #     takes or makes it, or that replaces it (its end), its return that connects it, its
  #     end by the adapter, by the adapter's deletion or by its organisation's purge, the
  #     first listing that names it, each listing of it that completes, and a start of its
  #     adapter that changes the source's line on access or its words for its items or its
  #     collections (`Apiary.Adapters.declare/2`), which tells each organisation with a
  #     connection to the adapter once.
  #
  # Locks, in one order for every change here, so none waits on another in turn:
  #
  #   0. the adapter's row, first, as `Apiary.Adapters.Connections` holds it before its
  #      connections: every start holds it `FOR NO KEY UPDATE` (`Apiary.Adapters.declare/2`),
  #      before the rows `relink_adapter/2` holds when it changes the adapter's `items`,
  #      and a listing's part `FOR SHARE` (`hold_adapter/1`), before its connection; no
  #      other change here holds it;
  #   1. the connections: a listing's part holds its connection `FOR UPDATE`, and no other
  #      connection; an assign and a collection's switch (`set_collection_backlog/4`) their
  #      connection `FOR SHARE`; a target's Backlog switch (`set_backlog/3`) and a
  #      workspace's unlink (`unlink_workspace/2`) the connections of the collections they
  #      change, `FOR SHARE`, by id;
  #   2. the workspaces, `FOR SHARE`, all in one statement, by id, as a marking
  #      (`Apiary.Deletion`) and a policy write hold them: the workspace an assign or a
  #      target's switch names, the one a collection's switch finds the collection in,
  #      read with no lock first, and for a listing's part the organisation's only
  #      workspace with those its collections are assigned to; an unlink holds none;
  #   3. the collections, `FOR UPDATE`: by id for an assign, a switch and an unlink, read
  #      again once held, so a collection's switch finds out there whether its collection
  #      is still in the workspace it holds; for a listing's part, the live ones of its
  #      connection that it names, by ref, then, when it completes the listing, those of
  #      its connection it ends (`complete/3`), and no collection of another connection.
  #      A part makes the others it names with an insert that leaves a ref live under
  #      another connection as it is and never locks its row (`ON CONFLICT DO NOTHING`);
  #      that insert only waits for a change writing the row to end, and it runs before
  #      the part writes the collections it holds (`put_collections/5`). A change that
  #      holds collections by id holds their connections first, so it holds none of a
  #      connection's collections while a part of that connection runs. A ref live under
  #      another connection moves after the part commits (`move_here/5`): first its
  #      collection ends in a separate transaction that holds that one row, by adapter
  #      and ref, and no connection, then the feed's counter (`end_elsewhere/3`); then a
  #      transaction that holds what a part holds makes the new one. A disconnect
  #      (`disconnect/2`) holds one row too, by adapter, connection and ref, and no
  #      connection's row, then the feed's counter;
  #   4. the targets an assign or a part makes, by workspace, then by system and path: a
  #      part makes them after every collection it writes, its ends included
  #      (`finish_part/4`);
  #   5. the work items, `FOR UPDATE`, by id, where a change holds several
  #      (`Apiary.WorkItems`): a take in holds its ticket's connection and collection
  #      `FOR SHARE` before the work item, and nothing locks a collection or a target after
  #      a work item; a work item's comment is held `FOR UPDATE` only right after its
  #      work item, as a comment's deletion holds it (`Apiary.WorkItems.Moves`);
  #   6. the workspace's counter of work item numbers (`Apiary.WorkItems.Number`), only
  #      right after the work item it numbers;
  #   7. the environment records of the collections an assign assigns or moves to a
  #      workspace, or a part makes or updates, `FOR UPDATE`, by collection and then pool,
  #      then the prebuilds their trigger queues or ends (`Apiary.Environments.trigger/2`;
  #      `Apiary.Dispatches.Slots` names the order from the records on): an assign takes
  #      them after its targets (`relink/5`), and a part after its targets, so after every
  #      collection it holds, its ends included (`finish_part/4`);
  #   8. the adapter's feed counter, last.
  #
  # A start that changes the adapter's `items` holds, after its row, the adapter's
  # connections that have not ended `FOR SHARE`, by id, then every live collection of
  # theirs `FOR UPDATE`, by id, and no workspace (`relink_adapter/2`). Every other read of
  # an adapter's `items` here takes no lock, and is safe against such a start because it
  # comes after the collection it decides for is held, so it reads the adapter as the start
  # left it, or before the start, which then waits for that collection and sees what was
  # written:
  #
  #   * an assign reads it once it holds its collections (`relink/5`);
  #   * a Backlog switch reads the target's collections and their adapters with no lock
  #     first (`target_collections/1`), then reads the adapters again once it holds the
  #     collections, and leaves out those whose adapter has no items
  #     (`lock_target_collections/3`); a collection's switch reads its adapter once it
  #     holds the collection (`lock_switchable/4`);
  #   * an end, a disconnect and a workspace's unlink read it once they hold, or have
  #     written, the collections they end or unlink (`tell_unlinked/1`);
  #   * a post of items or of comments decides on a collection once it holds it
  #     `FOR SHARE` (`verdict/3`, from `Apiary.Sources.Ingest`; its look before that lock
  #     only refuses early, and is asked again under it), so an item taken in before the
  #     start's `unlinked` entry goes on, as one taken in before a Backlog is turned off;
  #   * a listing's part does not read it so: the collections a part makes are new rows,
  #     which a start cannot hold, so the part holds the adapter `FOR SHARE` before its
  #     connection, and reads its `items` from that row;
  #   * the pages' reads (`backlog_switch/2`, the lists and counts) change nothing.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{Access, Adapters, Audit, Environments, PublicId, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Connection, Connections, Feed, Wire}
  alias Apiary.Lingo.Domain
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.Target
  alias Apiary.Sources.Item

  @listing_action :"source_item.post"
  @disconnect_action :"adapter.disconnect"
  @live_index "(adapter_id, external_ref) WHERE ended_at IS NULL"
  # How many times a listing's part moves a ref live under another connection of the
  # adapter, at most (`move_here/5`).
  @move_rounds 3
  # What a listing's part reads back of each collection it makes or updates.
  @put_fields [
    :id,
    :organisation_id,
    :adapter_id,
    :external_ref,
    :workspace_id,
    :backlog,
    :items,
    :target_system,
    :target_path,
    :environment_ref,
    :ended_at
  ]
  @listings "source_collection_listings"
  # How long a listing's bookkeeping is kept after its first part, in seconds.
  @listing_seconds 24 * 60 * 60
  # The rows a page of collections holds; the characters a search holds at most, a title's
  # most; the ids one assign takes at most.
  @page_size 50
  @max_search 1024
  @max_assign 10_000

  @typedoc """
  A live collection a connection reaches, as a page lists it: its id and public id, its
  title (`name`) and address, its workspace, when it was added and last listed, its open
  tickets, and its Backlog switch (`backlog`): `%{on: on}`, whether its items come into
  its workspace's Backlog, where it has one; nil where it has none: assigned to no
  workspace, or with no items, it or its adapter.
  """
  @type row :: %{
          id: Ecto.UUID.t(),
          public_id: String.t(),
          name: String.t(),
          url: String.t(),
          workspace: Workspace.t() | nil,
          added_at: DateTime.t(),
          last_listed_at: DateTime.t(),
          open_tickets: non_neg_integer,
          backlog: %{on: boolean} | nil
        }

  @typedoc """
  How many live collections a connection reaches: all, unassigned, by workspace id; and
  how many refs it reaches only through collections that ended (`ended`).
  """
  @type counts :: %{
          total: non_neg_integer,
          unassigned: non_neg_integer,
          by_workspace: %{Ecto.UUID.t() => pos_integer},
          ended: non_neg_integer
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
  # nothing. Once an accepted part commits, each ref it named that was live under another
  # connection of the adapter, which no listing newer than the part named there, moves to
  # the part's connection (`move_here/5`, three rounds at most; a ref that another
  # connection makes live again each time stays there): that collection ends as a
  # disconnect ends it, with the entry `collection.move` in its organisation's trail, and
  # a new collection is made under the part's connection; the answer is
  # `{:ok, :accepted}` whether or not the move's second step is refused.
  @spec post_listing(Scope.t() | nil, Wire.listing()) ::
          {:ok, :accepted} | {:error, :forbidden | :unknown | :ended | :suspended | :invalid}
  def post_listing(key_scope, %{
        connection_id: public_id,
        collections: collections,
        listing: part
      }) do
    Repo.transact(fn ->
      with {:ok, adapter, found, connection} <- hold_listed(key_scope, public_id),
           {:ok, listing} <- record_part(connection, part) do
        now = DateTime.utc_now()
        put = put_collections(connection, adapter, collections, part.started_at, now)
        {ended, completed?} = complete(connection, listing, now)
        :ok = finish_part(connection, put, ended, now)
        ids = Enum.map(put.put, & &1.id) ++ Enum.map(ended, & &1.id)
        {:ok, {connection, ids, is_nil(found.listed_at) or completed?, put.elsewhere}}
      end
    end)
    |> case do
      {:ok, {connection, collection_ids, connection_changed?, elsewhere}} ->
        :ok = broadcast_collections(connection, collection_ids)
        if connection_changed?, do: :ok = broadcast_connection(connection)
        :ok = move_here(key_scope, connection, elsewhere, part.started_at, @move_rounds)
        {:ok, :accepted}

      {:error, _reason} = refused ->
        refused
    end
  end

  # The first holds of a listing's part, and of the second step of a move
  # (`move_here/5`): the adapter of the key of `key_scope`, `FOR SHARE`
  # (`hold_adapter/1`), then its connection `public_id`, found as the module says and
  # held `FOR UPDATE` (`Apiary.Adapters.Connections.mark_listed/1`). `{:ok, adapter,
  # found, connection}`, the connection as found and as held; else the refusal, in the
  # order `post_listing/2` gives.
  defp hold_listed(key_scope, public_id) do
    with {:ok, adapter_id} <- Connections.key_rights(key_scope, @listing_action),
         adapter = hold_adapter(adapter_id),
         {:ok, found, _scope} <-
           Connections.connection_for_key(key_scope, public_id, @listing_action),
         {:ok, connection} <- Connections.mark_listed(found) do
      {:ok, adapter, found, connection}
    end
  end

  # After a listing's part commits: each collection it named whose ref was live under
  # another connection of the adapter (`elsewhere`, as the wire gave it), which the part
  # left as it was, moves to `connection`, in two steps, so that no transaction holds a
  # row out of the module's lock order:
  #
  #   1. in order of ref, in one transaction for each ref, the collection live under
  #      another connection is held and ended as a disconnect ends it
  #      (`end_elsewhere/3`), with the entry `collection.move` in its organisation's
  #      trail; once each commits, it is broadcast to that organisation;
  #   2. then, in one transaction, the refs no connection holds live any more are made
  #      under `connection` as a listing's part makes collections (`hold_listed/2`,
  #      `put_collections/5`, `finish_part/4`): new, with nothing of the ended one, so no
  #      workspace and no Backlog switch come over, and assigned to the organisation's
  #      only workspace when it has one, as any collection a part makes. Once it commits,
  #      they are broadcast.
  #
  # A ref that a listing newer than `started_at` named under the other connection, or that
  # is live under `connection` by then, stays as it is. A ref that another connection made
  # live again between the two steps is moved again, `rounds` times in all; after that it
  # stays where it is until a listing names it again. A connection that ended or whose
  # organisation is out of use by the second step makes none.
  defp move_here(_key_scope, _connection, [], _started_at, _rounds), do: :ok
  defp move_here(_key_scope, _connection, _elsewhere, _started_at, 0), do: :ok

  defp move_here(key_scope, %Connection{} = connection, elsewhere, started_at, rounds) do
    free =
      for collection <- Enum.sort_by(elsewhere, & &1.ref),
          end_elsewhere(connection, collection.ref, started_at) != :kept,
          do: collection

    Repo.transact(fn ->
      with {:ok, adapter, _found, held} <- hold_listed(key_scope, connection.public_id) do
        now = DateTime.utc_now()
        put = put_collections(held, adapter, free, started_at, now)
        :ok = finish_part(held, put, [], now)
        {:ok, {held, Enum.map(put.put, & &1.id), put.elsewhere}}
      end
    end)
    |> case do
      {:ok, {held, ids, again}} ->
        :ok = broadcast_collections(held, ids)
        move_here(key_scope, connection, again, started_at, rounds - 1)

      {:error, _reason} ->
        :ok
    end
  end

  # The first step of a move (`move_here/5`), for the ref `ref` of the adapter of
  # `connection`, in a separate transaction: the collection live with that ref is held
  # by adapter and ref, under whichever connection (`lock_live/2`), with no connection
  # held.
  # One of another connection that no listing newer than `started_at` named is ended as a
  # disconnect ends it (`end_disconnected/2`), whatever its organisation's state, and its
  # organisation's trail gets the entry `collection.move`, by the instance, about the
  # collection, with its title as it was then (`name`), its connection's public id
  # (`connection_id`) and the adapter's name (`integration`), written before the end, as a
  # Backlog switch writes its entry before its change. `:ended` once that commits, after
  # which the collection is broadcast to its organisation; `:free` for a ref no
  # connection holds live; `:kept` otherwise.
  defp end_elsewhere(%Connection{id: connection_id, adapter_id: adapter_id}, ref, started_at) do
    {:ok, outcome} =
      Repo.transact(fn ->
        case lock_live(adapter_id, ref) do
          nil ->
            {:ok, :free}

          %Collection{connection_id: ^connection_id} ->
            {:ok, :kept}

          %Collection{} = collection ->
            if DateTime.compare(collection.last_listed_at, started_at) == :gt do
              {:ok, :kept}
            else
              scope = Scope.for_instance(collection.connection.organisation)

              {:ok, _entry} =
                Audit.record(Repo, scope, :"collection.move", collection, %{
                  details: %{
                    name: collection.title,
                    connection_id: collection.connection.public_id,
                    integration: Repo.get!(Node, adapter_id).name
                  }
                })

              {:ok, {:ended, end_disconnected(collection, DateTime.utc_now())}}
            end
        end
      end)

    case outcome do
      {:ended, %Collection{} = ended} ->
        :ok =
          broadcast_collections(
            %Connection{id: ended.connection_id, organisation_id: ended.organisation_id},
            [ended.id]
          )

        :ended

      free_or_kept ->
        free_or_kept
    end
  end

  # The adapter `adapter_id`, held `FOR SHARE`, first of all a part holds, so a start that
  # changes its `items` (`relink_adapter/2`) and the part come one after the other: the
  # part reads the adapter's `items` from this row, and what it writes of each collection
  # it makes is linked or not as that start left it.
  defp hold_adapter(adapter_id),
    do: Repo.one!(from n in Node, where: n.id == ^adapter_id, lock: "FOR SHARE")

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
  # the module says. A ref live under another connection of the adapter is left as it is
  # here, and moved once the part commits (`move_here/5`). A collection made here is
  # assigned to the organisation's only workspace, when it has one (`only_workspace/1`).
  # It makes no target and writes no feed entry: `finish_part/4` does, after
  # `complete/3`. `%{put: collections, made: ids, assigned: before, workspaces: held,
  # elsewhere: named}`: the collections made or updated, each with its adapter, the ids of
  # those made, the assigned ones as they stood before the part (`assigned_before/2`),
  # with their `items`, the workspaces held, by id, and those of `collections` whose ref
  # was live under another connection, as the wire gave them.
  #
  # The only workspace is read without a lock, then held with the workspaces the named
  # collections are assigned to, in one statement, by id, so the part holds every
  # workspace in the order a marking and a policy write hold them; then it is read again
  # (`only_held/3`): one marked or claimed meanwhile, or no longer the only one, links
  # nothing, as when the organisation has none or two.
  #
  # Then the collections: the live ones of `connection` that the part names are held
  # `FOR UPDATE`, by ref (`hold_live/2`), and no other collection is held. The other refs
  # are made with an insert that does nothing where a ref is live (`ON CONFLICT DO
  # NOTHING`): a ref live under another connection, however recently it became live,
  # while it is live at the insert, is left with that connection in this transaction
  # (`elsewhere`, which `move_here/5` moves once the part commits, unless a listing newer
  # than the part named it there, three rounds at most), and its row is never
  # locked; the insert only waits for a change that is writing that row to end. The
  # collections held are updated after the insert, so while it runs they are held but not
  # yet written, and the insert of a part of another connection that meets one of them
  # does not wait on this part; once they are written, such an insert waits for this
  # part to end. Each collection is given `adapter`, which the part holds `FOR SHARE`
  # (`hold_adapter/1`), for its `items`.
  defp put_collections(_connection, _adapter, [], _started_at, _now),
    do: %{put: [], made: MapSet.new(), assigned: %{}, workspaces: %{}, elsewhere: []}

  defp put_collections(
         %Connection{} = connection,
         %Node{} = adapter,
         collections,
         started_at,
         now
       ) do
    organisation_id = connection.organisation_id
    only = only_workspace(organisation_id)
    assigned = assigned_before(connection, collections)

    workspaces =
      lock_workspaces(organisation_id, [
        only | Enum.map(Map.values(assigned), &elem(&1.listed, 0))
      ])

    workspace_id = only_held(organisation_id, only, workspaces)
    held = hold_live(connection, collections)

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
          # The wire always says (`Apiary.Adapters.Wire.listing/1`); said nothing of, a
          # collection has items.
          items: Map.get(collection, :items, true),
          environment_ref: Map.get(collection, :environment_ref),
          last_listed_at: started_at,
          inserted_at: now,
          updated_at: now
        }
      end

    {live, others} = Enum.split_with(rows, &MapSet.member?(held, &1.external_ref))

    {_count, made} =
      PublicId.Insert.insert_all(Collection, others,
        on_conflict: :nothing,
        conflict_target: {:unsafe_fragment, @live_index},
        returning: @put_fields
      )

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
            items: fragment("EXCLUDED.items"),
            environment_ref: fragment("EXCLUDED.environment_ref"),
            last_listed_at: fragment("EXCLUDED.last_listed_at"),
            updated_at: fragment("EXCLUDED.updated_at")
          ]
        ]

    # Each of `live` is held, so it is still live and conflicts only with itself.
    {_count, updated} =
      PublicId.Insert.insert_all(Collection, live,
        on_conflict: newer,
        conflict_target: {:unsafe_fragment, @live_index},
        returning: @put_fields
      )

    # Neither held nor made: live under another connection at the insert.
    made_refs = MapSet.new(made, & &1.external_ref)

    elsewhere =
      Enum.reject(
        collections,
        &(MapSet.member?(held, &1.ref) or MapSet.member?(made_refs, &1.ref))
      )

    %{
      elsewhere: elsewhere,
      put: Enum.map(made ++ updated, &%{&1 | adapter: adapter}),
      made: MapSet.new(made, & &1.id),
      assigned: assigned,
      workspaces: workspaces
    }
  end

  # After every collection write of a part, `put_collections/5`'s and `complete/3`'s, so
  # the part holds the targets and the adapter's feed counter after them all, as the
  # module's lock order says: each collection made in a workspace, and each one in a
  # workspace whose target the part changes, makes its target there
  # (`insert_listed_targets/4`); then the trigger of `Apiary.Environments.trigger/2`, at
  # `now`, for the collections made or updated; then the feed's `linked` entry for each
  # one made linked
  # and each updated one whose `items` linked it (`flipped/2`), its `unlinked` entry for
  # each updated one whose `items` unlinked it, then for each of `ended` that was linked.
  defp finish_part(%Connection{} = connection, put, ended, now) do
    %{put: collections, made: made, assigned: assigned, workspaces: workspaces} = put

    # Made here, or with another workspace or target than before the part.
    new_target? =
      &(MapSet.member?(made, &1.id) or
          assigned |> Map.get(&1.external_ref, %{}) |> Map.get(:listed) != listed(&1))

    :ok =
      insert_listed_targets(connection.organisation_id, workspaces, collections, new_target?)

    _queued = Environments.trigger(collections, now)

    {made_now, updated} = Enum.split_with(collections, &MapSet.member?(made, &1.id))
    {linked, unlinked} = flipped(updated, assigned)
    :ok = tell(Enum.filter(made_now, &Collection.linked?/1) ++ linked, "linked")
    :ok = tell(unlinked, "unlinked")

    tell_unlinked(ended)
  end

  # The refs of the live collections of `connection` that `collections` name, each held
  # `FOR UPDATE`, by ref. None of them ends before the transaction does: an end writes
  # the collection's row, which waits for that lock.
  defp hold_live(%Connection{} = connection, collections) do
    refs = Enum.map(collections, & &1.ref)

    Repo.all(
      from c in Collection,
        where: c.connection_id == ^connection.id and is_nil(c.ended_at),
        where: c.external_ref in ^refs,
        order_by: c.external_ref,
        select: c.external_ref,
        lock: "FOR UPDATE"
    )
    |> MapSet.new()
  end

  # The collections among `updated`, which a part updated, that its `items` linked, and
  # those it unlinked: an update leaves a collection's workspace and Backlog as they were,
  # so only a change of `items` changes its link, of a collection assigned before the part
  # (`assigned`, by ref).
  defp flipped(updated, assigned) do
    changes =
      for collection <- updated,
          %{items: items_before} <- [Map.get(assigned, collection.external_ref)],
          Collection.linked?(%{collection | items: items_before}) !=
            Collection.linked?(collection),
          do: collection

    Enum.split_with(changes, &Collection.linked?/1)
  end

  # The live collections of `connection` that `collections` name by ref and that are
  # assigned to a workspace, as they stand before the part: by ref, their workspace's id
  # and target (`listed`, as `listed/1` gives them) and their `items`.
  defp assigned_before(%Connection{} = connection, collections) do
    refs = Enum.map(collections, & &1.ref)

    Repo.all(
      from c in Collection,
        where: c.connection_id == ^connection.id and is_nil(c.ended_at),
        where: c.external_ref in ^refs and not is_nil(c.workspace_id),
        select:
          {c.external_ref,
           %{listed: {c.workspace_id, c.target_system, c.target_path}, items: c.items}}
    )
    |> Map.new()
  end

  defp listed(%Collection{} = collection),
    do: {collection.workspace_id, collection.target_system, collection.target_path}

  # The workspaces of the organisation `organisation_id` among `ids`, by id, each held
  # `FOR SHARE` in order of id, while it is not marked for deletion nor claimed by a purge,
  # as `lock_workspace/2` holds one.
  defp lock_workspaces(organisation_id, ids) do
    case ids |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort() do
      [] ->
        %{}

      ids ->
        Repo.all(
          from w in Workspace,
            where: w.id in ^ids and w.organisation_id == ^organisation_id,
            where: is_nil(w.deletion_marked_at) and is_nil(w.purge_started_at),
            order_by: w.id,
            lock: "FOR SHARE"
        )
        |> Map.new(&{&1.id, &1})
    end
  end

  # The targets of the collections `put` that `new_target?` picks, each in its workspace
  # among `workspaces`, as an assign makes them (`insert_targets/3`): by workspace id,
  # then by system and path.
  defp insert_listed_targets(organisation_id, workspaces, put, new_target?) do
    put
    |> Enum.filter(&(Map.has_key?(workspaces, &1.workspace_id) and new_target?.(&1)))
    |> Enum.group_by(& &1.workspace_id)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.each(fn {workspace_id, collections} ->
      :ok = insert_targets(organisation_id, Map.fetch!(workspaces, workspace_id), collections)
    end)
  end

  # The id of the organisation's only workspace not marked for deletion, read without a
  # lock; nil while it has none, or two or more.
  defp only_workspace(organisation_id) do
    case Repo.all(
           from w in Workspace,
             where: w.organisation_id == ^organisation_id and is_nil(w.deletion_marked_at),
             select: w.id,
             limit: 2
         ) do
      [id] -> id
      _none_or_more -> nil
    end
  end

  # `only`, once `lock_workspaces/2` holds it among `workspaces`, so that it is not marked
  # before the transaction ends, while it is still the organisation's only workspace not
  # marked for deletion; nil otherwise.
  defp only_held(_organisation_id, nil, _workspaces), do: nil

  defp only_held(organisation_id, only, workspaces) do
    if Map.has_key?(workspaces, only) and only_workspace(organisation_id) == only,
      do: only
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
  # connection's listing complete (`listing_completed_at`). `{ended, completed?}`, the
  # collections it ended, whose `unlinked` entries `finish_part/4` writes.
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

      {ended, true}
    else
      {[], false}
    end
  end

  @doc false
  # disconnect/2 ends the live collection of the key's adapter named by `collection_ref`
  # under the connection `connection_id`, its public id
  # (`Apiary.Adapters.Wire.source_disconnect/1`), for the adapter's key of `key_scope`
  # (`adapter.disconnect`), as `POST /v1/sources/disconnect` asks, with the feed's
  # `unlinked` entry when it is linked. It holds that one row `FOR UPDATE`, by adapter,
  # connection and ref (`lock_live/3`), and no connection's row, then the feed's counter
  # when it writes an entry. In this order: `{:error, :forbidden}` for a request outside the
  # key's rights, decided before any collection is looked up; `{:ok, :unchanged}` for a
  # ref with no live collection under that connection, which changes nothing and writes
  # no entry (never seen, disconnected already, left out by a complete listing, ended
  # with its connection, or live under another connection of the adapter, where it stays
  # live), and so for a `connection_id` that names no connection of the adapter, a
  # pending one or one that ended; `{:error, :suspended}` for a live collection under
  # that connection whose organisation is out of use, which changes nothing;
  # `{:ok, :disconnected}`. Never `:unknown` or `:ended`.
  @spec disconnect(Scope.t() | nil, Wire.source_disconnect()) ::
          {:ok, :disconnected | :unchanged} | {:error, :forbidden | :suspended}
  def disconnect(key_scope, %{connection_id: public_id, collection_ref: ref}) do
    with {:ok, adapter_id} <- Connections.key_rights(key_scope, @disconnect_action) do
      Repo.transact(fn ->
        case lock_live(adapter_id, public_id, ref) do
          nil ->
            {:ok, :unchanged}

          %Collection{} = collection ->
            with {:ok, _scope} <-
                   Connections.in_use(key_scope, collection.connection, @disconnect_action) do
              now = DateTime.utc_now()

              %Collection{} = end_disconnected(collection, now)
              {:ok, :disconnected}
            end
        end
      end)
    end
  end

  # Ends `collection`, held, as a disconnect ends one: `disconnected`, at `now`, with the
  # feed's `unlinked` entry when it was linked (`tell_unlinked/1`). The collection as it
  # was written.
  defp end_disconnected(%Collection{} = collection, now) do
    {1, [ended]} =
      Repo.update_all(
        from(c in Collection, where: c.id == ^collection.id, select: c),
        set: [ended_at: now, ended_reason: :disconnected, updated_at: now]
      )

    :ok = tell_unlinked([ended])
    ended
  end

  # The live collection of the adapter `adapter_id` with the ref `ref`, under any of its
  # connections, held `FOR UPDATE`, with its connection and organisation; `nil` for none.
  defp lock_live(adapter_id, ref) do
    Repo.one(
      from c in Collection,
        where: c.adapter_id == ^adapter_id and c.external_ref == ^ref and is_nil(c.ended_at),
        lock: "FOR UPDATE",
        preload: [connection: :organisation]
    )
  end

  # The live collection of the adapter `adapter_id` with the ref `ref` under its
  # connection `public_id`, held `FOR UPDATE`, with its connection and organisation;
  # `nil` for none. The connection is found in a subquery, which holds no lock on its
  # row, so only the collection's row is held.
  defp lock_live(adapter_id, public_id, ref) do
    connection_ids =
      from k in Connection,
        where: k.adapter_id == ^adapter_id and k.public_id == ^public_id,
        select: k.id

    Repo.one(
      from c in Collection,
        where:
          c.adapter_id == ^adapter_id and c.external_ref == ^ref and is_nil(c.ended_at) and
            c.connection_id in subquery(connection_ids),
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
  #     another adapter, one ended otherwise, and a live one not linked: assigned to no
  #     workspace, with its Backlog turned off, with no items, or of an adapter with
  #     none;
  #   * `{:ok, collection, scope}`, a live linked collection, and the key's scope narrowed
  #     to its organisation.
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
    collection = Repo.preload(collection, [:adapter, connection: :organisation])

    with {:ok, scope} <- Connections.in_use(key_scope, collection.connection, action) do
      if Collection.linked?(collection),
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

  ## A start that changes its adapter's items

  @doc false
  # relink_adapter/2, inside the transaction of a start of the adapter (`before`, as it
  # stood, and `adapter`, as the start wrote it; `Apiary.Adapters.declare/2`), which holds
  # its row `FOR NO KEY UPDATE`: when the start changed its `items`, true to false or false
  # to true, it holds the connections of the adapter that have not ended `FOR SHARE`, by
  # id, then every live collection of theirs `FOR UPDATE`, by id, and writes the feed's
  # `unlinked` entry for each that was linked, or its `linked` entry for each that now is:
  # those assigned to a workspace, with their Backlog on and with items. Its `backlog` and
  # its workspace stay as they are, and the organisation's trail gets no entry, as for a
  # listing's part that changes a collection's `items`. A work item already taken in from
  # one of them goes on, as when its Backlog is turned off. `{:ok, changed}`, the
  # collections whose link changed, for `broadcast_relinked/1` once the start commits;
  # `{:ok, []}` when `items` did not change, which holds nothing more.
  #
  # Every live collection is held, not only those it changes, so that no change of a
  # collection's link reads the adapter's `items` while the start is writing it: an
  # assign, a switch, an unlink, an end, a disconnect and a post of items or comments read
  # the adapter once they hold their collections, so they either read it before the start,
  # which then waits for them and sees what they wrote, or after it commits (the module's
  # lock order).
  @spec relink_adapter(Node.t(), Node.t()) :: {:ok, [Collection.t()]}
  def relink_adapter(%Node{kind: :adapter, id: id, items: same}, %Node{id: id, items: same}),
    do: {:ok, []}

  def relink_adapter(%Node{kind: :adapter, id: id}, %Node{kind: :adapter, id: id} = adapter) do
    connection_ids =
      Repo.all(
        from k in Connection,
          where: k.adapter_id == ^id and is_nil(k.ended_at),
          order_by: k.id,
          select: k.id,
          lock: "FOR SHARE"
      )

    held =
      Repo.all(
        from c in Collection,
          where: c.adapter_id == ^id and c.connection_id in ^connection_ids,
          where: is_nil(c.ended_at),
          order_by: c.id,
          lock: "FOR UPDATE"
      )

    # With the adapter's items, as the start wrote them, each is linked when it is
    # assigned, with its Backlog on and with items; with the others, none is.
    changed = Enum.filter(held, &Collection.linked?(%{&1 | adapter: %{adapter | items: true}}))
    :ok = tell(changed, if(adapter.items, do: "linked", else: "unlinked"))
    {:ok, changed}
  end

  @doc false
  # After a start that changed its adapter's `items` commits (`relink_adapter/2`): the
  # collections whose link it changed, broadcast by connection.
  @spec broadcast_relinked([Collection.t()]) :: :ok
  def broadcast_relinked(collections) do
    for {connection_id, of_connection} <- Enum.group_by(collections, & &1.connection_id) do
      :ok =
        broadcast_collections(
          %Connection{id: connection_id, organisation_id: hd(of_connection).organisation_id},
          Enum.map(of_connection, & &1.id)
        )
    end

    :ok
  end

  ## Ends

  @doc false
  # Inside the transaction of a connection's end, under the connection's row
  # (`Apiary.Adapters.Connections`): ends every live collection of the connections
  # `connection_ids` (`connection_ended`), with the feed's `unlinked` entry for each
  # linked. The number ended.
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
  # `organisation_id` to none, with the feed's `unlinked` entry for each live one that was
  # linked. The number unlinked. Run again, it unlinks nothing more.
  @spec unlink_workspace(Ecto.UUID.t(), Ecto.UUID.t()) :: non_neg_integer
  def unlink_workspace(organisation_id, workspace_id) do
    {:ok, count} =
      Repo.transact(fn ->
        # The connections of its collections first, `FOR SHARE`, by id, then the
        # collections, by id, as a Backlog switch holds them: a listing's part, which holds
        # its connection `FOR UPDATE` and its collections by ref, and the unlink wait for
        # each other, never on each other in turn.
        linked =
          Repo.all(
            from c in Collection,
              where: c.organisation_id == ^organisation_id and c.workspace_id == ^workspace_id,
              select: {c.id, c.connection_id}
          )

        _held = lock_connections(organisation_id, Enum.map(linked, &elem(&1, 1)))
        ids = Enum.map(linked, &elem(&1, 0))

        ids =
          Repo.all(
            from c in Collection,
              where: c.id in ^ids and c.workspace_id == ^workspace_id,
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
  # or lost their workspace, that was linked.
  defp tell_unlinked(collections),
    do:
      collections
      |> Repo.preload(:adapter)
      |> Enum.filter(&Collection.linked?/1)
      |> tell("unlinked")

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
  # list_collections/3 is a page of the live collections of `connection`, of the scope's
  # organisation, to a person who may read the instance's adapters there (`adapter.read`):
  # at most `page_size/0` rows, in the order `order:` names; `[]` to anyone else, and for
  # a connection of another organisation. `opts`:
  #
  #   * `view:` `:all` (the default), every one; `:unassigned`, those linked to no
  #     workspace; `:assigned`, those linked to one;
  #   * `search:` text the title holds, any case, `%`, `_` and `\` as they are, the
  #     spaces around it left out; at most 1,024 characters, a title's most, of valid
  #     UTF-8 with no NUL, else nothing matches;
  #   * `workspace:` a workspace of the organisation, or its id: those linked to it;
  #   * `after:` the public id (`sc_…`) of the last row of the page before, for the next;
  #     one that names no collection of the connection gives `[]`. For a collection that
  #     ended after that page was read, the next page starts past it all the same;
  #   * `order:` `:title` (the default), by title, then id; `:unassigned_first`, those
  #     linked to no workspace first, then those linked to one, each by title, then id.
  #     The page after `after:` starts past that row in the same order: its link to a
  #     workspace or none, its title, its id. Another order raises `ArgumentError`, as
  #     another view does.
  #
  # A page of `page_size/0` rows may have more after it; a shorter one is the last. Each
  # row's `backlog` is its switch, which `set_collection_backlog/4` turns (`row/0`).
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

  defp page_query(%Connection{} = connection, opts) do
    order = Keyword.get(opts, :order, :title)

    connection
    |> found_query(opts)
    |> sort(order)
    |> after_row(connection, Keyword.get(opts, :after), order)
    |> join(:left, [c], w in assoc(c, :workspace))
    |> join(:inner, [c], n in assoc(c, :adapter))
    |> limit(@page_size)
    |> preload([_c, w, n], workspace: w, adapter: n)
  end

  # The live collections of `connection` that the filters of `opts` find, `view:`,
  # `search:` and `workspace:`, unordered: what `list_collections/3` pages through and
  # `count_collections/3` counts.
  defp found_query(%Connection{id: connection_id}, opts) do
    from(c in Collection, where: c.connection_id == ^connection_id and is_nil(c.ended_at))
    |> view(Keyword.get(opts, :view, :all))
    |> search(Keyword.get(opts, :search))
    |> in_workspace(Keyword.get(opts, :workspace))
  end

  defp sort(query, :title), do: order_by(query, [c], asc: c.title, asc: c.id)

  defp sort(query, :unassigned_first),
    do:
      order_by(query, [c],
        asc: fragment("? IS NOT NULL", c.workspace_id),
        asc: c.title,
        asc: c.id
      )

  defp sort(_query, _order),
    do: raise(ArgumentError, "an order is :title or :unassigned_first")

  defp view(query, :all), do: query
  defp view(query, :unassigned), do: where(query, [c], is_nil(c.workspace_id))
  defp view(query, :assigned), do: where(query, [c], not is_nil(c.workspace_id))

  defp view(_query, _view),
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

  defp after_row(query, _connection, nil, _order), do: query

  defp after_row(query, %Connection{id: connection_id}, public_id, order) do
    with true <- Collection.public_id?(public_id),
         {assigned, title, id} <-
           Repo.one(
             from c in Collection,
               where: c.public_id == ^public_id and c.connection_id == ^connection_id,
               select: {not is_nil(c.workspace_id), c.title, c.id}
           ) do
      past(query, order, assigned, title, id)
    else
      _none -> where(query, false)
    end
  end

  # The rows past the one whose link to a workspace or none, title and id are `assigned`,
  # `title` and `id`, in `order`.
  defp past(query, :title, _assigned, title, id),
    do:
      where(query, [c], fragment("(?, ?) > (?, ?)", c.title, c.id, ^title, type(^id, :binary_id)))

  defp past(query, :unassigned_first, assigned, title, id) do
    where(
      query,
      [c],
      fragment(
        "(? IS NOT NULL, ?, ?) > (?, ?, ?)",
        c.workspace_id,
        c.title,
        c.id,
        ^assigned,
        ^title,
        type(^id, :binary_id)
      )
    )
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
      open_tickets: Map.get(tickets, collection.id, 0),
      backlog: row_backlog(collection)
    }
  end

  # The switch of a live collection assigned to a workspace, with items, as its adapter
  # (loaded) has: whether it is on. A collection with no items, or of an adapter with
  # none, has no switch: it is never linked, and its `backlog` keeps its value, unread.
  defp row_backlog(%Collection{
         ended_at: nil,
         workspace_id: workspace_id,
         items: true,
         adapter: %Node{items: true},
         backlog: on
       })
       when is_binary(workspace_id),
       do: %{on: on}

  defp row_backlog(%Collection{}), do: nil

  # The open tickets of each of the collections `ids`, by id: those open at their source
  # and not disconnected (`Apiary.Sources.Item`); one with none is left out.
  defp open_tickets([]), do: %{}

  defp open_tickets(ids) do
    Repo.all(
      from i in Item,
        where: i.collection_id in ^ids and i.state == :open and is_nil(i.disconnected_at),
        group_by: i.collection_id,
        select: {i.collection_id, count(i.id)}
    )
    |> Map.new()
  end

  @doc false
  # count_collections/3 is how many live collections of `connection` the filters of
  # `opts` find, to a person who may read the instance's adapters in the scope's
  # organisation (`adapter.read`): `view:`, `search:` and `workspace:` as
  # `list_collections/3` takes them, the rows of all its pages counted; `after:` and
  # `order:` are not read. 0 to anyone else, and for a connection of another
  # organisation.
  @spec count_collections(Scope.t(), Connection.t(), keyword) :: non_neg_integer
  def count_collections(scope, connection, opts \\ [])

  def count_collections(%Scope{} = scope, %Connection{} = connection, opts) when is_list(opts) do
    if readable?(scope, connection) do
      connection
      |> found_query(opts)
      |> where([c], is_nil(c.ended_at))
      |> Repo.aggregate(:count)
    else
      0
    end
  end

  @doc false
  # counts/2 is how many live collections `connection` reaches, to a person who may read
  # the instance's adapters in the scope's organisation (`adapter.read`): `total`, those
  # linked to no workspace (`unassigned`), and those linked to each workspace, by its id
  # (`by_workspace`, a workspace with none left out). An ended collection is counted in
  # none of these; `ended` is how many refs the connection's listings named whose
  # collections all ended. All 0 to anyone else, and for a connection of another
  # organisation.
  @spec counts(Scope.t(), Connection.t()) :: counts
  def counts(%Scope{} = scope, %Connection{id: connection_id} = connection) do
    {by_workspace, ended} =
      if readable?(scope, connection),
        do: {live_by_workspace(connection_id), ended_refs(connection_id)},
        else: {[], 0}

    {unassigned, assigned} = Enum.split_with(by_workspace, &is_nil(elem(&1, 0)))

    %{
      total: by_workspace |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
      unassigned: unassigned |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
      by_workspace: Map.new(assigned),
      ended: ended
    }
  end

  # The live collections of the connection `connection_id`, counted by workspace id, nil
  # for those linked to none.
  defp live_by_workspace(connection_id) do
    Repo.all(
      from c in Collection,
        where: c.connection_id == ^connection_id and is_nil(c.ended_at),
        group_by: c.workspace_id,
        select: {c.workspace_id, count(c.id)}
    )
  end

  # How many refs of the connection `connection_id` have an ended collection and no live
  # one.
  defp ended_refs(connection_id) do
    live =
      from c in Collection,
        where: c.connection_id == ^connection_id and is_nil(c.ended_at),
        select: c.external_ref

    Repo.one(
      from c in Collection,
        where: c.connection_id == ^connection_id and not is_nil(c.ended_at),
        where: c.external_ref not in subquery(live),
        select: count(c.external_ref, :distinct)
    )
  end

  @doc false
  # count_unassigned/2 is how many live collections `connection` reaches that are linked to
  # no workspace, as `counts/2` counts them.
  @spec count_unassigned(Scope.t(), Connection.t()) :: non_neg_integer
  def count_unassigned(%Scope{} = scope, %Connection{} = connection),
    do: counts(scope, connection).unassigned

  @doc false
  # targets?/1 says whether any live collection of `connection` has a target
  # (`target_system`); the target of an ended collection counts not. It asks no scope: its
  # caller loads `connection` under the reader's scope first.
  @spec targets?(Connection.t()) :: boolean
  def targets?(%Connection{id: connection_id}) do
    Repo.exists?(
      from c in Collection,
        where: c.connection_id == ^connection_id and is_nil(c.ended_at),
        where: not is_nil(c.target_system)
    )
  end

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
  #   * `{:error, :other_domain}` for a workspace whose domain the connection's adapter
  #     does not serve: its latest start listed `domains` without the workspace's
  #     (`Apiary.Lingo.Domain.serves?/2`). An adapter that lists none serves every
  #     domain. Only this check reads the adapter's domains: a listing, Take in and the
  #     feed never do, so a collection assigned before the adapter narrowed them stays
  #     assigned, and its tickets come in as before;
  #   * `{:error, :not_found}` for an id that names no live collection of the connection:
  #     of another connection or organisation, ended, or none;
  #   * `{:ok, count}`, how many changed their link: the others are as asked already.
  #
  # It holds the connection `FOR SHARE`, so the connection does not end meanwhile, and the
  # workspace `FOR SHARE`, so it is not marked nor claimed meanwhile; then the collections,
  # by id, so two assigns never wait on each other in turn; then the adapter's feed
  # counter, last. One with its Backlog on and with items, as its adapter has, assigned
  # to a workspace from none, writes the feed's `linked` entry, and assigned to none from
  # a workspace its `unlinked` entry; one moved from a workspace to another keeps its link
  # state, and writes none, and one with its Backlog off, or with no items, or of an
  # adapter with none, writes none either way. With a workspace, each collection
  # asked for that has a target makes that target in the workspace, as a run of it would
  # name it, unless the workspace has it already; with none, nothing is made, and no
  # target is ever removed. The entry of `collection.assign`,
  # the organisation's, is about the workspace, or the organisation when it unlinks, with
  # the count, the connection's public id and the workspace's id (nil when it unlinks);
  # none when nothing changed. After the commit, the collections changed are broadcast.
  @spec assign_collections(Scope.t(), Connection.t(), [Ecto.UUID.t()], Workspace.t() | nil) ::
          {:ok, non_neg_integer} | {:error, :invalid | :ended | :other_domain | Access.reason()}
  def assign_collections(%Scope{} = scope, %Connection{} = connection, ids, workspace)
      when is_list(ids) and (is_nil(workspace) or is_struct(workspace, Workspace)) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"collection.assign", scope.organisation),
           {:ok, ids, every_id?} <- cast_ids(ids),
           organisation_id = scope.organisation.id,
           {:ok, held} <- lock_connection(organisation_id, connection),
           {:ok, workspace_id} <- lock_target(organisation_id, workspace),
           :ok <- served(held, workspace),
           true <- every_id? || {:error, :not_found},
           {:ok, collections} <- lock_collections(organisation_id, connection, ids) do
        changed = Enum.reject(collections, &(&1.workspace_id == workspace_id))
        :ok = insert_targets(organisation_id, workspace, collections)
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

  # The connections of the organisation `organisation_id` among `ids`, each held
  # `FOR SHARE` in order of id, so none ends, and no listing's part of one runs, before
  # the transaction ends.
  defp lock_connections(organisation_id, ids) do
    case ids |> Enum.uniq() |> Enum.sort() do
      [] ->
        []

      ids ->
        Repo.all(
          from k in Connection,
            where: k.id in ^ids and k.organisation_id == ^organisation_id,
            order_by: k.id,
            lock: "FOR SHARE"
        )
    end
  end

  defp lock_connection(organisation_id, %Connection{id: id}) do
    case Repo.one(
           from c in Connection,
             where: c.id == ^id and c.organisation_id == ^organisation_id,
             lock: "FOR SHARE"
         ) do
      nil -> {:error, :not_found}
      %Connection{state: :ended} -> {:error, :ended}
      %Connection{} = held -> {:ok, held}
    end
  end

  # Whether the connection's adapter serves the workspace's domain, as its latest start
  # listed them; any adapter serves an unassign. The adapter's row is read without a lock:
  # a start that changes its domains meanwhile changes no assignment either way.
  defp served(_connection, nil), do: :ok

  defp served(%Connection{adapter_id: adapter_id}, %Workspace{} = workspace) do
    domains = Repo.one(from n in Node, where: n.id == ^adapter_id, select: n.domains)
    if Domain.serves?(domains, workspace), do: :ok, else: {:error, :other_domain}
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

  # The targets of `collections` in `workspace`, as a dispatched run of each would name
  # it: its labels carry the collection's system and path under the labels that name a
  # target by the workspace's domain, and the domain reads them as the projector does
  # (`Apiary.Lingo.Domain.target/2`), so the run lands on the target made here. A
  # collection without a target, or with one no label could name, makes none.
  defp insert_targets(_organisation_id, nil, _collections), do: :ok

  defp insert_targets(organisation_id, %Workspace{id: workspace_id} = workspace, collections) do
    targets =
      for collection <- collections,
          {:ok, target} <- [collection_target(workspace, collection)],
          do: target

    Target.insert_new(organisation_id, workspace_id, targets)
  end

  defp collection_target(workspace, %Collection{target_system: system, target_path: path})
       when is_binary(system) and is_binary(path) do
    labels = workspace |> Domain.target_labels() |> Enum.zip([system, path]) |> Map.new()
    Domain.target(workspace, labels)
  end

  defp collection_target(_workspace, _collection), do: :none

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
      _queued =
        changed
        |> Enum.map(&%{&1 | workspace_id: workspace_id, updated_at: now})
        |> Environments.trigger(now)

      changed
      |> Repo.preload(:adapter)
      |> Enum.filter(
        &(is_nil(&1.workspace_id) and Collection.linked?(%{&1 | workspace_id: workspace_id}))
      )
      |> tell("linked")
    else
      tell_unlinked(changed)
    end
  end

  ## The Backlog of a target

  @doc false
  # backlog_switch/2 is whether the items of `target`, a target of the scope's workspace,
  # come into the workspace's Backlog, to a person who may read its work items
  # (`work_item.read`): `%{on: on, item_noun: noun}`, on while any of its collections
  # there has its Backlog on, and `noun` what their adapters call their items
  # (`Apiary.Adapters.shared_item_noun/1`); nil for anyone else, and for a target with no
  # collection there (none live, of a connected connection, assigned to the workspace,
  # with the target's system and path, that has items and whose adapter has items). A
  # collection with no items, or of an adapter with none, has no switch: it is never
  # linked, and its `backlog` keeps its value, unread.
  @spec backlog_switch(Scope.t(), Target.t()) ::
          %{on: boolean, item_noun: %{one: String.t(), other: String.t()} | nil} | nil
  def backlog_switch(%Scope{} = scope, %Target{} = target) do
    with true <- readable_target?(scope, target),
         [_ | _] = found <-
           Repo.all(select(target_collections(target), [c, _k, n], {c.backlog, n})) do
      %{
        on: Enum.any?(found, &elem(&1, 0)),
        item_noun: found |> Enum.map(&elem(&1, 1)) |> Adapters.shared_item_noun()
      }
    else
      _none -> nil
    end
  end

  @doc false
  # set_backlog/3 turns the Backlog of `target`, a target of the scope's workspace, on or
  # off (`on`), for each of its collections there (`backlog_switch/2`), in one
  # transaction (`collection.set_backlog`, owners and admins, asked of the organisation):
  #
  #   * `Apiary.Access`'s refusal, before anything is read;
  #   * `{:error, :not_found}` for a target of another workspace than the scope's, for a
  #     workspace marked for deletion or claimed by its purge, and for a target with no
  #     collection there, those with no items, or of an adapter with none, left out:
  #     those it never changes;
  #   * `{:ok, count}`, how many changed: the others are as asked already.
  #
  # It holds the connections of the collections `FOR SHARE`, by id, then the workspace
  # `FOR SHARE`, then the collections, by id, read again once held, as an assign holds
  # them, then the adapter's feed counter, last: a listing's part, which holds its
  # connection `FOR UPDATE` and its collections by ref, and the switch wait for each
  # other, never on each other in turn. Each one it turns on writes the feed's
  # `linked` entry, each it turns off its `unlinked` entry: all are assigned to the
  # workspace. The entry of `collection.set_backlog` is about the target, with `backlog`,
  # the new state, and the count; none when nothing changed. After the commit, the
  # collections changed are broadcast, by connection.
  @spec set_backlog(Scope.t(), Target.t(), boolean) ::
          {:ok, non_neg_integer} | {:error, Access.reason()}
  def set_backlog(%Scope{} = scope, %Target{} = target, on) when is_boolean(on) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"collection.set_backlog", scope.organisation),
           true <- same_workspace?(scope, target) || {:error, :not_found},
           [_ | _] = found <-
             Repo.all(select(target_collections(target), [c], {c.id, c.connection_id})),
           connections = lock_connections(scope.organisation.id, Enum.map(found, &elem(&1, 1))),
           workspace_id when is_binary(workspace_id) <-
             lock_workspace(scope.organisation.id, target.workspace_id) || {:error, :not_found},
           [_ | _] = collections <- lock_target_collections(target, found, connections) do
        changed = Enum.reject(collections, &(&1.backlog == on))

        if changed != [] do
          {:ok, _entry} =
            Audit.record(Repo, scope, :"collection.set_backlog", target, %{
              details: %{backlog: on, count: length(changed)}
            })

          :ok = switch_backlog(changed, on)
        end

        {:ok, changed}
      else
        [] -> {:error, :not_found}
        {:error, _reason} = refused -> refused
      end
    end)
    |> case do
      {:ok, changed} ->
        for {connection_id, of_connection} <- Enum.group_by(changed, & &1.connection_id) do
          broadcast_collections(
            %Connection{id: connection_id, organisation_id: target.organisation_id},
            Enum.map(of_connection, & &1.id)
          )
        end

        {:ok, length(changed)}

      {:error, _reason} = refused ->
        refused
    end
  end

  defp readable_target?(%Scope{workspace: %Workspace{} = workspace} = scope, target),
    do: same_workspace?(scope, target) and Access.can?(scope, :"work_item.read", workspace)

  defp readable_target?(_scope, _target), do: false

  defp same_workspace?(
         %Scope{
           organisation: %Organisation{id: organisation_id},
           workspace: %Workspace{id: workspace_id}
         },
         %Target{organisation_id: organisation_id, workspace_id: workspace_id}
       ),
       do: true

  defp same_workspace?(_scope, _target), do: false

  # The live collections of a connected connection, assigned to the workspace of `target`,
  # whose target is the target's system and path, that have items, as their adapters do,
  # by id. Every domain names a target by the system and path its labels carry, as they
  # are, so a collection's are its target's.
  defp target_collections(%Target{} = target) do
    from c in Collection,
      join: k in Connection,
      on: k.id == c.connection_id and k.organisation_id == c.organisation_id,
      join: n in Node,
      on: n.id == c.adapter_id,
      where:
        c.organisation_id == ^target.organisation_id and
          c.workspace_id == ^target.workspace_id and c.target_system == ^target.system and
          c.target_path == ^target.path and is_nil(c.ended_at) and k.state == :connected and
          is_nil(k.ended_at) and c.items and n.items,
      order_by: c.id
  end

  # The collections `found` of `target_collections/1`, `{id, connection_id}`, of the
  # `connections` held, each held `FOR UPDATE`, by id, and read again once held, so one
  # that ended, moved, changed its target, lost its items, or whose connection ended
  # meanwhile is left out; then, in the next statement, their adapters, so one whose
  # adapter lost its items meanwhile is left out too. That read takes no lock, and needs
  # none: a start that changes an adapter's `items` holds every live collection of the
  # adapter `FOR UPDATE` before it commits (`relink_adapter/2`), so while these are held
  # it has either committed, and this statement, which begins after the lock, reads its
  # `items`, or it commits after this transaction, and its entries follow the switch's.
  # The adapter is never held here: a start holds it before the collections, and the
  # switch, which holds the collections first, would wait on it in turn.
  defp lock_target_collections(%Target{} = target, found, connections) do
    connected =
      for %Connection{state: :connected, ended_at: nil, id: id} <- connections,
          into: MapSet.new(),
          do: id

    ids = for {id, connection_id} <- found, MapSet.member?(connected, connection_id), do: id

    held =
      Repo.all(
        from c in Collection,
          where: c.id in ^ids,
          where: c.workspace_id == ^target.workspace_id and is_nil(c.ended_at) and c.items,
          where: c.target_system == ^target.system and c.target_path == ^target.path,
          order_by: c.id,
          lock: "FOR UPDATE"
      )

    with_items =
      Repo.all(
        from n in Node,
          where: n.id in ^Enum.uniq(Enum.map(held, & &1.adapter_id)) and n.items,
          select: n.id
      )
      |> MapSet.new()

    Enum.filter(held, &MapSet.member?(with_items, &1.adapter_id))
  end

  # Turns `changed`, held, assigned to a workspace and with items, as their adapters
  # have, on or off, then writes the feed's entries, the adapter's feed counter last: each
  # such change flips whether the collection is linked. The caller writes its entry
  # first, once, about what the press named: the target, or the collection.
  defp switch_backlog(changed, on) do
    ids = Enum.map(changed, & &1.id)

    {_count, _} =
      Repo.update_all(from(c in Collection, where: c.id in ^ids),
        set: [backlog: on, updated_at: DateTime.utc_now()]
      )

    if on,
      do: tell(changed, "linked"),
      else: tell(changed, "unlinked")
  end

  ## The Backlog of a collection

  @doc false
  # set_collection_backlog/4 turns the Backlog of one collection of `connection` on or off
  # (`on`), whatever its target, and with none: the collection whose id, the id Qory
  # Apiary gives it (`id`, never a ref), is `collection_id`, in one transaction
  # (`collection.set_backlog`, owners and admins, asked of the organisation, as an assign
  # is). In this order:
  #
  #   * `Apiary.Access`'s refusal, before anything is read;
  #   * `{:error, :not_found}` for an id that is not a UUID, and for a connection of
  #     another organisation;
  #   * `{:error, :ended}` for a connection that ended;
  #   * `{:error, :not_found}` for an id that names no live collection of the connection
  #     assigned to a workspace: of another connection or organisation, ended, assigned
  #     to none, or in a workspace marked for deletion or claimed by its purge; and for a
  #     collection with no items, or of an adapter with none, which has no switch
  #     (`row/0`'s `backlog`);
  #   * `{:ok, 1}` once it changed; `{:ok, 0}` for one as asked already, which writes
  #     nothing.
  #
  # It holds the connection `FOR SHARE`, then the workspace the collection is in, read
  # with no lock first, `FOR SHARE`, then the collection `FOR UPDATE`, read again once
  # held, then reads its adapter, then the adapter's feed counter, last, as an assign and
  # `set_backlog/3` hold them. A collection that moved to another workspace in between is
  # not found. Turned on, it writes the feed's `linked` entry, turned off its `unlinked`
  # entry, as `set_backlog/3` does. The entry of `collection.set_backlog`, in the trail of
  # the collection's workspace, is about the collection, with `backlog`, the new state,
  # the count, 1, the collection's title as it is then (`name`) and the connection's
  # public id (`connection_id`), so the entry names it whatever becomes of it later. After
  # the commit, the collection is broadcast.
  @spec set_collection_backlog(Scope.t(), Connection.t(), Ecto.UUID.t(), boolean) ::
          {:ok, 0 | 1} | {:error, :ended | Access.reason()}
  def set_collection_backlog(%Scope{} = scope, %Connection{} = connection, collection_id, on)
      when is_boolean(on) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"collection.set_backlog", scope.organisation),
           {:ok, id} <- cast_id(collection_id),
           organisation_id = scope.organisation.id,
           {:ok, held} <- lock_connection(organisation_id, connection),
           workspace_id when is_binary(workspace_id) <- assigned_to(held, id),
           ^workspace_id <- lock_workspace(organisation_id, workspace_id),
           %Collection{} = collection <- lock_switchable(held, id, workspace_id) do
        if collection.backlog == on do
          {:ok, {held, []}}
        else
          {:ok, _entry} =
            Audit.record(Repo, scope, :"collection.set_backlog", collection, %{
              details: %{
                backlog: on,
                count: 1,
                name: collection.title,
                connection_id: held.public_id
              }
            })

          :ok = switch_backlog([collection], on)
          {:ok, {held, [collection.id]}}
        end
      else
        {:error, _reason} = refused -> refused
        _none -> {:error, :not_found}
      end
    end)
    |> case do
      {:ok, {held, changed}} ->
        :ok = broadcast_collections(held, changed)
        {:ok, length(changed)}

      {:error, _reason} = refused ->
        refused
    end
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  # The workspace the live collection `id` of `connection` is assigned to, read with no
  # lock; nil for none.
  defp assigned_to(%Connection{id: connection_id, organisation_id: organisation_id}, id) do
    Repo.one(
      from c in Collection,
        where: c.id == ^id and c.connection_id == ^connection_id,
        where: c.organisation_id == ^organisation_id and is_nil(c.ended_at),
        select: c.workspace_id
    )
  end

  # The collection `id` of `connection`, held `FOR UPDATE`, and read again once held:
  # live, still in the workspace `workspace_id`, with items; then, in the next statement,
  # its adapter, which must have items too, as `lock_target_collections/3` reads it, and
  # for the same reason. nil otherwise.
  defp lock_switchable(
         %Connection{id: connection_id, organisation_id: organisation_id},
         id,
         workspace_id
       ) do
    with %Collection{} = collection <-
           Repo.one(
             from c in Collection,
               where: c.id == ^id and c.connection_id == ^connection_id,
               where: c.organisation_id == ^organisation_id and is_nil(c.ended_at),
               where: c.workspace_id == ^workspace_id and c.items,
               lock: "FOR UPDATE"
           ),
         true <-
           Repo.exists?(from n in Node, where: n.id == ^collection.adapter_id and n.items) do
      collection
    else
      _none -> nil
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
