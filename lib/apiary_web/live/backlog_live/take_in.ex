defmodule ApiaryWeb.BacklogLive.TakeIn do
  # The take in's dialog (`ApiaryWeb.BacklogComponents.take_in_dialog/1`) for the pages
  # that take a ticket in: the Backlog (`ApiaryWeb.BacklogLive.Index`) and the full ticket
  # (`ApiaryWeb.BacklogLive.Ticket`).
  #
  # **Open.** A press of Take in (`"take_in"`), or of Take in again or Take in here
  # (`"take_in_again"`), opens the dialog and starts nothing (`open/4`). The page keeps
  # the open dialog in its `:take_in` assign, nil while none is open: the ticket and all
  # its comments, read again with the page's scope, the kind of take in, the comment as
  # typed and what the take in starts, nil where it starts no run. A ticket no longer in
  # the Backlog opens nothing and is refused as `:not_found`; a person who may not take a
  # ticket in is told who may.
  #
  # **The comment** is kept as it is typed (`"take_in_change"`), by ticket, in
  # `:take_in_drafts`: Cancel, ×, Escape and a click outside the box close the dialog
  # (`"take_in_cancel"`), and the next press on the same ticket opens it with the same
  # text.
  #
  # **Confirm** (`"take_in_confirm"`, `confirm/2`) takes the dialog first, so a second
  # submit finds none and a double click takes the ticket in once. It takes the ticket in
  # with the comment (`Apiary.WorkItems.take_in/3`, `take_in_again/3`): on success the page
  # leads to the work item. A comment too long, or with a character a comment may not
  # have, opens the dialog again with the error and the text. Any other refusal is the
  # page's to say, and the text stays kept.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use Gettext, backend: ApiaryWeb.Gettext
  use ApiaryWeb, :verified_routes

  import Phoenix.Component, only: [assign: 2, assign: 3, update: 3]

  alias Apiary.{Access, Stages, WorkItems}
  alias Apiary.Sources.Backlog
  alias ApiaryWeb.{BacklogComponents, SpendDialog}

  # The most characters a comment has (`Apiary.Sources.Comment.max_member_body/0`).
  @max Apiary.Sources.Comment.max_member_body()

  # mount/1 is the page's assigns before any dialog opens.
  @spec mount(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def mount(socket), do: assign(socket, take_in: nil, take_in_drafts: %{})

  # open/4 opens the dialog of `event`, `"take_in"` or `"take_in_again"`, for the ticket
  # `id`, its focus to go back to the button `return_to` once it closes: `{:ok, socket}`,
  # or `{:refused, refusal}` for the page to say.
  @spec open(Phoenix.LiveView.Socket.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:refused, term}
  def open(socket, event, id, return_to) do
    scope = socket.assigns.current_scope

    with :ok <- may(scope),
         %{} = ticket <- Backlog.get_ticket(scope, id) do
      kind = kind(event, ticket)

      {:ok,
       assign(socket, :take_in, %{
         kind: kind,
         ticket: ticket,
         comments: Backlog.list_comments(scope, ticket),
         comment: Map.get(socket.assigns.take_in_drafts, ticket.id, ""),
         errors: [],
         return_to: if(is_binary(return_to), do: return_to),
         line:
           SpendDialog.take_in_line(
             BacklogComponents.take_in_action(kind),
             Stages.take_in_starts(scope.workspace, ticket.id),
             scope.workspace
           )
       })}
    else
      nil -> {:refused, :not_found}
      {:error, refusal} -> {:refused, refusal}
    end
  end

  defp may(scope) do
    if Access.can?(scope, :"work_item.take_in", scope.workspace),
      do: :ok,
      else: {:error, :forbidden}
  end

  # Take in again names its work item's place: here, or another workspace's (Take in
  # here), where the work item has no number here (`Apiary.Sources.Backlog`), whether or
  # not the person may read the work items there.
  defp kind("take_in", _ticket), do: :take_in
  defp kind(_again, %{work_item: %{number: nil}}), do: :here
  defp kind(_again, _ticket), do: :again

  # change/2 keeps the comment as typed, in the open dialog and for its ticket.
  @spec change(Phoenix.LiveView.Socket.t(), map) :: Phoenix.LiveView.Socket.t()
  def change(%{assigns: %{take_in: %{} = ask}} = socket, %{"comment" => comment})
      when is_binary(comment) do
    socket
    |> assign(:take_in, %{ask | comment: comment})
    |> update(:take_in_drafts, &Map.put(&1, ask.ticket.id, comment))
  end

  def change(socket, _params), do: socket

  # cancel/1 closes the dialog; the comment stays kept.
  @spec cancel(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def cancel(socket), do: assign(socket, :take_in, nil)

  # confirm/2 takes the ticket of the open dialog in with the comment `params` has:
  # `{:ok, socket, work_item}`, with the dialog closed and the comment no longer kept;
  # `{:open, socket}`, the dialog open again with the comment's error; `{:refused,
  # socket, refusal, id}` for the page to say; `:none` while no dialog is open.
  @spec confirm(Phoenix.LiveView.Socket.t(), map) ::
          {:ok, Phoenix.LiveView.Socket.t(), Apiary.WorkItems.WorkItem.t()}
          | {:open, Phoenix.LiveView.Socket.t()}
          | {:refused, Phoenix.LiveView.Socket.t(), term, String.t()}
          | :none
  def confirm(%{assigns: %{take_in: %{} = ask}} = socket, params) do
    scope = socket.assigns.current_scope
    comment = if is_binary(params["comment"]), do: params["comment"], else: ask.comment
    socket = socket |> assign(:take_in, nil) |> keep(ask.ticket.id, comment)
    attrs = %{comment: comment}

    result =
      if ask.kind == :take_in,
        do: WorkItems.take_in(scope, ask.ticket.id, attrs),
        else: WorkItems.take_in_again(scope, ask.ticket.id, attrs)

    case result do
      {:ok, work_item} ->
        {:ok, update(socket, :take_in_drafts, &Map.delete(&1, ask.ticket.id)), work_item}

      {:error, :comment_too_long} ->
        {:open, assign(socket, :take_in, %{ask | comment: comment, errors: [too_long(comment)]})}

      {:error, %Ecto.Changeset{errors: errors}} when is_list(errors) ->
        case ApiaryWeb.CoreComponents.translate_errors(errors, :comment) do
          [] -> {:refused, socket, :unsaved, ask.ticket.id}
          words -> {:open, assign(socket, :take_in, %{ask | comment: comment, errors: words})}
        end

      {:error, refusal} ->
        {:refused, socket, refusal, ask.ticket.id}
    end
  end

  def confirm(_socket, _params), do: :none

  defp keep(socket, id, comment), do: update(socket, :take_in_drafts, &Map.put(&1, id, comment))

  defp too_long(comment),
    do:
      gettext("Shorten the comment to %{max} characters. It has %{count}.",
        max: ApiaryWeb.Format.number(@max),
        count:
          ApiaryWeb.Format.number(comment |> String.trim() |> String.codepoints() |> length())
      )

  # path/2 is the page of the work item a take in made or brought back.
  @spec path(Apiary.Accounts.Scope.t(), Apiary.WorkItems.WorkItem.t()) :: String.t()
  def path(scope, work_item),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{work_item.number}"
end
