defmodule Apiary.Submissions do
  # The submissions of a work item, one for each run that stored a version of the type in
  # `submit.type` of the work item's process version, as the Submissions list on a stage's
  # tab and the Submission block of a run's page show them. Left out of the documentation
  # at `/docs` (`@moduledoc false`), as the work items are.
  #
  # A stored submission is a JSON object (`ref`, `repositories`, ...) that the workspace's
  # type for it checks, so every member here is read as untrusted: a member that is not of
  # the form below is left out, and what is read is bounded.
  #
  # Each `repositories` entry has `system`, `path`, `commit` (the head, a hex id of 40 or
  # 64 characters), `commit_url`, `draft` and, where the harness wrote the run's commits,
  # `base` (`{commit, commit_url}`) and `commits` (`[{commit, step, commit_url}]`, in the
  # order the run made them, the head last). `step` is the ledger step that made the commit,
  # `deliverable:<id>` or `fix:<finding id>`. A link is kept only when it is an `https`
  # address.
  @moduledoc false

  import Ecto.Query

  alias Apiary.{Artifacts, Processes, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.Collection
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Nodes.Node
  alias Apiary.Runs.{Preparation, Run}
  alias Apiary.Stages.Artifacts, as: StageArtifacts
  alias Apiary.Stages.GateDecision
  alias Apiary.WorkItems.WorkItem

  # The versions read for one list, newest first. The `Base` line of a row looks for the
  # head of an earlier row among these.
  @max_versions 50
  # The commits listed for one repository: the first ones and the head.
  @max_commits 100
  @max_repositories 20
  # The most of a build plan that is read for the text of its changes.
  @max_plan_bytes 262_144
  @plan_type "build-plan"

  @commit ~r/\A([0-9a-f]{40}|[0-9a-f]{64})\z/
  @id ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/

  @typedoc """
  What a commit's step says: `{:change, id, text}` for a deliverable of the build plan,
  `text` the plan's text of the change or nil, `{:fix, finding}` for a fix of a review
  finding, and nil for any other step.
  """
  @type step :: {:change, String.t(), String.t() | nil} | {:fix, String.t()} | nil

  @doc """
  The type of the work item's submissions: `submit.type` of its process version's harness
  template, nil for none.
  """
  @spec type(WorkItem.t()) :: String.t() | nil
  def type(%WorkItem{} = work_item) do
    case work_item |> Processes.version_for() |> Processes.harness_template() do
      %{"submit" => %{"type" => type}} when is_binary(type) -> type
      _none -> nil
    end
  end

  @doc """
  The rows of the work item's submissions of `type`, newest first, from `artifacts`
  (`Apiary.Artifacts.list/1`). A version a cancelled run wrote and a withdrawal are left
  out. `[]` for none.

  A row is `%{id:, number:, run:, run_id:, workspace_id:, stage_id:, at:, approved:, ref:,
  repositories:}`: the version's public id and number, its run's number, public id and
  workspace (nil where no run is registered), the stage it was made in, when its run ended
  (when it was stored, for a run that has not ended), whether a gate decision approved it,
  the branch (`ref`), and one `t:repository/0` for each repository.

  With `only`, a list of version public ids, the rows of those versions alone, which still
  read the earlier versions for their `Base` line.
  """
  @spec list(WorkItem.t(), String.t() | nil, [Artifacts.Artifact.t()], [String.t()] | nil) ::
          [map]
  def list(work_item, type, artifacts, only \\ nil)

  def list(%WorkItem{} = work_item, type, artifacts, only) when is_binary(type) do
    versions =
      case Enum.find(artifacts, &(&1.type == type and &1.name == "main")) do
        %{versions: versions} -> counted(versions)
        nil -> []
      end

    versions = within(versions, only)
    plans = plans(artifacts)
    ends = run_ends(versions)
    approved = approved(work_item, versions)

    # Oldest first, so that a row finds the heads of the rows before it.
    {rows, _heads} =
      versions
      |> Enum.reverse()
      |> Enum.map_reduce([], fn version, heads ->
        content = StageArtifacts.read_json(version) || %{}
        run = version.run && version.run.run
        text = plan_changes(plans, version)

        repositories =
          content |> Map.get("repositories") |> repositories(text) |> based(heads)

        row = %{
          id: version.public_id,
          number: version.number,
          run: run && run.number,
          run_id: run && run.public_id,
          workspace_id: version.workspace_id,
          stage_id: version.stage_id,
          at: Map.get(ends, run && run.public_id) || version.inserted_at,
          approved: MapSet.member?(approved, version.public_id),
          ref: text_of(content["ref"]),
          repositories: repositories
        }

        {row, heads(row) ++ heads}
      end)

    rows = Enum.reverse(rows)
    if only, do: Enum.filter(rows, &(&1.id in only)), else: rows
  end

  def list(_work_item, _type, _artifacts, _only), do: []

  @doc """
  What a run's page shows of its submissions: `%{type:, rows:, names:}`, the submission
  type's name, the rows (`list/4`) of the versions of that type the run stored, by the
  version's public id, and the integration name for each system of a draft
  (`system_names/2`). Nil for a run no queue started, a run whose process version names no
  submit type, a run that stored no version of it, and a reader of another workspace.
  `outputs` is the versions the run pushed (`Apiary.Runs.Preparation`'s `outputs`).
  """
  @spec for_run(Scope.t(), Run.t(), [map]) ::
          %{type: String.t(), rows: %{String.t() => map}, names: %{String.t() => String.t()}}
          | nil
  def for_run(%Scope{} = scope, %Run{dispatch_run_id: id} = run, outputs) when is_binary(id) do
    with %DispatchRun{} = dispatch_run <- Repo.get(DispatchRun, id),
         type when is_binary(type) <- Artifacts.submit_type(dispatch_run),
         ids = for(%{type: ^type, name: "main", public_id: public_id} <- outputs, do: public_id),
         true <- ids != [],
         %WorkItem{} = work_item <- Preparation.work_item(scope, run),
         [_row | _more] = rows <- list(work_item, type, Artifacts.list(work_item), ids) do
      %{
        type: type,
        rows: Map.new(rows, &{&1.id, &1}),
        names: system_names(work_item, draft_systems(rows))
      }
    else
      _none -> nil
    end
  end

  def for_run(_scope, _run, _outputs), do: nil

  @doc """
  The name of the integration that draws each of `systems` (`target_system` of the
  workspace's collections), by system, for the mark beside a draft's number. A system that
  no collection of the workspace names is not in the map.
  """
  @spec system_names(WorkItem.t(), [String.t()]) :: %{String.t() => String.t()}
  def system_names(_work_item, []), do: %{}

  def system_names(%WorkItem{workspace_id: workspace_id}, systems) do
    Repo.all(
      from c in Collection,
        join: a in Node,
        on: a.id == c.adapter_id,
        where: c.workspace_id == ^workspace_id and c.target_system in ^systems,
        order_by: [asc: c.inserted_at, asc: c.id],
        select: {c.target_system, coalesce(a.title, a.name)}
    )
    |> Enum.reverse()
    |> Map.new()
  end

  @doc "The systems of the drafts in `rows`, each once."
  @spec draft_systems([map]) :: [String.t()]
  def draft_systems(rows) do
    for row <- rows,
        %{draft: {:draft, _draft}, system: system} <- row.repositories,
        uniq: true,
        do: system
  end

  ## The versions

  # The versions that count: no cancelled run's, no withdrawal. Newest first.
  defp counted(versions),
    do: Enum.reject(versions, &(&1.withdrawn or Artifacts.cancelled?(&1)))

  # Up to `@max_versions`, from the newest of `only` for a read of some versions.
  defp within(versions, nil), do: Enum.take(versions, @max_versions)

  defp within(versions, only) do
    case Enum.find(versions, &(&1.public_id in only)) do
      nil ->
        []

      newest ->
        versions |> Enum.drop_while(&(&1.number > newest.number)) |> Enum.take(@max_versions)
    end
  end

  # When each run ended, by the run's public id.
  defp run_ends(versions) do
    ids = for %{run: %{run: %Run{public_id: id}}} <- versions, is_binary(id), do: id

    if ids == [] do
      %{}
    else
      Repo.all(
        from r in Run.registered(),
          where: r.public_id in ^ids and not is_nil(r.exited_at),
          select: {r.public_id, r.exited_at}
      )
      |> Map.new()
    end
  end

  # The public ids of the versions a gate decision approved.
  defp approved(%WorkItem{id: id}, versions) do
    ids = Enum.map(versions, & &1.public_id)

    Repo.all(
      from d in GateDecision,
        where: d.work_item_id == ^id and d.kind == :approve,
        select: d.versions
    )
    |> List.flatten()
    |> Enum.filter(&(&1 in ids))
    |> MapSet.new()
  end

  ## The build plan's changes

  # The versions of the work item's build plan that count, oldest first, each read once
  # when a row asks for it (`plan_changes/2`).
  defp plans(artifacts) do
    case Enum.find(artifacts, &(&1.type == @plan_type and &1.name == "main")) do
      %{versions: versions} -> versions |> counted() |> Enum.reverse()
      nil -> []
    end
  end

  # The text of each change of the plan that was newest when `version` was stored, by the
  # deliverable's id. `%{}` for none.
  defp plan_changes(plans, version) do
    plan =
      plans
      |> Enum.filter(&(DateTime.compare(&1.inserted_at, version.inserted_at) != :gt))
      |> List.last()

    if plan, do: changes(plan), else: %{}
  end

  defp changes(%{files: [%{size: size} = file | _rest]}) when size <= @max_plan_bytes do
    with {:ok, source} <- Artifacts.open_file(file),
         {:ok, text} <- read(source) do
      deliverables(text)
    else
      _error -> %{}
    end
  end

  defp changes(_plan), do: %{}

  defp read(path) when is_binary(path), do: File.read(path)
  defp read(stream), do: {:ok, stream |> Enum.to_list() |> IO.iodata_to_binary()}

  @doc """
  The text of each change of a build plan, by the id of its deliverable: the cells Id and
  Change of the rows of the table under `## Deliverables`. A row with another id form, or
  with no change text, is left out.
  """
  @spec deliverables(String.t()) :: %{String.t() => String.t()}
  def deliverables(markdown) when is_binary(markdown) do
    markdown
    |> String.split(~r/\r?\n/)
    |> Enum.drop_while(&(String.trim(&1) != "## Deliverables"))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(&1, "## ")))
    |> Enum.flat_map(&row/1)
    |> Map.new()
  end

  defp row(line) do
    case line |> String.trim() |> cells() do
      [id, change | _rest] ->
        if id != "Id" and Regex.match?(@id, id) and change != "",
          do: [{id, change}],
          else: []

      _other ->
        []
    end
  end

  # The cells of a table row, `[]` for a line that is not one.
  defp cells("|" <> rest) do
    rest
    |> String.split(~r/(?<!\\)\|/)
    |> Enum.map(&(&1 |> String.replace("\\|", "|") |> String.trim()))
  end

  defp cells(_line), do: []

  ## The repositories

  @typedoc """
  A repository of a submission: `%{system:, path:, commit:, short:, url:, base:, commits:,
  count:, draft:}`. `commit` is the head and `short` its first seven characters; `url` the
  head's address, nil for none. `base` is `%{commit:, short:, url:, line:}`, nil for none,
  `line` `:start` or `{:head, run}`, the earlier run whose submission has the commit as its
  head. `commits` is the entries listed, `%{commit:, short:, url:, step:, head:}` (`step` as
  `t:step/0`), and `count` how many there are in all. `draft` is `{:draft, %{number:, url:,
  title:}}`, `:none` for a submission that records why it sent none, nil for neither.
  """
  @type repository :: map

  defp repositories(list, changes) when is_list(list) do
    list |> Enum.take(@max_repositories) |> Enum.flat_map(&repository(&1, changes))
  end

  defp repositories(_other, _changes), do: []

  defp repository(%{"system" => system, "path" => path, "commit" => commit} = entry, changes)
       when is_binary(system) and is_binary(path) do
    if commit?(commit) do
      commits = commits(entry["commits"], commit, changes)

      [
        %{
          system: system,
          path: path,
          commit: commit,
          short: short(commit),
          url: link(entry["commit_url"]),
          base: base(entry["base"]),
          commits: bounded(commits),
          count: length(commits),
          draft: draft(entry["draft"])
        }
      ]
    else
      []
    end
  end

  defp repository(_entry, _changes), do: []

  defp base(%{"commit" => commit} = base) do
    if commit?(commit),
      do: %{commit: commit, short: short(commit), url: link(base["commit_url"]), line: :start}
  end

  defp base(_other), do: nil

  defp commits(list, head, changes) when is_list(list) do
    entries =
      Enum.flat_map(list, fn
        %{"commit" => commit} = entry ->
          if commit?(commit) do
            [
              %{
                commit: commit,
                short: short(commit),
                url: link(entry["commit_url"]),
                step: step(entry["step"], changes),
                head: false
              }
            ]
          else
            []
          end

        _other ->
          []
      end)

    # The head is the last commit that is the repository's `commit`.
    case Enum.find_index(Enum.reverse(entries), &(&1.commit == head)) do
      nil -> entries
      from_end -> List.update_at(entries, length(entries) - 1 - from_end, &%{&1 | head: true})
    end
  end

  defp commits(_other, _head, _changes), do: []

  # The first commits and the head, when there are more than `@max_commits`.
  defp bounded(commits) when length(commits) <= @max_commits, do: commits

  defp bounded(commits) do
    head = Enum.find_index(commits, & &1.head)
    last = List.last(commits)
    kept = Enum.take(commits, @max_commits - 1)

    cond do
      head && head < @max_commits - 1 -> Enum.take(commits, @max_commits)
      head -> kept ++ [Enum.at(commits, head)]
      true -> kept ++ [last]
    end
  end

  defp step("deliverable:" <> id, changes) do
    if Regex.match?(@id, id), do: {:change, id, Map.get(changes, id)}
  end

  defp step("fix:" <> finding, _changes) do
    if Regex.match?(@id, finding), do: {:fix, finding}
  end

  defp step(_other, _changes), do: nil

  defp draft(%{"number" => number, "url" => url, "title" => title})
       when is_integer(number) and number > 0 and is_binary(title) do
    {:draft, %{number: number, url: link(url), title: title}}
  end

  defp draft(%{"none" => reason}) when is_binary(reason), do: :none
  defp draft(_other), do: nil

  # The `Base` line of each repository: the head of an earlier row's submission when its
  # commit is that row's, in the same repository, else where the branch starts.
  defp based(repositories, heads) do
    Enum.map(repositories, fn
      %{base: %{commit: commit} = base} = repository ->
        line =
          case Enum.find(heads, &(&1.commit == commit and &1.where == where(repository))) do
            %{run: run} when is_integer(run) -> {:head, run}
            _none -> :start
          end

        %{repository | base: %{base | line: line}}

      repository ->
        repository
    end)
  end

  # The heads of a row's repositories, to find the `Base` of the rows after it.
  defp heads(row) do
    for repository <- row.repositories,
        do: %{commit: repository.commit, where: where(repository), run: row.run}
  end

  defp where(%{system: system, path: path}), do: {system, path}

  ## The values

  defp commit?(value), do: is_binary(value) and Regex.match?(@commit, value)
  defp short(commit), do: binary_part(commit, 0, 7)

  # An `https` address with a host and no user name or password; nil for any other.
  defp link(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil}}
      when is_binary(host) and host != "" ->
        url

      _other ->
        nil
    end
  end

  defp link(_other), do: nil

  defp text_of(text) when is_binary(text), do: text
  defp text_of(_other), do: nil
end
