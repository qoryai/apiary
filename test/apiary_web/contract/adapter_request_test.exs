defmodule ApiaryWeb.Contract.AdapterRequestTest do
  # An adapter's signed declaration, `POST /v1/adapter`, through
  # `ApiaryWeb.Contract.AdapterRequest`: the signature under the adapter's key, its time's
  # window, the replay rule, the refusals in their order, the body read strictly, and the
  # key's use recorded once a request is accepted, a POST included, as a node's key's is
  # not.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import ExUnit.CaptureLog
  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1, unsigned_answer?: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Adapters, Repo}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Adapters.Feed
  alias Apiary.Audit.Entry
  alias Apiary.Nodes.Node
  alias ApiaryWeb.Contract.{AdapterRequest, SignedRequest}

  @moduletag needs: :factory

  @target "/v1/adapter"
  @unauthorized %{"error" => "unauthorized"}
  @invalid %{"error" => "invalid_request"}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{adapter: adapter, access_key: key, pair: pair} = connectable_adapter_fixture()
    %{scope: scope, adapter: adapter, key: key, seed: pair.secret, admin: instance_admin_scope()}
  end

  defp body(attrs \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "time" => now_time(),
        "connect_url" => "https://tracker-adapter.acme.example/connect",
        "sync" => %{
          "default_interval" => 900,
          "minimum_interval" => 300,
          "sends_changes" => false
        }
      },
      attrs
    )
  end

  defp now_time(offset \\ 0) do
    (SignedRequest.now() + offset)
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end

  defp declare(ctx, body, opts \\ []) do
    defaults = [target: @target, content_type: "application/json", delivery: nil]

    signed_post(
      build_conn(),
      Keyword.get(opts, :key_id, ctx.key.key_id),
      Keyword.get(opts, :seed, ctx.seed),
      body,
      Keyword.merge(defaults, opts)
    )
  end

  defp reload(node), do: Repo.get!(Node, node.id)
  defp used_at(key), do: Repo.get!(AccessKey, key.id).last_used_at
  defp seen_count, do: Repo.aggregate("adapter_seen_requests", :count)

  describe "a valid declaration" do
    test "is stored and answered 204, signed, with no body; the key's use is recorded", ctx do
      assert used_at(ctx.key) == nil

      conn = declare(ctx, body())
      assert conn.status == 204
      assert conn.resp_body == ""
      assert signed_answer?(conn)

      assert %Node{
               connect_url: "https://tracker-adapter.acme.example/connect",
               sync_default_interval: 900,
               sync_minimum_interval: 300,
               sync_sends_changes: false
             } = reload(ctx.adapter)

      assert %DateTime{} = used_at(ctx.key)
      assert Adapters.last_seen(ctx.admin, ctx.adapter) == {:ok, used_at(ctx.key)}
      assert Enum.map(Feed.entries(ctx.adapter), & &1.kind) == ["sync"]
    end

    test "accepts a time up to 300 seconds from the clock, either way", ctx do
      for offset <- [-299, 299] do
        assert declare(ctx, body(%{"time" => now_time(offset)})).status == 204, "#{offset}"
      end
    end

    test "takes the media type whatever its case and parameters", ctx do
      conn = declare(ctx, body(), content_type: "Application/JSON; charset=utf-8")
      assert conn.status == 204
    end
  end

  describe "the signature and the key" do
    test "a bad, missing or malformed signature is the same unsigned 401, and records nothing",
         ctx do
      raw = Jason.encode!(body())

      other =
        Apiary.ContractFixtures.sign_request(ctx.seed, ctx.key.key_id, nil, "POST", @target, raw)

      tampered =
        Apiary.ContractFixtures.sign_request(
          ctx.seed,
          ctx.key.key_id,
          Apiary.ContractFixtures.instance_id(),
          "POST",
          @target,
          raw <> " "
        )

      for signature <- [other, tampered, "", "not-a-signature", String.duplicate("A", 86)] do
        conn = declare(ctx, raw, signature: signature)
        assert json_response(conn, 401) == @unauthorized, inspect(signature)
        assert unsigned_answer?(conn)
      end

      # A body other than the one signed.
      good =
        Apiary.ContractFixtures.sign_request(
          ctx.seed,
          ctx.key.key_id,
          Apiary.ContractFixtures.instance_id(),
          "POST",
          @target,
          raw
        )

      conn = declare(ctx, Jason.encode!(body(%{"version" => 1})) <> "\n", signature: good)
      assert json_response(conn, 401) == @unauthorized

      assert used_at(ctx.key) == nil
      assert reload(ctx.adapter).sync_default_interval == nil
      assert seen_count() == 0
    end

    test "a key of another kind, an unknown key or a revoked key is refused 401", ctx do
      node = node_fixture(ctx.scope)
      %{access_key: node_key, pair: node_pair} = enrolled_key_fixture(ctx.scope, node)

      conn = declare(ctx, body(), key_id: node_key.key_id, seed: node_pair.secret)
      assert json_response(conn, 401) == @unauthorized
      assert Repo.get!(AccessKey, node_key.id).last_used_at == nil

      conn = declare(ctx, body(), key_id: "ak_0000000000000000")
      assert json_response(conn, 401) == @unauthorized

      conn = declare(ctx, body(), key_id: "not-a-key-id")
      assert json_response(conn, 401) == @unauthorized

      {:ok, _} = Adapters.revoke_key(ctx.admin, ctx.key)
      conn = declare(ctx, body())
      assert json_response(conn, 401) == @unauthorized
      assert reload(ctx.adapter).sync_default_interval == nil
    end

    test "an adapter's key is refused at a node's endpoint, and a node's POST records no use there",
         ctx do
      conn =
        signed_post(build_conn(), ctx.key.key_id, ctx.seed, %{"version" => 1},
          target: "/v1/runs",
          content_type: "application/json",
          delivery: nil
        )

      assert json_response(conn, 401) == @unauthorized
      assert used_at(ctx.key) == nil
    end

    test "a node's key: its verified POST records no use in the plug",
         ctx do
      node = node_fixture(ctx.scope)
      %{access_key: node_key, pair: node_pair} = enrolled_key_fixture(ctx.scope, node)
      raw = ~s({"version":1})
      instance_id = Apiary.ContractFixtures.instance_id()

      conn =
        build_conn(:post, "/v1/runs", raw)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-qory-access-key-id", node_key.key_id)
        |> Plug.Conn.put_req_header("x-qory-instance-id", instance_id)
        |> Plug.Conn.put_req_header("x-qory-contract-version", "1")
        |> Plug.Conn.put_req_header(
          "x-qory-signature-ed25519",
          Apiary.ContractFixtures.sign_request(
            node_pair.secret,
            node_key.key_id,
            instance_id,
            "POST",
            "/v1/runs",
            raw
          )
        )
        |> Plug.Conn.assign(:raw_body, raw)
        |> SignedRequest.call(SignedRequest.init(content_type: "application/json"))

      refute conn.halted
      assert conn.assigns.access_key.id == node_key.id
      assert Repo.get!(AccessKey, node_key.id).last_used_at == nil
    end
  end

  describe "freshness and replay" do
    test "a time more than 300 seconds from the clock, stale or in the future, is 401 and stores nothing",
         ctx do
      for offset <- [-301, 301, -86_400, 86_400] do
        conn = declare(ctx, body(%{"time" => now_time(offset)}))
        assert json_response(conn, 401) == @unauthorized, "#{offset}"
        assert unsigned_answer?(conn)
      end

      assert reload(ctx.adapter).sync_default_interval == nil
      assert used_at(ctx.key) == nil
      assert seen_count() == 0
    end

    test "the same request sent again is a replay, 401, and changes nothing", ctx do
      raw = Jason.encode!(body())
      assert declare(ctx, raw).status == 204
      used = used_at(ctx.key)
      entries = Repo.aggregate(Entry, :count)

      conn = declare(ctx, raw)
      assert json_response(conn, 401) == @unauthorized
      assert unsigned_answer?(conn)
      assert used_at(ctx.key) == used
      assert Repo.aggregate(Entry, :count) == entries

      # Built anew, with a later time, it is a new request.
      assert declare(ctx, body(%{"time" => now_time(1)})).status == 204
    end

    test "a replay is keyed on the key: the same bytes signed by another adapter's key are not",
         ctx do
      %{access_key: other_key, pair: other_pair} = connectable_adapter_fixture()
      raw = Jason.encode!(body())
      assert declare(ctx, raw).status == 204

      assert declare(ctx, raw, key_id: other_key.key_id, seed: other_pair.secret).status == 204
    end
  end

  describe "the body" do
    test "each field the contract refuses is 400 invalid_request, signed, and records nothing",
         ctx do
      sync = body()["sync"]

      bodies = [
        Map.put(body(), "version", 2),
        Map.delete(body(), "version"),
        Map.put(body(), "time", "2026-10-15T12:00:00.5Z"),
        Map.put(body(), "time", nil),
        Map.put(body(), "connect_url", "http://tracker-adapter.acme.example/connect"),
        Map.put(body(), "connect_url", "https://user@tracker-adapter.acme.example/connect"),
        Map.put(body(), "connect_url", String.duplicate("a", 10)),
        Map.put(body(), "sync", Map.put(sync, "default_interval", 59)),
        Map.put(body(), "sync", Map.put(sync, "default_interval", 86_401)),
        Map.put(body(), "sync", Map.put(sync, "minimum_interval", 901)),
        Map.put(body(), "sync", Map.put(sync, "minimum_interval", "300")),
        Map.put(body(), "sync", Map.delete(sync, "sends_changes")),
        Map.put(body(), "sync", Map.put(sync, "sends_changes", "false")),
        Map.put(body(), "sync", Map.put(sync, "pulls", true)),
        Map.put(body(), "name", "Acme")
      ]

      for body <- bodies do
        conn = declare(ctx, body)
        assert json_response(conn, 400) == @invalid, inspect(body)
        assert signed_answer?(conn)
      end

      raw = Jason.encode!(body())

      for broken <- [
            String.replace(raw, ~s("default_interval":900), ~s("default_interval":900.0)),
            String.replace(raw, ~s("version":1), ~s("version":1,"version":1)),
            "[]",
            "not json",
            ""
          ] do
        assert json_response(declare(ctx, broken), 400) == @invalid, broken
      end

      assert reload(ctx.adapter).sync_default_interval == nil
      assert used_at(ctx.key) == nil
      assert seen_count() == 0
    end
  end

  describe "the refusals before the body" do
    test "a POST that is not application/json is 415, unsigned", ctx do
      for type <- ["text/plain", "application/cloudevents-batch+json", "json"] do
        conn = declare(ctx, body(), content_type: type)
        assert json_response(conn, 415) == %{"error" => "unsupported_media_type"}
        assert unsigned_answer?(conn)
      end
    end

    test "a signing header sent twice, or an instance id absent or malformed, is 400 bad_request",
         ctx do
      conn = declare(ctx, body(), headers: [{"x-qory-access-key-id", ctx.key.key_id}])
      assert json_response(conn, 400) == %{"error" => "bad_request"}

      for instance_id <- [nil, "-starts-with-a-dash", String.duplicate("a", 65)] do
        conn = declare(ctx, body(), instance_id: instance_id)
        assert json_response(conn, 400) == %{"error" => "bad_request"}, inspect(instance_id)
        assert signed_answer?(conn)
      end
    end

    test "a contract revision absent, malformed or not served is 400 unsupported_contract_version",
         ctx do
      for version <- [nil, "2", "01", "1.0", "one"] do
        conn = declare(ctx, body(), contract_version: version)

        assert json_response(conn, 400) == %{"error" => "unsupported_contract_version"},
               inspect(version)

        assert signed_answer?(conn)
      end

      assert AdapterRequest.revisions() == [1]
    end

    test "a body over 1 MiB is 413 before anything else", ctx do
      conn = declare(ctx, String.duplicate(" ", 1024 * 1024 + 1))
      assert json_response(conn, 413) == %{"error" => "payload_too_large"}
    end
  end

  test "a deleted adapter's key is refused: its keys are revoked with it", ctx do
    {:ok, _} = Adapters.delete_adapter(ctx.admin, ctx.adapter)
    assert json_response(declare(ctx, body()), 401) == @unauthorized
  end

  test "an endpoint that answers 2xx to a POST without accept/2 is answered 500", ctx do
    raw = Jason.encode!(body())

    conn =
      build_conn(:post, @target, raw)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-qory-access-key-id", ctx.key.key_id)
      |> Plug.Conn.put_req_header("x-qory-instance-id", Apiary.ContractFixtures.instance_id())
      |> Plug.Conn.put_req_header("x-qory-contract-version", "1")
      |> Plug.Conn.put_req_header(
        "x-qory-signature-ed25519",
        Apiary.ContractFixtures.sign_request(
          ctx.seed,
          ctx.key.key_id,
          Apiary.ContractFixtures.instance_id(),
          "POST",
          @target,
          raw
        )
      )
      |> Plug.Conn.assign(:raw_body, raw)
      |> AdapterRequest.call([])

    refute conn.halted
    assert %AccessKey{} = conn.assigns.access_key

    {conn, log} = with_log(fn -> Plug.Conn.send_resp(conn, 204, "") end)
    assert log =~ "without AdapterRequest.accept/2"
    refute log =~ ctx.key.key_id
    assert conn.status == 500
    assert Jason.decode!(conn.resp_body) == %{"error" => "internal_error"}

    # Nothing was accepted, so nothing was recorded as the key's use.
    assert used_at(ctx.key) == nil
    assert Repo.aggregate(from(s in "adapter_seen_requests"), :count) == 0
  end
end
