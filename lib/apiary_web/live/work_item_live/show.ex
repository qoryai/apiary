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
  # **A test work item** has no ticket and no integration: no Ticket tab (its address
  # patches to Explore's tab), no ticket in the header, Details or the Thread, and no
  # Take in again. Its parts call the line it was made from "the line", where they call
  # a ticket "the ticket".
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
  # **The workflow model.** Where the reader is shown the feature `workflow_model`
  # (`ApiaryWeb.WorkItemLive.Workflow`), the header shows the stages of the work item's
  # process version, the rail the stage card in place of the step card, and the body
  # the runs and the artifacts above the tabs (`ApiaryWeb.WorkItemLive.StageComponents`).
  # The page reads them again on `{:stage_changed, id}` and `{:artifact_pushed, …}` on the
  # work item's topics (`ApiaryWeb.WorkItemLive.Workflow.subscribe/1`), and does
  # Approve, Request changes, the escalation actions and Move back through
  # `Apiary.Stages`, each refused without words as the other actions are. The head's
  # status follows the stage and its state, as Explore's words do at Explore; a work item
  # that ended keeps its words and the stage track, and has no stage card. Without the
  # feature the page is as before it.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory
  on_mount {ApiaryWeb.Access, :"work_item.read"}

  import ApiaryWeb.WorkItemComponents

  alias Apiary.{Access, WorkItems}
  alias ApiaryWeb.{HarnessComponents, UserAuth}
  alias ApiaryWeb.WorkItemLive.{Comments, StageComponents, View, Workflow}

  @answer_keys for position <- 1..20, do: Integer.to_string(position)
  @edit_keys ["understanding", "scope_in", "scope_out", "approach"]
  @comment_events Comments.events() -- ["cancel_question"]
  @actions ~w(undo ask_decline decline ask_close close confirm explore_again answer change_proposal confirm_changes)
  # The statuses of today's Explore (`Apiary.WorkItems.explore/3`) while the work item is
  # at Explore, its gate included.
  @explore_statuses [
    :queued,
    :running,
    :questions,
    :used_up,
    :no_result,
    :lost,
    :cancelled,
    :confirm
  ]

  @stage_events ~w(stage_approve stage_ask_changes stage_request_changes stage_resolve stage_move stage_check)
  @resolutions %{
    "accept" => :accept,
    "another_round" => :another_round,
    "close" => :close,
    "decline" => :decline
  }

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
      <:crumb patch={@tab != home(@row) && tab_path(@current_scope, @number, home(@row))}>
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
            stage_status={head_status(@flow, @item)}
          >
            <:track :if={@flow}>
              <StageComponents.process_track id="work-item-head-stages" page={@flow} />
            </:track>
          </.work_item_header>
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
            test={@item.test}
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
          <StageComponents.stage_card
            :if={@flow && !@flow.ended}
            page={@flow}
            number={@number}
            add_path={&add_path(@current_scope, @number, &1)}
            answers_path={tab_path(@current_scope, @number, :explore)}
            asking={@stage_asking}
            error={@stage_error}
            check={@stage_check}
            notice={@stage_notice}
          />
          <.step_card
            :if={!@flow or @flow.explore}
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
            <div :if={@flow} id="work-item-flow" class="flex flex-col gap-3">
              <StageComponents.stage_runs runs={@flow.runs} />
              <StageComponents.stage_notes notes={@flow.notes} />
              <section
                id="work-item-artifacts"
                class="q-xp-sec"
                aria-labelledby="work-item-artifacts-h"
              >
                <h3 id="work-item-artifacts-h">{gettext("Artifacts")}</h3>
                <StageComponents.approval_marks index={@flow.index} />
                <Workflow.artifact_list id="work-item-artifact-list" artifacts={@artifacts} />
              </section>
            </div>
            <.work_item_tabs
              number={@number}
              current={@tab}
              ticket_path={tab_path(@current_scope, @number, :ticket)}
              explore_path={tab_path(@current_scope, @number, :explore)}
              thread_path={tab_path(@current_scope, @number, :thread)}
              comment_count={@comment_count}
              item_noun={@source.item_noun}
              ticket={!@item.test}
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
        if connected?(socket) do
          WorkItems.subscribe(scope)
          if Workflow.on?(scope), do: Workflow.subscribe(row)
        end

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
           edit_submits: 0,
           flow: nil,
           artifacts: [],
           stage_asking: nil,
           stage_error: nil,
           stage_check: nil,
           stage_notice: nil
         )}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket |> assign(:tab, socket.assigns.live_action) |> load() |> ticketed() |> editable()}
  end

  # A test work item has no Ticket tab: its address is Explore's tab.
  defp ticketed(%{assigns: %{row: %{test: true}, tab: :ticket}} = socket),
    do: push_patch(socket, to: tab_path(scope(socket), socket.assigns.number, :explore))

  defp ticketed(socket), do: socket

  # The tab the work item's address opens: Explore's for a test work item, which has no
  # ticket.
  defp home(%{test: true}), do: :explore
  defp home(_row), do: :ticket

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
    do:
      {:noreply,
       assign(socket, asking: nil, deleting_comment: nil, stage_asking: nil, stage_error: nil)}

  def handle_event(event, params, socket) when event in @comment_events,
    do: Comments.handle_event(event, params, socket)

  def handle_event(event, %{"number" => number} = params, socket) when event in @actions do
    # While the stage runner holds an escalation, Run another round on its card runs
    # Explore again.
    held? =
      event == "explore_again" and
        escalated?(socket.assigns[:flow], status(socket.assigns[:item]))

    if number == Integer.to_string(socket.assigns.number) and not held?,
      do: act(event, params, socket),
      else: {:noreply, socket}
  end

  def handle_event(event, %{"number" => number} = params, socket) when event in @stage_events do
    if number == Integer.to_string(socket.assigns.number) and socket.assigns.flow,
      do: stage_act(event, params, socket),
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

  # The workflow model's actions. Each form sends the stage the reader saw (`seen`); the
  # page reads the work item again and acts only while it is still in that stage, asked
  # again on the server (`ApiaryWeb.WorkItemLive.Workflow.decide/4`) with the page as it
  # is now.
  defp stage_act("stage_ask_changes", _params, socket),
    do: {:noreply, assign(socket, stage_asking: :changes, stage_error: nil)}

  defp stage_act("stage_approve", params, socket),
    do: fresh(socket, params, &decided(&1, &2, {:approve, note(params)}))

  defp stage_act("stage_request_changes", params, socket) do
    case note(params) do
      nil ->
        {:noreply, assign(socket, stage_asking: :changes, stage_error: :note)}

      note ->
        fresh(socket, params, &decided(&1, &2, {:request_changes, note, text(params["version"])}))
    end
  end

  defp stage_act("stage_resolve", %{"how" => "move_back"} = params, socket) do
    case text(params["stage"]) do
      nil ->
        {:noreply, socket}

      stage ->
        fresh(socket, params, &decided(&1, &2, {:resolve, {:move_back, stage}, note(params)}))
    end
  end

  defp stage_act("stage_resolve", params, socket) do
    case Map.fetch(@resolutions, params["how"]) do
      {:ok, how} -> fresh(socket, params, &decided(&1, &2, {:resolve, how, note(params)}))
      :error -> {:noreply, socket}
    end
  end

  defp stage_act("stage_move", params, socket) do
    case text(params["stage"]) do
      nil -> {:noreply, socket}
      stage -> fresh(socket, params, &decided(&1, &2, {:move, stage, note(params)}))
    end
  end

  # Check again, while the stage waits for a workflow: the read of the harness calls its
  # adapter, so it runs outside the page's process (`handle_async/3`). A found workflow
  # starts the stage's run, and a work item that ended keeps its stage state, so the check
  # runs only on one that has not ended; `fresh/3` has read the page again by then.
  defp stage_act("stage_check", params, socket) do
    fresh(socket, params, fn socket, _seen ->
      %{row: row, flow: flow} = socket.assigns
      scope = scope(socket)

      if flow.ended do
        {:noreply, socket}
      else
        {:noreply,
         socket
         |> assign(:stage_check, :checking)
         |> start_async(:stage_check, fn -> Workflow.check(scope, row, flow) end)}
      end
    end)
  end

  # Reads the page again, then calls `fun` with the socket and the stage the reader saw,
  # where the work item is still in it; otherwise shows where it moved.
  defp fresh(socket, params, fun) do
    seen = {socket.assigns.flow, text(params["seen"])}
    socket = refresh(socket)

    cond do
      socket.redirected != nil or is_nil(socket.assigns.row) ->
        {:noreply, socket}

      is_nil(elem(seen, 1)) ->
        {:noreply, socket}

      current_stage(socket) == elem(seen, 1) ->
        fun.(assign(socket, :stage_notice, nil), seen)

      true ->
        {:noreply, assign(socket, :stage_notice, moved(seen, socket.assigns.flow))}
    end
  end

  defp stage_key(%{stage: %{id: id}}), do: id
  defp stage_key(_flow), do: nil

  defp current_stage(%{assigns: %{flow: %{stage: %{id: id}}}}), do: id
  defp current_stage(_socket), do: nil

  defp decided(socket, seen, action) do
    %{row: row, flow: flow} = socket.assigns

    case Workflow.decide(scope(socket), row, flow, action) do
      {:ok, _result} ->
        {:noreply, socket |> assign(stage_asking: nil, stage_error: nil) |> load()}

      {:error, reason} when reason in [:stage_changed, :not_at_gate, :not_escalated] ->
        socket = refresh(socket)

        if socket.redirected,
          do: {:noreply, socket},
          else: {:noreply, assign(socket, :stage_notice, moved(seen, socket.assigns.flow))}

      # A work item that ended has no stage card, so the page read again is the answer.
      {:error, reason} when reason in [:forbidden, :confirm_gate, :invalid, :not_live] ->
        {:noreply, socket |> assign(stage_asking: nil, stage_error: nil) |> refresh()}

      {:error, reason} ->
        socket = refresh(socket)

        if socket.redirected,
          do: {:noreply, socket},
          else: {:noreply, assign(socket, :stage_notice, refused(reason, flow))}
    end
  end

  # Why the stage runner did not act, each with its fix first.
  defp refused(:not_earlier, flow), do: not_earlier(flow)

  defp refused(:not_approver, flow),
    do: gettext("Ask an approver of %{stage} to act on it.", stage: flow.stage.name)

  defp refused(:unknown_stage, _flow),
    do:
      gettext(
        "Choose a stage from the list. The stage you sent is not in the work item's process version."
      )

  defp refused(:not_placed, _flow),
    do: gettext("Reload the page. The work item is not in a stage.")

  defp refused(:not_found, _flow),
    do: gettext("Reload the page. The work item is not in this workspace any more.")

  defp refused({:invalid, :note}, _flow),
    do: gettext("Shorten the note to 4,000 characters or fewer.")

  defp refused(_reason, _flow),
    do:
      gettext(
        "Reload the page and act again, and tell an instance admin if it fails again. Qory Apiary could not act on the stage."
      )

  # Where the work item moved since the reader saw it, by the names of the stages.
  defp moved({seen_flow, seen_id}, flow) do
    stage = stage_name(seen_flow, seen_id) || stage_name(flow, seen_id) || seen_id

    case flow do
      %{stage: %{id: ^seen_id, name: current}} ->
        gettext("Check the stage and act again. %{stage} changed before your click.",
          stage: current
        )

      %{stage: %{name: current}} when is_binary(current) ->
        gettext(
          "Check the new stage and act again. The work item moved from %{stage} to %{current} before your click.",
          stage: stage,
          current: current
        )

      _none ->
        gettext(
          "Check the work item's stage and act again. It moved from %{stage} before your click.",
          stage: stage
        )
    end
  end

  defp not_earlier(flow),
    do:
      gettext("Choose a stage before %{current} to move back to.",
        current: (flow && flow.stage.name) || ""
      )

  defp stage_name(%{stages: stages}, id), do: Enum.find_value(stages, &(&1.id == id && &1.name))
  defp stage_name(_flow, _id), do: nil

  @impl true
  def handle_async(:stage_check, {:ok, result}, socket) do
    case result do
      {:ok, _work_item} ->
        {:noreply, socket |> assign(:stage_check, nil) |> load()}

      {:error, :still_missing} ->
        socket = load(assign(socket, :stage_check, nil))

        workflow =
          (socket.assigns.flow && List.first(socket.assigns.flow.missing_workflows)) || ""

        {:noreply, assign(socket, :stage_check, {:still_missing, workflow})}

      {:error, reason} when reason in [:forbidden, :not_found, :not_approver] ->
        {:noreply, socket |> assign(:stage_check, nil) |> refresh()}

      {:error, reason} ->
        {:noreply, assign(socket, :stage_check, {:failed, check_words(socket, reason)})}
    end
  end

  def handle_async(:stage_check, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :stage_check, {:failed, check_words(socket, :exited)})}

  # Why Check again did not start the stage, each with its fix first: the work item is not
  # live or not in a stage, or the harness was not read (`Apiary.Stacks.Sources.read/2`).
  defp check_words(_socket, :not_live),
    do:
      gettext(
        "Reload the page. The work item is closed or declined, so it has no stage to check."
      )

  defp check_words(_socket, :not_placed),
    do: gettext("Reload the page. The work item is not in a stage, so there is nothing to check.")

  defp check_words(_socket, :exited),
    do:
      gettext(
        "Try again, and tell an instance admin if it fails again. The check of the harness stopped with an error in Qory Apiary."
      )

  defp check_words(socket, reason) do
    scope = scope(socket)

    chosen = Apiary.Stacks.Sources.chosen(scope.workspace)
    source = Map.put(chosen, :label, chosen.git || "")
    HarnessComponents.read_words(reason, source, scope.organisation.name)
  end

  # A note as the Stages functions take it: its text, or nil where it is blank.
  defp note(params), do: text(params["note"])

  defp text(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp text(_value), do: nil

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

  def handle_info({:stage_changed, id}, %{assigns: %{row: %{} = row}} = socket) do
    if socket.assigns.flow && id in [row.id, row.public_id],
      do: {:noreply, refresh(socket, &editable/1)},
      else: {:noreply, socket}
  end

  def handle_info({:artifact_pushed, _pushed}, socket) do
    if socket.assigns.flow,
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
      # Explore runs as before the workflow model: while the work item is at Explore,
      # the step card stays beside the stage card, with Undo, the answers, Decline and
      # Confirm. Its Confirm approves Explore's gate (`Apiary.WorkItems.confirm/4`), so
      # the stage card offers no second Approve there.
      flow = if Workflow.on?(scope), do: Workflow.page(scope, row)

      flow =
        flow &&
          %{
            flow
            | confirm_gate: explore.status == :confirm,
              explore: explore.status in @explore_statuses,
              ended: explore.status in [:declined, :closed, :undone]
          }

      page = View.page(scope, row, explore, thread, names)

      # A form opened in another stage, and its check, close when the stage changes.
      socket =
        if stage_key(socket.assigns[:flow]) == stage_key(flow),
          do: socket,
          else: assign(socket, stage_asking: nil, stage_error: nil, stage_check: nil)

      # Take in again is reached from the Backlog only while it shows the ticket: its
      # record is live, its adapter is not removed, and its Backlog takes it in.
      backlog_off =
        is_nil(names[:ticket_id]) or source.adapter_removed or
          MapSet.member?(WorkItems.backlog_off(scope, [row]), row.id)

      assign(socket,
        row: row,
        now: now,
        page_title: gettext("Work item #%{number}", number: row.number),
        source: words(row, source),
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
        can: can(scope, row, explore.status, flow),
        flow: flow,
        artifacts: if(flow, do: Workflow.artifacts(row), else: [])
      )
    else
      _gone ->
        socket
        |> assign(:row, nil)
        |> push_navigate(to: tab_path(scope, socket.assigns.number, socket.assigns.tab))
    end
  end

  # A test work item's parts call its line "the line", where they call a ticket "the
  # ticket".
  defp words(%{test: true}, source) do
    %{
      source
      | item_noun: %{
          one: pgettext("the line a test work item was made from", "line"),
          other: pgettext("the line a test work item was made from", "lines")
        }
    }
  end

  defp words(_row, source), do: source

  # The Thread: what happened at Explore and people's comments, the one place the page
  # reads them.
  defp thread_entries(scope, row, now), do: WorkItems.thread(scope, row, now)

  # What the reader may do here: undo, close, and act at the step it stands at. While the
  # stage runner holds an escalation, its card offers Run another round and Decline in
  # place of the step card's Run Explore again and Decline.
  # The head's status under the workflow model: nil keeps the words of the work item's
  # status, for one that ended, and at Explore while a run, its questions or its gate
  # are what the stage is at; anywhere else, the stage and its state.
  defp head_status(nil, _item), do: nil
  defp head_status(%{ended: true}, _item), do: nil

  defp head_status(%{at_explore: true, state: state}, %{status: status})
       when state in [:running, :waiting_answers, :at_gate] and status in @explore_statuses,
       do: nil

  defp head_status(flow, _item), do: StageComponents.head_status(flow)

  defp can(scope, row, status, flow) do
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
      act:
        live? and not is_nil(action) and not escalated?(flow, status) and
          Access.can?(scope, action, row)
    }
  end

  defp status(%{status: status}), do: status
  defp status(_item), do: nil

  defp escalated?(%{escalation: %{}}, status)
       when status in [:no_result, :lost, :cancelled, :used_up],
       do: true

  defp escalated?(_flow, _status), do: false

  defp scope(socket), do: socket.assigns.current_scope

  defp tab_path(scope, number, :ticket),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}"

  defp tab_path(scope, number, :explore),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}/explore"

  defp tab_path(scope, number, :edit),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}/explore/edit"

  defp tab_path(scope, number, :thread),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}/thread"

  # Add's page for an input of `type`: a person's upload of an artifact
  # (`ApiaryWeb.ArtifactLive`).
  defp add_path(scope, number, type) do
    ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}" <>
      "/artifacts/new?" <> URI.encode_query(type: type)
  end
end
