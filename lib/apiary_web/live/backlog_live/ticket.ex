defmodule ApiaryWeb.BacklogLive.Ticket do
  # One ticket of a workspace's Backlog, by its public id (`tk_…`): its page (`:show`),
  # the full ticket (`ApiaryWeb.BacklogComponents.ticket/1`, frame `:full`), with Backlog
  # back, for whoever may read the workspace's work items.
  #
  # The ticket is read with the page's scope (`Apiary.Sources.Backlog.get_ticket/2`): an
  # id of no ticket of this Backlog is a path that does not exist. An open ticket with no
  # work item has Take in (`ApiaryWeb.BacklogComponents.take_in_block/1`), as over the
  # list: Take in opens the take in's dialog (`ApiaryWeb.BacklogLive.TakeIn`), whose Take
  # in leads to the new work item's page, and a refusal is a flash in the page's words
  # (`ApiaryWeb.BacklogComponents.take_in_refused/3`), after which the page reads the
  # ticket again. The page listens on the topic of its workspace's Backlog
  # (`Apiary.Sources.Backlog.subscribe/1`) and reads the ticket again on each message; a
  # ticket that leaves the Backlog meanwhile stays as it was last read.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory
  on_mount {ApiaryWeb.Access, :"work_item.read"}

  alias Apiary.{Access, Adapters}
  alias Apiary.Sources.Backlog
  alias ApiaryWeb.{BacklogComponents, SourceComponents}
  alias ApiaryWeb.BacklogLive.TakeIn

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:backlog}
    >
      <:crumb navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/backlog"}>
        {gettext("Backlog")}
      </:crumb>
      <:crumb>{@full_form}</:crumb>

      <BacklogComponents.ticket
        id="ticket"
        frame={:full}
        ticket={@ticket}
        integration={@ticket.integration.name}
        comments={@comments}
        back_path={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/backlog"}
        item_noun={@item_noun}
        collection_noun={@collection_noun}
      >
        <:take_in :if={@ticket.state == :open and is_nil(@ticket.work_item)}>
          <BacklogComponents.take_in_block
            id="ticket-take-in"
            ticket_id={@ticket.id}
            refused={@refused}
          />
        </:take_in>
        <:rendered_body>
          <SourceComponents.body
            id="ticket-body"
            body={@ticket.body}
            format={@ticket.body_format}
            item_noun={@item_noun}
          />
        </:rendered_body>
        <:rendered_comment :let={comment}>
          <SourceComponents.body
            id={"ticket-comment-#{comment.id}-body"}
            body={comment.body}
            format={comment.body_format}
            item_noun={@item_noun}
          />
        </:rendered_comment>
      </BacklogComponents.ticket>

      <BacklogComponents.take_in_dialog
        :if={@take_in}
        ask={@take_in}
        item_noun={@item_noun}
        collection_noun={@collection_noun}
      >
        <:rendered_body>
          <SourceComponents.body
            id="take-in-dialog-body"
            body={@take_in.ticket.body}
            format={@take_in.ticket.body_format}
            item_noun={@item_noun}
          />
        </:rendered_body>
        <:rendered_comment :let={comment}>
          <SourceComponents.body
            id={"take-in-dialog-comment-#{comment.id}-body"}
            body={comment.body}
            format={comment.body_format}
            item_noun={@item_noun}
          />
        </:rendered_comment>
      </BacklogComponents.take_in_dialog>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"item_id" => item_id}, _session, socket) do
    scope = socket.assigns.current_scope
    ticket = Backlog.get_ticket(scope, item_id) || raise ApiaryWeb.NotFound
    if connected?(socket), do: Backlog.subscribe(scope)

    {:ok,
     socket
     |> assign(
       page_title: Apiary.ExternalText.line(ticket.title),
       full_form: Apiary.ExternalText.line(BacklogComponents.full_form(ticket)),
       item_noun: Adapters.workspace_item_noun(scope),
       collection_noun:
         case Backlog.collection_nouns(scope) do
           [noun] -> noun
           _none_or_several -> nil
         end,
       refused:
         if(!Access.can?(scope, :"work_item.take_in", scope.workspace),
           do: BacklogComponents.take_in_who_may(scope)
         )
     )
     |> TakeIn.mount()
     |> put_ticket(ticket)}
  end

  @impl true
  # Take in opens the take in's dialog for the page's ticket, whatever id the press sends.
  def handle_event("take_in", params, socket) do
    case TakeIn.open(socket, "take_in", socket.assigns.ticket.id, params["return"]) do
      {:ok, socket} -> {:noreply, socket}
      {:refused, refusal} -> {:noreply, refused(socket, refusal)}
    end
  end

  def handle_event("take_in_change", params, socket),
    do: {:noreply, TakeIn.change(socket, params)}

  def handle_event("take_in_cancel", _params, socket), do: {:noreply, TakeIn.cancel(socket)}

  # The dialog's Take in: the new work item's page, the dialog again with the comment's
  # error, or why not.
  def handle_event("take_in_confirm", params, socket) do
    case TakeIn.confirm(socket, params) do
      {:ok, socket, work_item} ->
        {:noreply,
         push_navigate(socket, to: TakeIn.path(socket.assigns.current_scope, work_item))}

      {:open, socket} ->
        {:noreply, socket}

      {:refused, socket, refusal, _id} ->
        {:noreply, refused(socket, refusal)}

      :none ->
        {:noreply, socket}
    end
  end

  defp refused(socket, refusal) do
    words =
      BacklogComponents.take_in_refused(refusal, socket.assigns.current_scope, %{
        integration: socket.assigns.ticket.integration.name,
        item_noun: socket.assigns.item_noun
      })

    socket |> put_flash(:error, words) |> reload()
  end

  # A ticket of the workspace's Backlog was written, ended, closed or taken in: the page
  # reads its ticket again, with its scope, whatever the message names.
  @impl true
  def handle_info({:tickets_changed, _ids}, socket), do: {:noreply, reload(socket)}

  defp reload(socket) do
    case Backlog.get_ticket(socket.assigns.current_scope, socket.assigns.ticket.id) do
      nil -> socket
      ticket -> put_ticket(socket, ticket)
    end
  end

  defp put_ticket(socket, ticket),
    do:
      assign(socket,
        ticket: ticket,
        comments: Backlog.list_comments(socket.assigns.current_scope, ticket)
      )
end
