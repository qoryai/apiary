defmodule Apiary.Runs.WriteNeeds do
  # A run with access `write` or `write-no-push` that qory closed failed, before a session
  # joined it, with the end reason `write_needs_wall`: the machine has no wall, and a run
  # that writes to the checkout needs one. The run is not a read-only run, so
  # `Apiary.Runs.ReadNeeds` does not cover it. Qory Apiary does not store the access on the
  # run; the two accesses end with the same reason.
  #
  # `installed` is true for a run on the instance's pool, as in `Apiary.Runs.ReadNeeds`.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query

  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Repo
  alias Apiary.Runs.{ReadNeeds, Run}

  @typedoc "The run's end reason, and whether the run's pool is the instance's."
  @type facts :: %{code: String.t(), installed: boolean}

  @doc false
  # of_run/1 is the facts of a run that ended with `write_needs_wall`; nil for any other
  # run, and for none.
  @spec of_run(map | nil) :: facts | nil
  def of_run(%{reason: "write_needs_wall" = code, node_id: node_id}),
    do: %{code: code, installed: ReadNeeds.installed?(node_id)}

  def of_run(_run), do: nil

  @doc false
  # of_dispatch_run/1 is the facts of the registered run of `dispatch_run`, read from the
  # database: nil when it has none, and as `of_run/1` otherwise.
  @spec of_dispatch_run(DispatchRun.t()) :: facts | nil
  def of_dispatch_run(%DispatchRun{id: id}) do
    from(r in Run.registered(),
      where: r.dispatch_run_id == ^id,
      select: map(r, [:reason, :node_id])
    )
    |> Repo.one()
    |> of_run()
  end
end
