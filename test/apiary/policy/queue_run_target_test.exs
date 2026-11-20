defmodule Apiary.Policy.QueueRunTargetTest do
  # A run of a workspace's queue has the target the projector gives it, its work item's,
  # by adapter and collection ref, on the wire too: its run configuration
  # (`Apiary.Policy.Serving`) and its registry target name (`Apiary.Registry.RunAccess`).
  # Its labels have an address, which two targets can share, or which a target leaves when
  # its collection moves. Not async: the features and the registry's settings are the
  # whole node's.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures

  alias Apiary.{InstanceConfig, Policy, Repo}
  alias Apiary.Policy.{RunConfiguration, Serving}
  alias Apiary.Registry.{Names, RunAccess}
  alias Apiary.Runs.Target
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: [:registry, :security]

  # A run of the queue of a work item at forge.example.com/acme/shop, attached, in a
  # workspace with a baseline, and its target's row with a rule for that target alone.
  setup do
    %{scope: scope} = sign_up_fixture()
    {:ok, _rule} = Policy.allow(scope, nil, %{host: "git.example"})
    ctx = sealed_run_fixture(scope)

    work_item =
      Repo.get!(
        WorkItem,
        Repo.get!(Apiary.Dispatches.DispatchRun, ctx.run.dispatch_run_id).work_item_id
      )

    target = Repo.one!(Target.by_key(scope.workspace.id, WorkItem.target(work_item)))
    {:ok, _rule} = Policy.allow(scope, target, %{host: "shop.example"})
    {key, _seed} = ctx.gateway_key

    Map.merge(ctx, %{
      scope: scope,
      target: target,
      wire_key: Repo.preload(key, [:workspace])
    })
  end

  defp name(scope, %Target{public_id: public_id}),
    do: Names.target_name(InstanceConfig.registry_instance(), scope.organisation.id, public_id)

  defp configuration_target(ctx, dispatch_run_id) do
    {:ok, %RunConfiguration{target_id: target_id}} =
      Serving.fetch(ctx.wire_key, ctx.run.registration_labels, dispatch_run_id)

    target_id
  end

  test "two collections at one address: the run has its work item's target", ctx do
    %{system: system, path: path} = ctx.target

    :ok =
      Target.insert_new(ctx.scope.organisation.id, ctx.scope.workspace.id, [
        Apiary.NodesFixtures.target_key(%{system: system, path: path})
      ])

    assert Repo.aggregate(
             from(t in Target, where: t.workspace_id == ^ctx.scope.workspace.id),
             :count
           ) == 2

    assert configuration_target(ctx, ctx.run.dispatch_run_id) == ctx.target.id
    assert RunAccess.rights(ctx.run) == %{name(ctx.scope, ctx.target) => ["pull"]}

    # Its labels alone have an address of two targets: the baseline's.
    assert configuration_target(ctx, nil) == nil
  end

  test "a collection after a move: the run keeps its target", ctx do
    {1, _rows} =
      Repo.update_all(from(t in Target, where: t.id == ^ctx.target.id),
        set: [path: "acme/moved"]
      )

    assert configuration_target(ctx, ctx.run.dispatch_run_id) == ctx.target.id
    assert RunAccess.rights(ctx.run) == %{name(ctx.scope, ctx.target) => ["pull"]}

    # Its labels alone have the old address, of no target: the baseline's.
    assert configuration_target(ctx, nil) == nil
  end
end
