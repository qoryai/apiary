defmodule ApiaryWeb.Contract.EventsNodesTest do
  @moduledoc """
  The events endpoint, the run endpoint and nodes: each run records its node and the
  instance its registration or first batch claimed, each delivery its instance; a run's
  registration is held to the node's instance limit, a signed 409 `instance_limit` with
  nothing stored, and a batch to none; and a batch that holds a ping, which the contract no
  longer has, is a signed 400 `invalid_request`.
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

  defp register(%{key: key, secret: secret}, body, opts),
    do: signed_register(build_conn(), key.key_id, secret, body, opts)

  defp run!(subject), do: Repo.one!(from r in Run, where: r.run_id == ^subject)

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
      {subject, batch} = first_events()
      assert register(ctx, registration(subject), instance_id: "i_one").status == 200
      assert deliver(ctx, batch, instance_id: "i_two").status == 202

      assert run!(subject).instance_id == "i_one"
      assert [%Delivery{instance_id: "i_two"}] = Repo.all(Delivery)
    end
  end

  describe "the instance limit" do
    test "a node runs one instance: another's registration of a new run is a signed 409, nothing stored",
         %{scope: scope} do
      ctx = key_on(scope, node_fixture(scope))
      assert register(ctx, registration(), instance_id: "i_one").status == 200

      # The same instance starts another run: it takes no second slot.
      assert register(ctx, registration(), instance_id: "i_one").status == 200

      refused = Ecto.UUID.generate()
      conn = register(ctx, registration(refused), instance_id: "i_two")
      assert json_response(conn, 409) == %{"error" => "instance_limit"}
      assert signed_answer?(conn)

      refute Repo.exists?(from r in Run, where: r.run_id == ^refused)

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

      assert register(ctx, registration(), instance_id: "i_two").status == 200
    end

    test "a pool runs up to its limit; a pool without one, any number", %{scope: scope} do
      limited = key_on(scope, pool_fixture(scope, %{instance_limit: 2}))

      for instance <- ["i_one", "i_two"] do
        assert register(limited, registration(), instance_id: instance).status == 200
      end

      assert json_response(register(limited, registration(), instance_id: "i_three"), 409) ==
               %{"error" => "instance_limit"}

      open = key_on(scope, pool_fixture(scope))

      for n <- 1..5 do
        assert register(open, registration(), instance_id: "i_#{n}").status == 200
      end
    end

    test "only a registration is held to it: a batch of a new run is stored", %{scope: scope} do
      ctx = key_on(scope, node_fixture(scope))
      assert register(ctx, registration(), instance_id: "i_one").status == 200

      {_subject, batch} = first_events()
      assert deliver(ctx, batch, instance_id: "i_two").status == 202
    end

    test "a registration sent again, the same bytes, is answered again whatever the limit",
         %{scope: scope} do
      ctx = key_on(scope, node_fixture(scope))
      body = Jason.encode!(registration())

      first = register(ctx, body, instance_id: "i_one")
      assert first.status == 200
      assert register(ctx, registration(), instance_id: "i_one").status == 200

      again = register(ctx, body, instance_id: "i_one")
      assert again.status == 200
      assert again.resp_body == first.resp_body

      node = Repo.get!(Node, ctx.node.id)
      assert node.instance_limit_refused == 0
    end
  end

  describe "the ping" do
    test "a batch that holds one is a signed 400 invalid_request, whatever its interval",
         %{scope: scope} do
      ctx = key_on(scope, pool_fixture(scope))

      for interval <- [30, 301, nil] do
        subject = Ecto.UUID.generate()
        ping = wire_event(subject, 1, "ping", %{"interval_seconds" => interval})
        {_subject, batch} = first_events(subject)

        for events <- [[ping], [ping | batch]] do
          conn = deliver(ctx, events)
          assert json_response(conn, 400) == %{"error" => "invalid_request"}, inspect(interval)
          assert signed_answer?(conn)
        end
      end

      assert Repo.aggregate(Run, :count) == 0
      assert Repo.aggregate(Event, :count) == 0
    end

    test "a heartbeat's interval_seconds is read by nothing here", %{scope: scope} do
      ctx = key_on(scope, pool_fixture(scope))
      subject = Ecto.UUID.generate()

      beat =
        wire_event(subject, 3, "run.heartbeat", %{
          "elapsed_seconds" => 1,
          "interval_seconds" => 3600
        })

      assert deliver(ctx, [beat]).status == 202
    end
  end
end
