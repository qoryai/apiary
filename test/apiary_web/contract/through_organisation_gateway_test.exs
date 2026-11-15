defmodule ApiaryWeb.Contract.ThroughOrganisationGatewayTest do
  # A run that goes through a gateway of the organisation, which has no workspace: its
  # discovery, a registration from a node of any workspace of the organisation, the
  # attach, the batches and the outcome, through the endpoints, also while the organisation
  # is out of use (`Apiary.EditionStubs.OutOfUse`) and once it is marked for deletion.
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

  defp run(run_id), do: Repo.one!(from r in Run, where: r.node_run_id == ^run_id)

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

  defp reload({key, secret}, run_id),
    do: signed_get(build_conn(), key.key_id, secret, "/v1/runs/" <> run_id)

  defp deliver_as({key, secret}, events, delivery),
    do: signed_post(build_conn(), key.key_id, secret, events, delivery: delivery)

  # A run of the node of the other workspace, registered through the organisation's
  # gateway and attached by it.
  defp attached(ctx) do
    {run_id, run_key} = registered(ctx.key)
    assert attach(ctx.gateway_key, run_id, attach_body(run_key)).status == 200
    {run_id, run_key}
  end

  defp stored(run_id) do
    run = run(run_id)

    {Repo.aggregate(from(e in Apiary.Runs.Event, where: e.run_id == ^run.id), :count),
     Repo.aggregate(from(d in Apiary.Runs.Delivery, where: d.node_run_id == ^run_id), :count)}
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
      refute Repo.exists?(from r in Run, where: r.node_run_id == ^subject)
    end

    test "a delivery sent again is answered as before", ctx do
      {run_id, run_key} = attached(ctx)
      {_subject, [started]} = first_events(run_id)
      delivery = Ecto.UUID.generate()
      assert response(deliver_as(ctx.gateway_key, [started], delivery), 202) == ""
      assert stored(run_id) == {1, 1}

      conn = deliver_as(ctx.gateway_key, [started], delivery)
      assert response(conn, 202) == ""
      assert get_resp_header(conn, "x-qory-configuration") != []
      assert stored(run_id) == {1, 1}

      assert attach(ctx.gateway_key, run_id, attach_body(run_key)).status == 200
    end

    @tag needs: :security
    test "is given the run's policy at its reload", ctx do
      {:ok, _rule} = Apiary.Policy.allow(ctx.elsewhere, nil, %{host: "api.example"})
      {run_id, _run_key} = attached(ctx)
      assert reload(ctx.gateway_key, run_id).status == 200
    end

    test "a new delivery to a run whose events were pruned is a 410 that records it", ctx do
      {run_id, _run_key} = attached(ctx)
      {_subject, [started]} = first_events(run_id)
      assert response(deliver(ctx.gateway_key, [started]), 202) == ""

      Repo.update_all(from(r in Run, where: r.node_run_id == ^run_id),
        set: [events_pruned_at: DateTime.utc_now()]
      )

      next = wire_event(run_id, 2, "run.heartbeat")
      assert response(deliver(ctx.gateway_key, [next]), 410) == ""
      {_events, deliveries} = stored(run_id)
      assert deliveries == 2
    end
  end

  describe "a gateway of an organisation out of use" do
    setup do
      :ok = Edition.put_test_stub(EditionStubs.OutOfUse)
    end

    defp out_of_use(%{scope: scope}), do: Process.put(:out_of_use, [scope.organisation.id])

    test "its key is discovered, and a workspace's gateway of its organisation is not", ctx do
      workspace_gateway = gateway_fixture(ctx.scope)

      %{access_key: key, secret: secret} =
        contract_key_fixture(ctx.scope, node: workspace_gateway)

      out_of_use(ctx)

      assert json_response(discover(ctx.gateway_key), 200)["node_id"] == ctx.gateway.public_id
      assert json_response(discover({key, secret}), 401) == %{"error" => "unauthorized"}
    end

    test "acts for no run of its organisation's workspaces", ctx do
      {run_id, run_key} = registered(ctx.key)
      out_of_use(ctx)

      conn = attach(ctx.gateway_key, run_id, attach_body(run_key))
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert run(run_id).attached_at == nil

      # The organisation's node is refused, as every key of a node out of use is.
      assert json_response(register(ctx.key, gateway_registration()), 401) ==
               %{"error" => "unauthorized"}
    end

    test "is refused everywhere once its organisation is marked for deletion", ctx do
      {run_id, run_key} = registered(ctx.key)

      {:ok, _} = Apiary.Deletion.delete_organisation(ctx.scope, ctx.scope.organisation.slug)

      assert json_response(discover(ctx.gateway_key), 401) == %{"error" => "unauthorized"}

      assert json_response(attach(ctx.gateway_key, run_id, attach_body(run_key)), 401) ==
               %{"error" => "unauthorized"}

      {_subject, [started]} = first_events(run_id)

      assert json_response(deliver(ctx.gateway_key, [started]), 401) == %{
               "error" => "unauthorized"
             }
    end
  end
end
