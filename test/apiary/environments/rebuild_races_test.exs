defmodule Apiary.Environments.RebuildRacesTest do
  # A member's Rebuild (`Apiary.Environments.rebuild/2`) beside a listing's part that
  # changes the collection's `environment_ref`, each on a separate connection, outside the
  # SQL sandbox, so each commits and each waits on the other's locks as it would in
  # production. Not async: what these tests commit is visible to every other test while
  # they run, and they delete it again before they end; the adapter the collection came
  # through, which outlives the organisation, by what it made.
  #
  # The rule under test: a Rebuild holds the collections before their environment records,
  # as a part and an assign do (`Apiary.Dispatches.Slots`), so a part that holds the
  # collection `FOR UPDATE` and then triggers, and a Rebuild, take turns, and neither
  # deadlocks.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.Races

  alias Apiary.{Dispatches, Edition, Environments, Repo, Targets}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode, PublicKey}
  alias Apiary.Adapters.{Collection, Connection}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Environments.Record
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias Apiary.Runs.Target
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag needs: :factory

  @system "code.example.com"
  @path "acme/shop"

  setup_all :clean_up_leftovers
  setup :setup_races

  # A node pool, a target of the workspace, and a collection assigned there with it and
  # the `environment_ref` `env-1`, whose record for the pool was queued for that ref and
  # target, with no prebuild waiting: a Rebuild queues one. All committed.
  setup do
    started = DateTime.utc_now()
    %{scope: scope} = sign_up()
    pool = pool_fixture(scope, name: "mac-pool")

    collection =
      collection_fixture(scope,
        external_ref: "SHOP",
        target_system: @system,
        target_path: @path,
        environment_ref: "env-1"
      )

    # Before the clean up of `setup_races`: the organisation, then what outlives it, the
    # adapter the collection came through and the entries it left in the instance's trail.
    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      adapters = [collection.adapter_id]
      Repo.delete_all(from o in Organisation, where: o.id == ^scope.organisation.id)

      adapter_keys =
        Repo.all(from k in AccessKey, where: k.node_id in ^adapters, select: k.key_id)

      Repo.delete_all(from p in PublicKey, where: p.key_id in ^adapter_keys)
      Repo.delete_all(from c in Connection, where: c.adapter_id in ^adapters)
      Repo.delete_all(from k in AccessKey, where: k.node_id in ^adapters)
      Repo.delete_all(from c in EnrolmentCode, where: c.node_id in ^adapters)
      Repo.delete_all(from n in Node, where: n.id in ^adapters)

      Repo.delete_all(
        from e in Entry,
          where: e.organisation_id == ^Edition.instance_organisation_id(),
          where: e.inserted_at >= ^started
      )

      Sandbox.checkin(Repo)
    end)

    Repo.insert!(%Record{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      pool_id: pool.id,
      source_collection_id: collection.id,
      queued_ref: "env-1",
      queued_at: DateTime.utc_now(),
      queued_target_system: @system,
      queued_target_path: @path
    })

    :ok =
      Target.insert_new(scope.organisation.id, scope.workspace.id, [
        %{system: @system, path: @path}
      ])

    %{
      scope: scope,
      pool: pool,
      collection: collection,
      target: Targets.get(scope, @system, @path)
    }
  end

  # The prebuilds of `collection` that wait, `{pool_id, environment_ref}` by pool.
  defp waiting(%Collection{id: id}) do
    Repo.all(
      from r in DispatchRun,
        where: r.step == ^DispatchRun.prebuild() and r.source_collection_id == ^id,
        where: r.state == :waiting,
        order_by: r.pool_id,
        select: {r.pool_id, r.environment_ref}
    )
  end

  test "a part holds the collection, a Rebuild waits for it, then the part triggers: neither deadlocks",
       ctx do
    %{id: id} = ctx.collection

    # The part holds its collection `FOR UPDATE` and changes its `environment_ref`.
    {part, part_backend} =
      hold(fn ->
        %Collection{} = Repo.one!(from c in Collection, where: c.id == ^id, lock: "FOR UPDATE")

        {1, _rows} =
          Repo.update_all(from(c in Collection, where: c.id == ^id),
            set: [environment_ref: "env-2"]
          )

        :ok
      end)

    rebuild = start(fn -> Environments.rebuild(ctx.scope, ctx.target) end)

    # The Rebuild waits on the part. Had it locked the records first, the part's trigger
    # would now wait on the Rebuild, and the Rebuild, which has waited longer, would be
    # refused (`deadlock_detected`).
    await_waited(rebuild.backend, part_backend)

    queued =
      continue(part, fn ->
        Environments.trigger([Repo.get!(Collection, id)], Dispatches.now())
      end)

    commit(part)

    assert [%DispatchRun{environment_ref: "env-2"}] = queued

    # The Rebuild read the collection as the part left it, and found its prebuild of
    # `env-2` waiting for the pool: it queued nothing more.
    assert Task.await(rebuild.task, 10_000) == {:ok, 0}
    assert waiting(ctx.collection) == [{ctx.pool.id, "env-2"}]
  end
end
