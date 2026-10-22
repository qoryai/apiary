defmodule ApiaryWeb.Contract.MachineLogControllerTest do
  # `POST /v1/dispatches/<dispatch_id>/machine-log` (`ApiaryWeb.Contract.DispatchController`),
  # as a node pool's starter sends it: the `204` signed, with no body and
  # `Cache-Control: no-store`, the log kept, once per dispatch, before or after the
  # dispatch ends; each refusal's status and code in the contract's order, its body valid
  # under the vendored `refusal.schema.json`, signed but a `401`; the body's bounds. The bodies are
  # the vendored contract's fixtures (`machine-log/` and `invalid/machine-log-*`), each with
  # the clock's time. What the upload writes is `Apiary.Dispatches.MachineLogsTest`'s. Not
  # async: the features and the folder are the whole node's.
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

  @whole @fixtures |> Path.join("machine-log/whole.json") |> File.read!() |> Jason.decode!()

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

  # The contract's fixture `machine-log/whole.json`, its time the clock's, `changes` put
  # over it.
  defp body(changes \\ %{}), do: Map.merge(fixture_body("machine-log/whole.json"), changes)

  defp id(%Dispatch{public_id: public_id}), do: public_id
  defp id(public_id) when is_binary(public_id), do: public_id

  # A dispatch of a fresh work item, claimed and its job started, not handed over.
  defp dispatch!(ctx) do
    {:ok, _run} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(ctx.scope), 1) end)
    {:ok, %{dispatch: dispatch}} = Dispatches.claim(ctx.key, Dispatches.now())
    dispatch
  end

  # The body of a refusal of `status`, after a check that it is valid under the contract's
  # refusal.
  defp refusal(conn, status) do
    body = json_response(conn, status)
    assert {:ok, _} = JSV.validate(body, validator("provisioner/v1/refusal.schema.json"))
    body
  end

  # A refusal of `status` and `code`, its body valid under the contract's refusal, signed.
  defp refused?(conn, status, code),
    do: refusal(conn, status) == %{"error" => code} and signed_answer?(conn)

  defp stored?(conn) do
    conn.status == 204 and conn.resp_body == "" and signed_answer?(conn) and
      get_resp_header(conn, "cache-control") == ["no-store, no-transform"]
  end

  defp record(%Dispatch{id: id}), do: Repo.get_by(MachineLog, dispatch_id: id)

  test "each fixture under machine-log/ is 204, signed, with no body: the log and truncated kept as sent",
       ctx do
    uploaded =
      for path <- Path.wildcard(Path.join([@fixtures, "machine-log", "*.json"])) do
        name = Path.relative_to(path, @fixtures)
        body = fixture_body(name)
        assert {:ok, _} = JSV.validate(body, validator("provisioner/v1/machine-log.schema.json"))

        dispatch = dispatch!(ctx)
        assert stored?(upload(ctx, dispatch, body)), name
        assert File.read!(Path.join(ctx.dir, dispatch.public_id)) == body["log"]
        assert %MachineLog{truncated: truncated, byte_size: size} = record(dispatch)
        assert {truncated, size} == {Map.get(body, "truncated", false), byte_size(body["log"])}
        name
      end

    assert Enum.sort(uploaded) == ["machine-log/truncated.json", "machine-log/whole.json"]
  end

  test "is accepted for a run that opened, and after its dispatch ended", ctx do
    %{dispatch: handed_over} = handed_over_fixture(ctx.scope, ctx.key)
    assert stored?(upload(ctx, handed_over, body()))

    ended = dispatch!(ctx)
    :ok = Dispatches.release(ctx.key, ended.public_id, %{reason: "stopped"})
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

      conn = upload(ctx, dispatch, fixture_body("machine-log/truncated.json"))
      assert refused?(conn, 409, "machine_log_exists")

      assert json_response(conn, 409) ==
               @fixtures
               |> Path.join("refusal/machine-log-exists.json")
               |> File.read!()
               |> Jason.decode!()

      assert File.read!(Path.join(ctx.dir, dispatch.public_id)) == @whole["log"]
      assert %MachineLog{truncated: false} = record(dispatch)
    end

    test "a body the contract refuses is 400 invalid_request, signed: each invalid fixture",
         ctx do
      dispatch = dispatch!(ctx)

      refused =
        for path <- Path.wildcard(Path.join([@fixtures, "invalid", "machine-log-*.json"])) do
          name = Path.relative_to(path, @fixtures)
          body = fixture_body(name)

          assert {:error, _} =
                   JSV.validate(body, validator("provisioner/v1/machine-log.schema.json"))

          assert refused?(upload(ctx, dispatch, body), 400, "invalid_request"), name
          name
        end

      assert Enum.sort(refused) == [
               "invalid/machine-log-log-nul.json",
               "invalid/machine-log-undefined-member.json",
               "invalid/machine-log-version-2.json",
               "invalid/machine-log-without-log.json"
             ]

      time = now_time()

      for raw <- [
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
      assert refusal(conn, 413) == %{"error" => "payload_too_large"}
      assert record(over) == nil
    end

    test "under a bad signature is 401, unsigned", ctx do
      dispatch = dispatch!(ctx)
      conn = upload(ctx, dispatch, body(), seed: :crypto.strong_rand_bytes(32))
      assert refusal(conn, 401) == %{"error" => "unauthorized"}
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
      assert refusal(conn, 401) == %{"error" => "unauthorized"}
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
