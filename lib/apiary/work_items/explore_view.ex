defmodule Apiary.WorkItems.ExploreView do
  # ExploreView reads Explore for one work item as the work item pages draw it
  # (`ApiaryWeb.WorkItemComponents`): plain maps, people by the ids of their accounts,
  # runs by their public ids (`rn_…`) and questions by their position. `Apiary.WorkItems`
  # asks it once it has checked who reads. It writes nothing.
  #
  # ## `explore/2`
  #
  # Where Explore stands, at `now`:
  #
  #   * `status`: for a live work item, `Apiary.WorkItems.Explore.status/2` of its current
  #     take in; for an ended one, its state (`:declined`, `:closed` or `:undone`);
  #   * `stage`: nil for a live work item; for an ended one, the stage its decline or close
  #     recorded (`:explore`, `:confirm` or `:shape`), `:explore` for an undo, and for an
  #     end that recorded none, the stage its current take in was at;
  #   * `take_in`: the current take in;
  #   * `run`: the latest run of the current take in, nil for none, and `earlier_runs` the
  #     runs before it, oldest first, each a run map (below);
  #   * `earlier_take_ins`: the take ins before the current one, oldest first, each with who
  #     took it in and when (`taken_in_by_id`, `taken_in_at`), how it ended (`ended`, the
  #     kind of its end's event), who ended it and when (`ended_by_id`, nil where no
  #     person did, `ended_at`), and its runs (`%{id, attempt, of, state}`);
  #   * `answers_by_ids`: who answered within the current take in, in the order they first
  #     answered, nil for an account whose row is gone;
  #   * `confirmed_by_id` and `confirmed_at`, the current take in's confirmation, nil for
  #     none, and `changes`, the fields it changed, each `%{value: value, by_id: id}`.
  #
  # A run map: `id` (its registered run's public id, nil before its handover or for a run
  # never handed over), `attempt`, `of`, `state` (`Apiary.WorkItems.Explore.run_state/1`),
  # `place` (`Apiary.WorkItems.Explore.step/4`), `started_at`, `ended_at`, `outcome`, and
  # by what it gave: `proposal` (`Apiary.WorkItems.Proposal.from_result/1`), nil for none;
  # `understanding` and `questions`, each `%{public_id: position, text: question, answer:
  # answer or nil}`, for a run that asked; and `answered_by_id` and `answered_at` once its
  # questions were answered. A confirmed run's proposal is read from its confirmation,
  # which keeps the result, so it outlives the run's events.
  #
  # ## `thread/2`
  #
  # What happened to the work item at Explore, in the order it happened, for the Thread:
  # each entry a map with its `kind` and `at`, and by kind:
  #
  #   * the events of the work item: `:taken_in` (`actor_id`, `take_in`, `again`, and
  #     `first_instruction` for the current take in, nil for an earlier one),
  #     `:answered` (`actor_id`, `run`, `questions` with their answers), `:explore_again`
  #     (`actor_id`, `run`, the run it started), `:confirmed` (`actor_id`, `changed`),
  #     `:declined` and `:closed` (`actor_id`, nil for the instance, `stage`, nil where
  #     none was recorded), `:undone` (`actor_id`);
  #   * the runs: `:started` (`run`, `start`: nil for a take in's first run, `:answers` for
  #     a run after answers, `:again` for any other), at its start, for a run handed over;
  #     then at its end `:asked` (`run`, `questions`, `duration_ms`), `:proposed` (`run`,
  #     `duration_ms`), `:no_result` (`run`, `outcome`), `:lost` or `:cancelled` (`run`).
  #
  # `run` is `%{id, attempt, of}`. A run that has not ended, or reads as running, has no
  # entry at its end.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  alias Apiary.WorkItems.{Explore, Proposal, State, WorkItem}

  @ends [:declined, :closed, :undone]

  # explore/2 is where Explore stands for `work_item` at `now` (the moduledoc).
  @doc false
  @spec explore(WorkItem.t(), DateTime.t()) :: map
  def explore(%WorkItem{id: id, take_in: take_in} = work_item, %DateTime{} = now) do
    steps = Explore.steps(id, :all, now)
    by_take_in = Enum.group_by(steps, & &1.take_in)
    current = Map.get(by_take_in, take_in, [])
    answers = Enum.group_by(Explore.answers(id), &{&1.take_in, &1.attempt})
    confirmation = Explore.confirmation(id, take_in)
    events = Explore.events(id)
    live? = State.live?(work_item.state)
    runs = Enum.map(current, &run_view(&1, answers, confirmation))

    %{
      status:
        if(live?, do: Explore.status(current, not is_nil(confirmation)), else: work_item.state),
      stage: unless(live?, do: ended_stage(work_item, events, current, confirmation)),
      take_in: take_in,
      run: List.last(runs),
      earlier_runs: Enum.drop(runs, -1),
      earlier_take_ins: earlier_take_ins(events, by_take_in, take_in),
      answers_by_ids:
        answers
        |> Enum.filter(fn {{answered_in, _attempt}, _rows} -> answered_in == take_in end)
        |> Enum.sort()
        |> Enum.flat_map(fn {_key, rows} -> Enum.map(rows, & &1.answered_by_id) end)
        |> Enum.uniq(),
      confirmed_by_id: confirmation && confirmation.confirmed_by_id,
      confirmed_at: confirmation && confirmation.confirmed_at,
      changes: changes(confirmation)
    }
  end

  defp run_view(step, answers, confirmation) do
    rows = Map.get(answers, {step.take_in, step.attempt}, [])

    view = %{
      id: step.run && step.run.public_id,
      attempt: step.attempt,
      of: step.of,
      state: Explore.run_state(step),
      place: step.place,
      started_at: Explore.started_at(step),
      ended_at: Explore.ended_at(step),
      outcome: step.outcome,
      proposal: nil,
      understanding: nil,
      questions: [],
      answered_by_id: nil,
      answered_at: nil
    }

    view =
      case {step.outcome, confirmed_result(step, confirmation)} do
        {_outcome, %{} = result} ->
          %{view | outcome: :proposal, place: :proposal, proposal: Proposal.from_result(result)}

        {:proposal, nil} ->
          %{view | proposal: Proposal.from_result(step.result)}

        {:questions, nil} ->
          %{
            view
            | understanding: step.result["understanding"],
              questions: questions(Proposal.questions(step.result), rows)
          }

        _other ->
          view
      end

    case rows do
      [first | _rest] ->
        %{view | answered_by_id: first.answered_by_id, answered_at: first.answered_at}

      [] ->
        view
    end
  end

  defp confirmed_result(
         %{take_in: take_in, attempt: attempt},
         %{take_in: take_in, attempt: attempt} = confirmation
       ),
       do: confirmation.result

  defp confirmed_result(_step, _confirmation), do: nil

  defp questions(questions, rows) do
    answers = Map.new(rows, &{&1.position, &1.answer})

    questions
    |> Enum.with_index(1)
    |> Enum.map(fn {text, position} ->
      %{public_id: Integer.to_string(position), text: text, answer: Map.get(answers, position)}
    end)
  end

  defp changes(nil), do: %{}

  defp changes(confirmation) do
    confirmation.changes
    |> Proposal.decode()
    |> Map.new(fn {field, value} ->
      {field, %{value: value, by_id: confirmation.confirmed_by_id}}
    end)
  end

  # The stage the end of an ended work item recorded: of its latest event of the kind of
  # its state.
  defp ended_stage(work_item, events, current, confirmation) do
    case Enum.filter(events, &(&1.kind == work_item.state)) |> List.last() do
      %{kind: :undone} ->
        :explore

      %{data: %{"stage" => stage}} when stage in ["explore", "confirm", "shape"] ->
        String.to_existing_atom(stage)

      _none ->
        Explore.stage(Explore.status(current, not is_nil(confirmation)))
    end
  end

  # The take ins before the current one: each `:taken_in` event and the end that followed
  # it, before the next take in.
  defp earlier_take_ins(events, by_take_in, current) do
    events
    |> take_ins()
    |> Enum.filter(fn {take_in, _taken, _end} -> take_in < current end)
    |> Enum.map(fn {take_in, taken, ended} ->
      %{
        take_in: take_in,
        taken_in_by_id: taken.actor_id,
        taken_in_at: taken.at,
        ended: ended && ended.kind,
        ended_by_id: ended && ended.actor_id,
        ended_at: ended && ended.at,
        runs:
          for step <- Map.get(by_take_in, take_in, []) do
            %{
              id: step.run && step.run.public_id,
              attempt: step.attempt,
              of: step.of,
              state: Explore.run_state(step)
            }
          end
      }
    end)
  end

  # `{take_in, taken_in_event, end_event or nil}` for each take in, in order. A
  # `:taken_in` event names its take in in its data; one that does not counts on from the
  # one before.
  defp take_ins(events) do
    {done, open} =
      Enum.reduce(events, {[], nil}, fn event, {done, open} ->
        case {event.kind, open} do
          {:taken_in, nil} ->
            {done, {take_in_of(event, done), event, nil}}

          {:taken_in, {_n, _taken, _end} = previous} ->
            {[previous | done], {take_in_of(event, [previous | done]), event, nil}}

          {kind, {n, taken, nil}} when kind in @ends ->
            {done, {n, taken, event}}

          _other ->
            {done, open}
        end
      end)

    Enum.reverse(if open, do: [open | done], else: done)
  end

  defp take_in_of(%{data: %{"take_in" => n}}, _done) when is_integer(n), do: n
  defp take_in_of(_event, [{n, _taken, _end} | _rest]), do: n + 1
  defp take_in_of(_event, []), do: 1

  ## The Thread

  # thread/2 is what happened to `work_item` at Explore, at `now` (the moduledoc).
  @doc false
  @spec thread(WorkItem.t(), DateTime.t()) :: [map]
  def thread(%WorkItem{id: id} = work_item, %DateTime{} = now) do
    steps = Explore.steps(id, :all, now)
    by_run = Map.new(steps, &{{&1.take_in, &1.attempt}, &1})
    answers = Enum.group_by(Explore.answers(id), &{&1.take_in, &1.attempt})

    (event_entries(work_item, Explore.events(id), by_run, answers) ++
       Enum.flat_map(steps, &run_entries(&1, by_run, answers)))
    |> Enum.with_index()
    |> Enum.sort_by(fn {entry, index} -> {DateTime.to_unix(entry.at, :microsecond), index} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp event_entries(work_item, events, by_run, answers) do
    events
    |> Enum.map_reduce(0, fn event, taken ->
      case event.kind do
        :taken_in ->
          take_in = take_in_number(event, taken)

          {%{
             kind: :taken_in,
             at: event.at,
             actor_id: event.actor_id,
             take_in: take_in,
             again: take_in > 1,
             first_instruction: if(take_in == work_item.take_in, do: work_item.first_instruction)
           }, take_in}

        kind ->
          {event_entry(kind, event, by_run, answers), taken}
      end
    end)
    |> elem(0)
    |> Enum.reject(&is_nil/1)
  end

  defp take_in_number(%{data: %{"take_in" => n}}, _taken) when is_integer(n), do: n
  defp take_in_number(_event, taken), do: taken + 1

  defp event_entry(:answered, event, by_run, answers) do
    key = {event.data["take_in"], event.data["attempt"]}

    %{
      kind: :answered,
      at: event.at,
      actor_id: event.actor_id,
      run: run_ref(Map.get(by_run, key), key),
      questions:
        for row <- Map.get(answers, key, []) do
          %{public_id: Integer.to_string(row.position), text: row.question, answer: row.answer}
        end
    }
  end

  defp event_entry(:explore_again, event, by_run, _answers) do
    key = {event.data["take_in"], event.data["attempt"]}

    %{
      kind: :explore_again,
      at: event.at,
      actor_id: event.actor_id,
      run: run_ref(Map.get(by_run, key), key)
    }
  end

  defp event_entry(:confirmed, event, _by_run, _answers),
    do: %{
      kind: :confirmed,
      at: event.at,
      actor_id: event.actor_id,
      changed: (event.data["changed"] || []) != []
    }

  defp event_entry(kind, event, _by_run, _answers) when kind in [:declined, :closed] do
    stage =
      case event.data["stage"] do
        stage when stage in ["explore", "confirm", "shape"] -> String.to_existing_atom(stage)
        _none -> nil
      end

    %{kind: kind, at: event.at, actor_id: event.actor_id, stage: stage}
  end

  defp event_entry(:undone, event, _by_run, _answers),
    do: %{kind: :undone, at: event.at, actor_id: event.actor_id}

  defp event_entry(_kind, _event, _by_run, _answers), do: nil

  defp run_entries(step, by_run, answers) do
    run = run_ref(step, {step.take_in, step.attempt})

    started =
      case Explore.started_at(step) do
        nil -> []
        at -> [%{kind: :started, at: at, run: run, start: start(step, by_run, answers)}]
      end

    started ++ ended(step, run, answers)
  end

  defp start(%{attempt: 1}, _by_run, _answers), do: nil

  defp start(step, by_run, answers) do
    before = {step.take_in, step.attempt - 1}

    case Map.get(by_run, before) do
      %{outcome: :questions} -> if Map.has_key?(answers, before), do: :answers, else: :again
      _other -> :again
    end
  end

  defp ended(step, run, answers) do
    case Explore.ended_at(step) do
      nil ->
        []

      at ->
        duration = duration_ms(step, at)

        case step.place do
          :questions ->
            rows =
              Map.new(
                Map.get(answers, {step.take_in, step.attempt}, []),
                &{&1.position, &1.answer}
              )

            questions =
              step.result
              |> Proposal.questions()
              |> Enum.with_index(1)
              |> Enum.map(fn {text, position} ->
                %{
                  public_id: Integer.to_string(position),
                  text: text,
                  answer: Map.get(rows, position)
                }
              end)

            [%{kind: :asked, at: at, run: run, questions: questions, duration_ms: duration}]

          :proposal ->
            [%{kind: :proposed, at: at, run: run, duration_ms: duration}]

          :no_result ->
            [%{kind: :no_result, at: at, run: run, outcome: step.outcome}]

          place when place in [:lost, :cancelled] ->
            [%{kind: place, at: at, run: run}]
        end
    end
  end

  defp duration_ms(step, ended_at) do
    case {step.run, Explore.started_at(step)} do
      {%{duration_ms: ms}, _started} when is_integer(ms) -> ms
      {_run, %DateTime{} = started} -> max(DateTime.diff(ended_at, started, :millisecond), 0)
      _none -> nil
    end
  end

  defp run_ref(%{run: run, attempt: attempt, of: of}, _key),
    do: %{id: run && run.public_id, attempt: attempt, of: of}

  defp run_ref(nil, {_take_in, attempt}), do: %{id: nil, attempt: attempt, of: nil}
end
