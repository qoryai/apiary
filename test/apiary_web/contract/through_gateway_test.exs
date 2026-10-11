defmodule ApiaryWeb.Contract.ThroughGatewayTest do
  # A run that goes through a gateway: its registration, from a node whose choice resolves
  # to a gateway, is given a run key; the gateway the run key names attaches it; from then
  # on its batches, heartbeats and reloads are the gateway's alone, and its outcome its
  # node's.
  use ApiaryWeb.ConnCase, async: true

  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.Nodes.Node
  alias Apiary.{Repo, SigningKey}
  alias Apiary.Runs.{Attach, Batch, Delivery, Event, Ingest, Run, RunKey}

  setup do
    %{scope: scope} = sign_up_fixture()
    # The workspace's first gateway is its default, and the node made after it uses it.
    gateway = gateway_fixture(scope)

    %{access_key: gateway_key, secret: gateway_secret} =
      contract_key_fixture(scope, node: gateway)

    %{access_key: key, secret: secret, node: node} = contract_key_fixture(scope)
    assert node.gateway_choice == :default

    %{
      scope: scope,
      gateway: gateway,
      node: node,
      gateway_key: {gateway_key, gateway_secret},
      key: {key, secret}
    }
  end

  defp register({key, secret}, body),
    do: signed_register(build_conn(), key.key_id, secret, Jason.encode!(body))

  defp attach({key, secret}, run_id, body),
    do: signed_attach(build_conn(), key.key_id, secret, run_id, Jason.encode!(body))

  defp deliver({key, secret}, events), do: signed_post(build_conn(), key.key_id, secret, events)

  defp reload({key, secret}, run_id),
    do: signed_get(build_conn(), key.key_id, secret, "/v1/runs/" <> run_id)

  defp outcome({key, secret}, run_id, body) do
    signed_post(build_conn(), key.key_id, secret, Jason.encode!(body),
      target: "/v1/runs/#{run_id}/outcome",
      content_type: "application/json",
      delivery: nil
    )
  end

  defp run(run_id), do: Repo.one!(from r in Run, where: r.run_id == ^run_id)

  defp now, do: ApiaryWeb.Contract.SignedRequest.now() |> DateTime.from_unix!()

  defp beat(subject, sequence),
    do: wire_event(subject, sequence, "run.heartbeat", %{"elapsed_seconds" => 30})

  # Registers a run through the gateway and returns its id and run key.
  defp registered(ctx, attrs \\ %{}) do
    run_id = Ecto.UUID.generate()
    conn = register(ctx.key, gateway_registration(run_id, attrs))
    assert %{"run_key" => run_key} = json_response(conn, 200)
    {run_id, run_key}
  end

  # Registers a run through the gateway and attaches it: its id.
  defp attached(ctx) do
    {run_id, run_key} = registered(ctx)
    assert attach(ctx.gateway_key, run_id, attach_body(run_key)).status == 200
    run_id
  end

  # Another gateway of the workspace, with an active key.
  defp other_gateway(ctx) do
    gateway = gateway_fixture(ctx.scope)
    %{access_key: key, secret: secret} = contract_key_fixture(ctx.scope, node: gateway)
    {key, secret}
  end

  # The run's attach window closed a second ago, with whatever else `changes` sets.
  defp closed(run_id, changes \\ []) do
    window = [
      run_key_issued_at: DateTime.add(now(), -601, :second),
      attach_by: DateTime.add(now(), -1, :second)
    ]

    Repo.update_all(from(r in Run, where: r.run_id == ^run_id), set: window ++ changes)
  end

  defp set_choice(%Node{id: id}, changes),
    do: Repo.update_all(from(n in Node, where: n.id == ^id), set: changes)

  describe "a registration through a gateway" do
    test "is given the run's id and a run key that names the gateway, with no run configuration",
         ctx do
      run_id = Ecto.UUID.generate()
      conn = register(ctx.key, gateway_registration(run_id))

      assert conn.status == 200
      assert signed_answer?(conn)

      assert %{"version" => 1, "run_id" => ^run_id, "run_key" => run_key} =
               json_response(conn, 200)

      assert conn.resp_body =~ ~r/\A\{"version":1,"run_id":"[^"]+","run_key":"qrk_[^"]+"\}\z/
      assert get_resp_header(conn, "x-qory-run-configuration") == []
      assert get_resp_header(conn, "etag") == []
      assert [_digest] = get_resp_header(conn, "x-qory-configuration")

      {gateway_key, _secret} = ctx.gateway_key
      assert {:ok, grant, payload} = RunKey.verify(run_key)
      assert grant.run_id == run_id
      assert grant.workspace == ctx.scope.workspace.public_id
      assert grant.node_id == ctx.node.public_id
      assert grant.gateway == ctx.gateway.public_id
      assert grant.gateway_url == ctx.gateway.url
      assert grant.gateway_public_keys == [gateway_key.public_key]
      assert grant.instance_id == instance_id()
      assert DateTime.diff(grant.attach_by, grant.issued) == 600

      run = run(run_id)
      assert Run.through_gateway?(run)
      assert run.run_key_payload == payload
      assert run.gateway_id == ctx.gateway.id
      assert run.node_id == ctx.node.id
      assert run.state == "pending"
      assert {run.registration_interval_seconds, run.registration_answer_digest} == {nil, nil}
      assert DateTime.compare(run.attach_by, DateTime.truncate(run.attach_by, :second)) == :eq
      assert run.attached_at == nil
    end

    test "grants the attach window asked for, clamped to the ceiling", ctx do
      for {asked, granted} <- [{120, 120}, {3600, 3600}, {5000, 3600}] do
        {_run_id, run_key} = registered(ctx, %{"attach_seconds" => asked})
        {:ok, grant, _payload} = RunKey.verify(run_key)
        assert DateTime.diff(grant.attach_by, grant.issued) == granted, inspect(asked)
      end

      for asked <- [0, -1, 1.5, "60"] do
        conn =
          register(
            ctx.key,
            gateway_registration(Ecto.UUID.generate(), %{"attach_seconds" => asked})
          )

        assert json_response(conn, 400) == %{
                 "error" => "invalid_request",
                 "names" => ["attach_seconds"]
               }

        assert signed_answer?(conn)
      end
    end

    test "repeated with the same bytes is given the same run key, and stores nothing more", ctx do
      body = gateway_registration()
      first = register(ctx.key, body)
      again = register(ctx.key, body)

      assert again.status == 200
      assert again.resp_body == first.resp_body
      assert signed_answer?(again)
      assert Repo.aggregate(Run, :count) == 1
    end

    test "from a gateway's own key is 409 gateway_key, whatever its shape", ctx do
      for body <- [gateway_registration(), registration()] do
        conn = register(ctx.gateway_key, body)
        assert json_response(conn, 409) == %{"error" => "gateway_key"}
        assert signed_answer?(conn)
      end

      assert Repo.aggregate(Run, :count) == 0
    end

    test "a shape that does not match the node's choice is node_is_direct or node_uses_gateway",
         ctx do
      conn = register(ctx.key, registration())
      assert json_response(conn, 409) == %{"error" => "node_uses_gateway"}
      assert signed_answer?(conn)

      set_choice(ctx.node, gateway_choice: :direct)
      conn = register(ctx.key, gateway_registration())
      assert json_response(conn, 409) == %{"error" => "node_is_direct"}
      assert signed_answer?(conn)

      assert Repo.aggregate(Run, :count) == 0
    end

    test "a choice that leads nowhere is no_default_gateway, gateway_not_serving or gateway_without_key",
         ctx do
      # No default resolves: the gateway is not the default any more.
      Repo.update_all(from(n in Node, where: n.id == ^ctx.gateway.id),
        set: [default_gateway: false]
      )

      conn = register(ctx.key, gateway_registration())
      assert json_response(conn, 409) == %{"error" => "no_default_gateway"}
      assert signed_answer?(conn)

      # A named gateway of another organisation may not serve the node's workspace.
      %{scope: elsewhere} = sign_up_fixture()
      foreign = gateway_fixture(elsewhere)
      set_choice(ctx.node, gateway_choice: :named, gateway_id: foreign.id)
      conn = register(ctx.key, gateway_registration())
      assert json_response(conn, 409) == %{"error" => "gateway_not_serving"}

      # A named gateway with no active key.
      keyless = gateway_fixture(ctx.scope)
      set_choice(ctx.node, gateway_choice: :named, gateway_id: keyless.id)
      conn = register(ctx.key, gateway_registration())
      assert json_response(conn, 409) == %{"error" => "gateway_without_key"}
      assert signed_answer?(conn)

      assert Repo.aggregate(Run, :count) == 0
    end

    test "is refused for its route before the instance limit, and the limit before a used run id",
         ctx do
      pool = pool_fixture(ctx.scope, %{instance_limit: 1})
      %{access_key: key, secret: secret} = contract_key_fixture(ctx.scope, node: pool)
      pool_key = {key, secret}

      # The pool's one instance is taken by a run of another instance.
      {run_id, _run_key} = registered(%{ctx | key: pool_key})

      second = fn body ->
        signed_register(build_conn(), key.key_id, secret, Jason.encode!(body),
          instance_id: "i_another"
        )
      end

      assert json_response(second.(gateway_registration()), 409) == %{"error" => "instance_limit"}
      # A shape the choice refuses is refused for it first, taking no slot.
      assert json_response(second.(registration()), 409) == %{"error" => "node_uses_gateway"}
      # The run id is used, by the pool's own run, but the limit comes first.
      other_bytes = gateway_registration(run_id, %{"labels" => %{"other" => "x"}})

      assert json_response(second.(other_bytes), 409) == %{
               "error" => "instance_limit"
             }

      # The same pool instance, another body under the same run id: the run id is used.
      conn = register(pool_key, gateway_registration(run_id, %{"labels" => %{"other" => "x"}}))
      assert json_response(conn, 409) == %{"error" => "run_id_used"}
    end

    test "of a direct node is unchanged: its run configuration, with its digest", ctx do
      set_choice(ctx.node, gateway_choice: :direct)
      run_id = Ecto.UUID.generate()
      conn = register(ctx.key, registration(run_id))

      assert conn.status == 200
      assert signed_answer?(conn)
      assert [digest] = get_resp_header(conn, "x-qory-run-configuration")
      assert get_resp_header(conn, "etag") == [~s("#{digest}")]
      refute Map.has_key?(json_response(conn, 200), "run_key")

      run = run(run_id)
      refute Run.through_gateway?(run)
      assert run.gateway_id == nil
      assert run.registration_answer_digest == digest
    end
  end

  describe "an attach" do
    test "attaches the run: its run configuration, with the registration's labels and about",
         ctx do
      {run_id, run_key} = registered(ctx)
      conn = attach(ctx.gateway_key, run_id, attach_body(run_key, %{"interval_seconds" => 20}))

      assert conn.status == 200
      assert signed_answer?(conn)

      assert json_response(conn, 200) |> Map.take(~w(labels about)) == %{
               "labels" => %{"forge" => "git.example.com", "repository" => "acme/shop"},
               "about" => %{"title" => "Fix the failing build"}
             }

      assert [digest] = get_resp_header(conn, "x-qory-run-configuration")
      assert get_resp_header(conn, "etag") == [~s("#{digest}")]
      assert [_configuration] = get_resp_header(conn, "x-qory-configuration")

      run = run(run_id)
      assert run.attached_at != nil
      assert run.attach_interval_seconds == 20
      assert run.attach_answer_digest == digest
      assert run.forager_version == "0.4.0"
      assert run.contract_version == 1
      assert run.node_id == ctx.node.id
      assert run.state == "pending"
    end

    test "leaves out labels and about the registration did not have", ctx do
      {run_id, run_key} = registered(ctx, %{"labels" => nil, "about" => nil})
      conn = attach(ctx.gateway_key, run_id, attach_body(run_key))
      assert conn.status == 200
      refute Map.has_key?(json_response(conn, 200), "labels")
      refute Map.has_key?(json_response(conn, 200), "about")
    end

    test "repeated by the gateway under another of its keys is given the same answer", ctx do
      {run_id, run_key} = registered(ctx)
      first = attach(ctx.gateway_key, run_id, attach_body(run_key))
      attached_at = run(run_id).attached_at

      %{access_key: second, secret: secret} = contract_key_fixture(ctx.scope, node: ctx.gateway)
      again = attach({second, secret}, run_id, attach_body(run_key, %{"interval_seconds" => 60}))

      assert again.status == 200
      assert signed_answer?(again)
      assert again.resp_body == first.resp_body

      assert get_resp_header(again, "x-qory-run-configuration") ==
               get_resp_header(first, "x-qory-run-configuration")

      run = run(run_id)
      assert run.attached_at == attached_at
      assert run.attach_interval_seconds == 30
    end

    test "from a key that is not a gateway's is 409 not_a_gateway, before the run key is read",
         ctx do
      {run_id, run_key} = registered(ctx)

      for run_key <- [run_key, "qrk_not.a-run-key"] do
        conn = attach(ctx.key, run_id, attach_body(run_key))
        assert json_response(conn, 409) == %{"error" => "not_a_gateway"}
        assert signed_answer?(conn)
      end

      assert run(run_id).attached_at == nil
    end

    test "with a run key that does not verify, or of another run, is 400 run_key_invalid", ctx do
      {run_id, run_key} = registered(ctx)
      {other_id, other_key} = registered(ctx)
      [payload, _signature] = run_key |> String.trim_leading("qrk_") |> String.split(".")
      [_payload, signature] = other_key |> String.trim_leading("qrk_") |> String.split(".")

      for {path_id, run_key} <- [
            {run_id, "qrk_not.a-run-key"},
            {run_id, "qrk_" <> payload <> "." <> signature},
            {run_id, other_key},
            {other_id, run_key}
          ] do
        conn = attach(ctx.gateway_key, path_id, attach_body(run_key))
        assert json_response(conn, 400) == %{"error" => "run_key_invalid"}
        assert signed_answer?(conn)
      end

      assert Repo.aggregate(from(r in Run, where: not is_nil(r.attached_at)), :count) == 0
    end

    test "of a run that has ended is 410, before an expired window", ctx do
      {run_id, run_key} = registered(ctx)
      closed(run_id, state: "completed", exited_at: now())

      conn = attach(ctx.gateway_key, run_id, attach_body(run_key))
      assert response(conn, 410) == ""
      assert signed_answer?(conn)

      # A run whose record is gone has ended too.
      Repo.delete_all(from(r in Run, where: r.run_id == ^run_id))
      assert response(attach(ctx.gateway_key, run_id, attach_body(run_key)), 410) == ""
    end

    test "past its window is 409 run_key_expired, before another gateway is wrong", ctx do
      {run_id, run_key} = registered(ctx)
      closed(run_id)

      for gateway_key <- [ctx.gateway_key, other_gateway(ctx)] do
        conn = attach(gateway_key, run_id, attach_body(run_key))
        assert json_response(conn, 409) == %{"error" => "run_key_expired"}
        assert signed_answer?(conn)
      end
    end

    test "from a gateway the run key does not name is 409 wrong_gateway", ctx do
      {run_id, run_key} = registered(ctx)
      conn = attach(other_gateway(ctx), run_id, attach_body(run_key))
      assert json_response(conn, 409) == %{"error" => "wrong_gateway"}
      assert signed_answer?(conn)

      # Once its gateway attached it, another is still wrong, never given the run.
      assert attach(ctx.gateway_key, run_id, attach_body(run_key)).status == 200
      conn = attach(other_gateway(ctx), run_id, attach_body(run_key))
      assert json_response(conn, 409) == %{"error" => "wrong_gateway"}
    end

    test "by a gateway that may no longer serve the run's workspace is workspace_not_served",
         ctx do
      {run_id, run_key} = registered(ctx)

      # The gateway as it would be had it been deleted after its key was verified: core's
      # gateways serve their own workspace alone, and a deletion refuses while the run
      # waits, so its row is marked here, past the application. The attach reads the
      # gateway's row as it is once the run's row is held.
      {key, _secret} = ctx.gateway_key

      Repo.update_all(from(n in Node, where: n.id == ^key.node_id),
        set: [deleted_at: DateTime.utc_now(), default_gateway: false]
      )

      {:ok, body} = Attach.parse(attach_body(run_key))

      assert Attach.attach(key, run_id, body, %{}) == {:error, :workspace_not_served}
      assert run(run_id).attached_at == nil
    end

    test "with a body the contract refuses is 400 invalid_request, and a stale time 401", ctx do
      {run_id, run_key} = registered(ctx)

      for {attrs, name} <- [
            {%{"labels" => %{"a" => "b"}}, "body"},
            {%{"interval_seconds" => 301}, "interval_seconds"},
            {%{"run_key" => nil}, "run_key"},
            {%{"time" => "2026-10-11T12:00:00.5Z"}, "time"}
          ] do
        conn = attach(ctx.gateway_key, run_id, attach_body(run_key, attrs))
        assert json_response(conn, 400) == %{"error" => "invalid_request", "names" => [name]}
        assert signed_answer?(conn)
      end

      stale = now() |> DateTime.add(-301, :second) |> DateTime.to_iso8601()
      conn = attach(ctx.gateway_key, run_id, attach_body(run_key, %{"time" => stale}))
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert unsigned_answer?(conn)

      assert run(run_id).attached_at == nil
    end
  end

  describe "after the attach" do
    test "the gateway's batches and heartbeats are taken, and the run stays its node's", ctx do
      run_id = attached(ctx)
      {_subject, [started]} = first_events(run_id)

      conn = deliver(ctx.gateway_key, [started, beat(run_id, 3)])
      assert response(conn, 202) == ""
      assert signed_answer?(conn)

      run = run(run_id)
      assert run.event_count == 2
      assert run.state == "running"
      assert run.node_id == ctx.node.id
      assert run.instance_id == instance_id()
      assert run.workspace_id == ctx.scope.workspace.id
      assert [%Delivery{workspace_id: workspace_id}] = Repo.all(Delivery)
      assert workspace_id == ctx.scope.workspace.id
    end

    test "a batch or a heartbeat from any other key is 409 wrong_gateway, the node's own included",
         ctx do
      run_id = attached(ctx)
      {_subject, [started]} = first_events(run_id)

      for key <- [ctx.key, other_gateway(ctx)], events <- [[started], [beat(run_id, 2)]] do
        conn = deliver(key, events)
        assert json_response(conn, 409) == %{"error" => "wrong_gateway"}
        assert signed_answer?(conn)
      end

      assert Repo.aggregate(Event, :count) == 0
    end

    test "before the attach nobody's batch is taken, the gateway's included", ctx do
      {run_id, _run_key} = registered(ctx)
      {_subject, events} = first_events(run_id)

      for key <- [ctx.gateway_key, ctx.key] do
        assert json_response(deliver(key, events), 409) == %{"error" => "wrong_gateway"}
      end

      assert Repo.aggregate(Event, :count) == 0
    end

    test "a gateway's batch of a run it did not register opens none", ctx do
      {subject, events} = first_events()
      conn = deliver(ctx.gateway_key, events)

      assert json_response(conn, 409) == %{"error" => "wrong_gateway"}
      assert signed_answer?(conn)
      assert Repo.all(from r in Run, where: r.run_id == ^subject) == []
    end

    @tag needs: :security
    test "a reload is answered to the gateway alone", ctx do
      {:ok, _rule} = Apiary.Policy.allow(ctx.scope, nil, %{host: "api.example"})
      {run_id, run_key} = registered(ctx)

      # Before the attach, nobody's.
      assert json_response(reload(ctx.gateway_key, run_id), 404) == %{"error" => "not_found"}

      attached = attach(ctx.gateway_key, run_id, attach_body(run_key))
      conn = reload(ctx.gateway_key, run_id)
      assert conn.status == 200
      assert signed_answer?(conn)

      assert get_resp_header(conn, "x-qory-run-configuration") ==
               get_resp_header(attached, "x-qory-run-configuration")

      refute Map.has_key?(json_response(conn, 200), "labels")

      for key <- [ctx.key, other_gateway(ctx)] do
        conn = reload(key, run_id)
        assert json_response(conn, 404) == %{"error" => "not_found"}
        assert signed_answer?(conn)
      end
    end

    test "the run's clock offset is its heartbeats' alone, never its attach's", ctx do
      {run_id, run_key} = registered(ctx)
      # The gateway's clock two minutes behind this server's.
      behind = now() |> DateTime.add(-120, :second) |> DateTime.to_iso8601()

      assert attach(ctx.gateway_key, run_id, attach_body(run_key, %{"time" => behind})).status ==
               200

      {_subject, [started]} = first_events(run_id)
      assert response(deliver(ctx.gateway_key, [started]), 202) == ""

      assert {:ok, %{clock_offset_ms: nil}} = Apiary.Runs.Projector.project(run(run_id))
    end

    test "the outcome is the node's, and a batch after it is answered with the run's end", ctx do
      run_id = attached(ctx)
      body = %{"version" => 1, "state" => "succeeded", "time" => DateTime.to_iso8601(now())}

      conn = outcome(ctx.gateway_key, run_id, body)
      assert json_response(conn, 404) == %{"error" => "not_found"}

      conn = outcome(ctx.key, run_id, body)
      assert json_response(conn, 200) == %{"version" => 1}
      assert signed_answer?(conn)

      # A retry is the same outcome by its state and reason, whatever its time, and the
      # node's alone: the gateway is not given the repeat. Another state is refused.
      given = Map.take(run(run_id), [:outcome_time, :outcome_received_at, :outcome_digest])
      later = %{body | "time" => DateTime.to_iso8601(DateTime.add(now(), 5))}
      assert json_response(outcome(ctx.key, run_id, later), 200) == %{"version" => 1}

      assert json_response(outcome(ctx.gateway_key, run_id, later), 404) == %{
               "error" => "not_found"
             }

      assert json_response(outcome(ctx.key, run_id, %{body | "state" => "failed"}), 409) ==
               %{"error" => "outcome_given"}

      assert Map.take(run(run_id), [:outcome_time, :outcome_received_at, :outcome_digest]) ==
               given

      {_subject, [started]} = first_events(run_id)
      conn = deliver(ctx.gateway_key, [started])
      assert conn.status in 200..299
      assert signed_answer?(conn)
      assert %{"end" => %{"state" => "succeeded"}} = Jason.decode!(conn.resp_body)
      assert run(run_id).event_count == 1

      # Ended, the run is attached no more.
      run_key = RunKey.encode(run(run_id).run_key_payload, SigningKey.current())
      assert response(attach(ctx.gateway_key, run_id, attach_body(run_key)), 410) == ""
    end
  end

  describe "what a run through a gateway is held to" do
    test "a repeat of its registration is given the run key it was first given, byte for byte",
         ctx do
      body = gateway_registration()
      first = register(ctx.key, body)
      %{"run_id" => run_id, "run_key" => run_key} = json_response(first, 200)

      # The run keeps the signature it was given: a repeat signs nothing again, so a
      # change of the instance's signing key cannot give it a run key that verifies nowhere.
      assert {payload, signature} = RunKey.parts(run_key)
      run = run(run_id)
      assert {run.run_key_payload, run.run_key_signature} == {payload, signature}

      other = :crypto.strong_rand_bytes(64)
      Repo.update_all(from(r in Run, where: r.run_id == ^run_id), set: [run_key_signature: other])

      assert %{"run_key" => again} = json_response(register(ctx.key, body), 200)
      assert again == RunKey.assemble(payload, other)
    end

    test "a run found lost before its gateway attached it is run_key_expired, and stays lost",
         ctx do
      {run_id, run_key} = registered(ctx)
      # As the lost-run check leaves it at its attach_by, or a person's clearing of its
      # instance does, its window not yet past on the clock.
      Repo.update_all(from(r in Run, where: r.run_id == ^run_id),
        set: [state: "lost", lost_at: now()]
      )

      conn = attach(ctx.gateway_key, run_id, attach_body(run_key))
      assert json_response(conn, 409) == %{"error" => "run_key_expired"}
      assert signed_answer?(conn)

      run = run(run_id)
      assert {run.state, run.attached_at} == {"lost", nil}
    end

    test "a gateway of another organisation is wrong_gateway, and the run stays unattached",
         ctx do
      {run_id, run_key} = registered(ctx)
      %{scope: elsewhere} = sign_up_fixture()
      foreign = gateway_fixture(elsewhere)
      %{access_key: key, secret: secret} = contract_key_fixture(elsewhere, node: foreign)

      conn = attach({key, secret}, run_id, attach_body(run_key))
      assert json_response(conn, 409) == %{"error" => "wrong_gateway"}
      assert signed_answer?(conn)
      assert run(run_id).attached_at == nil
    end

    test "out of use, the run's organisation refuses the attach and the batches, 401", ctx do
      {run_id, run_key} = registered(ctx)
      {gateway_key, _secret} = ctx.gateway_key
      {:ok, body} = Attach.parse(attach_body(run_key))
      run_id_attached = attached(ctx)
      {_subject, events} = first_events(run_id_attached)
      {:ok, batch} = events |> Jason.encode!() |> Batch.parse()

      # Out of use as the edition puts an organisation out of use: marked for deletion here.
      :ok = Apiary.EditionKit.module().hide_instance_organisation(ctx.scope.organisation.id)

      # Over the wire the gateway's own key, of the same organisation, no longer verifies.
      conn = attach(ctx.gateway_key, run_id, attach_body(run_key))
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert unsigned_answer?(conn)
      conn = deliver(ctx.gateway_key, events)
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert unsigned_answer?(conn)

      # And the run's own place is refused whatever the key: the key verified before the mark.
      assert Attach.attach(gateway_key, run_id, body, %{}) == {:error, :unauthorized}

      assert Ingest.ingest(gateway_key, batch, %{contract_version: 1, instance_id: instance_id()}) ==
               {:error, :unauthorized}

      assert run(run_id).attached_at == nil
      assert Repo.aggregate(Event, :count) == 0
    end

    test "a gateway that is deleted attaches nothing and sends nothing", ctx do
      {run_id, run_key} = registered(ctx)
      attached_id = attached(ctx)
      {_subject, events} = first_events(attached_id)

      Repo.update_all(from(n in Node, where: n.id == ^ctx.gateway.id),
        set: [deleted_at: DateTime.utc_now(), default_gateway: false]
      )

      conn = attach(ctx.gateway_key, run_id, attach_body(run_key))
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert json_response(deliver(ctx.gateway_key, events), 401) == %{"error" => "unauthorized"}
      assert run(run_id).attached_at == nil
      assert Repo.aggregate(Event, :count) == 0
    end

    test "a run whose registering node is deleted still takes its gateway's batches", ctx do
      run_id = attached(ctx)
      {_subject, events} = first_events(run_id)

      Repo.update_all(from(n in Node, where: n.id == ^ctx.node.id),
        set: [deleted_at: DateTime.utc_now()]
      )

      assert response(deliver(ctx.gateway_key, events), 202) == ""
      assert run(run_id).event_count == 1
    end
  end
end
