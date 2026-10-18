defmodule Apiary.Environments.RebuildRacesTest do
  # A member's Rebuild (`Apiary.Environments.rebuild/2`) beside a listing's part that
  # changes the collection's `environment_ref`, each on a separate connection, outside the
  # SQL sandbox, so each commits and each waits on the other's locks as it would in
  # production. Not async: what these tests commit is visible to every other test while
  # they run, and they delete it again before they end; the adapter the collection came
  # through, which outlives the organisation, by what it made.
  #
  # The rule under test: a Rebuild holds the collections' connections, then the
  # collections, before their environment records, in the order a part and an assign keep
  # (`Apiary.Dispatches.Slots`), so a part that holds its connection and its collections
  # `FOR UPDATE` and then triggers, and a Rebuild, take turns, and neither deadlocks.
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

  test "a part of one connection holds its collections by ref, a Rebuild of two of them waits at the connection: neither deadlocks",
       ctx do
    %{scope: scope, pool: pool, collection: first} = ctx

    # A second collection of the same connection, with the target, and its record for the
    # pool. Then their refs are given in the reverse of their ids' order: a part holds the
    # higher id first, a lock by id the lower.
    second =
      Repo.insert!(
        struct!(first,
          id: nil,
          public_id: Apiary.PublicId.generate(Collection.prefix()),
          external_ref: "SHOP-2"
        )
      )

    Repo.insert!(%Record{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      pool_id: pool.id,
      source_collection_id: second.id,
      queued_ref: "env-1",
      queued_at: DateTime.utc_now(),
      queued_target_system: @system,
      queued_target_path: @path
    })

    [low, high] = Enum.sort([first.id, second.id])

    for {id, ref} <- [{low, "Z"}, {high, "Y"}] do
      {1, _rows} =
        Repo.update_all(from(c in Collection, where: c.id == ^id), set: [external_ref: ref])
    end

    connection_id = first.connection_id

    hold_refs = fn refs ->
      Repo.all(
        from c in Collection,
          where: c.connection_id == ^connection_id and is_nil(c.ended_at),
          where: c.external_ref in ^refs,
          order_by: c.external_ref,
          lock: "FOR UPDATE",
          select: c.id
      )
    end

    # The part holds its connection `FOR UPDATE`, then, by ref, the collection `Y`, the
    # higher id.
    {part, part_backend} =
      hold(fn ->
        %Connection{} =
          Repo.one!(from k in Connection, where: k.id == ^connection_id, lock: "FOR UPDATE")

        [^high] = hold_refs.(["Y"])
        :ok
      end)

    rebuild = start(fn -> Environments.rebuild(scope, ctx.target) end)

    # The Rebuild waits on the part. Had it held the lower id without the connection, the
    # part would now wait on it for `Z`, and the Rebuild, which has waited longer, would
    # be refused (`deadlock_detected`).
    await_waited(rebuild.backend, part_backend)

    queued =
      continue(part, fn ->
        [^low] = hold_refs.(["Z"])

        {2, _rows} =
          Repo.update_all(from(c in Collection, where: c.id in ^[low, high]),
            set: [environment_ref: "env-2"]
          )

        Environments.trigger(
          Repo.all(from c in Collection, where: c.id in ^[low, high]),
          Dispatches.now()
        )
      end)

    commit(part)

    assert [%DispatchRun{environment_ref: "env-2"}, %DispatchRun{environment_ref: "env-2"}] =
             queued

    # The Rebuild read both collections as the part left them, and found their prebuilds of
    # `env-2` waiting for the pool: it queued nothing more.
    assert Task.await(rebuild.task, 10_000) == {:ok, 0}

    for collection <- [first, second],
        do: assert(waiting(collection) == [{pool.id, "env-2"}])
  end
end
