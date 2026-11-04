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
  #     take in; for an ended one, its state (`:closed` or `:undone`);
  #   * `stage`: nil for a live work item; for an ended one, the stage its close
  #     recorded (`:explore`, `:confirm` or `:shape`), `:explore` for an undo, and for an
  #     end that recorded none, the stage its current take in was at;
  #   * `ended_reason`: for a work item the instance closed, the reason its `:closed` event
  #     gives (`"adapter_removed"`, `"last_stage_done"` or `"ticket_closed"`); nil
  #     otherwise;
  #   * `ended_by_id` and `ended_at`: for an ended work item, who ended it, nil where the
  #     instance closed it, and when, by its latest event of the kind of its state; nil for
  #     a live one;
  #   * `take_in`: the current take in, and `previous`, how the work item had ended before
  #     it (`:closed` or `:undone`), nil for a first take in;
  #   * `run`: the latest run of the current take in, nil for none, and `earlier_runs` the
  #     runs before it, oldest first, each a run map (below);
  #   * `earlier_take_ins`: the take ins before the current one, oldest first, each with who
  #     took it in and when (`taken_in_by_id`, `taken_in_at`), how it ended (`ended`, the
  #     kind of its end's event), who ended it and when (`ended_by_id`, nil where no
  #     person did, `ended_at`), the reason the instance gave for a close
  #     (`ended_reason`), and its runs, each a run map;
  #   * `answers_by_ids`: who answered within the current take in, in the order they first
  #     answered, nil for an account whose row is gone;
  #   * `confirmed_by_id` and `confirmed_at`, the current take in's confirmation, nil for
  #     none;
  #   * `comments`: the review comments on the current take in's proposals, oldest first,
  #     each `%{text: text, by_id: id, at: at, attempt: attempt, version: version,
  #     done_version: version or nil, done_at: at or nil}`: `attempt` the latest run when
  #     it was written, `version` the proposal's version it is on, and once a run replied
  #     and closed it, `done_version`, the proposal's version that run stood at, and
  #     `done_at`, the time of its reply (`Apiary.Explore.ReviewComments`).
  #   * `proposal`: the newest proposal of the current take in, `%{version:, message:,
  #     version_id:, images:}` (`Apiary.WorkItems.Explore.proposal/2`), the version its
  #     latest run stands at, or the one its confirmation keeps; nil for none. A result
  #     kept before runs pushed their proposal as an artifact has `message` alone;
  #   * `questions`: every question of the work item's newest questions, in their order,
  #     each `%{id:, number:, text:, context:, options:, state:, asked_run:, answer:,
  #     history:, follows:}`: `number` its place in the document, from 1, `state`
  #     `:open`, `:answered` or `:withdrawn`, `answer` nil or `%{option:, note:, by_id:,
  #     by:, at:}` (`by_id` by the move that wrote it, nil where none matches, `by` the
  #     name the document keeps), `history` its earlier answers in the same form, and
  #     `follows` the numbers of the questions it follows; and `questions_version`, the
  #     number of that version, nil for none;
  #   * `review_comments`: the review comments on the current take in's proposals, oldest
  #     first, each `%{id:, text:, by_id:, at:, version:, state:, reopened:, replies:}`:
  #     `state` `:open` or `:closed`, `reopened` true for an open one a run replied to,
  #     and each reply `%{run:, by_id:, text:, at:, outcome:, question:,
  #     question_number:, version:}`: a run's with its number, its `outcome`
  #     (`:changed`, `:answered`, `:declined` or `:asked`, with the question's id and
  #     number) and the proposal's version that run stood at; a member's with `by_id`
  #     and the proposal's version the take in's latest run stood at when it was written.
  #
  # A run map: `id` and `number` (its registered run's public id and number, both nil for
  # a run with none: one waiting, or one that ended before its handover), `workspace_id`, the workspace it was queued in, where it stays
  # when its work item moves, `attempt`, `of`, `state`
  # (`Apiary.WorkItems.Explore.run_state/1`), `place` (`Apiary.WorkItems.Explore.step/4`),
  # `started_at`, `ended_at`, `duration_ms`, how long it took once it ended, `outcome`,
  # `end_cause`, the end cause of its run of the queue (nil while it has not ended),
  # `end_detail`, the code that end kept, nil for none (a gateway's refusal code, such as
  # `"model_key_missing"`, for `run_refused`), `adapter_failure`, the call to an adapter
  # the run stopped at, nil for none (`%{adapter: title, cause: cause, call: path, code:
  # code}`, the adapter's title by `Apiary.Adapters.title/1`), `harness_failure`, why its
  # harness walk failed, nil for none (`%{code: code, source: source or nil, rule: rule or
  # nil, adapter: title, the name the walk kept, or nil, organisation: name, workspace:
  # name}`, `Apiary.Harnesses.RunHarness`, the names of the run's organisation and
  # workspace), `workflow_gap`, for a run that ended `workflow_not_in_harness`, the
  # workflow its harness had no skill for and where that harness came from
  # (`Apiary.Harnesses.WorkflowGap`), nil for any other run, `read_needs`, for a run qory
  # closed with a `read_needs_*` reason, the reason and whether the run's pool is the
  # instance's (`Apiary.Runs.ReadNeeds`), nil for any other run,
  # and by what it gave: `proposal`, `%{message: text}`, the Markdown of the newest version
  # of the work item's proposal a run of the take in up to it pushed, nil for none, with
  # `version`, that version's number (`Apiary.WorkItems.Explore.proposal_version/3`), nil
  # for none; `questions`, each `%{public_id: position, text: question, options:
  # [%{title:, explanation:}], answer: answer or nil, custom: true, false or nil}`, for a
  # run that asked: where its questions wait, the open questions of the work item's
  # newest questions, which the form answers by position, else the questions it asked and
  # those answered at it (`Apiary.Explore.Questions`, `Apiary.Explore.Given`); and
  # `answered_by_id` and `answered_at` once a member answered at it. A confirmed run's
  # proposal is the version its confirmation keeps. A run that ended before Explore's
  # runs pushed artifacts shows the proposal its result kept, and no questions. `wrote` is
  # the version of the proposal the run pushed, nil for none, with `wrote_proposal`, that
  # version as the top-level `proposal` gives one, without `version`, and `asked` how many questions of the newest questions
  # it asked.
  #
  # ## `thread/2`
  #
  # What happened to the work item at Explore, in the order it happened, for the Thread:
  # each entry a map with its `kind` and `at`, and by kind:
  #
  #   * the events of the work item: `:taken_in` (`actor_id`, `take_in`, `again`,
  #     `owner_id`, who owned the work item in that take in, and `first_instruction` for
  #     the current take in, nil for an earlier one),
  #     `:answered` (`actor_id`, `run`, `questions` with their answers, and `comment`, the
  #     text of a review comment or a reply, nil for answers; a send of the review comments
  #     has no entry), `:explore_again`
  #     (`actor_id`, `run`, the run it started), `:confirmed` (`actor_id`, `changed`),
  #     `:closed` (`actor_id`, nil for the instance, `stage`, nil where none was recorded,
  #     and the instance's `reason`, nil for a person),
  #     `:undone` (`actor_id`);
  #   * the runs: `:started` (`run`, `start`: nil for a take in's first run, `:answers` for
  #     a run after answers, `:again` for any other), at its start, for a run handed over;
  #     then at its end `:asked` (`run`, `questions`, `duration_ms`), `:proposed` (`run`,
  #     `duration_ms`, `owner_id`), `:no_result` (`run`, `outcome`, and the end cause and
  #     its code, `end_cause` and `end_detail`, as a run map has them), `:lost` or
  #     `:cancelled` (`run`).
  #
  # `run` is `%{id, workspace_id, attempt, of}`. A run that has not ended, or reads as
  # running, has no entry at its end.
  #
  # Who owned the work item in a take in is its owner for the current take in; for an
  # earlier one, the owner the next take in found (its `:taken_in` event's `before`). A
  # current take in that was a take in again and was undone gave its owner back to the
  # one before, and no record keeps the owner it had: nil.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  alias Apiary.Harnesses.{RunHarness, WorkflowGap}
  alias Apiary.Nodes.Node
  alias Apiary.Runs.ReadNeeds
  alias Apiary.Explore.{Given, Questions, ReviewComments}
  alias Apiary.WorkItems.{Explore, Proposal, State, WorkItem}

  @ends [:closed, :undone]

  # explore/2 is where Explore stands for `work_item` at `now` (the moduledoc).
  @doc false
  @spec explore(WorkItem.t(), DateTime.t()) :: map
  def explore(%WorkItem{id: id, take_in: take_in} = work_item, %DateTime{} = now) do
    steps = Explore.steps(id, :all, now)
    by_take_in = Enum.group_by(steps, & &1.take_in)
    current = Map.get(by_take_in, take_in, [])
    confirmation = Explore.confirmation(id, take_in)
    events = Explore.events(id)
    live? = State.live?(work_item.state)
    status = Explore.status(current, not is_nil(confirmation))

    ctx =
      context(work_item, steps, events, (live? and status == :questions) && List.last(current))

    taken = take_ins(events)
    runs = Enum.map(current, &run_view(&1, ctx, confirmation, work_item))

    %{
      status: if(live?, do: status, else: work_item.state),
      stage: unless(live?, do: ended_stage(work_item, events, current, confirmation)),
      ended_reason: unless(live?, do: ended_reason(work_item, events)),
      ended_by_id: unless(live?, do: ended_by_id(work_item, events)),
      ended_at: unless(live?, do: ended_at(work_item, events)),
      take_in: take_in,
      previous: previous(taken, take_in),
      run: List.last(runs),
      earlier_runs: Enum.drop(runs, -1),
      earlier_take_ins: earlier_take_ins(work_item, taken, by_take_in, ctx, take_in),
      answers_by_ids:
        for(%{kind: :answer, take_in: ^take_in, by_id: by_id} <- ctx.given, do: by_id)
        |> Enum.uniq(),
      confirmed_by_id: confirmation && confirmation.confirmed_by_id,
      confirmed_at: confirmation && confirmation.confirmed_at,
      comments: comments(ctx, take_in),
      proposal: newest_proposal(work_item, List.last(runs)),
      questions: questions_view(ctx),
      questions_version: ctx.questions_version,
      review_comments: review_comments(ctx, take_in)
    }
  end

  # The newest proposal of the current take in: the one its latest run stands at, or the
  # one its confirmation keeps; nil for none.
  defp newest_proposal(_work_item, nil), do: nil

  defp newest_proposal(%WorkItem{id: id}, %{proposal: %{message: message}, version: version})
       when is_binary(message) do
    case version && shown_proposal(id, version) do
      %{} = proposal -> Map.put(proposal, :version, version)
      _kept -> %{version: version, message: message}
    end
  end

  defp newest_proposal(%WorkItem{id: id, take_in: take_in}, %{attempt: attempt}) do
    with version when is_integer(version) <- Explore.proposal_version(id, take_in, attempt),
         %{} = proposal <- shown_proposal(id, version) do
      Map.put(proposal, :version, version)
    else
      _none -> nil
    end
  end

  # Version `version` of the work item `id`'s proposal as the page shows it (`message`,
  # its Markdown; `version_id`; `images`, its image files' filenames), nil for none.
  defp shown_proposal(id, version) do
    case Explore.proposal(id, version) do
      %{text: text, version_id: version_id, images: images} ->
        %{message: text, version_id: version_id, images: images}

      nil ->
        nil
    end
  end

  # Every question of the newest questions, in their order (the moduledoc).
  defp questions_view(ctx) do
    entries = (ctx.questions || %{})["questions"] || []
    numbers = for {%{"id" => id}, n} <- Enum.with_index(entries, 1), into: %{}, do: {id, n}
    given = for %{kind: :answer} = entry <- ctx.given, do: entry

    for {%{"id" => id} = question, number} <- Enum.with_index(entries, 1) do
      %{options: options} = Proposal.question(question)

      %{
        id: id,
        number: number,
        text: question["question"],
        context: question["context"],
        options: options,
        state: question_state(question["state"]),
        asked_run: get_in(question, ["asked", "run"]),
        answer: given_answer(question["answer"], id, given),
        history: Enum.map(question["history"] || [], &given_answer(&1, id, given)),
        follows: for(other <- question["follows"] || [], n = numbers[other], do: n)
      }
    end
  end

  defp question_state("answered"), do: :answered
  defp question_state("withdrawn"), do: :withdrawn
  defp question_state(_open), do: :open

  # An answer of the questions document, with who gave it by the move that wrote it
  # (`Apiary.Explore.Given`): `by_id` nil where no move matches, with `by`, the name the
  # document keeps.
  defp given_answer(%{"at" => at} = answer, id, given) do
    move = Enum.find(given, &(&1.id == id and second(&1.at) == at))

    %{
      option: answer["option"],
      note: answer["note"],
      by_id: move && move.by_id,
      by: get_in(answer, ["by", "name"]),
      at: (move && move.at) || time(at)
    }
  end

  defp given_answer(_none, _id, _given), do: nil

  defp second(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp time(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} -> at
      _invalid -> nil
    end
  end

  defp time(_at), do: nil

  # The review comments on the proposals of take in `take_in`, oldest first, each with
  # its replies (the moduledoc).
  defp review_comments(ctx, take_in) do
    written = for %{kind: :comment, id: id} = given <- ctx.given, into: %{}, do: {id, given}
    replies = for %{kind: :reply} = given <- ctx.given, do: given
    entries = (ctx.questions || %{})["questions"] || []
    numbers = for {%{"id" => id}, n} <- Enum.with_index(entries, 1), into: %{}, do: {id, n}

    for %{"on" => %{"artifact" => "proposal", "version" => version}} = comment <-
          ReviewComments.entries(ctx.review_comments),
        %{take_in: ^take_in} = given <- [Map.get(written, comment["id"])] do
      shown = Enum.map(comment["replies"] || [], &reply_view(&1, comment["id"], replies, ctx))
      open? = comment["state"] != "closed"

      %{
        id: comment["id"],
        text: comment["text"],
        by_id: given.by_id,
        at: given.at,
        version: version,
        state: if(open?, do: :open, else: :closed),
        reopened: open? and Enum.any?(shown, &is_integer(&1.run)),
        replies: Enum.map(shown, &Map.put(&1, :question_number, numbers[&1.question]))
      }
    end
  end

  # A reply to a review comment: a run's, with its outcome and the version of the
  # proposal that run stood at; a member's, with who wrote it and the version of the
  # proposal the take in's latest run stood at then.
  defp reply_view(%{"by" => %{"run" => number}} = reply, _id, _replies, ctx) do
    %{
      run: number,
      by_id: nil,
      text: reply["text"],
      at: time(reply["at"]),
      outcome: outcome(reply["outcome"]),
      question: reply["question"],
      version: (step = Map.get(ctx.by_number, number)) && version(step)
    }
  end

  defp reply_view(reply, id, replies, ctx) do
    move = Enum.find(replies, &(&1.id == id and second(&1.at) == reply["at"]))
    step = move && Enum.find(ctx.current, &(&1.attempt == move.attempt))

    %{
      run: nil,
      by_id: move && move.by_id,
      text: reply["text"],
      at: (move && move.at) || time(reply["at"]),
      outcome: nil,
      question: nil,
      version: step && version(step)
    }
  end

  defp outcome("changed"), do: :changed
  defp outcome("answered"), do: :answered
  defp outcome("declined"), do: :declined
  defp outcome("asked"), do: :asked
  defp outcome(_none), do: nil

  # What the pages read besides the runs: what members gave (`Apiary.Explore.Given`), the
  # newest questions and review comments, the runs by their registered run's number, and
  # `waiting`, the latest run of the current take in where its questions wait, else nil.
  defp context(work_item, steps, events, waiting) do
    questions = Questions.newest(work_item)

    %{
      given: Given.from_events(work_item, events),
      questions: document(questions),
      questions_version: number(questions),
      review_comments: document(ReviewComments.newest(work_item)),
      by_number: for(%{run: %{number: n}} = step <- steps, into: %{}, do: {n, step}),
      current: Enum.filter(steps, &(&1.take_in == work_item.take_in)),
      waiting: waiting || nil
    }
  end

  defp document({_version, document}), do: document
  defp document(nil), do: nil

  defp number({%{number: number}, _document}), do: number
  defp number(_none), do: nil

  # The review comments on the proposals of take in `take_in`, oldest first: each with who
  # wrote it and when, by its move (`Apiary.Explore.Given`), the run whose proposal it is
  # on, and once a run replied and closed it, the version of the proposal that run stood
  # at and when it replied.
  defp comments(ctx, take_in) do
    written =
      for %{kind: :comment, id: id} = given <- ctx.given, into: %{}, do: {id, given}

    for %{"on" => %{"artifact" => "proposal", "version" => version}} = comment <-
          ReviewComments.entries(ctx.review_comments),
        %{take_in: ^take_in} = given <- [Map.get(written, comment["id"])] do
      {done_version, done_at} = done(comment, ctx)

      %{
        text: comment["text"],
        by_id: given.by_id,
        at: given.at,
        attempt: given.attempt,
        version: version,
        done_version: done_version,
        done_at: done_at
      }
    end
  end

  # A closed review comment: the version of the proposal the run that closed it stood at,
  # and the time of its reply; `{nil, nil}` for an open one.
  defp done(%{"state" => "closed"} = comment, ctx) do
    replies = Enum.filter(comment["replies"] || [], &match?(%{"by" => %{"run" => _}}, &1))

    with %{"by" => %{"run" => number}, "at" => at} <- List.last(replies),
         %{} = step <- Map.get(ctx.by_number, number),
         {:ok, at, _offset} <- DateTime.from_iso8601(at) do
      {version(step), at}
    else
      _none -> {nil, nil}
    end
  end

  defp done(_comment, _ctx), do: {nil, nil}

  defp adapter_failure(%{adapter_failure: nil}), do: nil

  defp adapter_failure(%{failed_adapter: adapter} = dispatch_run) do
    %{
      adapter: Apiary.Adapters.title(adapter),
      cause: dispatch_run.adapter_failure,
      call: dispatch_run.adapter_failure_call,
      code: dispatch_run.adapter_failure_code
    }
  end

  defp harness_failure(
         %{end_cause: :harness_unresolved, harness_walk: %RunHarness{} = walk} = dispatch_run
       ) do
    %{
      code: walk.failure,
      source: walk.failed_source,
      rule: walk.failure_rule,
      adapter: walk_adapter(walk),
      organisation: name(dispatch_run.organisation),
      workspace: name(dispatch_run.workspace)
    }
  end

  defp harness_failure(_dispatch_run), do: nil

  defp name(%{name: name}), do: name
  defp name(_not_loaded), do: nil

  # The adapter a failed walk names: its title, read from its node, else the name the walk
  # kept, for a walk that failed before walks kept the adapter's id and once the adapter's
  # row is gone.
  defp walk_adapter(%RunHarness{failed_adapter: %Node{} = adapter}),
    do: Apiary.Adapters.title(adapter)

  defp walk_adapter(%RunHarness{failure_adapter: name}), do: name

  # A run whose harness had no skill for its workflow: the workflow and where the harness
  # came from (`Apiary.Harnesses.WorkflowGap`), nil for any other run.
  defp workflow_gap(%{run: %{} = run, dispatch_run: dispatch_run}, work_item),
    do:
      WorkflowGap.of_run(%{
        reason: run.reason,
        dispatch_run: %{dispatch_run | work_item: work_item}
      })

  defp workflow_gap(_step, _work_item), do: nil

  defp run_view(step, ctx, confirmation, work_item) do
    rows = answers_of(ctx, step)
    wrote = wrote(step)

    ended_at = Explore.ended_at(step)

    view = %{
      id: step.run && step.run.public_id,
      number: step.run && step.run.number,
      workspace_id: step.dispatch_run.workspace_id,
      attempt: step.attempt,
      of: step.of,
      state: Explore.run_state(step),
      place: step.place,
      started_at: Explore.started_at(step),
      ended_at: ended_at,
      duration_ms: ended_at && duration_ms(step, ended_at),
      outcome: step.outcome,
      end_cause: step.dispatch_run.end_cause,
      end_detail: step.dispatch_run.end_detail,
      adapter_failure: adapter_failure(step.dispatch_run),
      harness_failure: harness_failure(step.dispatch_run),
      workflow_gap: workflow_gap(step, work_item),
      read_needs: ReadNeeds.of_run(step.run),
      proposal: nil,
      version: nil,
      questions: [],
      answered_by_id: nil,
      answered_at: nil,
      wrote: wrote,
      wrote_proposal: wrote && wrote_proposal(step, wrote),
      asked: asked(step, ctx)
    }

    view =
      case {step.outcome, confirmed_result(step, confirmation)} do
        {_outcome, %{} = result} ->
          version = result["proposal_version"] || version(step)

          %{
            view
            | outcome: :proposal,
              place: :proposal,
              proposal: proposal(step, version, result),
              version: version
          }

        {:proposal, nil} ->
          version = version(step)
          %{view | proposal: proposal(step, version, step.dispatch_run.result), version: version}

        {:questions, nil} ->
          %{view | questions: questions(step, ctx, rows)}

        _other ->
          view
      end

    case rows do
      [first | _rest] ->
        %{view | answered_by_id: first.by_id, answered_at: first.at}

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

  defp version(step),
    do: Explore.proposal_version(step.dispatch_run.work_item_id, step.take_in, step.attempt)

  # The version of the proposal the run `step` pushed: its version, where the run before
  # it stood at another; nil for none.
  defp wrote(%{run: nil}), do: nil

  defp wrote(%{attempt: attempt} = step) do
    before =
      attempt > 1 &&
        Explore.proposal_version(step.dispatch_run.work_item_id, step.take_in, attempt - 1)

    case version(step) do
      version when is_integer(version) and version != before -> version
      _same -> nil
    end
  end

  defp wrote_proposal(step, version), do: shown_proposal(step.dispatch_run.work_item_id, version)

  # How many questions of the newest questions the run `step` asked.
  defp asked(%{run: %{number: number}}, ctx) when is_integer(number),
    do:
      Enum.count(
        (ctx.questions || %{})["questions"] || [],
        &(get_in(&1, ["asked", "run"]) == number)
      )

  defp asked(_step, _ctx), do: 0

  # The proposal of a run, at `version`: the Markdown of that version of the work item's
  # proposal, else the `message` a result kept before Explore's runs pushed their
  # proposal as an artifact; nil for none.
  defp proposal(step, version, result) do
    text = Explore.proposal_text(step.dispatch_run.work_item_id, version)

    case {text, result} do
      {text, _result} when is_binary(text) -> %{message: text}
      {nil, %{"message" => message}} when is_binary(message) -> %{message: message}
      _none -> %{message: nil}
    end
  end

  # The answers given at the run `step`, in the order they were given.
  defp answers_of(ctx, step) do
    for %{kind: :answer, take_in: take_in, attempt: attempt} = given <- ctx.given,
        take_in == step.take_in and attempt == step.attempt,
        do: given
  end

  # The questions of a run that asked: where its questions wait, the open questions of the
  # newest questions, in its order, which the form answers by position; otherwise the
  # questions it asked (`asked.run`) and those answered at it, with their answers.
  defp questions(step, ctx, rows) do
    answers = Map.new(rows, &{&1.id, &1})

    entries =
      if ctx.waiting && ctx.waiting.dispatch_run.id == step.dispatch_run.id do
        Questions.open(ctx.questions)
      else
        number = step.run && step.run.number

        for %{"id" => id} = question <- (ctx.questions || %{})["questions"] || [],
            Map.has_key?(answers, id) or
              (is_integer(number) and get_in(question, ["asked", "run"]) == number),
            do: question
      end

    entries
    |> Enum.with_index(1)
    |> Enum.map(fn {question, position} ->
      question_view(question, position, Map.get(answers, question["id"]))
    end)
  end

  defp question_view(question, position, given) do
    %{options: options} = Proposal.question(question)

    %{
      public_id: Integer.to_string(position),
      text: question["question"],
      options: options,
      answer: given && given.text,
      custom: given && given.custom
    }
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

  # The reason the instance gave for closing an ended work item: of its latest `:closed`
  # event, for a closed one.
  defp ended_reason(%WorkItem{state: :closed}, events) do
    case Enum.filter(events, &(&1.kind == :closed)) |> List.last() do
      %{data: %{"reason" => reason}} when is_binary(reason) -> reason
      _none -> nil
    end
  end

  defp ended_reason(_work_item, _events), do: nil

  # Who ended an ended work item, and when: its latest event of the kind of its state;
  # nil for who where the instance closed it. An end with no event, which no move writes,
  # reads the row.
  defp ended_by_id(work_item, events) do
    case ended_event(work_item, events) do
      %{actor_id: actor_id} -> actor_id
      nil -> work_item.closed_by_id
    end
  end

  defp ended_at(work_item, events) do
    case ended_event(work_item, events) do
      %{at: at} -> at
      nil -> work_item.closed_at || work_item.updated_at
    end
  end

  defp ended_event(work_item, events),
    do: events |> Enum.filter(&(&1.kind == work_item.state)) |> List.last()

  # How the work item had ended before the take in `take_in`, from its `:taken_in` event's
  # `before`: nil for a first take in.
  defp previous(taken, take_in) do
    case List.keyfind(taken, take_in, 0) do
      {_take_in, %{data: %{"before" => %{"state" => state}}}, _end}
      when state in ["closed", "undone"] ->
        String.to_existing_atom(state)

      _first ->
        nil
    end
  end

  # The take ins before the current one: each `:taken_in` event and the end that followed
  # it, before the next take in, with its runs as the current take in's are drawn, each
  # read with that take in's confirmation.
  defp earlier_take_ins(%WorkItem{id: id} = work_item, taken, by_take_in, ctx, current) do
    taken
    |> Enum.filter(fn {take_in, _taken, _end} -> take_in < current end)
    |> Enum.map(fn {take_in, taken, ended} ->
      confirmation = Explore.confirmation(id, take_in)

      %{
        take_in: take_in,
        taken_in_by_id: taken.actor_id,
        taken_in_at: taken.at,
        ended: ended && ended.kind,
        ended_by_id: ended && ended.actor_id,
        ended_at: ended && ended.at,
        ended_reason: close_reason(ended),
        runs:
          Enum.map(
            Map.get(by_take_in, take_in, []),
            &run_view(&1, ctx, confirmation, work_item)
          )
      }
    end)
  end

  defp close_reason(%{kind: :closed, data: %{"reason" => reason}}) when is_binary(reason),
    do: reason

  defp close_reason(_end), do: nil

  # Who owned the work item in each take in, by take in (the moduledoc).
  defp owners(work_item, events) do
    taken = take_ins(events)

    earlier =
      for {take_in, %{data: %{"before" => %{"owner_id" => owner_id}}}, _end} <- taken,
          take_in > 1,
          into: %{},
          do: {take_in - 1, owner_id}

    current =
      case List.keyfind(taken, work_item.take_in, 0) do
        {_take_in, %{data: %{"before" => %{}}}, %{kind: :undone}} -> nil
        _other -> work_item.owner_id
      end

    Map.put(earlier, work_item.take_in, current)
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
    events = Explore.events(id)
    current = Enum.filter(steps, &(&1.take_in == work_item.take_in))
    confirmed? = not is_nil(Explore.confirmation(id, work_item.take_in))

    waiting =
      (State.live?(work_item.state) and Explore.status(current, confirmed?) == :questions) &&
        List.last(current)

    ctx = context(work_item, steps, events, waiting)
    owners = owners(work_item, events)

    (event_entries(work_item, events, by_run, ctx, owners) ++
       Enum.flat_map(steps, &run_entries(&1, by_run, ctx, owners)))
    |> Enum.with_index()
    |> Enum.sort_by(fn {entry, index} -> {DateTime.to_unix(entry.at, :microsecond), index} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp event_entries(work_item, events, by_run, ctx, owners) do
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
             owner_id: Map.get(owners, take_in),
             first_instruction: if(take_in == work_item.take_in, do: work_item.first_instruction)
           }, take_in}

        kind ->
          {event_entry(kind, event, by_run, ctx), taken}
      end
    end)
    |> elem(0)
    |> Enum.reject(&is_nil/1)
  end

  defp take_in_number(%{data: %{"take_in" => n}}, _taken) when is_integer(n), do: n
  defp take_in_number(_event, taken), do: taken + 1

  # A send of the review comments queues a run and gives nothing to read: no entry.
  defp event_entry(:answered, %{data: %{"review_comments" => _ids}}, _by_run, _ctx), do: nil

  defp event_entry(:answered, event, by_run, ctx) do
    key = {event.data["take_in"], event.data["attempt"]}
    given = Enum.filter(ctx.given, &(&1.event_id == event.id))

    %{
      kind: :answered,
      at: event.at,
      actor_id: event.actor_id,
      run: run_ref(Map.get(by_run, key), key),
      questions:
        for {%{kind: :answer} = answer, position} <- Enum.with_index(given, 1) do
          %{
            public_id: Integer.to_string(position),
            text: answer.question,
            answer: answer.text,
            custom: answer.custom
          }
        end,
      comment: Enum.find_value(given, &if(&1.kind != :answer, do: &1.text))
    }
  end

  defp event_entry(:explore_again, event, by_run, _ctx) do
    key = {event.data["take_in"], event.data["attempt"]}

    %{
      kind: :explore_again,
      at: event.at,
      actor_id: event.actor_id,
      run: run_ref(Map.get(by_run, key), key)
    }
  end

  defp event_entry(:confirmed, event, _by_run, _ctx),
    do: %{
      kind: :confirmed,
      at: event.at,
      actor_id: event.actor_id,
      changed: (event.data["changed"] || []) != []
    }

  defp event_entry(:closed, event, _by_run, _ctx) do
    stage =
      case event.data["stage"] do
        stage when stage in ["explore", "confirm", "shape"] -> String.to_existing_atom(stage)
        _none -> nil
      end

    reason = if is_binary(event.data["reason"]), do: event.data["reason"]

    %{kind: :closed, at: event.at, actor_id: event.actor_id, stage: stage, reason: reason}
  end

  defp event_entry(:undone, event, _by_run, _ctx),
    do: %{kind: :undone, at: event.at, actor_id: event.actor_id}

  defp event_entry(_kind, _event, _by_run, _ctx), do: nil

  defp run_entries(step, by_run, ctx, owners) do
    run = run_ref(step, {step.take_in, step.attempt})

    started =
      case Explore.started_at(step) do
        nil -> []
        at -> [%{kind: :started, at: at, run: run, start: start(step, by_run, ctx)}]
      end

    started ++ ended(step, run, ctx, Map.get(owners, step.take_in))
  end

  defp start(%{attempt: 1}, _by_run, _ctx), do: nil

  defp start(step, by_run, ctx) do
    before = {step.take_in, step.attempt - 1}

    case Map.get(by_run, before) do
      %{outcome: :questions} = earlier ->
        if answers_of(ctx, earlier) != [], do: :answers, else: :again

      _other ->
        :again
    end
  end

  defp ended(step, run, ctx, owner_id) do
    case Explore.ended_at(step) do
      nil ->
        []

      at ->
        duration = duration_ms(step, at)

        case step.place do
          :questions ->
            questions = questions(step, ctx, answers_of(ctx, step))

            [%{kind: :asked, at: at, run: run, questions: questions, duration_ms: duration}]

          :proposal ->
            [%{kind: :proposed, at: at, run: run, duration_ms: duration, owner_id: owner_id}]

          :no_result ->
            [
              %{
                kind: :no_result,
                at: at,
                run: run,
                outcome: step.outcome,
                end_cause: step.dispatch_run.end_cause,
                end_detail: step.dispatch_run.end_detail
              }
            ]

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

  defp run_ref(%{run: run, dispatch_run: dispatch_run, attempt: attempt, of: of}, _key),
    do: %{
      id: run && run.public_id,
      number: run && run.number,
      workspace_id: dispatch_run.workspace_id,
      attempt: attempt,
      of: of
    }

  defp run_ref(nil, {_take_in, attempt}),
    do: %{id: nil, number: nil, workspace_id: nil, attempt: attempt, of: nil}
end
