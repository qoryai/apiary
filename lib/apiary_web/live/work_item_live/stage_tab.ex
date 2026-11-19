defmodule ApiaryWeb.WorkItemLive.StageTab do
  # The work item page's stage tabs and what each one lists, from what the page already read,
  # with no further read. A stage has a tab where it runs a workflow and has a run or is
  # the current stage, whatever its name, and where the runner passed the stage over whole
  # (`flow.stage_skips`). A tab's key is the stage's id, a stage keeps its id
  # for good, except for the stage that runs Explore's workflow, whose key is `:explore`.
  #
  # `view/3` filters only what the page draws. The page's moves read `item.run`, the
  # latest run of the take in, whatever the stage (`Apiary.WorkItems.Moves`), so a filter
  # never reaches it. With no stage card (`flow` nil) nothing is filtered.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  alias Apiary.Artifacts
  alias Apiary.Stages.Runner
  alias ApiaryWeb.People
  alias ApiaryWeb.WorkItemLive.{StageComponents, VerifyTab}

  # tabs/2 is the tabs of `flow` in the process version's order, with every run the page
  # read, of any take in: `%{id:, key:, name:, types:}`, `types` the stage's output types.
  @spec tabs(map, [map]) :: [map]
  def tabs(flow, runs) do
    ran = MapSet.new(runs, &stage_of(&1, flow))
    passed_over = MapSet.new(Map.get(flow, :stage_skips, []), & &1.stage_id)

    for stage <- flow.stages,
        MapSet.member?(passed_over, stage.id) or
          (Runner.workflows(%{"sequence" => stage.sequence}) != [] and
             (stage.id == flow.stage.id or MapSet.member?(ran, stage.id))) do
      %{id: stage.id, key: key(flow, stage.id), name: stage.name, types: stage.outputs}
    end
  end

  # key/2 is the key of the tab of the stage `id`.
  @spec key(map, String.t()) :: :explore | String.t()
  def key(%{explore_id: id}, id), do: :explore
  def key(_flow, id), do: id

  # tab/2 is the tab with the key `key` of `flow`'s tabs; nil for none.
  @spec tab(map, term) :: map | nil
  def tab(%{tabs: tabs}, key), do: Enum.find(tabs, &(&1.key == key))

  # current/1 is the key of the current stage's tab; nil where it has none.
  @spec current(map) :: :explore | String.t() | nil
  def current(flow) do
    case tab(flow, key(flow, flow.stage.id)) do
      %{key: key} -> key
      nil -> nil
    end
  end

  # proposal/1 is the key of the tab of the first stage with a `proposal` output, by its
  # outputs and not by its name; nil where that stage has no tab, or no stage has one.
  @spec proposal(map) :: :explore | String.t() | nil
  def proposal(flow) do
    case Enum.find(flow.stages, &("proposal" in &1.outputs)) do
      %{id: id} ->
        case tab(flow, key(flow, id)) do
          %{key: key} -> key
          nil -> nil
        end

      nil ->
        nil
    end
  end

  # record?/2 is whether a stage's tab has the record block (`foot_record/1`), with the
  # stage's `runs` and `artifacts`: every tab but during a first run with no output. A stage
  # with no run and no artifact has it for Add a version.
  @spec record?([map], [map]) :: boolean
  def record?([%{place: place}], []) when place in [:queued, :running], do: false
  def record?(_runs, _artifacts), do: true

  # folded?/4 is whether a tab's runs fold lists every run of `flow` (`flow.runs`, the
  # stage runs of the take in), with `run`, the take in's latest run, and `earlier_runs`
  # and `artifacts` as `view/3` reads them. Explore's tab lists each of Explore's runs; a
  # later stage's tab lists that stage's runs where it has the record block (`record?/2`).
  # A run whose stage has no tab is in no fold. True with no run.
  @spec folded?(map, map | nil, [map], [map]) :: boolean
  def folded?(flow, run, earlier_runs, artifacts) do
    records = earlier_runs ++ List.wrap(run && run[:workspace_id] && run)
    Enum.all?(flow.runs, &folded_run?(&1, flow, records, artifacts))
  end

  defp folded_run?(run, flow, records, artifacts) do
    stage = Enum.find(flow.stages, &(&1.id == stage_of(run, flow)))

    if stage && tab(flow, key(flow, stage.id)) do
      runs = runs(flow, stage, records)

      Enum.any?(runs, &(&1.attempt == run.attempt)) and
        (stage.id == flow.explore_id or record?(runs, artifacts(flow, stage, artifacts)))
    else
      false
    end
  end

  # view/3 is what the tab `tab` draws of `read` (`item`, `earlier_runs`, `earlier_take_ins`,
  # `questions`, `questions_version`, `review_comments`, `artifacts`):
  #
  #   * `stage`: the tab's stage, on a stage tab, else nil;
  #   * `runs`: the stage's runs of the take in, oldest first;
  #   * `skips`: the stage's workflow entries the runner passed over in the take in;
  #   * `entries`: the rows of the table of the stage's entries, where it has a skip
  #     (`entries/3`);
  #   * `proposal_version`: on the tab of Shape, passed over whole, the number of the proposal
  #     version that Explore's approval lists (`proposal_version/3`), else nil;
  #   * `passed_over`: the record of the runner passing the stage over whole in the take in
  #     (`Apiary.Stages.stage_skips/1`), nil for none;
  #   * `take_ins`: the earlier take ins with the stage's runs and skips, each with its
  #     `place` among all of them, from 1;
  #   * `questions`: the questions that the Questions tab groups under the stage, whether open
  #     or closed (`question_groups/3`); `waiting`, whether the tab is the current stage's
  #     and a question is open, of any stage;
  #   * `questions_version`, `review_comments`, `artifacts` and `index`, each of the stage;
  #   * `wrote`: the versions the stage's runs wrote, for the summary of its runs
  #     (`wrote/3`), [] for no stage;
  #   * `recorded`: the demo video and picture versions each of `runs` wrote (`recorded/2`);
  #   * `sessions`: %{}, for the caller to set to the sessions of the runs that
  #     `Apiary.Stages.shared_sequences/1` selects (`Apiary.Stages.run_sessions/1`);
  #   * `sequences`: %{}, for the caller to set to those runs' stage sequences;
  #   * `foot`: on Explore's tab at a later stage, the record block of Explore's runs.
  #
  # On the Ticket tab, the Questions tab and the Thread, `review_comments` are the current
  # stage's, and `questions` are all of them. A version
  # with no stage belongs to Explore, as a run with none does.
  @spec view(atom | String.t(), map | nil, map) :: map
  def view(_tab, nil, read) do
    %{
      stage: nil,
      runs: [],
      skips: [],
      entries: [],
      passed_over: nil,
      proposal_version: nil,
      take_ins: read.earlier_take_ins,
      questions: read.questions,
      waiting: nil,
      questions_version: read.questions_version,
      review_comments: read.review_comments,
      artifacts: read.artifacts,
      index: [],
      wrote: [],
      recorded: %{},
      sessions: %{},
      sequences: %{},
      foot: nil
    }
  end

  def view(tab, flow, read) when tab in [:ticket, :questions, :thread] do
    artifacts = artifacts(flow, flow.stage, read.artifacts)

    flow
    |> view(read.item.run, nil, read)
    |> Map.put(:review_comments, comments(flow, flow.stage, read.review_comments, artifacts))
  end

  def view(tab, flow, read) do
    stage = Enum.find(flow.stages, &(key(flow, &1.id) == tab))
    view(flow, read.item.run, stage, read)
  end

  defp view(flow, _run, nil, read) do
    %{
      stage: nil,
      runs: read.earlier_runs,
      skips: Map.get(flow, :skips, []),
      entries: [],
      passed_over: nil,
      proposal_version: nil,
      take_ins: Enum.map(read.earlier_take_ins, &with_skips(&1, flow, nil)),
      questions: read.questions,
      waiting: nil,
      questions_version: read.questions_version,
      review_comments: read.review_comments,
      artifacts: read.artifacts,
      index: [],
      wrote: [],
      recorded: %{},
      sessions: %{},
      sequences: %{},
      foot: nil
    }
  end

  defp view(flow, run, stage, read) do
    runs = runs(flow, stage, read.earlier_runs ++ List.wrap(run && run[:workspace_id] && run))
    artifacts = artifacts(flow, stage, read.artifacts)
    explore? = stage.id == flow.explore_id
    passed_over = passed_over(flow, stage, runs)

    %{
      stage: stage,
      runs: runs,
      skips: Enum.filter(Map.get(flow, :skips, []), &(&1.stage_id == stage.id)),
      entries: entries(flow, stage, Map.get(flow, :skips, [])),
      passed_over: passed_over,
      proposal_version: proposal_version(flow, stage, passed_over),
      take_ins: take_ins(flow, stage, read.earlier_take_ins),
      questions: questions(flow, stage, read.questions),
      waiting: waiting?(flow, stage, read.questions),
      questions_version: version_of(artifacts, "questions"),
      review_comments: comments(flow, stage, read.review_comments, artifacts),
      artifacts: artifacts,
      index: index(flow.index, artifacts),
      wrote: wrote(stage, runs, read.artifacts),
      recorded: recorded(runs, read.artifacts),
      sessions: %{},
      sequences: %{},
      foot: if(explore? and not flow.at_explore, do: %{runs: runs, latest: nil, pieces: nil})
    }
  end

  # The demo videos and pictures each of `runs` wrote (`VerifyTab.media/0`), by the run's
  # public id: its versions of each type that are not withdrawn, oldest first, as
  # `%{kind:, at:, count:}`, `count` 1 for a video and the number of files for a picture.
  defp recorded(runs, artifacts) do
    ids = for %{id: id} when is_binary(id) <- runs, into: MapSet.new(), do: id

    for %{type: type} = artifact <- artifacts,
        type in VerifyTab.media(),
        version <- artifact.versions,
        not version.withdrawn,
        id = run_id(version),
        MapSet.member?(ids, id) do
      {kind, count} =
        if type == "screenshot", do: {:pictures, length(version.files)}, else: {:videos, 1}

      {id, %{kind: kind, at: version.inserted_at, count: count}}
    end
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {id, items} -> {id, Enum.sort_by(items, & &1.at, DateTime)} end)
  end

  # The newest version of each of the stage's output types, of the artifact named `main`,
  # that one of `runs` wrote, as `%{type, version}` in the stage's order. A person's upload
  # is no run's, and the gate may show a higher version than this (`frames/1`).
  defp wrote(stage, runs, artifacts) do
    ids = for %{id: id} when is_binary(id) <- runs, into: MapSet.new(), do: id

    for type <- stage.outputs,
        number = newest_wrote(artifacts, type, ids),
        number != nil,
        do: %{type: type, version: number}
  end

  defp newest_wrote(artifacts, type, ids) do
    for(
      %{type: ^type, name: "main"} = artifact <- artifacts,
      version <- artifact.versions,
      MapSet.member?(ids, run_id(version)),
      do: version.number
    )
    |> Enum.max(fn -> nil end)
  end

  # The public id of the registered run that wrote `version`, nil for a person's version.
  defp run_id(%{run: %{run: %{public_id: id}}}), do: id
  defp run_id(_version), do: nil

  # The record of the runner passing `stage` over whole, while the work item is not in the
  # stage and the stage has no run: a person's move into it later runs it after all.
  defp passed_over(flow, stage, runs) do
    if stage.id != flow.stage.id and runs == [],
      do: Enum.find(Map.get(flow, :stage_skips, []), &(&1.stage_id == stage.id))
  end

  # The number of the proposal version that an approval at Explore's gate lists, for the tab
  # of the stage Shape (the sentence says so) that the runner passed over whole; nil for any
  # other stage, for a stage that ran, and where Explore's approval lists no proposal.
  defp proposal_version(flow, %{name: "Shape"}, passed_over) when passed_over != nil do
    Enum.find_value(Map.get(flow, :index, []), fn
      %{type: "proposal", name: "main", approved: number, approval: %{stage_id: id}}
      when is_integer(number) and id == flow.explore_id ->
        number

      _artifact ->
        nil
    end)
  end

  defp proposal_version(_flow, _stage, _passed_over), do: nil

  @doc """
  entries/3 is the rows of the table of a stage's workflow entries on its tab, in the order
  of the stage's sequence, for a work item on a track and a stage with at least one entry
  the runner passed over in the take in (`skips`, `Apiary.Stages.skips/1`); `[]` for any
  other stage, for Explore's, and for a stage where a workflow occurs twice in the sequence.
  Each row is `%{item:, kind:, name:, note:, rounds:, attempt:, shows:, skip:}`: `item` the
  entry as the document has it (a workflow entry, or a loop with its body), `kind` `:entry`
  or `:loop`, `name` the entry's name, else its workflow, `note` the workflow under a name
  that differs from it, or a loop's workflows, `rounds` a loop's limit, `attempt` and `shows`
  those of the newest run of the entry among `flow.runs` (nil for none), and `skip` the
  record of the runner passing the entry over, nil for none. Every entry of a loop's body
  that was passed over has a record, so the loop's `skip` is the first of them.
  """
  @spec entries(map, map, [map]) :: [map]
  def entries(flow, stage, skips) do
    skips = Enum.filter(skips, &(&1.stage_id == stage.id))
    runs = Enum.filter(Map.get(flow, :runs, []), &(&1.stage_id == stage.id))

    # A record of a skipped entry has no position: where a workflow occurs twice in the
    # sequence, its row cannot tell which entry a run or a record belongs to.
    if skips == [] or is_nil(Map.get(flow, :track)) or stage.id == flow.explore_id or
         repeats?(stage.sequence) do
      []
    else
      for {item, index} <- Enum.with_index(stage.sequence),
          row = entry(item, index, stage, runs, skips) do
        row
      end
    end
  end

  defp repeats?(sequence) do
    names =
      Enum.flat_map(sequence, fn
        %{"loop" => %{"body" => body}} -> for %{"workflow" => name} <- body, do: name
        %{"workflow" => name} -> [name]
        _item -> []
      end)

    length(names) != length(Enum.uniq(names))
  end

  defp entry(%{"loop" => %{"body" => body} = loop} = item, index, stage, runs, skips) do
    workflows = for %{"workflow" => workflow} <- body, do: workflow
    newest = newest_run(runs, workflows)

    %{
      item: item,
      kind: :loop,
      name: nil,
      note: Enum.join(workflows, ", "),
      rounds: Runner.rounds(%{"sequence" => stage.sequence}, index) || loop["rounds"],
      attempt: newest && newest.attempt,
      shows: newest && newest.shows,
      skip: Enum.find(skips, &(&1.workflow in workflows))
    }
  end

  defp entry(%{"workflow" => workflow} = item, _index, _stage, runs, skips) do
    name = item["name"]
    newest = newest_run(runs, [workflow])

    %{
      item: item,
      kind: :entry,
      name: if(is_binary(name) and name != "", do: name, else: workflow),
      note: if(is_binary(name) and name not in ["", workflow], do: workflow),
      rounds: nil,
      attempt: newest && newest.attempt,
      shows: newest && newest.shows,
      skip: Enum.find(skips, &(&1.workflow == workflow))
    }
  end

  defp entry(_item, _index, _stage, _runs, _skips), do: nil

  @doc """
  track_line/1 is the track the work item is on and where an approval put it there:
  `%{name:, gate:}`, `gate` the name of the stage whose gate the approval passed, nil where
  no approval that the stages passed over whole record made it (a move forward, or a stage
  that no track skipped); nil for a work item on no track.
  """
  @spec track_line(map) :: %{name: String.t(), gate: String.t() | nil} | nil
  def track_line(%{track: %{id: id, name: name}} = flow) do
    gate =
      Enum.find_value(Map.get(flow, :stage_skips, []), fn
        %{approved: %{kind: :approve, track_id: ^id, stage_id: stage_id}} ->
          Enum.find_value(flow.stages, &(&1.id == stage_id && &1.name))

        _skip ->
          nil
      end)

    %{name: name, gate: gate}
  end

  def track_line(_flow), do: nil

  @doc """
  fast_track?/1 is whether the work item of `flow` is on the track `fast-track`. A work item
  on another track, and one on none, is not.
  """
  @spec fast_track?(map) :: boolean
  def fast_track?(%{track: %{id: "fast-track"}}), do: true
  def fast_track?(_flow), do: false

  # The newest of `runs` (the stage's runs of the take in, `Workflow.page/2`'s `runs`,
  # newest first) of one of `workflows`; nil for none.
  defp newest_run(runs, workflows), do: Enum.find(runs, &(&1.workflow in workflows))

  # The stage of a run, a question or a version: one with none belongs to Explore.
  defp stage_of(row, flow), do: Map.get(row, :stage_id) || flow.explore_id

  defp runs(flow, stage, runs), do: Enum.filter(runs, &(stage_of(&1, flow) == stage.id))

  defp take_ins(flow, stage, take_ins) do
    for {take_in, place} <- Enum.with_index(take_ins, 1),
        runs = runs(flow, stage, take_in.runs),
        runs != [] do
      take_in |> Map.put(:runs, runs) |> Map.put(:place, place) |> with_skips(flow, stage.id)
    end
  end

  # The take in with the workflow entries the runner passed over in it, of the stage
  # `stage_id`, or of every stage for nil (`Apiary.Stages.earlier_skips/1`).
  defp with_skips(take_in, flow, stage_id) do
    skips =
      for skip <- Map.get(flow, :earlier_skips, []),
          skip.take_in == take_in[:take_in],
          stage_id in [nil, skip.stage_id],
          do: skip

    Map.put(take_in, :skips, skips)
  end

  # The questions of `stage`: those that the Questions tab groups under it, in every state
  # (`ApiaryWeb.WorkItemComponents.question_groups/3`). A question of a stage that the
  # process no longer has is Explore's, as a run with no stage is.
  defp questions(flow, stage, questions) do
    known = MapSet.new(flow.stages, & &1.id)

    Enum.filter(questions, fn question ->
      group = if MapSet.member?(known, question[:stage_id]), do: question.stage_id
      (group || flow.explore_id) == stage.id
    end)
  end

  # Whether the current stage's tab has the questions open: some question is open, of any
  # stage. The form of the Open questions frame, on this tab and on the Questions tab,
  # then has the decisions of the current stage, so the tab's Decisions frame is empty.
  defp waiting?(flow, stage, questions),
    do: stage.id == flow.stage.id and Enum.any?(questions, &(&1.state == :open))

  # Explore's tab lists the review comments on the proposal; a stage's tab those on a
  # version of its outputs made at the stage, among the stage's `artifacts`, each with its
  # target (`:target`), as its card shows it. A review comment on the whole round of a run
  # is on the tab of the stage that run ran at.
  defp comments(flow, stage, comments, artifacts) do
    made =
      for %{name: "main"} = a <- artifacts,
          v <- a.versions,
          into: MapSet.new(),
          do: {a.type, v.number}

    for comment <- comments, comment_at?(comment, flow, stage, made) do
      if is_integer(comment[:run]) or stage.id == flow.explore_id,
        do: comment,
        else: Map.put(comment, :target, StageComponents.type_words(comment.artifact))
    end
  end

  defp comment_at?(%{run: run} = comment, flow, stage, _made) when is_integer(run),
    do: stage_of(comment, flow) == stage.id

  defp comment_at?(comment, %{explore_id: id}, %{id: id}, _made),
    do: comment[:artifact] in [nil, "proposal"]

  defp comment_at?(comment, _flow, stage, made),
    do:
      comment[:artifact] in Map.get(stage, :outputs, []) and
        MapSet.member?(made, {comment[:artifact], comment[:version]})

  # The artifacts with a version made at the stage, each with those versions.
  defp artifacts(flow, stage, artifacts) do
    for artifact <- artifacts,
        versions = Enum.filter(artifact.versions, &(stage_of(&1, flow) == stage.id)),
        versions != [] do
      %{artifact | versions: versions}
    end
  end

  defp version_of(artifacts, type) do
    artifacts
    |> Enum.filter(&(&1.type == type and &1.name == "main"))
    |> Enum.flat_map(& &1.versions)
    |> Enum.map(& &1.number)
    |> Enum.max(fn -> nil end)
  end

  # The approval marks of the artifacts the tab lists.
  defp index(index, artifacts) do
    shown = MapSet.new(artifacts, &{&1.type, &1.name})
    Enum.filter(index, &MapSet.member?(shown, {&1.type, &1.name}))
  end

  # frames/1 is the output frames of the tab of a stage with no `verification` output: one
  # for each version an approval of the stage records (`Apiary.Stages.gate_frames/3`), in
  # that order, as `%{type:, name:, version:, open:, writer:, kind:}`, the first one `open`.
  # `version` is the version's number; `writer`, for the frame's caption, is the short name
  # of the member who made it where a person did (`ApiaryWeb.People.short/1`), "Former
  # member" for an account that is gone, else nil. `kind` is `:output`. The review
  # comments, the document a review comment is written to, have no frame.
  @spec frames([map]) :: [map]
  def frames(recorded) do
    recorded
    |> Enum.reject(&(&1.type == "review-comments"))
    |> Enum.with_index()
    |> Enum.map(fn {%{type: type, name: name, version: version}, place} ->
      %{
        type: type,
        name: name,
        version: version.number,
        open: place == 0,
        writer: if(version.writer == :person, do: member(version.user)),
        kind: :output
      }
    end)
  end

  defp member(user), do: People.short(People.email(user) || People.former_member())

  # verify?/1 is whether `stage` has an output of the type `verification`: its tab has the
  # frames of `verify_frames/2`, every other stage's tab those of `frames/1`.
  @spec verify?(map) :: boolean
  def verify?(stage), do: "verification" in stage.outputs

  # of_take_in/2 is `artifacts` with only the versions that a run of the take in
  # `take_in` wrote, as the newest outputs of a stage count them
  # (`Apiary.WorkItems.ExploreView.newest_outputs/3`); an artifact with none is left out.
  # A version a person added has no run, so it is left out too.
  @spec of_take_in([map], integer | nil) :: [map]
  def of_take_in(artifacts, take_in) do
    for artifact <- artifacts,
        versions = Enum.filter(artifact.versions, &match?(%{run: %{take_in: ^take_in}}, &1)),
        versions != [],
        do: %{artifact | versions: versions}
  end

  # newest/3 is `newest`, the newest version of each type's `main` (`verify_frames/2`), with
  # each type of the tab's `artifacts` that has no `main` there: the highest number among
  # the newest version of each of its names that a run of the take in `take_in` wrote
  # (`of_take_in/2`) and no member cancelled (`Apiary.Artifacts.newest_counted/1`).
  @spec newest(%{String.t() => pos_integer}, [map], integer | nil) ::
          %{String.t() => pos_integer}
  def newest(newest, artifacts, take_in) do
    for artifact <- of_take_in(artifacts, take_in),
        not Map.has_key?(newest, artifact.type),
        %{number: number} = version <- [Artifacts.newest_counted(artifact)],
        not Map.get(version, :withdrawn, false),
        reduce: newest do
      acc -> Map.update(acc, artifact.type, number, &max(&1, number))
    end
  end

  # verify_frames/2 is the output frames of the tab of `stage`, a stage with a
  # `verification` output (`verify?/1`), in its order, with the newest version a run of the
  # take in pushed at the stage of each type (`newest`): `%{type:, name:, version:, open:,
  # writer:, kind:}`, `name` `main` and `writer` nil, every frame open. A type with no such
  # version has no frame, nor do the review comments. The scenarios' films and pictures
  # (`ApiaryWeb.WorkItemLive.VerifyTab.media/0`) share one frame of the kind `:scenarios`,
  # in the place of the first, with the highest of their versions; each output other than
  # the verification is a frame of the kind `:row`, with its version and its artifact rows,
  # and no text; the verification's frame is of the kind `:output`.
  @spec verify_frames(map, %{String.t() => pos_integer}) :: [map]
  def verify_frames(stage, newest) do
    types = Enum.filter(stage.outputs, &(Map.has_key?(newest, &1) and &1 != "review-comments"))

    media = Enum.filter(types, &(&1 in VerifyTab.media()))

    types
    |> Enum.reject(&(&1 in Enum.drop(media, 1)))
    |> Enum.map(fn type ->
      frame = %{
        type: type,
        name: "main",
        version: newest[type],
        open: true,
        writer: nil,
        kind: :output
      }

      cond do
        type in media ->
          %{frame | kind: :scenarios, version: media |> Enum.map(&newest[&1]) |> Enum.max()}

        type != "verification" ->
          %{frame | kind: :row}

        true ->
          frame
      end
    end)
  end

  @doc """
  with_inputs/2 is `outputs`, the output frames (`frames/1` or `verify_frames/2`), then
  `inputs`, the input frames (`input_frames/2`), folded, but for an input of a type that an
  output frame already shows: the Scenarios frame shows both the films and the pictures
  (`ApiaryWeb.WorkItemLive.VerifyTab.media/0`). With no output frame, it is `inputs` as
  they are.
  """
  @spec with_inputs([map], [map]) :: [map]
  def with_inputs([], inputs), do: inputs

  def with_inputs(outputs, inputs) do
    shown = for output <- outputs, type <- shown_types(output), into: MapSet.new(), do: type
    outputs ++ for(input <- inputs, input.type not in shown, do: %{input | open: false})
  end

  defp shown_types(%{kind: :scenarios}), do: VerifyTab.media()
  defp shown_types(%{type: type}), do: [type]

  @doc """
  input_frames/2 is, for the current stage's tab where the stage started no run
  (`StageComponents.started_no_run?/1`), the frames of the newest versions of the stage's
  inputs: the person at the gate reads what earlier stages made. `[]` for any other tab.
  The first is `open`, as `frames/1` opens the first of the outputs. A frame's `kind` is
  `:output`.
  """
  @spec input_frames(map, map) :: [map]
  def input_frames(flow, stage) do
    if stage.id == flow.stage.id and StageComponents.started_no_run?(flow) do
      flow.inputs
      |> Enum.filter(&(is_integer(&1.version) and &1.type != "review-comments"))
      |> Enum.with_index()
      |> Enum.map(fn {input, place} ->
        %{
          type: input.type,
          name: "main",
          version: input.version,
          open: place == 0,
          writer: nil,
          kind: :output
        }
      end)
    else
      []
    end
  end

  # approved/3 is `frames` of `stage`, each with the approval it shows (`approval`), nil for
  # none, from `index`, the approval marks (`flow.index`). Only the first frame shows an
  # approval: the newest approval of its version, where the gate of `stage`
  # recorded it as a gate `none` (vault 0252), with no member (`automatic`) or with the
  # member who accepted the escalation that ended the stage (`by`). The gate is read from
  # the approval, not from the stage today: a later process version may change it. A
  # person gate's approval shows none.
  @spec approved([map], map, [map]) :: [map]
  def approved(frames, stage, index) do
    frames
    |> Enum.with_index()
    |> Enum.map(fn {frame, place} ->
      Map.put(frame, :approval, if(place == 0, do: approval(frame, stage, index)))
    end)
  end

  defp approval(%{type: type, version: version} = frame, stage, index) do
    name = Map.get(frame, :name, "main")

    with %{approved: ^version, approval: %{stage_id: id} = approval} when id == stage.id <-
           Enum.find(index, &(&1.type == type and &1.name == name)),
         true <- approval.automatic or approval.gate_none do
      approval
    else
      _none -> nil
    end
  end
end
