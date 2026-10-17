defmodule Apiary.Runs.ServedWithNodesHiddenTest do
  # What a node is served asks its access key, never what a person is shown: where the
  # edition hides the nodes (the part `nodes`) from every person, a node still reads the
  # discovery document, registers its runs, posts their events, has a run read again and
  # posts its outcome, and a person there still meets the nodes as not found.
  use ApiaryWeb.ConnCase, async: true

  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.Repo
  alias Apiary.Nodes.Node
  alias Apiary.Runs.{Event, Run}

  setup do
    %{scope: scope, user: user} = sign_up_fixture()
    %{access_key: key, secret: secret, node: node} = contract_key_fixture(scope)

    # The node registers its runs itself, not through a gateway.
    Repo.update_all(from(n in Node, where: n.id == ^node.id), set: [gateway_choice: :direct])

    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
    :ok = Apiary.EditionStubs.HidesNamed.put([:nodes])

    %{scope: scope, user: user, node: node, key: key, secret: secret}
  end

  defp run(run_id), do: Repo.one!(from r in Run, where: r.node_run_id == ^run_id)

  test "the edition hides the nodes from a person of the organisation", ctx do
    scope = Apiary.Access.reload(ctx.scope)
    assert scope.hidden == [:nodes]
    refute Apiary.Features.visible?(scope, :nodes)
    refute Apiary.Access.can?(scope, :"node.read", scope.workspace)
  end

  test "a node reads its configuration, registers a run, posts its events and its outcome",
       ctx do
    %{key: key, secret: secret} = ctx

    conn = signed_get(build_conn(), key.key_id, secret, "/.well-known/qory-configuration")
    assert conn.status == 200
    assert signed_answer?(conn)

    run_id = Ecto.UUID.generate()
    conn = signed_register(build_conn(), key.key_id, secret, Jason.encode!(registration(run_id)))
    assert conn.status == 200
    assert signed_answer?(conn)
    assert run(run_id).node_id == ctx.node.id

    {_subject, events} = first_events(run_id)
    assert signed_post(build_conn(), key.key_id, secret, events).status == 202
    run = run(run_id)
    assert Repo.aggregate(from(e in Event, where: e.run_id == ^run.id), :count) == 1

    time =
      ApiaryWeb.Contract.SignedRequest.now() |> DateTime.from_unix!() |> DateTime.to_iso8601()

    outcome =
      signed_post(
        build_conn(),
        key.key_id,
        secret,
        Jason.encode!(%{"version" => 1, "state" => "succeeded", "time" => time}),
        target: "/v1/runs/#{run_id}/outcome",
        content_type: "application/json",
        delivery: nil
      )

    assert outcome.status in [200, 202]
    assert run(run_id).outcome_state == "succeeded"
  end

  # A run is read again where the workspace serves a run configuration: its policy.
  @tag needs: :security
  test "a run registered is served its run configuration, and so is its reload", ctx do
    %{key: key, secret: secret} = ctx
    {:ok, _rule} = Apiary.Policy.deny(ctx.scope, nil, %{host: "ads.example"})
    {:ok, %{digest: digest}} = Apiary.Policy.current_configuration(ctx.scope, nil)

    run_id = Ecto.UUID.generate()
    conn = signed_register(build_conn(), key.key_id, secret, Jason.encode!(registration(run_id)))
    assert %{"security_policy" => _} = json_response(conn, 200)
    assert get_resp_header(conn, "x-qory-run-configuration") == [digest]

    again = signed_get(build_conn(), key.key_id, secret, "/v1/runs/" <> run_id)
    assert again.status == 200
    assert again.resp_body == conn.resp_body
  end

  test "a person's nodes page there is not found", ctx do
    conn = log_in_user(build_conn(), ctx.user)

    assert_error_sent 404, fn ->
      get(conn, ~p"/#{ctx.scope.organisation}/#{ctx.scope.workspace}/nodes")
    end
  end
end
