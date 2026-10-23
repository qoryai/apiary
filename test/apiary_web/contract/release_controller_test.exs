defmodule ApiaryWeb.Contract.ReleaseControllerTest do
  # `POST /v1/dispatches/<dispatch_id>/release` (`ApiaryWeb.Contract.DispatchController`),
  # as a node pool's starter sends it: the body held to the vendored
  # `release.schema.json`, the `204` signed, with no body and `Cache-Control: no-store`,
  # before `dispatched`, and each refusal's status and code, `409` `machine_exists` after
  # `dispatched` among them, its body held to the vendored `refusal.schema.json`, signed
  # but a `401`. The
  # order of the refusals and what each release writes is `Apiary.Dispatches.ReleaseTest`'s;
  # where the feature is off, `ApiaryWeb.Contract.PoolRequestTest`'s. Not async, as the
  # other contract tests of a pool: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1, unsigned_answer?: 1]
  import Apiary.DispatchedRunsFixtures, only: [handover_place_fixture: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Repo}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.Environments.Record
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory

  @vendored Path.expand("../../fixtures/contract", __DIR__)
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
    # The clock's time as the test begins, which `now_time/0` counts down from.
    Process.put(:now_time, {SignedRequest.now(), 0})
    %{scope: scope} = sign_up_fixture()
    Map.put(handover_place_fixture(scope), :scope, scope)
  end

  # A request's time: one second earlier for each request the test sends, counted down from
  # the clock's time as the test began. Two requests to one target with one time are one
  # signed body, which the replay guard refuses with a 401; a time read from the clock
  # again for each request could repeat one, as the clock moves on a second between them.
  defp now_time do
    {base, sent} = Process.get(:now_time)
    Process.put(:now_time, {base, sent + 1})

    (base - sent - 1)
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
      contract_version: "1"
    )
  end

  defp body, do: %{"version" => 1, "time" => now_time(), "reason" => "The job could not start."}

  defp release(ctx, dispatch, opts \\ []) do
    body = Keyword.get(opts, :body, body())
    assert {:ok, _} = JSV.validate(body, validator("provisioner/v1/release.schema.json"))
    post(ctx, dispatch, "release", body, opts)
  end

  # A run claimed: its dispatch, before `dispatched`.
  defp claimed!(ctx) do
    {:ok, %{dispatch: dispatch}} = Dispatches.claim(ctx.key, Dispatches.now())
    dispatch
  end

  # A run claimed and its `dispatched` sent, which hands the dispatch over.
  defp dispatched!(ctx) do
    dispatch = claimed!(ctx)
    conn = post(ctx, dispatch, "dispatched", %{"version" => 1, "time" => now_time()})

    assert conn.status == 204
    dispatch
  end

  defp id(%Dispatch{public_id: public_id}), do: public_id
  defp id(public_id) when is_binary(public_id), do: public_id

  defp queued!(ctx) do
    work_item = work_item_fixture(ctx.scope)
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    run
  end

  defp prebuild!(ctx) do
    collection = collection_fixture(ctx.scope)

    Repo.insert!(%Record{
      organisation_id: ctx.scope.organisation.id,
      workspace_id: ctx.scope.workspace.id,
      pool_id: ctx.pool.id,
      source_collection_id: collection.id
    })

    {:ok, run} =
      Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

    run
  end

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
  defp given_back?(conn) do
    conn.status == 204 and conn.resp_body == "" and signed_answer?(conn) and
      get_resp_header(conn, "cache-control") == ["no-store, no-transform"]
  end

  defp lapse!(%Dispatch{id: id}, fields \\ []) do
    now = DateTime.utc_now()

    lease_until = %{
      DateTime.truncate(DateTime.add(now, -60, :second), :second)
      | microsecond: {0, 6}
    }

    {1, _rows} =
      Repo.update_all(from(d in Dispatch, where: d.id == ^id),
        set:
          [claimed_at: DateTime.add(now, -700, :second), lease_until: lease_until] ++
            Enum.map(fields, &{&1, DateTime.add(now, -680, :second)})
      )
  end

  describe "a release" do
    test "before dispatched is 204, signed, with no body: the run waits again", ctx do
      queued = queued!(ctx)
      dispatch = claimed!(ctx)

      assert given_back?(release(ctx, dispatch))
      assert Repo.get!(DispatchRun, queued.id).state == :waiting
      assert %Dispatch{end_cause: :released} = Repo.get!(Dispatch, dispatch.id)
    end

    test "of a prebuild before dispatched is 204: the run waits again", ctx do
      queued = prebuild!(ctx)
      dispatch = claimed!(ctx)

      assert given_back?(release(ctx, dispatch))
      assert Repo.get!(DispatchRun, queued.id).state == :waiting
    end

    test "after dispatched is 409 machine_exists, past its lease too, and writes nothing",
         ctx do
      queued = queued!(ctx)
      dispatch = dispatched!(ctx)

      assert refused?(release(ctx, dispatch), 409, "machine_exists")
      lapse!(dispatch, [:dispatched_at, :handed_over_at])
      assert refused?(release(ctx, dispatch), 409, "machine_exists")

      assert %DispatchRun{state: :handed_over} = Repo.get!(DispatchRun, queued.id)
      assert %Dispatch{ended_at: nil} = Repo.get!(Dispatch, dispatch.id)
    end

    test "is refused with each status and code, signed", ctx do
      queued!(ctx)
      dispatch = claimed!(ctx)

      # A body the contract refuses.
      invalid = Map.delete(body(), "reason")
      conn = post(ctx, dispatch, "release", invalid)
      assert refused?(conn, 400, "invalid_request")

      # Unknown, of another pool, or of no dispatch's shape: one answer.
      assert refused?(release(ctx, "dp_0000000000000000"), 403, "forbidden")
      assert refused?(release(ctx, "not-a-dispatch"), 403, "forbidden")

      %{access_key: other_key, pair: other_pair} =
        Apiary.AccessKeysFixtures.enrolled_key_fixture(ctx.scope, pool_fixture(ctx.scope))

      assert refused?(
               release(ctx, dispatch, key_id: other_key.key_id, seed: other_pair.secret),
               403,
               "forbidden"
             )

      prebuild!(ctx)
      prebuild = claimed!(ctx)

      # Lapsed before dispatched.
      lapse!(dispatch)
      assert refused?(release(ctx, dispatch), 409, "lease_expired")

      # Ended.
      assert given_back?(release(ctx, prebuild))
      assert refused?(release(ctx, prebuild), 410, "gone")
    end

    test "under a bad signature is 401, unsigned", ctx do
      queued!(ctx)
      dispatch = claimed!(ctx)
      conn = release(ctx, dispatch, seed: :crypto.strong_rand_bytes(32))
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert unsigned_answer?(conn)
      assert %Dispatch{ended_at: nil} = Repo.get!(Dispatch, dispatch.id)
    end

    test "that cannot be written is 503 unavailable, signed, and writes nothing", ctx do
      queued = queued!(ctx)
      dispatch = claimed!(ctx)

      # A rule the release's audit entry breaks, in this test's transaction alone: the
      # write of the release fails.
      Repo.query!(
        "ALTER TABLE audit_entries ADD CONSTRAINT release_test_no_entry " <>
          "CHECK (action <> 'dispatch.release') NOT VALID"
      )

      {conn, log} = ExUnit.CaptureLog.with_log(fn -> release(ctx, dispatch) end)

      assert refused?(conn, 503, "unavailable")
      assert get_resp_header(conn, "cache-control") == ["no-store, no-transform"]
      refute log =~ "The job could not start."
      assert Repo.get!(DispatchRun, queued.id).state == :claimed

      assert %Dispatch{ended_at: nil, slot_freed_at: nil} = Repo.get!(Dispatch, dispatch.id)
      assert Repo.aggregate(from(e in Entry, where: e.action == "dispatch.release"), :count) == 0
    end
  end
end
