defmodule ApiaryWeb.Contract.QueuedRunIdTest do
  # A registration at the run endpoint whose run id is that of a run of a workspace's
  # queue: `409` `run_id_used`, signed, under any key, a node's, a node pool's or a
  # gateway's alike, on the whole instance and in every state of the run; after the
  # refusals every signed request gets and the body's and the `time`'s, and before every
  # answer that depends on the key. Nothing is stored, counted or recorded on the refusal.
  use ApiaryWeb.ConnCase, async: true

  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures
  import Ecto.Query

  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Nodes.Node
  alias Apiary.Repo
  alias Apiary.Runs.{Registration, Run}

  @run_id_used %{"error" => "run_id_used"}
  @unauthorized %{"error" => "unauthorized"}

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

  # A key of `node` of the scope's workspace, as the signing helpers take it.
  defp key(scope, node) do
    %{access_key: key, secret: secret} = contract_key_fixture(scope, node: node)
    %{key: key, secret: secret}
  end

  defp register(%{key: key, secret: secret}, body, opts \\ []),
    do: signed_register(build_conn(), key.key_id, secret, Jason.encode!(body), opts)

  defp runs(run_id), do: Repo.aggregate(from(r in Run, where: r.node_run_id == ^run_id), :count)

  defp refused?(conn) do
    json_response(conn, 409) == @run_id_used and signed_answer?(conn) and
      get_resp_header(conn, "x-qory-run-configuration") == [] and
      get_resp_header(conn, "etag") == []
  end

  # A node's key, a node pool's, a gateway's of the workspace and a gateway's of the
  # organisation.
  defp every_kind(scope) do
    gateway = gateway_fixture(scope)

    [
      node: key(scope, node_fixture(scope)),
      pool: key(scope, pool_fixture(scope)),
      gateway: key(scope, gateway),
      organisation_gateway: key(scope, organisation_gateway_fixture(scope))
    ]
  end

  describe "a run id of a run of the queue" do
    test "is 409 run_id_used, signed, under every kind of key, in either shape", ctx do
      for {kind, key} <- every_kind(ctx.scope),
          body <- [
            registration(ctx.queued.run_id),
            gateway_registration(ctx.queued.run_id)
          ] do
        conn = register(key, body)
        assert refused?(conn), "#{kind}: #{conn.status} #{conn.resp_body}"
        assert Repo.reload!(key.key).last_used_at == nil, "#{kind}"
      end

      assert runs(ctx.queued.run_id) == 0
    end

    test "is refused on the whole instance: a run of another organisation's queue", ctx do
      %{scope: other} = sign_up_fixture()
      theirs = queued!(other)
      ours = key(ctx.scope, node_fixture(ctx.scope))

      assert refused?(register(ours, registration(theirs.run_id)))
      assert runs(theirs.run_id) == 0
    end

    test "is refused in every state of the run", ctx do
      ours = key(ctx.scope, pool_fixture(ctx.scope))

      for changes <- [
            [state: :claimed],
            [state: :handed_over],
            [state: :ended, end_cause: :released],
            [state: :ended, end_cause: :lost]
          ] do
        Repo.update_all(from(d in DispatchRun, where: d.id == ^ctx.queued.id), set: changes)
        assert refused?(register(ours, registration(ctx.queued.run_id))), inspect(changes)
      end

      assert runs(ctx.queued.run_id) == 0
    end

    test "leaves every other run id to the answers it had", ctx do
      [node: node, pool: pool, gateway: gateway, organisation_gateway: org_gateway] =
        every_kind(ctx.scope)

      # The node and the pool were made after the workspace's first gateway, its default.
      assert register(node, gateway_registration()).status == 200
      assert register(pool, gateway_registration()).status == 200

      for key <- [gateway, org_gateway] do
        conn = register(key, gateway_registration())
        assert json_response(conn, 409) == %{"error" => "gateway_key"}
      end

      conn = register(node, registration())
      assert json_response(conn, 409) == %{"error" => "node_uses_gateway"}
    end
  end

  describe "the refusals before it" do
    setup ctx, do: %{ours: key(ctx.scope, node_fixture(ctx.scope))}

    test "a signature that does not verify is 401, unsigned", ctx do
      conn =
        signed_register(
          build_conn(),
          ctx.ours.key.key_id,
          "not the secret",
          Jason.encode!(registration(ctx.queued.run_id))
        )

      assert json_response(conn, 401) == @unauthorized
      assert unsigned_answer?(conn)
    end

    test "a key the instance does not hold is 401, unsigned", ctx do
      {:ok, _key} = Apiary.AccessKeys.revoke_access_key(ctx.scope, ctx.ours.key)
      conn = register(ctx.ours, registration(ctx.queued.run_id))
      assert json_response(conn, 401) == @unauthorized
      assert unsigned_answer?(conn)
    end

    test "a content type other than application/json is 415, unsigned", ctx do
      conn =
        register(ctx.ours, registration(ctx.queued.run_id), content_type: "text/plain")

      assert json_response(conn, 415) == %{"error" => "unsupported_media_type"}
      assert unsigned_answer?(conn)
    end

    test "a body the contract refuses is 400 invalid_request, signed", ctx do
      conn = register(ctx.ours, registration(ctx.queued.run_id, %{"extra" => true}))
      assert json_response(conn, 400) == %{"error" => "invalid_request", "names" => ["body"]}
      assert signed_answer?(conn)
    end

    test "a time more than 300 seconds from the server's clock is 401, unsigned", ctx do
      stale =
        ApiaryWeb.Contract.SignedRequest.now()
        |> Kernel.-(301)
        |> DateTime.from_unix!()
        |> DateTime.to_iso8601()

      conn = register(ctx.ours, registration(ctx.queued.run_id, %{"time" => stale}))
      assert json_response(conn, 401) == @unauthorized
      assert unsigned_answer?(conn)
    end
  end

  describe "the answers after it" do
    setup ctx, do: %{node: node_fixture(ctx.scope)}

    test "a key that may not open a run is 404 for any other run id", ctx do
      ours = key(ctx.scope, ctx.node)
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.NoRunPosting)

      assert refused?(register(ours, registration(ctx.queued.run_id)))

      conn = register(ours, registration())
      assert json_response(conn, 404) == %{"error" => "not_found"}
      assert signed_answer?(conn)
    end

    test "the same bytes a run of this id registered with are refused, not repeated", ctx do
      ours = key(ctx.scope, ctx.node)
      body = Jason.encode!(registration())
      run_id = Jason.decode!(body)["run_id"]
      first = signed_register(build_conn(), ours.key.key_id, ours.secret, body)
      assert first.status == 200

      # The run's id is then that of a run of the queue.
      queue_as(ctx.queued, run_id)
      again = signed_register(build_conn(), ours.key.key_id, ours.secret, body)
      assert refused?(again)
      assert runs(run_id) == 1
    end

    test "a run of this id whose events retention has pruned is refused, not 410", ctx do
      ours = key(ctx.scope, ctx.node)
      run_id = Ecto.UUID.generate()
      assert register(ours, registration(run_id)).status == 200

      Repo.update_all(from(r in Run, where: r.node_run_id == ^run_id),
        set: [events_pruned_at: DateTime.utc_now()]
      )

      queue_as(ctx.queued, run_id)
      assert refused?(register(ours, registration(run_id, %{"labels" => %{"task" => "x"}})))
    end

    test "a shape the node's choice does not take is refused, not node_is_direct", ctx do
      ours = key(ctx.scope, ctx.node)
      assert %Node{gateway_choice: :direct} = ctx.node

      conn = register(ours, gateway_registration())
      assert json_response(conn, 409) == %{"error" => "node_is_direct"}

      assert refused?(register(ours, gateway_registration(ctx.queued.run_id)))
    end

    test "an instance beyond the node's limit is refused, and the refusal is not counted",
         ctx do
      ours = key(ctx.scope, ctx.node)
      assert register(ours, registration(), instance_id: "i_one").status == 200

      conn = register(ours, registration(), instance_id: "i_two")
      assert json_response(conn, 409) == %{"error" => "instance_limit"}
      counted = Repo.reload!(ctx.node).instance_limit_refused
      assert counted == 1

      conn = register(ours, registration(ctx.queued.run_id), instance_id: "i_two")
      assert refused?(conn)
      assert Repo.reload!(ctx.node).instance_limit_refused == counted
      assert runs(ctx.queued.run_id) == 0
    end
  end

  describe "a registration that skips the lookup" do
    test "registers a run of the queue under a pool's key; register/3 refuses it", ctx do
      %{access_key: key} = contract_key_fixture(ctx.scope, node: pool_fixture(ctx.scope))
      bytes = Jason.encode!(registration(ctx.queued.run_id))
      {:ok, registration} = Registration.parse(Jason.decode!(bytes))
      meta = %{body: bytes, contract_version: 1, instance_id: ctx.queued.run_id}

      assert Registration.register(key, registration, meta) == {:error, :run_id_used}
      assert runs(ctx.queued.run_id) == 0

      assert {:ok, %{run: %Run{node_run_id: run_id}, repeated: false}} =
               Registration.register_without_dispatch_lookup(key, registration, meta)

      assert run_id == ctx.queued.run_id
    end
  end

  # Gives the run of the queue `run_id`, as if it had been queued with it.
  defp queue_as(%DispatchRun{id: id}, run_id),
    do: Repo.update_all(from(d in DispatchRun, where: d.id == ^id), set: [run_id: run_id])
end
