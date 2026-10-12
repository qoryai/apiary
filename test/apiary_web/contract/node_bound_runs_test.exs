defmodule ApiaryWeb.Contract.NodeBoundRunsTest do
  # A run is bound to the node whose key registered it, or whose key's batch opened it: its
  # batches, its heartbeats among them, and its reloads are taken from that node's active
  # keys alone, whichever of them signs (`Apiary.Runs.Sender`).
  use ApiaryWeb.ConnCase, async: true

  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.{AccessKeys, Repo}
  alias Apiary.Runs.{Delivery, Event, Run}

  @runs "/v1/runs"

  setup do
    %{scope: scope} = sign_up_fixture()
    %{access_key: key, secret: secret, node: node} = contract_key_fixture(scope)
    # A second key of the same node, as a key replaced while a run is live is.
    %{access_key: second, secret: second_secret} = contract_key_fixture(scope, node: node)
    # A key of another node of the same workspace.
    %{access_key: other, secret: other_secret} = contract_key_fixture(scope)

    %{
      scope: scope,
      node: node,
      key: {key, secret},
      second: {second, second_secret},
      other: {other, other_secret}
    }
  end

  defp deliver({key, secret}, events), do: signed_post(build_conn(), key.key_id, secret, events)

  defp register({key, secret}, body),
    do: signed_register(build_conn(), key.key_id, secret, Jason.encode!(body))

  defp reload({key, secret}, run_id),
    do: signed_get(build_conn(), key.key_id, secret, @runs <> "/" <> run_id)

  defp give({key, secret}, run_id, state \\ "succeeded") do
    time =
      ApiaryWeb.Contract.SignedRequest.now() |> DateTime.from_unix!() |> DateTime.to_iso8601()

    body = Jason.encode!(%{"version" => 1, "state" => state, "time" => time})
    target = "/v1/runs/#{run_id}/outcome"
    opts = [target: target, content_type: "application/json", delivery: nil]
    signed_post(build_conn(), key.key_id, secret, body, opts)
  end

  defp run(run_id), do: Repo.one!(from r in Run, where: r.run_id == ^run_id)

  defp events_of(run_id) do
    run = run(run_id)
    Repo.aggregate(from(e in Event, where: e.run_id == ^run.id), :count)
  end

  defp beat(subject, sequence),
    do: wire_event(subject, sequence, "run.heartbeat", %{"elapsed_seconds" => 30})

  describe "a run's batches" do
    test "from a key of another node are 409 wrong_node, signed, the whole batch refused",
         ctx do
      run_id = Ecto.UUID.generate()
      assert register(ctx.key, registration(run_id)).status == 200

      {_subject, [started]} = first_events(run_id)
      conn = deliver(ctx.other, [started, beat(run_id, 3)])

      assert json_response(conn, 409) == %{"error" => "wrong_node"}
      assert signed_answer?(conn)

      # Nothing of it is stored: no event, no delivery, the run as it was.
      run = run(run_id)
      assert Repo.aggregate(from(e in Event, where: e.run_id == ^run.id), :count) == 0
      assert Repo.aggregate(Delivery, :count) == 0
      assert run.event_count == 0
      assert run.node_id == ctx.node.id
    end

    test "of a run another node's batch opened are refused the same way", ctx do
      {subject, events} = first_events()
      assert deliver(ctx.other, events) |> response(202) == ""

      conn = deliver(ctx.key, [beat(subject, 3)])
      assert json_response(conn, 409) == %{"error" => "wrong_node"}
      assert signed_answer?(conn)
    end

    test "a heartbeat from another node's key is refused like any batch", ctx do
      run_id = Ecto.UUID.generate()
      assert register(ctx.key, registration(run_id)).status == 200

      assert json_response(deliver(ctx.other, [beat(run_id, 2)]), 409) == %{
               "error" => "wrong_node"
             }
    end

    test "are taken from every active key of the run's own node", ctx do
      run_id = Ecto.UUID.generate()
      assert register(ctx.key, registration(run_id)).status == 200

      {_subject, [started]} = first_events(run_id)
      assert deliver(ctx.key, [started]) |> response(202) == ""
      # The second key of the node: the run goes on under it.
      assert deliver(ctx.second, [beat(run_id, 3)]) |> response(202) == ""

      run = run(run_id)
      assert run.event_count == 2
      assert run.state == "running"
    end

    test "of a run its batch opened are taken from its node's other key too", ctx do
      {subject, events} = first_events()
      assert deliver(ctx.key, events) |> response(202) == ""
      assert deliver(ctx.second, [beat(subject, 3)]) |> response(202) == ""
      assert run(subject).node_id == ctx.node.id
    end

    test "under the same run id in another workspace open that workspace's own run", ctx do
      %{scope: elsewhere} = sign_up_fixture()
      %{access_key: key, secret: secret} = contract_key_fixture(elsewhere)

      {subject, events} = first_events()
      assert deliver(ctx.key, events) |> response(202) == ""
      assert deliver({key, secret}, events) |> response(202) == ""

      assert Repo.aggregate(from(r in Run, where: r.run_id == ^subject), :count) == 2
    end
  end

  describe "a run's reload" do
    @tag needs: :security
    test "under a second key of the node reads what the first does", ctx do
      {:ok, _} = Apiary.Policy.allow(ctx.scope, nil, %{host: "api.example"})
      run_id = Ecto.UUID.generate()
      registered = register(ctx.key, registration(run_id))
      assert registered.status == 200

      first = reload(ctx.key, run_id)
      second = reload(ctx.second, run_id)
      assert first.status == 200
      assert second.status == 200
      assert second.resp_body == first.resp_body
      assert signed_answer?(second)

      conn = reload(ctx.other, run_id)
      assert json_response(conn, 404) == %{"error" => "not_found"}
      assert signed_answer?(conn)
    end
  end

  describe "a registration repeated" do
    test "with the same bytes under the node's second key is given the same answer", ctx do
      body = registration(Ecto.UUID.generate())
      first = register(ctx.key, body)
      assert first.status == 200

      again = register(ctx.second, body)
      assert again.status == 200
      assert again.resp_body == first.resp_body
      assert signed_answer?(again)

      for header <- ~w(x-qory-run-configuration etag) do
        assert get_resp_header(again, header) == get_resp_header(first, header)
      end

      assert Repo.aggregate(from(r in Run, where: r.run_id == ^body["run_id"]), :count) == 1
    end

    test "with the same bytes under another node's key is 409 run_id_used", ctx do
      body = registration(Ecto.UUID.generate())
      assert register(ctx.key, body).status == 200

      conn = register(ctx.other, body)
      assert json_response(conn, 409) == %{"error" => "run_id_used"}
      assert signed_answer?(conn)
    end
  end

  describe "a direct run, from its registering node's active keys alone" do
    test "a gateway key of the same workspace is 409 wrong_node for a batch, 404 for an outcome",
         ctx do
      gateway = contract_key_fixture(ctx.scope, node: gateway_fixture(ctx.scope))
      gateway = {gateway.access_key, gateway.secret}
      run_id = Ecto.UUID.generate()
      assert register(ctx.key, registration(run_id)).status == 200

      conn = deliver(gateway, [beat(run_id, 2)])
      assert json_response(conn, 409) == %{"error" => "wrong_node"}
      assert signed_answer?(conn)

      conn = give(gateway, run_id)
      assert json_response(conn, 404) == %{"error" => "not_found"}
      assert signed_answer?(conn)

      run = run(run_id)
      assert events_of(run_id) == 0
      assert run.outcome_state == nil
      assert run.node_id == ctx.node.id
    end

    test "a pool's run takes its pool's keys, and refuses a node's; a node's run refuses a pool's",
         ctx do
      pool = pool_fixture(ctx.scope)
      %{access_key: first, secret: first_secret} = contract_key_fixture(ctx.scope, node: pool)
      %{access_key: second, secret: second_secret} = contract_key_fixture(ctx.scope, node: pool)
      {first, second} = {{first, first_secret}, {second, second_secret}}

      pooled = Ecto.UUID.generate()
      assert register(first, registration(pooled)).status == 200
      assert deliver(second, [beat(pooled, 2)]) |> response(202) == ""
      assert json_response(deliver(ctx.key, [beat(pooled, 3)]), 409) == %{"error" => "wrong_node"}
      assert json_response(give(ctx.key, pooled), 404) == %{"error" => "not_found"}
      assert run(pooled).node_id == pool.id
      assert events_of(pooled) == 1

      direct = Ecto.UUID.generate()
      assert register(ctx.key, registration(direct)).status == 200
      assert json_response(deliver(first, [beat(direct, 2)]), 409) == %{"error" => "wrong_node"}
      assert json_response(give(first, direct), 404) == %{"error" => "not_found"}
      assert events_of(direct) == 0
    end

    test "while a key is replaced the second key carries the run, and the revoked one is 401",
         ctx do
      run_id = Ecto.UUID.generate()
      assert register(ctx.key, registration(run_id)).status == 200

      {_subject, [started]} = first_events(run_id)
      assert deliver(ctx.key, [started]) |> response(202) == ""

      {key, _secret} = ctx.key
      {:ok, _} = AccessKeys.revoke_access_key(ctx.scope, key)

      # The key that registered the run is revoked: its batch and its outcome no longer
      # verify, and nothing of them is stored.
      conn = deliver(ctx.key, [beat(run_id, 3)])
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert unsigned_answer?(conn)

      conn = give(ctx.key, run_id)
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert unsigned_answer?(conn)

      assert events_of(run_id) == 1
      assert run(run_id).outcome_state == nil

      # The node's other key goes on: its batches and the outcome are the run's.
      assert deliver(ctx.second, [beat(run_id, 3)]) |> response(202) == ""
      assert response(give(ctx.second, run_id), 200) == ~s({"version":1})

      run = run(run_id)
      assert events_of(run_id) == 2
      assert run.outcome_state == "succeeded"
      assert run.node_id == ctx.node.id

      # Another node's key is still refused, for a batch and an outcome alike.
      assert json_response(deliver(ctx.other, [beat(run_id, 4)]), 409) == %{
               "error" => "wrong_node"
             }

      assert json_response(give(ctx.other, run_id, "failed"), 404) == %{"error" => "not_found"}
      assert run(run_id).outcome_state == "succeeded"
    end
  end
end
