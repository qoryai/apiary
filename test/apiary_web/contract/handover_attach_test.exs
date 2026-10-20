defmodule ApiaryWeb.Contract.HandoverAttachTest do
  # A run of the queue from its handover to its end, through the endpoints alone: the
  # starter says it started the job and asks for the handover; the gateway the run key
  # names attaches the run and is given the run configuration in force with the run
  # variables, the labels and what the run is about, as the handover stored them, under
  # the digest of the configuration with the variables; a reload returns the same; a batch
  # is answered the same digest; and the run's outcome,
  # under the pool's key, ends the run of the queue and frees its slot. Not async, as the
  # other contract tests of a pool: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.ContractFixtures
  import Apiary.DispatchedRunsFixtures, only: [handover_place_fixture: 1]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Policy, Repo}
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Slots}
  alias Apiary.Runs.{Run, RunVariables}
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    # A managed workspace, so each answer names the run configuration in force.
    {:ok, _rule} = Policy.allow(scope, nil, %{host: "api.example"})
    {:ok, %{digest: digest}} = Policy.current_configuration(scope, nil)

    scope
    |> handover_place_fixture()
    |> Map.merge(%{scope: scope, digest: digest})
  end

  defp now_time,
    do: SignedRequest.now() |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp pool_post(ctx, dispatch, action) do
    signed_post(build_conn(), ctx.key.key_id, ctx.seed, %{"version" => 1, "time" => now_time()},
      target: "/v1/dispatches/#{dispatch.public_id}/#{action}",
      content_type: "application/json",
      delivery: nil,
      contract_version: "3"
    )
  end

  defp gateway_attach(ctx, run_id, run_key) do
    {key, seed} = ctx.gateway_key
    signed_attach(build_conn(), key.key_id, seed, run_id, Jason.encode!(attach_body(run_key)))
  end

  defp gateway_reload(ctx, run_id) do
    {key, seed} = ctx.gateway_key
    signed_get(build_conn(), key.key_id, seed, "/v1/runs/" <> run_id)
  end

  defp gateway_batch(ctx, events) do
    {key, seed} = ctx.gateway_key
    signed_post(build_conn(), key.key_id, seed, events)
  end

  defp outcome(ctx, run_id) do
    body = %{"version" => 1, "state" => "succeeded", "time" => now_time()}

    signed_post(build_conn(), ctx.key.key_id, ctx.seed, Jason.encode!(body),
      target: "/v1/runs/#{run_id}/outcome",
      content_type: "application/json",
      delivery: nil
    )
  end

  test "a run handed over is attached, reloaded, sent and ended as the handover stored it",
       ctx do
    work_item = work_item_fixture(ctx.scope)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    {:ok, %{dispatch: dispatch}} = Dispatches.claim(ctx.key, Dispatches.now())

    assert pool_post(ctx, dispatch, "dispatched").status == 204
    handover = pool_post(ctx, dispatch, "handover")
    assert %{"run_id" => run_id, "run_key" => run_key} = json_response(handover, 200)
    assert run_id == queued.run_id

    stored = Repo.one!(from r in Run, where: r.dispatch_run_id == ^queued.id)
    assert stored.node_run_id == run_id
    assert stored.attached_at == nil

    # The attach: the configuration in force, then the variables, the labels and what the
    # run is about, as the handover stored them, under the digest of the configuration with
    # the variables, the document a reload returns.
    attached = gateway_attach(ctx, run_id, run_key)
    assert attached.status == 200
    assert signed_answer?(attached)
    [digest] = get_resp_header(attached, "x-qory-run-configuration")
    refute digest == ctx.digest
    assert Policy.policy_digest(ctx.scope, digest) == ctx.digest

    answer = Jason.decode!(attached.resp_body)

    assert answer["variables"] ==
             stored.registration_variables
             |> RunVariables.document()
             |> Jason.encode!()
             |> Jason.decode!()

    assert answer["variables"]["QORY_RUN_REPOSITORIES"]["value"] == "acme/shop"

    assert answer["labels"] == %{
             "forge" => "forge.example.com",
             "repository" => "acme/shop",
             "repositories" => "acme/shop"
           }

    assert answer["about"] == %{
             "kind" => "explore",
             "subjects" => [%{"type" => "work_item", "ref" => work_item.public_id}]
           }

    run = Repo.get!(Run, stored.id)
    assert run.attach_answer_digest == digest
    assert %DateTime{} = run.attached_at
    assert DateTime.diff(run.backstop_at, run.attached_at) == 1200

    # A reload returns the same answer, the same digest: the SHA-256 of its bytes.
    reload = gateway_reload(ctx, run_id)
    assert reload.status == 200
    assert signed_answer?(reload)
    assert get_resp_header(reload, "x-qory-run-configuration") == [digest]
    assert Policy.Render.digest(reload.resp_body) == digest
    assert Jason.decode!(reload.resp_body)["variables"] == answer["variables"]

    # A batch is answered the digest the run is given now.
    {_subject, [started]} = first_events(run_id)
    batch = gateway_batch(ctx, [started])
    assert response(batch, 202) == ""
    assert get_resp_header(batch, "x-qory-run-configuration") == [digest]

    # The outcome, the pool's, ends the run of the queue and frees its slot.
    assert json_response(outcome(ctx, run_id), 200) == %{"version" => 1}

    assert %DispatchRun{state: :ended, end_cause: :run_ended} =
             Repo.get!(DispatchRun, queued.id)

    assert %Dispatch{end_cause: :run_ended, slot_freed_at: %DateTime{}} =
             Repo.get!(Dispatch, dispatch.id)

    assert Slots.held(ctx.pool.id) == 0
  end

  test "the attach answer's labels carry the repository and its further repositories", ctx do
    :ok =
      Apiary.Runs.Target.insert_new(ctx.scope.organisation.id, ctx.scope.workspace.id, [
        %{system: "forge.example.com", path: "acme/shop"}
      ])

    target = Apiary.Targets.get(ctx.scope, "forge.example.com", "acme/shop")
    {:ok, _target} = Apiary.Targets.set_further_repositories(ctx.scope, target, "acme/docs")

    work_item = work_item_fixture(ctx.scope)
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    {:ok, %{dispatch: dispatch}} = Dispatches.claim(ctx.key, Dispatches.now())

    assert pool_post(ctx, dispatch, "dispatched").status == 204
    handover = pool_post(ctx, dispatch, "handover")
    assert %{"run_id" => run_id, "run_key" => run_key} = json_response(handover, 200)

    attached = gateway_attach(ctx, run_id, run_key)
    assert attached.status == 200
    [digest] = get_resp_header(attached, "x-qory-run-configuration")
    assert Policy.policy_digest(ctx.scope, digest) == ctx.digest

    answer = Jason.decode!(attached.resp_body)
    assert answer["variables"]["QORY_RUN_REPOSITORIES"]["value"] == "acme/shop,acme/docs"

    assert answer["labels"] == %{
             "forge" => "forge.example.com",
             "repository" => "acme/shop",
             "repositories" => "acme/shop,acme/docs"
           }
  end
end
