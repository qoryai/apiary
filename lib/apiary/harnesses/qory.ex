defmodule Apiary.Harnesses.Qory do
  # The Qory harness: the harness repository a workspace of a Qory type starts with, at
  # the address the instance sets (`QORY_HARNESS_URL`, `git/0`). Qory Apiary keeps no copy
  # of it and no commit of it: a workspace's harness settings choose a branch, a tag or a
  # commit (`Apiary.Stacks`), and with none chosen, the branch `main`.
  #
  # ## Reading the repository
  #
  # Over git's smart-HTTP protocol, anonymously (`Apiary.Harnesses.PublicGit`), as `git
  # ls-remote` and `git fetch` read it:
  #
  #   * `resolve/1` names the commit a branch, a tag or a commit is at now, with one
  #     `ls-refs` and no fetch: a branch only under `refs/heads/`, a tag only under
  #     `refs/tags/`. A machine's claim of a run calls it, before the claim's transaction
  #     (`Apiary.Dispatches.HarnessReads`), so the run starts on the commit the ref is at
  #     then.
  #   * `read/1` resolves the ref, then keeps the files of that commit in
  #     `qory_harness_files`, where it has none yet, and the commit the ref is at in
  #     `qory_harness_heads`, by its full name (`refs/heads/main`). The files are the
  #     root `qory.yaml`, the `process.yaml` of the module `software-factory`
  #     (`template_module/0`), and the `qory-stack.yaml` of each stack `qory.yaml`
  #     exports, at most 32; a stack whose name is not one path segment is left out, with
  #     one line in the log. One read takes at most 60 seconds and 64 requests. A new workspace and a save of the workspace's harness
  #     settings call it; so does `Apiary.Harnesses.QoryRefresh`, for `main` and each
  #     branch a harness choice follows, every 5 minutes and once at boot.
  #
  # A failed read is `{:ref_missing, ref}` for a ref the repository does not have, or
  # `{:unreadable, cause, hop}`, with the cause of `Apiary.Harnesses.PublicGit`, or
  # `:invalid` for files that break the harness format, and the host and port it failed
  # at (nil for none).
  #
  # ## Reading the stored files
  #
  # Every page, the workspace types and the stages read the stored files only, never the
  # repository: `head/1` is the commit a branch or tag was at when last read, `current/0`
  # that of `main`, and `workspace_commit/1` the commit of a workspace's harness settings.
  # `template/1`, `workflows/2`, `stacks/1` and `texts/1` read a commit's files, and are
  # nil or empty for a commit with none stored. What they decode is kept in memory by
  # commit (`Apiary.Harnesses.Qory.Memo`), as a commit's files never change.
  @moduledoc false

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.Harnesses.{PublicGit, Reader}
  alias Apiary.Harnesses.Qory.Memo
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Repo
  alias Apiary.Stacks
  alias Apiary.Stacks.Stack

  @default_branch "main"
  @default_stack "core"
  @template "software-factory"
  @root "qory.yaml"
  @commit ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @max_stacks 32
  @read_ms 60_000
  @read_requests 64

  @typedoc """
  Why a read of the Qory harness failed: a ref the repository does not have, or a read
  that failed, with its cause and the host and port it failed at, nil for none.
  """
  @type failure ::
          {:ref_missing, String.t()}
          | {:unreadable, PublicGit.cause() | :invalid, PublicGit.hop() | nil}

  @typedoc "A version of the Qory harness: a branch, a tag or a full commit id."
  @type version :: {:branch | :tag | :commit, String.t()}

  @typedoc """
  A ref to resolve: a version, `{:ref, name}` for a name of no known kind, read as qory
  reads one (a tag before a branch), or a name, a full commit id or else a branch.
  """
  @type ref :: version | {:ref, String.t()} | String.t()

  ## The repository

  @doc false
  # git/0 is the address of the Qory harness's repository, `QORY_HARNESS_URL`
  # (`config/runtime.exs`).
  @spec git() :: String.t()
  def git, do: :apiary |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(:url)

  @doc false
  # default_branch/0 is the branch a workspace whose harness settings choose none
  # follows: `main`.
  @spec default_branch() :: String.t()
  def default_branch, do: @default_branch

  @doc false
  # default_stack/0 is the stack of the Qory harness a workspace composes when its type's
  # template names none: `core`.
  @spec default_stack() :: String.t()
  def default_stack, do: @default_stack

  @doc false
  # template_module/0 is the module of the Qory harness with the software type's
  # template.
  @spec template_module() :: String.t()
  def template_module, do: @template

  @doc false
  # commit?/1 is whether `ref` is a full commit id: 40 or 64 lower-case hex digits.
  @spec commit?(term) :: boolean
  def commit?(ref), do: is_binary(ref) and Regex.match?(@commit, ref)

  @doc false
  # resolve/1 is the commit `ref` (`t:ref/0`) is at now in the repository, read with no
  # fetch and kept nowhere: `{:ok, commit}` or `{:error, failure}`, the failure with the
  # ref's name. A full commit id is taken as it is once the host serves the repository.
  # resolve/2 is the same for the public repository at `git`.
  @spec resolve(ref) :: {:ok, String.t()} | {:error, failure}
  def resolve(ref), do: resolve(git(), ref)

  @doc false
  @spec resolve(String.t(), ref) :: {:ok, String.t()} | {:error, failure}
  def resolve(git, ref) when is_binary(git) do
    {name, full} = names(ref)

    case PublicGit.commit(git, full) do
      {:ok, commit} -> {:ok, commit}
      {:error, :version_not_found, _hop} -> {:error, {:ref_missing, name}}
      {:error, cause, hop} -> {:error, {:unreadable, cause, hop}}
    end
  end

  # The name of `ref` as a person gave it, and as the host lists it: a branch under
  # `refs/heads/`, a tag under `refs/tags/`, a commit and a name of no kind as they are.
  defp names({:branch, name}), do: {name, "refs/heads/" <> name}
  defp names({:tag, name}), do: {name, "refs/tags/" <> name}
  defp names({kind, name}) when kind in [:commit, :ref], do: {name, name}
  defp names(ref) when is_binary(ref), do: ref |> version() |> names()

  # A name as a version: a full commit id, else a branch.
  defp version(ref) when is_binary(ref),
    do: if(commit?(ref), do: {:commit, ref}, else: {:branch, ref})

  defp version(ref), do: ref

  @doc false
  # budget/2 is a budget for `Apiary.Harnesses.PublicGit.session/3`: `ms` milliseconds
  # and `requests` requests in total, each request at most the time left.
  @spec budget(pos_integer, pos_integer) :: PublicGit.budget()
  def budget(ms, requests) do
    deadline = System.monotonic_time(:millisecond) + ms
    left = :counters.new(1, [])
    :counters.put(left, 1, requests)

    fn ->
      time = deadline - System.monotonic_time(:millisecond)

      cond do
        :counters.get(left, 1) <= 0 ->
          {:error, :no_calls}

        time <= 0 ->
          {:error, :late}

        true ->
          :counters.sub(left, 1, 1)
          {:ok, min(time, PublicGit.request_seconds() * 1000)}
      end
    end
  end

  @doc false
  # read/1 resolves `ref` (`resolve/1`) and keeps the files of its commit and the commit
  # a branch or a tag is at (the moduledoc), within one budget: `{:ok, commit}` or
  # `{:error, failure}`.
  @spec read(ref) :: {:ok, String.t()} | {:error, failure}
  def read(ref) do
    git = git()
    ref = version(ref)

    PublicGit.session(budget(@read_ms, @read_requests), fn ->
      with {:ok, commit} <- resolve(git, ref),
           :ok <- store(git, commit, ref) do
        with {kind, _name} when kind in [:branch, :tag] <- ref,
             do: put_head(git, ref |> names() |> elem(1), commit)

        {:ok, commit}
      end
    end)
  end

  defp store(git, commit, ref) do
    if stored?(git, commit), do: :ok, else: fetch(git, commit, ref)
  end

  defp fetch(git, commit, ref) do
    {name, _full} = names(ref)

    with {:ok, root} <- file(git, commit, name, @root),
         {:ok, exports} <- exports(root),
         {:ok, template} <- template_path(exports),
         stacks = Enum.map(valid_stacks(exports, git, commit), &Reader.stack_file(exports, &1)),
         {:ok, files} <- files(git, commit, name, Enum.uniq([template | stacks])) do
      now = DateTime.utc_now()

      rows =
        for {path, content} <- [{@root, root} | files] do
          %{git: git, commit: commit, path: path, content: content, inserted_at: now}
        end

      {_count, _rows} = Repo.insert_all("qory_harness_files", rows, on_conflict: :nothing)
      :ok
    end
  end

  # The stacks `exports` lists that a read keeps: the first `@max_stacks` whose name is
  # one path segment (`Apiary.Harnesses.Reader.segment?/1`). With `git` and `commit`, a
  # stack left out is one line in the log.
  defp valid_stacks(exports, git \\ nil, commit \\ nil) do
    {valid, refused} = Enum.split_with(exports.stacks, &Reader.segment?/1)
    {kept, over} = Enum.split(valid, @max_stacks)

    if git && (refused != [] or over != []) do
      Logger.warning(
        "the Qory harness exports stacks a read leaves out git=#{git} commit=#{commit} " <>
          "not_one_segment=#{inspect(refused)} over_#{@max_stacks}=#{inspect(over)}"
      )
    end

    kept
  end

  defp file(git, commit, ref, path) do
    case PublicGit.read(git, commit, path) do
      {:ok, nil, _commit} when path == @root -> {:error, {:unreadable, :invalid, nil}}
      {:ok, content, _commit} -> {:ok, content}
      {:error, :version_not_found, _hop} -> {:error, {:ref_missing, ref}}
      {:error, cause, hop} -> {:error, {:unreadable, cause, hop}}
    end
  end

  defp files(git, commit, ref, paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, files} ->
      case file(git, commit, ref, path) do
        {:ok, content} -> {:cont, {:ok, [{path, content} | files]}}
        {:error, _failure} = failed -> {:halt, failed}
      end
    end)
  end

  defp exports(root) do
    case Reader.exports(root) do
      {:ok, exports} -> {:ok, exports}
      _none_or_invalid -> {:error, {:unreadable, :invalid, nil}}
    end
  end

  defp template_path(exports) do
    case Reader.module_file(exports, @template, "process.yaml") do
      {:ok, path} -> {:ok, path}
      {:error, _reason} -> {:error, {:unreadable, :invalid, nil}}
    end
  end

  # A ref still at the stored commit writes nothing: a plain read takes no row lock, so a
  # transaction that reads the harness does not hold the row until it ends. An upsert
  # locks the row even when an `ON CONFLICT ... WHERE` leaves it unchanged. `read_at` is
  # then the time of the last read that found a new commit.
  defp put_head(git, ref, commit) do
    stored =
      Repo.one(
        from h in "qory_harness_heads",
          where: h.git == ^git and h.ref == ^ref,
          select: h.commit
      )

    if stored != commit do
      {_count, _rows} =
        Repo.insert_all(
          "qory_harness_heads",
          [%{git: git, ref: ref, commit: commit, read_at: DateTime.utc_now()}],
          on_conflict: {:replace, [:commit, :read_at]},
          conflict_target: [:git, :ref]
        )
    end

    :ok
  end

  ## The stored files

  @doc false
  # head/1 is the commit the branch or tag `ref` (`t:ref/0`) was at when it was last read
  # (`read/1`), nil for one never read. A full commit id is itself, where its files are
  # kept.
  @spec head(ref) :: String.t() | nil
  def head(ref) do
    git = git()

    case version(ref) do
      {:commit, commit} ->
        if stored?(git, commit), do: commit

      {kind, _name} = version when kind in [:branch, :tag] ->
        {_name, full} = names(version)

        Repo.one(
          from h in "qory_harness_heads",
            where: h.git == ^git and h.ref == ^full,
            select: h.commit
        )

      _other ->
        nil
    end
  end

  @doc false
  # current/0 is the commit `main` was at when it was last read, nil before the first
  # read.
  @spec current() :: String.t() | nil
  def current, do: head({:branch, @default_branch})

  @doc false
  # newest/0 is the commit whose files a read kept last, nil before any read: what a
  # reader takes where the commit it wants has no files kept.
  @spec newest() :: String.t() | nil
  def newest do
    git = git()

    Repo.one(
      from f in "qory_harness_files",
        where: f.git == ^git and f.path == @root,
        order_by: [desc: f.inserted_at, desc: f.commit],
        limit: 1,
        select: f.commit
    )
  end

  @doc false
  # version_commit/1 is the stored commit of `version` (`head/1`), nil for none.
  @spec version_commit(version | nil) :: String.t() | nil
  def version_commit({kind, name} = version)
      when kind in [:branch, :tag, :commit] and is_binary(name),
      do: head(version)

  def version_commit(_none), do: nil

  @doc false
  # chosen_commit/1 is the stored commit of a workspace's harness choice of the Qory
  # harness, as `Apiary.Stacks.Sources.chosen/1` gives it: of its version, else of its
  # pin, a commit or a branch.
  @spec chosen_commit(%{optional(:version) => term, optional(:pin) => term}) ::
          String.t() | nil
  def chosen_commit(%{version: {kind, name}}) when kind in [:branch, :tag, :commit],
    do: version_commit({kind, name})

  def chosen_commit(%{pin: pin}) when is_binary(pin), do: head(version(pin))
  def chosen_commit(_chosen), do: nil

  @doc false
  # row_version/1 is the version of the Qory harness a harness choice row of the Qory
  # harness has: its version's kind and name, else the `ref` of its document, a commit or
  # a branch, else the default branch; the default branch for no row too. The row's
  # choice decides, never the address its document has, which may be one the instance
  # set before (`git/0`). Nil for a row of a harness repository.
  @spec row_version(Stack.t() | nil) :: version | nil
  def row_version(nil), do: {:branch, @default_branch}

  def row_version(%Stack{choice: :qory, version_kind: kind, version_name: name})
      when kind in [:branch, :tag, :commit] and is_binary(name),
      do: {kind, name}

  def row_version(%Stack{choice: :qory, harness: harness}) do
    case is_binary(harness) && Reader.document(harness) do
      {:ok, %{"extends" => %{"ref" => ref}}} when is_binary(ref) -> version(ref)
      _none -> {:branch, @default_branch}
    end
  end

  def row_version(%Stack{}), do: nil

  @doc false
  # workspace_commit/1 is the stored commit of the Qory harness that `workspace`'s
  # harness settings choose, as the organisation shares them where the workspace sets
  # none (`Apiary.Stacks.workspace_harness/2`), `main`'s with neither. A workspace on a
  # harness repository reads `main`'s. Nil where that commit's files are not kept: a
  # reader that must have a commit then takes `newest/0`.
  @spec workspace_commit(Workspace.t() | Ecto.UUID.t()) :: String.t() | nil
  def workspace_commit(%Workspace{} = workspace) do
    organisation = %Organisation{id: workspace.organisation_id}

    case row_version(Stacks.workspace_harness(workspace, organisation)) do
      nil -> current()
      version -> version_commit(version)
    end
  end

  def workspace_commit(workspace_id) when is_binary(workspace_id) do
    case Repo.get(Workspace, workspace_id) do
      %Workspace{} = workspace -> workspace_commit(workspace)
      nil -> current()
    end
  end

  @doc false
  # template/1 is the software type's template at `commit`, as `Reader.template/1` reads
  # it, nil for a commit with no files kept or a template the reader refuses.
  @spec template(String.t() | nil) :: Reader.template() | nil
  def template(commit) do
    decoded(commit, :template, fn files, exports ->
      with {:ok, path} <- Reader.module_file(exports, @template, "process.yaml"),
           content when is_binary(content) <- Map.get(files, path),
           {:ok, template} <- Reader.template(content) do
        template
      else
        _none -> nil
      end
    end)
  end

  @doc false
  # texts/1 is the name, summary and description of the template at `commit`, nil for
  # none (`template/1`).
  @spec texts(String.t() | nil) ::
          %{name: String.t(), summary: String.t(), description: String.t()} | nil
  def texts(commit) do
    case template(commit) do
      %{} = template -> Map.take(template, [:name, :summary, :description])
      nil -> nil
    end
  end

  @doc false
  # stacks/1 is the stacks `qory.yaml` exports at `commit`, empty for a commit with no
  # files kept.
  @spec stacks(String.t() | nil) :: [String.t()]
  def stacks(commit),
    do: decoded(commit, :stacks, fn _files, exports -> valid_stacks(exports) end) || []

  @doc false
  # workflows/2 is the workflow names the stack `stack` lists at `commit`, sorted; empty
  # for a stack it does not export, and for a commit with no files kept.
  @spec workflows(String.t() | nil, String.t() | nil) :: [String.t()]
  def workflows(commit, stack) when is_binary(stack) do
    decoded(commit, {:workflows, stack}, fn files, exports ->
      with true <- stack in valid_stacks(exports),
           content when is_binary(content) <- Map.get(files, Reader.stack_file(exports, stack)),
           {:ok, %{workflows: workflows}} <- Reader.stack(content) do
        workflows |> Map.keys() |> Enum.sort()
      else
        _none -> []
      end
    end) || []
  end

  def workflows(_commit, nil), do: []

  # What `decode` makes of the files of `commit` and their exports, kept by commit; nil
  # for a commit with no files kept.
  defp decoded(commit, key, decode) when is_binary(commit) do
    git = git()

    Memo.fetch({git, commit, key}, fn ->
      with %{@root => root} = files when is_binary(root) <- stored_files(git, commit),
           {:ok, exports} <- Reader.exports(root) do
        {:ok, decode.(files, exports)}
      else
        _none -> :none
      end
    end)
  end

  defp decoded(_commit, _key, _decode), do: nil

  defp stored?(git, commit) do
    Repo.exists?(
      from f in "qory_harness_files",
        where: f.git == ^git and f.commit == ^commit and f.path == @root
    )
  end

  defp stored_files(git, commit) do
    Repo.all(
      from f in "qory_harness_files",
        where: f.git == ^git and f.commit == ^commit,
        select: {f.path, f.content}
    )
    |> Map.new()
  end

  ## Words

  @doc false
  # cause_words/1 is why a read failed, as one clause, for the words that end "failed:
  # <cause>".
  @spec cause_words(PublicGit.cause() | :invalid) :: String.t()
  def cause_words({:unreachable, seconds}),
    do: gettext("the connection timed out after %{n} seconds", n: seconds)

  def cause_words(:rate_limited), do: gettext("the host returned 429 Too Many Requests")

  def cause_words(:server_error),
    do: gettext("the harness host returned a server error (HTTP 500)")

  def cause_words(:not_found),
    do: gettext("the host serves nothing public at that address")

  def cause_words(:not_allowed),
    do: gettext("the host resolves to an address that is not public")

  def cause_words(:too_large),
    do: gettext("the source is larger than 16 MiB, or a harness file is larger than 0.25 MiB")

  def cause_words(cause) when cause in [:late, :no_calls], do: gettext("the read ran out of time")
  def cause_words(:not_text), do: gettext("a harness file is not text")
  def cause_words(:version_not_found), do: gettext("the host does not have the version")
  def cause_words(:invalid), do: gettext("the harness files break the harness format")

  def cause_words(_failed),
    do: gettext("the host returned something other than a git source over HTTPS")

  @doc false
  # cause_value/1 is a failure's cause as a run's record keeps it, a map of text keys;
  # cause_of/1 reads it back.
  @spec cause_value(PublicGit.cause() | :invalid) :: map
  def cause_value({:unreachable, seconds}), do: %{"cause" => "unreachable", "seconds" => seconds}
  def cause_value(cause) when is_atom(cause), do: %{"cause" => Atom.to_string(cause)}

  @causes ~w(not_found not_allowed rate_limited server_error late no_calls too_large
             failed version_not_found not_text invalid)

  @doc false
  @spec cause_of(map | nil) :: PublicGit.cause() | :invalid
  def cause_of(%{"cause" => "unreachable", "seconds" => seconds}) when is_integer(seconds),
    do: {:unreachable, seconds}

  def cause_of(%{"cause" => cause}) when cause in @causes, do: String.to_existing_atom(cause)
  def cause_of(_other), do: :failed
end
