defmodule Apiary.Adapters.CallsTest do
  # Qory Apiary's calls to an adapter (`Apiary.Adapters.Calls.call/4`) against a stub
  # adapter (`Req.Test`): each call signed for the adapter and its instance, sent to the
  # pinned address with the adapter's host kept; only an answer signed under the
  # adapter's access key and bound to that call counts; one retry, built anew, for a call
  # that reached no one, timed out or met an unsigned 502, 503 or 504; no redirect
  # followed; an answer over the limit refused; and a log line without a body.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import ExUnit.CaptureLog
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Adapters.{CallFailure, Calls}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.{FetchStub, SigningKey}
  alias Apiary.Integrations.Fetch.Address

  @moduletag needs: :factory
  # Each failure logs a line; the log test reads it, the others leave it out of the output.
  @moduletag :capture_log

  # Short times, so a test of a timeout or a retry takes milliseconds.
  @fast [attempt: 200, total: 2_000, retry_wait: {1, 2}]

  setup do
    %{adapter: adapter, pair: pair} = connectable_adapter_fixture()
    host = adapter.name <> ".localhost"

    adapter = %{
      adapter
      | call_url: "https://#{host}/calls/",
        call_instance_id: "instance-1"
    }

    %{adapter: adapter, host: host, seed: pair.secret}
  end

  defp stub(fun), do: Req.Test.stub(Calls, fun)

  # The adapter's answer with `status` and `body` to the call `conn` carries, signed under
  # `seed` and bound to that call.
  defp answer(conn, status, body, seed) do
    conn
    |> Plug.Conn.put_resp_header("x-qory-signature-ed25519", signed(conn, status, body, seed))
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end

  defp signed(conn, status, body, seed) do
    [call_signature] = Plug.Conn.get_req_header(conn, "x-qory-signature-ed25519")
    message = SignedMessage.call_answer(status, call_signature, body)
    Ed25519.encode(:crypto.sign(:eddsa, :none, message, [seed, :ed25519]))
  end

  # The answer signed for `signed_status`, sent with `status`.
  defp answer_as(conn, status, signed_status, body, seed) do
    conn
    |> Plug.Conn.put_resp_header(
      "x-qory-signature-ed25519",
      signed(conn, signed_status, body, seed)
    )
    |> Plug.Conn.send_resp(status, body)
  end

  # Tells the test of each call the stub receives: its headers and its raw body.
  defp tell(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    # The stub runs in the attempt's task, whose first caller is the test.
    send(hd(Process.get(:"$callers")), {:call, conn, body})
    {conn, body}
  end

  defp calls do
    receive do
      {:call, conn, body} -> [{conn, body} | calls()]
    after
      0 -> []
    end
  end

  @ok ~s({"version":1,"revision":1,"results":[]})

  defp resolve(adapter, opts \\ []),
    do: Calls.call(adapter, "resolve", [{"addresses", ["https://a.example/x"]}], opts)

  test "a call is signed for the adapter and its instance, sent to the pinned address, and its signed answer is read",
       %{adapter: adapter, host: host, seed: seed} do
    stub(fn conn ->
      {conn, _body} = tell(conn)
      answer(conn, 200, @ok, seed)
    end)

    assert resolve(adapter) == {:ok, %{"version" => 1, "revision" => 1, "results" => []}}
    assert [{conn, body}] = calls()

    assert conn.method == "POST"
    assert conn.request_path == "/calls/resolve"
    assert conn.host == Address.ntoa(FetchStub.public())
    assert Plug.Conn.get_req_header(conn, "host") == [host]
    assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
    assert Plug.Conn.get_req_header(conn, "x-qory-adapter-id") == [adapter.public_id]
    assert Plug.Conn.get_req_header(conn, "x-qory-instance-id") == ["instance-1"]
    assert Plug.Conn.get_req_header(conn, "x-qory-contract-version") == ["1"]

    assert %{"version" => 1, "time" => time, "addresses" => ["https://a.example/x"]} =
             Jason.decode!(body)

    assert body =~ ~r/\A\{"version":1,"time":"[^"]+","addresses":/
    assert {:ok, _time, 0} = DateTime.from_iso8601(time)

    [encoded] = Plug.Conn.get_req_header(conn, "x-qory-signature-ed25519")
    {:ok, signature} = Ed25519.decode(encoded, 64)
    message = SignedMessage.call(adapter.public_id, "instance-1", "POST", "resolve", body)
    assert Ed25519.verify(message, signature, SigningKey.public_key())
  end

  test "an answer that is unsigned, signed under another key or for another call, or outside the contract is :invalid_answer, not tried again",
       %{adapter: adapter, seed: seed} do
    other_seed = :crypto.strong_rand_bytes(32)

    for {name, plug} <- [
          {"unsigned", fn conn -> Plug.Conn.send_resp(conn, 200, @ok) end},
          {"another key", &answer(&1, 200, @ok, other_seed)},
          {"another call",
           fn conn ->
             conn
             |> Map.update!(:req_headers, fn headers ->
               List.keystore(headers, "x-qory-signature-ed25519", 0, {
                 "x-qory-signature-ed25519",
                 Ed25519.encode(:binary.copy(<<1>>, 64))
               })
             end)
             |> answer(200, @ok, seed)
           end},
          {"another status", &answer_as(&1, 200, 201, @ok, seed)},
          {"revision 2", &answer(&1, 200, ~s({"version":1,"revision":2,"results":[]}), seed)},
          {"version 2", &answer(&1, 200, ~s({"version":2,"revision":1,"results":[]}), seed)},
          {"not JSON", &answer(&1, 200, "results", seed)},
          {"a repeated member",
           &answer(&1, 200, ~s({"version":1,"revision":1,"revision":1}), seed)},
          {"a refusal without a code", &answer(&1, 409, ~s({"error":"Grant unknown"}), seed)},
          {"a refusal with more", &answer(&1, 409, ~s({"error":"grant_unknown","x":1}), seed)},
          {"two signatures",
           fn conn ->
             signature = signed(conn, 200, @ok, seed)

             conn
             |> Plug.Conn.prepend_resp_headers([
               {"x-qory-signature-ed25519", signature},
               {"x-qory-signature-ed25519", signature}
             ])
             |> Plug.Conn.send_resp(200, @ok)
           end}
        ] do
      stub(fn conn ->
        {conn, _body} = tell(conn)
        plug.(conn)
      end)

      assert {:error, %CallFailure{cause: :invalid_answer}} = resolve(adapter, @fast), name
      assert length(calls()) == 1, name
    end
  end

  test "a signed refusal is :refused with its code and status, and an unsigned 401 too, neither tried again",
       %{adapter: adapter, seed: seed} do
    for {plug, code, status} <- [
          {&answer(&1, 409, ~s({"error":"grant_unknown"}), &2), "grant_unknown", 409},
          {&answer(&1, 400, ~s({"error":"invalid_request"}), &2), "invalid_request", 400},
          {&answer(&1, 503, ~s({"error":"source_unavailable"}), &2), "source_unavailable", 503},
          {fn conn, _seed -> Plug.Conn.send_resp(conn, 401, ~s({"error":"unauthorized"})) end,
           "unauthorized", 401}
        ] do
      stub(fn conn ->
        {conn, _body} = tell(conn)
        plug.(conn, seed)
      end)

      assert {:error,
              %CallFailure{
                cause: :refused,
                code: ^code,
                status: ^status,
                adapter_id: id,
                adapter_public_id: public_id,
                adapter_name: name,
                path: "resolve"
              }} = resolve(adapter, @fast)

      assert {id, public_id, name} == {adapter.id, adapter.public_id, adapter.name}
      assert length(calls()) == 1, code
    end
  end

  test "an unsigned 502, 503 or 504 is tried once more, built anew with a later time and signed again",
       %{adapter: adapter, seed: seed} do
    for status <- [502, 503, 504] do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      stub(fn conn ->
        {conn, _body} = tell(conn)

        case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
          0 -> Plug.Conn.send_resp(conn, status, "busy")
          _second -> answer(conn, 200, @ok, seed)
        end
      end)

      assert {:ok, _body} = resolve(adapter, @fast)
      assert [{first, first_body}, {second, second_body}] = calls()

      assert DateTime.compare(time(second_body), time(first_body)) == :gt

      refute Plug.Conn.get_req_header(first, "x-qory-signature-ed25519") ==
               Plug.Conn.get_req_header(second, "x-qory-signature-ed25519")
    end
  end

  defp time(body) do
    {:ok, time, 0} = DateTime.from_iso8601(Jason.decode!(body)["time"])
    time
  end

  test "an unsigned 502 twice is :unreachable after the one retry", %{adapter: adapter} do
    stub(fn conn ->
      {conn, _body} = tell(conn)
      Plug.Conn.send_resp(conn, 502, "")
    end)

    assert {:error, %CallFailure{cause: :unreachable, status: 502}} = resolve(adapter, @fast)
    assert length(calls()) == 2
  end

  test "a call that reaches no one, or has no answer in the attempt's time, is tried once more",
       %{adapter: adapter} do
    stub(fn conn ->
      {conn, _body} = tell(conn)
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error, %CallFailure{cause: :unreachable}} = resolve(adapter, @fast)
    assert length(calls()) == 2

    stub(fn conn ->
      {conn, _body} = tell(conn)
      Process.sleep(1_000)
      Plug.Conn.send_resp(conn, 200, @ok)
    end)

    started = System.monotonic_time(:millisecond)
    assert {:error, %CallFailure{cause: :timeout}} = resolve(adapter, @fast)
    assert System.monotonic_time(:millisecond) - started < 1_000
    assert length(calls()) == 2
  end

  test "no attempt starts after the call's time: a retry that would not fit is not made",
       %{adapter: adapter} do
    stub(fn conn ->
      {conn, _body} = tell(conn)
      Process.sleep(1_000)
      Plug.Conn.send_resp(conn, 200, @ok)
    end)

    assert {:error, %CallFailure{cause: :timeout}} =
             resolve(adapter, attempt: 200, total: 250, retry_wait: {100, 100})

    assert length(calls()) == 1
  end

  test "a signed 429 is tried again after its Retry-After only when that ends within the call's time",
       %{adapter: adapter, seed: seed} do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    stub(fn conn ->
      {conn, _body} = tell(conn)

      case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
        0 ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> answer(429, ~s({"error":"rate_limited"}), seed)

        _second ->
          answer(conn, 200, @ok, seed)
      end
    end)

    assert {:ok, _body} = resolve(adapter, @fast)
    assert length(calls()) == 2

    stub(fn conn ->
      {conn, _body} = tell(conn)

      conn
      |> Plug.Conn.put_resp_header("retry-after", "60")
      |> answer(429, ~s({"error":"rate_limited"}), seed)
    end)

    assert {:error, %CallFailure{cause: :refused, code: "rate_limited", status: 429}} =
             resolve(adapter, @fast)

    assert length(calls()) == 1

    # An unsigned 429 is no 429: its Retry-After counts for nothing.
    stub(fn conn ->
      {conn, _body} = tell(conn)

      conn
      |> Plug.Conn.put_resp_header("retry-after", "0")
      |> Plug.Conn.send_resp(429, ~s({"error":"rate_limited"}))
    end)

    assert {:error, %CallFailure{cause: :invalid_answer, status: 429}} = resolve(adapter, @fast)
    assert length(calls()) == 1
  end

  test "a redirect is not followed", %{adapter: adapter} do
    stub(fn conn ->
      {conn, _body} = tell(conn)

      conn
      |> Plug.Conn.put_resp_header("location", "https://elsewhere.example/")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, %CallFailure{cause: :invalid_answer, status: 302}} = resolve(adapter, @fast)
    assert length(calls()) == 1
  end

  test "an answer over the limit is :invalid_answer", %{adapter: adapter, seed: seed} do
    big = ~s({"version":1,"revision":1,"results":[],"x":") <> String.duplicate("a", 200) <> ~s("})

    stub(fn conn ->
      {conn, _body} = tell(conn)
      answer(conn, 200, big, seed)
    end)

    assert {:error, %CallFailure{cause: :invalid_answer}} =
             resolve(adapter, Keyword.put(@fast, :max_answer, 100))

    assert length(calls()) == 1
  end

  test "a call over the limit is :too_large, and not sent", %{adapter: adapter} do
    stub(fn conn -> flunk("sent #{conn.request_path}") end)

    assert {:error, %CallFailure{cause: :too_large}} =
             Calls.call(adapter, "resolve", [{"addresses", [String.duplicate("a", 300)]}],
               max_call: 200
             )
  end

  test "an adapter with no call_url, or one Qory Apiary does not call, is not called",
       %{adapter: adapter} do
    stub(fn conn -> flunk("sent #{conn.request_path}") end)

    assert {:error, %CallFailure{cause: :no_address}} =
             resolve(%{adapter | call_url: nil, call_instance_id: nil})

    assert {:error, %CallFailure{cause: :not_allowed}} =
             resolve(%{adapter | call_url: "https://elsewhere.localhost/calls/"})

    assert {:error, %CallFailure{cause: :not_allowed}} =
             resolve(adapter, resolver: fn _host -> {:ok, [{127, 0, 0, 1}]} end)

    assert {:error, %CallFailure{cause: :not_allowed}} =
             resolve(adapter, resolver: fn _host -> {:ok, [{169, 254, 169, 254}]} end)

    assert {:error, %CallFailure{cause: :unreachable}} =
             resolve(adapter, resolver: fn _host -> {:error, :nxdomain} end)
  end

  test "a failure leaves one log line, with the adapter, the path and the cause, never a body or a signature",
       %{adapter: adapter} do
    stub(fn conn ->
      {conn, _body} = tell(conn)
      Plug.Conn.send_resp(conn, 400, ~s({"error":"invalid_request","secret":"s3cr3t"}))
    end)

    log =
      capture_log(fn ->
        assert {:error, %CallFailure{cause: :invalid_answer}} = resolve(adapter, @fast)
      end)

    assert [{conn, body}] = calls()
    [signature] = Plug.Conn.get_req_header(conn, "x-qory-signature-ed25519")

    assert log =~ "a call to an adapter failed adapter=#{adapter.public_id} path=resolve"
    assert log =~ "cause=invalid_answer"
    refute log =~ "s3cr3t"
    refute log =~ "https://a.example/x"
    refute log =~ body
    refute log =~ signature
    refute log =~ "instance-1"
  end

  describe "record_failure/3" do
    setup %{adapter: adapter} do
      %{scope: scope} = sign_up_fixture()
      work_item = work_item_fixture(scope)
      %{dispatch_run: run} = explore_run_fixture(work_item, end_cause: :inputs_invalid)

      failure = %CallFailure{
        adapter_id: adapter.id,
        adapter_public_id: adapter.public_id,
        adapter_name: adapter.name,
        path: "resolve",
        cause: :refused,
        code: "grant_unknown",
        status: 409
      }

      %{run: run, failure: failure}
    end

    defp reload(run), do: Repo.get!(DispatchRun, run.id)

    test "writes the adapter, the cause, the call and the refusal's code on the run",
         %{adapter: adapter, run: run, failure: failure} do
      assert Calls.record_failure(Repo, run, failure) == :ok

      assert %DispatchRun{
               adapter_failure_id: id,
               adapter_failure: :refused,
               adapter_failure_call: "resolve",
               adapter_failure_code: "grant_unknown"
             } = reload(run)

      assert id == adapter.id

      # A cause other than :refused keeps no code, whatever the failure has.
      assert Calls.record_failure(Repo, run, %{failure | cause: :timeout, path: "read"}) == :ok

      assert %DispatchRun{
               adapter_failure: :timeout,
               adapter_failure_call: "read",
               adapter_failure_code: nil
             } = reload(run)
    end

    test "a call no run makes, or a run that is gone, writes nothing",
         %{run: run, failure: failure} do
      assert_raise FunctionClauseError, fn ->
        Calls.record_failure(Repo, run, %{failure | path: "other"})
      end

      assert Calls.record_failure(Repo, %{run | id: Ecto.UUID.generate()}, failure) ==
               {:error, :not_found}

      assert reload(run).adapter_failure == nil
    end

    test "the database holds the adapter, the cause and the call together, or none",
         %{adapter: adapter, run: run} do
      at = from(d in DispatchRun, where: d.id == ^run.id)
      set = &Repo.update_all(at, set: &1)

      for cause <- CallFailure.causes(), call <- Calls.paths() do
        assert {1, _} =
                 set.(
                   adapter_failure_id: adapter.id,
                   adapter_failure: cause,
                   adapter_failure_call: call,
                   adapter_failure_code: nil
                 )
      end

      for fields <- [
            [adapter_failure_id: adapter.id],
            [adapter_failure: :timeout],
            [adapter_failure_call: "resolve"],
            [adapter_failure_code: "grant_unknown"],
            [adapter_failure_id: adapter.id, adapter_failure: :timeout],
            [adapter_failure_id: adapter.id, adapter_failure_call: "resolve"],
            [
              adapter_failure_id: adapter.id,
              adapter_failure: :timeout,
              adapter_failure_call: "other"
            ],
            [
              adapter_failure_id: adapter.id,
              adapter_failure: :timeout,
              adapter_failure_call: "resolve",
              adapter_failure_code: "grant_unknown"
            ],
            [
              adapter_failure_id: adapter.id,
              adapter_failure: :refused,
              adapter_failure_call: "resolve",
              adapter_failure_code: "Grant unknown"
            ]
          ] do
        nulls = [
          adapter_failure_id: nil,
          adapter_failure: nil,
          adapter_failure_call: nil,
          adapter_failure_code: nil
        ]

        assert_raise Postgrex.Error, ~r/dispatch_runs_adapter_failure_check/, fn ->
          set.(Keyword.merge(nulls, fields))
        end
      end

      assert {1, _} =
               set.(
                 adapter_failure_id: adapter.id,
                 adapter_failure: :refused,
                 adapter_failure_call: "read",
                 adapter_failure_code: "grant_unknown"
               )
    end
  end
end
