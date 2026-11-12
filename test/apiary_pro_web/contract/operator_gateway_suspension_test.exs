defmodule ApiaryProWeb.Contract.OperatorGatewaySuspensionTest do
  # An operator's organisation-level gateway while the operator is suspended and the
  # operator owns its clients (`ApiaryPro.Flags.operator_infrastructure?/0`), through the
  # endpoints: its clients keep running, so a client's run registers through it, attaches,
  # and sends its batches; a run of the operator's workspaces, whose place is out of use,
  # is refused; and a suspended client's runs through it are refused. The flag is set for
  # this process.
  use ApiaryWeb.ConnCase, async: true

  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import ApiaryPro.OperatorsFixtures
  import Ecto.Query

  alias Apiary.{Features, Repo}
  alias Apiary.Runs.{Run, RunKey}
  alias ApiaryPro.{Flags, Suspensions}

  @moduletag with_features: Features.all()

  setup do
    Flags.put_operator_infrastructure(false)
    operator = operator_fixture()
    client = client_fixture(operator.scope)
    %{instance_scope: instance_admin} = suite_instance_admin()
    Flags.put_operator_infrastructure(true)

    in_operator = scope_in(operator.user, operator.organisation, operator_workspace(operator))

    # The operator's first gateway is its default, and its clients' too.
    gateway = organisation_gateway_fixture(operator.scope, name: "edge-1")

    %{access_key: gateway_key, secret: gateway_secret} =
      contract_key_fixture(operator.scope, node: gateway)

    # A node of the client's, which the operator's owner makes, and one of the operator's
    # workspace, both on Default.
    %{access_key: client_key, secret: client_secret, node: client_node} =
      contract_key_fixture(client.scope)

    %{access_key: own_key, secret: own_secret, node: own_node} =
      contract_key_fixture(in_operator)

    assert client_node.gateway_choice == :default
    assert own_node.gateway_choice == :default

    %{
      operator: operator,
      client: client,
      instance_admin: instance_admin,
      gateway: gateway,
      gateway_key: {gateway_key, gateway_secret},
      client_key: {client_key, client_secret},
      own_key: {own_key, own_secret}
    }
  end

  defp operator_workspace(operator),
    do:
      Repo.one!(
        from w in Apiary.Organisations.Workspace,
          where: w.organisation_id == ^operator.organisation.id,
          order_by: [asc: w.inserted_at],
          limit: 1
      )

  defp suspend(ctx) do
    {:ok, _} = Suspensions.suspend_organisation(ctx.instance_admin, ctx.operator.organisation.id)
    :ok
  end

  defp register({key, secret}, body),
    do: signed_register(build_conn(), key.key_id, secret, Jason.encode!(body))

  defp attach({key, secret}, run_id, body),
    do: signed_attach(build_conn(), key.key_id, secret, run_id, Jason.encode!(body))

  defp deliver({key, secret}, events), do: signed_post(build_conn(), key.key_id, secret, events)

  defp registered(key) do
    run_id = Ecto.UUID.generate()
    conn = register(key, gateway_registration(run_id))
    assert %{"run_key" => run_key} = json_response(conn, 200)
    {run_id, run_key}
  end

  defp run(run_id), do: Repo.one!(from r in Run, where: r.node_run_id == ^run_id)

  test "with the operator suspended, a client's run registers through its gateway and attaches",
       ctx do
    suspend(ctx)

    {run_id, run_key} = registered(ctx.client_key)
    {:ok, grant, _payload} = RunKey.verify(run_key)
    assert grant.workspace == ctx.client.workspace.public_id
    assert grant.gateway == ctx.gateway.public_id

    assert attach(ctx.gateway_key, run_id, attach_body(run_key)).status == 200

    {_subject, [started]} = first_events(run_id)
    assert response(deliver(ctx.gateway_key, [started]), 202) == ""

    run = run(run_id)
    assert run.workspace_id == ctx.client.workspace.id
    assert run.gateway_id == ctx.gateway.id
    assert run.attached_at
    assert run.event_count == 1
  end

  test "with the operator suspended, a run of its workspace through its gateway is refused",
       ctx do
    {run_id, run_key} = registered(ctx.own_key)
    suspend(ctx)

    conn = attach(ctx.gateway_key, run_id, attach_body(run_key))
    assert json_response(conn, 401) == %{"error" => "unauthorized"}
    assert run(run_id).attached_at == nil

    # Its node's key is refused, as every key of a node of a suspended organisation is.
    assert json_response(register(ctx.own_key, gateway_registration()), 401) ==
             %{"error" => "unauthorized"}
  end

  test "with the client suspended, its runs through the operator's gateway are refused",
       ctx do
    {attached, attached_key} = registered(ctx.client_key)
    assert attach(ctx.gateway_key, attached, attach_body(attached_key)).status == 200
    {waiting, waiting_key} = registered(ctx.client_key)

    {:ok, _} = Suspensions.suspend_organisation(ctx.instance_admin, ctx.client.organisation.id)

    conn = attach(ctx.gateway_key, waiting, attach_body(waiting_key))
    assert json_response(conn, 401) == %{"error" => "unauthorized"}
    assert run(waiting).attached_at == nil

    {_subject, [started]} = first_events(attached)
    conn = deliver(ctx.gateway_key, [started])
    assert json_response(conn, 401) == %{"error" => "unauthorized"}
    assert run(attached).event_count == 0
  end
end
