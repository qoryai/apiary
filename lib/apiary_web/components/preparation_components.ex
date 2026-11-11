defmodule ApiaryWeb.PreparationComponents do
  @moduledoc """
  The **Run** list of a run's Timeline (`docs/ui.md`, The run page): the run's steps from
  its queue to the removal of its machine, from `Apiary.Runs.Preparation`. Each step is
  named as an action, in the order the steps run, with its state, its start time and its
  duration:

    * Queue the run, from the queue to the claim, for a run a node pool claimed, with
      Queued;
    * Request a machine, from the claim to the starter's `dispatched`, with Machine
      requested, the pool and the machine type;
    * Start the machine, from `dispatched` to the redemption of the run's code, with
      Machine started once the machine started, and the lines of the step of the kind
      `machine`, after a first line that Qory Apiary writes when the step started no later
      than the redemption, `create machine` and the seconds from `dispatched` to that
      step's start, at the time of `dispatched`. It is failed once that step failed. It
      has Started as and the machine log for an instance admin;
    * Prepare the machine, the steps that ran before the first agent session
      (`step_label/1`);
    * Agent session 1, 2 and on, one per agent session (`Apiary.Runs.Preparation`): Prepare
      the session, with Start the agent, Start the wall and any other step of the session,
      in the order they ran; Run the agent, from the session's start to its exit, with
      Started, Finished, the result and the model, then the session's Timeline (the
      `session` slot); and Save the outputs, the artifact versions the session saved and
      its push steps. A prebuild, a run of the queue for the step `prebuild`, has in their
      place Build the image, its session, with the session's join and wall, Started,
      Finished and the session's Timeline, and Save the outputs, its `dev.qory.run.built`
      with the image, as steps of the run (`prebuild_nodes/3`). Save the outputs is
      failed, with its cause line (`built_cause/1`), when the image was not saved: its
      report failed the check that stores it, or the run failed, was lost or was
      cancelled after the build and sent none;
    * Remove the machine, last (`clean_up/3`), with Machine removed, the cause and the
      machine's time alive; for a run on a permanent machine, Machine stays registered in
      its place.

  The steps inside a step show no time. A step that did not run has no row, but after a
  failed step: once the run has ended, each step after it that did not run has a grey
  row, Skipped. Remove the machine is not skipped when the machine was removed. A helper
  step (`Apiary.Runs.Preparation`) has no row: a `copy` step, and the join and the wall
  of a bare session. The list is not drawn when it has no row.

  The heading is "Run on" and the pool, with the run's state in the word of its badge:
  Pending, Running, Completed, Failed, Cancelled or Lost. A run no pool claimed has "Run",
  with its state.

  A step's output is its lines, each with its number and its time, at most 2,500 lines.

  A failed or running row is open when it appears, and so is Start the machine while its
  `machine` step runs or once that step failed. Prepare the machine is running, and open,
  on a live run until a step of an agent session begins or the preparation stops, so it
  shows no end between two steps, where no clock counts; Prepare the session is running
  until its session starts. An Agent session and its Run the agent are open while the run
  is alive. The others are closed. After that, a person's open or close stays. A failed
  step has the cause line under its output, which states what happened, with no advice.
  While the run is alive, a running row has a clock that ticks in the browser, and the
  heading has the run's time so far, from the first row's start; once the run has ended,
  the heading has the time from the first row's start to the end of the last row.

  Remove the machine shows what the pool's starter reported about the removal of the
  machine (`clean_up/3`): the removal's time from the run's end to a `gone` report, with
  the cause and the machine's time alive; else the state of the last report; else, once
  the run has ended and a machine existed for its dispatch, that a report is awaited for
  15 minutes after the run ended, then that none came. The 15 minutes are counted at
  render, against the time the caller passes (`now`); the caller renders again when they
  pass (`clean_up_due/3`).

  A push step's row, and its Save the outputs, open when the push fails on an open page.
  A failed push is no failed preparation (`Apiary.Runs.Preparation`).

  A step's name and output came from the run and are untrusted: they are interpolated,
  so they are escaped, and shown as a page shows a text an external system sent
  (`Apiary.ExternalText`). So are an artifact's type, the pool's name and the model. The
  machine log is shown to an instance admin alone, under Start the machine; the caller
  reads it for an instance admin and hands it over.
  """
  use Phoenix.Component
  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.CoreComponents, only: [icon: 1]
  import ApiaryWeb.ExternalText, only: [external_text: 1]
  import ApiaryWeb.RichText, only: [rich: 1, rich_gettext: 2]
  import ApiaryWeb.RunComponents, only: [duration: 1, time_legend: 1]

  alias Apiary.ExternalText
  alias Apiary.Runs.Preparation
  alias ApiaryWeb.{Format, MachineTypeWords, RunPageComponents}
  alias Phoenix.LiveView.JS

  # The most of a machine log the list shows, in bytes.
  @machine_log_bytes 65_536

  # How long after the run ended Remove the machine waits for a report, in seconds.
  @clean_up_wait_seconds 15 * 60

  @typedoc """
  What the last row of the list shows: the starter's last report, `{:report, state, at}`;
  that a report is awaited until `due_at`, `{:waiting, due_at}`; that none came,
  `:no_report`; that the machine is permanent and stays registered, `:stays`.
  """
  @type clean_up ::
          {:report, :deleting | :gone | :delete_failed, DateTime.t()}
          | {:waiting, DateTime.t()}
          | :no_report
          | :stays

  @doc """
  Whether a preparation has a row to show: a machine, a step with a row, a push, or an
  artifact version the run pushed.
  """
  @spec shown?(Preparation.t() | nil) :: boolean
  def shown?(nil), do: false

  def shown?(preparation) do
    preparation.machine != nil or Enum.any?(preparation.steps, &(not helper?(&1))) or
      pushes(preparation) != [] or Map.get(preparation, :outputs, []) != [] or
      Map.get(preparation, :queued) != nil
  end

  @doc """
  Whether the run page shows the list: the preparation has a row to show (`shown?/1`),
  or the list has a last row (`clean_up/3`), as for a run on a permanent machine.
  """
  @spec shown?(Preparation.t() | nil, clean_up | nil) :: boolean
  def shown?(preparation, clean_up), do: shown?(preparation) or clean_up != nil

  @doc """
  Whether the run's Timeline is drawn inside the Run the agent rows, or a prebuild's Build
  the image: the list is shown (`shown?/2`) and an agent session started. Else the
  Timeline follows the list.
  """
  @spec session_group?(Preparation.t() | nil, clean_up | nil) :: boolean
  def session_group?(preparation, clean_up),
    do: shown?(preparation, clean_up) and preparation.session_started_at != nil

  @doc """
  Whether the page stops reading a preparation at each flush: it was read once the run had
  ended, or once its session had started with no step running. A step's start or exit,
  the session's end and the run's exit still read it, once each
  (`ApiaryWeb.RunLive.Show`).
  """
  @spec settled?(Preparation.t() | nil, boolean) :: boolean
  def settled?(nil, _alive), do: false
  def settled?(%{}, false), do: true

  def settled?(%{session_started_at: at, steps: steps}, true),
    do: at != nil and not Enum.any?(steps, &(&1.state == "running"))

  @doc """
  What the last row of the list shows for `preparation` at `now` (`t:clean_up/0`), or
  nil for no row. Whether `run` is alive follows from its state; for a run no node pool
  claimed, its node, preloaded as `run.node`, shows whether it ran on a permanent machine
  (a node of kind `:node`).

    * A report of the starter is shown as soon as it exists, whether the run is alive or
      not.
    * With no report, a run that has ended and whose dispatch was handed over waits for
      one until 15 minutes after the run ended (`machine.ended_at`), and then has none.
    * A run with no dispatch, on a permanent machine, once it has ended, keeps its
      machine: the row is Machine stays registered.
    * Anything else has no row: a run that goes on with no report, a dispatch released
      before a machine existed, and a run on no permanent machine.
  """
  @spec clean_up(Preparation.t() | nil, Apiary.Runs.Run.t(), DateTime.t()) :: clean_up | nil
  def clean_up(%{machine: %{end: %{state: state, at: at}}}, _run, _now),
    do: {:report, state, at}

  def clean_up(%{machine: %{} = machine}, run, now) do
    cond do
      alive?(run) or is_nil(machine.handed_over_at) or is_nil(machine.ended_at) ->
        nil

      DateTime.compare(now, due_at(machine)) == :lt ->
        {:waiting, due_at(machine)}

      true ->
        :no_report
    end
  end

  def clean_up(%{machine: nil}, %{node: %{kind: :node}} = run, _now),
    do: if(alive?(run), do: nil, else: :stays)

  def clean_up(_preparation, _run, _now), do: nil

  @doc """
  When Remove the machine of `preparation` changes from waiting for a report to no
  report, as `clean_up/3` shows it at `now`: the time, or nil when the row is not waiting.
  """
  @spec clean_up_due(Preparation.t() | nil, Apiary.Runs.Run.t(), DateTime.t()) ::
          DateTime.t() | nil
  def clean_up_due(preparation, run, now) do
    case clean_up(preparation, run, now) do
      {:waiting, due_at} -> due_at
      _other -> nil
    end
  end

  defp due_at(%{ended_at: ended_at}), do: DateTime.add(ended_at, @clean_up_wait_seconds)

  defp alive?(%{state: state}), do: state in Apiary.Runs.Run.alive_states()

  @doc """
  The list. `machine_log` is what the caller read of the machine's log: `{:ok, text,
  truncated}` for an instance admin, `:none` while no log has arrived, `{:deleted, days}`
  once a log that arrived can have been deleted (`days` is the machine logs' retention),
  `:unreadable` for one whose file cannot be read, and `:hidden` for anyone else.
  `alive` is whether the run is alive: nothing ticks once it has ended. `clean_up` is
  what Remove the machine shows (`clean_up/3`), nil for no report. `session_open` is the
  `sequence` of the start of the agent session whose Agent session and Run the agent
  open when they appear on a run that ended, as for a link to an event inside it; nil
  for none. `run_state` is the run's state, for the heading, and a session that paused
  on a run that is `completed` reads as one that succeeded. `wall` is whether the run
  has a wall: only then does a Start the wall that did not run have a row. The `session`
  slot is a session's Timeline, inside its Run the agent, called with that `sequence`.
  """
  attr :id, :string, default: "prepare-machine"
  attr :preparation, :map, required: true
  attr :machine_log, :any, default: :hidden
  attr :alive, :boolean, required: true
  attr :clean_up, :any, default: nil
  attr :session_open, :integer, default: nil
  attr :run_state, :string, default: nil
  attr :wall, :boolean, default: true
  slot :session

  def run_list(assigns) do
    preparation = finished(assigns.preparation, assigns.run_state)
    alive = assigns.alive
    machine = preparation.machine
    removed = removed_row(assigns.clean_up, machine)

    shown = %{
      machine: machine,
      steps: Enum.reject(preparation.steps, &helper?/1),
      pairs: pairs(preparation, alive),
      outputs: outputs_row(preparation)
    }

    queued = Map.get(preparation, :queued)

    assigns =
      assign(assigns,
        nodes:
          if(queued,
            do: queued_nodes(queued),
            else: nodes(preparation, removed, alive, assigns.session_open, assigns.wall)
          ),
        heading: heading(machine, assigns.run_state, alive),
        total:
          if(queued,
            do: %{from: queued.queued_at},
            else: run_total(shown, removed, alive)
          ),
        machine_step: machine_step(preparation),
        start_output: start_output(preparation)
      )

    ~H"""
    <section :if={@nodes != []} id={@id} class="q-prep" aria-labelledby={"#{@id}-h"}>
      <div class="q-prep-hd">
        <h2 id={"#{@id}-h"}>{@heading}</h2>
        <.duration
          :if={@total[:ms]}
          id={"#{@id}-total"}
          ms={@total.ms}
          class="q-prep-total"
        />
        <.duration
          :if={@total[:from]}
          id={"#{@id}-total"}
          elapsed_seconds={0}
          elapsed_at={@total.from}
          so_far
          class="q-prep-total"
        />
      </div>
      <.time_legend first={gettext("Started")} second={gettext("Took")} />
      <ol class="q-prep-steps">
        <li :for={node <- @nodes}>
          <.flow id={"#{@id}-#{node.key}"} node={node} alive={@alive}>
            <.events :if={node.kind != :build} lines={node.events} />
            <%!-- Why a queued run waits where a person fixes it, and who: in the fold,
                  under its events. --%>
            <div :if={node[:why] && node[:fix]}>
              <p id={"#{@id}-why"} class="q-prep-wait-cause"><.rich text={node.why} /></p>
              <p id={"#{@id}-why-fix"} class="q-prep-fix">{node.fix}</p>
            </div>
            <%= if node.kind == :start do %>
              <.output
                :if={@start_output}
                id={"#{@id}-start-machine-output"}
                output={@start_output}
                pruned_at={@preparation.log_pruned_at}
              />
              <%!-- The vendor's type of the machine, for an instance admin alone
              (`Apiary.Runs.Preparation`), labelled as the machine log is. --%>
              <dl
                :if={@preparation.machine.started_as}
                id={"#{@id}-started-as"}
                class="q-prep-facts"
              >
                <dt>{gettext("Started as (instance admins)")}</dt>
                <dd><.external_text text={@preparation.machine.started_as} /></dd>
              </dl>
              <.machine_log id={"#{@id}-machine-log"} log={@machine_log} />
              <.cause
                :if={@preparation.stopped && @preparation.stopped.step == nil}
                id={"#{@id}-cause"}
                text={@preparation.stopped.what}
              />
              <.cause
                :if={
                  @preparation.stopped && @machine_step &&
                    @preparation.stopped.step == @machine_step.number
                }
                id={"#{@id}-cause"}
                text={cause_what(@preparation.stopped)}
              />
            <% end %>
            <ol :if={node.children != []} class="q-prep-steps">
              <li :for={child <- node.children}>
                <.inner_step
                  id={@id}
                  node={child}
                  preparation={@preparation}
                  alive={@alive}
                  session={@session}
                />
              </li>
            </ol>
            <%!-- A prebuild's Build the image: after its steps, its session's events, the
            session's cause line and its Timeline, as Run the agent has them. --%>
            <%= if node.kind == :build do %>
              <.events lines={node.events} />
              <.cause :if={node.cause} id={"#{@id}-cause"} text={node.cause} />
              {if node.session, do: render_slot(@session, node.session.sequence)}
            <% end %>
            <%!-- A prebuild's Save the outputs whose image was not saved: its cause line. --%>
            <.cause
              :if={node.kind == :outputs and node.cause}
              id={"#{@id}-outputs-cause"}
              text={node.cause}
            />
          </.flow>
          <%!-- Why a queued run waits, under Queue the run, open or closed, where nobody
                fixes it. --%>
          <p :if={node[:why] && !node[:fix]} id={"#{@id}-why"} class="q-prep-why">
            <.rich text={node.why} />
          </p>
        </li>
      </ol>
    </section>
    """
  end

  attr :id, :string, required: true, doc: "the list's id"
  attr :node, :map, required: true
  attr :preparation, :map, required: true
  attr :alive, :boolean, required: true
  attr :session, :list, default: [], doc: "the `session` slot of `run_list/1`"

  # A step inside a step, with no start or duration shown: a step of the run, with its output
  # and cause line; a step made of steps, as Prepare the session; Run the agent, with its
  # session's Timeline; or a step that did not run.
  defp inner_step(%{node: %{step: %{} = step}} = assigns) do
    assigns = assign(assigns, :step, step)

    ~H"""
    <.step_row
      id={"#{@id}-#{@node.key}"}
      step={@step}
      alive={@alive}
      pruned_at={@preparation.log_pruned_at}
      open={open?(@step.state)}
      label={step_label(@step)}
      times={false}
    >
      <.cause
        :if={@preparation.stopped && @preparation.stopped.step == @step.number}
        id={"#{@id}-cause"}
        text={cause_what(@preparation.stopped)}
      />
    </.step_row>
    """
  end

  defp inner_step(assigns) do
    ~H"""
    <.flow id={"#{@id}-#{@node.key}"} node={@node} alive={@alive} times={false}>
      <.events lines={@node.events} />
      <ol :if={@node.children != []} class="q-prep-steps">
        <li :for={child <- @node.children}>
          <.inner_step id={@id} node={child} preparation={@preparation} alive={@alive} />
        </li>
      </ol>
      {if @node.kind == :agent and @node.session != nil,
        do: render_slot(@session, @node.session.sequence)}
    </.flow>
    """
  end

  attr :id, :string, required: true
  attr :node, :map, required: true
  attr :alive, :boolean, required: true
  attr :times, :boolean, default: true, doc: "whether the row shows its start and duration"
  slot :inner_block

  # One step's row. A step that did not run is a grey row with "Skipped" and no content.
  # Remove the machine with no event to show is a row with no content too: its words
  # contain the report's state, so its mark has no text for a screen reader. Any other
  # step opens to its events and its steps.
  defp flow(%{node: %{state: "skipped"}} = assigns) do
    ~H"""
    <div id={@id} class="q-hd q-prep-row q-prep-skipped" data-state="skipped">
      <span class="size-3"></span>
      <.state_mark state="skipped" />
      <span class="q-k q-prep-name">{@node.name}</span>
      <span class="q-t">
        <span class="q-tc1 q-prep-cell"></span>
        <span class="q-tc2 q-prep-cell q-prep-skip">{gettext("Skipped")}</span>
      </span>
    </div>
    """
  end

  # A step of a queued run that has not run yet: a grey row with no mark, no time
  # and no content.
  defp flow(%{node: %{state: "not_run"}} = assigns) do
    ~H"""
    <div id={@id} class="q-hd q-prep-row q-prep-skipped" data-state="not_run">
      <span class="size-3"></span>
      <span class="q-prep-unrun self-center" aria-hidden="true"></span>
      <span class="q-k q-prep-name">{@node.name}</span>
      <span class="q-t">
        <span class="q-tc1 q-prep-cell"></span>
        <span class="q-tc2 q-prep-cell"></span>
      </span>
    </div>
    """
  end

  defp flow(%{node: %{clean_up: kind, events: []}} = assigns) when kind != nil do
    ~H"""
    <div id={@id} class="q-hd q-prep-row" data-state={@node.state} data-clean-up={@node.clean_up}>
      <span class="size-3"></span>
      <.flow_head node={@node} alive={@alive} times={@times} id={@id} />
    </div>
    """
  end

  defp flow(assigns) do
    ~H"""
    <details
      id={@id}
      class="q-tool q-prep-step"
      data-state={@node.state}
      data-clean-up={@node.clean_up}
      open={flow_open?(@node)}
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <summary class="q-hd q-prep-row">
        <.icon name="hero-chevron-right-micro" class="q-chev size-3" />
        <.flow_head node={@node} alive={@alive} times={@times} id={@id} />
      </summary>
      <div class={["q-xb", @node.state == "failed" && "q-xb-bad"]}>
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  # A row is open when it appears while it runs or once it failed, unless its `open` is set.
  defp flow_open?(%{open: open}) when is_boolean(open), do: open
  defp flow_open?(%{state: state}), do: open?(state)

  attr :id, :string, required: true
  attr :node, :map, required: true
  attr :alive, :boolean, required: true
  attr :times, :boolean, required: true

  # A step row's mark, name, words, start and duration; while it runs, a clock that ticks
  # from its start.
  defp flow_head(assigns) do
    assigns = assign(assigns, :ticking, assigns.alive and assigns.node.ticking)

    ~H"""
    <.clean_up_mark :if={@node.clean_up} kind={@node.clean_up} />
    <.state_mark :if={!@node.clean_up} state={@node.state} pulse={@ticking} />
    <span class="q-k q-prep-name">{@node.name}</span>
    <span :if={@node.text} class="q-s">{@node.text}</span>
    <span class="q-t">
      <span :if={@node.state == "running" and !@node.clean_up} class="q-running">
        {gettext("Running")}
      </span>
      <span class="q-tc1 q-prep-cell"><.clock :if={@times && @node.at} at={@node.at} /></span>
      <span class="q-tc2 q-prep-cell">
        <.duration :if={@times && @node.duration_ms} ms={@node.duration_ms} class="q-d" />
        <.duration
          :if={@times and @ticking and @node.since != nil}
          id={"#{@id}-clock"}
          elapsed_seconds={0}
          elapsed_at={@node.since}
          class="q-d"
        />
      </span>
    </span>
    """
  end

  attr :kind, :atom, required: true

  # Remove the machine's mark, from the pool starter's last report (`clean_up/3`).
  defp clean_up_mark(assigns) do
    ~H"""
    <%= case @kind do %>
      <% :gone -> %>
        <.icon name="hero-check-circle-micro" class="q-prep-ok size-4 self-center" />
        <span class="sr-only">{gettext("Succeeded")}</span>
      <% :delete_failed -> %>
        <.icon name="hero-x-circle-micro" class="q-prep-bad size-4 self-center" />
        <span class="sr-only">{gettext("Failed")}</span>
      <% kind when kind in [:deleting, :waiting] -> %>
        <.icon name="hero-ellipsis-horizontal-circle-micro" class="q-running size-4 self-center" />
      <% _none -> %>
        <.icon name="hero-minus-circle-micro" class="text-faint size-4 self-center" />
    <% end %>
    """
  end

  attr :lines, :list, required: true, doc: "`{label, value}` each"

  # A step's events and facts: an event with its time, a fact with its words.
  defp events(assigns) do
    ~H"""
    <dl :if={@lines != []} class="q-prep-facts">
      <%= for {label, value} <- @lines do %>
        <dt :if={match?({:external, _text}, label)}><.external_text text={elem(label, 1)} /></dt>
        <dt :if={!match?({:external, _text}, label)}>{label}</dt>
        <dd>
          <%= case value do %>
            <% {:at, at} -> %>
              <.clock at={at} />
            <% {:external, text} -> %>
              <.external_text text={text} />
            <% {:mono, text} -> %>
              <span class="font-mono text-[12.5px]"><.external_text text={text} /></span>
            <% {:rich, text} -> %>
              <.rich text={text} />
            <% {:duration, ms} -> %>
              <.duration ms={ms} />
            <% text -> %>
              {text}
          <% end %>
        </dd>
      <% end %>
    </dl>
    """
  end

  # The heading: the run, the pool it ran on, and its state. A run no pool claimed has
  # "Run" alone, with its state.
  defp heading(machine, state, alive) do
    run =
      if machine,
        do: gettext("Run on %{pool}", pool: ExternalText.line(machine.pool.name)),
        else: gettext("Run")

    case heading_state(state, alive) do
      nil -> run
      word -> [run, " · ", word]
    end
  end

  # The run's state in the word of its badge (`ApiaryWeb.RunComponents.state_label/1`),
  # so the two agree; with no state given, Running while the run is alive.
  defp heading_state(nil, true), do: gettext("Running")
  defp heading_state(nil, _alive), do: nil
  defp heading_state(state, _alive), do: ApiaryWeb.RunComponents.state_label(state)

  ## The steps

  # The list's steps in the order they run: Queue the run, Request a machine, Start the
  # machine, Prepare the machine, one Agent session per agent session, and Remove the
  # machine. A step that did not run has a row only after a failed step (`after_failure/1`).
  defp nodes(preparation, removed, alive, session_open, wall) do
    machine = preparation.machine
    plan = plan(preparation)
    going_on = alive and is_nil(preparation.stopped)

    middle =
      if preparation[:prebuild],
        do: prebuild_nodes(preparation, plan, {alive, going_on, session_open}),
        else: Enum.map(plan.sessions, &session_node(&1, alive, going_on, session_open, wall))

    # Prepare the machine runs, on a live run, until a step of an agent session, or of a
    # prebuild's Build the image, begins.
    machine_going_on = going_on and Enum.all?(plan.sessions, &unbegun?/1)

    ([
       queue_node(machine),
       request_node(machine),
       start_node(preparation),
       prepare_machine_node(plan.machine, alive, machine_going_on)
     ] ++ middle ++ [remove_node(removed, machine, alive)])
    |> after_failure()
    |> elem(0)
  end

  # A prebuild (the preparation's `prebuild`): `qory` builds its image in one session,
  # so the session is the step Build the image, and its `dev.qory.run.built` the step
  # Save the outputs, with no Agent session. One Build the image per place, as a run
  # has one session.
  defp prebuild_nodes(preparation, plan, {alive, going_on, session_open}) do
    places = plan.sessions

    builds =
      for place <- places,
          do: build_node(place, length(places), alive, going_on, session_open)

    builds ++ [built_node(preparation[:built], alive)]
  end

  # Build the image: the session's join, its wall and any other step of the session, then
  # Started and Finished as Run the agent has them, and the session's Timeline. Failed
  # when one of its steps failed or the session failed, with the session's cause line
  # (`Apiary.Runs.Preparation.build_what/1`) when none of its steps failed, as a failed
  # step has a cause line.
  defp build_node(place, count, alive, going_on, session_open) do
    key = if place.index == 1 or count == 1, do: "build", else: "build-#{place.index}"
    sequence = place.session && place.session.sequence
    open = if alive or (sequence != nil and sequence == session_open), do: true

    steps =
      [place.join, place.wall | place.extra]
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&{sequence(&1) || 0, &1.number})
      |> Enum.map(&step_node/1)

    session = agent_node(key, place, alive, open)
    fields = [key: key, kind: :build, name: gettext("Build the image")]
    node = group(fields, steps ++ [session], going_on and is_nil(place.session) and steps != [])
    ran? = session != nil and session.state != "skipped"
    step_failed? = Enum.any?(steps, &(&1.state == "failed"))

    %{
      node
      | children: steps,
        events: if(ran?, do: session.events, else: []),
        session: session && session.session,
        open: open,
        cause:
          if(ran? and session.state == "failed" and not step_failed?,
            do: Preparation.build_what(place.end || %{})
          )
    }
  end

  # Save the outputs of a prebuild (`Apiary.Runs.Preparation`'s `built`): its
  # `dev.qory.run.built`, with the image it reports. One event, so the row has its time
  # and no duration. Failed, with its cause line, when the image was not saved: the
  # report failed its check, or the run failed after the build and sent none.
  defp built_node(nil, alive), do: missing("outputs", gettext("Save the outputs"), alive)

  defp built_node(%{at: at, image: image, refused: refused} = built, _alive) do
    image = if(image, do: [{gettext("Image"), {:mono, image}}], else: [])

    entry(
      key: "outputs",
      kind: :outputs,
      name: gettext("Save the outputs"),
      state: if(refused, do: "failed", else: "succeeded"),
      at: at,
      ended_at: at,
      duration_ms: nil,
      events: if(refused, do: image, else: [{gettext("Outputs saved"), {:at, at}}] ++ image),
      cause: refused && built_cause(built)
    )
  end

  @doc """
  The cause line of a prebuild's Save the outputs whose image was not saved
  (`Apiary.Runs.Preparation`'s `built`), as rich text: what happened, with the values
  that differ as code, then what the reader does about it, where there is a step to take
  (`t:Apiary.Runs.Preparation.built_fix/0`). Nil for an image that was saved.
  """
  @spec built_cause(Preparation.built() | nil) :: term
  def built_cause(%{refused: refused, fix: fix}) when refused != nil do
    case built_fix(fix) do
      nil -> built_what(refused)
      fix -> [built_what(refused), " ", fix]
    end
  end

  def built_cause(_built), do: nil

  @doc """
  How a prebuild whose image was not saved ended, as the run page's header shows it: what
  happened, the first sentence of its cause line (`built_cause/1`), in plain text, with
  no advice. Nil for any other preparation, and for a prebuild lost or cancelled before
  its image arrived (`unsaved_line/1`).
  """
  @spec built_line(Preparation.t() | nil) :: String.t() | nil
  def built_line(%{built: %{refused: refused}}) when refused not in [nil, :lost, :cancelled],
    do: ApiaryWeb.RichText.plain_text(built_what(refused))

  def built_line(_preparation), do: nil

  @doc """
  How a prebuild ended that was lost or cancelled after its build finished and before an
  image arrived, as `built_line/1` has it; nil for any other preparation. The run page's
  header shows it only when the header has no other line on how the run ended: a lost or
  cancelled run often has one, the starter's outcome or the reason it was lost.
  """
  @spec unsaved_line(Preparation.t() | nil) :: String.t() | nil
  def unsaved_line(%{built: %{refused: refused}}) when refused in [:lost, :cancelled],
    do: built_what(refused)

  def unsaved_line(_preparation), do: nil

  defp built_what(:not_sent),
    do: gettext("The image was not saved: the build finished, but no image arrived.")

  defp built_what(:lost),
    do:
      gettext(
        "The image was not saved: the build finished, but the run was lost before an image arrived."
      )

  defp built_what(:cancelled),
    do:
      gettext(
        "The image was not saved: the build finished, but the run was cancelled before an image arrived."
      )

  defp built_what({:image_place, reported, expected}),
    do:
      rich_gettext(
        "The image was not saved: the run reported it at %{reported}, but this run saves images only under %{expected}.",
        reported: {:code, reported},
        expected: {:code, expected}
      )

  defp built_what({:environment_image, reported, {:destination, expected}}),
    do:
      rich_gettext(
        "The image was not saved: the run reported its environment image at %{reported}, but this run saves environment images only under %{expected}.",
        reported: {:code, reported},
        expected: {:code, expected}
      )

  defp built_what({:environment_image, reported, {:image, expected}}),
    do:
      rich_gettext(
        "The image was not saved: the run reported that it started from %{reported}, but this run starts from %{expected}.",
        reported: {:code, reported},
        expected: {:code, expected}
      )

  defp built_what({:form, member}),
    do:
      rich_gettext("The image was not saved: %{member} in the image report %{rule}.",
        member: {:code, member},
        rule: form_rule(member)
      )

  defp built_what(:no_destination),
    do:
      gettext(
        "The image was not saved: this run has no registry address to check the image against."
      )

  defp built_what(:not_prebuild),
    do:
      gettext(
        "The image was not saved: this run is not recorded as a prebuild handed over to a machine."
      )

  # The rule of the image report's member that the report broke
  # (`Apiary.Dispatches.Built`).
  defp form_rule(member) when member in ["image", "environment_image"],
    do:
      rich_gettext(
        "is not a registry address pinned by its digest, %{digest} and 64 lower-case hexadecimal digits, of at most 327 characters",
        digest: {:code, "@sha256:"}
      )

  defp form_rule("size"),
    do: gettext("is not a whole number of bytes from 1 to 9,007,199,254,740,991")

  defp form_rule("commit"), do: gettext("is not 40 or 64 lower-case hexadecimal characters")
  defp form_rule("environment_ref"), do: gettext("is not 1 to 200 characters")

  defp built_fix(:machine_log),
    do:
      rich_gettext("Read the machine log under %{step} for the cause.",
        step: {:b, gettext("Start the machine")}
      )

  defp built_fix({:pool_log, pool}),
    do: rich_gettext("Read the cause in the log of %{pool} on its host.", pool: {:b, pool})

  defp built_fix({:operator_log, operator, pool}),
    do:
      rich_gettext("Ask an admin of %{operator} for the cause in the log of %{pool}.",
        operator: operator,
        pool: {:b, pool}
      )

  defp built_fix({:support, run}), do: gettext("Contact support with run %{run}.", run: run)

  defp built_fix({:rebuild, target}),
    do: rich_gettext("Rebuild %{target} to build the image again.", target: {:b, target})

  defp built_fix({:ask_rebuild, workspace, target}),
    do:
      rich_gettext("Ask an admin of %{workspace} to rebuild %{target}.",
        workspace: workspace,
        target: {:b, target}
      )

  defp built_fix(nil), do: nil

  defp unbegun?(place),
    do: is_nil(place.session) and is_nil(place.join) and is_nil(place.wall) and place.extra == []

  # Where each step of the run goes: `machine`, the steps of Prepare the machine, and
  # `sessions`, one place per agent session in the order they started, each with its
  # join, its wall, the other steps between it and the session before, its pushes and the
  # versions it saved. A join, and any step but a wall that runs after the first
  # session's start, belong to the first agent session that starts after it; a wall to
  # the session of the last join before it when no agent session started between the
  # two, else to the last session that started before it; a push to the last session
  # that started before it; a version to the last that started before its time. A step
  # or a push with no such session, as on a run that failed before any session started,
  # goes to a session that has not started, after the others. A step with only its exit
  # goes to the last session that started before its exit. A prebuild's `image` step,
  # which Forager writes in the session's join after the session's start, goes to
  # Prepare the machine. Helper steps, and the step of the kind `machine` of a run a pool
  # claimed, which is Start the machine, have no place.
  defp plan(preparation) do
    steps =
      preparation.steps
      |> Enum.reject(&helper?/1)
      |> Enum.reject(&(preparation.machine != nil and &1.kind == "machine"))

    places =
      for {session, index} <- Enum.with_index(sessions(preparation), 1) do
        place(index, session, session.end)
      end

    # The session that has not started; for a run with no session's start at all, it has
    # how the run's session ended (`Apiary.Runs.Preparation`).
    next =
      place(length(places) + 1, nil, if(places == [], do: Map.get(preparation, :session_end)))

    {machine, places, next} =
      Enum.reduce(steps, {[], places, next}, fn step, {machine, places, next} ->
        case place_of(step, places, steps, preparation[:prebuild]) do
          :machine -> {[step | machine], places, next}
          :next -> {machine, places, put_step(next, step)}
          index -> {machine, update_place(places, index, &put_step(&1, step)), next}
        end
      end)

    {places, next} =
      Enum.reduce(pushes(preparation), {places, next}, fn push, {places, next} ->
        case started_before(places, sequence(push)) do
          nil -> {places, %{next | pushes: next.pushes ++ [push]}}
          %{index: i} -> {update_place(places, i, &%{&1 | pushes: &1.pushes ++ [push]}), next}
        end
      end)

    {places, next} =
      Enum.reduce(Map.get(preparation, :outputs, []), {places, next}, fn version, acc ->
        {places, next} = acc

        case started_by(places, version.at) do
          nil ->
            {places, %{next | versions: next.versions ++ [version]}}

          %{index: i} ->
            {update_place(places, i, &%{&1 | versions: &1.versions ++ [version]}), next}
        end
      end)

    used? =
      places == [] or next.join != nil or next.wall != nil or next.extra != [] or
        next.pushes != [] or next.versions != []

    %{machine: Enum.reverse(machine), sessions: if(used?, do: places ++ [next], else: places)}
  end

  defp place(index, session, finished),
    do: %{
      index: index,
      session: session,
      end: finished,
      join: nil,
      wall: nil,
      extra: [],
      pushes: [],
      versions: []
    }

  defp put_step(place, %{kind: "join"} = step) when is_nil(place.join), do: %{place | join: step}
  defp put_step(place, %{kind: "wall"} = step) when is_nil(place.wall), do: %{place | wall: step}
  defp put_step(place, step), do: %{place | extra: place.extra ++ [step]}

  defp update_place(places, index, fun),
    do: Enum.map(places, &if(&1.index == index, do: fun.(&1), else: &1))

  # A step's place among the events: the sequence of its start, else of its exit.
  defp sequence(step), do: step.started_sequence || step.exited_sequence

  defp place_of(%{kind: "image"}, _places, _steps, true), do: :machine
  defp place_of(step, places, steps, _prebuild), do: place_of(step, places, steps)

  defp place_of(step, places, steps) do
    seq = sequence(step)
    first = List.first(places)

    cond do
      step.kind == "join" ->
        next_place(places, seq)

      step.kind == "wall" ->
        case wall_join(steps, places, seq) do
          %{} = join -> place_of(join, places, steps)
          nil when first == nil -> :next
          nil -> started_before(places, seq).index
        end

      first == nil or seq == nil or first.session.sequence == nil or
          seq < first.session.sequence ->
        :machine

      # A step with only its exit may have started before the session: it stays with the
      # last session that started before its exit.
      is_nil(step.started_sequence) ->
        started_before(places, seq).index

      true ->
        next_place(places, seq)
    end
  end

  # The place of the first agent session that started after `seq`, else the session that
  # has not started.
  defp next_place(places, seq) do
    case started_after(places, seq) do
      nil -> :next
      %{index: i} -> i
    end
  end

  # The join a wall at `seq` starts the wall of: the last join before it, when no agent
  # session started between the two. Nil for none, as for a wall whose sequence is not
  # known.
  defp wall_join(_steps, _places, nil), do: nil

  defp wall_join(steps, places, seq) do
    join =
      steps
      |> Enum.filter(&(&1.kind == "join" and is_integer(sequence(&1)) and sequence(&1) < seq))
      |> Enum.max_by(&sequence/1, fn -> nil end)

    if join != nil and
         not Enum.any?(
           places,
           &(is_integer(&1.session.sequence) and
               &1.session.sequence > sequence(join) and
               &1.session.sequence < seq)
         ),
       do: join
  end

  # The first place whose session started after `seq`; nil for none.
  defp started_after(_places, nil), do: nil

  defp started_after(places, seq),
    do: Enum.find(places, &(is_integer(&1.session.sequence) and &1.session.sequence > seq))

  # The last place whose session started before `seq`, else the first; nil for no place.
  defp started_before(places, nil), do: List.first(places)

  defp started_before(places, seq) do
    places
    |> Enum.filter(&(is_integer(&1.session.sequence) and &1.session.sequence < seq))
    |> List.last() || List.first(places)
  end

  # The last place whose session started no later than `at`, else the first; nil for no
  # place.
  defp started_by(places, at) do
    places
    |> Enum.filter(&(DateTime.compare(&1.session.started_at, at) != :gt))
    |> List.last() || List.first(places)
  end

  # The steps in order, each step that did not run kept, as skipped, only when a failed
  # step comes before it and no step ran between the two; any other is left out, as a
  # session's Save the outputs when the session saved nothing. A step that ran and did not
  # fail clears the failure for the steps after it, as a later session that ran does. A
  # step made of steps counts as failed after its steps. Returns the steps and whether
  # the last step that ran failed.
  defp after_failure(nodes, failed \\ false) do
    {kept, failed} =
      Enum.map_reduce(nodes, failed, fn
        nil, failed ->
          {nil, failed}

        %{state: "skipped"} = node, failed ->
          {if(failed, do: node), failed}

        %{children: []} = node, _failed ->
          {node, node.state == "failed"}

        node, failed ->
          {children, failed_inside} = after_failure(node.children, failed)
          {%{node | children: children}, failed_inside or node.state == "failed"}
      end)

    {Enum.reject(kept, &is_nil/1), failed}
  end

  # A step of the list. `at` is its start, `since` when its clock starts while it runs,
  # `ended_at` its end. `ticking` is whether its clock counts while it runs. `open` is
  # whether it is open when it appears, nil for open while it runs or once it failed.
  # `step` is the run's step it shows, `session` the agent session of Run the agent, and
  # `clean_up` the starter's report that Remove the machine shows.
  defp entry(fields) do
    fields = Map.new(fields)
    state = fields.state

    defaults = %{
      at: nil,
      ended_at: nil,
      events: [],
      children: [],
      text: nil,
      open: nil,
      ticking: state == "running",
      step: nil,
      session: nil,
      clean_up: nil,
      cause: nil
    }

    node = Map.merge(defaults, fields)

    node
    |> Map.put_new(:since, node.at)
    |> Map.put_new_lazy(:duration_ms, fn ->
      if state != "running", do: ms_between(node.at, node.ended_at)
    end)
  end

  # A step that did not run: skipped once the run has ended, no row while it is alive.
  defp missing(_key, _name, true), do: nil

  defp missing(key, name, false),
    do: entry(key: key, kind: :skipped, name: name, state: "skipped")

  # A step made of steps: failed when one failed; else running when one runs or
  # `going_on`, so it shows no end between two of its steps; else cancelled when one was
  # cancelled; else paused when an agent session paused; else succeeded. Skipped when
  # none ran. It spans from the first one's start
  # to the last one's end, and its clock counts while one of its steps counts.
  defp group(fields, children, going_on) do
    ran = Enum.reject(children, &(is_nil(&1) or &1.state == "skipped"))
    states = Enum.map(ran, & &1.state)

    state =
      cond do
        ran == [] -> "skipped"
        "failed" in states -> "failed"
        "running" in states or going_on -> "running"
        "cancelled" in states -> "cancelled"
        "paused" in states -> "paused"
        true -> "succeeded"
      end

    ends = ran |> Enum.map(& &1.ended_at) |> Enum.reject(&is_nil/1)

    entry(
      Keyword.merge(fields,
        state: state,
        at: ran |> Enum.map(& &1.at) |> earliest(),
        ended_at: if(ends != [], do: Enum.max(ends, DateTime)),
        children: Enum.reject(children, &is_nil/1),
        ticking: Enum.any?(ran, & &1.ticking)
      )
    )
  end

  # A step of the run. A push's row is a new row once it failed, so it opens on an open
  # page (`flow/1` keeps the `open` a row mounted with).
  defp step_node(step) do
    key =
      if step.kind == "push" and step.state == "failed",
        do: "step-#{step.number}-failed",
        else: "step-#{step.number}"

    entry(
      key: key,
      kind: :step,
      name: Preparation.row_name(step),
      state: step.state,
      at: step.started_at || step.exited_at,
      ended_at: step.exited_at,
      duration_ms: step.duration_ms,
      step: step
    )
  end

  defp queue_node(%{queued_at: %DateTime{} = at} = machine) do
    entry(
      key: "queue",
      kind: :queue,
      name: gettext("Queue the run"),
      state: "succeeded",
      at: at,
      ended_at: machine.requested_at,
      events: [{gettext("Queued"), {:at, at}}]
    )
  end

  defp queue_node(_machine), do: nil

  # A queued run's list: Queue the run, running since the run of the queue began
  # to wait, then each step after it, not run yet.
  defp queued_nodes(%{queued_at: at} = queued) do
    reason = Map.get(queued, :reason)
    type = Map.get(queued, :machine_type)

    queue =
      entry(
        key: "queue",
        kind: :queue,
        name: gettext("Queue the run"),
        state: "running",
        at: at,
        events:
          [{gettext("Queued"), {:at, at}}] ++
            if(type,
              do: [{gettext("Machine type"), {:rich, MachineTypeWords.fact_words(type)}}],
              else: []
            ),
        why: waiting_words(reason, type),
        fix: waiting_fix(reason, queued)
      )

    later =
      for {key, name} <- [
            {"request", gettext("Request a machine")},
            {"start", gettext("Start the machine")},
            {"prepare", gettext("Prepare the machine")},
            {"session", gettext("Agent session %{n}", n: 1)},
            {"remove", gettext("Remove the machine")}
          ],
          do: entry(key: key, kind: :not_run, name: name, state: "not_run")

    [queue | later]
  end

  @doc """
  Why a queued run waits (Apiary.Runs.Waiting), as rich text: its first words are the
  reason. `type` is the run's machine type, `%{key: key, name: name, spec: spec}`, nil
  for none.
  """
  @spec waiting_words(term, map | nil) :: term
  def waiting_words({:no_fit, key, _pool}, %{spec: %{} = spec} = type) do
    name = type[:name] || key

    rich_gettext("Waiting for a machine: no pool offers a machine that fits %{type}.",
      type: MachineTypeWords.fitted(name, key, spec)
    )
  end

  def waiting_words({:no_fit, key, _pool}, _type),
    do: gettext("Waiting: no pool can start machine type %{name}", name: key)

  def waiting_words(reason, _type), do: waiting_words(reason)

  # Who fixes why a queued run waits; nil where nobody does. An instance admin reads that
  # an instance admin fixes the type, or the pool's admin adds an offer: "Qory Pool" for
  # the instance's pool. Anyone else reads "Contact support with run …" in place of the
  # instance admin, as the run page's other lines for the instance's pool do: an
  # organisation's people never see the word "instance", and "support" is how they reach
  # the instance admins. For a pool that is not the instance's, they also read that they
  # can ask the pool's admin for an offer.
  defp waiting_fix({:no_fit, _key, pool}, %{instance_admin: true}) when not is_nil(pool),
    do:
      gettext(
        "An instance admin makes the type fit an offer in Instance settings › Machine types, or the admin of %{pool} adds an offer that fits.",
        pool: pool_words(pool)
      )

  defp waiting_fix({:no_fit, _key, :instance}, %{run: run}),
    do: gettext("Contact support with run %{run}.", run: run)

  defp waiting_fix({:no_fit, _key, pool}, %{run: run}) when is_binary(pool),
    do:
      gettext(
        "Contact support with run %{run}, or ask the admin of %{pool} to add an offer that fits.",
        run: run,
        pool: pool_words(pool)
      )

  defp waiting_fix(_reason, _queued), do: nil

  defp pool_words(:instance), do: gettext("Qory Pool")
  defp pool_words(pool), do: ExternalText.line(pool)

  # Why a queued run waits (`Apiary.Runs.Waiting`), in one sentence whose first words are
  # the reason. A pool's name came from a person and is shown as a text an external
  # system sent. The instance's pool has no numbers: its count covers the runs of other
  # organisations.
  defp waiting_words(:harness), do: gettext("Waiting until Qory Apiary reads the harness.")

  defp waiting_words(:no_pool), do: gettext("Waiting: no pool can take the run")

  defp waiting_words({:cooldown, nil, until}),
    do:
      gettext("Waiting for a model key: every model key is in cooldown until %{time}.",
        time: cooldown_time(until)
      )

  defp waiting_words({:cooldown, provider, until}),
    do:
      gettext(
        "Waiting for a model key: every key of %{provider} is in cooldown until %{time}.",
        provider: ExternalText.line(provider),
        time: cooldown_time(until)
      )

  defp waiting_words({:image, target, :queued}),
    do:
      gettext("Waiting for the environment image: a build of %{target} is queued.",
        target: target
      )

  defp waiting_words({:image, target, :running}),
    do:
      gettext("Waiting for the environment image: a build of %{target} is running.",
        target: target
      )

  defp waiting_words({:image, target, nil}),
    do: gettext("Waiting for the environment image of %{target}.", target: target)

  defp waiting_words({:busy, :instance}),
    do: gettext("Waiting for a machine: Qory Pool runs all of its machines.")

  defp waiting_words({:busy, pool, in_use, limit}),
    do:
      ngettext(
        "Waiting for a machine: %{pool} runs %{in_use} of its %{count} machine.",
        "Waiting for a machine: %{pool} runs %{in_use} of its %{count} machines.",
        limit,
        pool: ExternalText.line(pool),
        in_use: Format.number(in_use),
        count: Format.number(limit)
      )

  defp waiting_words({:behind, n}),
    do:
      ngettext(
        "Waiting for a machine: %{count} run was queued before this one.",
        "Waiting for a machine: %{count} runs were queued before this one.",
        n,
        count: Format.number(n)
      )

  defp waiting_words({:pool, name}) when is_binary(name),
    do: gettext("Waiting for %{node} to run it.", node: ExternalText.line(name))

  defp waiting_words(_reason), do: nil

  @doc false
  # cooldown_time/2 is the end of a cooldown in the reader's time zone at `now`, as a key's
  # row on Model providers shows it (`ApiaryWeb.Format.week_time/2`): the time of day
  # alone on the reader's day, "14:00", the weekday on one of the six days after it,
  # "Fri 14:00", else with its date, "26 Sept, 14:00".
  @spec cooldown_time(DateTime.t(), DateTime.t()) :: String.t()
  def cooldown_time(until, now \\ DateTime.utc_now()), do: Format.week_time(until, now)

  defp request_node(nil), do: nil

  defp request_node(machine) do
    type =
      if machine.machine_type,
        do: {:rich, MachineTypeWords.requested(machine.machine_type, machine.machine_type.spec)},
        else: gettext("pool default")

    entry(
      key: "request",
      kind: :request,
      name: gettext("Request a machine"),
      state: "succeeded",
      at: machine.requested_at,
      ended_at: machine.started.started_at,
      duration_ms: machine.requested_ms,
      events: [
        {gettext("Machine requested"), {:at, machine.requested_at}},
        {gettext("Pool"), {:external, machine.pool.name}},
        {gettext("Machine type"), type}
      ]
    )
  end

  # Start the machine: from `dispatched` to the redemption of the run's code, with
  # Machine started once the machine started, the `machine` step's lines, Started as and
  # the machine log. Its clock counts from the request until `dispatched` arrives.
  defp start_node(%{machine: nil}), do: nil

  defp start_node(%{machine: machine} = preparation) do
    state = start_state(preparation)
    started = machine.started

    entry(
      key: "start",
      kind: :start,
      name: gettext("Start the machine"),
      state: state,
      at: started.started_at,
      since: started.started_at || machine.requested_at,
      ended_at: started.ended_at,
      duration_ms: started.duration_ms,
      events:
        if(state == "succeeded" and started.ended_at,
          do: [{gettext("Machine started"), {:at, started.ended_at}}],
          else: []
        ),
      open: start_open?(preparation)
    )
  end

  defp prepare_machine_node([], alive, _going_on),
    do: missing("prepare", gettext("Prepare the machine"), alive)

  defp prepare_machine_node(steps, _alive, going_on) do
    group(
      [key: "prepare", kind: :prepare, name: gettext("Prepare the machine")],
      Enum.map(steps, &step_node/1),
      going_on
    )
  end

  # An Agent session: Prepare the session, its steps in the order they ran; Run the
  # agent; and Save the outputs. The first session's key is `session`, the nth's
  # `session-n`. It and its Run the agent are open while the run is alive, and on a run
  # that ended when a link points inside it (`session_open`).
  defp session_node(place, alive, going_on, session_open, wall) do
    key = if place.index == 1, do: "session", else: "session-#{place.index}"
    sequence = place.session && place.session.sequence
    open = if alive or (sequence != nil and sequence == session_open), do: true

    ran =
      [place.join, place.wall | place.extra]
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&{sequence(&1) || 0, &1.number})
      |> Enum.map(&step_node/1)

    not_ran = [
      if(is_nil(place.join), do: missing("#{key}-join", gettext("Start the agent"), alive)),
      if(wall and is_nil(place.wall),
        do: missing("#{key}-wall", gettext("Start the wall"), alive)
      )
    ]

    prepare =
      group(
        [key: "#{key}-prepare", kind: :prepare_session, name: gettext("Prepare the session")],
        ran ++ not_ran,
        going_on and is_nil(place.session) and ran != []
      )

    group(
      [key: key, kind: :session, name: gettext("Agent session %{n}", n: place.index), open: open],
      [
        prepare,
        agent_node(key, place, alive, open),
        outputs_node("#{key}-outputs", place, alive)
      ],
      false
    )
  end

  # Run the agent: the session from its start to its exit, Started, Finished, Result and
  # Model, and the session's Timeline. For a run with no session's start at all, from the
  # session's end alone. A missing step while the session has neither.
  defp agent_node(key, %{session: nil, end: nil}, alive, _open),
    do: missing("#{key}-agent", gettext("Run the agent"), alive)

  defp agent_node(key, %{session: nil, end: finished}, alive, _open) do
    row = finished_row(finished, nil, alive)

    entry(
      key: "#{key}-agent",
      kind: :agent,
      name: gettext("Run the agent"),
      state: row.state,
      at: row.at,
      ended_at: row.exited_at,
      duration_ms: row.duration_ms,
      events: finished_events(row)
    )
  end

  defp agent_node(key, %{session: session}, alive, open) do
    row = session_row(session.started_at, session.end, alive)
    finished = finished_row(session.end, row, alive)

    entry(
      key: "#{key}-agent",
      kind: :agent,
      name: gettext("Run the agent"),
      state: row.state,
      at: session.started_at,
      ended_at: finished && finished.exited_at,
      duration_ms: row.duration_ms,
      events: [{gettext("Started"), {:at, session.started_at}} | finished_events(finished)],
      session: session,
      open: open
    )
  end

  defp finished_events(nil), do: []

  defp finished_events(finished) do
    [{gettext("Finished"), {:at, finished.at}}] ++
      if(finished.result != "", do: [{gettext("Result"), finished.result}], else: []) ++
      if(finished.model, do: [{gettext("Model"), {:mono, finished.model}}], else: [])
  end

  # Save the outputs: the versions the session's agent saved and the session's pushes,
  # with the key `key`. A new row once a push failed, so it opens on an open page.
  defp outputs_node(key, %{pushes: [], versions: []}, alive),
    do: missing(key, gettext("Save the outputs"), alive)

  defp outputs_node(key, place, _alive) do
    row = outputs_row(%{after_session: place.pushes, outputs: place.versions})

    events =
      if(place.versions != [],
        do: [{gettext("Outputs saved"), {:at, List.first(place.versions).at}}],
        else: []
      ) ++
        for version <- place.versions do
          {{:external, version.type},
           gettext("Version %{number}", number: Format.number(version.number))}
        end

    entry(
      key: if(row.state == "failed", do: "#{key}-failed", else: key),
      kind: :outputs,
      name: gettext("Save the outputs"),
      state: row.state,
      at: row.at,
      ended_at: outputs_end(row),
      duration_ms: row.duration_ms,
      ticking: row.ticking,
      events: events,
      children: Enum.map(place.pushes, &step_node/1)
    )
  end

  # Remove the machine, from what the pool's starter reported (`clean_up/3`): Machine
  # removed, the cause and the time alive, once the machine is gone; else the words of
  # the report or of the wait. A permanent machine's row is Machine stays registered. A
  # missing step for a machine with no report.
  defp remove_node(nil, nil, _alive), do: nil

  defp remove_node(nil, _machine, alive),
    do: missing("remove", gettext("Remove the machine"), alive)

  defp remove_node(removed, _machine, _alive) do
    state =
      case removed.kind do
        :gone -> "succeeded"
        :delete_failed -> "failed"
        kind when kind in [:deleting, :waiting] -> "running"
        _none -> "cancelled"
      end

    events =
      if(removed.gone_at, do: [{gettext("Machine removed"), {:at, removed.gone_at}}], else: []) ++
        if(removed.cause, do: [{gettext("Cause"), removed.cause}], else: []) ++
        if removed.alive_ms, do: [{gettext("Alive"), {:duration, removed.alive_ms}}], else: []

    entry(
      key: "remove",
      kind: :remove,
      name: removed.name,
      state: state,
      at: removed.at,
      ended_at: removed.gone_at,
      duration_ms: removed.duration_ms,
      ticking: false,
      events: events,
      text: removed.text,
      clean_up: removed.kind,
      open: false
    )
  end

  @doc "What a row of the preparation calls a step (`Apiary.Runs.Preparation.step_label/1`)."
  @spec step_label(map) :: String.t() | nil
  defdelegate step_label(step), to: Preparation

  @doc """
  The first sentence of a preparation's cause line (`stopped`'s `what`) as rich text: the
  command in qory's detail in code font, as `npm ci` in "(postCreateCommand: npm ci)".
  A detail with no such command, and a line with no detail, are plain text.
  """
  @spec cause_what(map) :: term()
  def cause_what(%{what: what} = stopped) do
    with detail when is_binary(detail) <- Map.get(stopped, :detail),
         {at, size} <- what |> :binary.matches(detail) |> List.last() do
      rest = at + size

      [
        binary_part(what, 0, at),
        detail_rich(detail),
        binary_part(what, rest, byte_size(what) - rest)
      ]
    else
      _none -> what
    end
  end

  # "hook: command", as qory names a set-up step, has its command in code font.
  defp detail_rich(detail) do
    case Regex.run(~r/\A(\w+): (.+)\z/s, detail) do
      [_detail, hook, command] -> [hook, ": ", {:code, command}]
      nil -> detail
    end
  end

  # A row is open when it appears while it runs or once it failed.
  defp open?(state), do: state in ["running", "failed"]

  # The run's step of the kind `machine`, nil for a run with none or no machine.
  defp machine_step(%{machine: nil}), do: nil
  defp machine_step(%{steps: steps}), do: Enum.find(steps, &(&1.kind == "machine"))

  # Start the machine's state: the machine's, from `dispatched` to the redemption, or
  # failed once its `machine` step failed.
  defp start_state(%{machine: nil}), do: nil

  defp start_state(%{machine: machine} = preparation) do
    case machine_step(preparation) do
      %{state: "failed"} -> "failed"
      _other -> machine.started.state
    end
  end

  # Start the machine is open when it appears while it or its `machine` step runs, or
  # once either failed.
  defp start_open?(preparation) do
    step = machine_step(preparation)
    open?(start_state(preparation)) or (step != nil and open?(step.state))
  end

  defp helper?(step), do: Map.get(step, :helper, false)

  # The push steps among the steps after the last agent session: a copy has no row.
  defp pushes(preparation),
    do: preparation |> Map.get(:after_session, []) |> Enum.reject(&helper?/1)

  # The run's agent sessions (`Apiary.Runs.Preparation`); for a preparation read without
  # them, the one session from `session_started_at` to `session_end`.
  defp sessions(%{sessions: sessions}), do: sessions
  defp sessions(%{session_started_at: nil}), do: []

  defp sessions(%{session_started_at: at} = preparation),
    do: [%{session: nil, sequence: nil, started_at: at, end: Map.get(preparation, :session_end)}]

  # Each agent session's times, for the heading's time (`run_total/3`), in the order they
  # started: `started`, from its start to its exit (`session_row/3`), and `finished`,
  # from its result to its exit (`finished_row/3`), nil while it has neither a result nor
  # an exit. A run with no session's start at all has one with no `started` when its
  # session ended.
  defp pairs(preparation, alive) do
    case sessions(preparation) do
      [] ->
        case finished_row(Map.get(preparation, :session_end), nil, alive) do
          nil -> []
          row -> [%{index: 1, key: nil, started: nil, finished: row}]
        end

      sessions ->
        for {session, index} <- Enum.with_index(sessions, 1) do
          started = session_row(session.started_at, session.end, alive)

          %{
            index: index,
            key: session.sequence,
            started: started,
            finished: finished_row(session.end, started, alive)
          }
        end
    end
  end

  # Start the machine's lines for a run with a step of the kind `machine`, nil without one or
  # for a reader who may not read the run's log: `create machine` first, when the step
  # started no later than the redemption, then the step's lines, numbered after it.
  # `empty` is whether the step has no line, which decides "No output." and the pruned
  # sentence.
  defp start_output(%{machine: nil}), do: nil

  defp start_output(%{machine: machine} = preparation) do
    case machine_step(preparation) do
      %{output: %{lines: step_lines} = output} = step ->
        first = create_line(machine.started, step.started_at)
        lines = first ++ Enum.map(step_lines, &%{&1 | number: &1.number + length(first)})
        output |> Map.put(:lines, lines) |> Map.put(:empty, step_lines == [])

      _none ->
        nil
    end
  end

  # The time the pool's provider took to make the machine: from `dispatched` to the start
  # of the `machine` step, in seconds to a tenth, the form of the step's lines. The line
  # is left out when the step started after the redemption: its start is then the time
  # `qory run` sent it, not the start of the machine.
  defp create_line(
         %{started_at: %DateTime{} = dispatched, ended_at: %DateTime{} = redeemed},
         %DateTime{} = started
       ) do
    if DateTime.after?(started, redeemed) do
      []
    else
      ms = max(DateTime.diff(started, dispatched, :millisecond), 0)
      seconds = :erlang.float_to_binary(ms / 1000, decimals: 1)

      [
        %{
          number: 1,
          at: dispatched,
          text: gettext("create machine  %{seconds} s", seconds: seconds)
        }
      ]
    end
  end

  defp create_line(_started, _step_started_at), do: []

  # Run the agent spans from a session's start to its exit. Its state is the exit's,
  # paused for an exit at the run's model keys' limit, succeeded for an exit with no state
  # of a step; running while the run is alive with no exit; cancelled once the run ended
  # with none.
  defp session_row(at, finished, alive) do
    exited_at = finished && finished.exited_at

    state =
      cond do
        exited_at -> exit_state(finished)
        alive -> "running"
        true -> "cancelled"
      end

    %{state: state, at: at, duration_ms: exited_at && ms_between(at, exited_at)}
  end

  # A run that paused after it pushed its questions or a proposal ended completed
  # (`Apiary.Runs.Fold.settle/1`), so each of its sessions that paused reads as one that
  # succeeded. A run that paused and is continued keeps its paused sessions.
  defp finished(preparation, "completed") do
    Map.new(preparation, fn
      {:session_end, finished} -> {:session_end, succeeded(finished)}
      {:sessions, sessions} -> {:sessions, Enum.map(sessions, &%{&1 | end: succeeded(&1.end)})}
      pair -> pair
    end)
  end

  defp finished(preparation, _run_state), do: preparation

  defp succeeded(%{} = finished) do
    if exit_state(finished) == "paused",
      do: Map.merge(finished, %{state: "succeeded", reason: nil}),
      else: finished
  end

  defp succeeded(finished), do: finished

  defp exit_state(%{state: "paused"}), do: "paused"
  # The shape of a pause until every gateway sends `paused`: Qory Apiary is deployed
  # before Forager, so it reads both while gateways of both versions run.
  defp exit_state(%{state: "cancelled", reason: "model_key_limit"}), do: "paused"

  defp exit_state(%{state: state}) when state in ["succeeded", "failed", "cancelled"],
    do: state

  defp exit_state(_session_end), do: "succeeded"

  # Finished, from the runtime's result to the session's exit, with the result's words
  # and the model; from the exit alone for a session with no result. Its state is the
  # session's (`session_row/3`). Nil while the session has neither.
  defp finished_row(finished, session, alive) do
    case finished do
      %{} ->
        state =
          cond do
            finished.exited_at && session -> session.state
            finished.exited_at -> exit_state(finished)
            alive -> "running"
            true -> "cancelled"
          end

        %{
          state: state,
          at: finished.result_at || finished.exited_at,
          exited_at: finished.exited_at,
          duration_ms: finished.result_at && ms_between(finished.result_at, finished.exited_at),
          result: result_words(finished),
          model: finished.model
        }

      nil ->
        nil
    end
  end

  # "exit 0 · success · 14 turns · 3 m 49 s · $0.84": what is known of the session's end.
  # An exit code of -1 is no exit status (the Forager contract's
  # `dev.qory.session.exited`), so the words show none.
  defp result_words(finished) do
    exit =
      if is_integer(finished.exit_code) and finished.exit_code != -1,
        do: gettext("exit %{code}", code: finished.exit_code)

    result =
      if finished.result_at, do: RunPageComponents.result_words(finished)

    [exit, result] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")
  end

  # Save the outputs: the artifact versions saved, and the push steps. It starts at
  # the first push's start and ends at the end of the last push; with no push step, it
  # spans from the first version pushed to the last. It is failed when a push failed; else
  # running when one runs; else cancelled when one was cancelled; else succeeded. Its
  # duration is nil while a push runs, and when it starts and ends at one moment. Nil
  # with neither.
  defp outputs_row(preparation) do
    steps = pushes(preparation)
    versions = Map.get(preparation, :outputs, [])

    if steps == [] and versions == [] do
      nil
    else
      states = Enum.map(steps, & &1.state)
      ticking = "running" in states

      state =
        cond do
          "failed" in states -> "failed"
          ticking -> "running"
          "cancelled" in states -> "cancelled"
          true -> "succeeded"
        end

      {at, to} =
        case steps do
          [] ->
            {List.first(versions).at, List.last(versions).at}

          steps ->
            ends = steps |> Enum.map(& &1.exited_at) |> Enum.reject(&is_nil/1)

            {steps |> Enum.map(&(&1.started_at || &1.exited_at)) |> earliest(),
             if(ends != [], do: Enum.max(ends, DateTime))}
        end

      %{
        state: state,
        at: at,
        duration_ms: if(not ticking and not same_moment?(at, to), do: ms_between(at, to)),
        ticking: ticking,
        versions: versions,
        steps: steps
      }
    end
  end

  # Remove the machine, from the `clean_up/3` value: from the run's end to the starter's
  # `gone` report, with the cause and the machine's time alive, from `dispatched` to that
  # report. Any other report, and the wait for one, show their words and no duration. A
  # permanent machine's row is Machine stays registered, with no time.
  defp removed_row(nil, _machine), do: nil

  defp removed_row(:stays, _machine) do
    %{
      kind: :stays,
      name: gettext("Machine stays registered"),
      text: nil,
      at: nil,
      gone_at: nil,
      duration_ms: nil,
      alive_ms: nil,
      cause: nil
    }
  end

  defp removed_row(clean_up, machine) do
    {kind, gone_at} =
      case clean_up do
        {:report, :gone, at} -> {:gone, at}
        {:report, state, _at} -> {state, nil}
        {:waiting, _due_at} -> {:waiting, nil}
        other -> {other, nil}
      end

    from = machine.ended_at

    %{
      kind: kind,
      name: gettext("Remove the machine"),
      text: if(kind != :gone, do: clean_up_text(kind)),
      at: from,
      gone_at: gone_at,
      duration_ms: gone_at && from && ms_between(from, gone_at),
      alive_ms: gone_at && ms_between(machine.started.started_at, gone_at),
      cause: cause_text(machine.removal_cause)
    }
  end

  defp clean_up_text(:deleting), do: gettext("Machine removal requested")
  defp clean_up_text(:delete_failed), do: gettext("Removal failed: the machine still exists")
  defp clean_up_text(:waiting), do: gettext("Waiting for a report")
  defp clean_up_text(:no_report), do: gettext("No removal report")

  defp cause_text(:keep_alive_lost), do: gettext("Keep-alive lost")
  defp cause_text(:run_ended), do: gettext("Run ended")
  defp cause_text(_cause), do: nil

  # The run's time for the heading, over the rows the list shows (`shown`: the machine
  # whose rows are shown, the steps with a row, the sessions and Save the outputs):
  # `%{from: at}` while the run is alive, a clock that counts from the first row's start;
  # `%{ms: ms}` once it has ended, from the first row's start to the end of the last row;
  # `%{}` without a start or an end.
  defp run_total(shown, removed, alive) do
    from = first_at(shown)

    cond do
      is_nil(from) -> %{}
      alive -> %{from: from}
      to = last_end(shown, removed) -> %{ms: ms_between(from, to)}
      true -> %{}
    end
  end

  defp first_at(%{machine: %{queued_at: %DateTime{} = at}}), do: at
  defp first_at(%{machine: %{requested_at: %DateTime{} = at}}), do: at

  defp first_at(shown) do
    Enum.map(shown.steps, &(&1.started_at || &1.exited_at))
    |> Kernel.++(for %{started: %{at: at}} <- shown.pairs, do: at)
    |> Kernel.++(for %{finished: %{at: at}} <- shown.pairs, do: at)
    |> Kernel.++([shown.outputs && shown.outputs.at])
    |> earliest()
  end

  # The end of the last row: the `gone` report, else the latest end among the machine's,
  # the steps', the sessions' and Save the outputs': its last push's, else its last
  # version's.
  defp last_end(_shown, %{gone_at: %DateTime{} = at}), do: at

  defp last_end(shown, _removed) do
    machine = shown.machine

    [
      machine && machine.ended_at,
      machine && machine.started.ended_at,
      outputs_end(shown.outputs)
      | Enum.map(shown.steps, & &1.exited_at) ++ Enum.map(shown.pairs, &pair_end/1)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      ends -> Enum.max(ends, DateTime)
    end
  end

  defp pair_end(%{finished: %{exited_at: %DateTime{} = at}}), do: at
  defp pair_end(%{finished: %{at: at}}), do: at
  defp pair_end(_pair), do: nil

  defp outputs_end(nil), do: nil

  defp outputs_end(%{steps: steps, versions: versions}) do
    (Enum.map(steps, & &1.exited_at) ++ Enum.map(versions, & &1.at))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      ends -> Enum.max(ends, DateTime)
    end
  end

  defp earliest(times) do
    case Enum.reject(times, &is_nil/1) do
      [] -> nil
      times -> Enum.min(times, DateTime)
    end
  end

  defp ms_between(%DateTime{} = from, %DateTime{} = to),
    do: max(DateTime.diff(to, from, :millisecond), 0)

  defp ms_between(_from, _to), do: nil

  # Whether a row starts and ends at one moment, such as Save the outputs with one version
  # and no push step.
  defp same_moment?(%DateTime{} = at, %DateTime{} = to), do: DateTime.compare(at, to) == :eq
  defp same_moment?(_at, _to), do: false

  attr :id, :string, required: true
  attr :step, :map, required: true
  attr :alive, :boolean, required: true
  attr :pruned_at, :any, default: nil, doc: "when retention deleted the run's log lines"
  attr :open, :boolean, default: nil, doc: "whether the row is open when it appears"
  attr :label, :string, default: nil, doc: "the row's name in place of the step's"
  attr :times, :boolean, default: true, doc: "whether the row shows its start and duration"
  slot :inner_block, doc: "what follows the step's output"

  # A step's row: its name came from the run, unless it has a label, and its output is
  # there for a reader who may read the run's log.
  defp step_row(assigns) do
    ~H"""
    <.row
      id={@id}
      state={@step.state}
      name={@label || Preparation.step_name(@step)}
      at={@step.started_at}
      since={@step.started_at}
      alive={@alive}
      duration_ms={@step.duration_ms}
      sent={is_nil(@label)}
      open={@open}
      times={@times}
    >
      <.output
        :if={@step.output}
        id={"#{@id}-output"}
        output={@step.output}
        pruned_at={@pruned_at}
      />
      {render_slot(@inner_block)}
    </.row>
    """
  end

  attr :id, :string, required: true
  attr :state, :string, required: true
  attr :name, :string, required: true
  attr :at, :any, required: true
  attr :since, :any, default: nil, doc: "when the row's clock starts"
  attr :alive, :boolean, default: false, doc: "whether the run is alive"
  attr :duration_ms, :integer, default: nil
  attr :sent, :boolean, default: false, doc: "whether the name came from the run"
  attr :open, :boolean, default: nil, doc: "whether the row is open when it appears; failed"
  attr :times, :boolean, default: true, doc: "whether the row shows its start and duration"
  slot :inner_block, required: true

  defp row(assigns) do
    assigns =
      assign(assigns,
        ticking: assigns.state == "running" and assigns.alive,
        open: if(is_nil(assigns.open), do: assigns.state == "failed", else: assigns.open)
      )

    ~H"""
    <details
      id={@id}
      class="q-tool q-prep-step"
      data-state={@state}
      open={@open}
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <summary class="q-hd q-prep-row">
        <.icon name="hero-chevron-right-micro" class="q-chev size-3" />
        <.state_mark state={@state} pulse={@ticking} />
        <span :if={@sent} class="q-k q-prep-name"><.external_text text={@name} /></span>
        <span :if={!@sent} class="q-k q-prep-name">{@name}</span>
        <span class="q-t">
          <span :if={@state == "running"} class="q-running">{gettext("Running")}</span>
          <span class="q-tc1 q-prep-cell"><.clock :if={@times && @at} at={@at} /></span>
          <span class="q-tc2 q-prep-cell">
            <.duration :if={@times && @duration_ms} ms={@duration_ms} class="q-d" />
            <.duration
              :if={@times and @ticking and @since != nil}
              id={"#{@id}-clock"}
              elapsed_seconds={0}
              elapsed_at={@since}
              class="q-d"
            />
          </span>
        </span>
      </summary>
      <div class={["q-xb", @state == "failed" && "q-xb-bad"]}>
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  attr :state, :string, required: true
  attr :pulse, :boolean, default: false

  defp state_mark(assigns) do
    ~H"""
    <%= case @state do %>
      <% "succeeded" -> %>
        <.icon name="hero-check-circle-micro" class="q-prep-ok size-4 self-center" />
        <span class="sr-only">{gettext("Succeeded")}</span>
      <% "failed" -> %>
        <.icon name="hero-x-circle-micro" class="q-prep-bad size-4 self-center" />
        <span class="sr-only">{gettext("Failed")}</span>
      <% "cancelled" -> %>
        <.icon name="hero-minus-circle-micro" class="text-faint size-4 self-center" />
        <span class="sr-only">{gettext("Cancelled")}</span>
      <% "paused" -> %>
        <span class="q-st q-st-paused size-4 justify-center self-center" aria-hidden="true">
          <i></i>
        </span>
        <span class="sr-only">{gettext("Paused")}</span>
      <% "skipped" -> %>
        <.icon name="hero-no-symbol-micro" class="text-faint size-4 self-center" />
      <% _running -> %>
        <.icon
          name="hero-ellipsis-horizontal-circle-micro"
          class={["q-running size-4 self-center", @pulse && "q-prep-pulse"]}
        />
    <% end %>
    """
  end

  attr :at, :any, required: true

  defp clock(assigns) do
    ~H"""
    <time datetime={DateTime.to_iso8601(@at)} title={Format.datetime(@at, seconds: true, zone: true)}>
      {Format.time(@at, seconds: true)}
    </time>
    """
  end

  attr :id, :string, required: true
  attr :output, :map, required: true
  attr :pruned_at, :any, default: nil, doc: "when retention deleted the run's log lines"

  defp output(assigns) do
    assigns = assign(assigns, :empty, Map.get(assigns.output, :empty, assigns.output.lines == []))

    ~H"""
    <div id={@id} class="q-well">
      <p :if={@output.truncated} class="text-xs text-faint">{cut_note(@output)}</p>
      <.log_lines :if={@output.lines != []} id={"#{@id}-lines"} lines={@output.lines} />
      <p :if={@empty and is_nil(@pruned_at)} class="text-sm text-faint">
        {gettext("No output.")}
      </p>
      <p :if={@empty and @pruned_at} class="text-sm text-faint">
        {gettext(
          "This run's log output was pruned on %{date}, under the workspace's retention. The timeline and the connections are whole.",
          date: Format.date(@pruned_at)
        )}
      </p>
    </div>
    """
  end

  # The note over a cut output (`t:Apiary.Runs.Preparation.output/0`). A cut of lines
  # leaves exactly `Apiary.Runs.Preparation.output_lines/0` lines of the step, so the
  # sentence has no singular. Under Start the machine, `create machine` is no line of the
  # step.
  defp cut_note(%{lines_cut: true}),
    do:
      gettext("The output is cut: these are its last %{lines} lines.",
        lines: Format.number(Apiary.Runs.Preparation.output_lines())
      )

  defp cut_note(_output), do: gettext("The output is cut: this is its last 64 KiB.")

  attr :id, :string, required: true
  attr :log, :any, required: true

  defp machine_log(%{log: {:ok, text, truncated}} = assigns) do
    shown = last_bytes(text, @machine_log_bytes)

    assigns =
      assign(assigns,
        lines: machine_lines(text, shown),
        truncated: truncated or byte_size(shown) < byte_size(text)
      )

    ~H"""
    <div id={@id} class="q-well">
      <div><span>{gettext("Machine log (instance admins)")}</span></div>
      <p :if={@truncated} class="text-xs text-faint">
        {gettext("The machine log is cut: this is its last part.")}
      </p>
      <.log_lines :if={@lines != []} id={"#{@id}-lines"} lines={@lines} />
    </div>
    """
  end

  defp machine_log(%{log: :none} = assigns) do
    ~H"""
    <p id={@id} class="text-sm text-faint">{gettext("No machine log has arrived.")}</p>
    """
  end

  defp machine_log(%{log: {:deleted, days}} = assigns) do
    assigns = assign(assigns, :days, days)

    ~H"""
    <p id={@id} class="text-sm text-faint">
      {ngettext(
        "Machine logs are kept for %{days} day. This machine has none.",
        "Machine logs are kept for %{days} days. This machine has none.",
        @days,
        days: @days
      )}
    </p>
    """
  end

  defp machine_log(%{log: :unreadable} = assigns) do
    ~H"""
    <p id={@id} class="text-sm text-faint">{gettext("The machine log could not be read.")}</p>
    """
  end

  defp machine_log(assigns), do: ~H""

  # The lines of the end of a machine log, `shown`, numbered in the whole log, `text`. A
  # machine log line has no time. The empty line after the last line feed is no line.
  defp machine_lines(text, shown) do
    skipped = binary_part(text, 0, byte_size(text) - byte_size(shown))
    first = length(:binary.matches(skipped, "\n")) + 1

    shown
    |> String.split("\n")
    |> Enum.with_index(first)
    |> Enum.map(fn {line, n} -> %{number: n, at: nil, text: String.trim_trailing(line, "\r")} end)
    |> then(fn lines ->
      case List.last(lines) do
        %{text: ""} -> Enum.drop(lines, -1)
        _other -> lines
      end
    end)
  end

  attr :id, :string, required: true
  attr :lines, :list, required: true, doc: "`%{number, at, text}` each; `at` may be nil"

  # A log, each line with its number and its time. A log whose lines have no time, as a
  # machine log's, has no time column; a line with no time in a log with times has an
  # empty cell. The text came from the run or the machine and is untrusted. Each line is
  # keyed by its number, so a live step sends only the lines that changed.
  defp log_lines(assigns) do
    assigns = assign(assigns, :timed, Enum.any?(assigns.lines, & &1.at))

    ~H"""
    <div id={@id} class={["q-log", @timed && "q-log-timed"]}>
      <div :for={line <- @lines} :key={line.number} class="q-log-ln">
        <span class="q-log-n">{line.number}</span>
        <span :if={@timed} class="q-log-t">
          <time :if={line.at} datetime={DateTime.to_iso8601(line.at)}>
            {Format.time(line.at, tenths: true)}
          </time>
        </span>
        <span class="q-log-x">{ExternalText.lines(line.text)}</span>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :text, :any, required: true, doc: "rich text (`ApiaryWeb.RichText`)"

  defp cause(assigns) do
    ~H"""
    <p id={@id} class="q-prep-cause" role="status"><.rich text={@text} /></p>
    """
  end

  # The last `limit` bytes of `text` at most, starting at a character.
  defp last_bytes(text, limit) when byte_size(text) <= limit, do: text

  defp last_bytes(text, limit),
    do: drop_partial(binary_part(text, byte_size(text) - limit, limit))

  defp drop_partial(<<_::utf8, _::binary>> = text), do: text
  defp drop_partial(<<_byte, rest::binary>>), do: drop_partial(rest)
  defp drop_partial(<<>>), do: ""
end
