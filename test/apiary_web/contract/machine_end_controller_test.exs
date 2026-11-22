defmodule ApiaryWeb.Contract.MachineEndControllerTest do
  # `POST /v1/dispatches/<dispatch_id>/machine-end` (`ApiaryWeb.Contract.DispatchController`),
  # as a node pool's starter sends it: the `204` signed, with no body and
  # `Cache-Control: no-store`, the state kept, before or after the dispatch ends, `gone`
  # kept for good; each refusal's status and code in the contract's order, its body valid
  # under the vendored `refusal.schema.json`, signed but a `401`. The bodies are the
  # vendored contract's fixtures (`machine-end/` and `invalid/machine-end-*`), each with
  # the clock's time. What the report writes is `Apiary.Dispatches.MachineEndsTest`'s. Not
  # async: one test alters the dispatches' table inside its transaction.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1, unsigned_answer?: 1]
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Dispatches, Repo}
  alias Apiary.Dispatches.Dispatch
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
    scope |> handover_place_fixture() |> Map.put(:scope, scope)
  end

  # The clock's time, two seconds earlier for each request a test sends, so no two of its
  # requests are one signature.
  defp now_time do
    (SignedRequest.now() - 2 * rem(System.unique_integer([:positive, :monotonic]), 125))
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end

  defp report(ctx, dispatch, body, opts \\ []) do
    signed_post(
      build_conn(),
      Keyword.get(opts, :key_id, ctx.key.key_id),
      Keyword.get(opts, :seed, ctx.seed),
      body,
      target: "/v1/dispatches/#{id(dispatch)}/machine-end",
      content_type: "application/json",
      delivery: nil,
      contract_version: "1"
    )
  end

  defp validator(path) do
    JSV.build!(%{"$ref" => @base <> path}, resolver: {Resolver, [@vendored]}, formats: true)
  end

  # The contract's fixture at `path` under `fixtures/`, its time the clock's.
  defp fixture_body(path) do
    @fixtures |> Path.join(path) |> File.read!() |> Jason.decode!() |> Map.put("time", now_time())
  end

  defp body(name), do: fixture_body("machine-end/#{name}.json")

  defp id(%Dispatch{public_id: public_id}), do: public_id
  defp id(public_id) when is_binary(public_id), do: public_id

  # A dispatch of a fresh work item, claimed, not handed over.
  defp dispatch!(ctx) do
    {:ok, _run} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(ctx.scope), 1) end)

    {:ok, %{dispatch: dispatch}} =
      Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now())

    dispatch
  end

  defp refusal(conn, status) do
    body = json_response(conn, status)
    assert {:ok, _} = JSV.validate(body, validator("provisioner/v1/refusal.schema.json"))
    body
  end

  defp refused?(conn, status, code),
    do: refusal(conn, status) == %{"error" => code} and signed_answer?(conn)

  defp kept?(conn) do
    conn.status == 204 and conn.resp_body == "" and signed_answer?(conn) and
      get_resp_header(conn, "cache-control") == ["no-store, no-transform"]
  end

  defp state(%Dispatch{id: id}), do: Repo.get!(Dispatch, id).machine_end_state

  test "each fixture under machine-end/ is 204, signed, with no body: the state kept", ctx do
    reported =
      for {name, state} <- [
            {"deleting", :deleting},
            {"delete-failed", :delete_failed},
            {"gone", :gone}
          ] do
        body = body(name)
        assert {:ok, _} = JSV.validate(body, validator("provisioner/v1/machine-end.schema.json"))

        dispatch = dispatch!(ctx)
        assert kept?(report(ctx, dispatch, body)), name
        assert state(dispatch) == state
        "machine-end/#{name}.json"
      end

    assert Enum.sort(reported) ==
             @fixtures
             |> Path.join("machine-end/*.json")
             |> Path.wildcard()
             |> Enum.map(&Path.relative_to(&1, @fixtures))
             |> Enum.sort()
  end

  test "every report replaces the state, and gone is final: a later one is still 204", ctx do
    dispatch = dispatch!(ctx)

    for {name, state} <- [
          {"deleting", :deleting},
          {"delete-failed", :delete_failed},
          {"deleting", :deleting},
          {"gone", :gone},
          {"delete-failed", :gone},
          {"deleting", :gone}
        ] do
      assert kept?(report(ctx, dispatch, body(name))), name
      assert state(dispatch) == state
    end
  end

  test "is accepted for a run that opened, and after its dispatch ended", ctx do
    %{dispatch: handed_over} = handed_over_fixture(ctx.scope, ctx.key)
    assert kept?(report(ctx, handed_over, body("gone")))

    ended = dispatch!(ctx)
    :ok = Dispatches.release(ctx.key, ended.public_id, %{reason: "stopped"})
    assert %Dispatch{ended_at: %DateTime{}} = Repo.get!(Dispatch, ended.id)
    assert kept?(report(ctx, ended, body("deleting")))
    assert state(ended) == :deleting
  end

  # A dispatch's routes follow the features of the run its claim registered, whatever the
  # run's state: the machine's end and log come after the run ended
  # (`ApiaryWeb.Contract.RunFeatures`).
  test "factory off since the claim: 204 while the run is live, and after it ended", ctx do
    dispatch = dispatch!(ctx)
    previous = Application.get_env(:apiary, :features)
    on_exit(fn -> Application.put_env(:apiary, :features, previous) end)

    Application.put_env(
      :apiary,
      :features,
      Apiary.Features.Saved.close(previous, previous -- [:factory])
    )

    assert kept?(report(ctx, dispatch, body("deleting")))
    assert state(dispatch) == :deleting

    {1, _rows} =
      Repo.update_all(
        from(r in Apiary.Runs.Run, where: r.dispatch_run_id == ^dispatch.dispatch_run_id),
        set: [state: "completed"]
      )

    now = DateTime.utc_now()

    {1, _rows} =
      Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
        set: [ended_at: now, end_cause: :run_ended]
      )

    assert kept?(report(ctx, dispatch, body("gone")))
    assert state(dispatch) == :gone
  end

  # A dispatch released before its handover, whose run of the queue a later claim took:
  # the earlier dispatch follows the run its claim registered, never the later one's.
  test "a released dispatch follows its failed run, not the run a later claim registered",
       ctx do
    {:ok, _run} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(ctx.scope), 1) end)
    {:ok, %{dispatch: first}} = walked_claim(ctx.key, Dispatches.now())
    :ok = Dispatches.release(ctx.key, first.public_id, %{reason: "No machine."})
    {:ok, %{dispatch: second}} = walked_claim(ctx.key, Dispatches.now())
    assert second.dispatch_run_id == first.dispatch_run_id

    # The failed run kept no factory; the later run keeps every feature.
    {1, _rows} =
      Repo.update_all(from(r in Apiary.Runs.Run, where: r.dispatch_id == ^first.id),
        set: [features: Apiary.Features.recorded() -- ["factory", "workflow_model"]]
      )

    previous = Application.get_env(:apiary, :features)
    on_exit(fn -> Application.put_env(:apiary, :features, previous) end)

    Application.put_env(
      :apiary,
      :features,
      Apiary.Features.Saved.close(previous, previous -- [:factory])
    )

    conn = report(ctx, first, body("deleting"))
    assert json_response(conn, 404) == %{"error" => "not_found"}
    assert state(first) == nil
    assert kept?(report(ctx, second, body("deleting")))
  end

  # A dispatch whose lease lapsed before its handover keeps no `ended_at`; its run failed
  # and left its run of the queue, which a later claim took. The lapsed dispatch follows
  # the run its claim registered, never the later one's.
  test "a lapsed dispatch follows its failed run, not the run a later claim registered",
       ctx do
    {:ok, _run} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(ctx.scope), 1) end)
    now = Dispatches.now()
    {:ok, %{dispatch: first}} = walked_claim(ctx.key, now)
    {:ok, %{dispatch: second}} = walked_claim(ctx.key, DateTime.add(now, 700, :second))
    assert second.dispatch_run_id == first.dispatch_run_id
    assert %Dispatch{stale_at: %DateTime{}, ended_at: nil} = Repo.get!(Dispatch, first.id)

    # The failed run kept no factory; the later run keeps every feature.
    {1, _rows} =
      Repo.update_all(from(r in Apiary.Runs.Run, where: r.dispatch_id == ^first.id),
        set: [features: Apiary.Features.recorded() -- ["factory", "workflow_model"]]
      )

    previous = Application.get_env(:apiary, :features)
    on_exit(fn -> Application.put_env(:apiary, :features, previous) end)

    Application.put_env(
      :apiary,
      :features,
      Apiary.Features.Saved.close(previous, previous -- [:factory])
    )

    conn = report(ctx, first, body("deleting"))
    assert json_response(conn, 404) == %{"error" => "not_found"}
    assert state(first) == nil
  end

  describe "the refusals, in the contract's order" do
    test "an unknown dispatch, a malformed id or another pool's is 403 forbidden, one answer",
         ctx do
      dispatch = dispatch!(ctx)

      %{access_key: other_key, pair: other_pair} =
        Apiary.AccessKeysFixtures.enrolled_key_fixture(ctx.scope, pool_fixture(ctx.scope))

      answers =
        for conn <- [
              report(ctx, "dp_0000000000000000", body("gone")),
              report(ctx, "..%2F..%2Fetc%2Fpasswd", body("gone")),
              report(ctx, dispatch, body("gone"),
                key_id: other_key.key_id,
                seed: other_pair.secret
              )
            ] do
          assert refused?(conn, 403, "forbidden")
          conn.resp_body
        end

      assert Enum.uniq(answers) == [~s({"error":"forbidden"})]
      assert state(dispatch) == nil
    end

    test "a body the contract refuses is 400 invalid_request, signed: each invalid fixture",
         ctx do
      dispatch = dispatch!(ctx)

      refused =
        for path <- Path.wildcard(Path.join([@fixtures, "invalid", "machine-end-*.json"])) do
          name = Path.relative_to(path, @fixtures)
          body = fixture_body(name)

          assert {:error, _} =
                   JSV.validate(body, validator("provisioner/v1/machine-end.schema.json"))

          assert refused?(report(ctx, dispatch, body), 400, "invalid_request"), name
          name
        end

      assert Enum.sort(refused) == [
               "invalid/machine-end-undefined-member.json",
               "invalid/machine-end-unknown-state.json",
               "invalid/machine-end-version-2.json",
               "invalid/machine-end-without-state.json"
             ]

      time = now_time()

      for raw <- [
            ~s({"version":1,"time":"#{time}","state":7}),
            ~s({"version":1,"time":"#{time}","state":"gone","state":"gone"}),
            "not json"
          ] do
        assert refused?(report(ctx, dispatch, raw), 400, "invalid_request"), raw
      end

      assert state(dispatch) == nil
    end

    test "under a bad signature is 401, unsigned", ctx do
      dispatch = dispatch!(ctx)
      conn = report(ctx, dispatch, body("gone"), seed: :crypto.strong_rand_bytes(32))
      assert refusal(conn, 401) == %{"error" => "unauthorized"}
      assert unsigned_answer?(conn)
      assert state(dispatch) == nil
    end

    test "a time more than 300 seconds from the clock is 401, unsigned", ctx do
      dispatch = dispatch!(ctx)

      past =
        (SignedRequest.now() - 310)
        |> DateTime.from_unix!()
        |> DateTime.to_iso8601()

      conn = report(ctx, dispatch, Map.put(body("gone"), "time", past))
      assert refusal(conn, 401) == %{"error" => "unauthorized"}
      assert unsigned_answer?(conn)
      assert state(dispatch) == nil
    end
  end

  test "a report that cannot be stored is 503 unavailable, signed, and keeps nothing", ctx do
    dispatch = dispatch!(ctx)

    Repo.query!(
      "ALTER TABLE dispatches ADD CONSTRAINT refuse_machine_end " <>
        "CHECK (machine_end_state IS NULL) NOT VALID"
    )

    {conn, log} = ExUnit.CaptureLog.with_log(fn -> report(ctx, dispatch, body("gone")) end)
    assert refused?(conn, 503, "unavailable")
    assert log =~ "a machine end could not be stored: Postgrex.Error"

    assert state(dispatch) == nil
  end
end
