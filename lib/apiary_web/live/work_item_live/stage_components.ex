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
  #     `move_back` or `close`), `note`, and `stage` for `move_back`; or `switch`, the id
  #     of the track to switch to, with no `how`;
  #   * `"stage_move"` - Move back while the stage waits for inputs: `stage` and `note`.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :html

  alias ApiaryWeb.{PauseWords, People, SettingsComponents}
  alias ApiaryWeb.WorkItemComponents
  alias ApiaryWeb.WorkItemLive.Workflow

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
            stage[:not_run] && "q-wi-stage-skipped",
            stage.at == :now && @wait && "q-wi-stage-wait"
          ]}
          aria-current={stage.at == :now && "step"}
        >
          <span class="q-wi-stage-n" aria-hidden="true">
            <%= cond do %>
              <% stage[:not_run] -> %>
              <% stage.at == :done -> %>
                <.icon name="hero-check-micro" class="size-3" />
              <% true -> %>
                {i}
            <% end %>
          </span>
          {stage.name}
          <span :if={stage[:not_run]} id={"#{@id}-#{stage.id}-not-run"} class="q-wi-stage-note">
            {gettext("Not run")}
          </span>
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

  attr :version_path, :any,
    default: nil,
    doc: "a function of a version's public id (`av_…`): its page; nil for no links"

  attr :recorded, :list,
    default: [],
    doc:
      "the versions an approval at the gate records (`Apiary.Stages.gate_frames/3`), " <>
        "`%{type, name, version}`; the gate lists those no output line shows"

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
        version_path={@version_path}
        recorded={@recorded}
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
  attr :version_path, :any, default: nil
  attr :recorded, :list, default: []
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
    <.needs id={@id} page={@page} types={@missing} />
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
      version_path={@version_path}
      recorded={@recorded}
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

  # What the stage needs: a line, then each type.
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
      </li>
    </ul>
    """
  end

  attr :id, :string, required: true
  attr :page, :map, required: true
  attr :number, :integer, required: true
  attr :version_path, :any, default: nil
  attr :recorded, :list, default: []
  attr :asking, :atom, default: nil
  attr :error, :atom, default: nil

  defp gate_card(assigns) do
    shown = assigns.page |> shown_outputs() |> Enum.flat_map(&named_rows/1) |> by_scenario()
    on_lines = MapSet.new(shown, & &1[:version_id])

    assigns =
      assign(assigns,
        marks: Map.new(assigns.page.index, &{{&1.type, &1.name}, &1}),
        versions: Enum.filter(shown, & &1.version_id),
        # At a Confirm gate the proposal can exist with no artifact, so an output with no
        # version is not shown as missing.
        shown: shown,
        drafts: Map.get(assigns.page, :drafts, []),
        # The other versions the approval records, one line for each. The questions are
        # on the Questions tab.
        others:
          Enum.reject(
            assigns.recorded,
            &(&1.type == "questions" or MapSet.member?(on_lines, &1.version.public_id))
          ),
        # A gate `none` takes no decision: the stage passes on once its outputs exist.
        decides: assigns.page.gate_kind != "none",
        started_no_run: started_no_run?(assigns.page),
        # The list of outputs says nothing while no output has a version.
        no_outputs_yet:
          started_no_run?(assigns.page) and Enum.all?(assigns.page.outputs, &is_nil(&1.version))
      )

    ~H"""
    <div id={@id} class="flex flex-col gap-2">
      <p :for={{draft, i} <- Enum.with_index(@drafts)} id={"#{@id}-draft-#{i}"}>
        {gettext("Submission:")}
        <.external_link href={draft.url}>
          {gettext("the draft in %{repository}", repository: draft.path)}
        </.external_link>
      </p>
      <div :if={@page.track && @page.offers == []} id={"#{@id}-track"} class="flex flex-col gap-1">
        <p id={"#{@id}-path"} class="flex items-center gap-2">
          <span class="text-sm font-semibold">{gettext("Track")}</span>
          <.badge color="success">{@page.track.name}</.badge>
        </p>
        <p :if={@started_no_run} id={"#{@id}-no-run"}>
          {gettext("Read the inputs below, then approve.")}
        </p>
      </div>
      <h3
        :if={not @no_outputs_yet and (@shown != [] or @page.outputs == [])}
        class="text-sm font-semibold"
      >
        {gettext("Outputs")}
      </h3>
      <p :if={@page.outputs == [] and not @no_outputs_yet} id={"#{@id}-none"}>
        {gettext("This stage has no outputs.")}
      </p>
      <ul :if={@shown != [] and not @no_outputs_yet} id={"#{@id}-outputs"} class="flex flex-col gap-1">
        <li :for={output <- @shown} id={"#{@id}-output-#{frame_key(output)}"}>
          <.link
            :if={@version_path && output[:version_id]}
            id={"#{@id}-version-#{frame_key(output)}"}
            navigate={@version_path.(output.version_id)}
            class="text-accent"
          >
            {version_words(output.type, output.name, output.version)}
          </.link>
          <span :if={!(@version_path && output[:version_id])}>
            {version_words(output.type, output.name, output.version)}
          </span>
          · <span id={"#{@id}-check-#{frame_key(output)}"}>{check_words(output)}</span>
          <.approval_mark
            id={"#{@id}-mark-#{frame_key(output)}"}
            mark={@marks[{output.type, output.name}]}
          />
        </li>
      </ul>
      <ul :if={@others != []} id={"#{@id}-recorded"} class="flex flex-col gap-1">
        <li :for={other <- @others} id={"#{@id}-recorded-#{frame_key(other)}"}>
          <.link
            :if={@version_path}
            navigate={@version_path.(other.version.public_id)}
            class="text-accent"
            phx-no-format
          >{version_words(other.type, other.version.number)}<%= if other.name != "main" do %> · {other.name}<% end %></.link>
          <span :if={!@version_path} phx-no-format>{version_words(other.type, other.version.number)}<%= if other.name != "main" do %> · {other.name}<% end %></span>
        </li>
      </ul>
      <.needs
        :if={@page.missing_outputs != [] and not @page.confirm_gate}
        id={@id}
        page={@page}
        types={@page.missing_outputs}
      />
      <p
        :if={@decides and not @page.confirm_gate and match?({:listed, _ids}, @page.approvers)}
        id={"#{@id}-approvers"}
        class="text-xs opacity-70"
      >
        {gettext("Only the members this stage lists can approve.")}
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
                {version_words(output.type, output.name, output.version)}
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
              <.icon name="hero-check-micro" class="size-3.5" />{gettext("Approve")}
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

  @doc false
  # started_no_run?/1 is whether `page`'s stage, at a gate that offers no track, of a work
  # item on a track, ran no workflow in the take in and has entries the runner passed over:
  # there is no run of the stage to read. A work item on no track is never so.
  @spec started_no_run?(map) :: boolean
  def started_no_run?(%{
        state: :at_gate,
        track: %{},
        offers: [],
        stage: stage,
        runs: runs,
        skips: skips
      }) do
    not Enum.any?(runs, &(&1.stage_id == stage.id)) and
      Enum.any?(skips, &(&1.stage_id == stage.id))
  end

  def started_no_run?(_page), do: false

  # The questions are in the Open questions frame of the stage's tab and on the Questions
  # tab, so the list of outputs leaves them out.
  defp shown_outputs(%{confirm_gate: true, outputs: outputs}),
    do: Enum.filter(outputs, &(&1.version_id && &1.type != "questions"))

  defp shown_outputs(%{outputs: outputs}), do: Enum.reject(outputs, &(&1.type == "questions"))

  # An output's rows on the gate card: one for the version of each of its names that the
  # gate shows (`names`), or one for the output where it has none, its version nil or
  # `main`'s. A row's DOM ids take `frame_key/1` of its type and name.
  defp named_rows(%{names: [_ | _] = names} = output) do
    for named <- names, do: Map.merge(output, Map.take(named, [:name, :version, :version_id]))
  end

  defp named_rows(output), do: [Map.put(output, :name, "main")]

  # The gate card's rows at a stage with a `verification` output: the films and pictures
  # (`ApiaryWeb.WorkItemLive.VerifyTab.media/0`) together, in the place of the first, in
  # the order of their names (`Apiary.Artifacts.name_order/1`), so each scenario's film or
  # pictures follow the one before; the other rows as they are. Elsewhere, `rows`.
  defp by_scenario(rows) do
    media = ApiaryWeb.WorkItemLive.VerifyTab.media()

    case Enum.split_with(rows, &(&1.type in media)) do
      {[], _rows} ->
        rows

      {films, others} ->
        if Enum.any?(rows, &(&1.type == "verification")) do
          at = Enum.find_index(rows, &(&1.type in media))
          sorted = Enum.sort_by(films, &{Apiary.Artifacts.name_order(&1.name), &1.type})
          {before, later} = Enum.split(others, at)
          before ++ sorted ++ later
        else
          rows
        end
    end
  end

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
  # it is (only where `Workflow.accept?/2` is true: with a result, with no required output
  # missing where the accept takes the stage to its gate, and with no switch), Move back
  # and Close; where the page shows a switch
  # (`page.switch`, one track a button, "Switch to <track>"), only the switches and Close.
  # Their form has the note field and Run another round in the block, which name it in
  # their `form` attribute, so the note goes with every action.
  defp escalation_card(assigns) do
    switch = Map.get(assigns.page, :switch) || []
    result = Map.get(assigns.page, :accept_needs, []) == []

    assigns =
      assign(
        assigns,
        :escalation,
        assigns.page.escalation ||
          %{
            cause: :escalate,
            accept: Workflow.accept?(result, switch),
            points: [],
            run: nil,
            harness_path: nil,
            return_to: nil
          }
      )
      |> assign(:switch, switch)

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
        <div :for={track <- @switch} class="flex flex-col gap-1">
          <div class="q-wi-acts flex-wrap">
            <.button
              id={"#{@id}-switch-#{track.id}"}
              type="submit"
              name="switch"
              value={track.id}
            >
              {switch_label(track)}
            </.button>
          </div>
          <p
            :if={track.first}
            id={"#{@id}-switch-#{track.id}-line"}
            class="text-xs opacity-70"
          >
            {switch_line(track)}
          </p>
        </div>
        <div :if={@escalation.accept} class="q-wi-acts flex-wrap">
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
        <div :if={Workflow.move_back?(@switch, @page.earlier)} class="q-wi-acts flex-wrap">
          <label for={"#{@id}-stage"} class="sr-only">{gettext("Earlier stage")}</label>
          <select id={"#{@id}-stage"} name="stage">
            <option
              :for={stage <- Enum.reverse(@page.earlier)}
              value={stage.id}
              selected={stage.id == Map.get(@escalation, :return_to)}
            >
              {stage.name}
            </option>
          </select>
          <.button id={"#{@id}-move"} type="submit" name="how" value="move_back">
            {gettext("Move back")}
          </.button>
        </div>
        <div class="q-wi-acts flex-wrap">
          <.button id={"#{@id}-close"} type="submit" name="how" value="close">
            {gettext("Close")}
          </.button>
          <p :if={@switch != []} id={"#{@id}-close-line"} class="basis-full text-xs opacity-70">
            {gettext("Ends the work item. No draft is sent.")}
          </p>
        </div>
      </form>
    </div>
    """
  end

  # switch_label/1 is the label of the button that switches to `track`; a return limit's
  # point uses it for the button's words (`ApiaryWeb.WorkItemLive.Workflow`).
  @doc false
  @spec switch_label(map) :: String.t()
  def switch_label(track), do: gettext("Switch to %{track}", track: track.name)

  # What a switch runs: the stage it starts, with the run's outputs, then the stages after
  # it that run on the track.
  defp switch_line(%{later: []} = track) do
    gettext(
      "%{stage} runs for the first time, with your note and the run's outputs. The next run undoes this attempt.",
      stage: track.first
    )
  end

  defp switch_line(track) do
    ngettext(
      "%{stage} runs for the first time, with your note and the run's outputs. The next run undoes this attempt, then %{later} runs on %{track}.",
      "%{stage} runs for the first time, with your note and the run's outputs. The next run undoes this attempt, then %{later} run on %{track}.",
      length(track.later),
      stage: track.first,
      later: words_list(track.later),
      track: track.name
    )
  end

  ## What the run needs from you

  @doc """
  The block "What the run needs from you": the points of the stage's open escalation, one
  numbered sentence each, followed by the sentence of its action: "Answer question N.",
  with "question N" linked to the question on the Questions tab, or "Run another
  round.", or the point's fix line in its place. A point whose text opens with its action
  (`in_text`) has no sentence after it, nor has a point with no action sentence (also
  `in_text`): a return limit's count, where the card shows neither a switch nor Move
  back. While the stage is escalated, a reader who may decide finds the note field and
  Run another round under the points; they belong to the form of the escalation card in
  the rail (`stage_card/1`). While the stage waits for
  answers, the answers run the next round, so the block has no form.
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
    default: "work-item-questions",
    doc: "the id before `-question-N` of a question on that tab"

  attr :scope, :any,
    default: nil,
    doc: "the reader's scope, with `number`, for the outputs of the run on an escalation"

  attr :number, :integer, default: nil, doc: "the work item's number"

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

    assigns =
      assign(assigns,
        switch: Map.get(assigns.page, :switch) || [],
        entry: assigns.page.escalation && assigns.page.escalation[:entry]
      )

    ~H"""
    <section id={@id} class={["q-xp-frame q-xp-needs", @class]} aria-labelledby={"#{@id}-h"}>
      <div class="q-xp-frame-h">
        <.icon name="hero-flag-micro" class="q-xp-frame-i size-4" />
        <h2 id={"#{@id}-h"} class="q-xp-frame-t">{gettext("What the run needs from you")}</h2>
      </div>
      <div class="q-xp-body q-xp-needs-body">
        <%!-- Where a switch is offered, the outputs of the run come first, then the points,
        then the note and Run another round. --%>
        <.live_component
          :if={(@switch != [] and @scope) && @number && @page.escalation && @page.escalation[:run_id]}
          module={ApiaryWeb.RunOutputs}
          id={"#{@id}-outputs"}
          scope={@scope}
          number={@number}
          run_id={@page.escalation.run_id}
          heading={gettext("The run's outputs")}
          skip={["verdict"]}
          class="q-xp-needs-outputs"
        />
        <ol
          :if={@points != []}
          id={"#{@id}-points"}
          class={["q-xp-needs-points", @switch != [] && "mt-6"]}
        >
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
        <.needs_form :if={@form} {assigns} />
      </div>
    </section>
    """
  end

  # The note and Run another round of the block, which name the escalation card's form in
  # their `form` attribute. Where a switch is offered, a line under the button says what
  # it runs.
  defp needs_form(assigns) do
    ~H"""
    <div class="q-xp-needs-form flex flex-col gap-2">
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
      <p :if={@switch != [] and @entry} id={"#{@field}-another-line"} class="text-xs opacity-70">
        {gettext(
          "Runs %{entry} again with your note. Use it when the run changed more than the work item asks.",
          entry: @entry
        )}
      </p>
    </div>
    """
  end

  attr :point, :map, required: true
  attr :href, :string, default: nil, doc: "the question of an `answer` point, nil for none"
  attr :harness_path, :any, default: nil

  # A point's sentence, escaped, then the sentence of its action. An `answer` point adds
  # "Answer question N.", with "question N" linked to its question; a `run_again` point
  # adds "Run another round.", or its fix line, escaped, in its place: a run's or a stop
  # cause's. In a fix line, the words "the set-up step Harness" link to that step when
  # `harness_path` is set (`gap_line/1`); only a run stopped at that step sets it. A point
  # whose text opens with its action (`in_text`, a failed check's) adds nothing, nor does
  # a point with no action sentence (`in_text` too): a return limit's count, where the
  # card shows neither a switch nor Move back.
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

  defp point(%{point: %{in_text: true}} = assigns) do
    ~H"""
    {@point.text}
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
      verdict: verdict_word(run, "text-info-soft-content")
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
      verdict_word(run, running_class)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  # The verdict of a stage run, or what it shows without one. A run a member cancelled
  # that has not ended (`cancelling`, `Apiary.Runs.Cancel.cancelling?/1`) is Cancelling,
  # in the colours of its run's state (`run_state`) as the run's line on the tab: those of
  # running while it runs, red once it is lost.
  defp verdict_word(run, running_class) do
    cond do
      Map.get(run, :cancelling) == true ->
        word(%{class: cancelling_class(run, running_class), word: gettext("Cancelling")})

      run.shows == :running ->
        word(%{class: running_class, word: shows_words(:running)})

      run.shows == :paused ->
        PauseWords.line(run.paused, run.paused_path)

      true ->
        shows_words(run.shows)
    end
  end

  defp cancelling_class(run, running_class) do
    case Map.get(run, :run_state) do
      state when state in [nil, :running] -> running_class
      state -> WorkItemComponents.state_class(%{state: state})
    end
  end

  defp word(assigns) do
    ~H"""
    <span class={@class}>{@word}</span>
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
  # "acceptance criteria" for `acceptance-criteria` (`Apiary.Artifacts.Type.words/1`).
  def type_words(type) when is_binary(type), do: Apiary.Artifacts.Type.words(type)
  def type_words(type), do: to_string(type)

  defp version_words(type, nil), do: type_words(type)

  defp version_words(type, number),
    do: gettext("%{type} v%{number}", type: type_words(type), number: Format.number(number))

  # A version of a named artifact in today's plain form: the type's words, the name where
  # it is not `main`, and the number, such as "demo video scenario-1 v1".
  defp version_words(type, name, number) when name in [nil, "main"],
    do: version_words(type, number)

  defp version_words(type, _name, nil), do: type_words(type)

  defp version_words(type, name, number),
    do:
      gettext("%{type} %{name} v%{number}",
        type: type_words(type),
        name: name,
        number: Format.number(number)
      )

  @doc false
  # output_versions/1 is the summary's pieces of the record block at a stage after Explore:
  # "spec v1" for each of the current stage's outputs that has a version, in the stage's
  # order. An output with no version has no piece, as Explore's proposal does. The
  # questions have none: they are on the Questions tab.
  def output_versions(%{outputs: outputs}) do
    for %{type: type, version: number} when is_integer(number) and type != "questions" <- outputs,
        do: version_words(type, number)
  end

  @doc """
  frame_key/1 is an output frame's part of its DOM ids: the artifact's type, then, where
  the name is not `main`, `--`, the name and `--`, such as `spec` or
  `test-features--other--`. A type or a name has no `--` (`Apiary.Artifacts.Type.name?/1`),
  so no frame's key, with or without an id's suffix, equals another named frame's key.
  """
  @spec frame_key(map) :: String.t()
  def frame_key(%{type: type, name: name}) when name != "main", do: "#{type}--#{name}--"
  def frame_key(%{type: type}), do: type

  @doc "Artifact types in a sentence, each with \"the\": \"the acceptance criteria and the mockup\"."
  def outputs_words(types),
    do: types |> Enum.map(&gettext("the %{type}", type: type_words(&1))) |> words_list()

  @doc """
  approver_line/3 is the sentence that says who decides on the stage named `stage`, for a
  reader who may not: `approvers` as `ApiaryWeb.WorkItemLive.Workflow.approvers/1` returns
  them, and `members`, the workspace's memberships, each with its `user`, as
  `Apiary.Organisations.list_workspace_members/1` returns them. The names of the listed
  members follow the list's order; a listed id that is no member's is left out. With no
  member left, or none listed, the sentence says that nobody may approve the stage.
  """
  @spec approver_line(String.t(), :members | {:listed, [String.t()]}, [map]) :: String.t()
  def approver_line(stage, :members, _members),
    do: gettext("A member who may approve %{stage} decides.", stage: stage)

  def approver_line(stage, {:listed, ids}, members) do
    names = Map.new(members, &{&1.user.id, People.short(People.email(&1.user))})

    case for(id <- Enum.uniq(ids), Map.has_key?(names, id), do: names[id]) do
      [] ->
        gettext(
          "Nobody may approve %{stage}. Ask an admin to list its approvers in Workspace settings › %{workflows}.",
          stage: stage,
          workflows: SettingsComponents.workflows_label()
        )

      listed ->
        gettext("An approver of %{stage} decides: %{approvers}.",
          stage: stage,
          approvers: words_list(listed)
        )
    end
  end

  defp words_list([]), do: ""
  defp words_list([one]), do: one

  defp words_list(many) do
    {init, [last]} = Enum.split(many, -1)
    gettext("%{list} and %{last}", list: Enum.join(init, ", "), last: last)
  end
end
