defmodule Apiary.Runs.Waiting do
  @moduledoc false

  # Why a queued run (`Apiary.Runs.Run.queued?/1`) waits, read for its run page from what a
  # claim checks (`Apiary.Dispatches.claim/4`), read without a lock. The first reason that applies:
  #
  #   * `:harness`, its harness walk is not resolved yet (`Apiary.Harnesses.WalkJob`);
  #   * `:no_pool`, no pool that serves the workspace's runs is ready
  #     (`c:Apiary.Edition.machines_ready/1`);
  #   * `{:no_fit, key, pool}`, no such pool can start its machine type of key `key`
  #     (`Apiary.MachineTypes.unserved/2`): `pool` is the name of the first of them, or
  #     `:instance` for the instance's pool, a pool of no organisation and no workspace,
  #     whose admins are the instance's;
  #   * `{:cooldown, provider, until}`, every key of each of its model providers
  #     (`dispatch_runs.model_provider_ids`) is in cooldown, while runs are given model
  #     keys (`Apiary.ModelKeys.cooling_until/2`): `provider` is the name of the first of
  #     them, its model choice's provider, and `until` when the first key of any of them
  #     leaves its cooldown;
  #   * `{:image, target, build}`, it is held for the build of its target's environment
  #     image on every serving pool (`Apiary.Environments.held/1`): `build` is `:queued`
  #     while a prebuild of the target waits, `:running` while one is claimed or handed
  #     over, nil when none is live;
  #   * `{:busy, pool, in_use, limit}`, every serving pool runs as many machines as its
  #     limit allows (`Apiary.Nodes.instances_in_use/2`), as the claim counts them: the
  #     first pool, with its numbers; `{:busy, :instance}` for the instance's pool, whose
  #     count covers the runs of other organisations;
  #   * `{:behind, n}`, `n` runs of the workspace were queued before it and wait;
  #   * `{:pool, name}`, none of these: the pool `name` has not taken it yet, "Qory Pool"
  #     for the instance's pool, as `Apiary.Runs.Place` shows it; nil for no pool.

  import Ecto.Query

  alias Apiary.{Environments, ModelKeys, Repo}
  alias Apiary.Adapters.Collection
  alias Apiary.Connections.Connection
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.RunHarness
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Workspace
  alias Apiary.Runs.ProviderCredential
  alias Apiary.WorkItems.WorkItem

  @typedoc "Why a queued run waits (the moduledoc)."
  @type reason ::
          :harness
          | :no_pool
          | {:no_fit, String.t(), String.t() | :instance}
          | {:cooldown, String.t(), DateTime.t()}
          | {:image, String.t(), :queued | :running | nil}
          | {:busy, String.t(), non_neg_integer, pos_integer}
          | {:busy, :instance}
          | {:behind, pos_integer}
          | {:pool, String.t() | nil}

  # The instance's pool's name on the pages (`Apiary.Runs.Place`).
  @instance_pool "Qory Pool"

  @doc false
  # reason/2 is why the run of the queue `queued`, waiting, waits at `now` (the moduledoc).
  @spec reason(DispatchRun.t(), DateTime.t()) :: reason
  def reason(%DispatchRun{} = queued, %DateTime{} = now \\ DateTime.utc_now()) do
    workspace = Repo.get!(Workspace, queued.workspace_id)
    pools = Apiary.WorkspaceSetup.serving_pools(workspace)

    cond do
      Repo.exists?(
        from h in RunHarness, where: h.dispatch_run_id == ^queued.id and h.state != :resolved
      ) ->
        :harness

      is_nil(Apiary.Edition.machines_ready(workspace)) ->
        :no_pool

      key = queued.work_item_id && Apiary.MachineTypes.unserved(workspace, queued.work_item_id) ->
        {:no_fit, key, pools |> List.first() |> pool_place()}

      cooling = cooldown(queued, now) ->
        cooling

      image = image(queued, pools) ->
        image

      busy = busy(pools, now) ->
        busy

      (n = behind(queued)) > 0 ->
        {:behind, n}

      true ->
        {:pool, pools |> List.first() |> pool_name()}
    end
  end

  # Every key of each of the run's model providers in cooldown at `now`: the first
  # provider's name and when the first key leaves its cooldown.
  defp cooldown(%DispatchRun{model_provider_ids: [first | _] = ids}, now) do
    with true <- ProviderCredential.applies?(),
         %DateTime{} = until <- ModelKeys.cooling_until(ids, now),
         %Connection{name: name} <- Repo.get(Connection, first) do
      {:cooldown, name, until}
    else
      _not_cooling -> nil
    end
  end

  defp cooldown(_queued, _now), do: nil

  # Held for the build of its target's environment image on every serving pool, with the
  # state of the newest live prebuild of that target on one of them.
  defp image(%DispatchRun{work_item_id: nil}, _pools), do: nil
  defp image(_queued, []), do: nil

  defp image(%DispatchRun{} = queued, pools) do
    held? =
      Environments.holds?(queued.workspace_id) and
        Enum.all?(pools, fn %Node{id: pool_id} ->
          Repo.exists?(
            from r in DispatchRun,
              as: :run,
              where: r.id == ^queued.id,
              where: exists(Environments.held(pool_id))
          )
        end)

    if held? do
      item = Repo.get!(WorkItem, queued.work_item_id)
      {:image, item.target_path, build(queued, item, Enum.map(pools, & &1.id))}
    end
  end

  defp build(queued, item, pool_ids) do
    state =
      Repo.one(
        from r in DispatchRun,
          join: c in Collection,
          on: c.id == r.source_collection_id,
          where: r.workspace_id == ^queued.workspace_id and r.step == ^DispatchRun.prebuild(),
          where: r.pool_id in ^pool_ids and r.state in [:waiting, :claimed, :handed_over],
          where: c.target_system == ^item.target_system and c.target_path == ^item.target_path,
          order_by: [desc: r.queued_at],
          select: r.state,
          limit: 1
      )

    case state do
      nil -> nil
      :waiting -> :queued
      _taken -> :running
    end
  end

  # Every serving pool at its limit, counted as the claim counts it; the first, with its
  # numbers.
  defp busy([], _now), do: nil

  defp busy(pools, now) do
    counts =
      for pool <- pools,
          do: {pool, pool.instance_limit && Apiary.Nodes.instances_in_use(pool, now)}

    if Enum.all?(counts, fn {pool, in_use} ->
         pool.instance_limit && in_use >= pool.instance_limit
       end) do
      case hd(counts) do
        {%Node{workspace_id: nil}, _in_use} -> {:busy, :instance}
        {pool, in_use} -> {:busy, pool.name, in_use, pool.instance_limit}
      end
    end
  end

  defp behind(queued) do
    Repo.aggregate(
      from(r in DispatchRun,
        where: r.workspace_id == ^queued.workspace_id and r.state == :waiting,
        where:
          r.queued_at < ^queued.queued_at or
            (r.queued_at == ^queued.queued_at and r.id < ^queued.id)
      ),
      :count
    )
  end

  # The first serving pool of a run that no pool fits: `:instance` for the instance's
  # pool, by its place, not its name, which a workspace's pool can have too.
  defp pool_place(%Node{organisation_id: nil, workspace_id: nil}), do: :instance
  defp pool_place(pool), do: pool_name(pool)

  defp pool_name(nil), do: nil
  defp pool_name(%Node{organisation_id: nil, workspace_id: nil}), do: @instance_pool
  defp pool_name(%Node{name: name}), do: name
end
