defmodule ApiaryWeb.Contract.ThroughOrganisationGatewayTest do
  # A run that goes through a gateway of the organisation, which has no workspace: its
  # discovery, a registration from a node of any workspace of the organisation, the
  # attach, the batches and the outcome, through the endpoints. Then, through the
  # edition's seams, a gateway of another organisation that serves this one's
  # workspaces, while that organisation is out of use.
  use ApiaryWeb.ConnCase, async: true

  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.{Edition, EditionStubs, Repo}
  alias Apiary.Runs.{Run, RunKey}
  alias ApiaryWeb.Contract.Configuration

  setup do
    %{scope: scope} = sign_up_fixture()
    workspace = workspace_fixture(scope.organisation)
    elsewhere = workspace_scope(scope.user, workspace)

    # The organisation's first gateway is its default, and the node made after it, in
    # either workspace, uses it.
    gateway = organisation_gateway_fixture(scope)

    %{access_key: gateway_key, secret: gateway_secret} =
      contract_key_fixture(scope, node: gateway)

    %{access_key: key, secret: secret, node: node} = contract_key_fixture(elsewhere)
    assert node.gateway_choice == :default

    %{
      scope: scope,
      elsewhere: elsewhere,
      gateway: gateway,
      node: node,
      gateway_key: {gateway_key, gateway_secret},
      key: {key, secret}
    }
  end

  defp discover({key, secret}),
    do: signed_get(build_conn(), key.key_id, secret, "/.well-known/qory-configuration")

  defp register({key, secret}, body),
    do: signed_register(build_conn(), key.key_id, secret, Jason.encode!(body))

  defp attach({key, secret}, run_id, body),
    do: signed_attach(build_conn(), key.key_id, secret, run_id, Jason.encode!(body))

  defp deliver({key, secret}, events),
    do: signed_post(build_conn(), key.key_id, secret, events)

  defp outcome({key, secret}, run_id, body) do
    signed_post(build_conn(), key.key_id, secret, Jason.encode!(body),
      target: "/v1/runs/#{run_id}/outcome",
      content_type: "application/json",
      delivery: nil
    )
  end

  defp run(run_id), do: Repo.one!(from r in Run, where: r.run_id == ^run_id)

  defp now, do: ApiaryWeb.Contract.SignedRequest.now() |> DateTime.from_unix!()

  defp digest({key, _secret}) do
    {:ok, key} = Apiary.AccessKeys.fetch_for_verification(key.key_id)
    [Configuration.digest(key)]
  end

  # A run registered by `key`'s node through its gateway: its id and run key.
  defp registered(key) do
    run_id = Ecto.UUID.generate()
    conn = register(key, gateway_registration(run_id))
    assert %{"run_key" => run_key} = json_response(conn, 200)
    {run_id, run_key}
  end

  # The whole of a run through `gateway_key`, registered by `key`'s node, of `workspace`.
  defp carried(%{gateway_key: gateway_key, key: key, gateway: gateway}, workspace) do
    assert json_response(discover(gateway_key), 200)["node_id"] == gateway.public_id
    refute Map.has_key?(json_response(discover(gateway_key), 200), "workspaces")

    run_id = Ecto.UUID.generate()
    conn = register(key, gateway_registration(run_id))
    assert %{"run_key" => run_key} = json_response(conn, 200)
    assert signed_answer?(conn)

    {:ok, grant, _payload} = RunKey.verify(run_key)
    assert grant.workspace == workspace.public_id
    assert grant.gateway == gateway.public_id

    conn = attach(gateway_key, run_id, attach_body(run_key))
    assert conn.status == 200
    assert signed_answer?(conn)
    assert get_resp_header(conn, "x-qory-configuration") == digest(gateway_key)

    {_subject, [started]} = first_events(run_id)
    conn = deliver(gateway_key, [started])
    assert response(conn, 202) == ""
    assert get_resp_header(conn, "x-qory-configuration") == digest(gateway_key)

    body = %{"version" => 1, "state" => "succeeded", "time" => DateTime.to_iso8601(now())}
    assert json_response(outcome(key, run_id, body), 200) == %{"version" => 1}

    run = run(run_id)
    assert run.workspace_id == workspace.id
    assert run.gateway_id == gateway.id
    assert run.event_count == 1
    assert run.outcome_state
    run
  end

  describe "a gateway of the organisation" do
    test "is given a document without workspaces, under the digest every answer names",
         ctx do
      conn = discover(ctx.gateway_key)
      document = json_response(conn, 200)

      assert document["node_id"] == ctx.gateway.public_id
      refute Map.has_key?(document, "workspaces")
      assert signed_answer?(conn)
      assert get_resp_header(conn, "x-qory-configuration") == digest(ctx.gateway_key)
    end

    test "carries a run of a node of any workspace of the organisation", ctx do
      carried(ctx, ctx.elsewhere.workspace)
    end

    test "its key registers no run, and a batch of a run it did not attach opens none", ctx do
      conn = register(ctx.gateway_key, gateway_registration())
      assert json_response(conn, 409) == %{"error" => "gateway_key"}

      {subject, events} = first_events()
      conn = deliver(ctx.gateway_key, events)
      assert json_response(conn, 409) == %{"error" => "wrong_gateway"}
      refute Repo.exists?(from r in Run, where: r.run_id == ^subject)
    end
  end

  # Another organisation whose organisation-level gateway serves the scope's
  # organisation's workspaces, through the edition's seams, and is the default of the
  # scope's organisation's node once the scope's organisation's gateway goes.
  defp serving_another(ctx) do
    %{scope: operator} = sign_up_fixture()
    gateway = organisation_gateway_fixture(operator)

    %{access_key: gateway_key, secret: gateway_secret} =
      contract_key_fixture(operator, node: gateway)

    # Its own workspace's node, on its organisation's default: this gateway.
    %{access_key: own_key, secret: own_secret} = contract_key_fixture(operator)

    Edition.put_test_stub(EditionStubs.ServesAcross)
    EditionStubs.ServesAcross.put([{operator.organisation.id, ctx.scope.organisation.id}])

    # The scope's organisation's gateway goes, so its workspaces' default is the other
    # organisation's.
    {:ok, _} = Apiary.Nodes.update_node(ctx.elsewhere, ctx.node, %{gateway_choice: "direct"})
    {:ok, _} = Apiary.Nodes.delete_node(ctx.scope, ctx.gateway)
    {:ok, _} = Apiary.Nodes.update_node(ctx.elsewhere, ctx.node, %{gateway_choice: "default"})

    %{
      operator: operator,
      gateway: gateway,
      gateway_key: {gateway_key, gateway_secret},
      own_key: {own_key, own_secret}
    }
  end

  describe "a gateway of an organisation out of use, serving another" do
    setup :serving_another

    test "carries the served organisation's run through every endpoint", ctx do
      EditionStubs.ServesAcross.out_of_use([ctx.operator.organisation.id])
      carried(ctx, ctx.elsewhere.workspace)
    end

    test "its key is discovered, and a workspace's gateway of its organisation is not", ctx do
      workspace_gateway = gateway_fixture(ctx.operator)

      %{access_key: key, secret: secret} =
        contract_key_fixture(ctx.operator, node: workspace_gateway)

      EditionStubs.ServesAcross.out_of_use([ctx.operator.organisation.id])

      assert json_response(discover(ctx.gateway_key), 200)["node_id"] == ctx.gateway.public_id
      assert json_response(discover({key, secret}), 401) == %{"error" => "unauthorized"}
    end

    test "acts for no run of its own organisation's workspaces", ctx do
      {run_id, run_key} = registered(ctx.own_key)
      EditionStubs.ServesAcross.out_of_use([ctx.operator.organisation.id])

      conn = attach(ctx.gateway_key, run_id, attach_body(run_key))
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert run(run_id).attached_at == nil

      # Its own organisation's node is refused, as every key of a node out of use is.
      assert json_response(register(ctx.own_key, gateway_registration()), 401) ==
               %{"error" => "unauthorized"}
    end

    test "is refused everywhere once its organisation is marked for deletion", ctx do
      {run_id, run_key} = registered(ctx.key)

      {:ok, _} =
        Apiary.Deletion.delete_organisation(ctx.operator, ctx.operator.organisation.slug)

      assert json_response(discover(ctx.gateway_key), 401) == %{"error" => "unauthorized"}

      assert json_response(attach(ctx.gateway_key, run_id, attach_body(run_key)), 401) ==
               %{"error" => "unauthorized"}

      {_subject, [started]} = first_events(run_id)

      assert json_response(deliver(ctx.gateway_key, [started]), 401) == %{
               "error" => "unauthorized"
             }

      assert json_response(register(ctx.key, gateway_registration()), 409) ==
               %{"error" => "gateway_without_key"}
    end
  end

  describe "a gateway that may no longer serve a run's workspace" do
    setup :serving_another

    setup ctx do
      {:ok, _rule} = Apiary.Policy.allow(ctx.elsewhere, nil, %{host: "api.example"})
      :ok
    end

    defp reload({key, secret}, run_id),
      do: signed_get(build_conn(), key.key_id, secret, "/v1/runs/" <> run_id)

    # A run of the scope's organisation's node, registered through the other
    # organisation's gateway and attached by it.
    defp attached(ctx) do
      {run_id, run_key} = registered(ctx.key)
      assert attach(ctx.gateway_key, run_id, attach_body(run_key)).status == 200
      {run_id, run_key}
    end

    defp stored(run_id) do
      run = run(run_id)

      {Repo.aggregate(from(e in Apiary.Runs.Event, where: e.run_id == ^run.id), :count),
       Repo.aggregate(from(d in Apiary.Runs.Delivery, where: d.run_id == ^run_id), :count)}
    end

    # Each refusal, signed, and nothing of the batch stored.
    defp refused(ctx, {run_id, run_key}) do
      {_subject, [started]} = first_events(run_id)
      before = stored(run_id)

      conn = deliver(ctx.gateway_key, [started])
      assert json_response(conn, 410) == %{"error" => "workspace_not_served"}
      assert signed_answer?(conn)
      assert stored(run_id) == before

      conn = reload(ctx.gateway_key, run_id)
      assert json_response(conn, 410) == %{"error" => "workspace_not_served"}
      assert signed_answer?(conn)
      assert get_resp_header(conn, "x-qory-run-configuration") == []

      conn = attach(ctx.gateway_key, run_id, attach_body(run_key))
      assert json_response(conn, 409) == %{"error" => "workspace_not_served"}
      assert signed_answer?(conn)
    end

    # With the relation back, a new run registers and is attached.
    defp served_again(ctx) do
      EditionStubs.ServesAcross.switch(:on)
      EditionStubs.ServesAcross.put([{ctx.operator.organisation.id, ctx.scope.organisation.id}])
      {run_id, _run_key} = attached(ctx)
      {_subject, [started]} = first_events(run_id)
      assert response(deliver(ctx.gateway_key, [started]), 202) == ""
    end

    test "is served while the relation holds", ctx do
      {run_id, run_key} = attached(ctx)
      {_subject, [started]} = first_events(run_id)

      assert response(deliver(ctx.gateway_key, [started]), 202) == ""
      assert stored(run_id) == {1, 1}
      assert reload(ctx.gateway_key, run_id).status == 200
      assert attach(ctx.gateway_key, run_id, attach_body(run_key)).status == 200
    end

    test "is refused once the relation is withdrawn", ctx do
      run = attached(ctx)
      EditionStubs.ServesAcross.put([])
      refused(ctx, run)
      served_again(ctx)
    end

    test "is refused while the edition's serving is off", ctx do
      run = attached(ctx)
      EditionStubs.ServesAcross.switch(:off)
      refused(ctx, run)
      served_again(ctx)
    end

    test "is refused once the run's organisation leaves, while it serves others", ctx do
      %{scope: another} = sign_up_fixture()
      run = attached(ctx)

      EditionStubs.ServesAcross.put([
        {ctx.operator.organisation.id, another.organisation.id}
      ])

      refused(ctx, run)
      served_again(ctx)
    end
  end
end
