defmodule ApiaryWeb.PreparationComponents do
  @moduledoc """
  The Prepare machine section of a run's Timeline (`docs/ui.md`, The run page): how the
  run's machine was prepared, from `Apiary.Runs.Preparation`. One row per step, in the
  order the steps ran: Machine requested and Machine started for a run a node pool
  claimed, then the run's steps, then Session started. Each row has its state, its start
  time and its duration, and opens on a click to its output; a failed row is open, with
  the cause line under its output. Under Machine started the line is its second sentence
  alone, who fixes the cause: the run's header shows the first as the run's reason. While
  the run is alive, a running row has a clock that ticks in the browser, and the heading
  has the time so far; with no row running, the heading has the time to the end of the
  last row that ended.

  The last row, Clean up, shows what the pool's starter reported about the removal of the
  machine (`clean_up/3`): the report's state and time as soon as a report exists; else,
  once the run has ended and a machine existed for its dispatch, that a report is awaited
  for 15 minutes after the run ended, then that none came; and for a run on a permanent
  machine, once it has ended, that the machine stays registered. The 15 minutes are
  counted at render, against the time the caller gives (`now`); the caller renders again
  when they pass (`clean_up_due/3`).

  A step's name and output came from the run and are untrusted: they are interpolated,
  so they are escaped, and shown as a page shows a text an external system sent
  (`Apiary.ExternalText`). The machine log is shown to an instance admin alone; the
  caller reads it for an instance admin and hands it over.
  """
  use Phoenix.Component
  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.CoreComponents, only: [icon: 1]
  import ApiaryWeb.ExternalText, only: [external_text: 1]
  import ApiaryWeb.RichText, only: [rich: 1]
  import ApiaryWeb.RunComponents, only: [duration: 1, time_legend: 1]

  alias Apiary.ExternalText
  alias Apiary.Runs.Preparation
  alias ApiaryWeb.{Format, Support}
  alias Phoenix.LiveView.JS

  # The most of a machine log the section shows, in bytes.
  @machine_log_bytes 65_536

  # How long after the run ended the Clean up row waits for a report, in seconds.
  @clean_up_wait_seconds 15 * 60

  @typedoc """
  What the Clean up row shows: the starter's last report, `{:report, state, at}`; that a
  report is awaited until `due_at`, `{:waiting, due_at}`; that none came, `:no_report`;
  that the machine is permanent and stays registered, `:stays`.
  """
  @type clean_up ::
          {:report, :deleting | :gone | :delete_failed, DateTime.t()}
          | {:waiting, DateTime.t()}
          | :no_report
          | :stays

  @doc """
  Whether a preparation has a machine or a step to show. The run page also shows the
  section when it has a Clean up row (`clean_up/3`), as for a run with no step.
  """
  @spec shown?(Preparation.t() | nil) :: boolean
  def shown?(%{machine: nil, steps: []}), do: false
  def shown?(%{}), do: true
  def shown?(nil), do: false

  @doc """
  Whether the page reads a preparation no more: it was read once the run had ended, or
  once its session had started with no step running. A step that starts after that, the
  join of a later session, shows when the page is opened again.
  """
  @spec settled?(Preparation.t() | nil, boolean) :: boolean
  def settled?(nil, _alive), do: false
  def settled?(%{}, false), do: true

  def settled?(%{session_started_at: at, steps: steps}, true),
    do: at != nil and not Enum.any?(steps, &(&1.state == "running"))

  @doc """
  What the Clean up row of `preparation` shows at `now` (`t:clean_up/0`), or nil for no
  row. `run` gives whether the run is alive, and, for a run no node pool claimed, whether
  it ran on a permanent machine (a node of kind `:node`, preloaded as `run.node`).

    * A report of the starter is shown as soon as it exists, whether the run is alive or
      not.
    * With no report, a run that has ended and whose dispatch was handed over waits for
      one until 15 minutes after the run ended (`machine.ended_at`), and then has none.
    * A run with no dispatch, on a permanent machine, once it has ended, keeps its machine.
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
  When the Clean up row of `preparation` changes from waiting for a report to no report,
  as `clean_up/3` shows it at `now`: the time, or nil when the row is not waiting.
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
  The section. `machine_log` is what the caller read of the machine's log: `{:ok, text,
  truncated}` for an instance admin, `:none` while no log has arrived, `{:deleted, days}`
  once a log that arrived can have been deleted (`days` is the machine logs' retention),
  `:unreadable` for one whose file cannot be read, and `:hidden` for anyone else.
  `alive` is whether the run is alive: nothing ticks once it has ended. `clean_up` is
  what the Clean up row shows (`clean_up/3`), nil for no row.
  """
  attr :id, :string, default: "prepare-machine"
  attr :preparation, :map, required: true
  attr :machine_log, :any, default: :hidden
  attr :alive, :boolean, required: true
  attr :clean_up, :any, default: nil

  def prepare_machine(assigns) do
    going_from = going_from(assigns.preparation, assigns.alive)

    assigns =
      assign(assigns,
        total_ms: if(is_nil(going_from), do: total_ms(assigns.preparation)),
        going_from: going_from
      )

    ~H"""
    <section id={@id} class="q-prep" aria-labelledby={"#{@id}-h"}>
      <div class="q-prep-hd">
        <h2 id={"#{@id}-h"}>{gettext("Prepare machine")}</h2>
        <.duration :if={@total_ms} id={"#{@id}-total"} ms={@total_ms} class="q-prep-total" />
        <.duration
          :if={@going_from}
          id={"#{@id}-total"}
          elapsed_seconds={0}
          elapsed_at={@going_from}
          so_far
          class="q-prep-total"
        />
      </div>
      <.time_legend first={gettext("Started")} second={gettext("Took")} />
      <ol class="q-prep-steps">
        <li :if={@preparation.machine}>
          <.row
            id={"#{@id}-requested"}
            state="succeeded"
            name={gettext("Machine requested")}
            at={@preparation.machine.requested_at}
            duration_ms={@preparation.machine.requested_ms}
          >
            <dl class="q-prep-facts">
              <dt>{gettext("Pool")}</dt>
              <dd><.external_text text={@preparation.machine.pool.name} /></dd>
              <dt>{gettext("Machine type")}</dt>
              <dd>
                <.external_text
                  :if={@preparation.machine.machine_type}
                  text={@preparation.machine.machine_type}
                />
                <span :if={!@preparation.machine.machine_type}>{gettext("pool default")}</span>
              </dd>
            </dl>
          </.row>
        </li>
        <li :if={@preparation.machine}>
          <.row
            id={"#{@id}-started"}
            state={@preparation.machine.started.state}
            name={gettext("Machine started")}
            at={@preparation.machine.started.started_at}
            since={@preparation.machine.started.started_at || @preparation.machine.requested_at}
            alive={@alive}
            duration_ms={@preparation.machine.started.duration_ms}
          >
            <.machine_log id={"#{@id}-machine-log"} log={@machine_log} />
            <.cause
              :if={@preparation.stopped && @preparation.stopped.step == nil}
              id={"#{@id}-cause"}
              text={Support.stored_line(@preparation.stopped.fix)}
            />
          </.row>
        </li>
        <li :for={step <- @preparation.steps}>
          <.row
            id={"#{@id}-step-#{step.number}"}
            state={step.state}
            name={Preparation.step_name(step)}
            at={step.started_at}
            since={step.started_at}
            alive={@alive}
            duration_ms={step.duration_ms}
            sent
          >
            <.output
              :if={step.output}
              id={"#{@id}-step-#{step.number}-output"}
              output={step.output}
              pruned_at={@preparation.log_pruned_at}
            />
            <.cause
              :if={@preparation.stopped && @preparation.stopped.step == step.number}
              id={"#{@id}-cause"}
              text={[@preparation.stopped.what, " ", Support.stored_line(@preparation.stopped.fix)]}
            />
          </.row>
        </li>
        <li :if={@preparation.session_started_at}>
          <div id={"#{@id}-session"} class="q-hd q-prep-row">
            <.state_mark state="succeeded" />
            <span class="q-k">{gettext("Session started")}</span>
            <span class="q-t">
              <span class="q-tc1 q-prep-cell"><.clock at={@preparation.session_started_at} /></span>
              <span class="q-tc2 q-prep-cell"></span>
            </span>
          </div>
        </li>
        <li :if={@clean_up}>
          <.clean_up_row id={"#{@id}-clean-up"} clean_up={@clean_up} />
        </li>
      </ol>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :clean_up, :any, required: true

  # The Clean up row: a mark, its name, what was reported or awaited, and the report's
  # time. The text contains the state, so the mark is an icon with no text for a screen
  # reader.
  defp clean_up_row(assigns) do
    {kind, at} =
      case assigns.clean_up do
        {:report, state, at} -> {state, at}
        {:waiting, _due_at} -> {:waiting, nil}
        other -> {other, nil}
      end

    assigns = assign(assigns, kind: kind, at: at, text: clean_up_text(kind))

    ~H"""
    <div id={@id} class="q-hd q-prep-row" data-clean-up={@kind}>
      <.clean_up_mark kind={@kind} />
      <span class="q-k">{gettext("Clean up")}</span>
      <span class="q-s">{@text}</span>
      <span class="q-t">
        <span class="q-tc1 q-prep-cell"><.clock :if={@at} at={@at} /></span>
        <span class="q-tc2 q-prep-cell"></span>
      </span>
    </div>
    """
  end

  defp clean_up_text(:gone), do: gettext("Machine removed")
  defp clean_up_text(:deleting), do: gettext("Machine removal requested")
  defp clean_up_text(:delete_failed), do: gettext("Removal failed: the machine still exists")
  defp clean_up_text(:waiting), do: gettext("Waiting for a report")
  defp clean_up_text(:no_report), do: gettext("No removal report")
  defp clean_up_text(:stays), do: gettext("Machine stays registered")

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

  attr :id, :string, required: true
  attr :state, :string, required: true
  attr :name, :string, required: true
  attr :at, :any, required: true
  attr :since, :any, default: nil, doc: "when the row's clock starts"
  attr :alive, :boolean, default: false, doc: "whether the run is alive"
  attr :duration_ms, :integer, default: nil
  attr :sent, :boolean, default: false, doc: "whether the name came from the run"
  slot :inner_block, required: true

  defp row(assigns) do
    assigns = assign(assigns, :ticking, assigns.state == "running" and assigns.alive)

    ~H"""
    <details
      id={@id}
      class="q-tool q-prep-step"
      data-state={@state}
      open={@state == "failed"}
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
    ~H"""
    <div id={@id} class="q-well">
      <p :if={@output.truncated} class="text-xs text-faint">
        {gettext("The output is cut: this is its last 64 KiB.")}
      </p>
      <pre :if={@output.text != ""}>{ExternalText.lines(@output.text)}</pre>
      <p :if={@output.text == "" and is_nil(@pruned_at)} class="text-sm text-faint">
        {gettext("No output.")}
      </p>
      <p :if={@output.text == "" and @pruned_at} class="text-sm text-faint">
        {gettext(
          "This run's log output was pruned on %{date}, under the workspace's retention. The timeline and the connections are whole.",
          date: Format.date(@pruned_at)
        )}
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :log, :any, required: true

  defp machine_log(%{log: {:ok, text, truncated}} = assigns) do
    shown = last_bytes(text, @machine_log_bytes)

    assigns =
      assign(assigns, text: shown, truncated: truncated or byte_size(shown) < byte_size(text))

    ~H"""
    <div id={@id} class="q-well">
      <div><span>{gettext("Machine log (instance admins)")}</span></div>
      <p :if={@truncated} class="text-xs text-faint">
        {gettext("The machine log is cut: this is its last part.")}
      </p>
      <pre>{ExternalText.lines(@text)}</pre>
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

  attr :id, :string, required: true
  attr :text, :any, required: true, doc: "rich text (`ApiaryWeb.RichText`)"

  defp cause(assigns) do
    ~H"""
    <p id={@id} class="q-prep-cause" role="status"><.rich text={@text} /></p>
    """
  end

  # When the preparation of a live run began, while it goes on: it has not ended
  # (`ended_at/1`), and a row is running, or the machine started and no step has yet.
  # Between two steps, and for a runtime with no session event once its last step ended,
  # nothing shows that it goes on, so no clock counts past it: the heading has the time
  # to the end of the last row that ended (`total_ms/1`).
  defp going_from(preparation, alive) do
    if alive and is_nil(ended_at(preparation)) and going_on?(preparation),
      do: first_at(preparation)
  end

  defp going_on?(%{machine: machine, steps: steps}) do
    Enum.any?(steps, &(&1.state == "running")) or
      (machine != nil and (machine.started.state == "running" or steps == []))
  end

  defp first_at(%{machine: %{requested_at: at}}), do: at
  defp first_at(%{steps: [%{started_at: at} | _]}), do: at
  defp first_at(_preparation), do: nil

  # From the first row's time to the session's start, to the end of the failed row, or,
  # with neither and no row running, to the end of the last row that ended. The caller
  # shows it only while no clock counts (`going_from/2`).
  defp total_ms(preparation) do
    from = first_at(preparation)
    to = ended_at(preparation) || last_end(preparation)
    if from && to, do: max(DateTime.diff(to, from, :millisecond), 0)
  end

  # When the preparation ended: the session's start, or the end of the failed row; nil
  # while it has done neither.
  defp ended_at(%{session_started_at: %DateTime{} = at}), do: at
  defp ended_at(%{stopped: nil}), do: nil
  defp ended_at(%{stopped: %{step: nil}, machine: machine}), do: machine.started.ended_at

  defp ended_at(%{stopped: %{step: number}, steps: steps}),
    do: Enum.find_value(steps, &(&1.number == number && &1.exited_at))

  # The latest end among the rows, while none is running; nil while one is, or none has
  # an end.
  defp last_end(%{machine: machine, steps: steps}) do
    running? =
      Enum.any?(steps, &(&1.state == "running")) or
        (machine != nil and machine.started.state == "running")

    ends = [machine && machine.started.ended_at | Enum.map(steps, & &1.exited_at)]

    case Enum.reject(ends, &is_nil/1) do
      [_ | _] = ends when not running? -> Enum.max(ends, DateTime)
      _none -> nil
    end
  end

  # The last `limit` bytes of `text` at most, starting at a character.
  defp last_bytes(text, limit) when byte_size(text) <= limit, do: text

  defp last_bytes(text, limit),
    do: drop_partial(binary_part(text, byte_size(text) - limit, limit))

  defp drop_partial(<<_::utf8, _::binary>> = text), do: text
  defp drop_partial(<<_byte, rest::binary>>), do: drop_partial(rest)
  defp drop_partial(<<>>), do: ""
end
