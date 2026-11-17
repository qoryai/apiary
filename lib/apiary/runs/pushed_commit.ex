defmodule Apiary.Runs.PushedCommit do
  # One commit a run reported it pushed to a place in another system, one row per commit and
  # place, kept in the order the run reported them. The run's qory reports each push through
  # the run API (`POST /v1/runs/<run_id>/pushed-commits`, docs/contract/run-api.md); the
  # next run of the work item reads the list (`for_run/2`) to continue from it.
  #
  # `system` and `path` are the place the commit went to, labels as the run sent them
  # (`Apiary.Runs.Target.label/1`). `commit` is the full commit id, 40 or 64 lowercase hex
  # characters: Qory Apiary reads no git, so it checks only that form. `sequence` is the
  # position in the run's list, from 1; `at` is when Qory Apiary stored the row.
  #
  # Not an event projection: the rows are kept when a run's events are pruned
  # (`Apiary.Retention`) and go with the run.
  @moduledoc false
  use Ecto.Schema

  import Ecto.Query, only: [from: 2]

  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Repo
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.WorkItem

  @typedoc "One commit of one run."
  @type t :: %__MODULE__{}

  @typedoc "A commit as `for_run/2` lists it."
  @type entry :: %{
          system: String.t(),
          path: String.t(),
          commit: String.t(),
          run_id: String.t(),
          cancelled: boolean,
          at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "run_pushed_commits" do
    field :sequence, :integer
    field :system, :string
    field :path, :string
    field :commit, :string
    field :at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :run, Apiary.Runs.Run
  end

  @commit ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/

  @doc "Whether `commit` is a full commit id: 40 or 64 lowercase hex characters."
  @spec commit?(term) :: boolean
  def commit?(commit), do: is_binary(commit) and Regex.match?(@commit, commit)

  @doc """
  Why a run's report is refused, or nil: `:run_ended` once the run's end is recorded, its
  run of the queue ended. A report is not refused while a member's cancel is requested
  (`Apiary.Runs.Run.cancel_requested?/1`): the run goes on until its exit arrives, and what
  it pushed before then is on the forge's branch, so it is kept and listed with the mark
  of the cancel. The one place the rule is written; `record/3` reads it under the work
  item's lock.
  """
  @spec refusal(DispatchRun.t() | nil) :: :run_ended | nil
  def refusal(%DispatchRun{state: :ended}), do: :run_ended
  def refusal(_dispatch_run), do: nil

  @doc """
  Stores the commits `repositories`, `[%{system:, path:, commit:}]`, as the next rows of
  the run's list, in the order given, `:ok`. A commit the run reported before for the same
  system and path, or twice in `repositories`, is stored once and takes no position. Under
  the work item's lock, as a push and a cancel take it, with the run's run of the queue
  read again: `{:error, :run_ended}` when `refusal/1` says so, and `{:error, :not_found}`
  for a work item or a run that is gone.
  """
  @spec record(WorkItem.t(), Run.t(), [map]) :: :ok | {:error, :run_ended | :not_found}
  def record(%WorkItem{} = work_item, %Run{} = run, repositories) when is_list(repositories) do
    result =
      Repo.transact(fn ->
        with %WorkItem{} <- held(work_item),
             %Run{} = run <- Repo.get(Run, run.id),
             %DispatchRun{} = dispatch_run <- Repo.get(DispatchRun, run.dispatch_run_id),
             nil <- refusal(dispatch_run) do
          {:ok, store(run, repositories)}
        else
          :run_ended -> {:error, :run_ended}
          _gone -> {:error, :not_found}
        end
      end)

    with {:ok, :ok} <- result, do: :ok
  end

  defp held(%WorkItem{id: id, workspace_id: workspace_id}) do
    Repo.one(
      from w in WorkItem,
        where: w.id == ^id and w.workspace_id == ^workspace_id,
        lock: "FOR UPDATE"
    )
  end

  defp store(%Run{} = run, repositories) do
    stored =
      MapSet.new(
        Repo.all(
          from c in __MODULE__,
            where: c.run_id == ^run.id,
            select: {c.system, c.path, c.commit}
        )
      )

    last =
      Repo.one(from c in __MODULE__, where: c.run_id == ^run.id, select: max(c.sequence)) || 0

    now = DateTime.utc_now()

    rows =
      repositories
      |> Enum.map(&{&1.system, &1.path, &1.commit})
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(stored, &1))
      |> Enum.with_index(last + 1)
      |> Enum.map(fn {{system, path, commit}, sequence} ->
        %{
          id: Ecto.UUID.generate(),
          organisation_id: run.organisation_id,
          workspace_id: run.workspace_id,
          run_id: run.id,
          sequence: sequence,
          system: system,
          path: path,
          commit: commit,
          at: now
        }
      end)

    if rows != [], do: Repo.insert_all(__MODULE__, rows)
    :ok
  end

  @doc """
  The commits the earlier runs of the run's work item reported, each as an entry, with none
  that `run` reported: the runs of the work item (`work_item_id` of their run of the queue,
  whatever their stage) with a lower number than `run`'s, ordered by run number, then by
  the position in the run's list. `cancelled` is whether a member cancelled the run that
  reported the commit (`cancel_requested_at`), read now: a run that ended at its time limit,
  was released or lost its machine has no mark. `[]` for none.
  """
  @spec for_run(WorkItem.t(), Run.t()) :: [entry]
  def for_run(%WorkItem{id: work_item_id}, %Run{id: run_id, number: number})
      when is_integer(number) do
    from(c in __MODULE__,
      join: r in Run,
      on: r.id == c.run_id,
      join: d in DispatchRun,
      on: d.id == r.dispatch_run_id,
      where: d.work_item_id == ^work_item_id and r.id != ^run_id and r.number < ^number,
      order_by: [asc: r.number, asc: c.sequence],
      select: %{
        system: c.system,
        path: c.path,
        commit: c.commit,
        run_id: r.node_run_id,
        cancelled: not is_nil(r.cancel_requested_at),
        at: c.at
      }
    )
    |> Repo.all()
    |> selection()
  end

  def for_run(_work_item, _run), do: []

  # Which of the ordered entries `GET work-item` lists. All of them: qory reads the whole
  # list of every earlier run, since a cancelled run's commits are all needed to tell them
  # from a commit nobody reported. The one place to narrow the list.
  defp selection(entries), do: entries
end
