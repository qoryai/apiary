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
  # (`Apiary.Dispatches.Slots`), so a part that holds its connection `FOR UPDATE` and its
  # collections `FOR NO KEY UPDATE` and then changes them, and a Rebuild, take turns, and
  # neither deadlocks.
  use ExUnit.Case, async: false

  @before_compile Apiary.TestSetup

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.Races

  alias Apiary.{Edition, Environments, Repo, Targets}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode, PublicKey}
  alias Apiary.Adapters.{Collection, Connection}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Environments.Record
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias Apiary.Runs.Target
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag needs: [:factory, :registry]

  @system "code.example.com"
  @path "acme/shop"

  setup_all :clean_up_leftovers
  setup :setup_races

  # A node pool, a target of the workspace, and a collection assigned there with it and
  # the `environment_ref` `env-1`, whose record for the pool was queued for that ref and
  # target, with no prebuild waiting: a Rebuild queues one. All committed.
  setup do
    started = database_now()
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
      source_collection_id: collection.id
    })

    :ok =
      Target.insert_new(scope.organisation.id, scope.workspace.id, [
        Collection.target(collection)
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

  test "a part holds the collection, a Rebuild waits for it, then the part commits: neither deadlocks",
       ctx do
    connection = Repo.get!(Connection, ctx.collection.connection_id)
    key_scope = listing_key!(connection)

    # A listing's part, held open once it wrote the collection's `environment_ref`: it
    # holds its connection `FOR UPDATE`, then the collection `FOR NO KEY UPDATE`, by ref
    # (`Apiary.Adapters.Collections.post_listing/2`).
    {part, part_backend} = hold(listing_part(key_scope, connection, [ctx.collection], "env-2"))
    assert part.result == {:ok, :accepted}

    rebuild = start(fn -> Environments.rebuild(ctx.scope, ctx.target) end)

    # The Rebuild waits on the part, at the part's connection.
    await_waited(rebuild.backend, part_backend)
    assert statement(rebuild.backend) =~ ~s(FROM "adapter_connections")
    commit(part)

    # The Rebuild read the collection as the part left it, and queued its prebuild of
    # `env-2` for the pool.
    assert Task.await(rebuild.task, 10_000) == {:ok, 1}
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
      source_collection_id: second.id
    })

    [low, high] = Enum.sort([first.id, second.id])

    for {id, ref} <- [{low, "Z"}, {high, "Y"}] do
      {1, _rows} =
        Repo.update_all(from(c in Collection, where: c.id == ^id), set: [external_ref: ref])
    end

    connection = Repo.get!(Connection, first.connection_id)
    key_scope = listing_key!(connection)
    named = Repo.all(from c in Collection, where: c.id in ^[low, high])

    # A listing's part of both, held open once it wrote their `environment_ref`: it holds
    # its connection `FOR UPDATE`, then, by ref, `Y`, the higher id, and `Z`, in one
    # statement (`Apiary.Adapters.Collections.post_listing/2`). The part cannot be
    # stopped between `Y` and `Z`, so it is held once it holds both.
    {part, part_backend} = hold(listing_part(key_scope, connection, named, "env-2"))
    assert part.result == {:ok, :accepted}

    rebuild = start(fn -> Environments.rebuild(scope, ctx.target) end)

    # The Rebuild waits on the part. Had it held the lower id without the connection, it
    # could hold `Z` while a part held `Y` and waited on `Z`, and Postgres would roll back
    # one of the two transactions with `deadlock_detected`.
    await_waited(rebuild.backend, part_backend)
    assert statement(rebuild.backend) =~ ~s(FROM "adapter_connections")
    commit(part)

    # The Rebuild read both collections as the part left them, and queued their prebuilds
    # of `env-2` for the pool.
    assert Task.await(rebuild.task, 10_000) == {:ok, 2}

    for collection <- [first, second],
        do: assert(waiting(collection) == [{pool.id, "env-2"}])
  end

  test "a registration on the second pool holds its row, then takes a run number, beside a Rebuild of both pools: neither deadlocks",
       ctx do
    second = pool_fixture(ctx.scope, name: "linux-pool")
    [first, last] = Enum.sort_by([ctx.pool, second], & &1.id)

    {1, _rows} =
      Repo.update_all(from(n in Node, where: n.id == ^last.id), set: [instance_limit: 5])

    last = Repo.get!(Node, last.id)

    # A registration on `last`: the instance limit's check holds the pool's row
    # `FOR UPDATE` (`Apiary.Nodes.check_instance_limit/3`), and the run's number comes
    # next.
    {registration, registration_backend} =
      hold(fn -> Apiary.Nodes.check_instance_limit(last, "i-1", DateTime.utc_now()) end)

    rebuild =
      start(fn ->
        try do
          Environments.rebuild(ctx.scope, ctx.target)
        rescue
          error -> {:raised, Exception.message(error)}
        end
      end)

    # The Rebuild waits at `last`'s row. Had it taken the run counter before that row, the
    # registration would now wait on it for the counter, and Postgres would abort the
    # Rebuild, which has waited longer (`deadlock_detected`).
    await_waited(rebuild.backend, registration_backend)
    number = continue(registration, fn -> Apiary.Runs.Number.next(ctx.scope.workspace, last) end)
    commit(registration)

    assert Task.await(rebuild.task, 10_000) == {:ok, 2}
    assert is_integer(number)
    assert waiting(ctx.collection) == [{first.id, "env-1"}, {last.id, "env-1"}]
  end
end
