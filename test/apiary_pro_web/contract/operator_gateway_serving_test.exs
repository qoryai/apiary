defmodule ApiaryProWeb.Contract.OperatorGatewayServingTest do
  # An operator's organisation-level gateway acts for a run of a client's workspace only
  # while it may serve that workspace (`Apiary.Access.may_serve?/2`): while the operator
  # owns its clients (`ApiaryPro.Flags.operator_infrastructure?/0`) and the client is still
  # its client. Once the flag is off, or the client has parted, its key is refused for the
  # client's runs: an attach, a repeat of one included, is `409` `workspace_not_served`, a
  # batch and a reload `410` `workspace_not_served`, nothing of it stored. Not async: an
  # operator is made by an instance admin, an owner of the suite's one instance
  # organisation. The flags are this process's own.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import ApiaryPro.OperatorsFixtures
  import Ecto.Query

  alias Apiary.{Features, Repo}
  alias Apiary.Runs.Run
  alias ApiaryPro.{Flags, Transfers}

  @moduletag with_features: Features.all()

  # With the `registry` feature a gateway's run is also served its registry credential and
  # the registry's hosts, so its document is no longer the workspace's policy alone. This
  # file asserts that policy, as the core's composed run configuration tests do.
  setup {Apiary.DataCase, :without_registry}

  # The operator's gateway edge-1, the default of the client's workspace, with its key; a
  # policy in that workspace; a node of the client's on Default, with its key; a run of that
  # node registered through the gateway and attached, and a second registered and not
  # attached yet.
  setup do
    Flags.put_transfers(true)
    Flags.put_operator_infrastructure(false)
    operator = operator_fixture()
    client = client_fixture(operator.scope)
    Flags.put_operator_infrastructure(true)

    gateway = organisation_gateway_fixture(operator.scope, name: "edge-1")

    # A policy, so the client's workspace serves a run configuration a reload answers.
    {:ok, _rule} = Apiary.Policy.allow(client.owner.scope, nil, %{host: "api.example"})

    %{access_key: gateway_key, secret: gateway_secret} =
      contract_key_fixture(operator.scope, node: gateway)

    %{access_key: client_key, secret: client_secret} = contract_key_fixture(client.scope)

    gateway_key = {gateway_key, gateway_secret}
    client_key = {client_key, client_secret}

    {attached, attached_key} = registered(client_key)
    assert attach(gateway_key, attached, attach_body(attached_key)).status == 200
    attached_at = run(attached).attached_at

    {waiting, waiting_key} = registered(client_key)

    %{
      operator: operator,
      client: client,
      gateway: gateway,
      gateway_key: gateway_key,
      attached: {attached, attached_key},
      attached_at: attached_at,
      waiting: {waiting, waiting_key}
    }
  end

  defp register({key, secret}, body),
    do: signed_register(build_conn(), key.key_id, secret, Jason.encode!(body))

  defp attach({key, secret}, run_id, body),
    do: signed_attach(build_conn(), key.key_id, secret, run_id, Jason.encode!(body))

  defp deliver({key, secret}, events), do: signed_post(build_conn(), key.key_id, secret, events)

  defp reload({key, secret}, run_id),
    do: signed_get(build_conn(), key.key_id, secret, "/v1/runs/" <> run_id)

  defp registered(key) do
    run_id = Ecto.UUID.generate()
    conn = register(key, gateway_registration(run_id))
    assert %{"run_key" => run_key} = json_response(conn, 200)
    {run_id, run_key}
  end

  defp run(run_id), do: Repo.one!(from r in Run, where: r.node_run_id == ^run_id)

  # The gateway's key, asked to act for the client's runs: refused for each, nothing stored.
  defp refused_for_the_client(ctx) do
    {waiting, waiting_key} = ctx.waiting
    {attached, attached_key} = ctx.attached

    conn = attach(ctx.gateway_key, waiting, attach_body(waiting_key))
    assert json_response(conn, 409) == %{"error" => "workspace_not_served"}
    assert run(waiting).attached_at == nil

    # The same instance of the gateway attaching its run again, which a repeat is.
    conn = attach(ctx.gateway_key, attached, attach_body(attached_key))
    assert json_response(conn, 409) == %{"error" => "workspace_not_served"}
    assert run(attached).attached_at == ctx.attached_at

    {_subject, [started]} = first_events(attached)
    conn = deliver(ctx.gateway_key, [started])
    assert json_response(conn, 410) == %{"error" => "workspace_not_served"}
    assert run(attached).event_count == 0

    conn = reload(ctx.gateway_key, attached)
    assert json_response(conn, 410) == %{"error" => "workspace_not_served"}
  end

  test "while the operator owns its clients, the gateway acts for the client's runs", ctx do
    {waiting, waiting_key} = ctx.waiting
    {attached, attached_key} = ctx.attached
    assert attach(ctx.gateway_key, waiting, attach_body(waiting_key)).status == 200
    assert attach(ctx.gateway_key, attached, attach_body(attached_key)).status == 200

    {_subject, [started]} = first_events(attached)
    assert response(deliver(ctx.gateway_key, [started]), 202) == ""
    assert run(attached).event_count == 1

    assert %{"security_policy" => %{"egress" => %{"allow" => ["api.example"]}}} =
             json_response(reload(ctx.gateway_key, attached), 200)
  end

  test "with the flag off, the gateway's key is refused for the client's runs", ctx do
    Flags.put_operator_infrastructure(false)
    refused_for_the_client(ctx)
  end

  test "once the client has parted, the gateway's key is refused for its runs", ctx do
    Flags.put_operator_infrastructure(false)

    {:ok, _} =
      Transfers.drop(ctx.operator.scope, ctx.client.organisation.id, ctx.client.organisation.name)

    Flags.put_operator_infrastructure(true)
    refused_for_the_client(ctx)
  end
end
