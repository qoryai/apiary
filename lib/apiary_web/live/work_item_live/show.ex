defmodule ApiaryWeb.WorkItemLive.Show do
  # One work item, by its number in the workspace: its Ticket tab (`:ticket`), Explore's
  # tab (`:explore`) and its Thread (`:thread`). The tabs are live actions of this one
  # LiveView, so a tab is a patch and the header stays.
  #
  # **The frame.** The header (`ApiaryWeb.WorkItemComponents.work_item_header/1`, with
  # its stages), the notices under it (the integration's uninstall, the Close question,
  # how it ended), the rail (the step card and Details) and the tabs.
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
  # **What a reader does.** Undo, Close, Run Explore again, the answers, and under Qory's
  # proposal Confirm or a comment, each sent with the work item the page last read and
  # the attempt of its latest run, so a page that read an earlier state is refused
  # (`Apiary.WorkItems.Moves`). A refused action shows no words: the page reads the work
  # item again and draws where it stands now. Only a form whose fields are wrong says so,
  # under its fields, and a comment by a reader who is not an approver of the stage. The
  # forms' drafts are kept as the reader writes (`"answer_draft"`, `"change_draft"`): a
  # selected option clears its question's text, and a text clears the selected option.
  # A comment's field is empty to confirm. An event that names another number than the
  # page's does nothing.
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
  # At Explore the runs and the artifacts are in the history fold, and the block above the
  # tabs shows only while a note of a gate decision, an escalation or a check exists.
  # The page reads them again on `{:stage_changed, id}` and `{:artifact_pushed, …, …}` on the
  # work item's topics (`ApiaryWeb.WorkItemLive.Workflow.subscribe/2`), and does
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

  alias Apiary.{Access, Artifacts, WorkItems}
  alias ApiaryWeb.{ArtifactComponents, HarnessComponents, UserAuth}
  alias ApiaryWeb.WorkItemLive.{Comments, StageComponents, View, Workflow}

  @comment_events Comments.events() -- ["cancel_question"]
  # The stage's state and Explore's status under which the step card is the one card.
  @one_card [
    {:running, :queued},
    {:running, :running},
    {:waiting_answers, :questions},
    {:at_gate, :confirm}
  ]

  @actions ~w(undo ask_close close explore_again answer_draft answer confirm run_with_comments review_comment reply)
  # The statuses where no run runs, so a member may write review comments
  # (`Apiary.WorkItems.Moves.review_comment/4`).
  @no_run [:questions, :confirm, :no_result, :lost, :cancelled, :used_up]
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
    "close" => :close
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
      width={if @page, do: "read", else: "work"}
    >
      <:crumb navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/work"}>
        {gettext("Work items")}
      </:crumb>
      <:crumb patch={
        (@page && tab_path(@current_scope, @number, :explore)) ||
          (@tab != home(@row) && tab_path(@current_scope, @number, home(@row)))
      }>
        {gettext("Work item #%{number}", number: @number)}
      </:crumb>

      <:crumb :if={@page}>{page_title(@page)}</:crumb>

      <.review_page
        :if={@page}
        kind={elem(@page, 0)}
        number={@number}
        comment={elem(@page, 1)}
        value={@page_value}
        error={@page_error}
        submits={@page_submits}
        cancel={tab_path(@current_scope, @number, :explore)}
      />
      <.work_item_frame :if={!@page} label={gettext("Work item #%{number}", number: @number)}>
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
            backlog_off={@backlog_off or is_nil(@again_path)}
            again_path={@again_path}
            item_noun={@source.item_noun}
            now={@now}
          />
        </:header>
        <:rail>
          <StageComponents.stage_card
            :if={@flow && !@flow.ended && !one_card?(@flow, @item)}
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
            :if={step_card?(@flow, @item)}
            work_item={@item}
            integration={@source.integration}
            uninstalled={@source.uninstalled}
            backlog_off={@backlog_off}
            can_undo={@can.undo}
            can_act={@can.act}
            can_close={@can.close}
            previous={@previous}
            explore_path={if @tab != :explore, do: tab_path(@current_scope, @number, :explore)}
            item_noun={@source.item_noun}
            now={@now}
            queued_of={queued_of(@flow, @item)}
            stage_name={if one_card?(@flow, @item), do: @flow.stage.name}
          >
            <:badge :if={one_card?(@flow, @item)}>
              <StageComponents.stage_badge page={@flow} />
            </:badge>
          </.step_card>
          <.work_item_details
            work_item={@item}
            ticket={@source.ticket}
            integration={@source.integration}
            uninstalled={@source.uninstalled}
            item_noun={@source.item_noun}
            collection_noun={@source.collection_noun}
            queued={queued_run(@flow, @item)}
            process_version={@flow && @flow.version}
            fold={@review_comments != []}
            now={@now}
          />
          <.review_comments
            :if={@review_comments != []}
            id="work-item-review"
            class="q-rc-rail"
            comments={@review_comments}
            reply_path={!running?(@item) && @can_review && (&reply_path(@current_scope, @number, &1))}
            reading={running?(@item) && @item.run[:attempt]}
          />
        </:rail>
        <:body>
          <div
            :if={@flow && (!@flow.explore or stage_notes(@flow) != [])}
            id="work-item-flow"
            class="q-wi-flow flex flex-col gap-3"
          >
            <StageComponents.stage_runs :if={!@flow.explore} runs={@flow.runs} />
            <StageComponents.stage_notes notes={stage_notes(@flow)} />
            <section
              :if={!@flow.explore}
              id="work-item-artifacts"
              class="q-xp-sec"
              aria-labelledby="work-item-artifacts-h"
            >
              <h3 id="work-item-artifacts-h">{gettext("Artifacts")}</h3>
              <StageComponents.approval_marks index={@flow.index} />
              <ArtifactComponents.list
                id="work-item-artifact-list"
                artifacts={@artifacts}
                scope={@current_scope}
                number={@number}
                add={@flow.can_add}
              />
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
            proposal={@proposal}
            questions={@questions}
            questions_version={@questions_version}
            review_comments={@review_comments}
            can_act={@can.act}
            review_path={@can_review && review_path(@current_scope, @number)}
            reply_path={@can_review && (&reply_path(@current_scope, @number, &1))}
            backlog_off={@backlog_off}
            answers={@answers}
            errors={@errors}
            form_error={@form_error}
            submits={@submits}
            item_noun={@source.item_noun}
            now={@now}
          >
            <:artifacts :if={@flow && @flow.explore}>
              <section
                id="work-item-artifacts"
                class="q-xp-sec"
                aria-labelledby="work-item-artifacts-h"
              >
                <h3 id="work-item-artifacts-h">{gettext("Artifacts")}</h3>
                <StageComponents.approval_marks index={@flow.index} />
                <ArtifactComponents.list
                  id="work-item-artifact-list"
                  artifacts={@artifacts}
                  scope={@current_scope}
                  number={@number}
                  add={@flow.can_add}
                />
              </section>
            </:artifacts>
          </.explore_tab>
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
          if Workflow.on?(scope), do: Workflow.subscribe(scope, row)
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
           form_error: nil,
           submits: 0,
           page: nil,
           asked_page: nil,
           page_value: "",
           page_error: nil,
           page_submits: 0,
           proposal: nil,
           questions: [],
           questions_version: nil,
           review_comments: [],
           can_review: false,
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
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:tab, socket.assigns.live_action)
     |> assign(:asked_page, asked_page(socket.assigns.live_action, params))
     |> load()
     |> ticketed()}
  end

  # The form page an address on Explore's tab asks for: `?review=new` for Add review
  # comment, `?reply=<id>` for Reply to that review comment; nil for none.
  defp asked_page(:explore, %{"review" => "new"}), do: :comment
  defp asked_page(:explore, %{"reply" => id}) when is_binary(id), do: {:reply, id}
  defp asked_page(_tab, _params), do: nil

  # The form page as the work item stands: one the reader may use now, else none, and
  # the address patches back to Explore's tab.
  defp form_page(%{assigns: %{asked_page: nil}} = socket), do: assign(socket, :page, nil)

  defp form_page(%{assigns: %{can_review: false}} = socket), do: back(socket)

  defp form_page(%{assigns: %{asked_page: :comment}} = socket),
    do: assign(socket, :page, {:comment, nil})

  defp form_page(%{assigns: %{asked_page: {:reply, id}}} = socket) do
    case Enum.find(socket.assigns.review_comments, &(&1.id == id)) do
      nil -> back(socket)
      comment -> assign(socket, :page, {:reply, comment})
    end
  end

  defp back(socket) do
    socket
    |> assign(page: nil, asked_page: nil)
    |> push_patch(to: tab_path(scope(socket), socket.assigns.number, :explore))
  end

  defp page_title({:comment, _comment}), do: gettext("Add review comment")
  defp page_title({:reply, _comment}), do: gettext("Reply")

  # A test work item has no Ticket tab: its address is Explore's tab.
  defp ticketed(%{assigns: %{row: %{test: true}, tab: :ticket}} = socket),
    do: push_patch(socket, to: tab_path(scope(socket), socket.assigns.number, :explore))

  defp ticketed(socket), do: socket

  # The tab the work item's address opens: Explore's for a test work item, which has no
  # ticket.
  defp home(%{test: true}), do: :explore
  defp home(_row), do: :ticket

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

  defp act("ask_close", _params, socket), do: {:noreply, assign(socket, :asking, :close)}

  defp act("undo", _params, socket),
    do: done(socket, WorkItems.undo(scope(socket), socket.assigns.row))

  defp act("close", _params, socket),
    do: done(socket, WorkItems.close(scope(socket), socket.assigns.row))

  defp act("explore_again", _params, socket) do
    with_attempt(socket, fn attempt ->
      done(socket, WorkItems.explore_again(scope(socket), socket.assigns.row, attempt))
    end)
  end

  # The questions form as the reader changes it.
  defp act("answer_draft", params, socket),
    do: {:noreply, assign(socket, :answers, drafted(params))}

  # Run with answers: the answers given, each question with an option, Give your own
  # option, or a note; a question with neither stays open.
  defp act("answer", params, socket) do
    draft = drafted(params)
    open = Enum.filter(socket.assigns.questions, &(&1.state == :open))

    case answer_list(draft, open) do
      {:error, errors} ->
        {:noreply, refused_answers(socket, draft, errors, nil)}

      {:ok, []} ->
        {:noreply, refused_answers(socket, draft, %{}, :blank)}

      {:ok, answers} ->
        with_attempt(socket, fn attempt ->
          scope = scope(socket)

          case WorkItems.answer(scope, socket.assigns.row, attempt, answers) do
            {:ok, _work_item} ->
              {:noreply, socket |> assign(answers: %{}, errors: %{}, form_error: nil) |> load()}

            {:error, {:invalid, %{} = errors}} ->
              {:noreply, refused_by_id(socket, draft, errors)}

            {:error, {:invalid, :form}} ->
              {:noreply, socket |> refused_answers(draft, %{}, :stale) |> refresh()}

            {:error, _refused} ->
              {:noreply,
               socket |> assign(answers: draft, errors: %{}, form_error: nil) |> refresh()}
          end
        end)
    end
  end

  defp act("confirm", _params, socket) do
    with_attempt(socket, fn attempt ->
      done(socket, WorkItems.confirm(scope(socket), socket.assigns.row, attempt))
    end)
  end

  # Run with comments: the next run, with every open review comment.
  defp act("run_with_comments", _params, socket) do
    with_attempt(socket, fn attempt ->
      done(socket, WorkItems.send_review_comments(scope(socket), socket.assigns.row, attempt))
    end)
  end

  defp act("review_comment", params, socket) do
    text = text_of(params)

    with_attempt(socket, fn attempt ->
      written(
        socket,
        text,
        WorkItems.review_comment(scope(socket), socket.assigns.row, attempt, text)
      )
    end)
  end

  defp act("reply", %{"comment" => id} = params, socket) when is_binary(id) do
    text = text_of(params)

    with_attempt(socket, fn attempt ->
      written(
        socket,
        text,
        WorkItems.reply(scope(socket), socket.assigns.row, attempt, id, text),
        :reply_blank
      )
    end)
  end

  defp act(_event, _params, socket), do: {:noreply, socket}

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
  # adapter, so it runs outside the page's process (`handle_async/3`). The stage runner
  # checks under the work item's lock that it has not ended (`:not_live`).
  defp stage_act("stage_check", params, socket) do
    fresh(socket, params, fn socket, _seen ->
      %{row: row, flow: flow} = socket.assigns
      scope = scope(socket)

      {:noreply,
       socket
       |> assign(:stage_check, :checking)
       |> start_async(:stage_check, fn -> Workflow.check(scope, row, flow) end)}
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
  @doc false
  def refused(:not_earlier, flow), do: not_earlier(flow)

  def refused({:outputs_missing, types}, flow) do
    gettext("Add %{outputs} before you approve %{stage}.",
      outputs: StageComponents.outputs_words(types),
      stage: flow.stage.name
    )
  end

  def refused(:not_approver, flow),
    do: gettext("Ask an approver of %{stage} to act on it.", stage: flow.stage.name)

  def refused(:unknown_stage, _flow),
    do:
      gettext(
        "Choose a stage from the list. The stage you sent is not in the work item's process version."
      )

  def refused(:not_placed, _flow),
    do: gettext("Reload the page. The work item is not in a stage.")

  def refused(:not_found, _flow),
    do: gettext("Reload the page. The work item is not in this workspace any more.")

  def refused({:invalid, :note}, _flow),
    do: gettext("Shorten the note to 4,000 characters or fewer.")

  def refused(_reason, _flow),
    do:
      gettext(
        "Reload the page and act again, and %{contact_support} if it fails again. Qory Apiary could not act on the stage.",
        contact_support: ApiaryWeb.Support.plain(mid_sentence: true)
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
    do: gettext("Reload the page. The work item is closed, so it has no stage to check.")

  defp check_words(_socket, :not_placed),
    do: gettext("Reload the page. The work item is not in a stage, so there is nothing to check.")

  defp check_words(_socket, :exited),
    do:
      rich_gettext(
        "Try again, and %{contact_support} if it fails again. The check of the harness stopped with an error in Qory Apiary.",
        contact_support: ApiaryWeb.Support.rich(mid_sentence: true)
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

  # A review comment or a reply written: back to Explore's tab. A text the check refuses,
  # or a reader who is not an approver of the stage, keeps the draft and says why under
  # the field; `blank` is the word for an empty one.
  defp written(socket, text, result, blank \\ :blank)

  defp written(socket, _text, {:ok, _work_item}, _blank) do
    socket = assign(socket, page_value: "", page_error: nil, asked_page: nil, page: nil)
    {:noreply, push_patch(socket, to: tab_path(scope(socket), socket.assigns.number, :explore))}
  end

  defp written(socket, text, {:error, {:invalid, %{comment: error}}}, blank),
    do: {:noreply, page_refused(socket, text, if(error == :blank, do: blank, else: error))}

  defp written(socket, text, {:error, :not_approver}, _blank),
    do: {:noreply, page_refused(socket, text, :not_approver)}

  defp written(socket, text, {:error, _refused}, _blank),
    do: {:noreply, socket |> assign(page_value: text, page_error: nil) |> refresh()}

  defp page_refused(socket, text, error) do
    socket
    |> assign(page_value: text, page_error: error)
    |> update(:page_submits, &(&1 + 1))
  end

  defp text_of(%{"text" => text}) when is_binary(text), do: text
  defp text_of(_params), do: ""

  # The refusals of `Apiary.WorkItems.answer/4` by question id. A refusal of a field
  # (`:note_required`, `{:too_long, max}`, `:characters`) shows under its question. A
  # question answered or withdrawn since the page drew it, an id or an option it no
  # longer has, is not the reader's error: the page reads the questions again, with the
  # draft kept, and says under the form that no answer was sent (`:stale`).
  defp refused_by_id(socket, draft, errors) do
    fields =
      for {id, error} <- errors, field_error?(error), into: %{}, do: {id, error}

    if map_size(fields) == map_size(errors),
      do: refused_answers(socket, draft, fields, nil),
      else: socket |> refused_answers(draft, fields, :stale) |> refresh()
  end

  defp field_error?(error),
    do: error in [:note_required, :characters] or match?({:too_long, _max}, error)

  defp refused_answers(socket, draft, errors, form_error) do
    socket
    |> assign(answers: draft, errors: errors, form_error: form_error)
    |> update(:submits, &(&1 + 1))
  end

  # The questions form's draft: by question id, each `%{"option" => choice, "note" =>
  # text}` with only text in it.
  defp drafted(params) do
    case params["answers"] do
      %{} = given ->
        for {id, %{} = value} <- given, is_binary(id), into: %{} do
          {id,
           for(
             {field, text} <- value,
             field in ["option", "note"],
             is_binary(text),
             into: %{},
             do: {field, text}
           )}
        end

      _none ->
        %{}
    end
  end

  @doc false
  # answer_list/2 is the answers the form's draft `draft` gives to the open questions
  # `open` (each with `:id` and `:options`), in their order, as
  # `Apiary.WorkItems.answer/4` takes them: `{:ok, [%{"id" => id, "option" => title or
  # nil, "note" => text or nil}]}`. An option picked is its title, with the note where
  # one is written; Give your own option (`"own"`) is a nil option and needs a note; a
  # note alone is a nil option with it. A question with nothing picked and an empty field
  # is left out, and stays open. `{:error, errors}` by question id, `:note_required` for
  # Give your own option with an empty field.
  @spec answer_list(map, [map]) ::
          {:ok, [%{String.t() => String.t() | nil}]} | {:error, %{String.t() => atom}}
  def answer_list(draft, open) when is_map(draft) and is_list(open) do
    checked =
      for %{id: id, options: options} <- open do
        given = Map.get(draft, id, %{})
        note = if blank?(given["note"]), do: nil, else: given["note"]

        case {picked(given["option"], options), note} do
          {:own, nil} -> {:error, id, :note_required}
          {:own, note} -> {:ok, %{"id" => id, "option" => nil, "note" => note}}
          {nil, nil} -> :none
          {nil, note} -> {:ok, %{"id" => id, "option" => nil, "note" => note}}
          {title, note} -> {:ok, %{"id" => id, "option" => title, "note" => note}}
        end
      end

    case for({:error, id, error} <- checked, into: %{}, do: {id, error}) do
      errors when errors == %{} -> {:ok, for({:ok, answer} <- checked, do: answer)}
      errors -> {:error, errors}
    end
  end

  # The option a choice names: `:own`, an option's title by its place from 1, or nil.
  defp picked("own", _options), do: :own

  defp picked(choice, options) when is_binary(choice) do
    case Integer.parse(choice) do
      {n, ""} when n >= 1 -> options |> Enum.at(n - 1) |> then(&(&1 && &1.title))
      _other -> nil
    end
  end

  defp picked(_choice, _options), do: nil

  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank?(_text), do: true

  ## Live

  @impl true
  def handle_info({:work_items_changed, ids}, %{assigns: %{row: %{public_id: id}}} = socket) do
    if is_list(ids) and id in ids,
      do: {:noreply, refresh(socket)},
      else: {:noreply, socket}
  end

  def handle_info({:stage_changed, id}, %{assigns: %{row: %{} = row}} = socket) do
    if socket.assigns.flow && id in [row.id, row.public_id],
      do: {:noreply, refresh(socket)},
      else: {:noreply, socket}
  end

  def handle_info({:artifact_pushed, _work_item_id, _version_id}, socket) do
    if socket.assigns.flow,
      do: {:noreply, refresh(socket)},
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
      # the step card stays beside the stage card, with Undo, the answers and Confirm. Its Confirm approves Explore's gate (`Apiary.WorkItems.confirm/4`), so
      # the stage card offers no second Approve there. A proposal can still wait after the
      # work item left Explore (a gate `none` passes on), so the Confirm gate and the step
      # card are Explore's.
      flow = if Workflow.on?(scope), do: Workflow.page(scope, row)

      flow =
        flow &&
          %{
            flow
            | confirm_gate: flow.at_explore and explore.status == :confirm,
              explore: flow.at_explore and explore.status in @explore_statuses,
              ended: explore.status in [:closed, :undone]
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
          if (explore.status in [:closed, :undone] and names[:ticket_id]) &&
               WorkItems.take_in_again?(row) do
            ~p"/#{scope.organisation}/#{scope.workspace}/backlog?#{[ticket: names[:ticket_id]]}"
          end,
        previous: explore.previous,
        item: page.work_item,
        work_item: row,
        earlier_runs: page.earlier_runs,
        earlier_take_ins: page.earlier_take_ins,
        proposal: page.proposal,
        questions: page.questions,
        questions_version: page.questions_version,
        review_comments: page.review_comments,
        can_review: can_review?(scope, row, explore.status),
        thread: page.thread,
        people: page.people,
        comment_count: WorkItems.count_comments(scope, row),
        can_comment: Comments.can_comment?(scope, row),
        deleting_comment: Comments.still_asking(socket.assigns.deleting_comment, thread),
        can: can(scope, row, explore.status, flow),
        flow: flow,
        artifacts: if(flow, do: Artifacts.list(row), else: [])
      )
      |> form_page()
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
  # stage runner holds an escalation, its card offers Run another round and Close in
  # place of the step card's Run Explore again and Close work item…
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
    live? = status not in [:closed, :undone]

    action =
      case status do
        :questions -> :"work_item.answer"
        :confirm -> :"work_item.confirm"
        status when status in [:no_result, :lost, :cancelled] -> :"work_item.explore_again"
        :used_up -> :"work_item.close"
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

  # Details' Runs under the workflow model, while the newest run waits for a machine and
  # none has started: that run, in place of None yet, counted as the step card counts it.
  defp queued_run(%{runs: [%{shows: :queued} | _]} = flow, %{run: %{attempt: attempt}} = item)
       when is_integer(attempt) do
    case queued_of(flow, item) do
      of when is_integer(of) ->
        gettext("Attempt %{attempt} is queued.", attempt: Format.number(attempt))

      nil ->
        nil
    end
  end

  defp queued_run(_flow, _item), do: nil

  # The most runs of the take in for its latest run. In a loop the runner applies the
  # round limit of the work item's version, the stage card's rounds. The database row of a
  # run queued before the work item moved to a version with fewer rounds keeps the old
  # `of`, so in a loop the count does not use it. Outside a loop the runner caps the runs
  # by the row's `of`, and the count is that `of`. Nil without a run.
  defp queued_of(flow, %{run: %{attempt: attempt, of: of}})
       when is_integer(attempt) and is_integer(of),
       do: runs_of(flow, attempt, of)

  defp queued_of(_flow, _item), do: nil

  defp runs_of(%{rounds: rounds, loop: true} = flow, attempt, _of) when is_integer(rounds),
    do: attempt + max(rounds - (Map.get(flow, :round) || 1), 0)

  defp runs_of(_flow, _attempt, of), do: of

  # At Explore, while its run runs, its questions wait or its gate waits, the step card is
  # the stage's one card, with the stage's state: the stage card is not shown. Explore's
  # status says the same: a run that ended without a result, while the stage still runs,
  # keeps both cards, so the step card says what happened.
  defp one_card?(%{explore: true, state: state}, item),
    do: {state, status(item)} in @one_card

  defp one_card?(_flow, _item), do: false

  # Today's step card, beside the stage card at Explore. At the run limit it says that the
  # run was "the last run of this take in", which is false while the escalation card
  # offers Run another round: there the step card is not shown.
  defp step_card?(nil, _item), do: true
  defp step_card?(%{explore: false}, _item), do: false
  defp step_card?(flow, item), do: not (status(item) == :used_up and escalated?(flow, :used_up))

  defp status(%{status: status}), do: status
  defp status(_item), do: nil

  # The notes above the tabs. At Explore, only the notes that Explore's screen shows
  # nowhere else: a gate decision, a resolved escalation or a failed check. The answers
  # are in the Questions frame, the review comments and replies are cards, and the Runs
  # list and the artifacts are in the history fold.
  defp stage_notes(%{explore: true, notes: notes}),
    do:
      Enum.filter(
        notes,
        &(!&1.comment and &1.kind in [:request_changes, :move, :escalation, :check])
      )

  defp stage_notes(%{notes: notes}), do: notes

  defp escalated?(%{escalation: %{}}, status)
       when status in [:no_result, :lost, :cancelled, :used_up],
       do: true

  defp escalated?(_flow, _status), do: false

  defp scope(socket), do: socket.assigns.current_scope

  # Whether the reader may write review comments and replies now: while no run runs, as
  # `Apiary.WorkItems.Moves.review_comment/4` checks it, with the permission to answer
  # (`work_item.answer`). Whether the reader approves the stage is checked when they send.
  defp can_review?(scope, row, status),
    do: status in @no_run and Access.can?(scope, :"work_item.answer", row)

  defp running?(%{status: status}), do: status in [:queued, :running]
  defp running?(_item), do: false

  defp review_path(scope, number),
    do: tab_path(scope, number, :explore) <> "?" <> URI.encode_query(review: "new")

  defp reply_path(scope, number, id),
    do: tab_path(scope, number, :explore) <> "?" <> URI.encode_query(reply: id)

  defp tab_path(scope, number, :ticket),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}"

  defp tab_path(scope, number, :explore),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}/explore"

  defp tab_path(scope, number, :thread),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}/thread"

  # Add's page for an input of `type`: a person's upload of an artifact
  # (`ApiaryWeb.ArtifactLive`).
  defp add_path(scope, number, type),
    do: ArtifactComponents.new_path(scope, number) <> "?" <> URI.encode_query(type: type)
end
