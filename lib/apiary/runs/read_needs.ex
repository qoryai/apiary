defmodule Apiary.Runs.ReadNeeds do
  # A run of a read-only workflow that qory closed failed, before a session joined it,
  # with one of four end reasons: `read_needs_wall`, the machine has no wall;
  # `read_needs_setup_outside`, `wall.setup` runs the setup inside the agent's container;
  # `read_needs_no_nested_docker`, the image runs nested Docker; and
  # `read_needs_setup_removed`, the setup container was not removed. Qory Apiary only
  # reads the code; this module gives the facts a work item's sentence depends on.
  #
  # `installed` is true for a run on the instance's pool, the one a node with no
  # organisation and no workspace is (`nodes_place_check`), which
  # `Apiary.Nodes.Installed` installs. A person in an organisation cannot edit that
  # pool's forager.yaml. It reads the run's node (`Apiary.Runs.Run`, `node_id`), which a
  # claim sets to the pool and nothing moves, so a pool no longer declared, or deleted,
  # reads as it did when the run ended.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query

  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Nodes.Node
  alias Apiary.Repo
  alias Apiary.Runs.Run

  @codes ~w(read_needs_wall read_needs_setup_outside read_needs_no_nested_docker read_needs_setup_removed)

  @typedoc "The run's end reason, and whether the run's pool is the instance's."
  @type facts :: %{code: String.t(), installed: boolean}

  @doc false
  # of_run/1 is the facts of a run that ended with one of the four reasons; nil for any
  # other run, and for none.
  @spec of_run(map | nil) :: facts | nil
  def of_run(%{reason: code, node_id: node_id}) when code in @codes,
    do: %{code: code, installed: installed?(node_id)}

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

  defp installed?(nil), do: false

  defp installed?(node_id) do
    Repo.exists?(
      from n in Node,
        where: n.id == ^node_id and n.kind == :pool,
        where: is_nil(n.organisation_id) and is_nil(n.workspace_id)
    )
  end
end
