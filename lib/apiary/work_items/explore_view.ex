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
  #   * `status`: for a live work item, `Apiary.WorkItems.Explore.status/3` of its current
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
  #   * `proposal`: the newest proposal of the current take in, `%{version:, message:,
  #     version_id:, images:}` (`Apiary.WorkItems.Explore.proposal/2`), the version its
  #     latest run stands at, or the one in its confirmation; nil for none. A result
  #     stored before runs pushed their proposal as an artifact has `message` alone;
  #   * `questions`: the questions of the work item's newest questions that a run of the
  #     current take in wrote (`asked.run`) or reopened last (the `reopened.run` of the
  #     last entry of its `history` that has one), in their order, each `%{id:, number:,
  #     text:, context:, options:, state:, asked_run:, stage_id:, answer:, history:,
  #     follows:, decision:}`: `stage_id` the stage of the run that wrote or reopened it
  #     last, `number` its row's place on the Explore tab, from 1, top to bottom
  #     (`shown_numbers/1`), `state` `:open`,
  #     `:answered`, `:decided` or `:withdrawn`, `decision` nil or the run's choice,
  #     `%{option:, reason:, run:, at:}`, kept after a member answered, `answer` nil or
  #     `%{option:, recommended:, note:, by_id:, by:, at:}` (`by_id` by the move that
  #     wrote it, nil where none matches, `by` the name in the document), `history` its
  #     earlier answers in the same form, and `follows` the
  #     numbers of the questions it follows, among these questions; and
  #     `questions_version`, the number of that version, nil for none;
  #   * `review_comments`: the review comments of the current take in, oldest first, each
  #     `%{id:, artifact:, text:, by_id:, at:, version:, run:, attempt:, stage_id:,
  #     state:, reopened:, replies:}`: `artifact` the type it is on and `version` that
  #     type's version, both nil for a review comment on the whole round of a run, whose
  #     `run` is that run's number, `attempt` its attempt and `stage_id` the stage it ran
  #     at (all three nil for an output's),
  #     `state` `:open` or `:closed`, `reopened` true for an open one a run replied to,
  #     and each reply `%{run:, by_id:, text:, at:, outcome:, question:,
  #     question_number:, version:}`: a run's with its number, its `outcome`
  #     (`:changed`, `:answered`, `:declined` or `:asked`, with the question's id and
  #     number) and the version of the comment's type that run stood at; a member's with
  #     `by_id` and that type's version the take in's latest run stood at when it was
  #     written.
  #
  # A run map: `id` and `number` (its registered run's public id and number, both nil for
  # a run with none: one waiting, or one that ended before its handover), `workspace_id`, the workspace it was queued in, where it stays
  # when its work item moves, `stage_id`, the stage it ran at, `attempt`, `of`, `state`
  # (`Apiary.WorkItems.Explore.run_state/1`), `paused`, for a paused run that a run
  # continues, why it paused and the run that continues it (`Apiary.Dispatches.Pause`),
  # else nil, `place` (`Apiary.WorkItems.Explore.step/4`),
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
  # [%{title:, explanation:, recommended:}], answer: answer or nil, custom: true, false or
  # nil, recommended: whether the answer is the option the run recommends}`, for a
  # run that asked: where its questions wait, the open questions of the work item's
  # newest questions that a run of the current take in wrote or reopened last, which
  # `Apiary.WorkItems.Moves.answer/4` refers to by position, else the questions it wrote
  # or reopened, also those a later run reopened again, and those answered at it
  # (`Apiary.Explore.Questions`, `Apiary.Explore.Given`), each with its answer given at
  # the run; and `answered_by_id` and `answered_at` once a member answered at it;
  # `sent`, true for a run that a send of the review comments at the run before it
  # started, with `sent_by_id`, the member who sent them, nil for any other run. A
  # confirmed run's proposal is the version in its confirmation. A run that ended before
  # Explore's runs pushed artifacts shows the proposal in its result, and no questions.
  # `wrote` is the version of the proposal the run pushed, nil for none, with
  # `wrote_proposal`, that version in the form of the top-level `proposal`, without
  # `version`, and `asked` how many questions of the newest questions it wrote or
  # reopened, also those a later run reopened again: both read from the artifacts the
  # run pushed, so a run that failed after it pushed them has them too. The versions of
  # the proposal the runs stand at, and whether each has a Markdown file, are read in one
  # query (`pushed/1`). Of the proposals' texts, only the newest proposal's is read from
  # the store: a `proposal` or `wrote_proposal` of another version is `%{message: nil,
  # unread: version, kept: message}`, `kept` the `message` of its result or nil, until
  # the page opens its fold and reads it (`proposals/2`, `with_proposals/2`); a `proposal`
  # whose read found no text shows `kept`, and stays unread. A version with no Markdown
  # file is not left unread: its `wrote_proposal` is nil, and its `proposal` is
  # `%{message: kept}`.
  #
  # ## `thread/2`
  #
  # What happened to the work item at Explore, in the order it happened, for the Thread:
  # each entry a map with its `kind` and `at`, and by kind:
  #
  #   * the events of the work item: `:taken_in` (`actor_id`, `take_in`, `again`,
  #     `owner_id`, who owned the work item in that take in, and `first_instruction` for
  #     the current take in, nil for an earlier one),
  #     `:answered` (`actor_id`, `run`, `questions` with their answers, `comment`, the
  #     text of a review comment or a reply, nil for answers, `artifact`, the type it is
  #     on, and `reply`, true for a reply; a send of the review comments has no entry),
  #     `:explore_again`
  #     (`actor_id`, `run`, the run it started), `:confirmed` (`actor_id`, `changed`),
  #     `:closed` (`actor_id`, nil for the instance, `stage`, nil where none was recorded,
  #     and the instance's `reason`, nil for a person),
  #     `:undone` (`actor_id`);
  #   * the runs: `:started` (`run`, `start`: nil for a take in's first run,
  #     `:review_comments` for a run a send of the review comments queued, `:answers` for
  #     a run after answers, `:again` for any other), at its start, for a run handed over;
  #     then at its end `:asked` (`run`, `questions`, the questions it wrote or reopened,
  #     `duration_ms`), `:proposed` (`run`, `duration_ms`, `owner_id`), `:no_result`
  #     (`run`, `outcome`, the end cause and its code, `end_cause` and `end_detail`, as a
  #     run map has them, and `wrote`, the version of the proposal a failed run pushed
  #     before it failed, nil for none), `:lost` or `:cancelled` (`run`). A run that
  #     waits on an earlier run's open questions and wrote or reopened none ends as
  #     `:proposed` with no `owner_id` where it wrote a proposal, as `:replied` (`run`,
  #     `replies`, how many replies to review comments it wrote, `duration_ms`) where it
  #     wrote none but at least one such reply, else as `:no_result` with `outcome`
  #     `:none`.
  #
  # A run at a stage after Explore's starts with `start` nil where the run before it ran at
  # another stage. Where it gave no result, it ends as `:asked` where it wrote questions,
  # and with no entry where it pushed a version of an output: its outputs are its result.
  #
  # `run` is `%{id, workspace_id, stage_id, attempt, of}`, `stage_id` the stage it ran at,
  # nil for none. A run that has not ended, or reads as running, has no entry at its end.
  #
  # Who owned the work item in a take in is its owner for the current take in; for an
  # earlier one, the owner the next take in found (its `:taken_in` event's `before`). A
  # current take in that was a take in again and was undone gave its owner back to the
  # one before, and no record keeps the owner it had: nil.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Apiary.Repo
  alias Apiary.Artifacts.{Artifact, ArtifactFile, Version}
  alias Apiary.Dispatches.{DispatchRun, Pause}
  alias Apiary.Harnesses.{RunHarness, WorkflowGap}
  alias Apiary.Nodes.Node
  alias Apiary.Runs.ReadNeeds
  alias Apiary.Explore.{Given, Questions, ReviewComments}
  alias Apiary.WorkItems.{Confirmation, Explore, Proposal, State, WorkItem}

  @ends [:closed, :undone]

  # explore/2 is where Explore stands for `work_item` at `now` (the moduledoc).
  @doc false
  @spec explore(WorkItem.t(), DateTime.t()) :: map
  def explore(%WorkItem{id: id, take_in: take_in} = work_item, %DateTime{} = now) do
    steps = Explore.steps(id, :all, now)
    by_take_in = Enum.group_by(steps, & &1.take_in)
    current = Map.get(by_take_in, take_in, [])
    confirmations = confirmations(id)
    confirmation = confirmations[take_in]
    events = Explore.events(id)
    live? = State.live?(work_item.state)
    status = Explore.status(current, not is_nil(confirmation), work_item)

    ctx =
      context(work_item, steps, events, (live? and status == :questions) && List.last(current))

    read = newest_read(id, List.last(current), confirmation, ctx)
    taken = take_ins(events)
    runs = Enum.map(current, &run_view(&1, ctx, confirmation, work_item, read))
    earlier = earlier_take_ins(work_item, taken, by_take_in, ctx, {take_in, confirmations}, read)

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
      earlier_take_ins: earlier,
      answers_by_ids:
        for(%{kind: :answer, take_in: ^take_in, by_id: by_id} <- ctx.given, do: by_id)
        |> Enum.uniq(),
      confirmed_by_id: confirmation && confirmation.confirmed_by_id,
      confirmed_at: confirmation && confirmation.confirmed_at,
      proposal: newest_proposal(work_item, List.last(runs), ctx, read),
      questions: questions_view(ctx),
      questions_version: ctx.questions_version,
      review_comments: review_comments(ctx, take_in)
    }
  end

  # newest_outputs/3 is the newest version of each of `types` that a run of `work_item`'s
  # current take in pushed at the stage `stage_id`, a stage after Explore's, by type, of the
  # artifact named `main`. A type with none has no entry.
  @doc false
  @spec newest_outputs(WorkItem.t(), String.t(), [String.t()]) :: %{String.t() => pos_integer}
  def newest_outputs(%WorkItem{id: id, take_in: take_in}, stage_id, types)
      when is_binary(stage_id) and is_list(types) do
    for {type, number} <- Explore.versions(id, take_in, {stage_id, false}),
        type in types,
        reduce: %{} do
      newest -> Map.update(newest, type, number, &max(&1, number))
    end
  end

  # output/3 is version `number` of `work_item`'s artifact of `type` named `main` as the
  # page shows it (`message`, its Markdown; `version_id`; `images`), nil for none.
  @doc false
  @spec output(WorkItem.t(), String.t(), pos_integer) :: map | nil
  def output(%WorkItem{id: id}, type, number) when is_binary(type) and is_integer(number),
    do: id |> Explore.document(type, number) |> shown_document()

  # The text of the newest proposal of the current take in, the one version of the
  # proposal that `explore/2` reads from the store: by its number, as the page shows it
  # (`shown_proposal/2`); empty for none. The proposals of the earlier runs are read
  # where the page opens their fold (`proposals/2`, `with_proposals/2`).
  defp newest_read(_id, nil, _confirmation, _ctx), do: %{}

  defp newest_read(id, step, confirmation, ctx) do
    version =
      case confirmed_result(step, confirmation) do
        %{} = result -> result["proposal_version"] || version(step, ctx)
        nil -> version(step, ctx)
      end

    if is_integer(version), do: %{version => shown_proposal(id, version)}, else: %{}
  end

  # proposals/2 is versions `versions` of `work_item`'s proposal as the page shows them,
  # by number: `%{message:, version_id:, images:}`, nil for a version with no text, read
  # once each, for the folds the page opens.
  @doc false
  @spec proposals(WorkItem.t(), [pos_integer]) :: %{pos_integer => map | nil}
  def proposals(%WorkItem{id: id}, versions) when is_list(versions),
    do: Map.new(versions, &{&1, shown_proposal(id, &1)})

  # with_proposals/2 is `explore`, as `explore/2` returns it, with the proposals of
  # `texts` (`proposals/2`) in the runs that show them: an earlier run's `wrote_proposal`
  # and `proposal`, and the `proposal` of an earlier take in's run, which the page draws
  # in that take in's fold, that `explore/2` left unread (`:unread`, the version's
  # number), each filled where `texts` has its version.
  @doc false
  @spec with_proposals(map, %{pos_integer => map | nil}) :: map
  def with_proposals(explore, texts) when texts == %{}, do: explore

  def with_proposals(explore, texts) do
    filled = &(&1 |> filled(:wrote_proposal, texts) |> filled(:proposal, texts))
    taken = &filled(&1, :proposal, texts)

    %{
      explore
      | earlier_runs: Enum.map(explore.earlier_runs, filled),
        earlier_take_ins:
          Enum.map(explore.earlier_take_ins, &%{&1 | runs: Enum.map(&1.runs, taken)})
    }
  end

  defp filled(run, key, texts) do
    with %{unread: version} = unread <- Map.get(run, key),
         {:ok, shown} <- Map.fetch(texts, version) do
      Map.put(run, key, read_proposal(key, shown, unread))
    else
      _kept -> run
    end
  end

  # A proposal read for its fold, as the page shows it. A read that found no text leaves
  # the proposal unread, so the next open reads it again: a `wrote_proposal` stays as it
  # was, and a `proposal` shows the `message` of its result until then.
  defp read_proposal(_key, %{message: text} = shown, _unread) when is_binary(text), do: shown
  defp read_proposal(:wrote_proposal, _none, unread), do: unread
  defp read_proposal(:proposal, _none, unread), do: %{unread | message: unread.kept}

  # The newest proposal of the current take in: the one its latest run stands at, or the
  # one in its confirmation; nil for none. `read` has that version, by number
  # (`newest_read/4`), so it is not read again.
  defp newest_proposal(_work_item, nil, _ctx, _read), do: nil

  defp newest_proposal(
         %WorkItem{id: id},
         %{proposal: %{message: message}, version: version},
         _ctx,
         read
       )
       when is_binary(message) do
    case read_version(id, version, read) do
      {%{} = proposal, _read} -> Map.put(proposal, :version, version)
      _kept -> %{version: version, message: message}
    end
  end

  defp newest_proposal(%WorkItem{id: id, take_in: take_in}, %{attempt: attempt}, ctx, read) do
    with version when is_integer(version) <- version_at(take_in, attempt, ctx),
         {%{} = proposal, _read} <- read_version(id, version, read) do
      Map.put(proposal, :version, version)
    else
      _none -> nil
    end
  end

  # Version `version` of the work item `id`'s proposal as the page shows it, from `read`,
  # the versions read already, by number; a version not in it is read and added. `{nil,
  # read}` for no version.
  defp read_version(_id, nil, read), do: {nil, read}

  defp read_version(id, version, read) do
    case Map.fetch(read, version) do
      {:ok, shown} ->
        {shown, read}

      :error ->
        shown = shown_proposal(id, version)
        {shown, Map.put(read, version, shown)}
    end
  end

  # Version `version` of the work item `id`'s proposal as the page shows it (`message`,
  # its Markdown; `version_id`; `images`, its image files' filenames), nil for none.
  defp shown_proposal(id, version), do: id |> Explore.proposal(version) |> shown_document()

  defp shown_document(%{text: text, version_id: version_id, images: images}),
    do: %{message: text, version_id: version_id, images: images}

  defp shown_document(nil), do: nil

  # The questions of the newest questions that a run of the current take in wrote or
  # reopened last, in their order, each numbered by its row's place on the Explore tab
  # (the moduledoc).
  defp questions_view(ctx) do
    numbers = shown_numbers(ctx)
    given = for %{kind: :answer} = entry <- ctx.given, do: entry

    for %{"id" => id} = question <- (ctx.questions || %{})["questions"] || [],
        current_take_in?(question, ctx) do
      %{options: options} = Proposal.question(question)
      history = question["history"] || []
      moves = Enum.filter(given, &(&1.id == id))

      %{
        id: id,
        number: numbers[id],
        text: question["question"],
        context: question["context"],
        options: options,
        state: question_state(question["state"]),
        asked_run: get_in(question, ["asked", "run"]),
        stage_id: question_stage(question, ctx),
        answer: given_answer(question["answer"], Enum.at(moves, length(history)), options),
        history:
          for(
            {entry, n} <- Enum.with_index(history),
            do: given_answer(entry, Enum.at(moves, n), options)
          ),
        follows: for(other <- question["follows"] || [], n = numbers[other], do: n),
        decision: decision(question["decision"])
      }
    end
  end

  # A run's decision on a question, as the page shows it; nil for none.
  defp decision(%{"option" => option, "reason" => reason} = decision) do
    %{option: option, reason: reason, run: decision["run"], at: time(decision["at"])}
  end

  defp decision(_none), do: nil

  # The number of each question the Explore tab shows (`current_take_in?/2`), by its id:
  # its row's place from 1, top to bottom. With an open question, the questions frame has
  # the closed questions, the decisions, then the open questions. With none, the Decisions
  # frame comes first, then the frame of the closed questions
  # (`ApiaryWeb.WorkItemComponents.explore_tab/1`).
  defp shown_numbers(ctx) do
    {decisions, questions} =
      ((ctx.questions || %{})["questions"] || [])
      |> Enum.filter(&(match?(%{"id" => _id}, &1) and current_take_in?(&1, ctx)))
      |> Enum.split_with(&decision_row?/1)

    {open, closed} = Enum.split_with(questions, &(question_state(&1["state"]) == :open))
    rows = if open == [], do: decisions ++ closed, else: closed ++ decisions ++ open

    rows |> Enum.with_index(1) |> Map.new(fn {%{"id" => id}, n} -> {id, n} end)
  end

  # Whether the tab shows the question among the decisions
  # (`ApiaryWeb.WorkItemComponents.decision?/1`).
  defp decision_row?(%{"decision" => %{"option" => _, "reason" => _}, "state" => state}),
    do: state in ["decided", "answered"]

  defp decision_row?(_question), do: false

  # Whether a run of the current take in wrote the question (`asked.run`) or reopened it
  # last (the `reopened.run` of the last entry of its `history` that has one), the rule of
  # `Apiary.Explore.Questions.open_in_take_in/2` for any state. The questions document of
  # a work item spans its take ins.
  defp current_take_in?(question, ctx) do
    MapSet.member?(ctx.current_runs, get_in(question, ["asked", "run"])) or
      MapSet.member?(ctx.current_runs, reopened_run(question))
  end

  # The stage of the run of the current take in that reopened the question last, else of
  # the run that wrote it; nil for a run with no stage.
  defp question_stage(question, ctx) do
    reopened = reopened_run(question)

    run =
      if MapSet.member?(ctx.current_runs, reopened),
        do: reopened,
        else: get_in(question, ["asked", "run"])

    case Map.get(ctx.by_number, run) do
      %{dispatch_run: %{stage_id: stage_id}} -> stage_id
      _none -> nil
    end
  end

  # The `reopened.run` of the last entry of the question's `history` that has one; nil
  # for none.
  defp reopened_run(question) do
    (question["history"] || [])
    |> Enum.reverse()
    |> Enum.find_value(&(is_map(&1) && get_in(&1, ["reopened", "run"])))
  end

  defp question_state("answered"), do: :answered
  defp question_state("decided"), do: :decided
  defp question_state("withdrawn"), do: :withdrawn
  defp question_state(_open), do: :open

  # An answer of the questions document, with who gave it by `move`, the move that wrote
  # it (`Apiary.Explore.Given`, which pairs a question's moves with its `history` and
  # then its answer by order): `by_id` nil where no move is at its place, with `by`, the
  # name in the document; `recommended` whether the option chosen is the one the run
  # recommends.
  defp given_answer(%{} = answer, move, options) do
    %{
      option: answer["option"],
      recommended: recommended?(options, answer["option"]),
      note: answer["note"],
      by_id: move && move.by_id,
      by: get_in(answer, ["by", "name"]),
      at: (move && move.at) || time(answer["at"])
    }
  end

  defp given_answer(_none, _move, _options), do: nil

  defp recommended?(options, title),
    do: Enum.any?(options, &(&1.title == title and &1[:recommended] == true))

  defp second(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp time(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} -> at
      _invalid -> nil
    end
  end

  defp time(_at), do: nil

  # The review comments of take in `take_in`, oldest first, each with its replies (the
  # moduledoc).
  defp review_comments(ctx, take_in) do
    written = for %{kind: :comment, id: id} = given <- ctx.given, into: %{}, do: {id, given}
    replies = for %{kind: :reply} = given <- ctx.given, do: given
    numbers = shown_numbers(ctx)

    for %{"on" => on} = comment <- ReviewComments.entries(ctx.review_comments),
        {type, version, run} <- [on_parts(on)],
        %{take_in: ^take_in} = given <- [Map.get(written, comment["id"])] do
      shown =
        (comment["replies"] || [])
        |> Enum.with_index(1)
        |> Enum.map(fn {reply, position} ->
          reply_view(reply, {type, comment["id"], position}, replies, ctx)
        end)

      open? = comment["state"] != "closed"

      %{
        id: comment["id"],
        artifact: type,
        text: comment["text"],
        by_id: given.by_id,
        at: given.at,
        version: version,
        run: run,
        attempt: run_attempt(ctx, run),
        stage_id: run_stage(ctx, run),
        state: if(open?, do: :open, else: :closed),
        reopened: open? and Enum.any?(shown, &is_integer(&1.run)),
        replies: Enum.map(shown, &Map.put(&1, :question_number, numbers[&1.question]))
      }
    end
  end

  # The stage the run `number` ran at, nil for none.
  defp run_stage(ctx, number) do
    case number && Map.get(ctx.by_number, number) do
      %{dispatch_run: %{stage_id: stage_id}} -> stage_id
      _none -> nil
    end
  end

  # The attempt of the run `number` in its take in, nil for none.
  defp run_attempt(ctx, number) do
    case number && Map.get(ctx.by_number, number) do
      %{attempt: attempt} -> attempt
      _none -> nil
    end
  end

  # What a review comment is on: `{type, version, nil}` for one output, `{nil, nil, run}`
  # for the round of the run `run`.
  defp on_parts(%{"artifact" => type, "version" => version}), do: {type, version, nil}
  defp on_parts(%{"run" => run}), do: {nil, nil, run}

  # A reply to a review comment: a run's, with its outcome and the version of the
  # comment's type that run stood at; a member's, with who wrote it and the version of
  # that type the take in's latest run stood at then, by the move that wrote that reply
  # of that review comment (`at`, the type, the review comment's id and the reply's
  # position from 1), with its text and time.
  defp reply_view(%{"by" => %{"run" => number}} = reply, {type, _id, _position}, _replies, ctx) do
    %{
      run: number,
      by_id: nil,
      text: reply["text"],
      at: time(reply["at"]),
      outcome: outcome(reply["outcome"]),
      question: reply["question"],
      version: (step = Map.get(ctx.by_number, number)) && version(step, ctx, type)
    }
  end

  defp reply_view(reply, {type, id, position}, replies, ctx) do
    move =
      Enum.find(
        replies,
        &(&1.id == id and Map.get(ctx.reply_positions, &1.event_id) == position and
            &1.text == reply["text"] and second(&1.at) == reply["at"])
      )

    step = move && Enum.find(ctx.current, &(&1.attempt == move.attempt))

    %{
      run: nil,
      by_id: move && move.by_id,
      text: reply["text"],
      at: (move && move.at) || time(reply["at"]),
      outcome: nil,
      question: nil,
      version: step && version(step, ctx, type)
    }
  end

  defp outcome("changed"), do: :changed
  defp outcome("answered"), do: :answered
  defp outcome("declined"), do: :declined
  defp outcome("asked"), do: :asked
  defp outcome(_none), do: nil

  # What the pages read besides the runs: what members gave (`Apiary.Explore.Given`), the
  # position of the reply each move of a reply wrote, by the move's event, the runs a send
  # of the review comments was made at, by take in and attempt, each with the member who
  # sent them (`sent`, from the `"review_comments"` key of the event), the newest
  # questions and review comments, the runs by their registered run's number, the steps of
  # the current take in and their registered runs' numbers (`current_runs`), and
  # `waiting`, the latest run of the current take in where its questions wait, else nil.
  # The newest questions and review comments are read once, for `given` too.
  defp context(work_item, steps, events, waiting) do
    {pushed, markdown} = pushed(work_item.id)
    questions = Questions.newest(work_item)
    review_comments = document(ReviewComments.newest(work_item))
    current = Enum.filter(steps, &(&1.take_in == work_item.take_in))

    %{
      given: Given.from_events(events, document(questions), review_comments),
      reply_positions:
        for(
          %{kind: :answered, id: id, data: %{"reply" => position}} <- events,
          into: %{},
          do: {id, position}
        ),
      sent:
        for(
          %{kind: :answered, data: %{"review_comments" => _ids} = data} = event <- events,
          into: %{},
          do: {{data["take_in"], data["attempt"]}, event.actor_id}
        ),
      pushed: pushed,
      markdown: markdown,
      questions: document(questions),
      questions_version: number(questions),
      review_comments: review_comments,
      by_number: for(%{run: %{number: n}} = step <- steps, into: %{}, do: {n, step}),
      current: current,
      current_runs: for(%{run: %{number: n}} <- current, into: MapSet.new(), do: n),
      waiting: waiting || nil
    }
  end

  defp document({_version, document}), do: document
  defp document(nil), do: nil

  defp number({%{number: number}, _document}), do: number
  defp number(_none), do: nil

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

  # The fields `ApiaryWeb.RunComponents.quiet_for/2` reads, as the run's page has them, and
  # the run's ids: nil for a run of the queue with no registered run.
  @doc false
  def heard(nil), do: nil

  def heard(%{} = run) do
    Map.take(run, [
      :id,
      :workspace_id,
      :state,
      :inserted_at,
      :last_heartbeat_at,
      :registration_interval_seconds,
      :attach_interval_seconds,
      :heartbeat_interval_seconds
    ])
  end

  # The run map of the run `step` (the moduledoc), with `read`, the versions of the
  # proposal read already, by number: a proposal of a version not in it is left unread.
  defp run_view(step, ctx, confirmation, work_item, read) do
    rows = answers_of(ctx, step)
    wrote = wrote(step, ctx)

    wrote_proposal =
      case Map.fetch(read, wrote) do
        {:ok, shown} -> shown
        :error -> if is_integer(wrote) and markdown?(wrote, ctx), do: unread(wrote, nil)
      end

    ended_at = Explore.ended_at(step)

    view = %{
      id: step.run && step.run.public_id,
      number: step.run && step.run.number,
      workspace_id: step.dispatch_run.workspace_id,
      stage_id: step.dispatch_run.stage_id,
      attempt: step.attempt,
      of: step.of,
      state: Explore.run_state(step),
      paused: Pause.of_run(step.run),
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
      heard: heard(step.run),
      proposal: nil,
      version: nil,
      questions: [],
      answered_by_id: nil,
      answered_at: nil,
      sent: Map.has_key?(ctx.sent, {step.take_in, step.attempt - 1}),
      sent_by_id: Map.get(ctx.sent, {step.take_in, step.attempt - 1}),
      wrote: wrote,
      wrote_proposal: wrote_proposal,
      asked: asked(step, ctx)
    }

    view =
      case {step.outcome, confirmed_result(step, confirmation)} do
        {_outcome, %{} = result} ->
          version = result["proposal_version"] || version(step, ctx)
          proposal = proposal(version, result, read, ctx)
          %{view | outcome: :proposal, place: :proposal, proposal: proposal, version: version}

        {:proposal, nil} ->
          version = version(step, ctx)
          proposal = proposal(version, step.dispatch_run.result, read, ctx)
          %{view | proposal: proposal, version: version}

        {:questions, nil} ->
          %{view | questions: questions(step, ctx, rows)}

        _other ->
          view
      end

    case rows do
      [first | _rest] -> %{view | answered_by_id: first.by_id, answered_at: first.at}
      [] -> view
    end
  end

  defp confirmed_result(
         %{take_in: take_in, attempt: attempt},
         %{take_in: take_in, attempt: attempt} = confirmation
       ),
       do: confirmation.result

  defp confirmed_result(_step, _confirmation), do: nil

  # The version of `type` the run `step` stands at; nil for none.
  defp version(step, ctx, type \\ "proposal"),
    do: version_at(step.take_in, step.attempt, ctx, type)

  # The version of `type` the run `attempt` of take in `take_in` stands at, as
  # `Apiary.WorkItems.Explore.version/4` reads it: the newest version a run of the take in
  # up to it pushed, from `ctx.pushed` (`pushed/1`); nil for none.
  defp version_at(take_in, attempt, ctx, type \\ "proposal") do
    ctx.pushed
    |> Enum.filter(fn {{y, t, a}, _number} -> y == type and t == take_in and a <= attempt end)
    |> Enum.map(fn {_run, number} -> number end)
    |> Enum.max(fn -> nil end)
  end

  # The newest version of each artifact named `main` each run of the work item `id` pushed,
  # by `{type, take_in, attempt}`, and whether each proposal version has Markdown, read in
  # one query for the page.
  defp pushed(id) do
    rows =
      Repo.all(
        from v in Version,
          as: :version,
          join: a in Artifact,
          on: a.id == v.artifact_id,
          join: d in DispatchRun,
          on: d.id == v.run_id,
          where: a.work_item_id == ^id and a.name == "main",
          where: d.work_item_id == ^id,
          select:
            {a.type, d.take_in, d.attempt, v.number,
             exists(
               from f in ArtifactFile,
                 where:
                   f.version_id == parent_as(:version).id and
                     like(f.content_type, "text/markdown%")
             )}
      )

    newest =
      Enum.reduce(rows, %{}, fn {type, take_in, attempt, number, _markdown}, newest ->
        Map.update(newest, {type, take_in, attempt}, number, &max(&1, number))
      end)

    {newest,
     for({"proposal", _take_in, _attempt, n, markdown} <- rows, into: %{}, do: {n, markdown})}
  end

  # Every confirmation of the work item `id`, by take in, read in one query for the page.
  defp confirmations(id) do
    Repo.all(from c in Confirmation, where: c.work_item_id == ^id)
    |> Map.new(&{&1.take_in, &1})
  end

  # Whether the store may have a text for version `number` of the proposal: false only for
  # a version the runs pushed with no Markdown file (`pushed/1`), which the page shows
  # with no proposal, as for a version whose text it read and found none.
  defp markdown?(number, ctx), do: Map.get(ctx.markdown, number, true)

  # A proposal left unread for its fold: version `number`, with `kept`, the `message` of
  # its result or nil.
  defp unread(number, kept), do: %{message: nil, unread: number, kept: kept}

  # The version of the proposal the run `step` pushed: its version, where the run before
  # it stood at another; nil for none.
  defp wrote(%{run: nil}, _ctx), do: nil

  defp wrote(%{attempt: attempt} = step, ctx) do
    before = attempt > 1 && version_at(step.take_in, attempt - 1, ctx)

    case version(step, ctx) do
      version when is_integer(version) and version != before -> version
      _same -> nil
    end
  end

  # How many questions of the newest questions the run `step` wrote or reopened
  # (`wrote?/2`).
  defp asked(%{run: %{number: number}}, ctx) when is_integer(number),
    do: Enum.count((ctx.questions || %{})["questions"] || [], &wrote?(&1, number))

  defp asked(_step, _ctx), do: 0

  # The proposal of a run, at `version`: that version of the work item's proposal as the
  # page shows it (`message`, its Markdown; `version_id`; `images`), else the `message` of
  # a result from before Explore's runs pushed their proposal as an artifact; nil for
  # none. A version not in `read`, the versions read already, by number, is left unread
  # (`:unread`, with the result's `message` as `:kept`), for its fold
  # (`with_proposals/2`).
  defp proposal(version, result, read, ctx) do
    kept =
      case result do
        %{"message" => message} when is_binary(message) -> message
        _none -> nil
      end

    case Map.fetch(read, version) do
      {:ok, %{message: text} = shown} when is_binary(text) ->
        shown

      {:ok, _none} ->
        %{message: kept}

      :error when is_integer(version) ->
        if markdown?(version, ctx), do: unread(version, kept), else: %{message: kept}

      :error ->
        %{message: kept}
    end
  end

  # The questions of the newest questions the run `step` wrote (`asked.run`) or reopened
  # (the `reopened.run` of any entry of its `history`), in their order, each with its
  # answer given at the run, for the Thread's `:asked`. A question that a later run
  # reopened again is in this list too.
  defp wrote_questions(%{run: %{number: number}} = step, ctx) when is_integer(number) do
    answers = Map.new(answers_of(ctx, step), &{&1.id, &1})

    ((ctx.questions || %{})["questions"] || [])
    |> Enum.filter(&wrote?(&1, number))
    |> Enum.with_index(1)
    |> Enum.map(fn {question, position} ->
      question_view(question, position, Map.get(answers, question["id"]))
    end)
  end

  defp wrote_questions(_step, _ctx), do: []

  # Whether the run numbered `number` wrote the question (`asked.run`) or reopened it
  # (`reopened_by?/2`), also where a later run reopened it again: the rule of the
  # Thread's `:asked`, of a run's `asked`, and of the questions of a run whose questions
  # do not wait. A question with a run's `decision` counts only for a run that reopened
  # it: the run that wrote it wrote the option it chose, for no member to answer.
  defp wrote?(%{"decision" => %{}} = question, number), do: reopened_by?(question, number)

  defp wrote?(question, number),
    do: get_in(question, ["asked", "run"]) == number or reopened_by?(question, number)

  # Whether an entry of the question's `history` has the `reopened.run` `number`.
  defp reopened_by?(question, number) do
    Enum.any?(question["history"] || [], fn entry ->
      is_map(entry) and get_in(entry, ["reopened", "run"]) == number
    end)
  end

  # The Thread's entry at the end of a run that waits on questions it did not write, as
  # one that waits on an earlier run's open question: `:proposed` where it wrote a
  # proposal, `:replied` where it wrote none but replied to a review comment, else
  # `:no_result`, a run without a result.
  defp without_questions(step, run, at, duration, ctx) do
    case {wrote(step, ctx), replies_by(step, ctx)} do
      {version, _replies} when is_integer(version) ->
        %{kind: :proposed, at: at, run: run, duration_ms: duration, owner_id: nil}

      {_none, replies} when replies > 0 ->
        %{kind: :replied, at: at, run: run, replies: replies, duration_ms: duration}

      _none ->
        %{
          kind: :no_result,
          at: at,
          run: run,
          outcome: :none,
          end_cause: step.dispatch_run.end_cause,
          end_detail: step.dispatch_run.end_detail,
          wrote: nil
        }
    end
  end

  # How many replies to review comments of the newest review comments the run `step`
  # wrote, by its registered run's number (a reply's `by.run`).
  defp replies_by(%{run: %{number: number}}, ctx) when is_integer(number) do
    ctx.review_comments
    |> ReviewComments.entries()
    |> Enum.flat_map(&(&1["replies"] || []))
    |> Enum.count(&(is_map(&1) and get_in(&1, ["by", "run"]) == number))
  end

  defp replies_by(_step, _ctx), do: 0

  # The answers given at the run `step`, in the order they were given.
  defp answers_of(ctx, step) do
    for %{kind: :answer, take_in: take_in, attempt: attempt} = given <- ctx.given,
        take_in == step.take_in and attempt == step.attempt,
        do: given
  end

  # The questions of a run that asked: where its questions wait, the open questions of the
  # newest questions that a run of the current take in wrote or reopened last, in its
  # order, which `Apiary.WorkItems.Moves.answer/4` refers to by position; otherwise the
  # questions it wrote or reopened (`wrote?/2`) and those answered at it, with their
  # answers given at it.
  defp questions(step, ctx, rows) do
    answers = Map.new(rows, &{&1.id, &1})

    entries =
      if ctx.waiting && ctx.waiting.dispatch_run.id == step.dispatch_run.id do
        Questions.open_in_take_in(ctx.questions, ctx.current_runs)
      else
        number = step.run && step.run.number

        for %{"id" => id} = question <- (ctx.questions || %{})["questions"] || [],
            Map.has_key?(answers, id) or (is_integer(number) and wrote?(question, number)),
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
      custom: given && given.custom,
      recommended: !!given and given.custom != true and recommended?(options, given.text)
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

  # The take ins before the current one, `current`: each `:taken_in` event and the end
  # that followed it, before the next take in, with its runs as the current take in's are
  # drawn, each read with that take in's confirmation, from `confirmations`
  # (`confirmations/1`); with `read`, the versions of the proposal read already, by number.
  defp earlier_take_ins(work_item, taken, by_take_in, ctx, {current, confirmations}, read) do
    for {take_in, taken_in, ended} <- taken, take_in < current do
      confirmation = confirmations[take_in]

      %{
        take_in: take_in,
        taken_in_by_id: taken_in.actor_id,
        taken_in_at: taken_in.at,
        ended: ended && ended.kind,
        ended_by_id: ended && ended.actor_id,
        ended_at: ended && ended.at,
        ended_reason: close_reason(ended),
        runs:
          Enum.map(
            Map.get(by_take_in, take_in, []),
            &run_view(&1, ctx, confirmation, work_item, read)
          )
      }
    end
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

    ctx =
      work_item
      |> context(steps, events, waiting)
      |> Map.put(:explore_id, Apiary.Stages.explore_stage_id(work_item))

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

  # A send of the review comments queues a run and gives nothing to read: no entry. A
  # send that wrote a comment on the proposal too (Run another round) has its entry.
  defp event_entry(:answered, %{data: %{"review_comments" => _ids} = data}, _by_run, _ctx)
       when not is_map_key(data, "review_comment"),
       do: nil

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
      comment: Enum.find_value(given, &if(&1.kind != :answer, do: &1.text)),
      artifact: commented_type(event, ctx),
      reply: is_integer(event.data["reply"])
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

  # The type the review comment of an `:answered` event is on; nil for an event with none.
  defp commented_type(%{data: %{"review_comment" => id}}, ctx) do
    ctx.review_comments
    |> ReviewComments.entries()
    |> Enum.find_value(&(&1["id"] == id && get_in(&1, ["on", "artifact"])))
  end

  defp commented_type(_event, _ctx), do: nil

  defp run_entries(step, by_run, ctx, owners) do
    run = run_ref(step, {step.take_in, step.attempt})

    started =
      case Explore.started_at(step) do
        nil -> []
        at -> [%{kind: :started, at: at, run: run, start: start(step, by_run, ctx)}]
      end

    started ++ ended(step, run, ctx, Map.get(owners, step.take_in))
  end

  # How a run started: after a send of the review comments at the run before it (the
  # event's `"review_comments"`, which `Apiary.Runs.ListFacts` reads too), after the
  # answers to the questions of the run before it, or again; at a stage after Explore's,
  # as a first start where the run before it ran at another stage.
  defp start(%{attempt: 1}, _by_run, _ctx), do: nil

  defp start(step, by_run, ctx) do
    before = {step.take_in, step.attempt - 1}

    if later?(step, ctx) and not same_stage?(Map.get(by_run, before), step) do
      nil
    else
      start_after(before, by_run, ctx)
    end
  end

  defp start_after(before, by_run, ctx) do
    if Map.has_key?(ctx.sent, before) do
      :review_comments
    else
      case Map.get(by_run, before) do
        %{outcome: :questions} = earlier ->
          if answers_of(ctx, earlier) != [], do: :answers, else: :again

        _other ->
          :again
      end
    end
  end

  # Whether the run `step` ran at a stage after Explore's.
  defp later?(%{dispatch_run: %{stage_id: stage_id}}, ctx),
    do: is_binary(stage_id) and stage_id != ctx.explore_id

  defp same_stage?(%{dispatch_run: %{stage_id: stage_id}}, %{dispatch_run: %{stage_id: stage_id}}),
       do: true

  defp same_stage?(_before, _step), do: false

  defp ended(step, run, ctx, owner_id) do
    case Explore.ended_at(step) do
      nil ->
        []

      at ->
        step
        |> ended_entries(run, ctx, owner_id, at)
        |> Enum.flat_map(&later_entry(&1, step, ctx))
    end
  end

  # A run at a stage after Explore's that gave no result: `:asked` where it wrote
  # questions, no entry where it pushed a version of an output.
  defp later_entry(%{kind: :no_result, outcome: :none} = entry, step, ctx) do
    cond do
      not later?(step, ctx) ->
        [entry]

      (questions = wrote_questions(step, ctx)) != [] ->
        [
          %{
            kind: :asked,
            at: entry.at,
            run: entry.run,
            questions: questions,
            duration_ms: duration_ms(step, entry.at)
          }
        ]

      outputs?(step, ctx) ->
        []

      true ->
        [entry]
    end
  end

  defp later_entry(entry, _step, _ctx), do: [entry]

  # Whether the run `step` pushed a version of an output: of a type other than the
  # proposal, the questions, the verdict and the review comments.
  defp outputs?(step, ctx) do
    others = ["proposal", "questions", "verdict", ReviewComments.type_name()]

    Enum.any?(ctx.pushed, fn {{type, take_in, attempt}, _number} ->
      take_in == step.take_in and attempt == step.attempt and type not in others
    end)
  end

  defp ended_entries(step, run, ctx, owner_id, at) do
    duration = duration_ms(step, at)

    case step.place do
      :questions ->
        case wrote_questions(step, ctx) do
          [] ->
            [without_questions(step, run, at, duration, ctx)]

          questions ->
            [%{kind: :asked, at: at, run: run, questions: questions, duration_ms: duration}]
        end

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
            end_detail: step.dispatch_run.end_detail,
            wrote: (Explore.run_state(step) == :failed && wrote(step, ctx)) || nil
          }
        ]

      place when place in [:lost, :cancelled] ->
        [%{kind: place, at: at, run: run}]
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
      stage_id: dispatch_run.stage_id,
      attempt: attempt,
      of: of
    }

  defp run_ref(nil, {_take_in, attempt}),
    do: %{id: nil, number: nil, workspace_id: nil, stage_id: nil, attempt: attempt, of: nil}
end
