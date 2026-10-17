defmodule Apiary.WorkItems do
  # WorkItems holds a workspace's work items (`Apiary.WorkItems.WorkItem`): what the
  # sidebar counts, how the pages name a work item's ticket, and the close of a work
  # item; taking in, undoing, a person's close and the comments come with their pages.
  #
  # ## Closing: `close_locked/3` and `close_for_adapter/2`
  #
  # `close_locked(work_items, closer, now)` is the one close of a work item, whoever
  # closes it, inside the caller's transaction, which holds each work item `FOR UPDATE`.
  # Each one is live (`Apiary.WorkItems.State.live?/1`): exploring, the one state a member
  # may close, whatever it waits on (Confirm, the questions, a run without a result, the
  # run limit). Each moves to `:closed` (`Apiary.WorkItems.State.next/2`), with
  # `closed_at` `now` and `closed_by_id` the person who closed it, or nil when the
  # instance did, and gets its event, `:closed`, by the person, or by the instance with
  # the reason it gives in the event's data (`%{"reason" => reason}`). Its runs of the
  # queue not yet handed over end (`Apiary.Dispatches.cancel_for_close/2`); a run handed
  # over goes on to its end. Its ticket, and anything at the ticket's source, is left as
  # it is. It answers the workspaces whose queue changed, for the caller to tell once its
  # transaction commits (`Apiary.Dispatches.broadcast/1`).
  #
  # `close_for_adapter(adapter, now)` closes, as the instance (`adapter_removed`), every
  # live work item of every organisation whose ticket came through a connection to
  # `adapter`, inside the caller's transaction: the removal of the adapter
  # (`Apiary.Adapters.delete_adapter/2`). Closed, declined and undone work items are left
  # as they are.
  #
  # **The lock order.** A close takes its locks in one order: the connections first (the
  # removal ends them before it closes), then the work items `FOR UPDATE` in the order of
  # their ids, then their runs of the queue `FOR UPDATE` in the order of their ids, then
  # the dispatches of those runs, written. The slots of a node pool's instance limit that
  # the ended dispatches held are freed by a write of the dispatches that frees each one
  # once (`Apiary.Dispatches.Slots`), with no lock on the pool's row: a claim holds its
  # pool before the runs it lapses, so a close that held runs and then waited on a pool
  # could wait on a claim that waits on it.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{Access, Dispatches, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Connection}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Sources.Item
  alias Apiary.WorkItems.{State, WorkItem, WorkItemEvent}

  @typedoc """
  Who closes a work item: a person, by the id of their account, or the instance, with the
  reason it gives.
  """
  @type closer :: {:person, Ecto.UUID.t()} | {:instance, String.t()}

  @doc false
  # How many of the scope's workspace's work items wait on the scope's person: the count
  # beside the sidebar's Work items. Nothing waits on a person before the stages that ask
  # one something, so it is 0.
  @spec count_waiting_on(Scope.t()) :: non_neg_integer
  def count_waiting_on(%Scope{}), do: 0

  @doc false
  # ticket_names/2 is how the work item pages name the ticket of each of `work_items`, by
  # the work item's id: its `key` at the source, such as `"#1204"`, or nil, and the
  # `collection_title`, the title of the collection that holds it, as the Backlog draws
  # them. The ticket's ref at the source is never in it.
  #
  # A work item's ticket is the record of the work item's organisation, adapter and ref,
  # as the Backlog links them, of a collection linked to the work item's workspace. Where
  # several records share the ref, it is the live one (the record not disconnected, its
  # collection not ended, its connection connected), else the one that ended last. A work
  # item with no such record has no key, and its collection title as it was taken in.
  #
  # Only work items of the scope's workspace are named, and only when the scope's person
  # may read its work items (`work_item.read`); any other gets no entry. One query names
  # them all, whatever their number.
  @spec ticket_names(Scope.t(), [WorkItem.t()]) :: %{
          Ecto.UUID.t() => %{key: String.t() | nil, collection_title: String.t()}
        }
  def ticket_names(%Scope{} = scope, work_items) when is_list(work_items) do
    ids = for %WorkItem{id: id} when is_binary(id) <- work_items, uniq: true, do: id

    case {ids, workspace(scope)} do
      {[_ | _], {:ok, organisation_id, workspace_id}} ->
        from(w in WorkItem,
          as: :work_item,
          left_lateral_join: t in subquery(ticket()),
          on: true,
          where:
            w.id in ^ids and w.organisation_id == ^organisation_id and
              w.workspace_id == ^workspace_id,
          select: {w.id, %{key: t.key, collection_title: coalesce(t.title, w.collection_title)}}
        )
        |> Repo.all()
        |> Map.new()

      _none ->
        %{}
    end
  end

  # The ticket of the work item named `:work_item` in the query around it: the key and the
  # collection's title of its live record, else of the one that ended last.
  defp ticket do
    from i in Item,
      join: c in Collection,
      on: c.id == i.collection_id and c.organisation_id == i.organisation_id,
      join: k in Connection,
      on: k.id == c.connection_id and k.organisation_id == c.organisation_id,
      where:
        i.organisation_id == parent_as(:work_item).organisation_id and
          i.adapter_id == parent_as(:work_item).adapter_id and
          i.external_ref == parent_as(:work_item).external_ref and
          c.workspace_id == parent_as(:work_item).workspace_id,
      order_by: [
        desc:
          is_nil(i.disconnected_at) and is_nil(c.ended_at) and k.state == :connected and
            is_nil(k.ended_at),
        desc_nulls_last: fragment("LEAST(?, ?, ?)", i.disconnected_at, c.ended_at, k.ended_at),
        desc: i.inserted_at,
        desc: i.id
      ],
      limit: 1,
      select: %{key: i.key, title: c.title}
  end

  # The scope's organisation's id and its workspace's id, when the scope's person may read
  # the workspace's work items; `:error` otherwise.
  defp workspace(
         %Scope{
           organisation: %Organisation{id: organisation_id},
           workspace: %Workspace{organisation_id: organisation_id} = workspace
         } = scope
       ) do
    if Access.can?(scope, :"work_item.read", workspace),
      do: {:ok, organisation_id, workspace.id},
      else: :error
  end

  defp workspace(%Scope{}), do: :error

  @doc false
  # stable_url/1 is the address of `work_item` that Qory gives another system: the
  # instance's public URL, then `/work-items/` and the work item's public id. It names no
  # organisation and no workspace, so it stays the same when the work item moves to
  # another workspace. No route of the instance serves it yet.
  @spec stable_url(WorkItem.t()) :: String.t()
  def stable_url(%WorkItem{public_id: public_id}) when is_binary(public_id),
    do: ApiaryWeb.Endpoint.url() <> "/work-items/" <> public_id

  ## Closing

  @doc false
  # close_locked/3 closes `work_items`, each held `FOR UPDATE` by the caller's
  # transaction and read under that lock, at `now`, as `closer` (the moduledoc):
  # `{:ok, workspace_ids}`, the workspaces whose queue changed; `{:error, :not_live}`,
  # writing nothing, when one of them is not live; or `{:error, changeset}` of an event
  # the database refused, after which the caller's transaction is to roll back.
  @spec close_locked([WorkItem.t()], closer, DateTime.t()) ::
          {:ok, [Ecto.UUID.t()]} | {:error, :not_live | Ecto.Changeset.t()}
  def close_locked(work_items, closer, %DateTime{} = now) when is_list(work_items) do
    in_transaction!("close_locked/3")
    {closed_by_id, actor_kind, actor_id, data} = actor(closer)

    if Enum.all?(work_items, &(State.next(&1.state, :close) == {:ok, :closed})) do
      ids = work_items |> Enum.map(& &1.id) |> Enum.uniq() |> Enum.sort()

      {count, _rows} =
        Repo.update_all(
          from(w in WorkItem, where: w.id in ^ids and w.state == :exploring),
          set: [state: :closed, closed_at: now, closed_by_id: closed_by_id, updated_at: now]
        )

      # Each one was read live under the caller's lock, so each one closes.
      unless count == length(ids),
        do: raise(ArgumentError, "close_locked/3 closes work items the caller holds")

      with :ok <- record_closes(work_items, actor_kind, actor_id, data, now) do
        Dispatches.cancel_for_close(ids, now)
      end
    else
      {:error, :not_live}
    end
  end

  @doc false
  # close_for_adapter/2 closes, as the instance, every live work item whose ticket came
  # through a connection to `adapter`, in every organisation, inside the caller's
  # transaction (the moduledoc): `{:ok, workspace_ids}`, the workspaces whose queue
  # changed, or `close_locked/3`'s error.
  @spec close_for_adapter(Node.t(), DateTime.t()) ::
          {:ok, [Ecto.UUID.t()]} | {:error, :not_live | Ecto.Changeset.t()}
  def close_for_adapter(%Node{kind: :adapter, id: adapter_id}, %DateTime{} = now) do
    in_transaction!("close_for_adapter/2")

    connections = from c in Connection, where: c.adapter_id == ^adapter_id, select: c.id

    work_items =
      Repo.all(
        from w in WorkItem,
          where: w.connection_id in subquery(connections),
          where: w.state == :exploring,
          order_by: w.id,
          lock: "FOR UPDATE"
      )

    case work_items do
      [] -> {:ok, []}
      _some -> close_locked(work_items, {:instance, "adapter_removed"}, now)
    end
  end

  defp actor({:person, user_id}) when is_binary(user_id),
    do: {user_id, :person, user_id, %{}}

  defp actor({:instance, reason}) when is_binary(reason),
    do: {nil, :instance, nil, %{"reason" => reason}}

  # The `:closed` event of each work item, in the workspace the work item is in.
  defp record_closes(work_items, actor_kind, actor_id, data, now) do
    work_items
    |> Enum.uniq_by(& &1.id)
    |> Enum.reduce_while(:ok, fn work_item, :ok ->
      %WorkItemEvent{
        organisation_id: work_item.organisation_id,
        workspace_id: work_item.workspace_id,
        work_item_id: work_item.id
      }
      |> WorkItemEvent.changeset(%{
        kind: :closed,
        actor_kind: actor_kind,
        actor_id: actor_id,
        at: now,
        data: data
      })
      |> Repo.insert()
      |> case do
        {:ok, _event} -> {:cont, :ok}
        {:error, _changeset} = error -> {:halt, error}
      end
    end)
  end

  defp in_transaction!(what) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "Apiary.WorkItems.#{what} runs inside the caller's transaction")
  end
end
