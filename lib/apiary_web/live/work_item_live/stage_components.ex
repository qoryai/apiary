defmodule ApiaryWeb.WorkItemLive.StageComponents do
  # The stage parts of the work item page and the board under the workflow model
  # (`ApiaryWeb.WorkItemLive.Workflow`): the stage track, the stage card in the rail (its
  # state: running, waiting for inputs, for answers or for a workflow, escalated, at the
  # gate, done), the runs, the approval marks, and the board's columns.
  #
  # Every component takes the plain maps `ApiaryWeb.WorkItemLive.Workflow.page/2` and
  # `board/1` give. Stage names, workflow names, artifact types and gaps come from the
  # workspace's process, its harness and its runs: a component only interpolates them,
  # so HEEx escapes them.
  #
  # The events the stage card sends, each with `number`, the work item's number:
  #
  #   * `"stage_approve"` - Approve, with `note`;
  #   * `"stage_ask_changes"`, `"stage_request_changes"` - Request changes opens its form,
  #     which sends `note` and `version`, the artifact version it is about or `""`;
  #   * `"stage_resolve"` - an escalation action: `how` (`accept`, `another_round`,
  #     `move_back` or `close`), `note`, and `stage` for `move_back`;
  #   * `"stage_move"` - Move back while the stage waits for inputs: `stage` and `note`.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :html

  alias ApiaryWeb.PauseWords
  alias ApiaryWeb.WorkItemComponents

  @note_units 2 * 2_000

  ## The stage track

  @doc """
  The stages of the work item's process version, in order: those before the current
  stage done, the current one the current step (`aria-current="step"`), amber while it
  waits for a person.
  """
  attr :id, :string, default: "work-item-head-stages"
  attr :page, :map, required: true, doc: "`ApiaryWeb.WorkItemLive.Workflow.page/2`"

  def process_track(assigns) do
    assigns = assign(assigns, :wait, waits?(assigns.page.state) and !assigns.page.ended)

    ~H"""
    <div id={@id} class="q-wi-track">
      <ol aria-label={gettext("Stages")} class="flex-wrap">
        <li
          :for={{stage, i} <- Enum.with_index(@page.stages, 1)}
          id={"#{@id}-#{stage.id}"}
          class={[
            "q-wi-stage",
            "q-wi-stage-#{track_class(stage.at)}",
            stage.at == :now && @wait && "q-wi-stage-wait"
          ]}
          aria-current={stage.at == :now && "step"}
        >
          <span class="q-wi-stage-n" aria-hidden="true">
            <%= if stage.at == :done do %>
              <.icon name="hero-check-micro" class="size-3" />
            <% else %>
              {i}
            <% end %>
          </span>
          {stage.name}
        </li>
      </ol>
    </div>
    """
  end

  # The stage's waiting or running run: it has a path only at Explore.
  defp live_run(page),
    do: Enum.find(page.runs, &(&1.shows in [:running, :queued] and &1.stage_id == page.stage.id))

  defp track_class(:done), do: "done"
  defp track_class(:now), do: "now"
  defp track_class(:todo), do: "todo"

  defp waits?(state),
    do: state in [:waiting_inputs, :waiting_answers, :waiting_workflow, :escalated, :at_gate]

  ## The stage card

  @doc """
  The current stage in the rail: its name, its state and round, then what the state
  needs. Waiting for inputs lists each missing required input with Add, and Move back;
  waiting for answers links to the questions on the current stage's tab, and to the block
  "What the run needs from you" while an escalation waits too; waiting for a workflow names
  the workflow the harness no longer declares; escalated shows the escalation card; at the
  gate shows the gate card.
  """
  attr :id, :string, default: "work-item-stage"
  attr :page, :map, required: true, doc: "`ApiaryWeb.WorkItemLive.Workflow.page/2`"
  attr :number, :integer, required: true, doc: "the work item's number"
  attr :add_path, :any, required: true, doc: "a function of an artifact type: Add's path"
  attr :answers_path, :string, default: nil, doc: "the current stage's tab, with the questions"
  attr :asking, :atom, default: nil, values: [nil, :changes], doc: "the form showing"

  attr :error, :atom,
    default: nil,
    values: [nil, :note],
    doc: "a field of Request changes the server refused: `:note`, left blank"

  attr :check, :any,
    default: nil,
    doc:
      "Check again: `:checking`, `{:still_missing, workflow}`, `{:failed, message}` with `message` as rich text (`ApiaryWeb.RichText`), or nil"

  attr :notice, :string,
    default: nil,
    doc: "why the page did not act: the work item moved, or a move back went forward"

  attr :needs_path, :string,
    default: "#work-item-needs",
    doc: "where the block \"What the run needs from you\" is (`needs_block/1`)"

  def stage_card(assigns) do
    ~H"""
    <section
      id={@id}
      class={["q-wi-step", waits?(@page.state) && @page.can_decide && "q-wi-step-ask"]}
      aria-labelledby={"#{@id}-h"}
    >
      <div class="q-wi-step-h">
        <h2 id={"#{@id}-h"}>{@page.stage.name}</h2>
        <span id={"#{@id}-state"}><.state_badge state={shown_state(@page)} /></span>
        <WorkItemComponents.run_link
          :if={@page.state == :running}
          id={"#{@id}-run-link"}
          run={live_run(@page)}
        />
      </div>
      <p :if={@page.rounds && !@page.at_explore} id={"#{@id}-round"}>
        {gettext("Round %{round} of %{rounds}",
          round: Format.number(@page.round || 1),
          rounds: Format.number(@page.rounds)
        )}
      </p>
      <p :if={@notice} id={"#{@id}-notice"} class="q-xp-err" role="alert">{@notice}</p>
      <.stage_body
        id={@id}
        page={@page}
        number={@number}
        add_path={@add_path}
        answers_path={@answers_path}
        asking={@asking}
        error={@error}
        check={@check}
        needs_path={@needs_path}
      />
    </section>
    """
  end

  @doc """
  The stage's state as the stage card shows it, as a badge: on the step card, where it is
  the one card of the stage at Explore.
  """
  attr :id, :string, default: "work-item-step-state"
  attr :page, :map, required: true, doc: "`ApiaryWeb.WorkItemLive.Workflow.page/2`"
  attr :quiet, :boolean, default: false, doc: "the stage's run has a late heartbeat"

  def stage_badge(assigns) do
    ~H"""
    <span id={@id}><.state_badge state={shown_state(@page)} quiet={@quiet} /></span>
    """
  end

  attr :state, :atom, required: true
  attr :quiet, :boolean, default: false

  defp state_badge(assigns) do
    assigns =
      assign(assigns,
        color:
          if(assigns.quiet and assigns.state == :running,
            do: "warning",
            else: state_color(assigns.state)
          ),
        words: state_words(assigns.state)
      )

    ~H"""
    <.badge color={@color} class="q-wi-badge">{@words}</.badge>
    """
  end

  # The state as the card and the head show it: Queued while the stage's run waits for a
  # machine, as the step card and the run list say.
  defp shown_state(%{state: :running, queued: true}), do: :queued
  defp shown_state(%{state: state}), do: state

  defp state_color(:queued), do: "neutral"
  defp state_color(:running), do: "info"
  defp state_color(:at_gate), do: "info"
  defp state_color(:done), do: "neutral"
  defp state_color(_state), do: "warning"

  defp state_words(:queued), do: gettext("Queued")
  defp state_words(:running), do: gettext("Running")
  defp state_words(:waiting_inputs), do: gettext("Waits for inputs")
  defp state_words(:waiting_answers), do: gettext("Needs answers")
  defp state_words(:waiting_workflow), do: gettext("Waits for a workflow")
  defp state_words(:escalated), do: gettext("Waits for a person")
  defp state_words(:at_gate), do: gettext("At the gate")
  defp state_words(:done), do: gettext("Done")

  @doc """
  The head's status for the stage the work item is at: the stage and its state, with the
  mark of the work item's status that matches them.
  """
  def head_status(page) do
    %{
      words: page.stage.name <> " · " <> state_words(shown_state(page)),
      mark: head_mark(page)
    }
  end

  @doc """
  A row's status under its stage's group: `head_status/1` without the stage, which the
  group shows.
  """
  def group_status(page), do: %{words: state_words(shown_state(page)), mark: head_mark(page)}

  defp head_mark(%{state: :running, queued: true}), do: :todo
  defp head_mark(%{state: :running}), do: :run
  defp head_mark(%{state: :done}), do: :ready
  defp head_mark(%{can_decide: true}), do: :wait
  defp head_mark(_page), do: :wait_other

  attr :id, :string, required: true
  attr :page, :map, required: true
  attr :number, :integer, required: true
  attr :add_path, :any, required: true
  attr :answers_path, :string, default: nil
  attr :asking, :atom, default: nil
  attr :error, :atom, default: nil
  attr :check, :any, default: nil
  attr :needs_path, :string, default: "#work-item-needs"

  defp stage_body(%{page: %{state: :running}} = assigns) do
    assigns =
      assign(
        assigns,
        :line,
        gettext("%{stage} is running.", stage: assigns.page.stage.name)
      )

    ~H"""
    <p :if={!@page.queued} id={"#{@id}-line"}><.rich text={@line} /></p>
    """
  end

  defp stage_body(%{page: %{state: :waiting_inputs}} = assigns) do
    assigns =
      assign(
        assigns,
        :missing,
        for(%{required: true, version: nil, type: type} <- assigns.page.inputs, do: type)
      )

    ~H"""
    <.needs id={@id} page={@page} types={@missing} add_path={@add_path} />
    <.move_back
      :if={@page.can_decide and @page.earlier != []}
      id={"#{@id}-move"}
      event="stage_move"
      page={@page}
      number={@number}
    />
    """
  end

  defp stage_body(%{page: %{state: :waiting_answers}} = assigns) do
    ~H"""
    <p id={"#{@id}-line"}>
      {gettext("%{stage} waits for answers to the agent's questions.", stage: @page.stage.name)}
    </p>
    <.link
      :if={@answers_path && !@page.explore}
      id={"#{@id}-answers"}
      patch={@answers_path}
      class="q-link"
    >
      {gettext("Answer the questions")}
    </.link>
    <WorkItemComponents.waits_line
      :if={@page.escalation && @page.escalation.points != []}
      count={length(@page.escalation.points)}
      path={@needs_path}
    />
    """
  end

  defp stage_body(%{page: %{state: :waiting_workflow}} = assigns) do
    ~H"""
    <p :for={{line, i} <- Enum.with_index(@page.gaps)} id={"#{@id}-gap-#{i}"}>{line}</p>
    <form :if={@page.can_decide} id={"#{@id}-check"} phx-submit="stage_check" novalidate>
      <input type="hidden" name="number" value={@number} />
      <input type="hidden" name="seen" value={@page.stage.id} />
      <%= case @check do %>
        <% {:still_missing, workflow} -> %>
          <p id={"#{@id}-check-result"} class="q-xp-err">
            {gettext("The harness still does not list %{workflow}.", workflow: workflow)}
          </p>
          <.button id={"#{@id}-check-go"} type="submit">{gettext("Check again")}</.button>
        <% {:failed, message} -> %>
          <p id={"#{@id}-check-result"} class="q-xp-err"><.rich text={message} /></p>
          <.button id={"#{@id}-check-go"} type="submit">{gettext("Try again")}</.button>
        <% :checking -> %>
          <.button id={"#{@id}-check-go"} type="submit" disabled>
            {gettext("Checking the harness…")}
          </.button>
        <% _none -> %>
          <.button id={"#{@id}-check-go"} type="submit">{gettext("Check again")}</.button>
      <% end %>
    </form>
    """
  end

  defp stage_body(%{page: %{state: :escalated}} = assigns) do
    ~H"""
    <.escalation_card
      id={"#{@id}-escalation"}
      page={@page}
      number={@number}
      needs_path={@needs_path}
    />
    """
  end

  defp stage_body(%{page: %{state: :at_gate}} = assigns) do
    ~H"""
    <.gate_card
      id={"#{@id}-gate"}
      page={@page}
      number={@number}
      add_path={@add_path}
      asking={@asking}
      error={@error}
    />
    """
  end

  defp stage_body(%{page: %{state: :done}} = assigns) do
    ~H"""
    <p id={"#{@id}-line"}>{gettext("Every stage is done.")}</p>
    """
  end

  ## The gate card

  attr :id, :string, required: true
  attr :page, :map, required: true
  attr :types, :list, required: true
  attr :add_path, :any, required: true

  # What the stage needs, and an Add for each type for a person who may add it.
  defp needs(assigns) do
    ~H"""
    <p id={"#{@id}-line"}>
      {gettext("%{stage} needs %{inputs}",
        stage: @page.stage.name,
        inputs: outputs_words(@types)
      )}
    </p>
    <ul id={"#{@id}-inputs"} class="flex flex-col gap-1">
      <li :for={type <- @types} id={"#{@id}-input-#{type}"} class="flex items-center gap-2">
        <span class="q-grow">{type_words(type)}</span>
        <.button
          :if={@page.can_add}
          id={"#{@id}-add-#{type}"}
          navigate={@add_path.(type)}
          aria-label={gettext("Add %{type}", type: type_words(type))}
        >
          <.icon name="hero-plus-micro" class="size-3.5" />{gettext("Add")}
        </.button>
      </li>
    </ul>
    """
  end

  attr :id, :string, required: true
  attr :page, :map, required: true
  attr :number, :integer, required: true
  attr :add_path, :any, required: true
  attr :asking, :atom, default: nil
  attr :error, :atom, default: nil

  defp gate_card(assigns) do
    assigns =
      assign(assigns,
        marks: Map.new(assigns.page.index, &{&1.type, &1}),
        versions: Enum.filter(assigns.page.outputs, & &1.version_id),
        # At a Confirm gate the proposal can exist with no artifact, so an output with no
        # version is not shown as missing.
        shown: shown_outputs(assigns.page),
        # A gate `none` takes no decision: the stage passes on once its outputs exist.
        decides: assigns.page.gate_kind != "none"
      )

    ~H"""
    <div id={@id} class="flex flex-col gap-2">
      <h3 :if={@shown != [] or @page.outputs == []} class="text-sm font-semibold">
        {gettext("Outputs")}
      </h3>
      <p :if={@page.outputs == []} id={"#{@id}-none"}>{gettext("This stage has no outputs.")}</p>
      <ul :if={@shown != []} id={"#{@id}-outputs"} class="flex flex-col gap-1">
        <li :for={output <- @shown} id={"#{@id}-output-#{output.type}"}>
          <span>{version_words(output.type, output.version)}</span>
          · <span id={"#{@id}-check-#{output.type}"}>{check_words(output)}</span>
          <.approval_mark id={"#{@id}-mark-#{output.type}"} mark={@marks[output.type]} />
        </li>
      </ul>
      <.needs
        :if={@page.missing_outputs != [] and not @page.confirm_gate}
        id={@id}
        page={@page}
        types={@page.missing_outputs}
        add_path={@add_path}
      />
      <p :if={@decides and not @page.confirm_gate} id={"#{@id}-approvers"} class="text-xs opacity-70">
        <%= case @page.approvers do %>
          <% :members -> %>
            {gettext("One approval covers each version. Any member approves.")}
          <% {:listed, _ids} -> %>
            {gettext("One approval covers each version. The members this stage lists approve.")}
        <% end %>
      </p>
      <%= if @page.can_decide and not @page.confirm_gate do %>
        <%= if @asking == :changes and @decides do %>
          <form
            novalidate
            id={"#{@id}-changes"}
            phx-submit="stage_request_changes"
            class="flex flex-col gap-2"
          >
            <input type="hidden" name="number" value={@number} />
            <input type="hidden" name="seen" value={@page.stage.id} />
            <label for={"#{@id}-changes-version"}>{gettext("About")}</label>
            <select id={"#{@id}-changes-version"} name="version">
              <option value="">{gettext("The whole stage")}</option>
              <option :for={output <- @versions} value={output.version_id}>
                {version_words(output.type, output.version)}
              </option>
            </select>
            <.note
              id={"#{@id}-changes-note"}
              error={@error == :note && gettext("Write what needs to change.")}
            />
            <div class="q-wi-acts">
              <.button id={"#{@id}-changes-go"} type="submit" variant="primary">
                {gettext("Request changes")}
              </.button>
              <.button id={"#{@id}-changes-cancel"} type="button" phx-click="cancel_question">
                {gettext("Cancel")}
              </.button>
            </div>
          </form>
        <% else %>
          <form :if={@page.approvable} novalidate id={"#{@id}-approve"} phx-submit="stage_approve">
            <input type="hidden" name="number" value={@number} />
            <input type="hidden" name="seen" value={@page.stage.id} />
            <input type="hidden" name="note" value="" />
            <.button id={"#{@id}-approve-go"} type="submit" variant="primary">
              <.icon name="hero-check-micro" class="size-3.5" />{gettext("Approve %{stage}",
                stage: @page.stage.name
              )}
            </.button>
          </form>
          <div :if={@decides} class="q-wi-acts">
            <.button
              id={"#{@id}-ask-changes"}
              type="button"
              phx-click="stage_ask_changes"
              phx-value-number={@number}
            >
              {gettext("Request changes")}
            </.button>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp shown_outputs(%{confirm_gate: true, outputs: outputs}),
    do: Enum.filter(outputs, & &1.version_id)

  defp shown_outputs(%{outputs: outputs}), do: outputs

  defp check_words(%{version: nil, required: false}), do: gettext("Optional, none")
  defp check_words(%{check: :passed}), do: gettext("Passed")
  defp check_words(%{check: :not_checked}), do: gettext("Not checked in this version")
  defp check_words(%{check: :missing}), do: gettext("Missing")

  ## The escalation card

  attr :line, :string, required: true
  attr :path, :any, default: nil, doc: "the set-up step Harness, where the fix is on it"

  # A line of text, escaped; the words "the set-up step Harness" link to that step where
  # the fix is on it.
  defp gap_line(assigns) do
    words = "the set-up step Harness"

    parts =
      if is_binary(assigns.path), do: String.split(assigns.line, words, parts: 2), else: []

    assigns = assign(assigns, words: words, parts: parts)

    ~H"""
    <%= case @parts do %>
      <% [before, rest] -> %>
        {before}<.link navigate={@path} class="q-link">{@words}</.link>{rest}
      <% _none -> %>
        {@line}
    <% end %>
    """
  end

  attr :id, :string, required: true
  attr :page, :map, required: true
  attr :number, :integer, required: true
  attr :needs_path, :string, default: "#work-item-needs"

  # The escalation in the rail: one line, "Waits for you: N points", which links to the
  # block "What the run needs from you" (`needs_block/1`), the run it came from, and Accept as
  # it is (only with a result), Move back and Close. Their form has the note field and Run
  # another round in the block, which name it in their `form` attribute, so the note goes
  # with every action.
  defp escalation_card(assigns) do
    assigns =
      assign(
        assigns,
        :escalation,
        assigns.page.escalation ||
          %{cause: :escalate, result: true, points: [], run: nil, harness_path: nil}
      )

    ~H"""
    <div id={@id} class="flex flex-col gap-2">
      <WorkItemComponents.waits_line
        :if={@escalation.points != []}
        count={length(@escalation.points)}
        path={@needs_path}
      />
      <p :if={@escalation.run} id={"#{@id}-run"} class="text-xs opacity-70">
        {gettext("From attempt %{attempt} · %{workflow}",
          attempt: Format.number(@escalation.run.number),
          workflow: @escalation.run.workflow || ""
        )}
      </p>
      <form
        :if={@page.can_decide}
        novalidate
        id={"#{@id}-form"}
        phx-submit="stage_resolve"
        class="flex flex-col gap-2"
      >
        <input type="hidden" name="number" value={@number} />
        <input type="hidden" name="seen" value={@page.stage.id} />
        <div :if={@escalation.result} class="q-wi-acts flex-wrap">
          <.button
            id={"#{@id}-accept"}
            type="submit"
            name="how"
            value="accept"
            variant="primary"
          >
            {gettext("Accept as it is")}
          </.button>
        </div>
        <div :if={@page.earlier != []} class="q-wi-acts flex-wrap">
          <label for={"#{@id}-stage"} class="sr-only">{gettext("Earlier stage")}</label>
          <select id={"#{@id}-stage"} name="stage">
            <option :for={stage <- Enum.reverse(@page.earlier)} value={stage.id}>{stage.name}</option>
          </select>
          <.button id={"#{@id}-move"} type="submit" name="how" value="move_back">
            {gettext("Move back")}
          </.button>
        </div>
        <div class="q-wi-acts flex-wrap">
          <.button id={"#{@id}-close"} type="submit" name="how" value="close">
            {gettext("Close")}
          </.button>
        </div>
      </form>
    </div>
    """
  end

  ## What the run needs from you

  @doc """
  The block "What the run needs from you": the points of the stage's open escalation, one
  numbered sentence each, followed by the sentence of its action: "Answer question N.",
  with "question N" linked to the question on the current stage's tab, or "Run another
  round.", or a stopped run's fix line in its place. While the stage is escalated, a reader who may decide
  finds the note field and Run another round under the points; they belong to the form of
  the escalation card in the rail (`stage_card/1`). While the stage waits for answers, the
  answers run the next round, so the block has no form.
  """
  attr :id, :string, default: "work-item-needs"
  attr :page, :map, required: true, doc: "`ApiaryWeb.WorkItemLive.Workflow.page/2`"

  attr :questions, :list,
    default: [],
    doc: "the questions of the take in, each with its `id` and `number` as the tabs number them"

  attr :question_path, :string,
    default: "",
    doc: "the path of the tab where the questions are; empty on that tab"

  attr :questions_id, :string,
    default: "work-item-explore-questions",
    doc: "the id of that tab's questions frame, before `-question-N`"

  attr :class, :string, default: nil

  def needs_block(assigns) do
    numbers = Map.new(assigns.questions, &{&1.id, &1.number})

    assigns =
      assign(assigns,
        points:
          Enum.map(
            (assigns.page.escalation || %{points: []}).points,
            &Map.put(&1, :number, numbers[&1.question])
          ),
        form: assigns.page.state == :escalated and assigns.page.can_decide,
        form_id: "work-item-stage-escalation-form",
        field: "work-item-stage-escalation"
      )

    ~H"""
    <section id={@id} class={["q-xp-frame q-xp-needs", @class]} aria-labelledby={"#{@id}-h"}>
      <div class="q-xp-frame-h">
        <.icon name="hero-flag-micro" class="q-xp-frame-i size-4" />
        <h2 id={"#{@id}-h"} class="q-xp-frame-t">{gettext("What the run needs from you")}</h2>
      </div>
      <div class="q-xp-body q-xp-needs-body">
        <ol :if={@points != []} id={"#{@id}-points"} class="q-xp-needs-points">
          <li :for={{point, i} <- Enum.with_index(@points, 1)} id={"#{@id}-point-#{i}"}>
            <.point
              point={point}
              href={
                point.number &&
                  "#{@question_path}##{@questions_id}-question-#{point.number}"
              }
              harness_path={@page.escalation && @page.escalation[:harness_path]}
            />
          </li>
        </ol>
        <div :if={@form} class="q-xp-needs-form flex flex-col gap-2">
          <label for={"#{@field}-note"}>{gettext("Note")}</label>
          <textarea
            id={"#{@field}-note"}
            name="note"
            rows="2"
            maxlength={note_units()}
            form={@form_id}
          ></textarea>
          <p class="text-xs opacity-70">
            {gettext("A note you add goes to the next run as work item data.")}
          </p>
          <div class="q-wi-acts flex-wrap">
            <.button
              id={"#{@field}-another"}
              type="submit"
              name="how"
              value="another_round"
              form={@form_id}
            >
              {gettext("Run another round")}
            </.button>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :point, :map, required: true
  attr :href, :string, default: nil, doc: "the question of an `answer` point, nil for none"
  attr :harness_path, :any, default: nil

  # A point's sentence, escaped, then the sentence of its action. An `answer` point adds
  # "Answer question N.", with "question N" linked to its question; a `run_again` point
  # adds "Run another round.", or the stop cause's fix line in its place, in which the
  # words "the set-up step Harness" link to that step where the fix is on it
  # (`gap_line/1`).
  defp point(%{point: %{action: :answer, number: n}, href: href} = assigns)
       when is_integer(n) and is_binary(href) do
    # The sentence is split at a marker, so that the link keeps its place in any locale.
    marker = <<0>>
    [before, rest] = String.split(gettext("Answer %{question}.", question: marker), marker)

    assigns =
      assign(assigns,
        before: before,
        rest: rest,
        words: gettext("question %{number}", number: Format.number(n))
      )

    ~H"""
    {@point.text} {@before}<.link href={@href} class="q-link">{@words}</.link>{@rest}
    """
  end

  defp point(%{point: %{action: :answer}} = assigns) do
    ~H"""
    {@point.text} {gettext("Answer the question.")}
    """
  end

  defp point(assigns) do
    fix = assigns.point[:fix]

    assigns =
      assign(assigns,
        line: fix || gettext("Run another round."),
        path: fix && assigns.harness_path
      )

    ~H"""
    {@point.text} <.gap_line line={@line} path={@path} />
    """
  end

  defp note_units, do: @note_units

  ## Move back

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :page, :map, required: true
  attr :number, :integer, required: true

  defp move_back(assigns) do
    ~H"""
    <form novalidate id={@id} phx-submit={@event} class="flex flex-col gap-2">
      <input type="hidden" name="number" value={@number} />
      <input type="hidden" name="seen" value={@page.stage.id} />
      <label for={"#{@id}-stage"}>{gettext("Move back to")}</label>
      <select id={"#{@id}-stage"} name="stage">
        <option :for={stage <- Enum.reverse(@page.earlier)} value={stage.id}>{stage.name}</option>
      </select>
      <.note id={"#{@id}-note"} />
      <div class="q-wi-acts">
        <.button id={"#{@id}-go"} type="submit">{gettext("Move back")}</.button>
      </div>
    </form>
    """
  end

  attr :id, :string, required: true
  attr :error, :any, default: nil, doc: "what is wrong with the note, or nil"

  defp note(assigns) do
    assigns = assign(assigns, :units, @note_units)

    ~H"""
    <label for={@id}>{gettext("Note")}</label>
    <textarea
      id={@id}
      name="note"
      rows="2"
      maxlength={@units}
      aria-describedby={@error && "#{@id}-error"}
      aria-invalid={@error && "true"}
    ></textarea>
    <p :if={@error} id={"#{@id}-error"} class="q-xp-err">
      <.icon name="hero-exclamation-triangle-micro" class="size-3.5" />{@error}
    </p>
    """
  end

  ## The runs

  @doc """
  The runs of the work item, newest first: each an attempt, counted from the work item's
  first run ("Attempt 2"), so that it is not taken for the run's number in its workspace
  ("Run 3"), with its workflow, its round and its verdict, or none yet.
  """
  attr :id, :string, default: "work-item-runs"
  attr :runs, :list, required: true

  def stage_runs(assigns) do
    ~H"""
    <section id={@id} class="q-xp-sec" aria-labelledby={"#{@id}-h"}>
      <h3 id={"#{@id}-h"}>{gettext("Runs")}</h3>
      <p :if={@runs == []} id={"#{@id}-none"}>{gettext("No run yet.")}</p>
      <ol :if={@runs != []} class="flex flex-col gap-1">
        <li :for={{run, i} <- Enum.with_index(@runs)} id={"#{@id}-#{i}"}>
          <.rich text={run_words(run)} />
        </li>
      </ol>
    </section>
    """
  end

  defp run_words(run) do
    rich_gettext("%{attempt} · %{workflow} · round %{round} · %{verdict}",
      attempt: WorkItemComponents.attempt_words(run),
      workflow: run.workflow || "",
      round: Format.number(run.round || 1),
      verdict:
        cond do
          run.shows == :running -> running_word(%{class: "text-info-soft-content"})
          run.shows == :paused -> PauseWords.line(run.paused, run.paused_path)
          true -> shows_words(run.shows)
        end
    )
  end

  @doc false
  # verdict_parts/2 is a stage run's workflow, round and verdict, in the words of its row
  # in `stage_runs/1`, the word running in the colours `running_class`. A run with no
  # workflow or no round has no part for it.
  def verdict_parts(run, running_class) do
    [
      run.workflow,
      run.round && gettext("round %{round}", round: Format.number(run.round)),
      cond do
        run.shows == :running -> running_word(%{class: running_class})
        run.shows == :paused -> PauseWords.line(run.paused, run.paused_path)
        true -> shows_words(run.shows)
      end
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp running_word(assigns) do
    ~H"""
    <span class={@class}>{shows_words(:running)}</span>
    """
  end

  defp shows_words(:passed), do: gettext("passed")
  defp shows_words(:failed), do: gettext("did not pass")
  defp shows_words(:questions), do: gettext("questions")
  defp shows_words(:queued), do: gettext("queued")
  defp shows_words(:running), do: gettext("running")
  defp shows_words(:no_verdict), do: gettext("ended without a verdict")
  defp shows_words(:undone), do: undone_word()

  # The word of a run an undo of its take in ended, after its round. The one place it is
  # set.
  defp undone_word, do: gettext("undone")

  @doc false
  # stage_notes/1 lists what the work item's next run reads as work item data
  # (`Apiary.Stages.notes/1`), oldest first: each with its kind and its stage.
  attr :id, :string, default: "work-item-notes"
  attr :notes, :list, required: true

  def stage_notes(assigns) do
    ~H"""
    <section :if={@notes != []} id={@id} class="q-xp-sec" aria-labelledby={"#{@id}-h"}>
      <h3 id={"#{@id}-h"}>{gettext("Notes for the next run")}</h3>
      <ol class="flex flex-col gap-2">
        <li :for={{note, i} <- Enum.with_index(@notes)} id={"#{@id}-#{i}"}>
          <p class="text-xs opacity-70">
            {note_words(note)}{if note.stage, do: " · #{note.stage}"}
          </p>
          <p :if={note.text not in [nil, ""]} class="whitespace-pre-line">{note.text}</p>
        </li>
      </ol>
    </section>
    """
  end

  # A comment on Explore's proposal is an answer to the run API, and a comment here.
  defp note_words(%{comment: true}), do: gettext("Comment")
  defp note_words(%{kind: :request_changes}), do: gettext("Changes requested")
  defp note_words(%{kind: :move}), do: gettext("Moved")
  defp note_words(%{kind: :escalation}), do: gettext("Escalation resolved")
  defp note_words(%{kind: :answer}), do: gettext("Answer")
  defp note_words(%{kind: :check}), do: gettext("Failed check")
  defp note_words(_note), do: gettext("Note")

  ## Approval marks

  @doc """
  The approval marks of the work item's artifacts: "Approved v2; v3 is newer" for an
  output with a newer version than the one approved, and "Changed after approval" for
  an earlier stage's artifact edited after its gate.
  """
  attr :id, :string, default: "work-item-marks"
  attr :index, :list, required: true

  def approval_marks(assigns) do
    assigns =
      assign(
        assigns,
        :marked,
        Enum.filter(assigns.index, &(&1.newer || &1.changed_after_approval))
      )

    ~H"""
    <ul :if={@marked != []} id={@id} class="flex flex-col gap-1">
      <li :for={mark <- @marked} id={"#{@id}-#{mark.type}-#{mark.name}"}>
        {type_words(mark.type)} ·
        <.approval_mark id={"#{@id}-#{mark.type}-#{mark.name}-m"} mark={mark} />
      </li>
    </ul>
    """
  end

  attr :id, :string, required: true
  attr :mark, :map, default: nil

  defp approval_mark(assigns) do
    ~H"""
    <span :if={@mark && @mark.approved && @mark.newer} id={@id} class="text-warning">
      {gettext("Approved v%{approved}; v%{newer} is newer",
        approved: Format.number(@mark.approved),
        newer: Format.number(@mark.newer)
      )}
    </span>
    <span :if={@mark && @mark.approved && @mark.newer && @mark.changed_after_approval}> · </span>
    <span :if={@mark && @mark.changed_after_approval} id={"#{@id}-changed"} class="text-warning">
      {gettext("Changed after approval")}
    </span>
    """
  end

  ## The board

  @doc """
  The board under the workflow model: a box for each stage of the workspace's current
  process version, then one for each stage that version removed while work items remain
  in it, marked with the version that has it. Each box has its name and its count.
  """
  attr :id, :string, default: "work-items-board"
  attr :columns, :list, required: true, doc: "`ApiaryWeb.WorkItemLive.Workflow.board/3`"

  def board_columns(assigns) do
    ~H"""
    <div id={@id} class="q-wl-flow q-wl-flow-stages" role="group" aria-label={gettext("Stages")}>
      <div
        :for={{column, i} <- Enum.with_index(@columns)}
        id={"#{@id}-#{i}"}
        class="q-wl-st content-start"
      >
        <span id={"#{@id}-#{i}-h"} class="q-wl-st-name">
          {column.name || gettext("Removed stage")}
        </span>
        <span class="q-wl-st-n">{Format.number(column.count)}</span>
        <span :if={column.removed} id={"#{@id}-#{i}-removed"} class="q-wl-st-what">
          <%= if column.version do %>
            {gettext("From version %{number}. This stage is not in the current version.",
              number: Format.number(column.version)
            )}
          <% else %>
            {gettext("This stage is not in the current version.")}
          <% end %>
        </span>
      </div>
    </div>
    """
  end

  ## Words

  @doc false
  # type_words/1 is an artifact type in a sentence: its name with spaces for hyphens,
  # "acceptance criteria" for `acceptance-criteria`.
  def type_words(type) when is_binary(type), do: String.replace(type, "-", " ")
  def type_words(type), do: to_string(type)

  defp version_words(type, nil), do: type_words(type)

  defp version_words(type, number),
    do: gettext("%{type} v%{number}", type: type_words(type), number: Format.number(number))

  @doc false
  # output_versions/1 is the summary's pieces of the record block at a stage after Explore:
  # "spec v1" for each of the current stage's outputs that has a version, in the stage's
  # order. An output with no version has no piece, as Explore's proposal and questions do.
  def output_versions(%{outputs: outputs}) do
    for %{type: type, version: number} when is_integer(number) <- outputs,
        do: version_words(type, number)
  end

  @doc "Artifact types in a sentence: \"acceptance criteria and mockup\"."
  def outputs_words(types), do: types |> Enum.map(&type_words/1) |> words_list()

  defp words_list([]), do: ""
  defp words_list([one]), do: one

  defp words_list(many) do
    {init, [last]} = Enum.split(many, -1)
    gettext("%{list} and %{last}", list: Enum.join(init, ", "), last: last)
  end
end
