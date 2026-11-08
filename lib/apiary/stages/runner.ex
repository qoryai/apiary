defmodule Apiary.Stages.Runner do
  # Runner is the stage runner's rules as pure functions: given a stage of a process
  # document (`Apiary.Processes`), where a work item is in it, an event and the facts the
  # caller read, it says the stage's next state, the new position and the actions to take.
  # It reads no database; `Apiary.Stages` reads the facts and applies the actions.
  #
  # ## The position
  #
  # A position is `%{entry: i, loop_entry: j, round: r}`: `i` the index in the stage's
  # sequence, `j` the index in the body of the loop at `i` (nil when the entry at `i` is a
  # workflow), and `r` the round. Entering a loop starts its round 1; a workflow outside a
  # loop keeps the round it found. An `entry` equal to the sequence's length is the end of
  # the sequence: the output checks, then the gate.
  #
  # ## The rules (the workflow model, § 4 to § 7, and its additions 1, 4 and 10)
  #
  #   * Entering a stage starts its sequence at once. A stage waits first while a required
  #     input is missing (`:waiting_inputs`), or while a workflow of its sequence is not
  #     declared by the workspace's harness (`:waiting_workflow`).
  #   * In a loop, `passed` from any workflow leaves the loop at once. `changes-requested`,
  #     or a run with no verdict, runs the next workflow of the ring; after the last one the
  #     ring goes back to the first, which starts the next round. At the round limit the
  #     stage escalates, `round_limit`, with the newest gaps.
  #   * Outside a loop, the sequence goes on after a run with `passed` or
  #     `changes-requested`. A run with no verdict escalates, `run_stopped`, with no gaps,
  #     on a first run and on a rerun. A test work item's run with no verdict goes on
  #     (`facts.test`): the built-in `hello` writes no verdict
  #     (`Apiary.Harnesses.Builtin`). So does a run of Explore whose take in has a
  #     proposal, or that left open questions (`facts.explore_result`).
  #   * `escalate` escalates, `escalate`; a run that stopped escalates, `run_stopped`, with
  #     its cause as the gaps.
  #   * Questions wait for answers (`:waiting_answers`), in any round and at any count of
  #     runs; the answers run the same workflow again, as the loop's next round.
  #   * At the end of the sequence the Exists checks run. When every required output
  #     passes, a person gate waits (`:at_gate`) and a gate `none` passes on (`:advance`).
  #     On a failure, a stage with a loop starts another round of its last loop, with the
  #     failed checks as the gaps of that round (`{:checks_failed, round, gaps}`), and the
  #     round counts; at the limit it escalates,
  #     `round_limit`. A stage with workflows and no loop escalates, `check_failed`.
  #   * A stage with no workflow is worked by people (§ 4): with a required output
  #     missing, it waits at its gate, a gate `none` too, and escalates nothing. A version
  #     a person adds in the stage (`:version_added`) runs the checks again: once every
  #     required output passes, a gate `none` passes on and a person gate keeps waiting.
  #   * Request changes runs the sequence again from its first loop, round 1, or from its
  #     start when it has no loop.
  #   * An escalation accepted counts the loop as passed: the sequence goes on with its
  #     next workflow, or, after its last, to the gate without the Exists checks, where
  #     a failed check stays shown (§ 6); an escalation at the end of the sequence goes to
  #     the gate too. Another round runs
  #     one more round: the same workflow for a stopped run, the loop's first workflow
  #     otherwise, the last loop for an escalation at the end, or the sequence from its
  #     start for a stage with no loop.
  #   * A queued run's time limit and access level are the lower of the entry's and the
  #     workflow's declaration (addition 10); its machine type is the entry's, else the
  #     document's.
  @moduledoc false

  @default_rounds 3

  @typedoc "Where a work item is in its stage's sequence."
  @type position :: %{
          entry: non_neg_integer,
          loop_entry: non_neg_integer | nil,
          round: pos_integer
        }

  @typedoc "A stage's state, as `work_items.stage_state` keeps it."
  @type state ::
          :running
          | :waiting_inputs
          | :waiting_answers
          | :waiting_workflow
          | :escalated
          | :at_gate
          | :done

  @typedoc "Why a stage escalates."
  @type cause :: :round_limit | :escalate | :check_failed | :run_stopped

  @typedoc """
  What a run gave: its newest verdict with its gaps (nil verdict for none), its
  questions, or why it stopped.
  """
  @type run_result ::
          {:verdict, :passed | :changes_requested | :escalate | nil, String.t() | nil}
          | {:questions, String.t()}
          | {:stopped, String.t()}

  @typedoc "What happened to the stage."
  @type event ::
          :enter
          | :resume
          | {:run, run_result}
          | :answered
          | :request_changes
          | {:accept, cause}
          | {:another_round, cause}
          | :version_added

  @typedoc """
  What the caller read: the stage's required input types with no version
  (`missing_inputs`), the stage's workflow names the harness does not declare
  (`undeclared`), the required output types whose Exists check fails (`failed_checks`),
  the document's machine type (`machine`), the harness's declarations by workflow name
  (`declarations`), whether the work item is a test work item (`test`) and, at a run's
  end, whether the run is a run of Explore whose take in has a proposal, or that left open
  questions (`explore_result`).
  """
  @type facts :: %{
          optional(:missing_inputs) => [String.t()],
          optional(:undeclared) => [String.t()],
          optional(:failed_checks) => [String.t()],
          optional(:machine) => String.t() | nil,
          optional(:declarations) => %{String.t() => map | nil},
          optional(:test) => boolean,
          optional(:explore_result) => boolean
        }

  @typedoc "A run to queue, at the position it runs at."
  @type run_spec :: %{
          workflow: String.t(),
          machine_type: String.t(),
          time_limit: pos_integer | nil,
          access: :read | :write | nil,
          entry: non_neg_integer,
          loop_entry: non_neg_integer | nil,
          round: pos_integer
        }

  @typedoc "An action for `Apiary.Stages` to apply."
  @type action ::
          {:queue, run_spec}
          | {:escalate, cause, String.t() | nil}
          | {:checks_failed, pos_integer, String.t()}
          | :advance

  @typedoc "The stage's next state, its position and the actions to apply."
  @type outcome :: %{state: state, position: position, actions: [action]}

  # step/4 is the outcome of `event` for `stage`, a stage of a process document, at
  # `position` (nil before the stage is entered), with `facts`.
  @doc false
  @spec step(map, position | nil, event, facts) :: outcome
  def step(stage, position, event, facts \\ %{})

  def step(stage, _position, :enter, facts), do: enter(stage, facts)

  # A stage waiting for inputs or for a workflow tries again from where it waits.
  def step(stage, position, :resume, facts) do
    cond do
      missing_inputs(facts) != [] -> enter(stage, facts)
      position == nil -> enter(stage, facts)
      true -> start_checked(stage, position, facts)
    end
  end

  def step(stage, position, {:run, result}, facts), do: run_ended(stage, position, result, facts)

  def step(stage, position, :answered, facts) do
    if in_loop?(position),
      do: start(stage, %{position | round: position.round + 1}, facts),
      else: start(stage, position, facts)
  end

  def step(stage, _position, :request_changes, facts) do
    case first_loop(stage) do
      nil -> start(stage, at(stage, 0, 1), facts)
      index -> start(stage, %{entry: index, loop_entry: 0, round: 1}, facts)
    end
  end

  def step(stage, position, {:accept, _cause}, facts) do
    next = next(stage, position)

    cond do
      at_end?(stage, position) -> gate(stage, position)
      entry_at(stage, next) == nil -> gate(stage, %{next | loop_entry: nil})
      true -> start(stage, next, facts)
    end
  end

  # A person added a version at the gate of a stage with no workflow: the checks run
  # again. At the gate of a stage with workflows, a version changes nothing.
  def step(stage, position, :version_added, facts) do
    if people?(stage),
      do: finish(stage, %{position | entry: length(sequence(stage)), loop_entry: nil}, facts),
      else: %{state: :at_gate, position: position, actions: []}
  end

  def step(stage, position, {:another_round, cause}, facts) do
    cond do
      at_end?(stage, position) ->
        case last_loop(stage) do
          nil -> start(stage, at(stage, 0, position.round), facts)
          index -> start(stage, %{entry: index, loop_entry: 0, round: position.round + 1}, facts)
        end

      in_loop?(position) and cause == :run_stopped ->
        start(stage, %{position | round: position.round + 1}, facts)

      in_loop?(position) ->
        start(stage, %{position | loop_entry: 0, round: position.round + 1}, facts)

      true ->
        start(stage, position, facts)
    end
  end

  ## Entering and starting

  defp enter(stage, facts) do
    position = at(stage, 0, 1)
    start_checked(stage, position, facts)
  end

  # Starts at `position` once every required input exists and every workflow of the
  # stage is declared.
  defp start_checked(stage, position, facts) do
    cond do
      missing_inputs(facts) != [] ->
        %{state: :waiting_inputs, position: position, actions: []}

      Enum.any?(workflows(stage), &(&1 in undeclared(facts))) ->
        %{state: :waiting_workflow, position: position, actions: []}

      true ->
        start(stage, position, facts)
    end
  end

  # Runs what is at `position`: a workflow, the workflow of a loop's body, or, past the
  # sequence's end, the checks.
  defp start(stage, position, facts) do
    case entry_at(stage, position) do
      nil -> finish(stage, %{position | entry: length(sequence(stage)), loop_entry: nil}, facts)
      entry -> queue(entry, position, facts)
    end
  end

  defp queue(%{"workflow" => workflow} = entry, position, facts) do
    if workflow in undeclared(facts) do
      %{state: :waiting_workflow, position: position, actions: []}
    else
      declaration = Map.get(Map.get(facts, :declarations, %{}), workflow)
      %{time_limit: time_limit, access: access} = lowered(entry, declaration)

      spec = %{
        workflow: workflow,
        machine_type: entry["machine"] || Map.get(facts, :machine) || "default",
        time_limit: time_limit,
        access: access,
        entry: position.entry,
        loop_entry: position.loop_entry,
        round: position.round
      }

      %{state: :running, position: position, actions: [{:queue, spec}]}
    end
  end

  # limits/4 is the time limit, in seconds, and the access level of a run of the entry at
  # `position` of `stage`, given the harness's declaration of its workflow (nil for
  # none): the lower of the entry's and the declaration's (addition 10). nil where the
  # position has no workflow entry.
  #
  # `workflow` is the workflow of a stage's run (`Apiary.Stages.run_workflow/1`), nil for
  # any other run. `Apiary.Processes.assign/3` moves a waiting run to a version that may
  # have another workflow at the run's position, or no entry. The level of that entry
  # does not apply to the run, so its access level is `:read`. Its time limit is that
  # entry's, nil for no entry.
  @doc false
  @spec limits(map, position, map | nil, String.t() | nil) ::
          %{time_limit: pos_integer | nil, access: :read | :write | nil} | nil
  def limits(stage, position, declaration, workflow \\ nil) do
    case entry_at(stage, position) do
      %{"workflow" => name} = entry when workflow in [nil, name] -> lowered(entry, declaration)
      %{"workflow" => _other} = entry -> %{lowered(entry, declaration) | access: :read}
      _none when is_nil(workflow) -> nil
      _none -> %{time_limit: nil, access: :read}
    end
  end

  defp lowered(entry, declaration) do
    %{
      time_limit:
        lower_time(seconds(entry["time_limit"]), seconds(declared(declaration, :time_limit))),
      access: lower_access(entry["access"], declared(declaration, :access))
    }
  end

  ## A run's end

  defp run_ended(stage, position, {:verdict, :passed, _gaps}, facts),
    do: start(stage, next(stage, position), facts)

  defp run_ended(_stage, position, {:verdict, :escalate, gaps}, _facts),
    do: escalate(:escalate, gaps, position)

  defp run_ended(stage, position, {:verdict, verdict, gaps}, facts) do
    cond do
      in_loop?(position) ->
        ring(stage, position, gaps, facts)

      is_nil(verdict) and not no_verdict_goes_on?(facts) ->
        escalate(:run_stopped, nil, position)

      true ->
        start(stage, next(stage, position), facts)
    end
  end

  defp run_ended(_stage, position, {:stopped, cause}, _facts),
    do: escalate(:run_stopped, cause, position)

  defp run_ended(_stage, position, {:questions, _questions}, _facts),
    do: %{state: :waiting_answers, position: position, actions: []}

  # Whether a run with no verdict outside a loop goes on: a test work item's run, or a run
  # of Explore whose take in has a proposal, or that left open questions, as Explore's
  # result is its proposal or its questions.
  defp no_verdict_goes_on?(facts),
    do: Map.get(facts, :test, false) or Map.get(facts, :explore_result, false)

  # The next workflow of the loop's ring, or the next round from its first, or the round
  # limit.
  defp ring(stage, position, gaps, facts) do
    body = body(stage, position.entry)

    cond do
      position.loop_entry + 1 < length(body) ->
        start(stage, %{position | loop_entry: position.loop_entry + 1}, facts)

      position.round >= rounds(stage, position.entry) ->
        escalate(:round_limit, gaps, position)

      true ->
        start(stage, %{position | loop_entry: 0, round: position.round + 1}, facts)
    end
  end

  ## The end of the sequence

  defp finish(stage, position, facts) do
    failed = Map.get(facts, :failed_checks, [])

    cond do
      failed == [] ->
        gate(stage, position)

      # No run makes the outputs of a stage with no workflow: people add them at its gate.
      people?(stage) ->
        %{state: :at_gate, position: position, actions: []}

      true ->
        gaps = check_gaps(failed)

        case last_loop(stage) do
          nil ->
            escalate(:check_failed, gaps, position)

          index ->
            if position.round >= rounds(stage, index) do
              escalate(:round_limit, gaps, position)
            else
              round = position.round + 1
              outcome = start(stage, %{entry: index, loop_entry: 0, round: round}, facts)
              %{outcome | actions: [{:checks_failed, round, gaps} | outcome.actions]}
            end
        end
    end
  end

  defp gate(stage, position) do
    case get_in(stage, ["gate", "kind"]) do
      "none" -> %{state: :done, position: position, actions: [:advance]}
      _person -> %{state: :at_gate, position: position, actions: []}
    end
  end

  defp escalate(cause, gaps, position),
    do: %{state: :escalated, position: position, actions: [{:escalate, cause, gaps}]}

  # check_gaps/1 is the gaps of failed Exists checks, one line per output type.
  @doc false
  @spec check_gaps([String.t()]) :: String.t()
  def check_gaps(types), do: Enum.map_join(types, "\n", &"No #{&1} was stored in this stage.")

  ## The document

  # The position that starts the entry at `index`: a loop at its round 1 and its first
  # workflow, a workflow or the end at `round`.
  defp at(stage, index, round) do
    case Enum.at(sequence(stage), index) do
      %{"loop" => _loop} -> %{entry: index, loop_entry: 0, round: 1}
      _workflow_or_end -> %{entry: index, loop_entry: nil, round: round}
    end
  end

  defp next(stage, position), do: at(stage, position.entry + 1, position.round)

  defp entry_at(stage, %{entry: index, loop_entry: loop_entry}) do
    case Enum.at(sequence(stage), index) do
      %{"loop" => %{"body" => body}} -> Enum.at(body, loop_entry || 0)
      %{"workflow" => _name} = entry -> entry
      _end -> nil
    end
  end

  defp sequence(stage), do: Map.get(stage, "sequence") || []

  defp body(stage, index), do: get_in(Enum.at(sequence(stage), index), ["loop", "body"]) || []

  # rounds/2 is the round limit of the loop at `index`, 3 by default (D7).
  @doc false
  @spec rounds(map, non_neg_integer | nil) :: pos_integer | nil
  def rounds(stage, index) when is_integer(index) do
    case Enum.at(sequence(stage), index) do
      %{"loop" => loop} -> Map.get(loop, "rounds") || @default_rounds
      _other -> nil
    end
  end

  def rounds(_stage, nil), do: nil

  # first_loop/1 and last_loop/1 are the index of the stage's first and last loop, nil
  # for none.
  @doc false
  @spec first_loop(map) :: non_neg_integer | nil
  def first_loop(stage), do: Enum.find_index(sequence(stage), &match?(%{"loop" => _}, &1))

  @doc false
  @spec last_loop(map) :: non_neg_integer | nil
  def last_loop(stage) do
    case first_loop(Map.put(stage, "sequence", Enum.reverse(sequence(stage)))) do
      nil -> nil
      from_end -> length(sequence(stage)) - 1 - from_end
    end
  end

  # workflows/1 is the stage's workflow names, in order, each once.
  @doc false
  @spec workflows(map) :: [String.t()]
  def workflows(stage) do
    stage
    |> sequence()
    |> Enum.flat_map(fn
      %{"loop" => %{"body" => body}} -> body
      entry -> [entry]
    end)
    |> Enum.map(& &1["workflow"])
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  # people?/1 is whether the stage has no workflow, so people make its outputs (§ 4).
  @doc false
  @spec people?(map) :: boolean
  def people?(stage), do: workflows(stage) == []

  # at_end?/2 is whether `position` is past the sequence's last entry.
  @doc false
  @spec at_end?(map, position) :: boolean
  def at_end?(stage, %{entry: entry}), do: entry >= length(sequence(stage))

  defp in_loop?(%{loop_entry: loop_entry}), do: is_integer(loop_entry)

  defp missing_inputs(facts), do: Map.get(facts, :missing_inputs, [])
  defp undeclared(facts), do: Map.get(facts, :undeclared, [])

  ## Limits (addition 10)

  defp declared(nil, _key), do: nil
  defp declared(declaration, key), do: Map.get(declaration, key)

  # seconds/1 is a duration of the process document (`1h30m`, `15m`, `90s`) in seconds;
  # nil for none, and for one that is not a duration.
  @doc false
  @spec seconds(term) :: pos_integer | nil
  def seconds(value) when is_binary(value) do
    case Regex.run(~r/\A(?:(\d{1,3})h)?(?:(\d{1,4})m)?(?:(\d{1,5})s)?\z/, value) do
      [_all | parts] when value != "" ->
        [hours, minutes, secs] = Enum.map(parts ++ List.duplicate("", 3 - length(parts)), &int/1)

        case hours * 3600 + minutes * 60 + secs do
          0 -> nil
          total -> total
        end

      _other ->
        nil
    end
  end

  def seconds(value) when is_integer(value) and value > 0, do: value
  def seconds(_value), do: nil

  defp int(""), do: 0
  defp int(digits), do: String.to_integer(digits)

  # The lower of two time limits; either may be nil, for none.
  defp lower_time(nil, other), do: other
  defp lower_time(one, nil), do: one
  defp lower_time(one, other), do: min(one, other)

  # The lower of two access levels: read when either is read.
  defp lower_access(entry, declared) do
    cond do
      read?(entry) or read?(declared) -> :read
      declared in [:write, "write"] -> :write
      true -> nil
    end
  end

  defp read?(level), do: level in [:read, "read"]
end
