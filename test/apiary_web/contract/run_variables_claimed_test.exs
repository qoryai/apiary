defmodule ApiaryWeb.Contract.RunVariablesClaimedTest do
  # The variables a workspace and its target set, with the organisation's, reach a claimed
  # run through its run configuration: the claim stores them with the run, the attach
  # serves them in `variables` once, a reload and a batch answer the same bytes and the
  # same digest after a later edit, the run claimed after the edit has the edit, and the
  # document is valid under the vendored schema. Not async, as the other contract tests of
  # a pool: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.ContractFixtures
  import Apiary.DispatchedRunsFixtures, only: [handover_place_fixture: 1, redeemed_run_key!: 1]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, ForagerSchemas, Policy, Repo, Variables}
  alias Apiary.Runs.Target
  alias ApiaryPro.OrganisationVariables
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: [:factory, :organisation_variables]

  setup do
    %{scope: scope} = sign_up_fixture()
    # A managed workspace, so each answer names the run configuration in force.
    {:ok, _rule} = Policy.allow(scope, nil, %{host: "api.example"})
    {:ok, %{digest: digest}} = Policy.current_configuration(scope, nil)

    target =
      Repo.insert!(%Target{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        system: "forge.example.com",
        path: "acme/shop",
        first_seen_at: DateTime.utc_now()
      })

    scope
    |> handover_place_fixture()
    |> Map.merge(%{scope: scope, digest: digest, target: target})
  end

  defp claim(ctx) do
    :ok = Apiary.DispatchedRunsFixtures.walks_resolved!()
    now = SignedRequest.now() |> DateTime.from_unix!() |> DateTime.to_iso8601()

    conn =
      signed_post(
        build_conn(),
        ctx.key.key_id,
        ctx.seed,
        %{"version" => 1, "time" => now, "wait_seconds" => 0},
        target: "/v1/pools/claim",
        content_type: "application/json",
        delivery: nil,
        contract_version: "1"
      )

    json_response(conn, 200)
  end

  defp gateway_attach(ctx, run_id, run_key) do
    {key, seed} = ctx.gateway_key
    signed_attach(build_conn(), key.key_id, seed, run_id, Jason.encode!(attach_body(run_key)))
  end

  defp gateway_reload(ctx, run_id) do
    {key, seed} = ctx.gateway_key
    signed_get(build_conn(), key.key_id, seed, "/v1/runs/" <> run_id)
  end

  defp set!(ctx, holder, name, value, attrs \\ %{}) do
    {:ok, variable} =
      Variables.create_variable(
        ctx.scope,
        holder,
        Map.merge(%{name: name, value: value}, attrs)
      )

    variable
  end

  # The variable `name` that `holder` sets itself.
  defp own(ctx, holder, name) do
    {:ok, variables} = Variables.list_variables(ctx.scope, holder)
    Enum.find(variables, &(&1.name == name))
  end

  # A work item queued, claimed through the endpoint, and its run attached: the attach.
  defp attached(ctx) do
    {:ok, queued} =
      Repo.transact(fn -> Dispatches.queue(work_item_fixture(ctx.scope), 1) end)

    %{"run_code" => code} = claim(ctx)
    run_key = redeemed_run_key!(code)
    {queued.run_id, gateway_attach(ctx, queued.run_id, run_key)}
  end

  defp values(conn) do
    for {name, %{"value" => value}} <- Jason.decode!(conn.resp_body)["variables"],
        into: %{},
        do: {name, value}
  end

  test "an attach serves what the levels resolve to, a reload serves the same after an edit, and the next run has the edit",
       ctx do
    {:ok, _organisation} =
      OrganisationVariables.create(ctx.scope, %{name: "REGION", value: "eu-west-1"})

    {:ok, _organisation} =
      OrganisationVariables.create(ctx.scope, %{name: "LOG_LEVEL", value: "info", locked: true})

    set!(ctx, :workspace, "REGION", "eu-central-1")
    set!(ctx, :workspace, "NODE_ENV", "production")
    set!(ctx, ctx.target, "NODE_ENV", "test")
    set!(ctx, ctx.target, "FEATURE_FLAG", "on")
    set!(ctx, :workspace, "PATH", "/tmp")
    set!(ctx, :workspace, "GH_TOKEN", "a forge token")

    {run_id, attached} = attached(ctx)
    assert attached.status == 200
    assert signed_answer?(attached)
    [digest] = get_resp_header(attached, "x-qory-run-configuration")

    # The target's value wins, the workspace's over the organisation's, the organisation's
    # lock holds, and the names Forager leaves out are not given.
    first = %{
      "QORY_RUN_SYSTEM" => "forge.example.com",
      "QORY_RUN_REPOSITORIES" => "acme/shop",
      "REGION" => "eu-central-1",
      "LOG_LEVEL" => "info",
      "NODE_ENV" => "test",
      "FEATURE_FLAG" => "on"
    }

    assert values(attached) == first

    # It is valid under the contract's schema, with the run's labels and about after it.
    assert :ok = ForagerSchemas.validate("run-configuration.schema.json", attached.resp_body)
    assert :ok = Policy.Schema.validate(attached.resp_body)
    assert Policy.policy_digest(ctx.scope, digest) == ctx.digest

    # An edit after the handover reaches neither the reload, nor its digest.
    {:ok, _changed} =
      Variables.update_variable(ctx.scope, own(ctx, :workspace, "NODE_ENV"), %{value: "staging"})

    {:ok, _changed} =
      Variables.update_variable(ctx.scope, own(ctx, ctx.target, "FEATURE_FLAG"), %{value: "off"})

    set!(ctx, :workspace, "ADDED_LATER", "yes")

    reload = gateway_reload(ctx, run_id)
    assert reload.status == 200
    assert get_resp_header(reload, "x-qory-run-configuration") == [digest]
    assert Policy.Render.digest(reload.resp_body) == digest
    assert values(reload) == first

    # The next run has the edit, under another digest.
    {_next_id, next} = attached(ctx)
    assert next.status == 200
    assert [next_digest] = get_resp_header(next, "x-qory-run-configuration")
    refute next_digest == digest

    assert %{"ADDED_LATER" => "yes", "NODE_ENV" => "test", "FEATURE_FLAG" => "off"} =
             values(next)

    assert :ok = ForagerSchemas.validate("run-configuration.schema.json", next.resp_body)
  end
end
