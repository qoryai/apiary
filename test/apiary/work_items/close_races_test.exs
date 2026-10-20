defmodule Apiary.WorkItems.CloseRacesTest do
  # The removal of an adapter, which closes the open work items of its connections
  # (`Apiary.WorkItems.close_for_adapter/2`), racing another removal of it and a claim of
  # a run of one of its work items. Each side runs on a separate connection, outside the
  # SQL sandbox, so each commits and each waits on the other's locks as it would in
  # production. Not async: what these tests commit is visible to every other test while
  # they run, and they delete it again before they end; the adapters and the keys' public
  # halves, which outlive an organisation, by what they made, and the entries the adapters
  # left in the trail of the instance's organisation.
  #
  # The rules under test: the lock order of a close (the adapter's row, its connections,
  # the work items, then their runs and dispatches), so that two removals take turns and
  # each work item closes once; a claim holding a run, which a removal waits for and then
  # ends; and a removal holding a run, which a claim skips without waiting.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.Races
  import Apiary.WorkItemsFixtures

  alias Apiary.{Adapters, Dispatches, Edition, Repo}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode, PublicKey}
  alias Apiary.Adapters.Connection
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Slots}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias Apiary.WorkItems.{WorkItem, WorkItemEvent}
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag needs: :factory

  setup_all do
    clean_up_leftovers(%{})
    :ok = Sandbox.checkout(Repo, sandbox: false)
    delete_adapters(from(n in Node, where: n.kind == :adapter and like(n.name, "Races %")))
    Sandbox.checkin(Repo)
    :ok
  end

  setup :setup_races

  setup do
    started = DateTime.utc_now()
    %{scope: scope} = sign_up()

    %{adapter: adapter, pair: adapter_pair} =
      connectable_adapter_fixture(%{name: name("adapter")})

    {connection, _nonce} = connection_fixture(scope, adapter, :listed)
    pool = pool_fixture(scope)
    %{access_key: key, pair: pool_pair} = enrolled_key_fixture(scope, pool)

    # Registered after the setup of `Apiary.Races`, so it runs before that one: the
    # organisation and its rows first, then the adapter, the public halves of the keys
    # and the entries of the instance's organisation.
    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      Repo.delete_all(from o in Organisation, where: o.id == ^scope.organisation.id)
      delete_adapters(from(n in Node, where: n.id == ^adapter.id))

      Repo.delete_all(
        from p in PublicKey,
          where: p.public_key in ^[adapter_pair.public_key, pool_pair.public_key]
      )

      Repo.delete_all(
        from e in Entry,
          where: e.organisation_id == ^Edition.instance_organisation_id(),
          where: e.inserted_at >= ^started
      )

      Sandbox.checkin(Repo)
    end)

    work_item = work_item_fixture(scope, connection_id: connection.id)
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

    %{
      admin: Apiary.OrganisationsFixtures.instance_admin_scope(),
      adapter: adapter,
      pool: pool,
      key: key,
      work_item: work_item,
      run: run
    }
  end

  defp delete_adapters(query) do
    ids = Repo.all(select(query, [n], n.id))
    Repo.delete_all(from c in Connection, where: c.adapter_id in ^ids)
    Repo.delete_all(from k in AccessKey, where: k.node_id in ^ids)
    Repo.delete_all(from c in EnrolmentCode, where: c.node_id in ^ids)
    Repo.delete_all(from n in Node, where: n.id in ^ids)
  end

  defp remove(ctx), do: fn -> Adapters.delete_adapter(ctx.admin, ctx.adapter) end
  defp claim(ctx), do: fn -> Dispatches.claim(ctx.key, Dispatches.now()) end

  defp closes(ctx),
    do:
      Repo.aggregate(
        from(e in WorkItemEvent,
          where: e.work_item_id == ^ctx.work_item.id and e.kind == :closed
        ),
        :count
      )

  defp closed!(ctx) do
    assert %WorkItem{state: :closed} = Repo.get!(WorkItem, ctx.work_item.id)
    assert closes(ctx) == 1
    assert %DispatchRun{state: :ended, end_cause: :closed} = Repo.get!(DispatchRun, ctx.run.id)
  end

  test "two removals: the second waits, then finds the adapter removed; the work item closes once",
       ctx do
    {first, first_pid} = hold(remove(ctx))
    assert {:ok, %Node{}} = first.result

    second = start(remove(ctx))
    await_blocked(second.backend, first_pid)
    commit(first)

    assert Task.await(second.task) == {:error, :not_found}
    closed!(ctx)
  end

  test "many removals at once: one removes it, and the work item closes once", ctx do
    answers = together(List.duplicate(remove(ctx), sides(4)))

    assert Enum.count(answers, &match?({:ok, %Node{}}, &1)) == 1
    assert Enum.all?(answers, &(match?({:ok, %Node{}}, &1) or &1 == {:error, :not_found}))
    closed!(ctx)
  end

  test "a claim holds the run: the removal waits, then ends the run and its dispatch", ctx do
    {first, first_pid} = hold(claim(ctx))
    assert {:ok, %{dispatch: dispatch}} = first.result

    second = start(remove(ctx))
    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:ok, %Node{}} = Task.await(second.task)
    closed!(ctx)

    assert %Dispatch{end_cause: :closed, slot_freed_at: %DateTime{}} =
             Repo.get!(Dispatch, dispatch.id)

    assert Slots.held(ctx.pool.id) == 0
  end

  test "the removal holds the run: a claim skips it without waiting, and the run ends", ctx do
    {first, _first_pid} = hold(remove(ctx))
    assert {:ok, %Node{}} = first.result

    second = start(claim(ctx))
    assert Task.await(second.task) == {:ok, :none}
    commit(first)

    closed!(ctx)
    assert Repo.all(from d in Dispatch, where: d.dispatch_run_id == ^ctx.run.id) == []
  end
end
