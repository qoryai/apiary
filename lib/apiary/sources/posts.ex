defmodule Apiary.Sources.Posts do
  # How a member's comment (`Apiary.Sources.Comment.member_changeset/3`) gets to its
  # source after its first post: the adapter's report that it stopped trying to post it
  # (`failed/2`, `POST /v1/work-items/changes/failed`), and a member's request to post it
  # again (`post_again/2`). The echo of a posted comment, which sets its ref, is
  # `Apiary.Sources.Ingest`'s.
  #
  # **The report** (`changes-failed.schema.json`) first checks that the key has
  # `source_item.post`, from the key and the action alone (`:forbidden`). Then it marks
  # the comment `:not_posted`, with the report's reason, when the comment is on an item
  # of the key's adapter and its post is under way (`:posting`). Anything else is
  # accepted and changes nothing: a `comment_id` of no comment of the adapter, one kept in
  # Qory Apiary alone (`:kept`, no entry was written for it), one posted, and one already
  # marked, whose first reason stays. So a report sent again, or late, is never an error.
  #
  # **A post again** checks `work_item.take_in` in the scope's workspace, then finds the
  # comment on a ticket of a collection of that workspace (`:not_found` otherwise), and
  # takes only one marked `:not_posted` (`:not_failed` otherwise). It writes a new
  # `comment` entry to the adapter's feed, with the same `comment_id`, and sets the comment
  # `:posting`, its reason cleared, in one transaction. Where the adapter's latest
  # description no longer sets `comments: true` on its source, it writes no entry and
  # sets the comment `:kept`, as a take in does for such a source.
  #
  # **Locks.** A post again takes the adapter's feed counter (`Apiary.Adapters.Feed`)
  # before the comment's row: it reads the comment first, unlocked, writes the entry, then
  # updates the comment only while it is still `:not_posted`, and rolls back otherwise. A
  # take in locks the counter and then the ticket's record (`FOR KEY SHARE`), and a post
  # of comments locks the ticket's record and then its comments' rows, so no order of the
  # three waits on itself. A report updates one row alone.
  #
  # **Broadcasts.** Once a change commits, the workspace of the ticket's collection is
  # sent `{:tickets_changed, [ticket id]}` on its Backlog's topic
  # (`Apiary.Sources.Topic.topic/1`), and each work item of the ticket in that workspace
  # `{:work_items_changed, [work item id]}` on the topic of its workspace's work items
  # (`Apiary.WorkItems.topic/1`), as its Ticket tab shows the comment; a change of
  # nothing sends nothing.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Access, Repo, WorkItems}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Connections, Feed}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Sources.{Comment, Item, Topic}
  alias Apiary.WorkItems.WorkItem

  @action :"source_item.post"

  @typedoc "An adapter's report that it stopped trying to post a comment."
  @type report :: %{
          time: DateTime.t(),
          comment_id: String.t(),
          reason: :item_gone | :not_permitted | :too_long | :unreachable
        }

  @doc false
  # failed/2 keeps the report of the key of `key_scope`, as in the moduledoc:
  # `{:ok, :accepted}`, or `{:error, :forbidden}`.
  @spec failed(Scope.t() | nil, report) :: {:ok, :accepted} | {:error, :forbidden}
  def failed(key_scope, %{comment_id: comment_id, reason: reason}) do
    with {:ok, adapter_id} <- Connections.key_rights(key_scope, @action) do
      now = DateTime.utc_now()

      {_count, marked} =
        Repo.update_all(
          from(c in Comment,
            join: i in Item,
            on: i.id == c.item_id and i.organisation_id == c.organisation_id,
            where: c.comment_id == ^comment_id and i.adapter_id == ^adapter_id,
            where: c.post_state == ^:posting,
            select: c.item_id
          ),
          set: [post_state: :not_posted, post_failure: reason, updated_at: now]
        )

      tell(marked)
      {:ok, :accepted}
    end
  end

  @doc false
  # post_again/2 posts again the member's comment `comment_id`, as in the moduledoc:
  # `{:ok, comment}` once it commits, or `{:error, :not_found | :forbidden | :not_failed}`.
  @spec post_again(Scope.t(), String.t()) ::
          {:ok, Comment.t()} | {:error, :not_found | :forbidden | :not_failed}
  def post_again(%Scope{} = scope, comment_id) do
    result =
      Repo.transact(fn ->
        with {:ok, workspace} <- workspace(scope),
             :ok <- Access.authorize(scope, :"work_item.take_in", workspace),
             {:ok, found} <- find(scope, workspace, comment_id),
             :ok <- failed?(found.comment) do
          again(found)
        end
      end)

    with {:ok, comment} <- result do
      tell([comment.item_id])
      {:ok, comment}
    end
  end

  # The scope's workspace, of its organisation.
  defp workspace(%Scope{
         organisation: %Organisation{id: organisation_id},
         workspace: %Workspace{organisation_id: organisation_id} = workspace,
         user: %{id: user_id}
       })
       when is_binary(user_id),
       do: {:ok, workspace}

  defp workspace(%Scope{}), do: {:error, :not_found}

  # The member's comment `comment_id` on a ticket of a collection of `workspace`, with the
  # ticket and its adapter, unlocked.
  defp find(%Scope{}, %Workspace{id: workspace_id, organisation_id: organisation_id}, id) do
    with true <- is_binary(id),
         {%Comment{} = comment, %Item{} = item, %Node{} = adapter} <-
           Repo.one(
             from c in Comment,
               join: i in Item,
               on: i.id == c.item_id and i.organisation_id == c.organisation_id,
               join: k in Collection,
               on: k.id == i.collection_id and k.organisation_id == i.organisation_id,
               join: n in Node,
               on: n.id == i.adapter_id,
               where: c.comment_id == ^id and c.organisation_id == ^organisation_id,
               where: k.workspace_id == ^workspace_id,
               select: {c, i, n}
           ) do
      {:ok, %{comment: comment, item: item, adapter: adapter}}
    else
      _none -> {:error, :not_found}
    end
  end

  defp failed?(%Comment{post_state: :not_posted}), do: :ok
  defp failed?(%Comment{}), do: {:error, :not_failed}

  # The entry first, then the comment, while it is still marked not posted.
  defp again(%{comment: comment, item: item, adapter: %Node{comments: true} = adapter}) do
    {:ok, _seq} =
      Feed.append(adapter, %{
        kind: "comment",
        comment_id: comment.comment_id,
        ref: item.external_ref,
        author_name: comment.author_name,
        body: comment.body
      })

    set_state(comment, :posting)
  end

  defp again(%{comment: comment}), do: set_state(comment, :kept)

  defp set_state(%Comment{id: id}, state) do
    case Repo.update_all(
           from(c in Comment,
             where: c.id == ^id and c.post_state == ^:not_posted,
             select: c
           ),
           set: [post_state: state, post_failure: nil, updated_at: DateTime.utc_now()]
         ) do
      {1, [comment]} -> {:ok, comment}
      {0, []} -> {:error, :not_failed}
    end
  end

  # The workspaces of the tickets `item_ids`, each sent their ids once the change has
  # committed, and the work items of those tickets told too (`work_items/1`).
  defp tell([]), do: :ok

  defp tell(item_ids) do
    Repo.all(
      from i in Item,
        join: c in Collection,
        on: c.id == i.collection_id and c.organisation_id == i.organisation_id,
        where: i.id in ^Enum.uniq(item_ids) and not is_nil(c.workspace_id),
        select: {c.workspace_id, i.public_id}
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {workspace_id, ids} ->
      Phoenix.PubSub.broadcast(Apiary.PubSub, Topic.topic(workspace_id), {:tickets_changed, ids})
    end)

    work_items(item_ids)
  end

  @doc false
  # work_items/1 sends `{:work_items_changed, ids}` on the topic of the work items of each
  # workspace (`Apiary.WorkItems.topic/1`), with the public ids of the work items of the
  # tickets `item_ids` there: those of the ticket's adapter and ref in the workspace of
  # its collection, as a work item's Ticket tab reads its ticket. Once the change to a
  # member's comment on those tickets has committed.
  @spec work_items([Ecto.UUID.t()]) :: :ok
  def work_items([]), do: :ok

  def work_items(item_ids) do
    Repo.all(
      from i in Item,
        join: c in Collection,
        on: c.id == i.collection_id and c.organisation_id == i.organisation_id,
        join: w in WorkItem,
        on:
          w.organisation_id == i.organisation_id and w.adapter_id == i.adapter_id and
            w.external_ref == i.external_ref and w.workspace_id == c.workspace_id,
        where: i.id in ^Enum.uniq(item_ids),
        distinct: true,
        select: {w.workspace_id, w.public_id}
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {workspace_id, ids} ->
      Phoenix.PubSub.broadcast(
        Apiary.PubSub,
        WorkItems.topic(workspace_id),
        {:work_items_changed, ids}
      )
    end)
  end
end
