defmodule ApiaryWeb.Contract.NodeBoundRunsTest do
  # A run is bound to the node whose key registered it, or whose key's batch opened it: its
  # batches, its heartbeats among them, and its reloads are taken from that node's active
  # keys alone, whichever of them signs (`Apiary.Runs.Sender`).
  use ApiaryWeb.ConnCase, async: true

  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.Repo
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

  defp run(run_id), do: Repo.one!(from r in Run, where: r.run_id == ^run_id)

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
end
