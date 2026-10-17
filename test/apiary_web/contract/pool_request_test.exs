defmodule ApiaryWeb.Contract.PoolRequestTest do
  # A node pool's starter's signed requests to the provisioner contract's four routes,
  # through `ApiaryWeb.Contract.AdapterRequest` with `kind: :pool`: the signature under the
  # pool's access key, the refusals in their order, the time's window, the replay rule,
  # every other kind of key refused as an unknown key is, the answers signed but a 401, and
  # the routes where the feature is off. A claim accepted, with an empty queue and no
  # wait, is answered `204`, signed; the other actions are not served yet, and an accepted
  # request of one is answered `404` `not_found`, signed. Not async: the features are the
  # whole node's.
  use ApiaryWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1, unsigned_answer?: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Repo}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Runs.RateLimit
  alias ApiaryWeb.Contract.{AdapterRequest, SignedRequest}

  @moduletag needs: :factory

  @claim "/v1/pools/claim"
  @dispatch "/v1/dispatches/dp_0123456789abcdef"
  @targets [
    @claim,
    @dispatch <> "/dispatched",
    @dispatch <> "/handover",
    @dispatch <> "/release"
  ]
  @unauthorized %{"error" => "unauthorized"}
  @not_found %{"error" => "not_found"}
  @invalid %{"error" => "invalid_request"}
  @bad_request %{"error" => "bad_request"}
  @unsupported %{"error" => "unsupported_contract_version"}
  @unknown_key_id "ak_0000000000000000"

  setup do
    %{scope: scope} = sign_up_fixture()
    pool = pool_fixture(scope)
    %{access_key: key, pair: pair} = enrolled_key_fixture(scope, pool)
    %{scope: scope, pool: pool, key: key, seed: pair.secret}
  end

  defp now_time(offset \\ 0) do
    (SignedRequest.now() + offset)
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end

  # A valid body for `target`, its time `offset` seconds from the clock.
  defp body(target, offset \\ 0)

  defp body(@claim, offset),
    do: %{"version" => 1, "time" => now_time(offset), "wait_seconds" => 0}

  defp body(target, offset) do
    base = %{"version" => 1, "time" => now_time(offset)}

    if String.ends_with?(target, "/release"),
      do: Map.merge(base, %{"reason" => "The job could not start.", "retry" => true}),
      else: base
  end

  defp signed(ctx, target, body, opts \\ []) do
    defaults = [target: target, content_type: "application/json", delivery: nil]

    signed_post(
      build_conn(),
      Keyword.get(opts, :key_id, ctx.key.key_id),
      Keyword.get(opts, :seed, ctx.seed),
      body,
      Keyword.merge(defaults, opts)
    )
  end

  defp claim(ctx, body, opts \\ []), do: signed(ctx, @claim, body, opts)

  defp used_at(key), do: Repo.get!(AccessKey, key.id).last_used_at

  # An accepted request's answer: a claim of an empty queue with no wait, `204` with no
  # body; any other route's, `404` `not_found`, as its action is not built yet.
  defp accepted?(conn, @claim), do: conn.status == 204 and conn.resp_body == ""
  defp accepted?(conn, _target), do: json_response(conn, 404) == @not_found
  defp seen_count, do: Repo.aggregate("adapter_seen_requests", :count)

  # The answer as it goes out, but the headers whose value differs from one answer to the
  # next.
  defp answer(conn) do
    headers =
      conn.resp_headers
      |> Enum.reject(fn {name, _value} -> name in ["x-request-id", "content-security-policy"] end)
      |> Enum.sort()

    {conn.status, headers, conn.resp_body}
  end

  defp with_features(names) do
    previous = Application.get_env(:apiary, :features)
    {:ok, features} = Apiary.Features.parse(names)
    Application.put_env(:apiary, :features, features)
    on_exit(fn -> Application.put_env(:apiary, :features, previous) end)
  end

  describe "a verified request" do
    test "on each route is accepted: a claim of an empty queue 204, the others 404 not_found, as their actions are not built yet, signed",
         ctx do
      for target <- @targets do
        conn = signed(ctx, target, body(target))
        assert accepted?(conn, target), target
        assert signed_answer?(conn), target
      end

      # Each was accepted: its signature recorded, and the key's use.
      assert seen_count() == 4
      assert %DateTime{} = used_at(ctx.key)
    end

    test "takes the media type whatever its case and parameters", ctx do
      conn = claim(ctx, body(@claim), content_type: "Application/JSON; charset=utf-8")
      assert accepted?(conn, @claim)
    end

    test "takes a pool's key enrolled in a browser as one enrolled with a code", ctx do
      pool = pool_fixture(ctx.scope)
      %{access_key: key, pair: pair} = browser_key_fixture(ctx.scope, pool)
      conn = claim(ctx, body(@claim), key_id: key.key_id, seed: pair.secret)
      assert accepted?(conn, @claim)
    end

    test "is served the provisioner contract's revisions, 1 alone", _ctx do
      assert AdapterRequest.revisions(:pool) == [1]
      assert AdapterRequest.revisions(:adapter) == [1]
      assert AdapterRequest.revisions() == [1]
    end
  end

  describe "the time and the replay" do
    test "a time up to 300 seconds from the clock, either way, is accepted", ctx do
      for offset <- [-300, 300] do
        conn = claim(ctx, body(@claim, offset))
        assert accepted?(conn, @claim), "#{offset}"
      end
    end

    test "a time more than 300 seconds from the clock is 401, unsigned, and records nothing",
         ctx do
      for target <- @targets, offset <- [-301, 301, -86_400, 86_400] do
        conn = signed(ctx, target, body(target, offset))
        assert json_response(conn, 401) == @unauthorized, "#{target} #{offset}"
        assert unsigned_answer?(conn)
      end

      assert seen_count() == 0
      assert used_at(ctx.key) == nil
    end

    test "the same request sent again is a replay, 401, unsigned; built anew it is a new one",
         ctx do
      for target <- @targets do
        raw = Jason.encode!(body(target))
        assert accepted?(signed(ctx, target, raw), target)

        conn = signed(ctx, target, raw)
        assert json_response(conn, 401) == @unauthorized, target
        assert unsigned_answer?(conn)

        assert accepted?(signed(ctx, target, body(target, 1)), target)
      end
    end

    test "a replay is keyed on the key: the same body under another pool's key is not one",
         ctx do
      pool = pool_fixture(ctx.scope)
      %{access_key: other, pair: pair} = enrolled_key_fixture(ctx.scope, pool)
      raw = Jason.encode!(body(@claim))

      assert accepted?(claim(ctx, raw), @claim)
      assert accepted?(claim(ctx, raw, key_id: other.key_id, seed: pair.secret), @claim)
    end
  end

  describe "whose key" do
    test "an adapter's, a node's or a gateway's key, a revoked pool's key, a pool's key of an organisation out of use, or a bad signature, each answers as an unknown key does",
         ctx do
      raw = Jason.encode!(body(@claim))
      reference = ctx |> claim(raw, key_id: @unknown_key_id) |> answer()
      assert {401, _headers, body} = reference
      assert Jason.decode!(body) == @unauthorized

      %{access_key: adapter_key, pair: adapter_pair} = connectable_adapter_fixture()
      node = node_fixture(ctx.scope)
      %{access_key: node_key, pair: node_pair} = enrolled_key_fixture(ctx.scope, node)
      gateway = gateway_fixture(ctx.scope)
      %{access_key: gateway_key, pair: gateway_pair} = enrolled_key_fixture(ctx.scope, gateway)

      others = [
        adapter: [key_id: adapter_key.key_id, seed: adapter_pair.secret],
        node: [key_id: node_key.key_id, seed: node_pair.secret],
        gateway: [key_id: gateway_key.key_id, seed: gateway_pair.secret],
        malformed_key_id: [key_id: "not-a-key-id"],
        bad_signature: [signature: String.duplicate("A", 86)],
        signed_over_another_body: [
          signature:
            Apiary.ContractFixtures.sign_request(
              ctx.seed,
              ctx.key.key_id,
              Apiary.ContractFixtures.instance_id(),
              "POST",
              @claim,
              raw <> " "
            )
        ]
      ]

      for {name, opts} <- others do
        assert ctx |> claim(raw, opts) |> answer() == reference, inspect(name)
      end

      # The pool's organisation out of use, as an edition puts it.
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.OutOfUse)
      Process.put(:out_of_use, [ctx.scope.organisation.id])
      assert ctx |> claim(raw) |> answer() == reference
      Process.put(:out_of_use, [])

      {:ok, _} = AccessKeys.revoke_access_key(ctx.scope, ctx.key)
      assert ctx |> claim(raw) |> answer() == reference

      assert seen_count() == 0
      assert Repo.get!(AccessKey, node_key.id).last_used_at == nil
      assert Repo.get!(AccessKey, adapter_key.id).last_used_at == nil
      assert Repo.get!(AccessKey, gateway_key.id).last_used_at == nil
    end

    test "a pool's key on an adapter's route is refused as an unknown key is there", ctx do
      body = %{
        "version" => 1,
        "time" => now_time(),
        "connect_url" => "https://tracker-adapter.acme.example/connect",
        "sync" => %{
          "default_interval" => 900,
          "minimum_interval" => 300,
          "sends_changes" => false
        }
      }

      raw = Jason.encode!(body)
      reference = ctx |> signed("/v1/adapter", raw, key_id: @unknown_key_id) |> answer()
      assert {401, _headers, _body} = reference
      assert ctx |> signed("/v1/adapter", raw) |> answer() == reference
      assert used_at(ctx.key) == nil
    end

    test "an adapter's key on its route still verifies", _ctx do
      %{access_key: key, pair: pair} = connectable_adapter_fixture()

      conn =
        AdapterRequest.call(
          request("/v1/adapter", key.key_id, pair.secret, ~s({"version":1})),
          AdapterRequest.init([])
        )

      refute conn.halted
      assert conn.assigns.access_key.id == key.id

      # And refused where a pool's key is due.
      conn =
        AdapterRequest.call(
          request(@claim, key.key_id, pair.secret, ~s({"version":1})),
          AdapterRequest.init(kind: :pool)
        )

      assert {conn.halted, conn.status} == {true, 401}
    end
  end

  describe "the order of refusals" do
    test "413 for a body over 1 MiB comes first, before 415 and the signature", ctx do
      big = String.duplicate(" ", 1024 * 1024 + 1)

      for target <- @targets do
        conn = signed(ctx, target, big, content_type: "text/plain", key_id: @unknown_key_id)
        assert json_response(conn, 413) == %{"error" => "payload_too_large"}, target
        assert unsigned_answer?(conn)
      end
    end

    test "a body of exactly 1 MiB is read", ctx do
      raw = Jason.encode!(body(@claim))
      raw = raw <> String.duplicate(" ", 1024 * 1024 - byte_size(raw))
      assert byte_size(raw) == 1024 * 1024
      assert accepted?(claim(ctx, raw), @claim)
    end

    test "415 for a POST that is not application/json, unsigned, before a header sent twice",
         ctx do
      for type <- ["text/plain", "application/cloudevents-batch+json", "json"] do
        conn =
          claim(ctx, body(@claim),
            content_type: type,
            headers: [{"x-qory-access-key-id", ctx.key.key_id}]
          )

        assert json_response(conn, 415) == %{"error" => "unsupported_media_type"}, type
        assert unsigned_answer?(conn)
      end
    end

    test "400 bad_request for a signing header sent twice, unsigned, before the signature",
         ctx do
      for header <-
            ~w(x-qory-access-key-id x-qory-instance-id x-qory-signature-ed25519 x-qory-timestamp) do
        conn =
          claim(ctx, body(@claim),
            key_id: @unknown_key_id,
            headers: [{header, "twice"}, {header, "twice"}]
          )

        assert json_response(conn, 400) == @bad_request, header
        assert unsigned_answer?(conn)
      end
    end

    test "401 before 429: a request that does not verify is 401 whatever the bucket", ctx do
      drain(ctx.key)
      conn = claim(ctx, body(@claim), signature: String.duplicate("A", 86))
      assert json_response(conn, 401) == @unauthorized
      assert unsigned_answer?(conn)
    end

    test "429 with Retry-After, signed, before an instance id absent", ctx do
      drain(ctx.key)
      conn = claim(ctx, body(@claim), instance_id: nil)
      assert json_response(conn, 429) == %{"error" => "rate_limited"}
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) >= 1
      assert signed_answer?(conn)
    end

    test "the bucket is the pool key's, apart from an adapter's bucket of the same id", ctx do
      for _ <- 1..200, do: RateLimit.check({:adapter, ctx.key.id}, rate: 50, burst: 100)
      assert accepted?(claim(ctx, body(@claim)), @claim)
    end

    test "400 bad_request for an instance id absent or malformed, signed, before the revision",
         ctx do
      for instance_id <- [nil, "-starts-with-a-dash", String.duplicate("a", 65)] do
        conn = claim(ctx, body(@claim), instance_id: instance_id, contract_version: "2")
        assert json_response(conn, 400) == @bad_request, inspect(instance_id)
        assert signed_answer?(conn)
      end
    end

    test "400 unsupported_contract_version, signed, before the body", ctx do
      for version <- [nil, "2", "01", "1.0", "one"] do
        conn = claim(ctx, %{"version" => 2}, contract_version: version)
        assert json_response(conn, 400) == @unsupported, inspect(version)
        assert signed_answer?(conn)
      end
    end

    test "400 invalid_request, signed, before the time and the replay", ctx do
      for target <- @targets do
        stale = body(target, -86_400)

        for invalid <- [
              Map.put(stale, "unknown", true),
              Map.put(stale, "version", 2),
              "not json"
            ] do
          conn = signed(ctx, target, invalid)
          assert json_response(conn, 400) == @invalid, "#{target} #{inspect(invalid)}"
          assert signed_answer?(conn)
        end
      end

      # A body sent again that the contract refuses is refused for its body, not as a replay.
      raw = Jason.encode!(Map.put(body(@claim), "unknown", true))
      assert json_response(claim(ctx, raw), 400) == @invalid
      assert json_response(claim(ctx, raw), 400) == @invalid
      assert seen_count() == 0
    end

    test "a handover carrying labels is 400 invalid_request", ctx do
      target = @dispatch <> "/handover"
      conn = signed(ctx, target, Map.put(body(target), "labels", ["linux"]))
      assert json_response(conn, 400) == @invalid
      assert signed_answer?(conn)
    end

    test "a POST answered 2xx without accept/2 is answered 500", ctx do
      raw = Jason.encode!(body(@claim))

      conn =
        @claim
        |> request(ctx.key.key_id, ctx.seed, raw)
        |> AdapterRequest.call(AdapterRequest.init(kind: :pool))

      refute conn.halted
      assert conn.assigns.access_key.id == ctx.key.id

      {conn, log} = with_log(fn -> Plug.Conn.send_resp(conn, 204, "") end)
      assert log =~ "a node pool's POST was answered 2xx without AdapterRequest.accept/2"
      refute log =~ ctx.key.key_id
      assert conn.status == 500
      assert seen_count() == 0
    end

    test "the plug takes the kinds it knows alone" do
      assert AdapterRequest.init([]) == [kind: :adapter]
      assert AdapterRequest.init(kind: :pool) == [kind: :pool]
      assert_raise ArgumentError, fn -> AdapterRequest.init(kind: :gateway) end
    end
  end

  describe "where the feature is off" do
    # The pool and its key are made while the feature is on, then it is turned off.
    setup do
      with_features("observability,security")
      refute Apiary.Features.on?(:factory)
      :ok
    end

    test "an unsigned request answers exactly as a path the router does not know", ctx do
      for target <- @targets do
        unsigned = fn path, raw ->
          fn ->
            build_conn()
            |> put_req_header("content-type", "application/json")
            |> put_req_header("x-qory-access-key-id", ctx.key.key_id)
            |> post(path, raw)
          end
        end

        raw = Jason.encode!(body(target))

        assert sent(404, unsigned.(target, raw)) == sent(404, unsigned.("/v1/pools/unknown", raw)),
               target

        # A body that is no JSON is parsed, and refused, as on any path: the route's body
        # is not read apart from the others where it is not served.
        assert sent(400, unsigned.(target, "not json")) ==
                 sent(400, unsigned.("/v1/pools/unknown", "not json")),
               target
      end
    end

    test "a verified request is answered 404 not_found, signed, and records nothing", ctx do
      for target <- @targets do
        conn = signed(ctx, target, body(target))
        assert json_response(conn, 404) == @not_found, target
        assert signed_answer?(conn)
      end

      assert seen_count() == 0
      assert used_at(ctx.key) == nil
    end
  end

  # The answer the endpoint sends to `request`, of `status`, but the headers whose value
  # differs from one answer to the next.
  defp sent(status, request) do
    # A path the router does not know is answered without raising; a body the parsers
    # refuse raises, and is answered as the error is.
    {^status, headers, body} =
      try do
        conn = request.()
        {conn.status, conn.resp_headers, conn.resp_body}
      rescue
        _exception -> assert_error_sent(status, request)
      end

    headers =
      headers
      |> Enum.reject(fn {name, _value} -> name in ["x-request-id", "content-security-policy"] end)
      |> Enum.sort()

    {status, headers, body}
  end

  # Spends the pool key's bucket until it is empty.
  defp drain(%AccessKey{id: id}) do
    for _ <- 1..200, do: RateLimit.check({:pool, id}, rate: 50, burst: 100)
    assert {:error, _seconds} = RateLimit.check({:pool, id}, rate: 50, burst: 100)
  end

  # A request that reached the plug, signed under `seed` with its raw body kept.
  defp request(target, key_id, seed, raw) do
    instance_id = Apiary.ContractFixtures.instance_id()

    build_conn(:post, target, raw)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-qory-access-key-id", key_id)
    |> put_req_header("x-qory-instance-id", instance_id)
    |> put_req_header("x-qory-contract-version", "1")
    |> put_req_header(
      "x-qory-signature-ed25519",
      Apiary.ContractFixtures.sign_request(seed, key_id, instance_id, "POST", target, raw)
    )
    |> Plug.Conn.assign(:raw_body, raw)
  end
end
