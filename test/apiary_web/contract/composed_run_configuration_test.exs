defmodule ApiaryWeb.Contract.ComposedRunConfigurationTest do
  # The image a run of the queue is given, through the endpoints alone: the attach of a
  # run handed over names the image the pool that claimed it recorded for the run's
  # target, beside the security_policy, under the composed document's digest; its reloads
  # and its batches carry the same image and digest, a policy change moving the digest and
  # never the image. A prebuild under a policy that names an image is given the policy
  # without it, and no run is given an image beside a policy that names one. Every other
  # run is answered byte for byte as before. Not async, as the other contract tests of a
  # pool: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.ContractFixtures
  import Apiary.DispatchedRunsFixtures, only: [handover_place_fixture: 1, dispatched!: 2]
  import Apiary.NodesFixtures, only: [collection_fixture: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Policy, Repo}
  alias Apiary.Environments.Record
  alias Apiary.Policy.{ComposedConfiguration, Render, RunConfiguration, Schema}
  alias Apiary.Runs.{Answer, Attach, Run, RunVariables}
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory

  @image "registry.example.com/acme/shop-env@sha256:" <> String.duplicate("3b9d", 16)
  @naming ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"observe","allow":["api.example","cdn.example"]},"image":"with-docker"}})

  setup do
    %{scope: scope} = sign_up_fixture()

    scope
    |> handover_place_fixture()
    |> Map.merge(%{scope: scope})
  end

  ## The workspace, the record and the runs

  # A managed workspace: its baseline, version 1.
  defp managed!(ctx) do
    {:ok, _rule} = Policy.allow(ctx.scope, nil, %{host: "api.example"})
    current!(ctx)
  end

  defp current!(ctx) do
    {:ok, configuration} = Policy.current_configuration(ctx.scope, nil)
    configuration
  end

  # A version of the baseline whose policy names an image, written as it is.
  defp naming!(ctx) do
    current = current!(ctx)

    Repo.insert!(%RunConfiguration{
      organisation_id: ctx.scope.organisation.id,
      workspace_id: ctx.scope.workspace.id,
      version: current.version + 1,
      document: @naming,
      digest: Render.digest(@naming),
      rendered_at: DateTime.utc_now()
    })
  end

  # The pool's environment record of a live collection of `target`, with an `image` built
  # for `built` (the target unless given).
  defp recorded!(ctx, target, built \\ nil) do
    {system, path} = target
    {built_system, built_path} = built || target
    collection = collection_fixture(ctx.scope, target_system: system, target_path: path)
    now = DateTime.utc_now()

    Repo.insert!(%Record{
      organisation_id: ctx.scope.organisation.id,
      workspace_id: ctx.scope.workspace.id,
      pool_id: ctx.pool.id,
      source_collection_id: collection.id,
      queued_ref: "env-1",
      queued_at: now,
      queued_target_system: system,
      queued_target_path: path,
      image: @image,
      size: 734_003_200,
      commit: "9c1e4a7b2d5f8e0a3c6b9d2f5a8c1e4b7d0a3f6c",
      built_at: now,
      reported_ref: "env-1",
      built_target_system: built_system,
      built_target_path: built_path,
      built_queued_at: now
    })
  end

  # The target a run of the queue is handed over for: the work item's collection's.
  @shop {"forge.example.com", "acme/shop"}

  # A run of the queue for the step explore, claimed by the pool, its job started and
  # handed over: its id and run key.
  defp explore!(ctx) do
    work_item = work_item_fixture(ctx.scope)
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    {:ok, %{dispatch: dispatch}} = Dispatches.claim(ctx.key, Dispatches.now(), 1)
    assert pool_post(ctx, dispatch, "dispatched").status == 204
    handover = pool_post(ctx, dispatch, "handover")
    assert %{"run_id" => run_id, "run_key" => run_key} = json_response(handover, 200)
    {run_id, run_key}
  end

  # A prebuild of a fresh collection, queued by the trigger, claimed by the pool at
  # revision 2 and handed over: its id and run key.
  defp prebuild!(ctx) do
    collection = collection_fixture(ctx.scope, target_path: "acme/shop")

    {:ok, _queued} =
      Repo.transact(fn -> {:ok, Apiary.Environments.trigger([collection], Dispatches.now())} end)

    %{dispatch: dispatch} = dispatched!(ctx.key, 2)

    {:ok, %{run: run, run_key: run_key}} =
      Dispatches.handover(ctx.key, dispatch.public_id, %{
        revision: 2,
        body: ~s({"version":1,"time":"2026-10-18T12:00:00Z"})
      })

    {run.node_run_id, run_key}
  end

  # A run a node registered itself, through the workspace's gateway: its id and run key.
  defp session!(ctx) do
    %{access_key: key, secret: secret} = contract_key_fixture(ctx.scope)
    run_id = Ecto.UUID.generate()

    conn =
      signed_register(
        build_conn(),
        key.key_id,
        secret,
        Jason.encode!(
          gateway_registration(run_id, %{
            "labels" => %{"forge" => "forge.example.com", "repository" => "acme/shop"}
          })
        )
      )

    assert %{"run_key" => run_key} = json_response(conn, 200)
    {run_id, run_key}
  end

  defp run(run_id), do: Repo.one!(from r in Run, where: r.node_run_id == ^run_id)

  defp composed_rows(ctx),
    do:
      Repo.all(from c in ComposedConfiguration, where: c.workspace_id == ^ctx.scope.workspace.id)

  ## The endpoints

  defp now_time,
    do: SignedRequest.now() |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp pool_post(ctx, dispatch, action) do
    signed_post(build_conn(), ctx.key.key_id, ctx.seed, %{"version" => 1, "time" => now_time()},
      target: "/v1/dispatches/#{dispatch.public_id}/#{action}",
      content_type: "application/json",
      delivery: nil
    )
  end

  defp attach(ctx, run_id, run_key) do
    {key, seed} = ctx.gateway_key
    signed_attach(build_conn(), key.key_id, seed, run_id, Jason.encode!(attach_body(run_key)))
  end

  defp reload(ctx, run_id) do
    {key, seed} = ctx.gateway_key
    signed_get(build_conn(), key.key_id, seed, "/v1/runs/" <> run_id)
  end

  # A batch of the run's heartbeat at `sequence`: the digest its answer carries, or nil.
  defp batch_digest(ctx, run_id, sequence) do
    {key, seed} = ctx.gateway_key
    event = wire_event(run_id, sequence, "run.heartbeat", %{"elapsed_seconds" => 30})
    conn = signed_post(build_conn(), key.key_id, seed, [event])
    assert response(conn, 202) == ""
    conn |> get_resp_header("x-qory-run-configuration") |> List.first()
  end

  defp digest_header(conn), do: get_resp_header(conn, "x-qory-run-configuration")

  ## What a run is answered

  # The attach's bytes and the reload's of `document`, as the run is answered them: the
  # document, then the run's variables, labels and what it is about.
  defp attach_bytes(document, run),
    do:
      Attach.answer_body(
        document,
        run.registration_variables,
        run.registration_labels,
        run.registration_about
      )

  defp reload_bytes(document, run),
    do:
      Answer.append_members(document, [
        {"variables",
         run.registration_variables &&
           RunVariables.document(run.registration_variables)}
      ])

  # Never an image both at the top level and in the security_policy: Forager's rule that
  # the two agree never has anything to decide.
  defp refute_two_images(body) do
    decoded = Jason.decode!(body)

    refute Map.has_key?(decoded, "image") and
             Map.has_key?(decoded["security_policy"] || %{}, "image")
  end

  # The run is answered as before this change: the attach, the reload and a batch carry
  # `document` (nil for a workspace that serves none) under its digest, the run keeps no
  # image, and nothing is composed.
  defp assert_as_before(ctx, {run_id, run_key}, document) do
    attached = attach(ctx, run_id, run_key)
    assert attached.status == 200
    run = run(run_id)

    {document, digest} =
      if document,
        do: {document, Render.digest(document)},
        else: {Render.no_policy_document(), Render.digest(Render.no_policy_document())}

    assert attached.resp_body == attach_bytes(document, run)
    assert digest_header(attached) == [digest]
    assert get_resp_header(attached, "etag") == [~s("#{digest}")]
    assert run.attach_answer_digest == digest
    assert run.configured_image == nil

    reloaded = reload(ctx, run_id)

    if document == Render.no_policy_document() do
      assert json_response(reloaded, 404) == %{"error" => "not_found"}
      assert batch_digest(ctx, run_id, 2) == nil
    else
      assert reloaded.status == 200
      assert reloaded.resp_body == reload_bytes(document, run)
      assert digest_header(reloaded) == [digest]
      assert get_resp_header(reloaded, "etag") == [~s("#{digest}")]
      assert batch_digest(ctx, run_id, 2) == digest
    end

    assert composed_rows(ctx) == []
  end

  describe "a run of the queue with a recorded image" do
    test "is given it beside the policy, on its attach, its reloads, its batches and a repeat",
         ctx do
      policy = managed!(ctx)
      recorded!(ctx, @shop)
      {run_id, run_key} = explore!(ctx)

      attached = attach(ctx, run_id, run_key)
      assert attached.status == 200
      run = run(run_id)

      composed = ComposedConfiguration.compose(policy.document, @image)
      digest = Render.digest(composed)
      refute digest == policy.digest

      assert composed ==
               String.replace(
                 policy.document,
                 ~s({"version":1,),
                 ~s({"version":1,"image":"#{@image}",),
                 global: false
               )

      assert attached.resp_body == attach_bytes(composed, run)
      assert digest_header(attached) == [digest]
      assert get_resp_header(attached, "etag") == [~s("#{digest}")]
      assert Schema.validate(attached.resp_body) == :ok
      refute_two_images(attached.resp_body)

      assert run.configured_image == @image
      assert run.attach_answer_digest == digest

      assert [%ComposedConfiguration{} = row] = composed_rows(ctx)
      assert row.digest == digest
      assert row.document == composed
      assert row.image == @image
      assert row.run_configuration_id == policy.id

      reloaded = reload(ctx, run_id)
      assert reloaded.status == 200
      assert reloaded.resp_body == reload_bytes(composed, run)
      assert digest_header(reloaded) == [digest]

      assert batch_digest(ctx, run_id, 2) == digest

      # A repeat of the attach is given what the attach was, read by its digest.
      again = attach(ctx, run_id, run_key)
      assert again.status == 200
      assert again.resp_body == attached.resp_body
      assert digest_header(again) == [digest]

      assert [^row] = composed_rows(ctx)
    end

    test "keeps its image when the policy changes mid-run, and reloads only for the policy",
         ctx do
      managed!(ctx)
      recorded!(ctx, @shop)
      {run_id, run_key} = explore!(ctx)
      assert attach(ctx, run_id, run_key).status == 200
      before = batch_digest(ctx, run_id, 2)

      {:ok, _rule} = Policy.allow(ctx.scope, nil, %{host: "cdn.example"})
      newer = current!(ctx)
      composed = ComposedConfiguration.compose(newer.document, @image)
      digest = Render.digest(composed)

      # The batch tells the run its configuration moved; the reload gives the new policy
      # with the same image.
      assert batch_digest(ctx, run_id, 3) == digest
      refute digest == before

      reloaded = reload(ctx, run_id)
      assert reloaded.status == 200
      assert reloaded.resp_body == reload_bytes(composed, run(run_id))
      assert digest_header(reloaded) == [digest]
      assert Jason.decode!(reloaded.resp_body)["image"] == @image

      # A newer prebuild recorded since gives the run nothing new: its image is fixed.
      Repo.update_all(from(r in Record, where: r.pool_id == ^ctx.pool.id),
        set: [image: "registry.example.com/acme/shop-env@sha256:" <> String.duplicate("7e0a", 16)]
      )

      assert Jason.decode!(reload(ctx, run_id).resp_body)["image"] == @image
      assert batch_digest(ctx, run_id, 4) == digest
    end

    test "is not shown behind the policy for its image", ctx do
      managed!(ctx)
      recorded!(ctx, @shop)
      {run_id, run_key} = explore!(ctx)
      assert attach(ctx, run_id, run_key).status == 200

      # The run reports what it holds, the composed digest.
      {key, seed} = ctx.gateway_key
      event = wire_event(run_id, 2, "run.heartbeat", %{"elapsed_seconds" => 30})
      held = run(run_id).attach_answer_digest

      conn =
        signed_post(build_conn(), key.key_id, seed, [event], run_configuration: held)

      assert response(conn, 202) == ""

      run = run(run_id)
      assert run.reported_run_configuration_digest == held

      assert %{drift: false, reported: reported, in_force: in_force} =
               Policy.digests(ctx.scope, run)

      assert reported == in_force
    end

    test "of an unmanaged workspace is given the image alone, on its attach and its reloads",
         ctx do
      recorded!(ctx, @shop)
      {run_id, run_key} = explore!(ctx)

      attached = attach(ctx, run_id, run_key)
      assert attached.status == 200
      run = run(run_id)

      composed = ~s({"version":1,"image":"#{@image}"})
      digest = Render.digest(composed)
      assert attached.resp_body == attach_bytes(composed, run)
      assert digest_header(attached) == [digest]
      assert Schema.validate(attached.resp_body) == :ok
      assert run.configured_image == @image

      assert [%ComposedConfiguration{run_configuration_id: nil, image: @image}] =
               composed_rows(ctx)

      # Never not found: the image is fixed when the run starts.
      reloaded = reload(ctx, run_id)
      assert reloaded.status == 200
      assert reloaded.resp_body == reload_bytes(composed, run)
      assert digest_header(reloaded) == [digest]

      # The workspace serves no policy, so its batches carry no digest.
      assert batch_digest(ctx, run_id, 2) == nil

      assert attach(ctx, run_id, run_key).resp_body == attached.resp_body
    end

    test "whose workspace's policy is made mid-run is given the policy with its image", ctx do
      recorded!(ctx, @shop)
      {run_id, run_key} = explore!(ctx)
      assert attach(ctx, run_id, run_key).status == 200

      policy = managed!(ctx)
      composed = ComposedConfiguration.compose(policy.document, @image)
      digest = Render.digest(composed)

      assert batch_digest(ctx, run_id, 2) == digest
      reloaded = reload(ctx, run_id)
      assert reloaded.resp_body == reload_bytes(composed, run(run_id))
      assert digest_header(reloaded) == [digest]
    end
  end

  describe "a workspace that stops serving its policy mid-run" do
    # The instance without the `security` feature, for what `fun` does: the workspace's
    # policy is served to nobody.
    defp without_security(fun) do
      features = Application.get_env(:apiary, :features)

      try do
        Application.put_env(:apiary, :features, List.delete(features, :security))
        fun.()
      after
        Application.put_env(:apiary, :features, features)
      end
    end

    test "never loosens a run given an image: its reload is not found", ctx do
      managed!(ctx)
      recorded!(ctx, @shop)
      {run_id, run_key} = explore!(ctx)
      assert attach(ctx, run_id, run_key).status == 200
      assert run(run_id).configured_image == @image

      without_security(fn ->
        assert json_response(reload(ctx, run_id), 404) == %{"error" => "not_found"}
      end)

      # Served again, the reload is the policy with the image.
      assert reload(ctx, run_id).status == 200
    end

    test "never loosens a run given no image: its reload is not found", ctx do
      managed!(ctx)
      {run_id, run_key} = explore!(ctx)
      assert attach(ctx, run_id, run_key).status == 200
      assert run(run_id).configured_image == nil

      without_security(fn ->
        assert json_response(reload(ctx, run_id), 404) == %{"error" => "not_found"}
      end)
    end

    test "gives a run that was given no policy at its attach its image alone again", ctx do
      recorded!(ctx, @shop)
      {run_id, run_key} = explore!(ctx)
      attached = attach(ctx, run_id, run_key)
      assert attached.status == 200

      without_security(fn ->
        reloaded = reload(ctx, run_id)
        assert reloaded.status == 200
        assert Jason.decode!(reloaded.resp_body)["image"] == @image
        refute Map.has_key?(Jason.decode!(reloaded.resp_body), "security_policy")
      end)
    end

    test "never loosens a run given no policy at its attach that took one on a reload",
         ctx do
      recorded!(ctx, @shop)
      {run_id, run_key} = explore!(ctx)
      attached = attach(ctx, run_id, run_key)
      assert attached.status == 200
      refute Map.has_key?(Jason.decode!(attached.resp_body), "security_policy")

      # The policy made mid-run reaches the run on a reload.
      policy = managed!(ctx)
      reloaded = reload(ctx, run_id)
      assert reloaded.status == 200

      assert Jason.decode!(reloaded.resp_body)["security_policy"] ==
               Jason.decode!(policy.document)["security_policy"]

      # The policy no longer served, the run keeps it: not found, never the image alone.
      without_security(fn ->
        assert json_response(reload(ctx, run_id), 404) == %{"error" => "not_found"}
      end)
    end
  end

  describe "a run answered as before" do
    test "a run a node registered itself, whatever the pool recorded", ctx do
      policy = managed!(ctx)
      recorded!(ctx, @shop)
      assert_as_before(ctx, session!(ctx), policy.document)
    end

    test "a run a node registered itself, of an unmanaged workspace", ctx do
      recorded!(ctx, @shop)
      assert_as_before(ctx, session!(ctx), nil)
    end

    test "a run of the queue with no recorded image", ctx do
      policy = managed!(ctx)
      assert_as_before(ctx, explore!(ctx), policy.document)
    end

    test "a run of the queue with no recorded image, of an unmanaged workspace", ctx do
      assert_as_before(ctx, explore!(ctx), nil)
    end

    test "a run of the queue whose recorded image was built for another target",
         ctx do
      policy = managed!(ctx)
      recorded!(ctx, @shop, {"forge.example.com", "acme/docs"})
      assert_as_before(ctx, explore!(ctx), policy.document)
    end

    test "a prebuild under a policy that names no image", ctx do
      policy = managed!(ctx)
      recorded!(ctx, {"code.example.com", "acme/shop"})
      assert_as_before(ctx, prebuild!(ctx), policy.document)
    end

    test "a prebuild of an unmanaged workspace", ctx do
      recorded!(ctx, {"code.example.com", "acme/shop"})
      assert_as_before(ctx, prebuild!(ctx), nil)
    end
  end

  describe "a policy that names an image" do
    test "gives a prebuild the policy without it, on its attach and its reloads", ctx do
      managed!(ctx)
      naming = naming!(ctx)
      {run_id, run_key} = prebuild!(ctx)

      attached = attach(ctx, run_id, run_key)
      assert attached.status == 200
      run = run(run_id)

      composed =
        ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"observe","allow":["api.example","cdn.example"]}}})

      digest = Render.digest(composed)
      assert attached.resp_body == attach_bytes(composed, run)
      assert digest_header(attached) == [digest]
      refute Map.has_key?(Jason.decode!(attached.resp_body), "image")
      assert run.configured_image == nil

      assert [%ComposedConfiguration{image: nil, document: ^composed} = row] =
               composed_rows(ctx)

      assert row.run_configuration_id == naming.id

      reloaded = reload(ctx, run_id)
      assert reloaded.resp_body == reload_bytes(composed, run)
      assert digest_header(reloaded) == [digest]
      assert batch_digest(ctx, run_id, 2) == digest

      assert attach(ctx, run_id, run_key).resp_body == attached.resp_body
    end

    test "gives a run of the queue no image beside it, even with one recorded", ctx do
      managed!(ctx)
      naming!(ctx)
      recorded!(ctx, @shop)
      {run_id, run_key} = explore!(ctx)

      attached = attach(ctx, run_id, run_key)
      assert attached.status == 200
      run = run(run_id)

      assert attached.resp_body == attach_bytes(@naming, run)
      assert digest_header(attached) == [Render.digest(@naming)]
      refute Map.has_key?(Jason.decode!(attached.resp_body), "image")
      refute_two_images(attached.resp_body)
      assert run.configured_image == nil

      reloaded = reload(ctx, run_id)
      assert reloaded.resp_body == reload_bytes(@naming, run)
      refute_two_images(reloaded.resp_body)
      assert batch_digest(ctx, run_id, 2) == Render.digest(@naming)
      assert composed_rows(ctx) == []
    end

    test "made mid-run keeps the run's image on its reloads, and applies the rest",
         ctx do
      policy = managed!(ctx)
      recorded!(ctx, @shop)
      {run_id, run_key} = explore!(ctx)
      assert attach(ctx, run_id, run_key).status == 200
      assert run(run_id).configured_image == @image

      assert Jason.decode!(policy.document)["security_policy"]["egress"]["allow"] == [
               "api.example"
             ]

      naming = naming!(ctx)

      composed =
        ComposedConfiguration.compose(ComposedConfiguration.without_image(@naming), @image)

      digest = Render.digest(composed)
      refute digest == run(run_id).attach_answer_digest

      # The batch tells the run its policy moved; the reload is the policy in force without
      # its image, beside the run's image, under the composed document's digest.
      assert batch_digest(ctx, run_id, 2) == digest

      reloaded = reload(ctx, run_id)
      assert reloaded.status == 200
      assert reloaded.resp_body == reload_bytes(composed, run(run_id))
      assert digest_header(reloaded) == [digest]
      assert Schema.validate(reloaded.resp_body) == :ok
      refute_two_images(reloaded.resp_body)

      decoded = Jason.decode!(reloaded.resp_body)
      assert decoded["image"] == @image
      refute Map.has_key?(decoded["security_policy"], "image")
      assert decoded["security_policy"]["egress"]["allow"] == ["api.example", "cdn.example"]

      assert [%ComposedConfiguration{image: @image} = row] =
               Enum.filter(composed_rows(ctx), &(&1.digest == digest))

      assert row.run_configuration_id == naming.id

      # The run reports what it reloaded: it is behind nothing.
      {key, seed} = ctx.gateway_key
      event = wire_event(run_id, 3, "run.heartbeat", %{"elapsed_seconds" => 30})
      conn = signed_post(build_conn(), key.key_id, seed, [event], run_configuration: digest)
      assert response(conn, 202) == ""
      assert get_resp_header(conn, "x-qory-run-configuration") == [digest]

      assert %{drift: false, reported: reported, in_force: in_force} =
               Policy.digests(ctx.scope, run(run_id))

      assert reported == naming.digest
      assert in_force == naming.digest

      # The next run starts in the policy's image: no top-level image.
      {next_id, next_key} = explore!(ctx)
      attached = attach(ctx, next_id, next_key)
      assert attached.status == 200
      assert attached.resp_body == attach_bytes(@naming, run(next_id))
      assert digest_header(attached) == [naming.digest]
      refute Map.has_key?(Jason.decode!(attached.resp_body), "image")
      assert run(next_id).configured_image == nil
    end
  end
end
