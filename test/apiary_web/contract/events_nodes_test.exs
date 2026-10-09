defmodule ApiaryWeb.Contract.EventsNodesTest do
  @moduledoc """
  The events endpoint and nodes: each run records its node and the instance its first
  batch claimed, each delivery its instance; the ping of a new run is held to the node's
  instance limit, a signed 409 `instance_limit` with nothing stored; and a ping announces
  its heartbeat interval, from 1 to 300 seconds, or the batch is a signed 400
  `invalid_request`.
  """
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Nodes.Node
  alias Apiary.Repo
  alias Apiary.Runs.{Delivery, Event, Run}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp key_on(scope, node) do
    %{access_key: key, secret: secret} = contract_key_fixture(scope, node: node)
    %{key: key, secret: secret, node: node}
  end

  defp deliver(%{key: key, secret: secret}, events, opts \\ []),
    do: signed_post(build_conn(), key.key_id, secret, events, opts)

  defp run!(subject), do: Repo.one!(from r in Run, where: r.run_id == ^subject)

  defp ping(subject, interval \\ 30) do
    {_subject, [ping, _started]} = first_events(subject)
    put_in(ping, ["data", "interval_seconds"], interval)
  end

  describe "where a run runs" do
    test "the run records the key's node and the claimed instance; the delivery the instance",
         %{scope: scope} do
      ctx = key_on(scope, node_fixture(scope))
      {subject, batch} = first_events()

      conn = deliver(ctx, batch, instance_id: "i_build-01")
      assert response(conn, 202) == ""
      assert signed_answer?(conn)

      run = run!(subject)
      assert run.node_id == ctx.node.id
      assert run.instance_id == "i_build-01"
      assert run.access_key_id == ctx.key.id
      assert [%Delivery{instance_id: "i_build-01"}] = Repo.all(Delivery)
    end

    test "a later batch from another instance leaves the run where it was", %{scope: scope} do
      ctx = key_on(scope, pool_fixture(scope))
      {subject, [ping, started]} = first_events()

      assert deliver(ctx, [ping], instance_id: "i_one").status == 202
      assert deliver(ctx, [started], instance_id: "i_two").status == 202

      assert run!(subject).instance_id == "i_one"

      assert ["i_one", "i_two"] ==
               Repo.all(from d in Delivery, order_by: d.instance_id, select: d.instance_id)
    end
  end

  describe "the instance limit" do
    test "a node runs one instance: another's ping of a new run is a signed 409, nothing stored",
         %{scope: scope} do
      ctx = key_on(scope, node_fixture(scope))
      first = Ecto.UUID.generate()
      assert deliver(ctx, [ping(first)], instance_id: "i_one").status == 202

      # The same instance starts another run: it takes no second slot.
      assert deliver(ctx, [ping(Ecto.UUID.generate())], instance_id: "i_one").status == 202

      refused = Ecto.UUID.generate()
      conn = deliver(ctx, [ping(refused)], instance_id: "i_two")
      assert json_response(conn, 409) == %{"error" => "instance_limit"}
      assert signed_answer?(conn)

      refute Repo.exists?(from r in Run, where: r.run_id == ^refused)
      refute Repo.exists?(from d in Delivery, where: d.run_id == ^refused)

      assert Repo.aggregate(
               from(e in Event, join: r in assoc(e, :run), where: r.run_id == ^refused),
               :count
             ) == 0

      node = Repo.get!(Node, ctx.node.id)
      assert node.instance_limit_refused == 1
      assert node.instance_limit_refused_at
    end

    test "an instance counts while its run is live: once lost, another may start",
         %{scope: scope} do
      ctx = key_on(scope, node_fixture(scope))
      long_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

      node_run_fixture(ctx.node, "i_one",
        state: "running",
        inserted_at: long_ago,
        started_at: long_ago
      )

      assert deliver(ctx, [ping(Ecto.UUID.generate())], instance_id: "i_two").status == 202
    end

    test "a pool runs up to its limit; a pool without one, any number", %{scope: scope} do
      limited = key_on(scope, pool_fixture(scope, %{instance_limit: 2}))

      for instance <- ["i_one", "i_two"] do
        assert deliver(limited, [ping(Ecto.UUID.generate())], instance_id: instance).status == 202
      end

      assert json_response(
               deliver(limited, [ping(Ecto.UUID.generate())], instance_id: "i_three"),
               409
             ) ==
               %{"error" => "instance_limit"}

      open = key_on(scope, pool_fixture(scope))

      for n <- 1..5 do
        assert deliver(open, [ping(Ecto.UUID.generate())], instance_id: "i_#{n}").status == 202
      end
    end

    test "only a ping is held to it: another batch of a new run is stored", %{scope: scope} do
      ctx = key_on(scope, node_fixture(scope))
      assert deliver(ctx, [ping(Ecto.UUID.generate())], instance_id: "i_one").status == 202

      {_subject, [_ping, started]} = first_events()
      assert deliver(ctx, [started], instance_id: "i_two").status == 202
    end

    test "a ping delivered again, of a run already stored, is 202 whatever the limit",
         %{scope: scope} do
      ctx = key_on(scope, node_fixture(scope))
      subject = Ecto.UUID.generate()
      body = Jason.encode!([ping(subject)])
      delivery = Ecto.UUID.generate()

      assert deliver(ctx, body, instance_id: "i_one", delivery: delivery).status == 202
      assert deliver(ctx, [ping(Ecto.UUID.generate())], instance_id: "i_one").status == 202
      assert deliver(ctx, body, instance_id: "i_one", delivery: delivery).status == 202
    end
  end

  describe "the ping's interval" do
    test "from 1 to 300 seconds is accepted", %{scope: scope} do
      ctx = key_on(scope, pool_fixture(scope))

      for interval <- [1, 30, 300] do
        assert deliver(ctx, [ping(Ecto.UUID.generate(), interval)]).status == 202
      end
    end

    test "above 300, below 1, not an integer or absent is a signed 400 invalid_request",
         %{scope: scope} do
      ctx = key_on(scope, pool_fixture(scope))

      for interval <- [301, 3600, 0, -1, 30.0, "30", nil] do
        conn = deliver(ctx, [ping(Ecto.UUID.generate(), interval)])
        assert json_response(conn, 400) == %{"error" => "invalid_request"}, inspect(interval)
        assert signed_answer?(conn)
      end

      {_subject, [ping, _started]} = first_events()
      conn = deliver(ctx, [update_in(ping, ["data"], &Map.delete(&1, "interval_seconds"))])
      assert json_response(conn, 400) == %{"error" => "invalid_request"}

      assert Repo.aggregate(Run, :count) == 0
    end

    test "is read only on a ping", %{scope: scope} do
      ctx = key_on(scope, pool_fixture(scope))
      subject = Ecto.UUID.generate()

      beat =
        wire_event(subject, 1, "run.heartbeat", %{
          "elapsed_seconds" => 1,
          "interval_seconds" => 3600
        })

      assert deliver(ctx, [beat]).status == 202
    end
  end
end
