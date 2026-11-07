defmodule ApiaryWeb.PreparationComponents do
  @moduledoc """
  The **Run** list of a run's Timeline (`docs/ui.md`, The run page): the run's phases from its
  queue to the removal of its machine, from `Apiary.Runs.Preparation`. One row per phase,
  in time order, each with its state, its start time and its duration, and only the
  phases that happened:

    * Queued, from the queue to the claim, for a run a node pool claimed;
    * Machine requested, from the claim to the starter's `dispatched`, with the pool and
      the machine type;
    * Machine started, from `dispatched` to the redemption of the run's code: a group that
      opens to Start machine, whose lines are those of the step of the kind `machine`,
      after a first line that Qory Apiary writes when the step started no later than the
      redemption, `create machine` and the seconds from `dispatched` to that step's
      start, at the time of `dispatched`. Start machine is failed once that step failed;
    * Prepare, a group of the steps that started before the first session
      (`step_label/1`), every step while no session has started;
    * Session started, a group from the first session's start to its exit, that opens to
      the run's Timeline (the `session` slot). It is open when it appears on a live run,
      and closed on a run that ended;
    * then, by time: a later session's steps, such as its join; Session finished, from the
      runtime's result to the session's exit, with the result and the model; and Outputs
      saved, the artifact versions the run pushed, and its push steps;
    * Machine removed, last (`clean_up/3`); for a run on a permanent machine, Machine
      stays registered in its place.

  A step's output is its lines, each with its number and its time, at most 2,500 lines.

  A failed or running row is open when it appears, and so is Start machine while its
  `machine` step runs or once that step failed. Prepare is running, and open, on a live
  run until its first session starts or the preparation stops, so it shows no end between
  two steps, where no clock counts. The others are closed. After that, a person's open or
  close stays. A failed row has the cause line under its output. Under Start machine, for
  a machine that did not start, the line is its second sentence alone, who fixes the
  cause: the run's header shows the first as the run's reason. While the run is alive, a
  running row has a clock that ticks in the browser, and the heading has the run's time
  so far, from the first row's start; once the run has ended, the heading has the time
  from the first row's start to the end of the last row.

  Machine removed shows what the pool's starter reported about the removal of the machine
  (`clean_up/3`): the removal's time from the run's end to a `gone` report, with the
  cause and the machine's time alive; else the state of the last report; else, once the
  run has ended and a machine existed for its dispatch, that a report is awaited for 15
  minutes after the run ended, then that none came. The 15 minutes are counted at render,
  against the time the caller passes (`now`); the caller renders again when they pass
  (`clean_up_due/3`).

  A push step's row opens when the push fails on an open page. A failed push is no
  failed preparation (`Apiary.Runs.Preparation`).

  A step's name and output came from the run and are untrusted: they are interpolated,
  so they are escaped, and shown as a page shows a text an external system sent
  (`Apiary.ExternalText`). So are an artifact's type and the model. The machine log is
  shown to an instance admin alone, under Start machine; the caller reads it for an
  instance admin and hands it over.
  """
  use Phoenix.Component
  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.CoreComponents, only: [icon: 1]
  import ApiaryWeb.ExternalText, only: [external_text: 1]
  import ApiaryWeb.RichText, only: [rich: 1]
  import ApiaryWeb.RunComponents, only: [duration: 1, time_legend: 1]

  alias Apiary.ExternalText
  alias Apiary.Runs.Preparation
  alias ApiaryWeb.{Format, MachineTypeWords, RunPageComponents, Support}
  alias Phoenix.LiveView.JS

  # The most of a machine log the list shows, in bytes.
  @machine_log_bytes 65_536

  # How long after the run ended the Machine removed row waits for a report, in seconds.
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
  Whether a preparation has a row to show: a machine, a step, or an artifact version the
  run pushed.
  """
  @spec shown?(Preparation.t() | nil) :: boolean
  def shown?(nil), do: false

  def shown?(preparation) do
    preparation.machine != nil or preparation.steps != [] or
      Map.get(preparation, :after_session, []) != [] or Map.get(preparation, :outputs, []) != []
  end

  @doc """
  Whether the run page shows the list: the preparation has a row to show (`shown?/1`),
  or the list has a last row (`clean_up/3`), as for a run on a permanent machine.
  """
  @spec shown?(Preparation.t() | nil, clean_up | nil) :: boolean
  def shown?(preparation, clean_up), do: shown?(preparation) or clean_up != nil

  @doc """
  Whether the run's Timeline is drawn inside the Session started row: the list is shown
  (`shown?/2`) and the session started. Else the Timeline follows the list.
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
  When the Machine removed row of `preparation` changes from waiting for a report to no
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
  what the last row shows (`clean_up/3`), nil for no row. `session_open` opens
  Session started when it appears on a run that ended, as for a link to an event inside
  it. The `session` slot is the run's Timeline, inside Session started.
  """
  attr :id, :string, default: "prepare-machine"
  attr :preparation, :map, required: true
  attr :machine_log, :any, default: :hidden
  attr :alive, :boolean, required: true
  attr :clean_up, :any, default: nil
  attr :session_open, :boolean, default: false
  slot :session

  def run_list(assigns) do
    preparation = assigns.preparation
    machine = preparation.machine
    {grouped, later} = split_steps(preparation)
    prepare_steps = if machine, do: Enum.reject(grouped, &(&1.kind == "machine")), else: grouped
    group = session_row(preparation, assigns.alive)
    finished = finished_row(preparation, group, assigns.alive)
    outputs = outputs_row(preparation)
    removed = removed_row(assigns.clean_up, machine)

    trailing =
      Enum.map(later, &{:step, &1.started_at || &1.exited_at, &1}) ++
        if(finished, do: [{:finished, finished.at, finished}], else: []) ++
        if(outputs, do: [{:outputs, outputs.at, outputs}], else: [])

    assigns =
      assign(assigns,
        machine: machine,
        total: run_total(preparation, removed, assigns.alive),
        started: started_row(preparation),
        start_state: start_state(preparation),
        start_open: start_open?(preparation),
        machine_step: machine_step(preparation),
        start_output: start_output(preparation),
        prepare_steps: prepare_steps,
        prepare: prepare_row(prepare_steps, preparation, assigns.alive),
        group: group,
        trailing: Enum.sort_by(trailing, &elem(&1, 1), &earlier?/2),
        removed: removed
      )

    ~H"""
    <section id={@id} class="q-prep" aria-labelledby={"#{@id}-h"}>
      <div class="q-prep-hd">
        <h2 id={"#{@id}-h"}>{gettext("Run")}</h2>
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
        <li :if={@machine && @machine.queued_at}>
          <div id={"#{@id}-queued"} class="q-hd q-prep-row">
            <span class="size-3"></span>
            <.state_mark state="succeeded" />
            <span class="q-k q-prep-name">{gettext("Queued")}</span>
            <span class="q-t">
              <span class="q-tc1 q-prep-cell"><.clock at={@machine.queued_at} /></span>
              <span class="q-tc2 q-prep-cell">
                <.duration
                  :if={ms_between(@machine.queued_at, @machine.requested_at)}
                  ms={ms_between(@machine.queued_at, @machine.requested_at)}
                  class="q-d"
                />
              </span>
            </span>
          </div>
        </li>
        <li :if={@machine}>
          <.row
            id={"#{@id}-requested"}
            state="succeeded"
            name={gettext("Machine requested")}
            at={@machine.requested_at}
            duration_ms={@machine.requested_ms}
          >
            <dl class="q-prep-facts">
              <dt>{gettext("Pool")}</dt>
              <dd><.external_text text={@machine.pool.name} /></dd>
              <dt>{gettext("Machine type")}</dt>
              <dd>
                <span :if={@machine.machine_type}>
                  {MachineTypeWords.requested(@machine.machine_type.name, @machine.machine_type.spec)}
                </span>
                <span :if={!@machine.machine_type}>{gettext("pool default")}</span>
              </dd>
            </dl>
          </.row>
        </li>
        <li :if={@machine}>
          <.row
            id={"#{@id}-started"}
            state={@start_state}
            name={gettext("Machine started")}
            at={@machine.started.started_at}
            since={@machine.started.started_at || @machine.requested_at}
            alive={@alive}
            duration_ms={@machine.started.duration_ms}
            open={@started.open}
          >
            <ol class="q-prep-steps">
              <li>
                <.row
                  id={"#{@id}-start-machine"}
                  state={@start_state}
                  name={gettext("Start machine")}
                  at={@machine.started.started_at}
                  since={@machine.started.started_at || @machine.requested_at}
                  alive={@alive}
                  duration_ms={@machine.started.duration_ms}
                  open={@start_open}
                >
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
                    text={Support.stored_line(@preparation.stopped.fix)}
                  />
                  <.cause
                    :if={
                      @preparation.stopped && @machine_step &&
                        @preparation.stopped.step == @machine_step.number
                    }
                    id={"#{@id}-cause"}
                    text={[
                      cause_what(@preparation.stopped),
                      " ",
                      Support.stored_line(@preparation.stopped.fix)
                    ]}
                  />
                </.row>
              </li>
            </ol>
          </.row>
        </li>
        <li :if={@prepare}>
          <.row
            id={"#{@id}-prepare"}
            state={@prepare.state}
            name={gettext("Prepare")}
            at={@prepare.at}
            since={@prepare.at}
            alive={@alive and @prepare.ticking}
            duration_ms={@prepare.duration_ms}
            open={open?(@prepare.state)}
          >
            <ol class="q-prep-steps">
              <li :for={step <- @prepare_steps}>
                <.prep_step id={@id} step={step} preparation={@preparation} alive={@alive} />
              </li>
            </ol>
          </.row>
        </li>
        <li :if={@group}>
          <details
            id={"#{@id}-session"}
            class="q-tool q-prep-step"
            data-state={@group.state}
            open={@alive or @session_open}
            phx-mounted={JS.ignore_attributes(["open"])}
          >
            <summary class="q-hd q-prep-row">
              <.icon name="hero-chevron-right-micro" class="q-chev size-3" />
              <.state_mark state={@group.state} pulse={@alive and @group.state == "running"} />
              <span class="q-k q-prep-name">{gettext("Session started")}</span>
              <span class="q-t">
                <span :if={@group.state == "running"} class="q-running">
                  {gettext("Running")}
                </span>
                <span class="q-tc1 q-prep-cell"><.clock at={@group.at} /></span>
                <span class="q-tc2 q-prep-cell">
                  <.duration :if={@group.duration_ms} ms={@group.duration_ms} class="q-d" />
                  <.duration
                    :if={@alive and @group.state == "running"}
                    id={"#{@id}-session-clock"}
                    elapsed_seconds={0}
                    elapsed_at={@group.at}
                    class="q-d"
                  />
                </span>
              </span>
            </summary>
            <div class="q-xb">{render_slot(@session)}</div>
          </details>
        </li>
        <li :for={{kind, _at, item} <- @trailing}>
          <.prep_step
            :if={kind == :step}
            id={@id}
            step={item}
            preparation={@preparation}
            alive={@alive}
          />
          <.row
            :if={kind == :finished}
            id={"#{@id}-session-finished"}
            state={item.state}
            name={gettext("Session finished")}
            at={item.at}
            since={item.at}
            alive={@alive}
            duration_ms={item.duration_ms}
          >
            <dl class="q-prep-facts">
              <dt :if={item.result != ""}>{gettext("Result")}</dt>
              <dd :if={item.result != ""}>{item.result}</dd>
              <dt :if={item.model}>{gettext("Model")}</dt>
              <dd :if={item.model} class="font-mono text-[12.5px]">
                <.external_text text={item.model} />
              </dd>
            </dl>
          </.row>
          <.row
            :if={kind == :outputs}
            id={outputs_id(@id, item.state)}
            state={item.state}
            name={gettext("Outputs saved")}
            at={item.at}
            since={item.at}
            alive={@alive and item.ticking}
            duration_ms={item.duration_ms}
            open={open?(item.state)}
          >
            <dl :if={item.versions != []} class="q-prep-facts">
              <%= for version <- item.versions do %>
                <dt><.external_text text={version.type} /></dt>
                <dd>{gettext("Version %{number}", number: Format.number(version.number))}</dd>
              <% end %>
            </dl>
            <ol :if={item.steps != []} class="q-prep-steps">
              <li :for={step <- item.steps}>
                <.step_row
                  id={push_row(@id, step)}
                  step={step}
                  alive={@alive}
                  pruned_at={@preparation.log_pruned_at}
                />
              </li>
            </ol>
          </.row>
        </li>
        <li :if={@removed}>
          <.removed_row id={"#{@id}-removed"} removed={@removed} />
        </li>
      </ol>
    </section>
    """
  end

  attr :id, :string, required: true, doc: "the list's id"
  attr :step, :map, required: true
  attr :preparation, :map, required: true
  attr :alive, :boolean, required: true

  # A step of the preparation: open while it runs or once it failed, with its cause line.
  defp prep_step(assigns) do
    ~H"""
    <.step_row
      id={"#{@id}-step-#{@step.number}"}
      step={@step}
      alive={@alive}
      pruned_at={@preparation.log_pruned_at}
      open={open?(@step.state)}
      label={step_label(@step)}
    >
      <.cause
        :if={@preparation.stopped && @preparation.stopped.step == @step.number}
        id={"#{@id}-cause"}
        text={[cause_what(@preparation.stopped), " ", Support.stored_line(@preparation.stopped.fix)]}
      />
    </.step_row>
    """
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

  # Start machine's state: the machine's, from `dispatched` to the redemption, or failed
  # once its `machine` step failed. Machine started has the same state.
  defp start_state(%{machine: nil}), do: nil

  defp start_state(%{machine: machine} = preparation) do
    case machine_step(preparation) do
      %{state: "failed"} -> "failed"
      _other -> machine.started.state
    end
  end

  # Start machine is open when it appears while it or its `machine` step runs, or once
  # either failed.
  defp start_open?(preparation) do
    step = machine_step(preparation)
    open?(start_state(preparation)) or (step != nil and open?(step.state))
  end

  # Machine started is open when it appears while Start machine is open.
  defp started_row(%{machine: nil}), do: nil
  defp started_row(preparation), do: %{open: start_open?(preparation)}

  # The steps in Prepare, and the steps after the first session's start. Prepare has the
  # steps that started before the first session, every step while no session has
  # started; a later session's steps, such as its join, follow Session started.
  defp split_steps(%{session_started_at: nil, steps: steps}), do: {steps, []}

  defp split_steps(%{session_started_at: session, steps: steps}) do
    Enum.split_with(steps, fn step ->
      # A step with only its exit recorded is placed by its exit.
      at = step.started_at || step.exited_at
      is_nil(at) or DateTime.before?(at, session)
    end)
  end

  # Start machine's lines for a run with a step of the kind `machine`, nil without one or
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

  # Prepare spans from its first step's start to the end of its last step. It is failed
  # when a step failed; else running when one runs, and, on a live run, until its first
  # session starts or the preparation stops, so it shows no end between two steps; else
  # cancelled when one was cancelled; else succeeded. Its duration is nil while it is
  # running. `ticking` is whether a step runs: between two steps no clock counts. Nil for
  # no step.
  defp prepare_row([], _preparation, _alive), do: nil

  defp prepare_row(steps, preparation, alive) do
    states = Enum.map(steps, & &1.state)
    ticking = "running" in states

    going_on =
      alive and is_nil(preparation.session_started_at) and is_nil(preparation.stopped)

    state =
      cond do
        "failed" in states -> "failed"
        ticking or going_on -> "running"
        "cancelled" in states -> "cancelled"
        true -> "succeeded"
      end

    at = steps |> Enum.map(&(&1.started_at || &1.exited_at)) |> earliest()
    ends = steps |> Enum.map(& &1.exited_at) |> Enum.reject(&is_nil/1)

    duration_ms =
      if state != "running" and at != nil and ends != [],
        do: ms_between(at, Enum.max(ends, DateTime))

    %{state: state, at: at, duration_ms: duration_ms, ticking: ticking}
  end

  # Session started spans from the first session's start to the session's exit. Its state
  # is the exit's, succeeded for an exit with no state of a step; running while the run is
  # alive with no exit; cancelled once the run ended with none. Nil before the session
  # starts.
  defp session_row(%{session_started_at: nil}, _alive), do: nil

  defp session_row(%{session_started_at: at} = preparation, alive) do
    exited_at = preparation |> Map.get(:session_end) |> then(&(&1 && &1.exited_at))

    state =
      cond do
        exited_at -> exit_state(preparation.session_end)
        alive -> "running"
        true -> "cancelled"
      end

    %{state: state, at: at, duration_ms: exited_at && ms_between(at, exited_at)}
  end

  defp exit_state(%{state: state}) when state in ["succeeded", "failed", "cancelled"],
    do: state

  defp exit_state(_session_end), do: "succeeded"

  # Session finished, from the runtime's result to the session's exit, with the result's
  # words and the model; from the exit alone for a session with no result. Its state is
  # Session started's. Nil while the session has neither.
  defp finished_row(preparation, session, alive) do
    case Map.get(preparation, :session_end) do
      %{} = finished ->
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

  # Outputs saved: the artifact versions the run pushed, and its push steps. It starts at
  # the first push's start and ends at the end of the last push; with no push step, it
  # spans from the first version pushed to the last. It is failed when a push failed; else
  # running when one runs; else cancelled when one was cancelled; else succeeded. Its
  # duration is nil while a push runs, and when it starts and ends at one moment. Nil
  # with neither.
  defp outputs_row(preparation) do
    steps = Map.get(preparation, :after_session, [])
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

  # A row's `id` changes when a push fails, as on an open page. `row/1` keeps the `open` a
  # row mounted with, so only a new row opens; after that, a person's open or close stays.
  defp outputs_id(id, "failed"), do: "#{id}-outputs-failed"
  defp outputs_id(id, _state), do: "#{id}-outputs"

  defp push_row(id, %{state: "failed", number: number}), do: "#{id}-step-#{number}-failed"
  defp push_row(id, %{number: number}), do: "#{id}-step-#{number}"

  # Machine removed, from the Machine removed value (`clean_up/3`): from the run's end to
  # the starter's `gone` report, with the cause and the machine's time alive, from
  # `dispatched` to that report. Any other report, and the wait for one, show their words
  # and no duration. A permanent machine's row is Machine stays registered, with no time.
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
      name: gettext("Machine removed"),
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

  attr :id, :string, required: true
  attr :removed, :map, required: true

  # The Machine removed row: a mark, its name, the words of a report that is no `gone` or
  # of the wait, its start and its duration. It opens to the cause and the time alive,
  # and is no `details` without either. The words contain the state, so the mark is an
  # icon with no text for a screen reader.
  defp removed_row(%{removed: %{cause: nil, alive_ms: nil}} = assigns) do
    ~H"""
    <div id={@id} class="q-hd q-prep-row" data-clean-up={@removed.kind}>
      <span class="size-3"></span>
      <.removed_head removed={@removed} />
    </div>
    """
  end

  defp removed_row(assigns) do
    ~H"""
    <details
      id={@id}
      class="q-tool q-prep-step"
      data-clean-up={@removed.kind}
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <summary class="q-hd q-prep-row">
        <.icon name="hero-chevron-right-micro" class="q-chev size-3" />
        <.removed_head removed={@removed} />
      </summary>
      <div class="q-xb">
        <dl class="q-prep-facts">
          <dt :if={@removed.cause}>{gettext("Cause")}</dt>
          <dd :if={@removed.cause}>{@removed.cause}</dd>
          <dt :if={@removed.alive_ms}>{gettext("Alive")}</dt>
          <dd :if={@removed.alive_ms}><.duration ms={@removed.alive_ms} /></dd>
        </dl>
      </div>
    </details>
    """
  end

  attr :removed, :map, required: true

  defp removed_head(assigns) do
    ~H"""
    <.clean_up_mark kind={@removed.kind} />
    <span class="q-k q-prep-name">{@removed.name}</span>
    <span :if={@removed.text} class="q-s">{@removed.text}</span>
    <span class="q-t">
      <span class="q-tc1 q-prep-cell"><.clock :if={@removed.at} at={@removed.at} /></span>
      <span class="q-tc2 q-prep-cell">
        <.duration :if={@removed.duration_ms} ms={@removed.duration_ms} class="q-d" />
      </span>
    </span>
    """
  end

  attr :kind, :atom, required: true

  defp clean_up_mark(assigns) do
    ~H"""
    <%= case @kind do %>
      <% :gone -> %>
        <.icon name="hero-check-circle-micro" class="q-prep-ok size-4 self-center" />
      <% :delete_failed -> %>
        <.icon name="hero-x-circle-micro" class="q-prep-bad size-4 self-center" />
      <% kind when kind in [:deleting, :waiting] -> %>
        <.icon name="hero-ellipsis-horizontal-circle-micro" class="q-running size-4 self-center" />
      <% _none -> %>
        <.icon name="hero-minus-circle-micro" class="text-faint size-4 self-center" />
    <% end %>
    """
  end

  # The run's time for the heading: `%{from: at}` while the run is alive, a clock that
  # counts from the first row's start; `%{ms: ms}` once it has ended, from the first row's
  # start to the end of the last row; `%{}` without a start or an end.
  defp run_total(preparation, removed, alive) do
    from = first_at(preparation)

    cond do
      is_nil(from) -> %{}
      alive -> %{from: from}
      to = last_end(preparation, removed) -> %{ms: ms_between(from, to)}
      true -> %{}
    end
  end

  defp first_at(%{machine: %{queued_at: %DateTime{} = at}}), do: at
  defp first_at(%{machine: %{requested_at: %DateTime{} = at}}), do: at

  defp first_at(preparation) do
    preparation.steps
    |> Enum.map(&(&1.started_at || &1.exited_at))
    |> Kernel.++([preparation.session_started_at])
    |> earliest()
  end

  # The end of the last row: the `gone` report, else the latest end among the machine's,
  # the steps', the session's and the pushes'.
  defp last_end(_preparation, %{gone_at: %DateTime{} = at}), do: at

  defp last_end(preparation, _removed) do
    machine = preparation.machine
    session_end = Map.get(preparation, :session_end)

    [
      machine && machine.ended_at,
      machine && machine.started.ended_at,
      session_end && session_end.exited_at
      | Enum.map(preparation.steps ++ Map.get(preparation, :after_session, []), & &1.exited_at)
    ]
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

  # Rows with no time sort last.
  defp earlier?(nil, _b), do: false
  defp earlier?(_a, nil), do: true
  defp earlier?(a, b), do: DateTime.compare(a, b) != :gt

  defp ms_between(%DateTime{} = from, %DateTime{} = to),
    do: max(DateTime.diff(to, from, :millisecond), 0)

  defp ms_between(_from, _to), do: nil

  # Whether a row starts and ends at one moment, such as Outputs saved with one version
  # and no push step.
  defp same_moment?(%DateTime{} = at, %DateTime{} = to), do: DateTime.compare(at, to) == :eq
  defp same_moment?(_at, _to), do: false

  attr :id, :string, required: true
  attr :step, :map, required: true
  attr :alive, :boolean, required: true
  attr :pruned_at, :any, default: nil, doc: "when retention deleted the run's log lines"
  attr :open, :boolean, default: nil, doc: "whether the row is open when it appears"
  attr :label, :string, default: nil, doc: "the row's name in place of the step's"
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
          <span class="q-tc1 q-prep-cell"><.clock :if={@at} at={@at} /></span>
          <span class="q-tc2 q-prep-cell">
            <.duration :if={@duration_ms} ms={@duration_ms} class="q-d" />
            <.duration
              :if={@ticking and @since != nil}
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
  # sentence has no singular. Under Start machine, `create machine` is no line of the step.
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
