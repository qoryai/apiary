defmodule Apiary.Dispatches.HarnessReads do
  # The live reads a claim makes of the Qory harness (`Apiary.Harnesses.Qory.git/0`) and
  # of the built-in harness (`Apiary.Harnesses.Builtin`), and what a failed read does to
  # the run. A claim reads the commit the `ref` of a run's base is at now, so the run's
  # documents have that commit (`Apiary.Dispatches.Handover`).
  #
  # **Outside the claim's transaction.** `prefetch/3` reads, before the claim locks
  # anything, the walks of the waiting runs the claim may take, without a lock, and
  # resolves each distinct address and ref once, in one read session of at most 10
  # seconds and 32 requests (`Apiary.Harnesses.PublicGit.session/3`). Inside the
  # transaction, `at_claim/3` reads only that map: a claim makes no network call between
  # its first lock and its commit. A base at a full commit id needs no read.
  # A successful read is kept for that claim alone: the next claim reads again.
  #
  # **A run of a process version.** A run with a process version (`process_version_id`)
  # composes the harness commit that version was made from, or the nearest version it was
  # based on that has one (`Apiary.Processes.harness_template/1`), with no read: a base
  # of the Qory harness with no version or on a branch, and a base of a harness
  # repository on a branch, where the record is of that harness (`source` `qory` and the
  # Qory harness's address as its `git`, else `repository` with the base's `git`). A base
  # at a tag or a commit, a record of another harness or of an address the instance set
  # before, and a run with no such record, are read as below.
  #
  # **A failed read.**
  #
  #   * a branch, a tag or a commit the repository does not have (`ref_missing`): the run
  #     ends at once;
  #   * a read that timed out, met the host's limit on reads, found no host, or met a
  #     server error (`unreachable`, `rate_limited`, `server_error`): the run stays
  #     queued, and later claims read it again. Its walk records the time of the first
  #     such failure (`read_failed_at`), and of the last one (`updated_at`); once the
  #     reads still fail 10 minutes after the first, the run ends. A successful read
  #     clears `read_failed_at`;
  #   * a read the session's budget left no time or no request for (`late`,
  #     `no_calls`): the claim's limit, not the host's. The run stays queued, with no
  #     failure recorded;
  #   * any other failure: the run ends at once;
  #   * a run whose walk the claim did not read before its transaction, queued since:
  #     the run stays queued for the next claim, with no failure recorded.
  #
  # **No read for a run not known to be a run of Explore.** While no files of the Qory
  # harness are kept, `prefetch/3` leaves out the walks of runs at the step `explore`
  # with a workflow whose `explore` is not set: only the kept files tell whether such a
  # run is a run of Explore, the claim leaves it queued anyway, and a read stores no
  # files. A run with `explore` not set at another step, or with no workflow, is known
  # without the files, and is read.
  #
  # **No read again within 30 seconds.** `prefetch/3` leaves out an address and ref whose
  # walks all have a failed read, the last one less than 30 seconds before: their runs
  # stay queued, as runs the claim did not read.
  #
  # A run that ends is ended by the claim, as one whose read failed
  # (`Apiary.Dispatches.Handover`): `harness_unresolved`, with the code `ref_missing` or
  # `harness_unreadable`.
  #
  # A test sets `config :apiary, Apiary.Dispatches.HarnessReads, read_ms: ms` or
  # `read_requests: n` (`Application.put_env/3`, in a module that is not async), to see
  # the session's time or requests run out.
  @moduledoc false

  import Ecto.Query

  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.{PublicGit, Qory, RunHarness}
  alias Apiary.{Processes, Repo}

  @read_ms 10_000
  @read_requests 32
  @wait_seconds 600
  @again_seconds 30

  @typedoc "What `prefetch/3` read: the result of each address and ref it resolved."
  @type reads :: %{optional({String.t(), Qory.ref()}) => {:ok, String.t()} | {:error, term}}

  @typedoc """
  What a claim does with a run's harness: `:none`, no live read for its walk; `{:ok,
  commit}`, the commit its documents have; `{:error, failure}`, the run ends; `:wait`, the
  run stays queued.
  """
  @type read :: :none | {:ok, String.t()} | {:error, Qory.failure()} | :wait

  @doc false
  # prefetch/3 is the reads of the walks of the waiting runs of `query`, the claim's
  # query of the next waiting run (`Apiary.Dispatches.waiting_query/2`), at most `max` of
  # them, read without a lock and before the claim's transaction, at `now`.
  @spec prefetch(Ecto.Query.t(), pos_integer, DateTime.t()) :: reads
  def prefetch(query, max, now) do
    walks =
      Repo.all(
        from [run: r] in known_runs(exclude(exclude(query, :lock), :limit)),
          join: h in RunHarness,
          on: h.dispatch_run_id == r.id,
          where: h.state == :resolved and h.origin in [:setting, :builtin],
          limit: ^max,
          select: {h, r.process_version_id}
      )

    templates =
      for {_walk, id} <- walks, uniq: true, into: %{}, do: {id, Processes.harness_template(id)}

    pairs =
      walks
      |> Enum.flat_map(fn {walk, version_id} ->
        case read_of(walk, Map.fetch!(templates, version_id)) do
          {:read, pair} -> [{pair, walk}]
          _none -> []
        end
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.reject(fn {_pair, walks} -> Enum.all?(walks, &failed_lately?(&1, now)) end)
      |> Enum.map(&elem(&1, 0))

    case pairs do
      [] ->
        %{}

      pairs ->
        PublicGit.session(
          Qory.budget(read_env(:read_ms, @read_ms), read_env(:read_requests, @read_requests)),
          fn ->
            Map.new(pairs, fn {git, ref} = pair -> {pair, Qory.resolve(git, ref)} end)
          end
        )
    end
  end

  # The runs of `query` a claim may take: with no files of the Qory harness kept, a run at
  # the step `explore` with a workflow and `explore` not set is not known to be a run of
  # Explore, and stays queued (`Apiary.Stages.known_explore/1`); a read of its walk
  # stores no files, so the claim leaves its walk out.
  defp known_runs(query) do
    git = Qory.git()

    if Repo.exists?(from f in "qory_harness_files", where: f.git == ^git),
      do: query,
      else:
        from([run: r] in query,
          where: not (is_nil(r.explore) and r.step == "explore" and not is_nil(r.workflow))
        )
  end

  @doc false
  # at_claim/3 is what the claim does with the harness of `run`, which it holds locked,
  # by the map `reads` from `prefetch/3` alone, at `now` (the moduledoc). A first read
  # that timed out, met the host's limit or a server error is recorded on the run's walk,
  # and a successful read clears it.
  @spec at_claim(DispatchRun.t(), reads, DateTime.t()) :: read
  def at_claim(%DispatchRun{id: id, process_version_id: version_id}, reads, now) do
    walk =
      Repo.one(from h in RunHarness, where: h.dispatch_run_id == ^id and h.state == :resolved)

    case walk && read_of(walk, Processes.harness_template(version_id)) do
      {:read, pair} -> decided(walk, Map.fetch(reads, pair), now)
      {:commit, commit} -> {:ok, commit}
      _none -> :none
    end
  end

  defp decided(walk, {:ok, {:ok, commit}}, now) do
    if walk.read_failed_at, do: failed_at!(walk, read_failed_at: nil, updated_at: now)
    {:ok, commit}
  end

  # The session's budget, not the host: as a run the claim did not read.
  defp decided(_walk, {:ok, {:error, {:unreadable, cause, _hop}}}, _now)
       when cause in [:late, :no_calls],
       do: :wait

  defp decided(walk, {:ok, {:error, {:unreadable, cause, _hop}} = failed}, now) do
    cond do
      not passing?(cause) ->
        failed

      is_nil(walk.read_failed_at) ->
        failed_at!(walk, read_failed_at: now, updated_at: now)
        :wait

      DateTime.diff(now, walk.read_failed_at) < @wait_seconds ->
        failed_at!(walk, updated_at: now)
        :wait

      true ->
        failed
    end
  end

  defp decided(_walk, {:ok, {:error, _failure} = failed}, _now), do: failed
  defp decided(_walk, :error, _now), do: :wait

  defp failed_at!(walk, changes) do
    {1, _rows} = Repo.update_all(from(h in RunHarness, where: h.id == ^walk.id), set: changes)
  end

  # A failure that a later read can pass.
  defp passing?({:unreachable, _seconds}), do: true
  defp passing?(cause), do: cause in [:rate_limited, :server_error]

  # Whether the last failed read of `walk` (the moduledoc) is less than 30 seconds
  # before `now`.
  defp failed_lately?(%RunHarness{read_failed_at: nil}, _now), do: false

  defp failed_lately?(%RunHarness{updated_at: at}, now),
    do: DateTime.diff(now, at) < @again_seconds

  # What a claim reads for `walk`, of a run whose process version has the harness record
  # `template` (nil for none): `{:commit, commit}` for a base that follows a branch of the
  # harness `template` records (the moduledoc), with that record's commit;
  # `{:read, {git, ref}}` for a base of the built-in harness, or of the Qory harness at a
  # branch or a tag; `{:commit, commit}` for one at a full commit id; `:none` for any
  # other walk, whose base is at the commit its pin records.
  defp read_of(
         %RunHarness{origin: origin, document: %{"extends" => %{"git" => git} = base}} = walk,
         template
       )
       when origin in [:setting, :builtin] do
    ref = base["ref"] || Qory.default_branch()

    cond do
      commit = origin == :setting and process_commit(walk, git, ref, template) ->
        {:commit, commit}

      origin == :setting and git != Qory.git() ->
        :none

      Qory.commit?(ref) ->
        {:commit, ref}

      origin == :builtin ->
        {:read, {git, {:branch, ref}}}

      walk.ref_kind in [:branch, :tag] ->
        {:read, {git, {walk.ref_kind, ref}}}

      true ->
        {:read, {git, {:branch, ref}}}
    end
  end

  defp read_of(_walk, _template), do: :none

  # The commit of `template` where the walk's base, at `git` and `ref`, follows a branch of
  # the harness `template` records; else nil.
  defp process_commit(walk, git, ref, %{"commit" => commit} = template) do
    qory? = git == Qory.git()

    following? =
      not Qory.commit?(ref) and
        (walk.ref_kind == :branch or (qory? and is_nil(walk.ref_kind)))

    same? =
      if qory?,
        do: template["source"] == "qory" and template["git"] == git,
        else: template["source"] == "repository" and template["git"] == git

    if following? and same? and Qory.commit?(commit), do: commit
  end

  defp process_commit(_walk, _git, _ref, _template), do: nil

  defp read_env(key, default) do
    :apiary
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
