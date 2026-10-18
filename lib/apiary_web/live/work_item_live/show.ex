defmodule ApiaryWeb.WorkItemLive.Show do
  # One work item, by its number in the workspace: its Ticket tab (`:ticket`), Explore's
  # tab (`:explore`), the page that changes Qory's proposal (`:edit`) and its Thread
  # (`:thread`). The tabs are live actions of this one LiveView, so a tab is a patch and
  # the header stays.
  #
  # **The frame.** The header (`ApiaryWeb.WorkItemComponents.work_item_header/1`, with
  # its stages), the notices under it (the integration's uninstall, the Close question,
  # how it ended), the rail (the step card and Details) and the tabs. The edit page keeps
  # the header and draws the form in place of the rail and the tabs; it is there only
  # while Qory's proposal waits for a reader who may confirm it, and patches to Explore's
  # tab otherwise.
  #
  # **What it reads.** The work item by its number (`Apiary.WorkItems.get_by_number/2`),
  # where Explore stands (`explore/3`), its ticket (`ticket/3`), the names of its ticket
  # (`ticket_names/2`) and whether the Backlog can take it in again (`backlog_off/2`),
  # each with the page's scope; the Thread's events and comments only on the Thread
  # (`thread_entries/3`, the one place they are read). `ApiaryWeb.WorkItemLive.View`
  # turns them into what the components draw. A number that names no work item the
  # reader may read is not found.
  #
  # **Live.** The page listens on its workspace's work items
  # (`Apiary.WorkItems.subscribe/1`) and reads everything again when a message names its
  # work item; a work item that moved to another workspace is then not found here.
  #
  # **What a reader does.** Undo, Decline, Close, Confirm, Run Explore again, the answers
  # and the edit page's changes, each sent with the work item the page last read and the
  # attempt of its latest run, so a page that read an earlier state is refused
  # (`Apiary.WorkItems.Moves`). A refused action shows no words: the page reads the work
  # item again and draws where it stands now. Only a form whose fields are wrong says so,
  # under its fields. An event that names another number than the page's does nothing.
  #
  # **People's comments** (`ApiaryWeb.WorkItemLive.Comments`) are in the Thread, in the
  # order they were written among its events, with the composer under it for a reader
  # who may comment; their count (`Apiary.WorkItems.count_comments/2`) is beside the
  # Thread's tab on every tab. The page keeps the work item it read as `:work_item` and
  # the comments' assigns, and passes their events to that module; Cancel closes the
  # question showing, the page's or a comment's.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory
  on_mount {ApiaryWeb.Access, :"work_item.read"}

  import ApiaryWeb.WorkItemComponents

  alias Apiary.{Access, WorkItems}
  alias ApiaryWeb.UserAuth
  alias ApiaryWeb.WorkItemLive.{Comments, View}

  @answer_keys for position <- 1..20, do: Integer.to_string(position)
  @edit_keys ["understanding", "scope_in", "scope_out", "approach"]
  @comment_events Comments.events() -- ["cancel_question"]
  @actions ~w(undo ask_decline decline ask_close close confirm explore_again answer change_proposal confirm_changes)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:work_items}
      width="work"
    >
      <:crumb navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/work"}>
        {gettext("Work items")}
      </:crumb>
      <:crumb patch={@tab != :ticket && tab_path(@current_scope, @number, :ticket)}>
        {gettext("Work item #%{number}", number: @number)}
      </:crumb>

      <.work_item_frame label={gettext("Work item #%{number}", number: @number)}>
        <:header>
          <.work_item_header
            work_item={@item}
            integration={@source.integration}
            link={
              url(~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/work/#{@number}")
            }
            can_close={@can.close}
            can_act={@can.act}
          />
          <.uninstalled_notice
            :if={@source.uninstalled}
            integration={@source.integration}
            at={@source.uninstalled_at}
            item_noun={@source.item_noun}
            now={@now}
          />
          <.close_question
            :if={@asking == :close and @can.close}
            number={@number}
            integration={@source.integration}
            uninstalled={@source.uninstalled}
            backlog_off={@backlog_off}
            item_noun={@source.item_noun}
          />
          <.end_notice
            work_item={@item}
            integration={@source.integration}
            uninstalled={@source.uninstalled}
            backlog_off={@backlog_off}
            again_path={@again_path}
            item_noun={@source.item_noun}
            now={@now}
          />
        </:header>
        <:rail :if={@tab != :edit}>
          <.step_card
            work_item={@item}
            integration={@source.integration}
            uninstalled={@source.uninstalled}
            backlog_off={@backlog_off}
            can_undo={@can.undo}
            can_act={@can.act}
            can_close={@can.close}
            previous={@previous}
            explore_path={if @tab != :explore, do: tab_path(@current_scope, @number, :explore)}
            edit_path={tab_path(@current_scope, @number, :edit)}
            asking={if @asking == :decline, do: :decline}
            item_noun={@source.item_noun}
            now={@now}
          />
          <.work_item_details
            work_item={@item}
            ticket={@source.ticket}
            integration={@source.integration}
            uninstalled={@source.uninstalled}
            item_noun={@source.item_noun}
            collection_noun={@source.collection_noun}
            now={@now}
          />
        </:rail>
        <:body>
          <%= if @tab == :edit do %>
            <.proposal_edit
              number={@number}
              proposal={@item.run.proposal}
              values={@edit_values}
              errors={@edit_errors}
              explore_path={tab_path(@current_scope, @number, :explore)}
              submits={@edit_submits}
            />
          <% else %>
            <.work_item_tabs
              number={@number}
              current={@tab}
              ticket_path={tab_path(@current_scope, @number, :ticket)}
              explore_path={tab_path(@current_scope, @number, :explore)}
              thread_path={tab_path(@current_scope, @number, :thread)}
              comment_count={@comment_count}
              item_noun={@source.item_noun}
            />
            <.ticket_tab
              :if={@tab == :ticket and @source.ticket != nil}
              work_item={@item}
              ticket={@source.ticket}
              comments={@source.comments}
              integration={@source.integration}
              uninstalled={@source.uninstalled}
              item_noun={@source.item_noun}
              now={@now}
            />
            <.explore_tab
              :if={@tab == :explore}
              work_item={@item}
              earlier_runs={@earlier_runs}
              earlier_take_ins={@earlier_take_ins}
              changes={@changes}
              can_act={@can.act}
              backlog_off={@backlog_off}
              answers={@answers}
              errors={@errors}
              submits={@submits}
              item_noun={@source.item_noun}
              now={@now}
            />
            <.thread :if={@tab == :thread}>
              <%= for {event, i} <- Enum.with_index(@thread, 1) do %>
                <Comments.comment_line
                  :if={event.kind == :comment}
                  entry={event}
                  scope={@current_scope}
                  person={&View.person(@people, &1)}
                  deleting={@deleting_comment}
                  now={@now}
                />
                <.thread_event
                  :if={event.kind != :comment}
                  id={"work-item-thread-ev-#{i}"}
                  integration={@source.integration}
                  now={@now}
                  {event}
                />
              <% end %>
            </.thread>
            <Comments.composer
              :if={@tab == :thread}
              can_comment={@can_comment}
              key={@composer_key}
              value={@composer_value}
              error={@composer_error}
              number={@number}
              workspace={@current_scope.workspace.name}
              reader={View.person(@people, @current_scope.user.id).name}
              item_noun={@source.item_noun}
            />
          <% end %>
        </:body>
      </.work_item_frame>
    </Layouts.app>
    """
  end

  ## Lifecycle

  @impl true
  def mount(%{"number" => number}, _session, socket) do
    scope = socket.assigns.current_scope

    case WorkItems.get_by_number(scope, number) do
      nil ->
        raise ApiaryWeb.NotFound

      row ->
        if connected?(socket), do: WorkItems.subscribe(scope)

        {:ok,
         socket
         |> Comments.mount()
         |> assign(
           row: row,
           work_item: row,
           number: row.number,
           tab: :ticket,
           asking: nil,
           all_comments: false,
           comment_count: 0,
           answers: %{},
           errors: %{},
           submits: 0,
           edit_values: %{},
           edit_errors: %{},
           edit_submits: 0
         )}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> assign(:tab, socket.assigns.live_action) |> load() |> editable()}
  end

  # The edit page is there while Qory's proposal waits for a reader who may confirm it;
  # anywhere else it is Explore's tab.
  defp editable(%{assigns: %{row: nil}} = socket), do: socket

  defp editable(%{assigns: %{tab: :edit}} = socket) do
    %{item: item, can: can, number: number} = socket.assigns

    if item.status == :confirm and can.act,
      do: assign(socket, :page_title, edit_title(number)),
      else: push_patch(socket, to: tab_path(scope(socket), number, :explore))
  end

  defp editable(socket), do: socket

  ## What a reader does

  @impl true
  def handle_event("cancel_question", _params, socket),
    do: {:noreply, assign(socket, asking: nil, deleting_comment: nil)}

  def handle_event(event, params, socket) when event in @comment_events,
    do: Comments.handle_event(event, params, socket)

  def handle_event(event, %{"number" => number} = params, socket) when event in @actions do
    if number == Integer.to_string(socket.assigns.number),
      do: act(event, params, socket),
      else: {:noreply, socket}
  end

  def handle_event("show_earlier_comments", _params, socket),
    do: {:noreply, socket |> assign(:all_comments, true) |> load()}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp act("ask_decline", _params, socket), do: {:noreply, assign(socket, :asking, :decline)}
  defp act("ask_close", _params, socket), do: {:noreply, assign(socket, :asking, :close)}

  defp act("undo", _params, socket),
    do: done(socket, WorkItems.undo(scope(socket), socket.assigns.row))

  defp act("decline", _params, socket),
    do: done(socket, WorkItems.decline(scope(socket), socket.assigns.row))

  defp act("close", _params, socket),
    do: done(socket, WorkItems.close(scope(socket), socket.assigns.row))

  defp act("confirm", _params, socket) do
    with_attempt(socket, fn attempt ->
      done(socket, WorkItems.confirm(scope(socket), socket.assigns.row, attempt))
    end)
  end

  defp act("explore_again", _params, socket) do
    with_attempt(socket, fn attempt ->
      done(socket, WorkItems.explore_again(scope(socket), socket.assigns.row, attempt))
    end)
  end

  defp act("answer", params, socket) do
    # Only the questions' answers, and only text: anything else is no answer.
    answers =
      case params["answers"] do
        %{} = given ->
          for {key, value} <- Map.take(given, @answer_keys),
              is_binary(value),
              into: %{},
              do: {key, value}

        _none ->
          %{}
      end

    with_attempt(socket, fn attempt ->
      case WorkItems.answer(scope(socket), socket.assigns.row, attempt, answers) do
        {:ok, _work_item} ->
          {:noreply, socket |> assign(answers: %{}, errors: %{}) |> load()}

        {:error, {:invalid, errors}} ->
          errors = if errors == :form, do: form_errors(socket, answers), else: errors

          {:noreply,
           socket
           |> assign(answers: answers, errors: errors)
           |> update(:submits, &(&1 + 1))}

        {:error, _refused} ->
          {:noreply, socket |> assign(answers: answers, errors: %{}) |> refresh()}
      end
    end)
  end

  defp act("change_proposal", params, socket),
    do: {:noreply, assign(socket, :edit_values, edit_values(params))}

  defp act("confirm_changes", params, socket) do
    changes = changes(params)

    with_attempt(socket, fn attempt ->
      case WorkItems.confirm(scope(socket), socket.assigns.row, attempt, changes) do
        {:ok, _work_item} ->
          {:noreply,
           socket
           |> assign(edit_values: %{}, edit_errors: %{})
           |> push_patch(to: tab_path(scope(socket), socket.assigns.number, :explore))}

        {:error, {:invalid, errors}} ->
          errors = if errors == :form, do: edit_form_errors(changes), else: errors

          {:noreply,
           socket
           |> assign(edit_values: edit_values(params), edit_errors: errors)
           |> update(:edit_submits, &(&1 + 1))}

        {:error, _refused} ->
          {:noreply, socket |> assign(:edit_errors, %{}) |> refresh(&editable/1)}
      end
    end)
  end

  # The attempt of the latest run as the page read it; with none, nothing to do.
  defp with_attempt(socket, fun) do
    case socket.assigns.item.run do
      %{attempt: attempt} when is_integer(attempt) -> fun.(attempt)
      _none -> {:noreply, socket}
    end
  end

  # After an action: no question showing, and the work item read again; after a refusal,
  # with the scope read again first.
  defp done(socket, {:error, _refused}),
    do: {:noreply, socket |> assign(:asking, nil) |> refresh()}

  defp done(socket, _result), do: {:noreply, socket |> assign(:asking, nil) |> load()}

  # A form that names another question or gives no text: each question of the latest run
  # without a text is to be answered.
  defp form_errors(socket, answers) do
    for question <- socket.assigns.item.run[:questions] || [],
        not is_binary(answers[question.public_id]),
        into: %{},
        do: {question.public_id, :blank}
  end

  # What the edit page's fields hold, by the names `proposal_edit/1` takes.
  defp edit_values(params) do
    complexity = if is_map(params["complexity"]), do: params["complexity"], else: %{}

    [level: complexity["level"], reason: complexity["reason"]]
    |> Enum.concat(for key <- @edit_keys, do: {String.to_existing_atom(key), params[key]})
    |> Enum.filter(fn {_field, value} -> is_binary(value) end)
    |> Map.new()
  end

  # What `Apiary.WorkItems.confirm/4` is given: the edit page's fields alone.
  defp changes(params) do
    complexity = if is_map(params["complexity"]), do: params["complexity"], else: %{}

    params
    |> Map.take(@edit_keys)
    |> Map.put("complexity", Map.take(complexity, ["level", "reason"]))
  end

  # A form missing a field, or with a field that is not text: each such field is to be
  # written.
  defp edit_form_errors(changes) do
    fields =
      [{:reason, changes["complexity"]["reason"]}] ++
        for key <- @edit_keys, do: {String.to_existing_atom(key), changes[key]}

    for {field, value} <- fields, not is_binary(value), into: %{}, do: {field, :blank}
  end

  ## Live

  @impl true
  def handle_info({:work_items_changed, ids}, %{assigns: %{row: %{public_id: id}}} = socket) do
    if is_list(ids) and id in ids,
      do: {:noreply, refresh(socket, &editable/1)},
      else: {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Reads

  # The scope read again before the work item, as the node pages do once a membership may
  # have changed elsewhere or an action was refused (`ApiaryWeb.UserAuth.reload_scope/1`):
  # a reader who may no longer be here is sent away; any other reads the page again, then
  # `next`.
  defp refresh(socket, next \\ & &1) do
    socket = UserAuth.reload_scope(socket)
    if socket.redirected, do: socket, else: socket |> load() |> next.()
  end

  # Everything the page draws, read again with its scope. A work item no longer readable
  # here loads the same address again, which is then not found.
  defp load(socket) do
    scope = scope(socket)
    now = DateTime.utc_now()
    comments = if socket.assigns.all_comments, do: :all, else: :latest

    with %{} = row <- WorkItems.get_by_number(scope, socket.assigns.number),
         %{} = explore <- WorkItems.explore(scope, row, now),
         %{} = source <- WorkItems.ticket(scope, row, comments) do
      names = Map.get(WorkItems.ticket_names(scope, [row]), row.id, %{})
      thread = if socket.assigns.tab == :thread, do: thread_entries(scope, row, now), else: []
      page = View.page(scope, row, explore, thread, names)

      # Take in again is reached from the Backlog only while it shows the ticket: its
      # record is live, its adapter is not removed, and its Backlog takes it in.
      backlog_off =
        is_nil(names[:ticket_id]) or source.adapter_removed or
          MapSet.member?(WorkItems.backlog_off(scope, [row]), row.id)

      assign(socket,
        row: row,
        now: now,
        page_title: gettext("Work item #%{number}", number: row.number),
        source: source,
        backlog_off: backlog_off,
        again_path:
          names[:ticket_id] &&
            ~p"/#{scope.organisation}/#{scope.workspace}/backlog?#{[ticket: names[:ticket_id]]}",
        previous: explore.previous,
        item: page.work_item,
        work_item: row,
        earlier_runs: page.earlier_runs,
        earlier_take_ins: page.earlier_take_ins,
        changes: page.changes,
        thread: page.thread,
        people: page.people,
        comment_count: WorkItems.count_comments(scope, row),
        can_comment: Comments.can_comment?(scope, row),
        deleting_comment: Comments.still_asking(socket.assigns.deleting_comment, thread),
        can: can(scope, row, explore.status)
      )
    else
      _gone ->
        socket
        |> assign(:row, nil)
        |> push_navigate(to: tab_path(scope, socket.assigns.number, socket.assigns.tab))
    end
  end

  # The Thread: what happened at Explore and people's comments, the one place the page
  # reads them.
  defp thread_entries(scope, row, now), do: WorkItems.thread(scope, row, now)

  # What the reader may do here: undo, close, and act at the step it stands at.
  defp can(scope, row, status) do
    live? = status not in [:declined, :closed, :undone]

    action =
      case status do
        :questions -> :"work_item.answer"
        :confirm -> :"work_item.confirm"
        status when status in [:no_result, :lost, :cancelled] -> :"work_item.explore_again"
        :used_up -> :"work_item.decline"
        _other -> nil
      end

    %{
      undo: live? and Access.can?(scope, :"work_item.undo", row),
      close: live? and Access.can?(scope, :"work_item.close", row),
      act: live? and not is_nil(action) and Access.can?(scope, action, row)
    }
  end

  defp scope(socket), do: socket.assigns.current_scope

  defp tab_path(scope, number, :ticket),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}"

  defp tab_path(scope, number, :explore),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}/explore"

  defp tab_path(scope, number, :edit),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}/explore/edit"

  defp tab_path(scope, number, :thread),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}/thread"
end
