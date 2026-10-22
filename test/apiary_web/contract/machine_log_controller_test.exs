defmodule ApiaryWeb.Contract.MachineLogControllerTest do
  # `POST /v1/dispatches/<dispatch_id>/machine-log` (`ApiaryWeb.Contract.DispatchController`),
  # as a node pool's starter sends it: the `204` signed, with no body and
  # `Cache-Control: no-store`, the log kept, once per dispatch, before or after the
  # dispatch ends; each refusal's status and code in the contract's order, signed but a
  # `401`; the body's bounds. The bodies are the contract's fixtures
  # (`contracts/provisioner/v1/fixtures/machine-log` and `invalid/machine-log-*`), written
  # here until the vendored contract has them. What the upload writes is
  # `Apiary.Dispatches.MachineLogsTest`'s. Not async: the features and the folder are the
  # whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1, unsigned_answer?: 1]
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Repo}
  alias Apiary.Dispatches.{Dispatch, MachineLog}
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory
  @moduletag :tmp_dir

  @whole "2026-10-15T12:01:05Z machine created: small\n2026-10-15T12:01:40Z job started\n2026-10-15T12:09:12Z job ended: exit 0\n2026-10-15T12:09:15Z machine stopped\n"
  @truncated "2026-10-15T12:09:12Z job ended: exit 0\n2026-10-15T12:09:15Z machine stopped\n"

  setup %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "machine-logs")
    before = Application.fetch_env(:apiary, :machine_logs_dir)
    Application.put_env(:apiary, :machine_logs_dir, dir)

    on_exit(fn ->
      case before do
        {:ok, value} -> Application.put_env(:apiary, :machine_logs_dir, value)
        :error -> Application.delete_env(:apiary, :machine_logs_dir)
      end
    end)

    %{scope: scope} = sign_up_fixture()
    scope |> handover_place_fixture() |> Map.merge(%{scope: scope, dir: dir})
  end

  # The clock's time, two seconds earlier for each request a test sends, so no two of its
  # requests are one signature.
  defp now_time do
    (SignedRequest.now() - 2 * rem(System.unique_integer([:positive, :monotonic]), 125))
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end

  defp upload(ctx, dispatch, body, opts \\ []) do
    signed_post(
      build_conn(),
      Keyword.get(opts, :key_id, ctx.key.key_id),
      Keyword.get(opts, :seed, ctx.seed),
      body,
      target: "/v1/dispatches/#{id(dispatch)}/machine-log",
      content_type: "application/json",
      delivery: nil,
      contract_version: "3"
    )
  end

  # The contract's fixture `machine-log/whole.json`, `changes` put over it.
  defp body(changes \\ %{}),
    do: Map.merge(%{"version" => 1, "time" => now_time(), "log" => @whole}, changes)

  defp id(%Dispatch{public_id: public_id}), do: public_id
  defp id(public_id) when is_binary(public_id), do: public_id

  # A dispatch of a fresh work item, claimed and its job started, not handed over.
  defp dispatch!(ctx) do
    {:ok, _run} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(ctx.scope), 1) end)
    dispatched!(ctx.key).dispatch
  end

  defp refused?(conn, status, code),
    do: json_response(conn, status) == %{"error" => code} and signed_answer?(conn)

  defp stored?(conn) do
    conn.status == 204 and conn.resp_body == "" and signed_answer?(conn) and
      get_resp_header(conn, "cache-control") == ["no-store, no-transform"]
  end

  defp record(%Dispatch{id: id}), do: Repo.get_by(MachineLog, dispatch_id: id)

  test "the fixture whole.json is 204, signed, with no body: the log kept as sent", ctx do
    dispatch = dispatch!(ctx)
    assert stored?(upload(ctx, dispatch, body()))
    assert File.read!(Path.join(ctx.dir, dispatch.public_id)) == @whole
    assert %MachineLog{truncated: false, byte_size: size} = record(dispatch)
    assert size == byte_size(@whole)
  end

  test "the fixture truncated.json keeps truncated", ctx do
    dispatch = dispatch!(ctx)
    assert stored?(upload(ctx, dispatch, body(%{"log" => @truncated, "truncated" => true})))
    assert %MachineLog{truncated: true} = record(dispatch)
  end

  test "is accepted for a run that opened, and after its dispatch ended", ctx do
    %{dispatch: handed_over} = handed_over_fixture(ctx.scope, ctx.key)
    assert stored?(upload(ctx, handed_over, body()))

    ended = dispatch!(ctx)
    :ok = Dispatches.release(ctx.key, ended.public_id, %{reason: "stopped", retry: false})
    assert %Dispatch{ended_at: %DateTime{}} = Repo.get!(Dispatch, ended.id)
    assert stored?(upload(ctx, ended, body()))

    lapsed = dispatch!(ctx)
    now = DateTime.utc_now()

    {1, _rows} =
      Repo.update_all(from(d in Dispatch, where: d.id == ^lapsed.id),
        set: [
          claimed_at: DateTime.add(now, -700, :second),
          lease_until: %{
            DateTime.truncate(DateTime.add(now, -60, :second), :second)
            | microsecond: {0, 6}
          },
          dispatched_at: DateTime.add(now, -690, :second)
        ]
      )

    assert stored?(upload(ctx, lapsed, body()))
  end

  describe "the refusals, in the contract's order" do
    test "an unknown dispatch, one that escapes the folder, or another pool's is 403 forbidden, one answer",
         ctx do
      dispatch = dispatch!(ctx)

      %{access_key: other_key, pair: other_pair} =
        Apiary.AccessKeysFixtures.enrolled_key_fixture(ctx.scope, pool_fixture(ctx.scope))

      answers =
        for conn <- [
              upload(ctx, "dp_0000000000000000", body()),
              upload(ctx, "..%2F..%2Fetc%2Fpasswd", body()),
              upload(ctx, "dp_0000000000000000%2F..%2F..%2Foutside", body()),
              upload(ctx, dispatch, body(), key_id: other_key.key_id, seed: other_pair.secret)
            ] do
          assert refused?(conn, 403, "forbidden")
          conn.resp_body
        end

      assert Enum.uniq(answers) == [~s({"error":"forbidden"})]
      assert record(dispatch) == nil
      refute File.exists?(ctx.dir)
    end

    test "a second upload is 409 machine_log_exists, the contract's fixture, and changes nothing",
         ctx do
      dispatch = dispatch!(ctx)
      assert stored?(upload(ctx, dispatch, body()))

      conn = upload(ctx, dispatch, body(%{"log" => @truncated, "truncated" => true}))
      assert refused?(conn, 409, "machine_log_exists")
      assert File.read!(Path.join(ctx.dir, dispatch.public_id)) == @whole
      assert %MachineLog{truncated: false} = record(dispatch)
    end

    test "a body the contract refuses is 400 invalid_request, signed: each invalid fixture",
         ctx do
      dispatch = dispatch!(ctx)
      time = now_time()

      for raw <- [
            # invalid/machine-log-version-2.json
            ~s({"version":2,"time":"#{time}","log":"x\\n"}),
            # invalid/machine-log-undefined-member.json
            ~s({"version":1,"time":"#{time}","log":"x\\n","gzip":true}),
            # invalid/machine-log-without-log.json
            ~s({"version":1,"time":"#{time}","truncated":false}),
            # invalid/machine-log-log-nul.json
            ~s({"version":1,"time":"#{time}","log":"machine created\\u0000\\n"}),
            ~s({"version":1,"time":"#{time}","log":"x","truncated":"yes"}),
            ~s({"version":1,"time":"#{time}","log":7}),
            ~s({"version":1,"time":"#{time}","log":"x","log":"y"})
          ] do
        assert refused?(upload(ctx, dispatch, raw), 400, "invalid_request"), raw
      end

      assert record(dispatch) == nil
    end

    test "a log of 786,432 characters is taken, one of 786,433 is 400, and a body over 1 MiB is 413",
         ctx do
      at_limit = dispatch!(ctx)
      assert stored?(upload(ctx, at_limit, body(%{"log" => String.duplicate("a", 786_432)})))
      assert record(at_limit).byte_size == 786_432

      over = dispatch!(ctx)

      assert refused?(
               upload(ctx, over, body(%{"log" => String.duplicate("a", 786_433)})),
               400,
               "invalid_request"
             )

      # 300,000 characters of 4 bytes each: within the characters, over 1 MiB as sent.
      conn = upload(ctx, over, body(%{"log" => String.duplicate("😀", 300_000)}))
      assert json_response(conn, 413) == %{"error" => "payload_too_large"}
      assert record(over) == nil
    end

    test "under a bad signature is 401, unsigned", ctx do
      dispatch = dispatch!(ctx)
      conn = upload(ctx, dispatch, body(), seed: :crypto.strong_rand_bytes(32))
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert unsigned_answer?(conn)
      assert record(dispatch) == nil
    end

    test "a time more than 300 seconds from the clock is 401, unsigned", ctx do
      dispatch = dispatch!(ctx)

      past =
        (SignedRequest.now() - 310)
        |> DateTime.from_unix!()
        |> DateTime.to_iso8601()

      conn = upload(ctx, dispatch, body(%{"time" => past}))
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert unsigned_answer?(conn)
    end
  end

  test "with no folder set is 503 unavailable, signed, and keeps nothing", ctx do
    dispatch = dispatch!(ctx)
    Application.put_env(:apiary, :machine_logs_dir, nil)

    {conn, log} = ExUnit.CaptureLog.with_log(fn -> upload(ctx, dispatch, body()) end)
    assert refused?(conn, 503, "unavailable")
    assert log =~ "APIARY_MACHINE_LOGS_DIR is not set"
    refute log =~ "machine created"
    assert record(dispatch) == nil
  end
end
