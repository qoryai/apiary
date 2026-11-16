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
  #     stage escalates, `round_limit`, with a point that says so
  #     (`Apiary.Stages.Points`).
  #   * A workflow entry outside a loop with `first_attempt: true` ends the sequence when its
  #     run ends `passed`: each workflow after it is passed over (`{:skip, spec}` with the
  #     reason `first_attempt_passed`, those in a loop's body included), and the Exists
  #     checks and the gate follow. Another verdict acts as for any entry.
  #   * Outside a loop, the sequence goes on after a run with `passed` or
  #     `changes-requested`. A run with no verdict escalates, `run_stopped`, with a point
  #     that says so, on a first run and on a rerun. A test work item's run with no verdict
  #     goes on (`facts.test`): the built-in `hello` writes no verdict
  #     (`Apiary.Harnesses.Builtin`). So does a run of Explore whose take in has a
  #     proposal, or that left open questions (`facts.explore_result`), and a run of
  #     Explore that pushed `passed` or `changes-requested`, which Explore counts as no
  #     verdict (`facts.explore_verdict`): the stage's checks then read its outputs.
  #   * `escalate` escalates, `escalate`, with the verdict's points; a run that stopped
  #     escalates, `run_stopped`, with a point of its cause.
  #   * Questions wait for answers (`:waiting_answers`), in any round and at any count of
  #     runs; the answers run the same workflow again, as the loop's next round. Open
  #     questions come first: a run that asked them and escalated waits for answers, and
  #     its escalation is kept with its points (`{:questions, texts, points}`).
  #   * At the end of the sequence the Exists checks run. When every required output
  #     passes, a person gate waits (`:at_gate`) and a gate `none` records its approval
  #     (`:approve`) and passes on (`:advance`).
  #     On a failure, a stage with a loop starts another round of its last loop, with the
  #     failed checks as the gaps of that round (`{:checks_failed, round, gaps}`), and the
  #     round counts; at the limit it escalates, `round_limit`, with the point of the
  #     rounds that ran and one point for each failed check. A stage with workflows and no
  #     loop escalates, `check_failed`, with the points of the failed checks.
  #   * A stage with no workflow is worked by people (§ 4): with a required output
  #     missing, it waits at its gate, a gate `none` too, and escalates nothing. A version
  #     a person adds in the stage (`:version_added`) runs the checks again: once every
  #     required output passes, a gate `none` passes on and a person gate keeps waiting.
  #   * Request changes runs the sequence again from its first loop, round 1, or from its
  #     start when it has no loop.
  #   * An escalation accepted counts the loop as passed: the sequence goes on with its
  #     next workflow, or, after its last, to the gate without the Exists checks, where
  #     a failed check stays shown (§ 6); an escalation at the end of the sequence goes to
  #     the gate too. At a gate `none` the accept is the approval: `Apiary.Stages`
  #     records it with the member who accepted. Another round runs
  #     one more round: the same workflow for a stopped run, the loop's first workflow
  #     otherwise, the last loop for an escalation at the end, or the sequence from its
  #     start for a stage with no loop.
  #   * A queued run's time limit and access level are the lower of the entry's and the
  #     workflow's declaration (addition 10); its machine type is the entry's, else the
  #     document's.
  #   * A stage, a loop, a workflow entry, an input and an output take `when` and `unless`,
  #     each with one condition: `{input: T}`, met while `T` counts (the version of `T`
  #     that the stage reads has a file of more than 0 bytes, `facts.counted`), or
  #     `{track: ID}`, met while the work item is on the track `ID`
  #     (`facts.track`, `Apiary.Stages.track/1`). `when`
  #     holds the item back while its condition is not met, `unless` while it is met
  #     (`unmet/2` is the reason, or nil). A stage whose condition holds it back is passed
  #     over when it is entered, before it waits for anything, with no run
  #     (`{:skip_stage, spec}`, then `:advance`), unless a person moved the work item into
  #     it (`facts.forced`). An input whose condition holds it back is not waited for.
  #   * A workflow entry whose condition holds it back starts no run and is passed over
  #     (`{:skip, spec}`):
  #     outside a loop the sequence goes on with its next entry; in a loop the ring goes
  #     on, as after a run with no verdict. A loop whose every entry is passed over is
  #     passed over too: once, with no round counted, and Request changes, Run another
  #     round and a failed check never start it again. A stage does not wait for an
  #     undeclared workflow whose condition holds it back. An output whose condition holds it
  #     back is not required (`required?/2`, by `unmet/2` as for any item), so the stage goes
  #     on to its gate. A loop with a condition that holds it back is passed over whole, each
  #     of its entries with that reason.
  @moduledoc false

  alias Apiary.Stages.Points

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

  @typedoc "A point of an escalation (`Apiary.Stages.Points`)."
  @type point :: %{required(String.t()) => String.t()}

  @typedoc """
  What a run gave: its newest verdict with its points (nil verdict for none), its
  questions, with the points of an `escalate` verdict where it has one, or the point of
  why it stopped.
  """
  @type run_result ::
          {:verdict, :passed | :changes_requested | :escalate | nil, [point] | nil}
          | {:questions, String.t(), [point] | nil}
          | {:stopped, [point]}

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
  questions (`explore_result`), and whether it is a run of Explore that pushed `passed` or
  `changes-requested` (`explore_verdict`); and the input types of the stage's conditions
  that count, each whose version the stage reads has a file of more than 0 bytes
  (`counted`); the id of the track the work item is on (`track`, nil for none); and, for
  an entry of a stage that a person moved the work item into, `forced`, true: the stage's
  own condition then does not pass it over.
  """
  @type facts :: %{
          optional(:missing_inputs) => [String.t()],
          optional(:counted) => [String.t()],
          optional(:track) => String.t() | nil,
          optional(:forced) => boolean,
          optional(:undeclared) => [String.t()],
          optional(:failed_checks) => [String.t()],
          optional(:machine) => String.t() | nil,
          optional(:declarations) => %{String.t() => map | nil},
          optional(:test) => boolean,
          optional(:explore_result) => boolean,
          optional(:explore_verdict) => boolean
        }

  @typedoc """
  Why an item is held back: the condition that holds it, `{input: T}` as `kind: :input` with
  the type, or `{track: ID}` as `kind: :track` with the id, and `negated` true where the
  condition is an `unless` that is met.
  """
  @type reason :: %{kind: :input | :track, value: String.t(), negated: boolean}

  @typedoc """
  A workflow entry passed over, at the position it would run at: its workflow and the
  condition that held it back, as `input` (a type) or `track` (an id), exactly one of them,
  with `negated` for an `unless`; or, with neither, `reason` `first_attempt_passed` and
  `cause_entry`, the name of the first attempt's entry, else its workflow.
  """
  @type skip_spec :: %{
          :workflow => String.t(),
          :input => String.t() | nil,
          :track => String.t() | nil,
          :negated => boolean,
          optional(:reason) => String.t(),
          optional(:cause_entry) => String.t(),
          :entry => non_neg_integer,
          :loop_entry => non_neg_integer | nil,
          :round => pos_integer
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

  @typedoc "A stage passed over whole: the condition that held it back."
  @type stage_skip_spec :: %{
          input: String.t() | nil,
          track: String.t() | nil,
          negated: boolean
        }

  @typedoc "An action for `Apiary.Stages` to apply."
  @type action ::
          {:queue, run_spec}
          | {:skip, skip_spec}
          | {:skip_stage, stage_skip_spec}
          | {:escalate, cause, [point]}
          | {:checks_failed, pos_integer, String.t()}
          | :approve
          | :advance

  @typedoc "The stage's next state, its position and the actions to apply."
  @type outcome :: %{state: state, position: position, actions: [action]}

  # step/4 is the outcome of `event` for `stage`, a stage of a process document, at
  # `position` (nil before the stage is entered), with `facts`.
  @doc false
  @spec step(map, position | nil, event, facts) :: outcome
  def step(stage, position, event, facts \\ %{})

  def step(stage, _position, :enter, facts) do
    case if(Map.get(facts, :forced, false), do: nil, else: unmet(stage, facts)) do
      nil -> enter(stage, facts)
      reason -> skip_stage(stage, reason, facts)
    end
  end

  # A stage waiting for inputs or for a workflow tries again from where it waits. Its own
  # condition was met, or a person moved the work item in, when it was entered.
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
    case List.first(loops(stage, facts)) do
      nil -> start(stage, at(stage, 0, 1, facts), facts)
      index -> start(stage, %{entry: index, loop_entry: 0, round: 1}, facts)
    end
  end

  def step(stage, position, {:accept, _cause}, facts) do
    next = next(stage, position, facts)

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
        case List.last(loops(stage, facts)) do
          nil -> start(stage, at(stage, 0, position.round, facts), facts)
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
    position = at(stage, 0, 1, facts)
    start_checked(stage, position, facts)
  end

  # A stage whose condition holds it back is passed over whole: no run, no wait, no gate.
  # The work item goes on to the next stage, or the work item ends after the last.
  defp skip_stage(stage, reason, facts) do
    spec = Map.take(reason_spec(reason), [:input, :track, :negated])

    %{
      state: :done,
      position: at(stage, 0, 1, facts),
      actions: [{:skip_stage, spec}, :advance]
    }
  end

  # Starts at `position` once every required input exists and every workflow of the
  # stage whose condition is met is declared.
  defp start_checked(stage, position, facts) do
    cond do
      missing_inputs(facts) != [] ->
        %{state: :waiting_inputs, position: position, actions: []}

      Enum.any?(
        workflows(stage, Map.get(facts, :counted, []), Map.get(facts, :track)),
        &(&1 in undeclared(facts))
      ) ->
        %{state: :waiting_workflow, position: position, actions: []}

      true ->
        start(stage, position, facts)
    end
  end

  # Runs what is at `position`: a workflow, the workflow of a loop's body, or, past the
  # sequence's end, the checks. A workflow whose condition is not met is passed over.
  defp start(stage, position, facts) do
    case entry_at(stage, position) do
      nil ->
        finish(stage, %{position | entry: length(sequence(stage)), loop_entry: nil}, facts)

      entry ->
        if held_back(stage, position, facts),
          do: pass_over(stage, position, facts),
          else: queue(entry, position, facts)
    end
  end

  # The reason the entry at `position` is held back: its loop's condition, else its own;
  # nil for none.
  defp held_back(stage, position, facts) do
    loop_reason =
      if in_loop?(position), do: unmet(Enum.at(sequence(stage), position.entry), facts)

    loop_reason || unmet(entry_at(stage, position), facts)
  end

  # Passes over the workflow at `position`, whose condition is not met: outside a loop the
  # sequence goes on with its next entry; in a loop the ring goes on, as after a run with
  # no verdict. A loop whose every workflow is passed over is passed over whole, so a
  # ring of skips never counts its rounds.
  defp pass_over(stage, position, facts) do
    cond do
      not in_loop?(position) ->
        skipped([skip(stage, position, facts)], start(stage, next(stage, position, facts), facts))

      passed_over?(stage, position.entry, facts) ->
        skips =
          for j <- 0..(length(body(stage, position.entry)) - 1),
              do: skip(stage, %{position | loop_entry: j}, facts)

        skipped(skips, start(stage, next(stage, position, facts), facts))

      true ->
        skipped([skip(stage, position, facts)], ring(stage, position, facts))
    end
  end

  defp skip(stage, position, facts) do
    entry = entry_at(stage, position)

    {:skip,
     Map.merge(reason_spec(held_back(stage, position, facts)), %{
       workflow: entry["workflow"],
       entry: position.entry,
       loop_entry: position.loop_entry,
       round: position.round
     })}
  end

  # A reason as the fields a record keeps: `input` or `track`, and `negated`.
  defp reason_spec(%{kind: :input, value: type, negated: negated}),
    do: %{input: type, track: nil, negated: negated}

  defp reason_spec(%{kind: :track, value: id, negated: negated}),
    do: %{input: nil, track: id, negated: negated}

  defp skipped(skips, outcome), do: %{outcome | actions: skips ++ outcome.actions}

  # unmet/2 is the reason `item` is held back with `facts`, `t:reason/0`; nil for an item that
  # nothing holds back. `item` is a stage, a loop entry, a workflow entry, an input or an
  # output. Its `when` holds it back while that condition is not met, its `unless` while that
  # condition is met. A condition of another form holds nothing back.
  @doc false
  @spec unmet(map, map) :: reason | nil
  def unmet(item, facts) do
    held(item["when"], false, facts) || held(item["unless"], true, facts)
  end

  # `negated` is false for `when`, which holds the item back when its condition is not met,
  # and true for `unless`, which holds it back when it is met.
  defp held(%{"input" => type}, negated, facts) when is_binary(type),
    do: held(type in Map.get(facts, :counted, []), :input, type, negated)

  defp held(%{"track" => id}, negated, facts) when is_binary(id),
    do: held(Map.get(facts, :track) == id, :track, id, negated)

  defp held(_condition, _negated, _facts), do: nil

  defp held(met?, kind, value, negated),
    do: if(met? == negated, do: %{kind: kind, value: value, negated: negated})

  # input_required?/2 is whether the stage waits for `input`, an input of a stage: its
  # `required`, while nothing holds the input back with `facts` (`unmet/2`).
  @doc false
  @spec input_required?(map, map) :: boolean
  def input_required?(input, facts),
    do: input["required"] == true and is_nil(unmet(input, facts))

  # condition_inputs/1 is the input types that the conditions of `stage` name, on the stage,
  # its inputs, its loops, its workflow entries, those in a loop included, and its outputs,
  # each once.
  @doc false
  @spec condition_inputs(map) :: [String.t()]
  def condition_inputs(stage) do
    items =
      [stage] ++
        (Map.get(stage, "inputs") || []) ++
        Enum.filter(sequence(stage), &Map.has_key?(&1, "loop")) ++
        entries(stage) ++ (Map.get(stage, "outputs") || [])

    for item <- items,
        key <- ["when", "unless"],
        %{"input" => type} <- [item[key]],
        is_binary(type),
        uniq: true,
        do: type
  end

  # required?/2 is whether `output`, an output of a stage, is required, with the facts of
  # `unmet/2` (the input types that count, `counted`, and the work item's `track`): its
  # `required`, while nothing holds the output back, as it does a stage, a loop, an entry
  # and an input.
  @doc false
  @spec required?(map, map) :: boolean
  def required?(output, facts),
    do: output["required"] == true and is_nil(unmet(output, facts))

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

  # `passed` from a first attempt (an entry outside a loop with `first_attempt: true`) ends
  # the sequence: the rest of it is passed over, and the checks and the gate follow. In a
  # loop `passed` already leaves the loop.
  defp run_ended(stage, position, {:verdict, :passed, _points}, facts) do
    if first_attempt?(stage, position) do
      end_position = %{position | entry: length(sequence(stage)), loop_entry: nil}
      outcome = finish(stage, end_position, facts, false)
      skipped(first_attempt_skips(stage, position), outcome)
    else
      start(stage, next(stage, position, facts), facts)
    end
  end

  defp run_ended(_stage, position, {:verdict, :escalate, points}, _facts),
    do: escalate(:escalate, points || [], position)

  defp run_ended(stage, position, {:verdict, verdict, _points}, facts) do
    cond do
      in_loop?(position) ->
        ring(stage, position, facts)

      is_nil(verdict) and not no_verdict_goes_on?(facts) ->
        escalate(:run_stopped, Points.no_verdict(), position)

      true ->
        start(stage, next(stage, position, facts), facts)
    end
  end

  defp run_ended(_stage, position, {:stopped, points}, _facts),
    do: escalate(:run_stopped, points, position)

  # Open questions first: the stage waits for answers, and the escalation is kept.
  defp run_ended(_stage, position, {:questions, _questions, [_ | _] = points}, _facts),
    do: %{state: :waiting_answers, position: position, actions: [{:escalate, :escalate, points}]}

  defp run_ended(_stage, position, {:questions, _questions, _none}, _facts),
    do: %{state: :waiting_answers, position: position, actions: []}

  # Whether a run with no verdict outside a loop goes on: a test work item's run, a run of
  # Explore whose take in has a proposal, or that left open questions, as Explore's result
  # is its proposal or its questions, and a run of Explore that pushed `passed` or
  # `changes-requested`.
  defp no_verdict_goes_on?(facts) do
    Map.get(facts, :test, false) or Map.get(facts, :explore_result, false) or
      Map.get(facts, :explore_verdict, false)
  end

  # The next workflow of the loop's ring, or the next round from its first, or the round
  # limit.
  defp ring(stage, position, facts) do
    body = body(stage, position.entry)
    rounds = rounds(stage, position.entry)

    cond do
      position.loop_entry + 1 < length(body) ->
        start(stage, %{position | loop_entry: position.loop_entry + 1}, facts)

      position.round >= rounds ->
        escalate(:round_limit, Points.round_limit(position.round, rounds), position)

      true ->
        start(stage, %{position | loop_entry: 0, round: position.round + 1}, facts)
    end
  end

  ## The end of the sequence

  # `restart?` is false after a passed first attempt: a failed check then escalates
  # `check_failed` at once, since a loop that starts again would run entries the first
  # attempt passed over.
  defp finish(stage, position, facts, restart? \\ true) do
    failed = Map.get(facts, :failed_checks, [])

    cond do
      failed == [] ->
        gate(stage, position)

      # No run makes the outputs of a stage with no workflow: people add them at its gate.
      people?(stage) ->
        %{state: :at_gate, position: position, actions: []}

      true ->
        gaps = check_gaps(failed)

        case restart? && List.last(loops(stage, facts)) do
          falsy when falsy in [nil, false] ->
            escalate(:check_failed, Points.check_failed(failed), position)

          index ->
            if position.round >= rounds(stage, index) do
              rounds = rounds(stage, index)

              escalate(
                :round_limit,
                Points.round_limit(position.round, rounds) ++ Points.check_failed(failed),
                position
              )
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
      "none" -> %{state: :done, position: position, actions: [:approve, :advance]}
      _person -> %{state: :at_gate, position: position, actions: []}
    end
  end

  defp escalate(cause, points, position),
    do: %{state: :escalated, position: position, actions: [{:escalate, cause, points}]}

  # check_gaps/1 is the gaps of failed Exists checks, one line per output type.
  @doc false
  @spec check_gaps([String.t()]) :: String.t()
  def check_gaps(types), do: Enum.map_join(types, "\n", &"No #{&1} was stored in this stage.")

  ## The document

  # The position that starts the entry at `index`: a loop at its round 1 and its first
  # workflow, a workflow or the end at `round`. A loop passed over with `facts`
  # (`passed_over?/3`) keeps `round`, so the round of the loop before it reaches the
  # sequence's end, where a failed check counts it against that loop's limit.
  defp at(stage, index, round, facts) do
    case Enum.at(sequence(stage), index) do
      %{"loop" => _loop} ->
        if passed_over?(stage, index, facts),
          do: %{entry: index, loop_entry: 0, round: round},
          else: %{entry: index, loop_entry: 0, round: 1}

      _workflow_or_end ->
        %{entry: index, loop_entry: nil, round: round}
    end
  end

  defp next(stage, position, facts), do: at(stage, position.entry + 1, position.round, facts)

  # A skip for each workflow after the first attempt at `position`, those in a loop's body
  # included, with the reason `first_attempt_passed` and the name of the first attempt's
  # entry, else its workflow, as `cause_entry`. No condition holds them back.
  defp first_attempt_skips(stage, position) do
    entry = entry_at(stage, position)
    cause = entry["name"] || entry["workflow"]

    for {item, i} <- Enum.with_index(sequence(stage)),
        i > position.entry,
        {workflow, j} <- later_workflows(item),
        do:
          {:skip,
           %{
             workflow: workflow,
             input: nil,
             track: nil,
             negated: false,
             reason: "first_attempt_passed",
             cause_entry: cause,
             entry: i,
             loop_entry: j,
             round: 1
           }}
  end

  defp later_workflows(%{"loop" => %{"body" => body}}),
    do: for({%{"workflow" => name}, j} <- Enum.with_index(body), do: {name, j})

  defp later_workflows(%{"workflow" => name}), do: [{name, nil}]

  defp first_attempt?(stage, position),
    do:
      not in_loop?(position) and
        Map.get(entry_at(stage, position) || %{}, "first_attempt") == true

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

  # loops/2 is the indexes of the stage's loops that are not passed over with `facts`
  # (`passed_over?/3`), in order.
  @doc false
  @spec loops(map, map) :: [non_neg_integer]
  def loops(stage, facts) do
    for {%{"loop" => _loop}, index} <- Enum.with_index(sequence(stage)),
        not passed_over?(stage, index, facts),
        do: index
  end

  # Whether the loop at `index` is passed over: its own condition holds it back, or the
  # condition of every entry of its body does.
  defp passed_over?(stage, index, facts) do
    body = body(stage, index)

    body != [] and
      (unmet(Enum.at(sequence(stage), index), facts) != nil or Enum.all?(body, &unmet(&1, facts)))
  end

  # workflows/1 is the stage's workflow names, in order, each once; workflows/3 those of
  # its entries that nothing holds back (`unmet/2`) with the input types that count,
  # `counted`, and the work item's track.
  @doc false
  @spec workflows(map) :: [String.t()]
  def workflows(stage), do: names(entries(stage))

  @doc false
  @spec workflows(map, [String.t()], String.t() | nil) :: [String.t()]
  def workflows(stage, counted, track \\ nil) do
    facts = %{counted: counted, track: track}

    sequence(stage)
    |> Enum.flat_map(fn
      %{"loop" => %{"body" => body}} = loop -> if unmet(loop, facts), do: [], else: body
      entry -> [entry]
    end)
    |> Enum.filter(&is_nil(unmet(&1, facts)))
    |> names()
  end

  defp entries(stage) do
    Enum.flat_map(sequence(stage), fn
      %{"loop" => %{"body" => body}} -> body
      entry -> [entry]
    end)
  end

  defp names(entries) do
    entries
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
