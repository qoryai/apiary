defmodule Apiary.Runs.ServedWhateverShownTest do
  # What a node is served follows the instance's features alone: where the edition hides
  # `observability` and `security` from the organisation's people, its nodes are still
  # served in full, and a person there still meets what the edition hides from them.
  use ApiaryWeb.ConnCase, async: true

  # The policy is served only on an instance with the security feature.
  @moduletag needs: :security

  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.{Policy, Repo}
  alias Apiary.Nodes.Node
  alias Apiary.Runs.{Event, Run}
  alias ApiaryWeb.Contract.Configuration

  setup do
    %{scope: scope, user: user} = sign_up_fixture()
    # The workspace's first gateway is its default: a node made after it goes through it.
    gateway = gateway_fixture(scope)

    %{access_key: gateway_key, secret: gateway_secret} =
      contract_key_fixture(scope, node: gateway)

    %{access_key: key, secret: secret, node: node} = contract_key_fixture(scope)

    # The policy is made before the edition hides the features: its baseline is stored.
    {:ok, _rule} = Policy.deny(scope, nil, %{host: "ads.example"})
    {:ok, %{digest: baseline}} = Policy.current_configuration(scope, nil)

    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.WithoutRecordOrPolicy)

    %{
      scope: scope,
      user: user,
      node: node,
      key: {key, secret},
      gateway_key: {gateway_key, gateway_secret},
      baseline: baseline
    }
  end

  # The node registers its runs itself, not through the gateway.
  defp direct(ctx),
    do:
      Repo.update_all(from(n in Node, where: n.id == ^ctx.node.id),
        set: [gateway_choice: :direct]
      )

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

  defp run(run_id), do: Repo.one!(from r in Run, where: r.run_id == ^run_id)

  defp in_force(conn), do: get_resp_header(conn, "x-qory-run-configuration")

  test "the edition hides the features from a person of the organisation", ctx do
    scope = Apiary.Access.reload(ctx.scope)
    refute Apiary.Features.visible?(scope, :observability)
    refute Apiary.Features.visible?(scope, :security)
  end

  test "a registration is answered the stored policy, not the document of no policy, and so is its reload",
       ctx do
    direct(ctx)
    run_id = Ecto.UUID.generate()
    conn = register(ctx.key, registration(run_id))

    assert %{"security_policy" => _} = json_response(conn, 200)
    assert conn.resp_body != ~s({"version":1})
    assert signed_answer?(conn)
    assert in_force(conn) == [ctx.baseline]
    assert run(run_id).node_id == ctx.node.id

    again = reload(ctx.key, run_id)
    assert again.status == 200
    assert again.resp_body == conn.resp_body
    assert in_force(again) == [ctx.baseline]
  end

  test "a batch's events are stored, and its answer carries the digest in force", ctx do
    direct(ctx)
    run_id = Ecto.UUID.generate()
    assert register(ctx.key, registration(run_id)).status == 200

    {_subject, events} = first_events(run_id)
    conn = deliver(ctx.key, events)

    assert conn.status == 202
    assert in_force(conn) == [ctx.baseline]

    assert get_resp_header(conn, "x-qory-configuration") == [
             Configuration.digest(elem(ctx.key, 0))
           ]

    run = run(run_id)
    assert Repo.aggregate(from(e in Event, where: e.run_id == ^run.id), :count) == 1
  end

  test "an outcome is stored", ctx do
    direct(ctx)
    run_id = Ecto.UUID.generate()
    assert register(ctx.key, registration(run_id)).status == 200

    conn = outcome(ctx.key, run_id)

    assert conn.status in [200, 202]
    assert signed_answer?(conn)
    assert run(run_id).outcome_state == "succeeded"
  end

  test "an attach through the gateway is served the stored policy", ctx do
    run_id = Ecto.UUID.generate()
    conn = register(ctx.key, gateway_registration(run_id))
    assert %{"run_key" => run_key} = json_response(conn, 200)

    conn = attach(ctx.gateway_key, run_id, attach_body(run_key))

    assert %{"security_policy" => _} = json_response(conn, 200)
    assert signed_answer?(conn)
    assert in_force(conn) == [ctx.baseline]
    assert run(run_id).attached_at
  end

  test "a person's policy page there is still not found", ctx do
    conn = log_in_user(build_conn(), ctx.user)

    assert_error_sent 404, fn ->
      get(conn, ~p"/#{ctx.scope.organisation}/#{ctx.scope.workspace}/policy")
    end
  end
end
