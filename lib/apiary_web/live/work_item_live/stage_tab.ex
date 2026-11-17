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

  alias Apiary.Stages.Runner
  alias ApiaryWeb.WorkItemLive.StageComponents

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
  #   * `passed_over`: the record of the runner passing the stage over whole in the take in
  #     (`Apiary.Stages.stage_skips/1`), nil for none;
  #   * `take_ins`: the earlier take ins with the stage's runs and skips, each with its
  #     `place` among all of them, from 1;
  #   * `questions`: on the current stage's tab, every open question and the closed ones the
  #     stage's runs wrote; on another tab, the closed ones its runs wrote;
  #   * `questions_version`, `review_comments`, `artifacts` and `index`, each of the stage;
  #   * `foot`: on Explore's tab at a later stage, the record block of Explore's runs.
  #
  # On the Ticket tab and the Thread, `review_comments` are the current stage's. A version
  # with no stage belongs to Explore, as a run with none does.
  @spec view(atom | String.t(), map | nil, map) :: map
  def view(_tab, nil, read) do
    %{
      stage: nil,
      runs: [],
      skips: [],
      entries: [],
      passed_over: nil,
      take_ins: read.earlier_take_ins,
      questions: read.questions,
      questions_version: read.questions_version,
      review_comments: read.review_comments,
      artifacts: read.artifacts,
      index: [],
      foot: nil
    }
  end

  def view(tab, flow, read) when tab in [:ticket, :thread] do
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
      take_ins: Enum.map(read.earlier_take_ins, &with_skips(&1, flow, nil)),
      questions: read.questions,
      questions_version: read.questions_version,
      review_comments: read.review_comments,
      artifacts: read.artifacts,
      index: [],
      foot: nil
    }
  end

  defp view(flow, run, stage, read) do
    runs = runs(flow, stage, read.earlier_runs ++ List.wrap(run && run[:workspace_id] && run))
    artifacts = artifacts(flow, stage, read.artifacts)
    explore? = stage.id == flow.explore_id

    %{
      stage: stage,
      runs: runs,
      skips: Enum.filter(Map.get(flow, :skips, []), &(&1.stage_id == stage.id)),
      entries: entries(flow, stage, Map.get(flow, :skips, [])),
      passed_over: passed_over(flow, stage, runs),
      take_ins: take_ins(flow, stage, read.earlier_take_ins),
      questions: questions(flow, stage, read.questions),
      questions_version: version_of(artifacts, "questions"),
      review_comments: comments(flow, stage, read.review_comments, artifacts),
      artifacts: artifacts,
      index: index(flow.index, artifacts),
      foot: if(explore? and not flow.at_explore, do: %{runs: runs, latest: nil, pieces: nil})
    }
  end

  # The record of the runner passing `stage` over whole, while the work item is not in the
  # stage and the stage has no run: a person's move into it later runs it after all.
  defp passed_over(flow, stage, runs) do
    if stage.id != flow.stage.id and runs == [],
      do: Enum.find(Map.get(flow, :stage_skips, []), &(&1.stage_id == stage.id))
  end

  @doc """
  entries/3 is the rows of the table of a stage's workflow entries on its tab, in the order
  of the stage's sequence, for a stage with at least one entry the runner passed over in
  the take in (`skips`, `Apiary.Stages.skips/1`); `[]` for any other stage, and for Explore's.
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
    runs = Enum.filter(flow.runs, &(&1.stage_id == stage.id))

    if skips == [] or stage.id == flow.explore_id do
      []
    else
      for {item, index} <- Enum.with_index(stage.sequence),
          row = entry(item, index, stage, runs, skips) do
        row
      end
    end
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

  defp questions(flow, stage, questions) do
    current? = stage.id == flow.stage.id

    Enum.filter(questions, fn question ->
      if question.state == :open,
        do: current? or (is_nil(current(flow)) and asked_at?(question, flow, stage)),
        else: asked_at?(question, flow, stage)
    end)
  end

  defp asked_at?(question, flow, stage), do: stage_of(question, flow) == stage.id

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

  # frames/2 is the output frames of `stage`, in its order, with the newest version a run of
  # the take in pushed at the stage of each type (`newest`): `%{type:, version:, open:}`,
  # the first one `open`. A type with no such version has no frame, nor do the review
  # comments, the document a review comment is written to.
  @spec frames(map, %{String.t() => pos_integer}) :: [map]
  def frames(stage, newest) do
    stage.outputs
    |> Enum.filter(&(Map.has_key?(newest, &1) and &1 != "review-comments"))
    |> Enum.with_index()
    |> Enum.map(fn {type, place} -> %{type: type, version: newest[type], open: place == 0} end)
  end

  @doc """
  input_frames/2 is, for the current stage's tab where the stage started no run
  (`StageComponents.started_no_run?/1`), the frames of the newest versions of the stage's
  inputs: the person at the gate reads what earlier stages made. `[]` for any other tab.
  The first is `open`, as `frames/2` opens the first of the outputs.
  """
  @spec input_frames(map, map) :: [map]
  def input_frames(flow, stage) do
    if stage.id == flow.stage.id and StageComponents.started_no_run?(flow) do
      flow.inputs
      |> Enum.filter(&(is_integer(&1.version) and &1.type != "review-comments"))
      |> Enum.with_index()
      |> Enum.map(fn {input, place} ->
        %{type: input.type, version: input.version, open: place == 0}
      end)
    else
      []
    end
  end

  # approved/3 is `frames` of `stage`, each with the approval it shows (`approval`), nil for
  # none, from `index`, the approval marks (`flow.index`). Only the first frame, the open
  # one, shows an approval: the newest approval of its version, where the gate of `stage`
  # recorded it as a gate `none` (vault 0252), with no member (`automatic`) or with the
  # member who accepted the escalation that ended the stage (`by`). The gate is read from
  # the approval, not from the stage today: a later process version may change it. A
  # person gate's approval shows none.
  @spec approved([map], map, [map]) :: [map]
  def approved(frames, stage, index) do
    Enum.map(frames, &Map.put(&1, :approval, if(&1.open, do: approval(&1, stage, index))))
  end

  defp approval(%{type: type, version: version}, stage, index) do
    with %{approved: ^version, approval: %{stage_id: id} = approval} when id == stage.id <-
           Enum.find(index, &(&1.type == type and &1.name == "main")),
         true <- approval.automatic or approval.gate_none do
      approval
    else
      _none -> nil
    end
  end
end
