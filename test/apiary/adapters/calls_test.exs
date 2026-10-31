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

  alias Apiary.Adapters.{CallClock, CallFailure, Calls, RunCredential}
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

  test "an answer with a status outside 100 to 599 is :invalid_answer, whatever signature it has",
       %{adapter: adapter, seed: seed} do
    for status <- [600, 999] do
      stub(fn conn ->
        {conn, _body} = tell(conn)
        # A well-formed signature, over the answer as if its status were 200.
        answer_as(conn, status, 200, @ok, seed)
      end)

      assert {:error, %CallFailure{cause: :invalid_answer, status: ^status}} =
               resolve(adapter, @fast)

      assert length(calls()) == 1
    end
  end

  test "the lookup of the adapter's host counts in the call's time", %{adapter: adapter} do
    stub(fn conn -> flunk("sent #{conn.request_path}") end)

    slow = fn _host ->
      Process.sleep(1_000)
      {:ok, [FetchStub.public()]}
    end

    started = System.monotonic_time(:millisecond)

    assert {:error, %CallFailure{cause: :timeout}} =
             resolve(adapter, Keyword.merge(@fast, total: 100, resolver: slow))

    assert System.monotonic_time(:millisecond) - started < 1_000
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

  test "identical calls to one adapter take times that strictly increase, so each signature is new",
       %{adapter: adapter, seed: seed} do
    stub(fn conn ->
      {conn, _body} = tell(conn)
      answer(conn, 200, @ok, seed)
    end)

    for _call <- 1..3, do: assert({:ok, _body} = resolve(adapter))
    assert [{first, a}, {second, b}, {third, c}] = calls()

    assert DateTime.compare(time(b), time(a)) == :gt
    assert DateTime.compare(time(c), time(b)) == :gt

    signatures =
      for conn <- [first, second, third],
          do: Plug.Conn.get_req_header(conn, "x-qory-signature-ed25519")

    assert signatures |> Enum.uniq() |> length() == 3
  end

  # The clock key of a call to resolve `addresses` at the adapter `adapter_id`.
  defp clock_key(adapter_id, addresses) do
    bytes = Calls.body([{"addresses", addresses}], ~U[2026-01-01 00:00:00Z])
    CallClock.key(adapter_id, "resolve", bytes)
  end

  test "identical callers at once never take the same time" do
    key = clock_key(Ecto.UUID.generate(), ["https://a.example/x"])
    now = System.os_time(:second)

    times =
      1..40
      |> Task.async_stream(fn _caller -> CallClock.take(key, now, now + 100) end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, {:ok, time}} -> time end)

    assert Enum.sort(times) == Enum.to_list(now..(now + 39))
  end

  test "different calls to one adapter in one second share the clock's second" do
    adapter_id = Ecto.UUID.generate()
    now = System.os_time(:second)

    times =
      for n <- 1..40 do
        {:ok, time} = CallClock.take(clock_key(adapter_id, ["https://a.example/#{n}"]), now, now)
        time
      end

    assert Enum.uniq(times) == [now]

    # The same call again takes the next second, or none past the latest it may take.
    key = clock_key(adapter_id, ["https://a.example/1"])
    assert CallClock.take(key, now, now) == :late
    assert CallClock.take(key, now, now + 1) == {:ok, now + 1}
  end

  test "different calls sent in one second carry the same time", %{adapter: adapter, seed: seed} do
    stub(fn conn ->
      {conn, _body} = tell(conn)
      answer(conn, 200, @ok, seed)
    end)

    # Within one second of the clock, two different calls carry that second; the test
    # tries again when the clock's second changed between them. Each try calls other
    # addresses: a call identical to one an earlier try sent in this second would take
    # the next second (`CallClock.take/3`).
    sent =
      Enum.find_value(1..5, fn attempt ->
        before = System.os_time(:second)
        a = "https://a.example/#{attempt}-1"
        b = "https://a.example/#{attempt}-2"
        assert {:ok, _} = Calls.call(adapter, "resolve", [{"addresses", [a]}])
        assert {:ok, _} = Calls.call(adapter, "resolve", [{"addresses", [b]}])
        sent = calls()
        if System.os_time(:second) == before, do: {before, sent}
      end)

    assert {second, [{_first, a}, {_second, b}]} = sent
    assert time(a) == DateTime.from_unix!(second)
    assert time(b) == DateTime.from_unix!(second)
  end

  test "a time more than 60 seconds ahead of the clock waits; past the call's time it fails :timeout unsent",
       %{adapter: adapter, seed: seed} do
    stub(fn conn ->
      {conn, _body} = tell(conn)
      answer(conn, 200, @ok, seed)
    end)

    key = clock_key(adapter.id, ["https://a.example/x"])
    ahead = System.os_time(:second) + CallClock.ahead() + 30
    {:ok, ^ahead} = CallClock.take(key, ahead, ahead)

    assert {:error, %CallFailure{cause: :timeout}} = resolve(adapter, @fast)
    assert calls() == []

    # The call took no time: the next identical call's time is the one after.
    assert CallClock.take(key, ahead, ahead + 1) == {:ok, ahead + 1}
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

    assert {:error, %CallFailure{cause: :not_allowed, refusal: :form}} =
             resolve(%{adapter | call_url: "https://elsewhere.localhost/calls/"})

    assert {:error,
            %CallFailure{cause: :not_allowed, refusal: {:address, {0, 0, 0, 0}, :unspecified}}} =
             resolve(adapter, resolver: fn _host -> {:ok, [{0, 0, 0, 0}]} end)

    assert {:error,
            %CallFailure{
              cause: :not_allowed,
              refusal: {:address, {169, 254, 169, 254}, :metadata}
            }} =
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

  test "a refused address's log line has the refusal: the form, or the address and its kind",
       %{adapter: adapter} do
    stub(fn conn -> flunk("sent #{conn.request_path}") end)

    log =
      capture_log(fn ->
        resolve(%{adapter | call_url: "https://elsewhere.localhost/calls/"})
        resolve(adapter, resolver: fn _host -> {:ok, [{169, 254, 169, 254}]} end)
      end)

    assert log =~ "path=resolve cause=not_allowed refusal=form duration_ms="

    assert log =~
             "path=resolve cause=not_allowed refusal=address ip=169.254.169.254 kind=metadata duration_ms="
  end

  describe "the typed calls" do
    @contract Path.expand("../../fixtures/integration-contract/adapter", __DIR__)

    # The contract's fixture at `path`, compact.
    defp compact(path),
      do: @contract |> Path.join(path) |> File.read!() |> Jason.decode!() |> Jason.encode!()

    # A stub that answers each call with `body`, signed, and tells the test of the call.
    defp answering(body, seed) do
      stub(fn conn ->
        {conn, _body} = tell(conn)
        answer(conn, 200, body, seed)
      end)
    end

    defp sent do
      assert [{conn, body}] = calls()
      {conn.request_path, Jason.decode!(body)}
    end

    test "run_credential/3 sends the connection, the resources, the access and the purpose, and keeps the token out of inspect",
         %{adapter: adapter, seed: seed} do
      answer = compact("run-credential-answer/write-without-expiry.json")
      answering(answer, seed)

      assert {:ok, %RunCredential{expires_at: nil, document: document} = credential} =
               Calls.run_credential(adapter, %{
                 connection_id: "ac_0123456789abcdef",
                 resources: ["C_2001"],
                 access: :write,
                 purpose: :work
               })

      assert document == Jason.decode!(answer)["credential"]
      refute inspect(credential) =~ "fixture-access-token"

      assert {"/calls/run-credential",
              %{
                "connection_id" => "ac_0123456789abcdef",
                "resources" => ["C_2001"],
                "access" => "write",
                "purpose" => "work"
              } = body} =
               sent()

      refute Map.has_key?(body, "grant_ref")
    end

    test "run_credential/3 reads expires_at; one not later than now is :invalid_answer",
         %{adapter: adapter, seed: seed} do
      later = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)

      body =
        "run-credential-answer/read.json"
        |> compact()
        |> String.replace("2026-10-15T13:00:00Z", DateTime.to_iso8601(later))

      answering(body, seed)
      request = %{grant_ref: "G_1", resources: ["R_1001"], access: "read", purpose: "harness"}
      assert {:ok, %RunCredential{expires_at: ^later}} = Calls.run_credential(adapter, request)

      answering(compact("run-credential-answer/read.json"), seed)

      assert {:error, %CallFailure{cause: :invalid_answer, status: 200, path: "run-credential"}} =
               Calls.run_credential(adapter, request)
    end

    test "resolve/3 sends the addresses and reads one result for each, in order",
         %{adapter: adapter, seed: seed} do
      answering(compact("resolve-answer/one-covered.json"), seed)
      addresses = ["https://code.example.com/acme/harness", "reader@code.example.com:acme/tools"]

      assert {:ok,
              [
                %{grant_ref: "G_1", resource_ref: "R_1001"},
                %{address: "reader@code.example.com:acme/tools", covered: false}
              ]} = Calls.resolve(adapter, addresses)

      assert {"/calls/resolve", %{"addresses" => ^addresses}} = sent()

      # The same answer to the addresses in the other order is not theirs.
      answering(compact("resolve-answer/one-covered.json"), seed)

      assert {:error, %CallFailure{cause: :invalid_answer}} =
               Calls.resolve(adapter, Enum.reverse(addresses))
    end

    test "read_document/3 sends the grant, the resource, the path and the version, and reads the document",
         %{adapter: adapter, seed: seed} do
      request = %{grant_ref: "G_1", resource_ref: "R_1001", path: "qory.yaml", at: "main"}

      answering(compact("read-answer/at-a-fixed-version.json"), seed)

      assert {:ok, %{found: true, content: "harness:\n  extends:\n    ref: v1\n"}} =
               Calls.read_document(adapter, request)

      assert {"/calls/read",
              %{
                "grant_ref" => "G_1",
                "resource_ref" => "R_1001",
                "path" => "qory.yaml",
                "at" => "main"
              }} =
               sent()

      answering(compact("read-answer/no-document.json"), seed)
      assert {:ok, %{found: false, content: nil}} = Calls.read_document(adapter, request)
    end

    test "read_public/3 sends the resource, the path and the version, with no grant, and reads the document",
         %{adapter: adapter, seed: seed} do
      request = %{resource_ref: "R_2001", path: "qory-stack.yaml", at: "main"}

      answering(compact("read-answer/at-a-fixed-version.json"), seed)

      assert {:ok, %{found: true, content: "harness:\n  extends:\n    ref: v1\n"}} =
               Calls.read_public(adapter, request)

      assert {"/calls/read-public",
              %{"resource_ref" => "R_2001", "path" => "qory-stack.yaml", "at" => "main"} = body} =
               sent()

      refute Map.has_key?(body, "grant_ref")

      assert Map.delete(body, "time") ==
               Map.delete(Jason.decode!(compact("read-public/at-a-name.json")), "time")
    end

    test "read_public/3 reads the refusal resource_not_public",
         %{adapter: adapter, seed: seed} do
      stub(fn conn ->
        {conn, _body} = tell(conn)
        answer(conn, 403, compact("refusal/resource-not-public.json"), seed)
      end)

      assert {:error,
              %CallFailure{cause: :refused, code: "resource_not_public", path: "read-public"}} =
               Calls.read_public(adapter, %{resource_ref: "R_2001", path: "qory.yaml", at: "main"})
    end

    test "resolve/3 reads a public result, with a grant and without",
         %{adapter: adapter, seed: seed} do
      answering(compact("resolve-answer/public.json"), seed)

      addresses = [
        "https://code.example.com/acme/public-stack",
        "https://code.example.com/acme/private-stack"
      ]

      assert {:ok,
              [
                %{resource_ref: "R_2001", public: true, public_ref: "example.com/team/project"} =
                  public,
                %{covered: false}
              ]} = Calls.resolve(adapter, addresses)

      refute Map.has_key?(public, :grant_ref)
    end

    test "a call outside its schema raises, without its values, and is not sent",
         %{adapter: adapter} do
      stub(fn conn -> flunk("sent #{conn.request_path}") end)

      for {fun, message} <- [
            {fn -> Calls.resolve(adapter, []) end, "a call to resolve outside its schema"},
            {fn -> Calls.resolve(adapter, ["a b"]) end, "a call to resolve outside its schema"},
            {fn ->
               Calls.read_document(adapter, %{
                 grant_ref: "G_1",
                 resource_ref: "R_1001",
                 path: "../secret",
                 at: "main"
               })
             end, "a call to read outside its schema"},
            {fn ->
               Calls.run_credential(adapter, %{
                 connection_id: "ac_0123456789abcdef",
                 resources: ["C_2001"],
                 access: :admin,
                 purpose: :work
               })
             end, "a call to run-credential outside its schema"},
            {fn ->
               Calls.run_credential(adapter, %{
                 grant_ref: "G_1",
                 resources: ["C_2001"],
                 access: :write,
                 purpose: :work
               })
             end, "a call to run-credential outside its schema"}
          ] do
        assert_raise ArgumentError, message, fun
      end
    end
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

      # A public read is a read of the harness files.
      assert Calls.record_failure(Repo, run, %{failure | path: "read-public"}) == :ok

      assert %DispatchRun{adapter_failure_call: "read", adapter_failure_code: "grant_unknown"} =
               reload(run)
    end

    test "a refused address is written as not_allowed, without its refusal",
         %{adapter: adapter, run: run, failure: failure} do
      for refusal <- [:form, :public_host, {:address, {169, 254, 169, 254}, :metadata}] do
        failure = %{failure | cause: :not_allowed, code: nil, status: nil, refusal: refusal}
        assert Calls.record_failure(Repo, run, failure) == :ok

        assert %DispatchRun{
                 adapter_failure_id: id,
                 adapter_failure: :not_allowed,
                 adapter_failure_call: "resolve",
                 adapter_failure_code: nil
               } = reload(run)

        assert id == adapter.id
      end

      assert %{rows: [["not_allowed"]]} =
               Repo.query!("SELECT adapter_failure FROM dispatch_runs WHERE id = $1", [
                 Ecto.UUID.dump!(run.id)
               ])

      # The causes the run's row takes are those its check allows
      # (`dispatch_runs_adapter_failure_check`), a refusal's reason none of them.
      assert Ecto.Enum.dump_values(DispatchRun, :adapter_failure) ==
               ~w(no_address not_allowed unreachable timeout refused invalid_answer too_large)
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
