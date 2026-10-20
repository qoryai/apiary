defmodule ApiaryWeb.WorkItemLive.Comments do
  # People's comments on the work item page's Thread (`ApiaryWeb.WorkItemLive.Show`): the
  # composer, a comment's More and its delete question, and what the page keeps for them.
  # Show calls it; it reads and writes through `Apiary.WorkItems` alone.
  #
  # Show keeps the work item it shows as `:work_item` (an `Apiary.WorkItems.WorkItem`) and
  # the reader's scope as `:current_scope`, and reads the Thread once
  # (`Apiary.WorkItems.thread/3`) and the count beside its tab
  # (`Apiary.WorkItems.count_comments/2`) whenever it hears that its work item changed
  # (`{:work_items_changed, ids}`): a comment and its deletion tell it so once they commit,
  # including those written on this page. What this module keeps:
  #
  #   * `:deleting_comment` - the public id (`cm_…`) of the comment whose delete question
  #     shows, or nil;
  #   * `:composer_key` - a number in the composer's DOM id, counted up once a comment is
  #     written, so the composer draws again empty;
  #   * `:composer_value`, `:composer_error` - a draft the server refused, and what was
  #     wrong with it (`Apiary.WorkItems.Comment.error/1`), or nil.
  #
  # The events it handles (`events/0`): `"comment"`, `"ask_delete_comment"`,
  # `"delete_comment"`; and `"cancel_question"`, which Show shares, closes the delete
  # question. A refused action has no words; the scope is read again
  # (`ApiaryWeb.UserAuth.reload_scope/1`), which sends away a reader who may no longer be
  # here.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  use ApiaryWeb, :html

  alias Apiary.Access
  alias Apiary.WorkItems
  alias Apiary.WorkItems.Comment
  alias ApiaryWeb.UserAuth
  alias ApiaryWeb.WorkItemComponents

  @events ["comment", "ask_delete_comment", "delete_comment", "cancel_question"]

  @doc false
  # events/0 is the events this module handles for Show.
  @spec events() :: [String.t()]
  def events, do: @events

  @doc false
  # mount/1 puts what this module keeps, as a page shows it first.
  @spec mount(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def mount(socket) do
    Phoenix.Component.assign(socket,
      deleting_comment: nil,
      composer_key: 0,
      composer_value: nil,
      composer_error: nil
    )
  end

  @doc false
  # handle_event/3 handles one of `events/0`: `{:noreply, socket}`.
  @spec handle_event(String.t(), map, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("comment", %{"body" => body}, socket) when is_binary(body) do
    %{current_scope: scope, work_item: work_item} = socket.assigns

    case WorkItems.comment(scope, work_item, body) do
      {:ok, _comment} ->
        {:noreply,
         Phoenix.Component.assign(socket,
           composer_key: socket.assigns.composer_key + 1,
           composer_value: nil,
           composer_error: nil
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, refused_draft(socket, body, Comment.error(changeset))}

      {:error, _refusal} ->
        {:noreply, UserAuth.reload_scope(socket)}
    end
  end

  # The question opens only on a comment of this work item, not deleted, that the reader
  # may delete; on any other, nothing happens.
  def handle_event("ask_delete_comment", %{"comment" => id}, socket) when is_binary(id) do
    %{current_scope: scope, work_item: work_item} = socket.assigns

    deletable? =
      Apiary.PublicId.valid?(Comment.prefix(), id) and
        Enum.any?(
          WorkItems.list_comments(scope, work_item),
          &(&1.public_id == id and is_nil(&1.deleted_at) and
              Access.can?(scope, :"work_item.comment_delete", &1))
        )

    if deletable?,
      do: {:noreply, Phoenix.Component.assign(socket, :deleting_comment, id)},
      else: {:noreply, socket}
  end

  def handle_event("delete_comment", %{"comment" => id}, socket) when is_binary(id) do
    socket = Phoenix.Component.assign(socket, :deleting_comment, nil)

    case WorkItems.delete_comment(socket.assigns.current_scope, id) do
      {:error, _refusal} -> {:noreply, UserAuth.reload_scope(socket)}
      _deleted -> {:noreply, socket}
    end
  end

  def handle_event("cancel_question", _params, socket),
    do: {:noreply, Phoenix.Component.assign(socket, :deleting_comment, nil)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # A blank text keeps no draft and has no words; any other refusal keeps the draft, with
  # what was wrong with it.
  defp refused_draft(socket, _body, :blank),
    do: Phoenix.Component.assign(socket, composer_value: nil, composer_error: nil)

  defp refused_draft(socket, body, error),
    do: Phoenix.Component.assign(socket, composer_value: body, composer_error: error)

  @doc false
  # can_comment?/2 is whether the reader may comment on `work_item`: whether the page
  # draws the composer.
  @spec can_comment?(Apiary.Accounts.Scope.t(), WorkItems.WorkItem.t()) :: boolean
  def can_comment?(scope, work_item), do: Access.can?(scope, :"work_item.comment", work_item)

  @doc false
  # people_ids/1 is the ids of the people the comments of `thread` name, their authors and
  # who deleted them, for the page's one look-up of people.
  @spec people_ids([map]) :: [Ecto.UUID.t()]
  def people_ids(thread) do
    for %{kind: :comment, comment: %Comment{} = comment} <- thread,
        id <- [comment.author_id, comment.deleted_by_id],
        is_binary(id),
        uniq: true,
        do: id
  end

  @doc false
  # still_asking/2 is the comment whose delete question shows, once the page read
  # `thread` again: nil when it is no longer a comment there that is not deleted.
  @spec still_asking(String.t() | nil, [map]) :: String.t() | nil
  def still_asking(nil, _thread), do: nil

  def still_asking(id, thread) do
    if Enum.any?(
         thread,
         &match?(%{kind: :comment, comment: %{public_id: ^id, deleted_at: nil}}, &1)
       ),
       do: id
  end

  @doc false
  # comment_line/1 is one comment of the Thread, an entry of `Apiary.WorkItems.thread/3`
  # (`%{kind: :comment, comment: comment}`), as `WorkItemComponents.thread_comment/1`
  # draws it: shown, asking whether to delete it (`deleting`, its public id), or deleted.
  # `person` names a person by id, nil among them, as the page names people (a former
  # member for an account that is gone, or for none); More shows where the reader may
  # delete it.
  attr :entry, :map, required: true, doc: "the Thread's entry of the comment"
  attr :scope, :any, required: true, doc: "the reader's scope"
  attr :person, :any, required: true, doc: "a function of an id, or nil, to a person"
  attr :deleting, :string, default: nil, doc: "the comment whose delete question shows"
  attr :now, :any, default: nil

  def comment_line(%{entry: %{comment: %Comment{} = comment}} = assigns) do
    assigns =
      assign(assigns,
        id: "work-item-thread-#{comment.public_id}",
        comment: %{
          public_id: comment.public_id,
          author: assigns.person.(comment.author_id),
          at: comment.inserted_at,
          body: comment.body
        },
        state: state(comment, assigns.deleting),
        can_delete:
          is_nil(comment.deleted_at) and
            Access.can?(assigns.scope, :"work_item.comment_delete", comment),
        deleted_by: comment.deleted_at && assigns.person.(comment.deleted_by_id),
        deleted_at: comment.deleted_at
      )

    ~H"""
    <WorkItemComponents.thread_comment
      id={@id}
      comment={@comment}
      state={@state}
      can_delete={@can_delete}
      deleted_by={@deleted_by}
      deleted_at={@deleted_at}
      now={@now}
    />
    """
  end

  defp state(%Comment{deleted_at: %DateTime{}}, _deleting), do: :deleted
  defp state(%Comment{public_id: id}, id), do: :asking
  defp state(%Comment{}, _deleting), do: :shown

  @doc false
  # composer/1 is the Thread's composer for the reader, where they may comment
  # (`can_comment`), with the draft the server refused and what was wrong with it, its DOM
  # id counted up once a comment is written.
  attr :can_comment, :boolean, required: true
  attr :key, :integer, required: true, doc: "`:composer_key`"
  attr :value, :string, default: nil, doc: "`:composer_value`"
  attr :error, :any, default: nil, doc: "`:composer_error`"
  attr :number, :integer, required: true, doc: "the work item's number"
  attr :workspace, :string, required: true, doc: "the workspace's name"
  attr :reader, :string, required: true, doc: "the reader's name"
  attr :item_noun, :map, default: nil

  def composer(assigns) do
    ~H"""
    <WorkItemComponents.composer
      :if={@can_comment}
      id={"work-item-composer-#{@key}"}
      number={@number}
      workspace={@workspace}
      reader={@reader}
      value={@value}
      error={@error}
      item_noun={@item_noun}
    />
    """
  end
end
