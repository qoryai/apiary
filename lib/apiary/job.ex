defmodule Apiary.Job do
  @moduledoc """
  What every job runs inside: an `Oban.Worker` that knows the organisation and the
  workspace it works for.

  Work the apiary does outside a request runs as a job in Oban's durable queue on Postgres:
  a row that survives a restart, retried with backoff. A job module says `use Apiary.Job`
  with the options of `Oban.Worker` and one of its own, `:scope`, and implements
  `c:perform/2`:

      defmodule Apiary.Example.Job do
        use Apiary.Job, queue: :default, max_attempts: 5

        @impl Apiary.Job
        def perform(%Apiary.Accounts.Scope{} = scope, %Oban.Job{args: args}) do
          # acts under `scope`, through the context functions, like any other caller
          :ok
        end
      end

      Apiary.Example.Job.for_scope(scope, %{"target_id" => id}) |> Oban.insert()

  ## What a job works for

  `:scope` says which ids the job's arguments carry, as string keys:

    * `:workspace`, the default: `organisation_id` and `workspace_id`, both set.
    * `:organisation`: `organisation_id` set and `workspace_id` nil, for an organisation's
      own work.
    * `:instance`: neither, for work that is the instance's and no organisation's. It is
      chosen by name, never a job's default.

  Every id is a UUID, written back in its canonical form, and `user_id` is optional. A job
  whose arguments do not carry what its `:scope` says is refused when it is built: `new/2`
  returns an invalid changeset, which `Oban.insert/1` answers with `{:error, changeset}`.
  One that reaches the queue anyway is cancelled, not run.

  Work across the instance, such as a sweep, enqueues one job per workspace or organisation
  with `insert_per_workspace/3` or `insert_per_organisation/3`, so one workspace's failure
  does not stop the others' and each has its own retries. A sweep's job is unique, so a
  sweep that stops half way can be run again and enqueues only what is missing, whenever
  it is run again. Its `unique:` takes one of two shapes, and a sweep refuses any other:

    * **Resume**: `unique: [period: :infinity, states: :incomplete]`. A job still waiting,
      running or to be retried is not enqueued again; one that has completed is, which is
      safe, since every job may run twice.
    * **Once per run**: `unique: [period: :infinity, states: :successful, keys:
      [:organisation_id, :workspace_id, :day]]`, with a key that names the run (here the
      day, given in the sweep's `args`). A run's job is enqueued once, whether or not it
      has completed; the next run's key is new.

  Either way `fields` keeps `:args` (the default), `keys`, when given, names the ids the
  sweep is by, and `period` is `:infinity`: Oban's default of 60 seconds would enqueue
  everything again on a run a minute later.

  A job that must not be enqueued twice for the same thing says so with Oban's `unique:`,
  its `keys:` naming `organisation_id`, `workspace_id` and the job's own arguments that
  say what it is for; never `user_id`, since who asked does not make it other work.

  ## Who acts

  `c:perform/2` is given the `Apiary.Accounts.Scope` built from the arguments
  (`Apiary.Organisations.job_scope/3`): the organisation and the workspace, and the person
  whose action enqueued the job when the arguments name them as `user_id`, with their
  membership there when they still hold one. Without `user_id` the scope is the
  instance's (`Apiary.Accounts.Scope.for_instance/2`): the actor of the job's changes is
  the instance, which may what its role in `Apiary.Access` allows and nothing else. The
  scope's `origin` is the job's worker, which the audit trail records as where a change
  came from (`Apiary.Audit`). `for_scope/3` names the scope's person, when it has one. A
  job whose organisation, workspace or person no longer exists is cancelled,
  `{:cancel, :scope_gone}`, not retried; one whose arguments are wrong,
  `{:cancel, :invalid_arguments}`.

  ## Time

  A job is stopped after 25 minutes, or the `timeout:` in milliseconds its module gives
  `use Apiary.Job`, and retried as a failure. The timeout must be shorter than the time
  after which the queue's lifeline takes a job still executing to be orphaned and runs it
  again (`config/config.exs`), so a slow job is never run twice at once; a module whose
  timeout is not fails to compile. Work that needs longer is split into jobs.

  ## The log

  For as long as `c:perform/2` runs, the process's Logger metadata carries the job's
  `organisation_id`, `workspace_id` and, when they name one, `user_id`
  (`Apiary.LogMetadata`), put from the arguments
  before the scope is read, and what it held before is put back afterwards. A job that
  fails, is cancelled or is discarded is logged by `Apiary.Job.Log`, with the ids.

  Every job must be safe to run twice: a retry after a crash can repeat work that had
  already half happened.
  """

  alias Apiary.Accounts.Scope
  alias Apiary.LogMetadata
  alias Apiary.Organisations

  @typedoc "What a job works for: a workspace, an organisation alone, or the instance."
  @type scope_kind :: :workspace | :organisation | :instance

  @scope_kinds [:workspace, :organisation, :instance]
  @keys ~w(organisation_id workspace_id user_id)a
  @timeout 25 * 60_000
  @chunk 500

  @doc """
  Does the job's work under `scope`, built from its arguments. Returns what
  `c:Oban.Worker.perform/1` returns.
  """
  @callback perform(Scope.t(), Oban.Job.t()) :: Oban.Worker.result()

  defmacro __using__(opts) do
    {kind, opts} = Keyword.pop(opts, :scope, :workspace)
    {timeout, worker_opts} = Keyword.pop(opts, :timeout, @timeout)

    unless kind in @scope_kinds do
      raise ArgumentError,
            "use Apiary.Job, scope: must be one of #{inspect(@scope_kinds)}, got: #{inspect(kind)}"
    end

    quote location: :keep do
      use Oban.Worker, unquote(worker_opts)

      @behaviour Apiary.Job

      @doc false
      def __apiary_job__, do: unquote(kind)

      @doc """
      Builds the job, refused (an invalid changeset) when `args` do not carry the
      organisation and workspace ids its scope, `#{inspect(unquote(kind))}`, needs. See
      `Apiary.Job`.
      """
      # Oban's `new/1` calls this one with no options.
      @impl Oban.Worker
      def new(args, opts) when is_map(args) and is_list(opts) do
        Apiary.Job.validate(super(args, opts), unquote(kind))
      end

      @doc """
      Builds the job for `scope`: its organisation and workspace ids, and the scope's
      person as the one who enqueued it, merged over `args`. See `Apiary.Job`.
      """
      @spec for_scope(Apiary.Accounts.Scope.t(), map(), [Oban.Job.option()]) ::
              Ecto.Changeset.t()
      def for_scope(%Apiary.Accounts.Scope{} = scope, args \\ %{}, opts \\ []) do
        new(Apiary.Job.scope_args(scope, unquote(kind), args), opts)
      end

      @impl Oban.Worker
      def perform(%Oban.Job{} = job), do: Apiary.Job.perform(__MODULE__, job)

      # Checked against the lifeline when the module is compiled.
      @apiary_job_timeout Apiary.Job.check_timeout!(
                            __MODULE__,
                            unquote(timeout),
                            Application.compile_env(:apiary, [Oban, :lifeline])
                          )

      @impl Oban.Worker
      def timeout(%Oban.Job{}), do: @apiary_job_timeout
    end
  end

  @doc "How long a job may run, in milliseconds, unless its module says otherwise: 25 minutes."
  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @timeout

  @doc false
  # The job's timeout, when it is a number of milliseconds shorter than the lifeline's
  # `rescue_after` (an hour when the lifeline is on without one); raises otherwise.
  @spec check_timeout!(module(), term(), term()) :: pos_integer()
  def check_timeout!(module, timeout, lifeline) do
    unless is_integer(timeout) and timeout > 0 do
      raise ArgumentError,
            "#{inspect(module)}: use Apiary.Job, timeout: must be a positive number of " <>
              "milliseconds, got: #{inspect(timeout)}"
    end

    case rescue_after_ms(lifeline) do
      limit when is_integer(limit) and timeout >= limit ->
        raise ArgumentError,
              "#{inspect(module)}: a job's timeout (#{timeout} ms) must be shorter than the " <>
                "lifeline's rescue_after (#{limit} ms), or a slow job is run twice at once"

      _limit ->
        timeout
    end
  end

  defp rescue_after_ms(lifeline) when lifeline in [nil, false], do: nil

  defp rescue_after_ms(lifeline) when is_list(lifeline) do
    case Keyword.get(lifeline, :rescue_after, {1, :hour}) do
      ms when is_integer(ms) -> ms
      period -> Oban.Period.to_seconds(period) * 1_000
    end
  end

  defp rescue_after_ms(_lifeline), do: Oban.Period.to_seconds({1, :hour}) * 1_000

  @doc """
  Enqueues one job of `worker`, a unique `scope: :workspace` job, for every workspace on
  the instance, each with `args` and the workspace's ids. Returns how many jobs were
  inserted; a job already enqueued is not counted, so a sweep run again after it stopped
  half way enqueues what is missing.

  The workspaces are read a page at a time and each job is inserted on its own, in the
  short transaction of Oban's unique insert: nothing is held open for the whole sweep.
  `opts` are the job's, and `oban:` the Oban instance, `Oban` by default. Raises unless
  `worker` is unique in one of the two shapes the module's documentation gives, by
  `organisation_id` and `workspace_id` at least.
  """
  @spec insert_per_workspace(module(), map(), keyword()) :: {:ok, non_neg_integer()}
  def insert_per_workspace(worker, args \\ %{}, opts \\ []) do
    ensure_kind!(worker, :workspace)
    args = string_keys(args)
    ensure_unique!(worker, opts, ["organisation_id", "workspace_id"], args)
    {oban, opts} = Keyword.pop(opts, :oban, Oban)

    sweep(&Organisations.page_workspace_ids/2, oban, fn {organisation_id, workspace_id} ->
      worker.new(
        Map.merge(args, %{"organisation_id" => organisation_id, "workspace_id" => workspace_id}),
        opts
      )
    end)
  end

  @doc """
  Enqueues one job of `worker`, a unique `scope: :organisation` job, for every organisation
  on the instance, each with `args` and the organisation's id, as `insert_per_workspace/3`
  does for workspaces. Raises unless `worker` is unique by `organisation_id` at least.
  """
  @spec insert_per_organisation(module(), map(), keyword()) :: {:ok, non_neg_integer()}
  def insert_per_organisation(worker, args \\ %{}, opts \\ []) do
    ensure_kind!(worker, :organisation)
    args = string_keys(args)
    ensure_unique!(worker, opts, ["organisation_id"], args)
    {oban, opts} = Keyword.pop(opts, :oban, Oban)

    sweep(&Organisations.page_organisation_ids/2, oban, fn organisation_id ->
      worker.new(
        Map.merge(args, %{"organisation_id" => organisation_id, "workspace_id" => nil}),
        opts
      )
    end)
  end

  # A page of ids at a time, by keyset, and one job at a time: Oban's basic engine does not
  # honour `unique:` in a bulk insert, and its unique insert holds an advisory lock until
  # its transaction ends, so no transaction spans more than one job.
  defp sweep(page, oban, build, cursor \\ nil, count \\ 0) do
    {ids, next} = page.(cursor, @chunk)
    count = count + Enum.count(ids, fn id -> not Oban.insert!(oban, build.(id)).conflict? end)

    if length(ids) < @chunk, do: {:ok, count}, else: sweep(page, oban, build, next, count)
  end

  # Oban's defaults for what `unique:` leaves out.
  @unique_defaults [fields: [:args, :queue, :worker], keys: [], period: 60, states: :successful]

  # Unique in one of the two shapes of the moduledoc, and by the ids at least: jobs of two
  # workspaces that differ in nothing else must not be taken for one.
  defp ensure_unique!(worker, opts, ids, args) do
    unique =
      case Keyword.get(opts, :unique, Keyword.get(worker.__opts__(), :unique)) do
        true -> @unique_defaults
        unique when is_list(unique) -> Keyword.merge(@unique_defaults, unique)
        _none -> nil
      end

    case unique && unique_problem(unique, ids, args) do
      nil when is_list(unique) ->
        :ok

      problem ->
        raise ArgumentError,
              "#{inspect(worker)} cannot be swept: #{problem || "it is not unique"}. " <>
                "See Apiary.Job for the unique: a sweep takes"
    end
  end

  defp unique_problem(unique, ids, args) do
    keys = Enum.map(unique[:keys], &to_string/1)
    run_keys = if keys == [], do: Map.keys(args), else: keys
    run_keys = run_keys -- ["organisation_id", "workspace_id", "user_id"]

    cond do
      :args not in unique[:fields] ->
        "its unique fields must include :args, or every workspace's job is one"

      unique[:period] != :infinity ->
        "its unique period must be :infinity, or a run a period later enqueues everything again"

      keys != [] and not Enum.all?(ids, &(&1 in keys)) ->
        "its unique keys must include #{Enum.join(ids, " and ")}"

      not resume?(unique[:states]) and run_keys == [] ->
        "unique beyond incomplete jobs, it needs a key that names the run, or no later " <>
          "run enqueues anything"

      true ->
        nil
    end
  end

  defp resume?(:incomplete), do: true

  defp resume?(states) when is_list(states),
    do: Enum.all?(states, &(&1 in Oban.Job.unique_states(:incomplete)))

  defp resume?(_states), do: false

  defp ensure_kind!(worker, kind) do
    # Loaded first: a module nothing has called yet is not loaded, and exports nothing.
    unless Code.ensure_loaded?(worker) and function_exported?(worker, :__apiary_job__, 0) and
             worker.__apiary_job__() == kind do
      raise ArgumentError, "#{inspect(worker)} is not an Apiary.Job with scope: #{inspect(kind)}"
    end
  end

  @doc false
  # The arguments of a job built for a scope: `args` with string keys, and over them the
  # scope's organisation and workspace ids as `kind` needs them, and the scope's person.
  @spec scope_args(Scope.t(), scope_kind(), map()) :: map()
  def scope_args(%Scope{} = scope, kind, args) do
    ids =
      case kind do
        :workspace ->
          %{"organisation_id" => id(scope.organisation), "workspace_id" => id(scope.workspace)}

        :organisation ->
          %{"organisation_id" => id(scope.organisation), "workspace_id" => nil}

        :instance ->
          %{}
      end

    ids = if scope.user, do: Map.put(ids, "user_id", scope.user.id), else: ids
    args |> string_keys() |> Map.merge(ids)
  end

  @doc false
  # Adds an error on `:args` when they do not carry what `kind` needs; otherwise writes the
  # ids back as string keys in their canonical form.
  @spec validate(Ecto.Changeset.t(), scope_kind()) :: Ecto.Changeset.t()
  def validate(%Ecto.Changeset{} = changeset, kind) do
    args = Ecto.Changeset.get_field(changeset, :args) || %{}

    case check_args(args, kind) do
      {:ok, ids} ->
        given = Map.filter(ids, fn {key, _id} -> given?(args, key) end)
        Ecto.Changeset.put_change(changeset, :args, args |> Map.drop(@keys) |> Map.merge(given))

      {:error, message} ->
        Ecto.Changeset.add_error(changeset, :args, message)
    end
  end

  @doc false
  @spec perform(module(), Oban.Job.t()) :: Oban.Worker.result()
  def perform(worker, %Oban.Job{args: args} = job) do
    case check_args(args, worker.__apiary_job__()) do
      {:ok, %{"organisation_id" => organisation_id, "workspace_id" => workspace_id} = ids} ->
        previous = LogMetadata.get()
        LogMetadata.put_ids(organisation_id, workspace_id, ids["user_id"])

        try do
          case Organisations.job_scope(organisation_id, workspace_id, ids["user_id"]) do
            {:ok, scope} ->
              worker.perform(Scope.put_origin(scope, %{worker: inspect(worker)}), job)

            :error ->
              {:cancel, :scope_gone}
          end
        after
          LogMetadata.restore(previous)
        end

      {:error, _message} ->
        {:cancel, :invalid_arguments}
    end
  end

  # The three ids in their canonical form, when each is a UUID or nil and those `kind`
  # needs are there.
  defp check_args(args, kind) do
    with {:ok, ids} <- cast_ids(args) do
      %{"organisation_id" => organisation_id, "workspace_id" => workspace_id} = ids

      cond do
        kind == :workspace and (is_nil(organisation_id) or is_nil(workspace_id)) ->
          {:error, "must name the organisation and the workspace it works for"}

        kind == :organisation and (is_nil(organisation_id) or not is_nil(workspace_id)) ->
          {:error, "must name the organisation it works for, and no workspace"}

        kind == :instance and not (is_nil(organisation_id) and is_nil(workspace_id)) ->
          {:error, "is the instance's and names no organisation or workspace"}

        true ->
          {:ok, ids}
      end
    end
  end

  # The keys whether the arguments have them as strings (as they come back from the
  # database) or as atoms (as a caller may build them).
  defp cast_ids(args) do
    Enum.reduce_while(@keys, {:ok, %{}}, fn key, {:ok, ids} ->
      case Map.get(args, Atom.to_string(key), Map.get(args, key)) do
        nil ->
          {:cont, {:ok, Map.put(ids, Atom.to_string(key), nil)}}

        value when is_binary(value) ->
          case Ecto.UUID.cast(value) do
            {:ok, uuid} -> {:cont, {:ok, Map.put(ids, Atom.to_string(key), uuid)}}
            :error -> {:halt, uuid_error()}
          end

        _other ->
          {:halt, uuid_error()}
      end
    end)
  end

  defp uuid_error,
    do: {:error, "organisation_id, workspace_id and user_id must each be a UUID or nil"}

  defp given?(args, key),
    do: Map.has_key?(args, key) or Map.has_key?(args, String.to_existing_atom(key))

  defp string_keys(args), do: Map.new(args, fn {key, value} -> {to_string(key), value} end)

  defp id(%{id: id}), do: id
  defp id(nil), do: nil
end
