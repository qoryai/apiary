defmodule ApiaryWeb.Contract.QueuedRunEventsTest do
  # A batch at the events endpoint whose subject is the run id of a run of a workspace's
  # queue: while no run holds that id (the run waits, is claimed, or ended before its
  # handover) the batch opens none, `409` `run_id_used`, signed, under any key, and
  # nothing of it is stored. Once the run is handed over, registered and attached, a batch
  # that finds it is answered as any batch of the run is.
  use ApiaryWeb.ConnCase, async: true

  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures
  import Ecto.Query

  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Repo
  alias Apiary.Runs.{Delivery, Event, Run}

  @run_id_used %{"error" => "run_id_used"}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, queued: queued!(scope)}
  end

  # A run of the scope's workspace's queue, waiting, with the run id Qory gave it.
  defp queued!(%Scope{workspace: workspace} = scope) do
    %DispatchRun{organisation_id: workspace.organisation_id, workspace_id: workspace.id}
    |> DispatchRun.queue_changeset(%{
      work_item_id: work_item_fixture(scope).id,
      step: "explore",
      take_in: 1,
      attempt: 1,
      of: 3,
      queued_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp key(scope, node) do
    %{access_key: key, secret: secret} = contract_key_fixture(scope, node: node)
    %{key: key, secret: secret}
  end

  defp deliver(%{key: key, secret: secret}, run_id) do
    {_subject, events} = first_events(run_id)
    signed_post(build_conn(), key.key_id, secret, events)
  end

  defp register(%{key: key, secret: secret}, body),
    do: signed_register(build_conn(), key.key_id, secret, Jason.encode!(body))

  defp attach(%{key: key, secret: secret}, run_id, run_key),
    do:
      signed_attach(build_conn(), key.key_id, secret, run_id, Jason.encode!(attach_body(run_key)))

  defp stored(run_id) do
    %{
      runs: Repo.aggregate(from(r in Run, where: r.node_run_id == ^run_id), :count),
      deliveries: Repo.aggregate(from(d in Delivery, where: d.node_run_id == ^run_id), :count)
    }
  end

  defp refused?(conn), do: json_response(conn, 409) == @run_id_used and signed_answer?(conn)

  defp set(%DispatchRun{id: id}, changes),
    do: Repo.update_all(from(d in DispatchRun, where: d.id == ^id), set: changes)

  describe "before the handover" do
    test "a node's, a pool's or a gateway's batch naming the run is 409 run_id_used", ctx do
      gateway = gateway_fixture(ctx.scope)

      keys = [
        node: key(ctx.scope, node_fixture(ctx.scope)),
        pool: key(ctx.scope, pool_fixture(ctx.scope)),
        gateway: key(ctx.scope, gateway),
        organisation_gateway: key(ctx.scope, organisation_gateway_fixture(ctx.scope))
      ]

      for {kind, key} <- keys do
        conn = deliver(key, ctx.queued.run_id)
        assert refused?(conn), "#{kind}: #{conn.status} #{conn.resp_body}"
        assert Repo.reload!(key.key).last_used_at == nil, "#{kind}"
      end

      assert stored(ctx.queued.run_id) == %{runs: 0, deliveries: 0}
    end

    test "in every state before it: waiting, claimed, ended", ctx do
      ours = key(ctx.scope, pool_fixture(ctx.scope))

      for changes <- [
            [state: :waiting],
            [state: :claimed],
            [state: :ended, end_cause: :released],
            [state: :ended, end_cause: :closed]
          ] do
        set(ctx.queued, changes)
        assert refused?(deliver(ours, ctx.queued.run_id)), inspect(changes)
      end

      assert stored(ctx.queued.run_id) == %{runs: 0, deliveries: 0}
    end

    test "on the whole instance: a run of another organisation's queue", ctx do
      %{scope: other} = sign_up_fixture()
      theirs = queued!(other)
      ours = key(ctx.scope, node_fixture(ctx.scope))

      assert refused?(deliver(ours, theirs.run_id))
      assert stored(theirs.run_id) == %{runs: 0, deliveries: 0}
    end

    test "comes after the 400 of a body the contract refuses", ctx do
      %{key: key, secret: secret} = key(ctx.scope, node_fixture(ctx.scope))
      {_subject, events} = first_events(ctx.queued.run_id)
      ping = wire_event(ctx.queued.run_id, 3, "ping")

      conn = signed_post(build_conn(), key.key_id, secret, events ++ [ping])
      assert json_response(conn, 400) == %{"error" => "invalid_request"}
    end

    test "comes after the 404 of a key that may not post", ctx do
      ours = key(ctx.scope, node_fixture(ctx.scope))
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.NoRunPosting)

      conn = deliver(ours, ctx.queued.run_id)
      assert json_response(conn, 404) == %{"error" => "not_found"}
      assert signed_answer?(conn)
    end
  end

  test "a run id of no run of the queue still opens a run, as before", ctx do
    ours = key(ctx.scope, node_fixture(ctx.scope))
    run_id = Ecto.UUID.generate()

    assert response(deliver(ours, run_id), 202) == ""
    assert %{runs: 1, deliveries: 1} = stored(run_id)
  end

  describe "after the handover" do
    # The workspace's first gateway is its default, and the pool made after it uses it.
    # The run is registered through the gateway under the pool's key and attached, and
    # is then the queue's run, handed over: as its handover leaves it.
    setup ctx do
      gateway = key(ctx.scope, gateway_fixture(ctx.scope))
      pool = key(ctx.scope, pool_fixture(ctx.scope))
      run_id = Ecto.UUID.generate()

      assert %{"run_key" => run_key} =
               json_response(register(pool, gateway_registration(run_id)), 200)

      assert attach(gateway, run_id, run_key).status == 200

      set(ctx.queued, run_id: run_id, state: :handed_over)

      Repo.update_all(from(r in Run, where: r.node_run_id == ^run_id),
        set: [dispatch_run_id: ctx.queued.id]
      )

      %{gateway: gateway, pool: pool, run_id: run_id}
    end

    test "the gateway that attached it is taken; the pool's key is 409 wrong_gateway", ctx do
      assert response(deliver(ctx.gateway, ctx.run_id), 202) == ""
      run = Repo.one!(from r in Run, where: r.node_run_id == ^ctx.run_id)
      assert Repo.aggregate(from(e in Event, where: e.run_id == ^run.id), :count) > 0

      for key <- [ctx.pool, key(ctx.scope, node_fixture(ctx.scope))] do
        conn = deliver(key, ctx.run_id)
        assert json_response(conn, 409) == %{"error" => "wrong_gateway"}
        assert signed_answer?(conn)
      end

      assert stored(ctx.run_id).runs == 1
    end

    test "a run whose events were pruned is 410, as before", ctx do
      Repo.update_all(from(r in Run, where: r.node_run_id == ^ctx.run_id),
        set: [events_pruned_at: DateTime.utc_now()]
      )

      assert response(deliver(ctx.gateway, ctx.run_id), 410) == ""
    end

    test "a key of another workspace opens no run under its id", ctx do
      %{scope: other} = sign_up_fixture()
      theirs = key(other, node_fixture(other))

      assert refused?(deliver(theirs, ctx.run_id))
      assert stored(ctx.run_id).runs == 1
    end
  end
end
