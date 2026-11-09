defmodule Apiary.Harnesses.WorkflowGap do
  # A run that ended with the reason `workflow_not_in_harness`: qory found no skill or
  # command for the run's workflow in the harness it composed for the run,
  # and closed the run failed before the runtime started. Qory Apiary only reads the code;
  # this module gives the facts a page or an escalation says of it: the workflow, and
  # where the run's harness came from, read from the run's harness walk
  # (`Apiary.Harnesses.RunHarness`):
  #
  #   * `{:target, path}`: origin `:file`, the harness file at the root of the work
  #     item's target;
  #   * `{:repository, address, narrowing}`: origin `:setting` with a section that extends
  #     a harness repository, its address as `Apiary.Stacks.Document.shown/1` writes it,
  #     and `{:stack, name}`, `{:path, path}` or nil;
  #   * `:section`: origin `:setting` with a section that lists modules and extends none;
  #   * `:qory`: the Qory harness of the workspace's type, which the walk takes when the
  #     workspace has no choice (no stack row);
  #   * nil: a hidden harness, which shows no source, a walk not resolved, or no walk.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query

  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.RunHarness
  alias Apiary.Repo
  alias Apiary.Runs.Run
  alias Apiary.Stacks.Document
  alias Apiary.WorkItems.WorkItem

  @code "workflow_not_in_harness"

  @typedoc "Where the run's harness came from, as the words show it (the moduledoc)."
  @type source ::
          {:target, String.t()}
          | {:repository, String.t(), {:stack, String.t()} | {:path, String.t()} | nil}
          | :section
          | :qory
          | nil

  @typedoc "The workflow the harness lacked, nil when the run's records have none, and the source."
  @type facts :: %{workflow: String.t() | nil, source: source}

  @doc false
  # code/0 is the run's end reason this module reads.
  @spec code() :: String.t()
  def code, do: @code

  @doc false
  # preload/1 is `run` with its run of the queue, that run's harness walk and work item
  # loaded, where its reason is `workflow_not_in_harness`; any other run as it is, with no
  # read. Every page that shows a run's end reason (`ApiaryWeb.RunComponents.reason_words/1`)
  # loads its run through this.
  @spec preload(Run.t()) :: Run.t()
  def preload(%Run{reason: @code, dispatch_run_id: id} = run) when is_binary(id),
    do: Repo.preload(run, dispatch_run: [:harness_walk, :work_item])

  def preload(%Run{} = run), do: run

  @doc false
  # of_run/1 is the facts of a run whose reason is `workflow_not_in_harness`, with its run
  # of the queue loaded (`preload/1`); nil for any other run, and for one whose run of the
  # queue is not loaded.
  @spec of_run(map) :: facts | nil
  def of_run(%{reason: @code, dispatch_run: %DispatchRun{} = dispatch_run}),
    do: facts(dispatch_run, loaded(dispatch_run.harness_walk), loaded(dispatch_run.work_item))

  def of_run(_run), do: nil

  @doc false
  # of_dispatch_run/2 is the facts of the run of the queue `dispatch_run` of `work_item`,
  # read from the database: nil unless its registered run's reason is
  # `workflow_not_in_harness`.
  @spec of_dispatch_run(DispatchRun.t(), WorkItem.t() | nil) :: facts | nil
  def of_dispatch_run(%DispatchRun{id: id} = dispatch_run, work_item) do
    if Repo.exists?(
         from r in Run.registered(), where: r.dispatch_run_id == ^id and r.reason == @code
       ) do
      walk = Repo.one(from h in RunHarness, where: h.dispatch_run_id == ^id)
      facts(dispatch_run, walk, work_item)
    end
  end

  defp facts(dispatch_run, walk, work_item) do
    %{
      workflow: (walk && walk.workflow) || dispatch_run.workflow,
      source: source(walk, work_item && work_item.target_path)
    }
  end

  defp loaded(%Ecto.Association.NotLoaded{}), do: nil
  defp loaded(value), do: value

  @doc false
  # source/2 is where the walk's harness came from (`t:source/0`), `target` the path of
  # the run's target.
  @spec source(RunHarness.t() | nil, String.t() | nil) :: source
  def source(%RunHarness{harness_hidden: true}, _target), do: nil

  def source(%RunHarness{state: :resolved, origin: :file}, target) when is_binary(target),
    do: {:target, target}

  def source(%RunHarness{state: :resolved, origin: :setting, stack_id: nil}, _target), do: :qory

  def source(%RunHarness{state: :resolved, origin: :setting, document: document}, _target) do
    case document do
      %{"extends" => %{"git" => git} = base} when is_binary(git) ->
        {:repository, Document.shown(git), narrowing(base)}

      %{} ->
        :section

      _none ->
        nil
    end
  end

  def source(_walk, _target), do: nil

  defp narrowing(%{"stack" => stack}) when is_binary(stack), do: {:stack, stack}
  defp narrowing(%{"path" => path}) when is_binary(path), do: {:path, path}
  defp narrowing(_base), do: nil
end
