defmodule ApiaryWeb.Contract.PrebuiltControllerTest do
  # `POST /v1/dispatches/<dispatch_id>/prebuilt` (`ApiaryWeb.Contract.DispatchController`),
  # as a node pool's starter sends it: the body held to the vendored
  # `prebuilt.schema.json`, the `204` signed, with no body and `Cache-Control: no-store`,
  # the image recorded and the run ended, and each refusal's status and code in the
  # contract's order, its body held to the vendored `refusal.schema.json` and, for the
  # three only a prebuilt meets, equal to its fixture, signed but a `401`. What each
  # prebuilt writes is `Apiary.Dispatches.PrebuiltTest`'s; where the feature is off,
  # `ApiaryWeb.Contract.PoolRequestTest`'s. Not async, as the other contract tests of a
  # pool: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1, unsigned_answer?: 1]

  import Apiary.DispatchedRunsFixtures,
    only: [handover_place_fixture: 1, prebuild_handed_over!: 2, prebuilt_meta: 1]

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Environments, Repo}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.Environments.Record
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory

  @vendored Path.expand("../../fixtures/contract", __DIR__)
  @fixtures Path.join(@vendored, "provisioner/v1/fixtures")
  @base "https://qory.dev/contracts/"

  # The vendored schemas by their URL under the contracts' base. Nothing is fetched.
  defmodule Resolver do
    @moduledoc false
    @behaviour JSV.Resolver

    @base "https://qory.dev/contracts/"

    @impl JSV.Resolver
    def resolve(@base <> path, roots) do
      Enum.find_value(roots, {:error, {:not_vendored, path}}, fn root ->
        file = Path.expand(path, root)

        with true <- String.starts_with?(file, root <> "/"),
             {:ok, body} <- File.read(file),
             {:ok, schema} <- Jason.decode(body) do
          {:ok, schema}
        else
          _ -> nil
        end
      end)
    end

    def resolve(url, _roots), do: {:error, {:not_vendored, url}}
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    Map.put(handover_place_fixture(scope), :scope, scope)
  end

  # The clock's time, two seconds earlier for each request a test sends, so no two of its
  # requests are one signature, even where the clock ticks between them: the same one
  # again is a replay.
  defp now_time do
    (SignedRequest.now() - 2 * rem(System.unique_integer([:positive, :monotonic]), 125))
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end

  defp post(ctx, dispatch, action, body, opts \\ []) do
    signed_post(
      build_conn(),
      Keyword.get(opts, :key_id, ctx.key.key_id),
      Keyword.get(opts, :seed, ctx.seed),
      body,
      target: "/v1/dispatches/#{id(dispatch)}/#{action}",
      content_type: "application/json",
      delivery: nil,
      contract_version: "3"
    )
  end

  # The body of a prebuilt of the run of the queue `queued`, `changes` put over it.
  defp body(%DispatchRun{} = queued, changes \\ %{}) do
    meta = prebuilt_meta(queued)

    Map.merge(
      %{
        "version" => 1,
        "time" => now_time(),
        "run_id" => meta.run_id,
        "image" => meta.image,
        "size" => meta.size,
        "environment_ref" => meta.environment_ref,
        "commit" => meta.commit
      },
      changes
    )
  end

  defp prebuilt(ctx, dispatch, body, opts \\ []) do
    assert {:ok, _} = JSV.validate(body, validator("provisioner/v1/prebuilt.schema.json"))
    post(ctx, dispatch, "prebuilt", body, opts)
  end

  defp handed_over!(ctx), do: prebuild_handed_over!(ctx.scope, ctx.key)

  defp id(%Dispatch{public_id: public_id}), do: public_id
  defp id(public_id) when is_binary(public_id), do: public_id

  defp validator(path) do
    JSV.build!(%{"$ref" => @base <> path},
      resolver: {Resolver, [@vendored]},
      formats: true
    )
  end

  # A refusal of `status` and `code`, its body held to the contract's refusal, signed.
  defp refused?(conn, status, code) do
    body = json_response(conn, status)
    {:ok, _} = JSV.validate(body, validator("provisioner/v1/refusal.schema.json"))
    body == %{"error" => code} and signed_answer?(conn)
  end

  # The 204: signed, with no body, not stored.
  defp recorded?(conn) do
    conn.status == 204 and conn.resp_body == "" and signed_answer?(conn) and
      get_resp_header(conn, "cache-control") == ["no-store, no-transform"]
  end

  defp lapse!(%Dispatch{id: id}) do
    now = DateTime.utc_now()

    lease_until = %{
      DateTime.truncate(DateTime.add(now, -60, :second), :second)
      | microsecond: {0, 6}
    }

    {1, _rows} =
      Repo.update_all(from(d in Dispatch, where: d.id == ^id),
        set: [claimed_at: DateTime.add(now, -700, :second), lease_until: lease_until]
      )
  end

  defp entries,
    do: Repo.aggregate(from(e in Entry, where: e.action == "dispatch.prebuilt"), :count)

  test "a prebuilt after the handover is 204, signed, with no body: the image recorded and the run ended",
       ctx do
    %{collection: collection, dispatch: dispatch, dispatch_run: queued} = handed_over!(ctx)
    body = body(queued)

    assert recorded?(prebuilt(ctx, dispatch, body))

    assert %Record{reported_ref: "env-1", size: 734_003_200} =
             record = Environments.fetch(ctx.pool.id, collection.id)

    assert record.image == body["image"]
    assert record.commit == body["commit"]
    assert record.built_target_path == collection.target_path
    assert %DispatchRun{state: :ended, end_cause: :prebuilt} = Repo.get!(DispatchRun, queued.id)
    assert entries() == 1

    # Any later request naming the dispatch is gone.
    assert refused?(prebuilt(ctx, dispatch, body(queued)), 410, "gone")

    assert refused?(
             post(ctx, dispatch, "release", %{
               "version" => 1,
               "time" => now_time(),
               "reason" => "late",
               "retry" => false
             }),
             410,
             "gone"
           )
  end

  test "the contract's prebuilt fixture is read and recorded, its run_id the dispatch's", ctx do
    %{collection: collection, dispatch: dispatch, dispatch_run: queued} = handed_over!(ctx)

    fixture =
      @fixtures
      |> Path.join("prebuilt/prebuilt.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.merge(%{"time" => now_time(), "run_id" => queued.run_id})

    assert recorded?(prebuilt(ctx, dispatch, fixture))

    assert %Record{reported_ref: "env-3f2a91c4", queued_ref: "env-1"} =
             Environments.fetch(ctx.pool.id, collection.id)
  end

  describe "the refusals, in the contract's order" do
    test "a body the contract refuses is 400 invalid_request, signed, for each refused fixture",
         ctx do
      %{dispatch: dispatch, dispatch_run: queued} = handed_over!(ctx)

      for path <- Path.wildcard(Path.join([@fixtures, "invalid", "prebuilt-*.json"])) do
        raw =
          path
          |> File.read!()
          |> String.replace(~s("2026-10-15T12:20:00Z"), ~s("#{now_time()}"))

        assert refused?(post(ctx, dispatch, "prebuilt", raw), 400, "invalid_request"), path
      end

      assert %DispatchRun{state: :handed_over} = Repo.get!(DispatchRun, queued.id)
      assert entries() == 0
    end

    test "an unknown dispatch, another pool's, or of no dispatch's shape is 403 forbidden, one answer",
         ctx do
      %{dispatch: dispatch, dispatch_run: queued} = handed_over!(ctx)

      %{access_key: other_key, pair: other_pair} =
        Apiary.AccessKeysFixtures.enrolled_key_fixture(ctx.scope, pool_fixture(ctx.scope))

      answers =
        for conn <- [
              prebuilt(ctx, "dp_0000000000000000", body(queued)),
              prebuilt(ctx, "not-a-dispatch", body(queued)),
              prebuilt(ctx, dispatch, body(queued),
                key_id: other_key.key_id,
                seed: other_pair.secret
              )
            ] do
          assert refused?(conn, 403, "forbidden")
          conn.resp_body
        end

      assert Enum.uniq(answers) == [~s({"error":"forbidden"})]
    end

    test "each 409 has its code, and the three a prebuilt alone meets are their fixtures", ctx do
      # lease_expired: a prebuild not handed over whose lease lapsed.
      collection = collection_fixture(ctx.scope)

      {:ok, [lapsed]} =
        Repo.transact(fn -> {:ok, Environments.trigger([collection], Dispatches.now())} end)

      {:ok, %{dispatch: lapsed_dispatch}} = Dispatches.claim(ctx.key, Dispatches.now())
      lapse!(lapsed_dispatch)
      assert refused?(prebuilt(ctx, lapsed_dispatch, body(lapsed)), 409, "lease_expired")

      # not_handed_over: the prebuild, waiting again once its lease lapsed, claimed again
      # and not handed over.
      {:ok, %{dispatch: claimed_dispatch, run: claimed}} =
        Dispatches.claim(ctx.key, Dispatches.now())

      assert claimed.step == "prebuild"
      conn = prebuilt(ctx, claimed_dispatch, body(claimed))
      assert refused?(conn, 409, "not_handed_over")
      assert json_response(conn, 409) == fixture("refusal/not-handed-over.json")

      # not_prebuild: an explore run's dispatch.
      {:ok, explore} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(ctx.scope), 1) end)
      {:ok, %{dispatch: explore_dispatch}} = Dispatches.claim(ctx.key, Dispatches.now())
      conn = prebuilt(ctx, explore_dispatch, body(explore, %{"environment_ref" => "env-1"}))
      assert refused?(conn, 409, "not_prebuild")
      assert json_response(conn, 409) == fixture("refusal/not-prebuild.json")

      # run_mismatch: handed over, another run_id.
      %{dispatch: dispatch, dispatch_run: queued} = handed_over!(ctx)
      conn = prebuilt(ctx, dispatch, body(queued, %{"run_id" => Ecto.UUID.generate()}))
      assert refused?(conn, 409, "run_mismatch")
      assert json_response(conn, 409) == fixture("refusal/run-mismatch.json")

      assert entries() == 0
    end

    test "under a bad signature is 401, unsigned", ctx do
      %{dispatch: dispatch, dispatch_run: queued} = handed_over!(ctx)
      conn = prebuilt(ctx, dispatch, body(queued), seed: :crypto.strong_rand_bytes(32))
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert unsigned_answer?(conn)
      assert %DispatchRun{state: :handed_over} = Repo.get!(DispatchRun, queued.id)
    end

    test "a time more than 300 seconds from the clock is 401, unsigned", ctx do
      %{dispatch: dispatch, dispatch_run: queued} = handed_over!(ctx)

      past =
        (SignedRequest.now() - 310)
        |> DateTime.from_unix!()
        |> DateTime.to_iso8601()

      conn = prebuilt(ctx, dispatch, body(queued, %{"time" => past}))
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert unsigned_answer?(conn)
    end
  end

  test "that cannot be written is 503 unavailable, signed, and writes nothing", ctx do
    %{collection: collection, dispatch: dispatch, dispatch_run: queued} = handed_over!(ctx)

    # A rule the record's build breaks, in this test's transaction alone: the write of the
    # prebuilt fails.
    Repo.query!(
      "ALTER TABLE environments ADD CONSTRAINT prebuilt_test_no_image " <>
        "CHECK (image IS NULL) NOT VALID"
    )

    {conn, log} = ExUnit.CaptureLog.with_log(fn -> prebuilt(ctx, dispatch, body(queued)) end)

    assert refused?(conn, 503, "unavailable")
    assert get_resp_header(conn, "cache-control") == ["no-store, no-transform"]
    refute log =~ "registry.example.com"
    assert %DispatchRun{state: :handed_over} = Repo.get!(DispatchRun, queued.id)
    assert %Dispatch{ended_at: nil, slot_freed_at: nil} = Repo.get!(Dispatch, dispatch.id)
    assert %Record{image: nil} = Environments.fetch(ctx.pool.id, collection.id)
    assert entries() == 0
  end

  defp fixture(path), do: @fixtures |> Path.join(path) |> File.read!() |> Jason.decode!()
end
