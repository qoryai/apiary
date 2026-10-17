defmodule ApiaryWeb.Contract.ClosedWorkItemRunTest do
  # A run of the queue handed over before its work item closed goes on to its end: the
  # removal of the adapter its ticket came through closes the work item
  # (`Apiary.Adapters.delete_adapter/2`), and the run's result, in its batch, and its
  # outcome are taken after it as before.
  use ApiaryWeb.ConnCase, async: true

  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures
  import Ecto.Query

  alias Apiary.{Adapters, Dispatches, Repo}
  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.Runs.{Event, Run}
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  defp key(scope, node) do
    %{access_key: key, secret: secret} = contract_key_fixture(scope, node: node)
    %{key: key, secret: secret}
  end

  # The workspace's first gateway is its default, and the pool made after it uses it. The
  # pool claims the run, which is registered through the gateway under the pool's key and
  # attached, and is then the queue's run, handed over: as its handover leaves it.
  setup do
    %{scope: scope} = sign_up_fixture()
    %{adapter: adapter} = connectable_adapter_fixture()
    {connection, _nonce} = connection_fixture(scope, adapter, :listed)
    work_item = work_item_fixture(scope, connection_id: connection.id)

    gateway = key(scope, gateway_fixture(scope))
    pool = key(scope, pool_fixture(scope))

    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    {:ok, %{dispatch: dispatch}} = Dispatches.claim(pool.key, Dispatches.now())

    run_id = Ecto.UUID.generate()

    assert %{"run_key" => run_key} =
             json_response(
               signed_register(
                 build_conn(),
                 pool.key.key_id,
                 pool.secret,
                 Jason.encode!(gateway_registration(run_id))
               ),
               200
             )

    assert signed_attach(
             build_conn(),
             gateway.key.key_id,
             gateway.secret,
             run_id,
             Jason.encode!(attach_body(run_key))
           ).status == 200

    at = DateTime.add(dispatch.claimed_at, 1, :second)

    Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
      set: [dispatched_at: at, handed_over_at: at]
    )

    Repo.update_all(from(d in DispatchRun, where: d.id == ^queued.id),
      set: [run_id: run_id, state: :handed_over]
    )

    Repo.update_all(from(r in Run, where: r.node_run_id == ^run_id),
      set: [dispatch_run_id: queued.id]
    )

    %{
      scope: scope,
      adapter: adapter,
      work_item: work_item,
      queued: queued,
      dispatch: dispatch,
      gateway: gateway,
      pool: pool,
      run_id: run_id
    }
  end

  test "the removal closes the work item; the run's result and outcome are then taken", ctx do
    {:ok, _deleted} = Adapters.delete_adapter(instance_admin_scope(), ctx.adapter)

    assert %WorkItem{state: :closed} = Repo.get!(WorkItem, ctx.work_item.id)

    assert %DispatchRun{state: :handed_over, end_cause: nil} =
             Repo.get!(DispatchRun, ctx.queued.id)

    assert %Dispatch{ended_at: nil, end_cause: nil, slot_freed_at: nil} =
             Repo.get!(Dispatch, ctx.dispatch.id)

    # The result, in a batch through the gateway that attached the run.
    {_subject, [started]} = first_events(ctx.run_id)

    result =
      wire_event(ctx.run_id, 3, "session.result", %{
        "outcome" => "success",
        "result" => ~s({"version":1})
      })

    conn =
      signed_post(build_conn(), ctx.gateway.key.key_id, ctx.gateway.secret, [started, result])

    assert response(conn, 202) == ""

    run = Repo.one!(from r in Run, where: r.node_run_id == ^ctx.run_id)

    assert Repo.exists?(
             from e in Event, where: e.run_id == ^run.id and e.type == "dev.qory.session.result"
           )

    # The outcome, under the pool's key, the node the run is bound to.
    time = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    conn =
      signed_post(
        build_conn(),
        ctx.pool.key.key_id,
        ctx.pool.secret,
        Jason.encode!(%{"version" => 1, "state" => "succeeded", "time" => time}),
        target: "/v1/runs/#{ctx.run_id}/outcome",
        content_type: "application/json",
        delivery: nil
      )

    assert json_response(conn, 200) == %{"version" => 1}
    assert signed_answer?(conn)
    assert %Run{outcome_state: "succeeded"} = Repo.get!(Run, run.id)
  end
end
