defmodule Apiary.WorkItems do
  # WorkItems holds a workspace's work items (`Apiary.WorkItems.WorkItem`): what the
  # sidebar counts, and how the pages name a work item's ticket, for now; taking in,
  # undoing, closing and the comments come with their pages.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{Access, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Connection}
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Sources.Item
  alias Apiary.WorkItems.WorkItem

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
end
