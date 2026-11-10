defmodule ApiaryWeb.WorkItemLive.StageTab do
  # The work item page's stage tabs and what each one lists, from what the page already read,
  # with no further read. A stage has a tab where it runs a workflow and has a run or is
  # the current stage, whatever its name. A tab's key is the stage's id, a stage keeps its id
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

    for stage <- flow.stages,
        Runner.workflows(%{"sequence" => stage.sequence}) != [],
        stage.id == flow.stage.id or MapSet.member?(ran, stage.id) do
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
  #   * `take_ins`: the earlier take ins with the stage's runs, each with its `place` among
  #     all of them, from 1;
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

  defp view(_flow, _run, nil, read) do
    %{
      stage: nil,
      runs: read.earlier_runs,
      take_ins: read.earlier_take_ins,
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
      take_ins: take_ins(flow, stage, read.earlier_take_ins),
      questions: questions(flow, stage, read.questions),
      questions_version: version_of(artifacts, "questions"),
      review_comments: comments(flow, stage, read.review_comments, artifacts),
      artifacts: artifacts,
      index: index(flow.index, artifacts),
      foot: if(explore? and not flow.at_explore, do: %{runs: runs, latest: nil, pieces: nil})
    }
  end

  # The stage of a run, a question or a version: one with none belongs to Explore.
  defp stage_of(row, flow), do: Map.get(row, :stage_id) || flow.explore_id

  defp runs(flow, stage, runs), do: Enum.filter(runs, &(stage_of(&1, flow) == stage.id))

  defp take_ins(flow, stage, take_ins) do
    for {take_in, place} <- Enum.with_index(take_ins, 1),
        runs = runs(flow, stage, take_in.runs),
        runs != [] do
      take_in |> Map.put(:runs, runs) |> Map.put(:place, place)
    end
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
end
