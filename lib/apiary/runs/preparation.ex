defmodule Apiary.Runs.Preparation do
  @moduledoc """
  How a run's machine was prepared, from the machine request to the start of its session,
  as the run page's Prepare machine section and the run's diagnostics show it. Read from
  records Qory Apiary keeps for every run: the run's dispatch, its steps
  (`Apiary.Runs.Step`) with their log lines, and its first `dev.qory.session.started`.

  `read/2` returns a map with five members:

    * `machine`: the dispatch whose claim registered the run, nil for a run no node
      pool claimed. `requested_at` is the claim; `started` spans from the starter's
      `dispatched` to the redemption of the run's code, or to the failure that ended the
      attempt (`t:machine/0`).
    * `steps`: the run's steps by number, each with its output: the last 64 KiB of its
      log lines as plain text (`Apiary.Runs.Record.plain_lines/1`), and whether that is
      cut (`t:step/0`). The output is nil for a reader who may not read the run's log
      (`run.read_log`), and empty once retention deleted the run's log lines.
    * `log_pruned_at`: when retention deleted the run's log lines (`runs.log_pruned_at`),
      nil while they are kept.
    * `session_started_at`: the time of the run's first `dev.qory.session.started`; nil
      before the session starts and once retention deleted the run's events.
    * `stopped`: why the preparation failed, nil while it has not (`t:stopped/0`).

  Every read is scoped as `Apiary.Runs.Record` scopes it: the scope's organisation and
  workspace, and the run's row id.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Access, ExternalText, Repo, SecretLogFilter}
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.Dispatch
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias Apiary.Runs.{Record, Run, Step}

  # The most of a step's output that is kept, in bytes of UTF-8.
  @output_bytes 65_536

  # The steps whose cause lies in the workspace: its targets, harness and set-up. A
  # failure of any other kind of step the contract lists lies on the pool's machine; a
  # kind outside the list counts as the workspace's.
  @pool_kinds ~w(image join wall)

  @typedoc "Where the cause of a failure lies, by who can fix it."
  @type fixer :: :instance_admin | :operator_admin | :workspace_admin

  @typedoc "Why a preparation failed."
  @type cause ::
          :machine_not_made | :lease_lapsed | :code_not_redeemed | :machine_stopped | :step_failed

  @typedoc """
  The pool that claimed the run: its public id, its name, and where it lives:
  `:instance` for the instance's pool, `:workspace` for a pool of the run's workspace,
  `:operator` for a pool of another organisation, whose name is `operator`.
  """
  @type pool :: %{
          id: String.t(),
          name: String.t(),
          place: :instance | :workspace | :operator,
          operator: String.t() | nil
        }

  @typedoc """
  The machine part. `dispatch_id` is the dispatch's public id, `dp_…`. `machine_type` is
  nil while the claim answer has no machine type. `release_reason` is the starter's
  reason of a release, nil for any other dispatch. `started.state` is `running`,
  `succeeded`, `failed` or `cancelled`, as a step's.
  """
  @type machine :: %{
          dispatch_id: String.t(),
          pool: pool,
          machine_type: String.t() | nil,
          requested_at: DateTime.t(),
          release_reason: String.t() | nil,
          started: %{
            state: String.t(),
            started_at: DateTime.t() | nil,
            ended_at: DateTime.t() | nil,
            duration_ms: non_neg_integer | nil
          }
        }

  @typedoc """
  One step. `name` is qory's name with its first letter in upper case, nil when only the
  step's exit is recorded, as `started_at` is.
  """
  @type step :: %{
          number: pos_integer,
          name: String.t() | nil,
          kind: String.t() | nil,
          state: String.t(),
          exit_code: integer | nil,
          started_at: DateTime.t() | nil,
          exited_at: DateTime.t() | nil,
          duration_ms: non_neg_integer | nil,
          output: %{text: String.t(), truncated: boolean} | nil
        }

  @typedoc """
  Why the preparation failed: the cause, the number of the failed step for `:step_failed`
  (nil for any other cause), who can fix it, and the cause line: `text`, what happened
  and who fixes it, and `fix`, its second sentence alone.
  """
  @type stopped :: %{
          cause: cause,
          step: pos_integer | nil,
          fixer: fixer,
          text: String.t(),
          fix: String.t()
        }

  @type t :: %{
          machine: machine | nil,
          steps: [step],
          log_pruned_at: DateTime.t() | nil,
          session_started_at: DateTime.t() | nil,
          stopped: stopped | nil
        }

  @doc """
  The preparation of `run` for the reader of `scope`: the moduledoc. `opts`:

    * `log`, whether the steps' output is read, by default whether `scope` may read the
      run's log (`run.read_log`). `Apiary.Runs.Diagnostics` sets it for a diagnostics
      key, which reads every run's log and has no scope in the run's workspace.
    * `release_reason`, how `stopped`'s text has the pool's release reason: `:filtered`,
      by default, through the secret filter (`Apiary.SecretLogFilter.filter_text/1`), as
      the run page's header has it; `:as_stored` for the diagnostics document, which
      keeps every text as stored.
  """
  @spec read(Scope.t(), Run.t(), keyword) :: t
  def read(%Scope{} = scope, %Run{} = run, opts \\ []) do
    attempt = attempt(scope, run)
    log? = Keyword.get_lazy(opts, :log, fn -> Access.can?(scope, :"run.read_log", run) end)
    kept? = is_nil(run.log_pruned_at)
    steps = for step <- Record.steps(scope, run), do: step(scope, run, step, log?, kept?)
    session_started_at = Record.session_started_at(scope, run)
    machine = machine(run, attempt, steps, session_started_at)

    %{
      machine: machine,
      steps: steps,
      log_pruned_at: run.log_pruned_at,
      session_started_at: session_started_at,
      stopped:
        stopped(
          scope,
          run,
          attempt,
          machine,
          steps,
          Keyword.get(opts, :release_reason, :filtered)
        )
    }
  end

  @doc "The most of a step's output a preparation keeps, in bytes: #{@output_bytes}."
  def output_bytes, do: @output_bytes

  ## The dispatch

  # The run's dispatch, with its pool, and how the attempt failed, if it did. This
  # function alone finds the dispatch.
  #
  # The dispatch is the one whose claim registered the run (`dispatch_id`) for a run whose
  # start failed, else the last one claimed of the run's run of the queue; a run no node
  # pool claimed has none, and neither has a run whose dispatch was deleted since. The
  # failure is the run's `start_failure` (`Apiary.Runs.Run.start_failures/0`) at
  # `start_failed_at`, or `code_not_redeemed` for a run lost with its code never redeemed.
  defp attempt(scope, %Run{} = run) do
    case dispatch(scope, run) do
      %Dispatch{} = dispatch -> %{dispatch: dispatch, failure: failure(run)}
      nil -> %{dispatch: nil, failure: nil}
    end
  end

  defp dispatch(scope, %Run{dispatch_id: id}) when is_binary(id),
    do: Repo.one(from d in dispatches(scope), where: d.id == ^id)

  defp dispatch(scope, %Run{dispatch_run_id: id}) when is_binary(id) do
    Repo.one(
      from d in dispatches(scope),
        where: d.dispatch_run_id == ^id,
        order_by: [desc: d.claimed_at, desc: d.id],
        limit: 1
    )
  end

  defp dispatch(_scope, %Run{}), do: nil

  defp dispatches(%Scope{organisation: organisation, workspace: workspace}) do
    from d in Dispatch,
      where: d.organisation_id == ^organisation.id and d.workspace_id == ^workspace.id,
      preload: [pool: :organisation]
  end

  defp failure(%Run{start_failure: "machine_not_made", start_failed_at: at}),
    do: {:machine_not_made, at}

  defp failure(%Run{start_failure: "lease_lapsed", start_failed_at: at}),
    do: {:lease_lapsed, at}

  defp failure(%Run{start_failure: "machine_stopped", start_failed_at: at}),
    do: {:machine_stopped, at}

  defp failure(%Run{} = run) do
    if code_lost?(run), do: {:code_not_redeemed, run.lost_at || run.run_code_expires_at}
  end

  # Lost with no attach, no exit and no outcome, its code never redeemed: the code's 15
  # minutes ran out.
  defp code_lost?(
         %Run{state: "lost", attached_at: nil, exited_at: nil, outcome_state: nil} = run
       ),
       do: not is_nil(run.run_code_expires_at) and is_nil(run.run_code_public_key)

  defp code_lost?(%Run{}), do: false

  ## The machine

  defp machine(_run, %{dispatch: nil}, _steps, _session_started_at), do: nil

  defp machine(run, %{dispatch: dispatch, failure: failure}, steps, session_started_at) do
    started_at = dispatch.dispatched_at

    {state, ended_at} =
      case failure do
        {_cause, at} ->
          {"failed", at}

        nil ->
          cond do
            ended = started_by(run, dispatch) -> {"succeeded", ended}
            steps != [] or session_started_at != nil -> {"succeeded", nil}
            run.state in Run.alive_states() -> {"running", nil}
            true -> {"cancelled", nil}
          end
      end

    %{
      dispatch_id: dispatch.public_id,
      pool: pool(dispatch.pool, run),
      machine_type: nil,
      requested_at: dispatch.claimed_at,
      release_reason: dispatch.release_reason,
      started: %{
        state: state,
        started_at: started_at,
        ended_at: ended_at,
        duration_ms: between(started_at, ended_at)
      }
    }
  end

  # When the machine started the run: the redemption of the run's code, which sets the
  # run key's issue time; for a run without a code, the dispatch's handover.
  defp started_by(%Run{run_code_public_key: key, run_key_issued_at: at}, _dispatch)
       when is_binary(key) and not is_nil(at),
       do: at

  defp started_by(%Run{run_code_expires_at: nil}, %Dispatch{handed_over_at: at}), do: at
  defp started_by(_run, _dispatch), do: nil

  defp pool(%Node{organisation_id: nil} = pool, _run),
    do: %{id: pool.public_id, name: pool.name, place: :instance, operator: nil}

  defp pool(%Node{organisation_id: id} = pool, %Run{organisation_id: id}),
    do: %{id: pool.public_id, name: pool.name, place: :workspace, operator: nil}

  defp pool(%Node{organisation: %Organisation{name: operator}} = pool, _run),
    do: %{id: pool.public_id, name: pool.name, place: :operator, operator: operator}

  defp between(%DateTime{} = from, %DateTime{} = to),
    do: max(DateTime.diff(to, from, :millisecond), 0)

  defp between(_from, _to), do: nil

  ## The steps

  # A step's output is read while the run's log lines are kept (`kept?`), and is empty
  # once retention deleted them.
  defp step(scope, run, %Step{} = step, log?, kept?) do
    %{
      number: step.step,
      name: name(step.name),
      kind: step.kind,
      state: step.state,
      exit_code: step.exit_code,
      started_at: step.started_at,
      exited_at: step.exited_at,
      duration_ms: step.duration_ms,
      output: if(log?, do: output(scope, run, step.step, kept?))
    }
  end

  # qory's name as it gave it, with its first letter in upper case.
  defp name(nil), do: nil

  defp name(name) do
    case String.next_grapheme(name) do
      {first, rest} -> String.upcase(first) <> rest
      nil -> nil
    end
  end

  # The step's output as plain text, at most #{@output_bytes} bytes: the end of it when it
  # is longer, without the line the cut fell in, unless that line is all there is.
  defp output(_scope, _run, _number, false), do: %{text: "", truncated: false}

  defp output(scope, run, number, true) do
    %{bytes: bytes, total: total} = Record.step_tail(scope, run, number, @output_bytes)
    cut? = total > byte_size(bytes)
    lines = Record.plain_lines(bytes)
    lines = if cut? and length(lines) > 1, do: tl(lines), else: lines
    whole = Enum.join(lines, "\n")
    text = last_bytes(whole, @output_bytes)
    %{text: text, truncated: cut? or text != whole}
  end

  # The last `limit` bytes of `text` at most, starting at a character.
  defp last_bytes(text, limit) when byte_size(text) <= limit, do: text

  defp last_bytes(text, limit) do
    tail = binary_part(text, byte_size(text) - limit, limit)
    drop_partial(tail)
  end

  defp drop_partial(<<_::utf8, _::binary>> = text), do: text
  defp drop_partial(<<_byte, rest::binary>>), do: drop_partial(rest)
  defp drop_partial(<<>>), do: ""

  ## Why it stopped

  defp stopped(scope, _run, %{failure: {cause, _at}}, machine, _steps, release_reason) do
    {fixer, who} = pool_fixer(scope, machine.pool)
    machine = %{machine | release_reason: reason(machine.release_reason, release_reason)}
    {what, fix} = machine_line(cause, machine, who, log_place(machine.pool))
    %{cause: cause, step: nil, fixer: fixer, text: what <> " " <> fix, fix: fix}
  end

  defp stopped(scope, run, _attempt, machine, steps, _release_reason) do
    case Enum.find(steps, &(&1.state == "failed")) do
      nil ->
        nil

      step ->
        {fixer, who} =
          if step.kind in @pool_kinds,
            do: pool_fixer(scope, machine && machine.pool),
            else: workspace_fixer(scope)

        {what, fix} = step_line(step, who, run.log_pruned_at)

        %{
          cause: :step_failed,
          step: step.number,
          fixer: fixer,
          text: what <> " " <> fix,
          fix: fix
        }
    end
  end

  # Each cause line is two sentences: what happened, then who fixes it. The first sentence
  # of a machine's cause is the one the run's header shows as the run's reason
  # (`ApiaryWeb.RunComponents.reason_words/1`), but for a lapsed lease, which names the
  # pool here.
  defp machine_line(:machine_not_made, machine, who, place) do
    {gettext("No machine was made: %{reason}.", reason: machine.release_reason),
     reads_why(who, place)}
  end

  defp machine_line(:lease_lapsed, machine, who, _place) do
    pool = pool_name(machine.pool)

    {gettext("%{pool} did not start a machine within 10 minutes.", pool: pool),
     gettext("%{who} checks that %{pool} is running.", who: who, pool: pool)}
  end

  defp machine_line(:code_not_redeemed, _machine, who, place) do
    {gettext("The machine did not start the run within 15 minutes of the request."),
     reads_why(who, place)}
  end

  defp machine_line(:machine_stopped, _machine, who, place) do
    {gettext("The machine stopped before it started the run."), reads_why(who, place)}
  end

  # The machine log of the instance's pool is on the run page, under Machine started, for
  # an instance admin, who fixes its causes.
  defp reads_why(_who, :machine_started) do
    gettext("An instance admin finds the cause in the machine log of the Machine started step.")
  end

  defp reads_why(who, place),
    do: gettext("%{who} reads why in %{place}.", who: who, place: place)

  # An exit code of -1 is no exit status (the Forager contract's `dev.qory.run.step_exited`),
  # so the line shows none.
  defp step_line(%{exit_code: code} = step, who, pruned_at)
       when is_integer(code) and code != -1 do
    {gettext("%{step} failed with exit code %{code}.", step: step_name(step), code: code),
     reads_cause(who, pruned_at)}
  end

  defp step_line(step, who, pruned_at),
    do: {gettext("%{step} failed.", step: step_name(step)), reads_cause(who, pruned_at)}

  # Once retention deleted the run's log lines, the step's output is gone.
  defp reads_cause(who, nil),
    do: gettext("%{who} reads the cause in the step's output.", who: who)

  defp reads_cause(_who, _pruned_at) do
    gettext(
      "The step's output was deleted under the workspace's log retention, so the cause is no longer shown."
    )
  end

  @doc """
  What the run page calls a step: its name (`t:step/0`), or "Step" and its number when
  only its exit is recorded.
  """
  @spec step_name(map) :: String.t()
  def step_name(%{name: name}) when is_binary(name), do: name
  def step_name(%{number: number}), do: gettext("Step %{number}", number: number)

  @doc """
  The step a preparation stopped at, as the run page names it: Machine started for a
  cause of the machine, else the failed step's name (`step_name/1`); nil while it has not
  stopped.
  """
  @spec stopped_step(t) :: String.t() | nil
  def stopped_step(%{stopped: %{step: nil}}), do: gettext("Machine started")

  def stopped_step(%{stopped: %{step: number}, steps: steps}),
    do: steps |> Enum.find(&(&1.number == number)) |> step_name()

  def stopped_step(_preparation), do: nil

  # The starter's reason as a line an external system sent, with its one closing full
  # stop left out for the sentence's, through the secret filter unless kept as stored.
  defp reason(nil, _how), do: gettext("n/a")

  defp reason(reason, :filtered),
    do: reason |> SecretLogFilter.filter_text() |> reason(:as_stored)

  defp reason(reason, :as_stored),
    do: reason |> ExternalText.line() |> String.replace_suffix(".", "")

  defp pool_name(%{name: name}), do: name

  # Who fixes a cause in the pool: an instance admin for the instance's pool, an admin of
  # the operator for an operator's, an admin of the workspace for the workspace's and for
  # a pool that is not known.
  defp pool_fixer(_scope, %{place: :instance}),
    do: {:instance_admin, gettext("An instance admin")}

  defp pool_fixer(_scope, %{place: :operator, operator: operator}),
    do: {:operator_admin, gettext("An admin of %{operator}", operator: operator)}

  defp pool_fixer(scope, _pool), do: workspace_fixer(scope)

  defp workspace_fixer(%Scope{workspace: workspace}),
    do: {:workspace_admin, gettext("An admin of %{workspace}", workspace: workspace.name)}

  # Where the machine log of the instance's pool is read: under Machine started on the run
  # page, by an instance admin. Any other pool's admins read it on the pool's host.
  defp log_place(%{place: :instance}), do: :machine_started

  defp log_place(pool),
    do: gettext("the log of %{pool} on its host", pool: pool_name(pool))
end
