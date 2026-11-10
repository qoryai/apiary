defmodule ApiaryWeb.WorkItemLive.Show do
  # One work item, by its number in the workspace: its Ticket tab (`:ticket`), Explore's
  # tab (`:explore`) and its Thread (`:thread`). The tabs are live actions of this one
  # LiveView, so a tab is a patch and the header stays. The address with no tab (`:open`)
  # shows the tab the work item opens on (`home/3`), once, when the address loads.
  #
  # **The frame.** The header (`ApiaryWeb.WorkItemComponents.work_item_header/1`, with
  # its stages), the notices under it (the integration's uninstall, the Close question,
  # how it ended), the rail (the step card and Details) and the tabs.
  #
  # **What it reads.** The work item by its number (`Apiary.WorkItems.get_by_number/2`),
  # where Explore stands (`explore/3`), its ticket (`ticket/3`), the names of its ticket
  # (`ticket_names/2`) and whether the Backlog can take it in again (`backlog_off/2`),
  # each with the page's scope; the Thread's events and comments only on the Thread
  # (`thread_entries/3`, the one place they are read). The proposal of an earlier run is
  # read where the reader opens its fold (`"open_fold"`), once, and stored in `texts`.
  # `ApiaryWeb.WorkItemLive.View` turns them into what the components draw. A number that
  # names no work item the reader may read is not found.
  #
  # **A member's comment** on the ticket shows on the Ticket tab with how far its post at
  # the source is (`ApiaryWeb.BacklogComponents.post_state/1`, `post_failure/1`). One not
  # posted has Post again (`"post_again"`, `Apiary.Sources.post_again/2`) for whoever may
  # take the workspace's tickets in; the page reads everything again after it. Post again
  # starts no run, so it opens no dialog.
  #
  # **A test work item** has no ticket and no integration: no Ticket tab (its address
  # patches to Explore's tab), no ticket in the header, Details or the Thread, and no
  # Take in again. Its parts call the line it was made from "the line", where they call
  # a ticket "the ticket".
  #
  # **Live.** The page listens on its workspace's work items
  # (`Apiary.WorkItems.subscribe/1`) and reads everything again when a message names its
  # work item; a work item that moved to another workspace is then not found here. While
  # Explore's run is running, it also listens on that run (`Apiary.Runs.subscribe/2`), and
  # only the dot of that run changes (`follow_run/1`). While the latest run waits in the
  # queue and no pool can take it (`no_pool/2`), the header shows that at any stage, and
  # so do Explore's tab and, where the page has it, the step card for a run of Explore. A
  # later stage's run has no block that shows a queued run, so it has the header's words
  # alone. While pools serve the workspace's runs and none can start the queued run's
  # machine type (`no_fit/3`), the header has the type's name, or the run's key where no
  # type has that key. The page reads everything again when a machine enrols a key on a
  # pool that serves the workspace's runs, or on the gateway such a pool's choice leads to
  # (`listen_to_pools/1`).
  #
  # **What a reader does.** Undo, Close, Run Explore again, Run another round, Confirm,
  # and a reply to a review comment on its form page (`?reply=<id>`), each
  # sent with the work item the page last read and the attempt of its latest run, so an
  # action from a page that read an earlier state fails (`Apiary.WorkItems.Moves`). Run
  # another round, from the questions form or the gate, sends the answers given, the
  # comment on the whole proposal and the open review comments in one move, which starts
  # one run (`Apiary.WorkItems.another_round/4`); the open review comments and the comment
  # go only from a reader who may send review comments (`work_item.review_comment`). With
  # nothing to send it shows under the form that no answer was given. Undo, Close, Run
  # Explore again and Confirm show no words when they fail: the page reads the work item
  # again and draws where it stands now. A send of Run another round or a reply that
  # writes nothing shows why under its form, with the drafts kept
  # (`ApiaryWeb.WorkItemComponents.send_error/1`): the artifact store out of
  # reach, a run of the page's attempt that started first, a work item that changed after
  # the page showed it, which the page reads again (the questions form shows that its
  # questions changed), the reader's access or the work item changed, or any other error.
  # At the run limit the page reads the work item again and shows no line. A form whose
  # fields are wrong shows why under its fields, as does the form page of a reader who is
  # not an approver of the stage. A form page stays open with its draft while a run that
  # started after it opened runs, with that run's line under the field. A reader who may
  # not approve, send or change a decision sees no gate. Where the page has a stage card,
  # Run another round shows the stage runner's line, under the gate or the form, only where
  # the page counted the reader as an approver and the send's `Apiary.Access` check does
  # not: the approver list or the reader's role changed after the page read the work
  # item. With no stage card, no line shows. The questions form's draft is kept as the
  # reader writes (`"answer_draft"`): each question's option and note, and the comment,
  # as the form or the gate has them; so is a form page's text (`"page_draft"`). An event
  # with another number than the page's does nothing.
  #
  # **A spend is confirmed first.** A click that starts a run opens the spend's dialog
  # (`ApiaryWeb.SpendDialog`, `spend/3`) and does nothing else; its Confirm acts, checked
  # again as a click is. Run Explore again and the stage card's Run another round open
  # it on every click; Explore's Run another round opens it where it sends an answer, a
  # comment or the open review comments. Confirm, Approve, Request changes,
  # Accept as it is, Move back and Check again open it only where the stage runner finds
  # that they start a run (`Apiary.Stages.starts/2`), and act at once otherwise.
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

  alias Apiary.{Access, AccessKeys, Artifacts, Edition, Gateways, Processes, Runs, Stages}
  alias Apiary.{WorkItems, WorkspaceSetup}
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.ExploreView
  alias ApiaryWeb.{ArtifactComponents, HarnessComponents, SpendDialog, UserAuth}
  alias ApiaryWeb.WorkItemLive.{Comments, StageComponents, View, Workflow}

  @comment_events Comments.events() -- ["cancel_question"]
  # As on the run's page (`ApiaryWeb.RunLive.Show`).
  @quiet_tick_ms 5_000
  # The stage's state and Explore's status under which the step card is the one card.
  @one_card [
    {:running, :queued},
    {:running, :running},
    {:waiting_answers, :questions},
    {:at_gate, :confirm}
  ]

  @actions ~w(undo ask_close close explore_again answer_draft answer confirm reply page_draft open_fold)
  # The statuses where no run runs, so the page shows Reply and its form page
  # (`can_review?/3`).
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
          (@tab != @home && tab_path(@current_scope, @number, @home))
      }>
        {gettext("Work item #%{number}", number: @number)}
      </:crumb>

      <:crumb :if={@page}>{page_title(@page)}</:crumb>

      <.review_page
        :if={@page}
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
            stage_status={head_status(@flow, @item, @no_pool, @no_fit)}
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
            needs_path={needs_path(@flow, @tab, @current_scope, @number)}
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
            stage_name={if one_card?(@flow, @item), do: @flow.stage.name}
            no_pool={@no_pool}
            commenting={@can.send and @proposal != nil}
            points={waiting_points(@flow)}
            needs_path={needs_path(@flow, @tab, @current_scope, @number)}
          >
            <:badge :if={one_card?(@flow, @item)}>
              <StageComponents.stage_badge page={@flow} quiet={@item[:run][:liveness] == :quiet} />
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
            reading={running?(@item) && !@item.run[:other_stage] && @item.run}
            explore_path={tab_path(@current_scope, @number, :explore)}
            level="h2"
            tip="tooltip-right"
          />
        </:rail>
        <:body>
          <div
            :if={@flow && (!@flow.explore or stage_notes(@flow) != [])}
            id="work-item-flow"
            class="q-wi-flow flex flex-col gap-3"
          >
            <StageComponents.needs_block
              :if={!@flow.explore and needs?(@flow)}
              page={@flow}
              questions={@questions}
              question_path={if @tab != :explore, do: tab_path(@current_scope, @number, :explore)}
              class="mb-3"
            />
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
            post_again={@may_post_again && "post_again"}
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
            can_send={@can.send}
            can_change={@can.change}
            reply_path={@can_review && (&reply_path(@current_scope, @number, &1))}
            backlog_off={@backlog_off}
            answers={@answers}
            comment={@comment}
            errors={@errors}
            form_error={@form_error}
            submits={@submits}
            move_error={@move_error}
            item_noun={@source.item_noun}
            now={@now}
            no_pool={@no_pool}
          >
            <:needs :if={@flow && @flow.explore && needs?(@flow)}>
              <StageComponents.needs_block page={@flow} questions={@questions} />
            </:needs>
            <:artifacts :if={@flow && @flow.explore}>
              <section
                id="work-item-artifacts"
                class="q-xp-sec"
                aria-labelledby="work-item-artifacts-h"
              >
                <h3 id="work-item-artifacts-h" class="q-xp-sec-t">{gettext("Artifacts")}</h3>
                <StageComponents.approval_marks index={@flow.index} />
                <ArtifactComponents.list
                  id="work-item-artifact-list"
                  artifacts={@artifacts}
                  scope={@current_scope}
                  number={@number}
                  add={@flow.can_add}
                  round={false}
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
      <SpendDialog.dialog :if={@spend} spend={@spend} />
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
           home: :ticket,
           asking: nil,
           all_comments: false,
           comment_count: 0,
           answers: %{},
           comment: "",
           errors: %{},
           form_error: nil,
           submits: 0,
           page: nil,
           asked_page: nil,
           page_value: "",
           page_error: nil,
           page_submits: 0,
           proposal: nil,
           texts: %{},
           questions: [],
           questions_version: nil,
           review_comments: [],
           can_review: false,
           flow: nil,
           artifacts: [],
           stage_asking: nil,
           stage_error: nil,
           stage_check: nil,
           stage_notice: nil,
           move_error: nil,
           followed_run: nil,
           quiet_timer: nil,
           no_pool: nil,
           no_fit: nil,
           pool_listened: MapSet.new(),
           spend: nil,
           may_post_again: Access.can?(scope, :"work_item.take_in", scope.workspace)
         )}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(tab: socket.assigns.live_action, move_error: nil, form_error: nil, errors: %{})
     |> ask_page(asked_page(socket.assigns.live_action, params))
     |> load()
     |> opened()
     |> ticketed()}
  end

  # The form page of an address on Explore's tab: `?reply=<id>` for Reply to that review
  # comment; nil for none.
  defp asked_page(:explore, %{"reply" => id}) when is_binary(id), do: {:reply, id}
  defp asked_page(_tab, _params), do: nil

  # Another form page than the one shown before starts with an empty field and no error.
  defp ask_page(%{assigns: %{asked_page: page}} = socket, page), do: socket

  defp ask_page(socket, page),
    do:
      assign(socket,
        asked_page: page,
        page: nil,
        page_value: "",
        page_error: nil,
        page_submits: 0
      )

  # The form page as the work item stands: one the reader may use now, else none, and
  # the address patches back to Explore's tab. A form page already open stays open with
  # its draft for a reader who may still write: while a run runs, with the line that the
  # run started first under the field (`{:running, run}`). After a confirm, a close or an
  # undo, it stays open with the line that nothing can be sent (`:changed`). Once the
  # reader can send again, that line goes.
  defp form_page(%{assigns: %{asked_page: nil}} = socket), do: assign(socket, :page, nil)

  defp form_page(%{assigns: %{can_review: false, page: {_kind, _comment}}} = socket) do
    %{item: item, row: row} = socket.assigns

    case item do
      %{status: status, run: %{attempt: _attempt} = run} when status in [:queued, :running] ->
        if Access.can?(scope(socket), :"work_item.review_comment", row),
          do: socket |> assign(:page_error, {:running, run}) |> open_page(),
          else: back(socket)

      # `can_review` is false at these statuses only where the reader lost the right.
      %{status: status} when status in @no_run ->
        back(socket)

      # A confirm moves the work item on, where the next stage may list other approvers,
      # so the reader's right at that stage does not decide this line.
      _other ->
        assign(socket, :page_error, :changed)
    end
  end

  defp form_page(%{assigns: %{can_review: false}} = socket), do: back(socket)

  defp form_page(%{assigns: %{page_error: {:running, _run}}} = socket),
    do: socket |> assign(:page_error, nil) |> open_page()

  defp form_page(%{assigns: %{page_error: :changed}} = socket),
    do: socket |> assign(:page_error, nil) |> open_page()

  defp form_page(socket), do: open_page(socket)

  defp open_page(%{assigns: %{asked_page: {:reply, id}}} = socket) do
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

  defp page_title({:reply, _comment}), do: gettext("Reply")

  # The address with no tab shows the tab the work item opens on. A later read leaves the
  # tab as it is, so a work item that leaves Explore does not move the reader.
  defp opened(%{assigns: %{tab: :open, home: home}} = socket), do: assign(socket, :tab, home)
  defp opened(socket), do: socket

  # A test work item has no Ticket tab: its address is Explore's tab.
  defp ticketed(%{assigns: %{row: %{test: true}, live_action: action}} = socket)
       when action in [:open, :ticket],
       do: push_patch(socket, to: tab_path(scope(socket), socket.assigns.number, :explore))

  defp ticketed(socket), do: socket

  # The tab the work item opens on: Explore's for a test work item, which has no ticket,
  # and for an open work item whose current stage is Explore; else the Ticket tab. With a
  # stage card, the tab depends on the stage, whatever Explore's status: a moved-back work
  # item has a confirmation, so its status is `:shape`. With none, a work item with no
  # stage is at Explore too (`at_explore?/2`), so the tab depends on the status as well.
  defp home(%{test: true}, _status, _flow), do: :explore

  defp home(_row, status, %{at_explore: at_explore}) do
    if at_explore and status not in [:closed, :undone], do: :explore, else: :ticket
  end

  defp home(row, status, nil) do
    if status in @explore_statuses and at_explore?(row, nil), do: :explore, else: :ticket
  end

  ## What a reader does

  @impl true
  def handle_event("cancel_question", _params, socket),
    do:
      {:noreply,
       assign(socket, asking: nil, deleting_comment: nil, stage_asking: nil, stage_error: nil)}

  def handle_event(event, params, socket) when event in @comment_events,
    do: Comments.handle_event(event, params, socket)

  def handle_event(event, %{"number" => _number} = params, socket) when event in @actions,
    do: action(event, params, socket, :ask)

  def handle_event(event, %{"number" => _number} = params, socket) when event in @stage_events,
    do: stage_action(event, params, socket, :ask)

  # Confirm in the spend's dialog: the action of the click that opened it, with the
  # dialog's note, checked again as a click is (`ApiaryWeb.SpendDialog`).
  def handle_event("spend_confirm", params, socket) do
    case SpendDialog.take(socket.assigns.spend, params) do
      nil ->
        {:noreply, socket}

      {event, params} when event in @actions ->
        action(event, params, assign(socket, :spend, nil), :act)

      {event, params} ->
        stage_action(event, params, assign(socket, :spend, nil), :act)
    end
  end

  def handle_event("spend_cancel", _params, socket), do: {:noreply, assign(socket, :spend, nil)}

  def handle_event("show_earlier_comments", _params, socket),
    do: {:noreply, socket |> assign(:all_comments, true) |> load()}

  # Post again on a member's comment not posted: the page read again; for a person who may
  # not take tickets in, who may, in a flash. A comment posted or gone meanwhile shows as
  # it is.
  def handle_event("post_again", %{"comment" => comment_id}, socket)
      when is_binary(comment_id) do
    scope = scope(socket)

    case Apiary.Sources.post_again(scope, comment_id) do
      {:error, :forbidden} ->
        {:noreply,
         socket
         |> put_flash(:error, ApiaryWeb.BacklogComponents.take_in_who_may(scope))
         |> load()}

      _posting_or_not ->
        {:noreply, load(socket)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # An action of the page, with `:ask` from a click: where it starts a run, the spend's
  # dialog opens and nothing else happens (`spend/3`); with `:act`, from the dialog's
  # Confirm, it acts.
  defp action(event, %{"number" => number} = params, socket, mode) do
    # While the stage runner holds an escalation, Run another round on its card runs
    # Explore again.
    held? =
      event == "explore_again" and
        escalated?(socket.assigns[:flow], status(socket.assigns[:item]))

    if number == Integer.to_string(socket.assigns.number) and not held?,
      do: ask_or(mode, event, params, assign(socket, :move_error, nil), &act/3),
      else: {:noreply, socket}
  end

  defp action(_event, _params, socket, _mode), do: {:noreply, socket}

  defp stage_action(event, %{"number" => number} = params, socket, mode) do
    if number == Integer.to_string(socket.assigns.number) and socket.assigns.flow,
      do: ask_or(mode, event, params, socket, &stage_act/3),
      else: {:noreply, socket}
  end

  defp stage_action(_event, _params, socket, _mode), do: {:noreply, socket}

  defp ask_or(:act, event, params, socket, act), do: act.(event, params, socket)

  defp ask_or(:ask, event, params, socket, act) do
    case spend(event, params, socket) do
      nil -> act.(event, params, socket)
      spend -> {:noreply, socket |> kept(event, params) |> assign(:spend, spend)}
    end
  end

  # The answers and the comment as the click sent them, kept while the dialog is open.
  defp kept(socket, "answer", params), do: drafts(socket, params)
  defp kept(socket, _event, _params), do: socket

  ## The spends

  # The dialog a click of `event` opens before it acts, or nil where the click starts no
  # run. Run Explore again and the stage card's Run another round start one on every
  # click, and Explore's Run another round where it sends something (`round_sends?/3`).
  # Confirm, Approve, Request changes, Accept as it is, Move back and Check again start
  # one where the stage they enter or run again starts a run, as the stage runner finds
  # it at the click (`Apiary.Stages.starts/2`): a stage with no workflow starts none. A
  # click that acts on nothing, as a questions form with an error, opens none.
  defp spend("explore_again", params, socket) do
    SpendDialog.ask("explore_again", params,
      title: gettext("Run Explore again?"),
      action: gettext("Run Explore again"),
      line: run_line(socket, :next_run),
      return_to: "work-item-step-again"
    )
  end

  defp spend("answer", params, socket) do
    if round_sends?(socket, drafted(params), comment_of(params)) do
      SpendDialog.ask("answer", params,
        title: gettext("Run another round?"),
        action: gettext("Run another round"),
        line: run_line(socket, :next_run),
        return_to:
          if(status(socket.assigns.item) == :confirm,
            do: "work-item-explore-gate-send",
            else: "work-item-explore-questions-go"
          )
      )
    end
  end

  defp spend("confirm", params, socket) do
    ask_if_run("confirm", params, socket, :approve,
      title: gettext("Confirm?"),
      action: gettext("Confirm"),
      return_to: "work-item-explore-gate-go"
    )
  end

  # A click on a stage the work item has left opens none: the act shows the notice.
  defp spend(event, params, socket) when event in @stage_events do
    seen = text(params["seen"])

    if seen == current_stage(socket) and Stages.at_stage?(socket.assigns.row, seen),
      do: stage_spend(event, params, socket)
  end

  defp spend(_event, _params, _socket), do: nil

  defp stage_spend("stage_approve", params, socket) do
    stage = socket.assigns.flow.stage.name

    ask_if_run("stage_approve", params, socket, :approve,
      title: gettext("Approve %{stage}?", stage: stage),
      action: gettext("Approve %{stage}", stage: stage),
      return_to: "work-item-stage-gate-approve-go"
    )
  end

  defp stage_spend("stage_request_changes", params, socket) do
    if note(params) do
      ask_if_run("stage_request_changes", params, socket, :request_changes,
        title: gettext("Request changes?"),
        action: gettext("Request changes"),
        return_to: "work-item-stage-gate-changes-go",
        note: [optional: false]
      )
    end
  end

  defp stage_spend("stage_resolve", %{"how" => "accept"} = params, socket) do
    ask_if_run("stage_resolve", params, socket, :accept,
      title: gettext("Accept as it is?"),
      action: gettext("Accept as it is"),
      return_to: "work-item-stage-escalation-accept",
      note: escalation_note()
    )
  end

  defp stage_spend("stage_resolve", %{"how" => "another_round"} = params, socket) do
    SpendDialog.ask("stage_resolve", params,
      title: gettext("Run another round?"),
      action: gettext("Run another round"),
      line: run_line(socket, :another_round),
      return_to: "work-item-stage-escalation-another",
      note: escalation_note()
    )
  end

  defp stage_spend("stage_resolve", %{"how" => "move_back", "stage" => stage} = params, socket)
       when is_binary(stage) do
    ask_if_run("stage_resolve", params, socket, {:move, stage},
      title: gettext("Move back?"),
      action: gettext("Move back"),
      return_to: "work-item-stage-escalation-move",
      note: escalation_note()
    )
  end

  defp stage_spend("stage_move", %{"stage" => stage} = params, socket) when is_binary(stage) do
    ask_if_run("stage_move", params, socket, {:move, stage},
      title: gettext("Move back?"),
      action: gettext("Move back"),
      return_to: "work-item-stage-move-go",
      note: []
    )
  end

  defp stage_spend("stage_check", params, socket) do
    words =
      if match?({:failed, _message}, socket.assigns.stage_check),
        do: {gettext("Try again?"), gettext("Try again")},
        else: {gettext("Check again?"), gettext("Check again")}

    ask_if_run("stage_check", params, socket, :found,
      title: elem(words, 0),
      action: elem(words, 1),
      return_to: "work-item-stage-check-go"
    )
  end

  defp stage_spend(_event, _params, _socket), do: nil

  # The note of the escalation card, which goes to the next run.
  defp escalation_note,
    do: [hint: gettext("A note you add goes to the next run as work item data.")]

  # The dialog of `event` where `act` starts a run, named by its workflow; else nil.
  defp ask_if_run(event, params, socket, act, opts) do
    case Stages.starts(socket.assigns.row, act) do
      {:run, workflow} ->
        line = SpendDialog.run_line({:workflow, workflow}, scope(socket).workspace)
        SpendDialog.ask(event, params, [line: line] ++ opts)

      :none ->
        nil
    end
  end

  # What `act` starts: a run of its workflow where the stage runner finds it, else the
  # next run of the work item's stage, or of Explore with no stage.
  defp run_line(socket, act) do
    what =
      case Stages.starts(socket.assigns.row, act) do
        {:run, workflow} -> {:workflow, workflow}
        :none -> {:stage, stage_now(socket.assigns.flow)}
      end

    SpendDialog.run_line(what, scope(socket).workspace)
  end

  defp stage_now(%{stage: %{name: name}}) when is_binary(name), do: name
  defp stage_now(_flow), do: gettext("Explore")

  # Whether Run another round sends anything: an answer, a changed decision, the
  # comment, or, with none, the open review comments (`comments_only?/1`).
  defp round_sends?(socket, draft, comment) do
    case draft_answers(socket, draft) do
      {:ok, [_ | _]} -> true
      {:ok, []} -> comment != nil or comments_only?(socket)
      {:error, _errors} -> false
    end
  end

  defp draft_answers(socket, draft) do
    answers(
      draft,
      socket.assigns.questions,
      status(socket.assigns.item),
      socket.assigns.can.change
    )
  end

  @doc false
  # answers/4 is the answers the page sends for `draft`, Run another round's draft
  # (`answer_list/2`). It reads the draft for these questions: the open questions, only
  # where the questions wait (`status` `:questions`), and the decided questions, where
  # the questions or the proposal wait (`:confirm`), for a reader who may change them
  # (`can_change`, `can/4`). `answer_list/2` keeps a decided question only where the
  # draft changes it.
  @spec answers(map, [map], atom, boolean) ::
          {:ok, [%{String.t() => String.t() | nil}]} | {:error, %{String.t() => atom}}
  def answers(draft, questions, status, can_change) do
    open = if status == :questions, do: Enum.filter(questions, &(&1.state == :open)), else: []

    decided =
      if status in [:questions, :confirm] and can_change,
        do: Enum.filter(questions, &decided?/1),
        else: []

    answer_list(draft, open ++ decided)
  end

  defp comments_only?(socket),
    do:
      socket.assigns.can.send and
        Enum.any?(socket.assigns.review_comments, &(&1.state == :open))

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

  # The questions form, or the gate's comment, as the reader changes it.
  defp act("answer_draft", params, socket), do: {:noreply, drafts(socket, params)}

  # Run another round, from the questions form or the gate: in one move
  # (`Apiary.WorkItems.another_round/4`), the answers given, each question with an
  # option, Give your own option, or a note, and the comment on the whole proposal; the
  # next run reads them with every open review comment. A question with neither stays
  # open. With no answer and no comment, the open review comments go alone, where the
  # reader may send them (`work_item.review_comment`, `can/4`); under the questions, with
  # none open, or for any other reader, nothing is sent; at the gate the move refuses it.
  defp act("answer", params, socket) do
    draft = drafted(params)
    comment = comment_of(params)
    socket = assign(socket, :comment, params["comment"] || socket.assigns.comment)

    case draft_answers(socket, draft) do
      {:error, errors} ->
        {:noreply, refused_answers(socket, draft, errors, nil)}

      {:ok, []} when comment == nil ->
        if status(socket.assigns.item) == :questions and not comments_only?(socket),
          do: blank_round(socket, draft),
          else: another_round(socket, draft, [], nil)

      {:ok, answers} ->
        another_round(socket, draft, answers, comment)
    end
  end

  # Approve is disabled while a changed decision is a draft; a click that reaches the
  # page then does nothing.
  defp act("confirm", _params, socket) do
    if changed_decision?(socket),
      do: {:noreply, socket},
      else: confirm(socket)
  end

  # A reply goes to the review comment of the open Reply page; a `"reply"` with the id of
  # any other review comment, or with no Reply page open, changes nothing.
  defp act("reply", %{"comment" => id} = params, socket) when is_binary(id) do
    case socket.assigns.page do
      {:reply, %{id: ^id}} ->
        text = text_of(params)

        with_attempt(socket, fn attempt ->
          written(
            socket,
            text,
            WorkItems.reply(scope(socket), socket.assigns.row, attempt, id, text)
          )
        end)

      _other ->
        {:noreply, socket}
    end
  end

  # A fold opened whose proposal the page has not read: an earlier run's in the fold of
  # the runs (`version`), or the runs' of an earlier take in (`take_in`, its place from
  # 1). For a reader who may still read the work item (`work_item.read`), the page reads
  # each such version (`Apiary.WorkItems.ExploreView.proposals/2`), stores what it read in
  # `texts`, and draws the runs again from the Explore it read last (`folds/1`), with no
  # other read; a version whose read found no text (nil in `texts`) is read again at the
  # next open. A fold with none unread does nothing. A reader who may not read the work
  # item is sent away, as when the page reads it again (`gone/1`).
  defp act("open_fold", params, socket) do
    %{row: row, texts: texts} = socket.assigns

    case Enum.reject(unread(socket.assigns, params), &is_map(texts[&1])) do
      [] ->
        {:noreply, socket}

      versions ->
        if Access.authorize(scope(socket), :"work_item.read", row) == :ok do
          read = ExploreView.proposals(row, versions)
          {:noreply, socket |> assign(:texts, Map.merge(texts, read)) |> folds()}
        else
          {:noreply, gone(socket)}
        end
    end
  end

  # A reply as the reader writes it, on its form page.
  defp act("page_draft", params, socket),
    do: {:noreply, assign(socket, :page_value, text_of(params))}

  defp act(_event, _params, socket), do: {:noreply, socket}

  defp confirm(socket) do
    with_attempt(socket, fn attempt ->
      done(socket, WorkItems.confirm(scope(socket), socket.assigns.row, attempt))
    end)
  end

  defp changed_decision?(socket) do
    socket.assigns.can.change and
      Enum.any?(
        socket.assigns.questions,
        &decision_changed?(&1, socket.assigns.answers[&1.id])
      )
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
  # adapter, so it runs outside the page's process (`handle_async/3`). The stage runner
  # checks under the work item's lock that it has not ended (`:not_live`).
  defp stage_act("stage_check", params, socket) do
    fresh(socket, params, fn socket, _seen ->
      row = socket.assigns.row
      scope = scope(socket)

      {:noreply,
       socket
       |> assign(:stage_check, :checking)
       |> start_async(:stage_check, fn -> Workflow.check(scope, row) end)}
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

  # Run another round, at the gate or under the questions, where the page counted the
  # reader as an approver (`can/4`) and the send's `Apiary.Access`
  # check does not, as when the approver list or the reader's role changed after the page
  # read the work item: the page read again, with the stage runner's line for that error
  # (`refused/2`) under the gate or the questions form, where the page has a stage card
  # (`flow`); with none, no line shows. A reader who may not approve, send or change a
  # decision sees no gate.
  defp not_approver(socket) do
    socket = refresh(socket)

    case {socket.redirected, socket.assigns.flow} do
      {redirected, %{stage: %{name: name}} = flow}
      when redirected in [nil, false] and is_binary(name) ->
        assign(socket, :move_error, refused(:not_approver, flow))

      _redirected_or_none ->
        socket
    end
  end

  # A send of Run another round that wrote nothing, for `reason`: the line for it under
  # the gate or the questions form (`move_error`, `send_error/1`),
  # and the questions form's `draft` kept (nil for none). The page keeps what it drew for
  # an artifact store out of reach (`:store_unavailable`), where reading the work item
  # again would need the store; for a run of the page's attempt that started first
  # (`:running`), whose start the page reads on its next change; and for any other error.
  # A work item that changed after the page showed it (`:stale`, `:not_waiting`) is read
  # again. Where the reader's access or the work item changed (`:forbidden`, `:not_found`,
  # `:not_live`), the scope is read again, as after any refusal. At the run limit
  # (`:used_up`) the page reads the work item again and shows no line.
  defp refused_send(socket, draft, reason) do
    socket =
      if draft, do: assign(socket, answers: draft, errors: %{}, form_error: nil), else: socket

    case reason do
      :used_up ->
        refresh(socket)

      reason when reason in [:stale, :not_waiting] ->
        refresh(socket, &assign(&1, :move_error, send_error(reason)))

      reason when reason in [:forbidden, :not_found, :not_live] ->
        socket |> UserAuth.reload_scope() |> assign(:move_error, send_error(reason))

      :running ->
        assign(socket, :move_error, send_error({:running, socket.assigns.item.run}))

      reason ->
        assign(socket, :move_error, send_error(reason))
    end
  end

  # Run another round's move, with the answers and the comment (nil for none); the
  # drafts stay where it writes nothing. A refused comment shows its line under the
  # form or the gate, a refused answer under its question. Where answers were sent, a
  # refusal of the form or a work item that changed shows that the questions changed;
  # without answers, a refusal shows as `refused_send/3` words it.
  defp another_round(socket, draft, answers, comment) do
    with_attempt(socket, fn attempt ->
      round = %{answers: answers, comment: comment}

      case WorkItems.another_round(scope(socket), socket.assigns.row, attempt, round) do
        {:ok, _work_item} ->
          {:noreply,
           socket |> assign(answers: %{}, comment: "", errors: %{}, form_error: nil) |> load()}

        {:error, {:invalid, %{comment: error}}} ->
          {:noreply,
           socket
           |> assign(answers: draft, errors: %{}, form_error: nil)
           |> assign(:move_error, comment_error(error, :comment))}

        {:error, {:invalid, %{} = errors}} ->
          {:noreply, refused_by_id(socket, draft, errors)}

        {:error, :not_approver} ->
          {:noreply,
           socket |> assign(answers: draft, errors: %{}, form_error: nil) |> not_approver()}

        {:error, reason}
        when answers != [] and reason in [{:invalid, :form}, :stale, :not_waiting] ->
          {:noreply, socket |> refused_answers(draft, %{}, :stale) |> refresh()}

        {:error, reason} ->
          {:noreply, refused_send(socket, draft, reason)}
      end
    end)
  end

  # Run another round with nothing to send: the line under the questions form.
  defp blank_round(socket, draft), do: {:noreply, refused_answers(socket, draft, %{}, :blank)}

  # The drafts of the questions form and of the comment, as the reader changes them.
  defp drafts(socket, params) do
    socket
    |> assign(:answers, drafted(params))
    |> assign(:comment, if(is_binary(params["comment"]), do: params["comment"], else: ""))
  end

  # The comment on the whole proposal as the form sent it; nil for none or a blank one.
  defp comment_of(params), do: text(params["comment"])

  # A reply written: back to Explore's tab. Otherwise the draft stays in the field, with
  # why under it: a text that fails the check (`:reply_blank` for an empty one), a reader
  # who is not an approver of the stage, and the refusals of `refused_send/3`, read again
  # as there. At the run limit (`:used_up`) no line shows.
  defp written(socket, _text, {:ok, _work_item}) do
    socket = assign(socket, page_value: "", page_error: nil, asked_page: nil, page: nil)
    {:noreply, push_patch(socket, to: tab_path(scope(socket), socket.assigns.number, :explore))}
  end

  defp written(socket, text, {:error, {:invalid, %{comment: error}}}),
    do: {:noreply, page_refused(socket, text, if(error == :blank, do: :reply_blank, else: error))}

  # On a form page kept after a confirm (`:changed`), the Copy line stays: at that status
  # an approver's send is refused too. No read again here: at a status in `@no_run` it
  # would go back to the tab and lose the text.
  defp written(%{assigns: %{page_error: :changed}} = socket, text, {:error, :not_approver}),
    do: {:noreply, page_refused(socket, text, :changed)}

  defp written(socket, text, {:error, :not_approver}),
    do: {:noreply, page_refused(socket, text, :not_approver)}

  defp written(socket, text, {:error, :store_unavailable}),
    do: {:noreply, page_refused(socket, text, :store_unavailable)}

  defp written(socket, text, {:error, :running}),
    do: {:noreply, page_refused(socket, text, {:running, socket.assigns.item.run})}

  defp written(socket, text, {:error, :used_up}),
    do: {:noreply, socket |> assign(page_value: text, page_error: nil) |> refresh()}

  defp written(socket, text, {:error, reason}) when reason in [:stale, :not_waiting],
    do: {:noreply, socket |> page_refused(text, :stale) |> refresh()}

  # The page reads the work item again, so the open form page has the line that nothing
  # can be sent, which a reload would lose with the text.
  defp written(socket, text, {:error, :not_live}) do
    {:noreply, socket |> UserAuth.reload_scope() |> page_refused(text, :not_live) |> refresh()}
  end

  defp written(socket, text, {:error, reason}) when reason in [:forbidden, :not_found],
    do: {:noreply, socket |> UserAuth.reload_scope() |> page_refused(text, reason)}

  defp written(socket, text, {:error, _refused}),
    do: {:noreply, page_refused(socket, text, :not_saved)}

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
  # draft kept, and shows under the form that no answer was sent (`:stale`).
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

  # The versions of the proposals the page left unread in the fold of `params`, as the
  # page drew it: an earlier run's (`"version"`), or those of an earlier take in's runs
  # (`"take_in"`, its place from 1). A version the page does not show is left out.
  defp unread(assigns, %{"version" => version}) do
    with {number, ""} <- Integer.parse(version),
         true <- Enum.any?(assigns.earlier_runs, &(unread_of(&1[:wrote_proposal]) == number)) do
      [number]
    else
      _none -> []
    end
  end

  defp unread(assigns, %{"take_in" => place}) do
    with {n, ""} when n >= 1 <- Integer.parse(place),
         %{runs: runs} <- Enum.at(assigns.earlier_take_ins, n - 1) do
      runs |> Enum.map(&unread_of(&1[:proposal])) |> Enum.filter(&is_integer/1) |> Enum.uniq()
    else
      _none -> []
    end
  end

  defp unread(_assigns, _params), do: []

  defp unread_of(%{unread: number}), do: number
  defp unread_of(_proposal), do: nil

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
  # answer_list/2 is the answers in the form's draft `draft` to the open questions
  # `open` (each with `:id` and `:options`), in their order, as
  # `Apiary.WorkItems.answer/4` takes them: `{:ok, [%{"id" => id, "option" => title or
  # nil, "note" => text or nil}]}`. An option picked is its title, with the note where
  # one is written; Give your own option (`"own"`) is a nil option and needs a note; a
  # note alone is a nil option with it. A question with nothing picked and an empty field
  # is left out, and stays open. A decided question (with a `:decision`) is left out
  # where the draft does not change it: the run's option, or nothing, picked, and an
  # empty field (`ApiaryWeb.WorkItemComponents.decision_changed?/2`). `{:error, errors}`
  # by question id, `:note_required` for Give your own option with an empty field.
  @spec answer_list(map, [map]) ::
          {:ok, [%{String.t() => String.t() | nil}]} | {:error, %{String.t() => atom}}
  def answer_list(draft, open) when is_map(draft) and is_list(open) do
    checked =
      for %{id: id, options: options} = question <- open,
          not decided?(question) or decision_changed?(question, draft[id]) do
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

  defp decided?(question), do: question[:state] == :decided and question[:decision] != nil

  # The option of a choice: `:own`, an option's title by its place from 1, or nil.
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
      do: {:noreply, changed(socket)},
      else: {:noreply, socket}
  end

  def handle_info({:stage_changed, id}, %{assigns: %{row: %{} = row}} = socket) do
    if socket.assigns.flow && id in [row.id, row.public_id],
      do: {:noreply, changed(socket)},
      else: {:noreply, socket}
  end

  def handle_info({:artifact_pushed, _work_item_id, _version_id}, socket) do
    if socket.assigns.flow,
      do: {:noreply, changed(socket)},
      else: {:noreply, socket}
  end

  # A machine enrolled a key on a pool that serves the workspace's runs, or on its
  # gateway, while no pool could take the queued run.
  def handle_info({:key_enrolled, %{node_id: _node_id}}, socket) do
    if socket.assigns.no_pool,
      do: {:noreply, changed(socket)},
      else: {:noreply, socket}
  end

  def handle_info(:quiet_tick, socket),
    do: {:noreply, socket |> show_liveness() |> quiet_timer()}

  def handle_info(
        {:run_changed, %Run{id: id} = run},
        %{assigns: %{followed_run: %{id: id}}} = socket
      ),
      do: {:noreply, heard_from(socket, run)}

  def handle_info(
        {:run_projected, %Run{id: id} = run, _first, _last},
        %{assigns: %{followed_run: %{id: id}}} = socket
      ),
      do: {:noreply, heard_from(socket, run)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # The page read again after the work item changed elsewhere, without the line of the
  # last move that was not made (`move_error`): that line is about the page before. The
  # errors under the questions form (`form_error`, `errors`) are cleared only where the
  # read changed the form's questions or run (`form_of/1`). After a read that left them
  # as they were, the page shows a refused send's error again: the line that no answer
  # was sent, where the message of the other member's answer comes after the send, and
  # a field error, after a Thread comment. The form's draft stays.
  defp changed(socket) do
    before = form_of(socket)
    socket = socket |> assign(:move_error, nil) |> refresh()

    if socket.redirected in [nil, false] and form_of(socket) != before,
      do: assign(socket, form_error: nil, errors: %{}),
      else: socket
  end

  # What the questions form belongs to: the newest questions' version, and the take in
  # and attempt of the latest run.
  defp form_of(%{assigns: assigns}) do
    {assigns[:questions_version], assigns[:row] && assigns.row.take_in,
     get_in(assigns, [:item, :run, :attempt])}
  end

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
  # here: the page's tab loads again, and is then not found.
  defp load(socket) do
    scope = scope(socket)
    now = DateTime.utc_now()
    comments = if socket.assigns.all_comments, do: :all, else: :latest

    with %{} = row <- WorkItems.get_by_number(scope, socket.assigns.number),
         row = with_version(row, scope),
         %{} = read <- WorkItems.explore(scope, row, now),
         explore = ExploreView.with_proposals(read, socket.assigns.texts),
         %{} = source <- WorkItems.ticket(scope, row, comments) do
      names = Map.get(WorkItems.ticket_names(scope, [row]), row.id, %{})
      thread = if socket.assigns.tab == :thread, do: thread_entries(scope, row, now), else: []
      # Explore runs as before the workflow model: while the work item is at Explore,
      # the step card has Undo, the answers and Confirm, beside the stage card, or as the
      # stage's one card in the states of `@one_card`. Its Confirm approves Explore's gate
      # (`Apiary.WorkItems.confirm/4`), so the stage card offers no second Approve there.
      # A proposal can still wait after the work item left Explore (a gate `none` passes
      # on), so the Confirm gate and the step card are Explore's.
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
      confirmers = confirmers(scope, row, flow)

      waits_at_confirm =
        explore.status == :confirm and at_explore?(row, flow) and
          not escalated?(flow, :confirm)

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
        home: home(row, explore.status, flow),
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
        explore: read,
        names: names,
        item:
          page.work_item
          |> with_confirmers(confirmers)
          |> Map.put(
            :taken_in_comment,
            explore.status == :queued and WorkItems.taken_in_comment?(scope, row)
          ),
        work_item: row,
        earlier_runs: page.earlier_runs,
        earlier_take_ins: page.earlier_take_ins,
        proposal: page.proposal,
        questions: page.questions,
        questions_version: page.questions_version,
        review_comments: page.review_comments,
        can_review: can_review?(scope, row, explore.status),
        thread: thread_lines(page.thread, waits_at_confirm, confirmers),
        people: page.people,
        comment_count: WorkItems.count_comments(scope, row),
        can_comment: Comments.can_comment?(scope, row),
        deleting_comment: Comments.still_asking(socket.assigns.deleting_comment, thread),
        can: can(scope, row, explore.status, flow),
        flow: flow,
        artifacts: if(flow, do: Artifacts.list(row), else: []),
        no_pool: no_pool(scope, page.work_item),
        no_fit: no_fit(scope, row, page.work_item)
      )
      |> form_page()
      |> follow_run()
      |> listen_to_pools()
    else
      _gone -> gone(socket)
    end
  end

  # The dot of the page's Explore run, by the way of the run's page: its row arrives with
  # each message of the run's topic, heartbeats included, and quiet is recomputed from that
  # row on a timer. A tick runs no query. A run with a `pending` row is followed for the
  # message that it started, with no timer and no read. Any other run is not followed, and
  # neither is a run of another workspace, because the scope has no topic for it.
  defp follow_run(socket) do
    old = socket.assigns.followed_run
    new = if connected?(socket), do: followable(socket)
    socket = assign(socket, :followed_run, new)

    if old && (is_nil(new) || old.id != new.id), do: Runs.unsubscribe(scope(socket), run_of(old))

    if new && (is_nil(old) || old.id != new.id),
      do: subscribed_to(socket, new),
      else: quiet_timer(socket)
  end

  defp followable(socket) do
    heard = View.live_heard(socket.assigns.item[:run])
    if heard && heard.workspace_id == scope(socket).workspace.id, do: heard
  end

  # Subscribed before the read, so a heartbeat after `load/1` read the row is not missed.
  defp subscribed_to(socket, heard) do
    scope = scope(socket)
    Runs.subscribe(scope, run_of(heard))

    if heard.state == "running",
      do: heard_from(socket, Runs.get_run!(scope, heard.id)),
      else: quiet_timer(socket)
  end

  defp run_of(heard), do: %Run{id: heard.id, workspace_id: heard.workspace_id}

  defp heard_from(socket, %Run{} = run) do
    socket
    |> assign(:followed_run, ExploreView.heard(run))
    |> show_liveness()
    |> quiet_timer()
  end

  # The item changes only when the dot does, so a heartbeat or a tick draws nothing else.
  defp show_liveness(%{assigns: %{followed_run: %{} = heard, item: %{run: run} = item}} = socket) do
    liveness = View.liveness_of(heard)

    if liveness == run.liveness,
      do: socket,
      else: assign(socket, :item, %{item | run: %{run | heard: heard, liveness: liveness}})
  end

  defp show_liveness(socket), do: socket

  # One timer at most, and none unless the followed run is running.
  defp quiet_timer(socket) do
    if timer = socket.assigns.quiet_timer, do: Process.cancel_timer(timer)

    timer =
      if match?(%{state: "running"}, socket.assigns.followed_run),
        do: Process.send_after(self(), :quiet_tick, @quiet_tick_ms)

    assign(socket, :quiet_timer, timer)
  end

  # A work item no longer readable here: the page's tab loads again, and is then not
  # found.
  defp gone(socket) do
    socket
    |> assign(:row, nil)
    |> push_navigate(to: tab_path(scope(socket), socket.assigns.number, socket.assigns.tab))
  end

  # The runs of the Explore tab drawn again with the proposals of `texts`, from the
  # Explore that `load/1` read last (`explore`): no store read and no read of Explore.
  # `ApiaryWeb.WorkItemLive.View.page/5` reads the people and the workspaces of the runs.
  defp folds(socket) do
    %{explore: read, texts: texts, row: row, names: names} = socket.assigns
    page = View.page(scope(socket), row, ExploreView.with_proposals(read, texts), [], names)
    assign(socket, earlier_runs: page.earlier_runs, earlier_take_ins: page.earlier_take_ins)
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
  # The head's status: while no pool can take the queued run, that, at Explore and at a
  # later stage alike; while pools serve the workspace's runs and none of them can start
  # the run's machine type, that type. Else, under the workflow model: nil keeps the
  # words of the work item's status, for one that ended, and at Explore while a run, its questions or its
  # gate are what the stage is at; anywhere else, the stage and its state.
  defp head_status(_flow, _item, %{}, _no_fit), do: no_pool_status()

  defp head_status(_flow, _item, nil, name) when is_binary(name),
    do: %{
      words: gettext("Waiting: no pool can start machine type %{name}", name: name),
      mark: :err
    }

  defp head_status(nil, _item, nil, nil), do: nil
  defp head_status(%{ended: true}, _item, nil, nil), do: nil

  defp head_status(%{at_explore: true, state: state}, %{status: status}, nil, nil)
       when state in [:running, :waiting_answers, :at_gate] and status in @explore_statuses,
       do: nil

  defp head_status(flow, _item, nil, nil),
    do: flow |> StageComponents.head_status() |> head_run_link(flow)

  # While the stage runs, the header's status links the run it is about, where that run
  # has a path: only Explore's runs do, at Explore (`Workflow.page/2`). The Work items list
  # uses the same words with no link, because its whole row is a link.
  defp head_run_link(status, %{state: :running, runs: runs, stage: %{id: stage_id}}) do
    run = Enum.find(runs, &(&1.shows in [:running, :queued] and &1.stage_id == stage_id))
    %{status | words: head_ref(run, status.words)}
  end

  defp head_run_link(status, _flow), do: status

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
      send:
        live? and status in [:questions, :confirm] and
          Access.can?(scope, :"work_item.review_comment", row),
      change:
        live? and status in [:questions, :confirm] and
          Access.can?(scope, :"work_item.answer", row),
      act:
        live? and not is_nil(action) and not escalated?(flow, status) and
          Access.can?(scope, action, row)
    }
  end

  # With the workflow model on, loads the work item's process version, or puts the
  # workspace's current one on a work item with none, so the `Apiary.Access` checks of the
  # page read no version (`Apiary.Stages.Approvers`). With it off, those checks read none.
  defp with_version(row, scope) do
    if Apiary.Features.on?(:workflow_model) do
      case Apiary.Repo.preload(row, :process_version) do
        %{process_version: nil} = row ->
          %{row | process_version: Processes.current(scope.workspace)}

        row ->
          row
      end
    else
      row
    end
  end

  # Who confirms next where the stage lists approvers: `:you` where the reader may confirm,
  # else the approvers by name, in the gate's order; nil keeps the owner rule. A listed
  # reader who may not confirm stays in the list; the components leave their name out.
  defp confirmers(scope, row, flow) do
    case gate_approvers(scope, row, flow) do
      [_ | _] = ids ->
        if Access.can?(scope, :"work_item.confirm", row) do
          :you
        else
          people = View.people(scope, ids)
          Enum.map(ids, &View.person(people, &1))
        end

      _members_or_none ->
        nil
    end
  end

  defp gate_approvers(_scope, _row, %{gate_approvers: ids}), do: ids

  defp gate_approvers(scope, row, nil) do
    with true <- Apiary.Features.on?(:workflow_model),
         %{gate: %{approvers: ids}} <- Apiary.Stages.status(row, scope) do
      ids
    else
      _off_or_not_placed -> nil
    end
  end

  # Who confirms next on the Thread's proposals, which wait at Explore's gate:
  # `confirmers/3`'s answer while the work item is at Explore's stage; nil at any later
  # stage, whose approvers do not confirm a proposal, so the owner rule stays.
  # A work item with no stage has only Explore's Confirm.
  defp at_explore?(_row, %{at_explore: at_explore}), do: at_explore
  defp at_explore?(%{stage_id: nil}, nil), do: true
  defp at_explore?(row, nil), do: row.stage_id == Apiary.Stages.explore_stage_id(row)

  # The Thread's proposal lines: only the proposal that waits at Confirm, the newest with
  # an owner, shows who confirms next. Every other line has no owner, so it shows only how
  # long the run took.
  defp thread_lines(thread, false, _confirmers), do: Enum.map(thread, &without_next/1)

  defp thread_lines(thread, true, confirmers) do
    waiting =
      thread
      |> Enum.filter(&match?(%{kind: :proposed, owner: %{}}, &1))
      |> Enum.max_by(& &1.at, DateTime, fn -> nil end)

    Enum.map(thread, fn
      ^waiting -> with_confirmers(waiting, confirmers)
      event -> without_next(event)
    end)
  end

  defp without_next(%{kind: :proposed} = event), do: %{event | owner: nil}
  defp without_next(event), do: event

  # Puts `confirmers/3`'s answer on the work item, whose header and step card show it at
  # Explore's gate, and on the Thread proposal that waits at Confirm; the components show
  # its words in place of the owner's.
  defp with_confirmers(map, nil), do: map

  defp with_confirmers(%{kind: :proposed, owner: %{}} = event, confirmers),
    do: Map.put(event, :confirmers, confirmers)

  defp with_confirmers(%{kind: _other} = event, _confirmers), do: event
  defp with_confirmers(work_item, confirmers), do: Map.put(work_item, :confirmers, confirmers)

  # While the work item's latest run waits in the queue, before a pool claims it (no state
  # yet), whatever Explore's status (a run after a move back to Explore, or a later
  # stage's run, follows a confirmation), and no pool that serves the workspace's runs is
  # ready by the Machines set-up step's rule (`c:Apiary.Edition.machines_ready/1`): the
  # step's lines of those pools (`Apiary.WorkspaceSetup.pools/1`), each with the reason it
  # is not ready, the workspace's name, and its Machines page for a reader who may open it
  # (`node.read`). Else nil. The take in's first run before it is queued (`workspace_id`
  # nil) is not in the queue.
  defp no_pool(scope, %{run: %{place: :queued, state: nil, workspace_id: id}})
       when is_binary(id) do
    workspace = scope.workspace

    if is_nil(Edition.machines_ready(workspace)) do
      %{
        pools: WorkspaceSetup.pools(workspace),
        workspace: workspace.name,
        path:
          if(Access.can?(scope, :"node.read", workspace),
            do: ~p"/#{scope.organisation}/#{workspace}/machines"
          )
      }
    end
  end

  defp no_pool(_scope, _item), do: nil

  # While the work item's latest run waits in the queue, and no pool that serves the
  # workspace's runs can start its machine type, the type's name, or the key where no type
  # has it (`Apiary.MachineTypes.unserved/2`).
  defp no_fit(scope, %{id: id}, %{run: %{place: :queued, state: nil, workspace_id: ws}})
       when is_binary(ws) do
    with key when is_binary(key) <- Apiary.MachineTypes.unserved(scope.workspace, id) do
      case Apiary.MachineTypes.get(key) do
        %{name: name} -> name
        nil -> key
      end
    end
  end

  defp no_fit(_scope, _row, _item), do: nil

  # While no pool can take the queued run, the page listens to the access keys of each
  # pool that serves the workspace's runs and of the gateway its choice leads to
  # (`Apiary.Gateways.chosen/1`), once per node (`Apiary.AccessKeys.subscribe/2`), as the
  # Machines set-up step listens to its pools, and reads everything again when a machine
  # enrols a key on one. A topic the scope may not read is not listened to: the instance's
  # pool's and gateway's for anyone but an instance admin, and a node of another
  # organisation. No other change of a pool or a gateway sends a message. Before the
  # browser connects, the page reads no gateway and listens to nothing.
  defp listen_to_pools(%{assigns: %{no_pool: %{pools: lines}}} = socket) do
    if connected?(socket), do: listen_to(socket, lines), else: socket
  end

  defp listen_to_pools(socket), do: socket

  defp listen_to(socket, lines) do
    scope = scope(socket)
    nodes = for %{pool: %{} = pool} <- lines, node <- [pool, Gateways.chosen(pool)], do: node

    listened =
      for %{id: id} = node <- nodes,
          id not in socket.assigns.pool_listened,
          listenable?(scope, node),
          reduce: socket.assigns.pool_listened do
        acc ->
          case AccessKeys.subscribe(scope, node) do
            :ok -> MapSet.put(acc, id)
            {:error, _refused} -> acc
          end
      end

    assign(socket, :pool_listened, listened)
  end

  # The nodes whose topic `Apiary.AccessKeys.subscribe/2` has a clause for: of the
  # scope's workspace, a gateway of its organisation, or a node of the instance.
  defp listenable?(%{workspace: %{id: id}}, %{workspace_id: id}), do: true

  defp listenable?(%{organisation: %{id: id}}, %{workspace_id: nil, organisation_id: id}),
    do: true

  defp listenable?(_scope, %{workspace_id: nil, organisation_id: nil}), do: true
  defp listenable?(_scope, _node), do: false

  # Details' Runs under the workflow model, while the newest run waits for a machine and
  # none has started: that run, in place of None yet; nil for a run without its attempt.
  defp queued_run(%{runs: [%{shows: :queued} | _]}, %{run: %{attempt: attempt} = run})
       when is_integer(attempt),
       do: rich_gettext("%{attempt} is queued.", attempt: attempt_words(run))

  defp queued_run(_flow, _item), do: nil

  # At Explore, while its run runs, its questions wait or its gate waits, the step card is
  # the stage's one card, with the stage's state: the stage card is not shown. Explore's
  # status must match too: after a run that ended without a result, while the stage
  # still runs, both cards show, so the step card shows what happened.
  defp one_card?(%{explore: true, state: state}, item),
    do: {state, status(item)} in @one_card

  defp one_card?(_flow, _item), do: false

  # Today's step card, beside the stage card at Explore. While the stage is escalated after
  # a run with no result, the block "What the run needs from you" says what happened and
  # the escalation card offers Run another round: there the step card is not shown. Nor is
  # it at a proposal whose stage escalated. Confirm shows again once the stage reaches its
  # gate.
  defp step_card?(nil, _item), do: true
  defp step_card?(%{explore: false}, _item), do: false
  defp step_card?(flow, item), do: not escalated?(flow, status(item))

  # Whether the page shows the block "What the run needs from you": while the live work
  # item's stage is escalated, with an escalation row or none, and while it waits for
  # answers with an escalation that has points.
  defp needs?(%{ended: false, state: :escalated}), do: true
  defp needs?(%{ended: false, escalation: %{points: [_ | _]}}), do: true

  defp needs?(_flow), do: false

  # The points of an escalation kept while the stage waits for answers, for the line
  # "Waits for you" on the step card; 0 otherwise.
  defp waiting_points(%{state: :waiting_answers, escalation: %{points: points}}),
    do: length(points)

  defp waiting_points(_flow), do: 0

  # Where the block "What the run needs from you" is: on this page, or, at Explore, on the
  # Explore tab when the page shows another tab.
  defp needs_path(%{explore: true}, tab, scope, number) when tab != :explore,
    do: tab_path(scope, number, :explore) <> "#work-item-needs"

  defp needs_path(_flow, _tab, _scope, _number), do: "#work-item-needs"

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

  defp escalated?(%{state: :escalated, escalation: %{}}, status)
       when status in [:no_result, :lost, :cancelled, :used_up, :confirm],
       do: true

  defp escalated?(_flow, _status), do: false

  defp scope(socket), do: socket.assigns.current_scope

  # Whether the page shows Reply and its form page: while no run runs, to a reader
  # `Apiary.Access` allows `work_item.review_comment`, which only the stage's approvers
  # have where it lists them. The move (`Apiary.WorkItems.Moves.reply/5`) checks the
  # same action, so a page read before the reader lost it shows
  # `{:error, :not_approver}` on the send.
  defp can_review?(scope, row, status),
    do: status in @no_run and Access.can?(scope, :"work_item.review_comment", row)

  defp running?(%{status: status}), do: status in [:queued, :running]
  defp running?(_item), do: false

  defp reply_path(scope, number, id),
    do: tab_path(scope, number, :explore) <> "?" <> URI.encode_query(reply: id)

  defp tab_path(scope, number, :open),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}"

  defp tab_path(scope, number, :ticket),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}/ticket"

  defp tab_path(scope, number, :explore),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}/explore"

  defp tab_path(scope, number, :thread),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}/thread"

  # Add's page for an input of `type`: a person's upload of an artifact
  # (`ApiaryWeb.ArtifactLive`).
  defp add_path(scope, number, type),
    do: ArtifactComponents.new_path(scope, number) <> "?" <> URI.encode_query(type: type)
end
