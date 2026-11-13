defmodule ApiaryProWeb.Contract.ServedWhateverGrantedTest do
  # What a node is served follows the instance's features alone, whatever an organisation
  # or a client is granted (an access key asks `Apiary.Features.on?/1`): a client whose
  # Runs are taken away still has its runs registered, attached, their events and their
  # outcome stored; an organisation whose security policy is taken away is still served
  # its policy and the organisation's, at registration, reload and with each batch; and a
  # client without the security policy, narrowed or dropped, is served the same document.
  # Not async: an operator is made by an instance admin, and the instance's features are
  # the node's.
  use ApiaryWeb.ConnCase, async: false

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures
  import Ecto.Query

  alias Apiary.{Features, Policy, Repo}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias Apiary.Policy.Serving
  alias Apiary.Runs.{Event, Run}
  alias ApiaryPro.{Grants, OrganisationPolicy, Transfers}

  @moduletag with_features: Features.all()

  # With the `registry` feature a gateway's run is also served its registry credential and
  # the registry's hosts, so its digest is no longer the workspace's policy alone. This
  # file asserts that policy, as the core's composed run configuration tests do.
  setup {Apiary.DataCase, :without_registry}

  setup do
    %{admin: instance_admin_fixture().instance_scope}
  end

  defp has?(organisation, feature),
    do: feature in ApiaryPro.Features.of(Repo.get!(Organisation, organisation.id))

  # The node registers its runs itself, not through a gateway.
  defp direct(node),
    do: Repo.update_all(from(n in Node, where: n.id == ^node.id), set: [gateway_choice: :direct])

  defp register({key, secret}, body),
    do: signed_register(build_conn(), key.key_id, secret, Jason.encode!(body))

  defp reload({key, secret}, run_id),
    do: signed_get(build_conn(), key.key_id, secret, "/v1/runs/" <> run_id)

  defp deliver({key, secret}, events), do: signed_post(build_conn(), key.key_id, secret, events)

  defp attach({key, secret}, run_id, body),
    do: signed_attach(build_conn(), key.key_id, secret, run_id, Jason.encode!(body))

  defp outcome({key, secret}, run_id) do
    time =
      ApiaryWeb.Contract.SignedRequest.now() |> DateTime.from_unix!() |> DateTime.to_iso8601()

    signed_post(
      build_conn(),
      key.key_id,
      secret,
      Jason.encode!(%{"version" => 1, "state" => "succeeded", "time" => time}),
      target: "/v1/runs/#{run_id}/outcome",
      content_type: "application/json",
      delivery: nil
    )
  end

  defp run(run_id), do: Repo.one!(from r in Run, where: r.node_run_id == ^run_id)

  defp in_force(conn), do: get_resp_header(conn, "x-qory-run-configuration")

  defp deny(document), do: Jason.decode!(document)["security_policy"]["egress"]["deny"] || []

  # What the key's workspace serves a run now: its digest, nil where nothing is served.
  defp digest({key, _secret}) do
    with true <- Serving.managed?(key),
         {:ok, configuration} <- Serving.fetch(key, %{}),
         do: configuration.digest,
         else: (_none -> nil)
  end

  describe "a client whose Runs are taken away" do
    setup ctx do
      operator = operator_fixture()
      client = client_fixture(operator.scope, "Acme")
      in_client = client.owner.scope

      # The workspace's first gateway is its default: a node made after it goes through it.
      gateway = gateway_fixture(in_client)

      %{access_key: gateway_key, secret: gateway_secret} =
        contract_key_fixture(in_client, node: gateway)

      %{access_key: key, secret: secret, node: node} = contract_key_fixture(in_client)
      {:ok, _rule} = Policy.deny(in_client, nil, %{host: "ads.example"})
      {:ok, %{digest: baseline}} = Policy.current_configuration(in_client, nil)

      assert {:ok, []} = Grants.set_client(operator.scope, client.organisation.id, [])
      refute has?(client.organisation, :observability)

      Map.merge(ctx, %{
        node: node,
        key: {key, secret},
        gateway_key: {gateway_key, gateway_secret},
        baseline: baseline
      })
    end

    test "has its runs registered, their events stored and their outcome", ctx do
      direct(ctx.node)
      run_id = Ecto.UUID.generate()
      conn = register(ctx.key, registration(run_id))
      assert json_response(conn, 200)
      assert in_force(conn) == [ctx.baseline]

      {_subject, events} = first_events(run_id)
      conn = deliver(ctx.key, events)
      assert conn.status == 202

      run = run(run_id)
      assert Repo.aggregate(from(e in Event, where: e.run_id == ^run.id), :count) == 1

      conn = outcome(ctx.key, run_id)
      assert conn.status in [200, 202]
      assert run(run_id).outcome_state == "succeeded"
    end

    test "has a run attached through its gateway, served its policy", ctx do
      run_id = Ecto.UUID.generate()
      conn = register(ctx.key, gateway_registration(run_id))
      assert %{"run_key" => run_key} = json_response(conn, 200)

      conn = attach(ctx.gateway_key, run_id, attach_body(run_key))
      assert %{"security_policy" => _} = json_response(conn, 200)
      assert in_force(conn) == [ctx.baseline]
      assert run(run_id).attached_at
    end
  end

  describe "an organisation whose security policy is taken away" do
    setup ctx do
      %{scope: owner, organisation: organisation} = sign_up_fixture()
      %{access_key: key, secret: secret, node: node} = contract_key_fixture(owner)
      {:ok, _rule} = Policy.deny(owner, nil, %{host: "ads.example"})
      {:ok, _rule} = OrganisationPolicy.deny(owner, %{host: "paste.example"})
      {:ok, %{digest: baseline}} = Policy.current_configuration(owner, nil)

      # The security policy taken away, with the features that need it.
      shown =
        Grants.shown(organisation) --
          [:security, :organisation_policy, :organisation_variables]

      assert {:ok, _} = Grants.set_organisation(ctx.admin, organisation.id, shown)
      refute has?(organisation, :security)

      Map.merge(ctx, %{node: node, key: {key, secret}, baseline: baseline})
    end

    test "is still served its policy and the organisation's", ctx do
      {key, _secret} = ctx.key
      assert Serving.managed?(key)
      assert {:ok, configuration} = Serving.fetch(key, %{})
      assert configuration.digest == ctx.baseline
      assert Enum.sort(deny(configuration.document)) == ["ads.example", "paste.example"]
    end

    test "answers a registration and its reload with the stored policy", ctx do
      direct(ctx.node)
      run_id = Ecto.UUID.generate()
      conn = register(ctx.key, registration(run_id))

      assert %{"security_policy" => _} = json_response(conn, 200)
      assert conn.resp_body != ~s({"version":1})
      assert in_force(conn) == [ctx.baseline]

      again = reload(ctx.key, run_id)
      assert again.status == 200
      assert again.resp_body == conn.resp_body
      assert in_force(again) == [ctx.baseline]
    end

    test "answers each batch with the digest in force", ctx do
      direct(ctx.node)
      run_id = Ecto.UUID.generate()
      assert register(ctx.key, registration(run_id)).status == 200

      {_subject, events} = first_events(run_id)
      conn = deliver(ctx.key, events)
      assert conn.status == 202
      assert in_force(conn) == [ctx.baseline]
    end
  end

  describe "a client without the security policy" do
    setup ctx do
      operator = operator_fixture()
      client = client_fixture(operator.scope, "Acme")
      in_client = client.owner.scope
      %{access_key: key, secret: secret} = contract_key_fixture(in_client)
      {:ok, _rule} = Policy.deny(in_client, nil, %{host: "ads.example"})
      key = {key, secret}
      served = digest(key)
      assert served

      Map.merge(ctx, %{operator: operator, client: client, key: key, served: served})
    end

    test "narrowed with its operator keeps the same digest", ctx do
      operator = ctx.operator.organisation
      assert {:ok, _} = Grants.set_organisation(ctx.admin, operator.id, [:observability])
      refute has?(ctx.client.organisation, :security)

      assert digest(ctx.key) == ctx.served
    end

    test "keeps the same digest, and keeps it once dropped", ctx do
      client = ctx.client.organisation
      assert {:ok, _} = Grants.set_client(ctx.operator.scope, client.id, [:observability])
      refute has?(client, :security)
      assert digest(ctx.key) == ctx.served

      assert {:ok, _} = Transfers.drop(ctx.operator.scope, client.id, client.name)
      assert has?(client, :security)
      assert digest(ctx.key) == ctx.served
    end
  end
end
