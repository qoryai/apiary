defmodule Apiary.Submissions do
  # The submissions of a work item, one for each run that stored a version of the type in
  # `submit.type` of the work item's process version, as the Submissions list on a stage's
  # tab and the Submission block of a run's page show them. Left out of the documentation
  # at `/docs` (`@moduledoc false`), as the work items are.
  #
  # A stored submission is a JSON object (`ref`, `repositories`, ...) that the workspace's
  # type for it checks, so every member here is read as untrusted: a member that is not of
  # the form below is left out, and what is read is bounded (`@max_*`).
  #
  # Each `repositories` entry has `system`, `path`, `commit` (the head, a hex id of 40 or
  # 64 characters), `commit_url`, `draft` and, where the harness wrote the run's commits,
  # `base` (`{commit, commit_url}`) and `commits` (`[{commit, step, commit_url}]`, in the
  # order the run made them, the last the head). `step` is the ledger step that made the
  # commit, `deliverable:<id>` or `fix:<finding id>`. A link is kept only when it is an
  # `https` address of at most 2048 characters. The head is marked on the last entry whose
  # `commit` is the repository's `commit`; a list whose last entry is another commit is
  # shown as it was read, with no mark when no entry is the head.
  #
  # `list_cached/5` and `for_run/4` take and return a cache, a map the caller keeps between
  # reads: a stored version never changes, so what was read of it is kept by its public id,
  # and each call returns the entries it used, so the cache does not grow.
  #
  # The text of a change comes from the Deliverables table of the work item's plan, the
  # artifact `main` of the plan type that the version's run recorded
  # (`run_harnesses.plan_type`, the `plan` of its workflow in the stack file). A run with
  # no plan type, or one whose plan has no such table, shows no text: no other type is
  # read instead.
  @moduledoc false

  import Ecto.Query

  alias Apiary.{Artifacts, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.Collection
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.RunHarness
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
  # The most of a stored submission and of a plan that is read.
  @max_json_bytes 1_048_576
  @max_plan_bytes 262_144
  @max_plan_rows 200
  # The characters of a stored text that are kept, and of an address.
  @max_text 200
  @max_url 2048

  @commit ~r/\A([0-9a-f]{40}|[0-9a-f]{64})\z/
  @id ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/

  @typedoc """
  What a commit's step says: `{:change, id, text}` for a deliverable of the run's plan,
  `text` the plan's text of the change or nil, `{:fix, finding}` for a fix of a review
  finding, and nil for any other step.
  """
  @type step :: {:change, String.t(), String.t() | nil} | {:fix, String.t()} | nil

  @doc """
  The type of the work item's submissions: `submit.type` of its process version's harness
  template, nil for none.
  """
  @spec type(WorkItem.t()) :: String.t() | nil
  def type(%WorkItem{} = work_item), do: Artifacts.submit_type(work_item)

  @doc """
  `type/1`, with the answer kept in `cache` for a work item whose process version is
  fixed (`process_version_id`), so a page that draws again asks once. `{type, cache}`.
  """
  @spec type_cached(WorkItem.t(), map) :: {String.t() | nil, map}
  def type_cached(%WorkItem{process_version_id: id} = work_item, cache) when is_binary(id) do
    case Map.fetch(cache, {:type, id}) do
      {:ok, type} ->
        {type, cache}

      :error ->
        type = type(work_item)
        {type, Map.put(cache, {:type, id}, type)}
    end
  end

  def type_cached(work_item, cache), do: {type(work_item), cache}

  @doc """
  The rows of the work item's submissions of `type`, newest first, from `artifacts`
  (`Apiary.Artifacts.list/1`). A version a cancelled run wrote and a withdrawal are left
  out. `[]` for none.

  A row is `%{id:, number:, run:, run_id:, workspace_id:, stage_id:, at:, approved:, ref:,
  repositories:}`: the version's public id and number, its run's number, public id and
  workspace (nil where no run is registered), the stage it was made in, when its run ended
  (when it was stored, for a run that has not ended), whether a gate decision approved it,
  the branch (`ref`), and one `t:repository/0` for each repository.

  With `only`, a list of version public ids, the rows of those versions alone.
  """
  @spec list(WorkItem.t(), String.t() | nil, [Artifacts.Artifact.t()], [String.t()] | nil) ::
          [map]
  def list(work_item, type, artifacts, only \\ nil),
    do: work_item |> list_cached(type, artifacts, only, %{}) |> elem(0)

  @doc """
  `list/4` with a cache: `{rows, cache}`. A version's stored file is read once and a
  plan's file once, whatever number of rows use them; a file is read only when a row needs
  it (a plan only for a row with a `deliverable:` step, and the versions that only an
  earlier row's `Base` would need only when a wanted row has a base).
  """
  @spec list_cached(
          WorkItem.t(),
          String.t() | nil,
          [Artifacts.Artifact.t()],
          [String.t()] | nil,
          map
        ) :: {[map], map}
  def list_cached(work_item, type, artifacts, only, cache)

  def list_cached(%WorkItem{} = work_item, type, artifacts, only, cache) when is_binary(type) do
    all =
      case Enum.find(artifacts, &(&1.type == type and &1.name == "main")) do
        %{versions: versions} -> versions
        nil -> []
      end

    listed = all |> counted() |> within(only)
    included = MapSet.new(listed, & &1.public_id)
    ends = run_ends(listed)
    approved = approved(work_item, listed)
    state = {cache, %{}}

    {wanted, others} =
      listed |> Enum.reverse() |> Enum.split_with(&(is_nil(only) or &1.public_id in only))

    {wanted_reads, state} = read_all(wanted, state)
    needs_others? = Enum.any?(wanted_reads, fn {_id, read} -> based?(read) end)
    {other_reads, state} = if needs_others?, do: read_all(others, state), else: {[], state}
    reads = Map.new(wanted_reads ++ other_reads)

    # The plans are read only for the versions with a `deliverable:` step to word.
    texted = Enum.filter(listed, &changes?(Map.get(reads, &1.public_id)))
    plan_types = plan_types(texted)
    plans = plans(artifacts, Map.values(plan_types))

    {rows, _heads, state} =
      listed
      |> Enum.reverse()
      |> Enum.reduce({[], [], state}, fn version, {rows, heads, state} ->
        read = Map.get(reads, version.public_id)

        if is_nil(read) do
          {rows, heads, state}
        else
          hidden? = hidden_before?(all, version, included)

          {repositories, state} =
            with_texts(read.repositories, plans[plan_types[version.run_id]], version, state)

          repositories = based(repositories, heads, hidden?)
          run = version.run && version.run.run

          row = %{
            id: version.public_id,
            number: version.number,
            run: run && run.number,
            run_id: run && run.public_id,
            workspace_id: version.workspace_id,
            stage_id: version.stage_id,
            at: Map.get(ends, run && run.public_id) || version.inserted_at,
            approved: MapSet.member?(approved, version.public_id),
            ref: read.ref,
            repositories: repositories
          }

          {[row | rows], heads(row) ++ heads, state}
        end
      end)

    {old, new} = state
    types = Map.filter(old, fn {{kind, _id}, _type} -> kind == :type end)
    {Enum.filter(rows, &(is_nil(only) or &1.id in only)), Map.merge(types, new)}
  end

  def list_cached(_work_item, _type, _artifacts, _only, cache), do: {[], cache}

  @doc """
  What a run's page shows of its submissions, with the cache of `list_cached/5`:
  `{shown, cache}`, `shown` `%{type:, rows:, names:}`, the submission type's name, the rows
  (`list/4`) of the versions of that type the run stored, by the version's public id, and
  the integration name for each system of a draft (`system_names/2`). Nil for a run no
  queue started, a run whose process version names no submit type, a run that stored no
  version of it, and a reader of another workspace. `outputs` is the versions the run
  pushed (`Apiary.Runs.Preparation`'s `outputs`). A run that stored no version of its work
  item's submission names costs no query.
  """
  @spec for_run(Scope.t(), Run.t(), [map], map) ::
          {%{type: String.t(), rows: %{String.t() => map}, names: %{String.t() => String.t()}}
           | nil, map}
  def for_run(%Scope{} = scope, %Run{dispatch_run_id: id} = run, outputs, cache)
      when is_binary(id) do
    if Enum.any?(outputs, &(&1.name == "main")) do
      {type, cache} = run_type(id, cache)
      ids = for %{type: ^type, name: "main", public_id: public_id} <- outputs, do: public_id

      with true <- is_binary(type) and ids != [],
           %WorkItem{} = work_item <- Preparation.work_item(scope, run),
           {[_row | _more] = rows, reads} <-
             list_cached(work_item, type, Artifacts.list(work_item), ids, cache) do
        shown = %{
          type: type,
          rows: Map.new(rows, &{&1.id, &1}),
          names: system_names(work_item, draft_systems(rows))
        }

        {shown, reads}
      else
        _none -> {nil, cache}
      end
    else
      {nil, cache}
    end
  end

  def for_run(_scope, _run, _outputs, cache), do: {nil, cache}

  # The submit type of the run of the queue `id`, kept in the cache: a run's process version
  # does not change.
  defp run_type(id, cache) do
    case Map.fetch(cache, {:type, id}) do
      {:ok, type} ->
        {type, cache}

      :error ->
        type =
          case Repo.get(DispatchRun, id) do
            %DispatchRun{} = dispatch_run -> Artifacts.submit_type(dispatch_run)
            nil -> nil
          end

        {type, Map.put(cache, {:type, id}, type)}
    end
  end

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

  @doc """
  The drafts of a stored submission, `content` its decoded JSON: `%{path:, number:, url:}`
  for each repository that has a numbered draft with an `https` link, in the order of the
  repositories, read as the list reads them (at most 20 repositories, a text of at most 200
  characters). `[]` for anything else. Pure: no read of the database or the store.
  """
  @spec repositories(term) :: [%{path: String.t(), number: pos_integer, url: String.t()}]
  def repositories(%{"repositories" => list}) do
    for repository <- read_repositories(list),
        {:draft, %{number: number, url: url}} <- [repository.draft],
        is_binary(url),
        do: %{path: repository.path, number: number, url: url}
  end

  def repositories(_content), do: []

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

  # Whether a submission older than `version` is not among the rows: beyond the window, or
  # written by a run a member cancelled. Its head may be the base.
  defp hidden_before?(all, version, included) do
    Enum.any?(all, fn other ->
      other.number < version.number and not other.withdrawn and
        not MapSet.member?(included, other.public_id)
    end)
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

  ## The cache

  # fetch/3 is the value of `key` in the cache of the caller, else in what this call read,
  # else `fun.()`; the value is kept in what this call returns.
  defp fetch({old, new}, key, fun) do
    cond do
      Map.has_key?(new, key) ->
        {Map.fetch!(new, key), {old, new}}

      Map.has_key?(old, key) ->
        value = Map.fetch!(old, key)
        {value, {old, Map.put(new, key, value)}}

      true ->
        value = fun.()
        {value, {old, Map.put(new, key, value)}}
    end
  end

  ## The stored files

  # `{id, read}` for each version, `read` `%{ref:, repositories:}`.
  defp read_all(versions, state) do
    Enum.map_reduce(versions, state, fn version, state ->
      {read, state} = fetch(state, {:version, version.public_id}, fn -> read_version(version) end)
      {{version.public_id, read}, state}
    end)
  end

  defp based?(%{repositories: repositories}), do: Enum.any?(repositories, & &1.base)

  # A stored file of a size the type allows is decoded; a larger one, or one that cannot be
  # read, gives a row with no repository.
  defp read_version(%{files: [%{size: size} | _rest]} = version) when size <= @max_json_bytes do
    content = StageArtifacts.read_json(version) || %{}

    %{
      ref: text_of(content["ref"]),
      repositories: read_repositories(content["repositories"])
    }
  end

  defp read_version(_version), do: %{ref: nil, repositories: []}

  ## The plan's changes

  # The versions of the plans of the work item that count, oldest first, by the plan's
  # type: the artifacts named `main` of the types in `types`.
  defp plans(artifacts, types) do
    for %{name: "main", type: type, versions: versions} <- artifacts,
        type in types,
        into: %{} do
      {type, versions |> counted() |> Enum.reverse()}
    end
  end

  # Whether a read version has a commit with a `deliverable:` step whose text is not yet
  # set.
  defp changes?(nil), do: false

  defp changes?(%{repositories: repositories}) do
    Enum.any?(repositories, fn repository ->
      Enum.any?(repository.commits, &match?(%{step: {:change, _id, nil}}, &1))
    end)
  end

  # The plan type each run of `versions` recorded (`run_harnesses.plan_type`), by the
  # run's id; a run with no walk or no type is not in the map. One query.
  defp plan_types(versions) do
    ids = for %{run_id: id} <- versions, is_binary(id), uniq: true, do: id

    if ids == [] do
      %{}
    else
      Repo.all(
        from h in RunHarness,
          where: h.dispatch_run_id in ^ids and not is_nil(h.plan_type),
          select: {h.dispatch_run_id, h.plan_type}
      )
      |> Map.new()
    end
  end

  # The repositories of a row with the text of each change, where a commit has a
  # `deliverable:` step: from the version of `plans`, the run's plan type's versions
  # (nil for a run with no plan type), that was newest when the version was stored, read
  # only now, and once.
  defp with_texts(repositories, plans, version, state) do
    ids =
      for repository <- repositories,
          %{step: {:change, id, nil}} <- repository.commits,
          uniq: true,
          do: id

    if ids == [] do
      {repositories, state}
    else
      plan =
        (plans || [])
        |> Enum.filter(&(DateTime.compare(&1.inserted_at, version.inserted_at) != :gt))
        |> List.last()

      {texts, state} =
        case plan do
          nil -> {%{}, state}
          plan -> fetch(state, {:plan, plan.public_id}, fn -> changes(plan) end)
        end

      repositories =
        for repository <- repositories do
          commits =
            for entry <- repository.commits do
              case entry do
                %{step: {:change, id, nil}} -> %{entry | step: {:change, id, texts[id]}}
                entry -> entry
              end
            end

          %{repository | commits: commits}
        end

      {repositories, state}
    end
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
  The text of each change of a plan, by the id of its deliverable: the cells Id and
  Change of the first 200 rows of the table under `## Deliverables`, each text of at most
  200 characters. A row with another id form, or with no change text, is left out.
  """
  @spec deliverables(String.t()) :: %{String.t() => String.t()}
  def deliverables(markdown) when is_binary(markdown) do
    markdown
    |> String.split(~r/\r?\n/)
    |> Enum.drop_while(&(String.trim(&1) != "## Deliverables"))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(&1, "## ")))
    |> Enum.flat_map(&row/1)
    |> Enum.take(@max_plan_rows)
    |> Map.new()
  end

  defp row(line) do
    case line |> String.trim() |> cells() do
      [id, change | _rest] ->
        if id != "Id" and Regex.match?(@id, id) and change != "",
          do: [{id, cut(change)}],
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
  `line` `{:head, run}` where an earlier row's submission has the commit as its head,
  `:start` where no earlier submission can have it, and `:unknown` where a version that is
  not a row (beyond the window, or a cancelled run's) may have it. `commits` is the entries
  listed, `%{commit:, short:, url:, step:, head:}` (`step` as `t:step/0`), and `count` how
  many there are in all. `draft` is `{:draft, %{number:, url:, title:}}`, `title` nil for
  none, `:none` for a submission that records why it sent none, nil for neither.
  """
  @type repository :: map

  defp read_repositories(list) when is_list(list) do
    list |> Enum.take(@max_repositories) |> Enum.flat_map(&repository/1)
  end

  defp read_repositories(_other), do: []

  defp repository(%{"system" => system, "path" => path, "commit" => commit} = entry)
       when is_binary(system) and is_binary(path) do
    if commit?(commit) do
      {commits, count} = commits(entry["commits"], commit)

      [
        %{
          system: cut(system),
          path: cut(path),
          commit: commit,
          short: short(commit),
          url: link(entry["commit_url"]),
          base: base(entry["base"]),
          commits: commits,
          count: count,
          draft: draft(entry["draft"])
        }
      ]
    else
      []
    end
  end

  defp repository(_entry), do: []

  defp base(%{"commit" => commit} = base) do
    if commit?(commit),
      do: %{commit: commit, short: short(commit), url: link(base["commit_url"]), line: :start}
  end

  defp base(_other), do: nil

  # The entries of the list that are commits, and how many there are. Only the entries that
  # are kept are made into maps: the first 100, or the first 99 and the head where the head
  # is a later entry.
  defp commits(list, head) when is_list(list) do
    valid = for %{"commit" => commit} = entry <- list, commit?(commit), do: entry
    count = length(valid)

    head_at =
      valid
      |> Enum.with_index()
      |> Enum.filter(fn {entry, _index} -> entry["commit"] == head end)
      |> List.last()
      |> case do
        {_entry, index} -> index
        nil -> nil
      end

    keep = kept(count, head_at)

    entries =
      for {entry, index} <- Enum.with_index(valid), index in keep do
        %{
          commit: entry["commit"],
          short: short(entry["commit"]),
          url: link(entry["commit_url"]),
          step: step(entry["step"]),
          head: index == head_at
        }
      end

    {entries, count}
  end

  defp commits(_other, _head), do: {[], 0}

  defp kept(count, _head_at) when count <= @max_commits, do: 0..(count - 1)//1

  defp kept(_count, head_at) when is_integer(head_at) and head_at >= @max_commits - 1,
    do: Enum.to_list(0..(@max_commits - 2)) ++ [head_at]

  defp kept(_count, _head_at), do: 0..(@max_commits - 1)

  defp step("deliverable:" <> id) do
    if Regex.match?(@id, id), do: {:change, id, nil}
  end

  defp step("fix:" <> finding) do
    if Regex.match?(@id, finding), do: {:fix, finding}
  end

  defp step(_other), do: nil

  defp draft(%{"number" => number, "url" => url} = draft)
       when is_integer(number) and number > 0 do
    title = if is_binary(draft["title"]), do: cut(draft["title"])
    {:draft, %{number: number, url: link(url), title: title}}
  end

  defp draft(%{"none" => reason}) when is_binary(reason), do: :none
  defp draft(_other), do: nil

  # The `Base` line of each repository: the head of an earlier row's submission when its
  # commit is that row's, in the same repository; else where the branch starts, unless a
  # version that is no row (`hidden?`) may have the commit as its head.
  defp based(repositories, heads, hidden?) do
    Enum.map(repositories, fn
      %{base: %{commit: commit} = base} = repository ->
        line =
          case Enum.find(heads, &(&1.commit == commit and &1.where == where(repository))) do
            %{run: run} when is_integer(run) -> {:head, run}
            _none -> if hidden?, do: :unknown, else: :start
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

  defp cut(text), do: String.slice(text, 0, @max_text)

  # An `https` address of at most 2048 characters with a host and no user name or password;
  # nil for any other.
  defp link(url) when is_binary(url) and byte_size(url) <= @max_url do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil}}
      when is_binary(host) and host != "" ->
        url

      _other ->
        nil
    end
  end

  defp link(_other), do: nil

  defp text_of(text) when is_binary(text), do: cut(text)
  defp text_of(_other), do: nil
end
