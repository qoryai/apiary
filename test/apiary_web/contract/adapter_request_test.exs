defmodule ApiaryWeb.Contract.AdapterRequestTest do
  # An adapter's signed requests (`ApiaryWeb.Contract.AdapterRequest`), through its
  # declaration, `POST /v1/adapter` (`ApiaryWeb.Contract.AdapterController`): verified
  # under an adapter's key alone, held to the clock and refused when seen before,
  # refused in order, and answered signed but for a 401. A GET is checked on the plug
  # itself, which no route of this piece serves yet.
  #
  # Not async: the contract's clock and the rate limit's configuration are the node's.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures, only: [signed_answer?: 1, unsigned_answer?: 1, sign_request: 6]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, IntegrationsContract, Repo}
  alias Apiary.Nodes.Node
  alias ApiaryWeb.Contract.{AdapterRequest, RawBody}

  @moduletag needs: :factory

  @instance_id "i_gYKDhIWGh4iJiouMjY6PkA"

  setup do
    %{scope: scope} = sign_up_fixture()
    adapter = adapter_fixture(scope)
    %{access_key: key, pair: pair} = enrolled_key_fixture(scope, adapter)
    now = System.os_time(:second)
    Application.put_env(:apiary, :contract_now, fn -> now end)
    on_exit(fn -> Application.delete_env(:apiary, :contract_now) end)
    %{scope: scope, adapter: adapter, key: key, seed: pair.secret, now: now}
  end

  defp time(ctx, offset \\ 0),
    do: (ctx.now + offset) |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp declaration(ctx, attrs \\ %{}) do
    %{
      "version" => 1,
      "time" => time(ctx),
      "connect_url" => "https://tracker-adapter.acme.example/connect",
      "sync" => %{"default_interval" => 900, "minimum_interval" => 300, "sends_changes" => false}
    }
    |> Map.merge(Map.new(attrs, fn {name, value} -> {to_string(name), value} end))
  end

  defp declare(ctx, body, opts \\ []) do
    {key_id, seed} = Keyword.get(opts, :as, {ctx.key.key_id, ctx.seed})
    opts = Keyword.delete(opts, :as)
    IntegrationsContract.adapter_post(build_conn(), key_id, seed, "/v1/adapter", body, opts)
  end

  defp reload(node), do: Repo.get!(Node, node.id)

  defp refusal(conn), do: Jason.decode!(conn.resp_body)

  describe "a declaration" do
    test "is stored and answered 204, signed, with no body", ctx do
      conn = declare(ctx, declaration(ctx))
      assert conn.status == 204
      assert conn.resp_body == ""
      assert signed_answer?(conn)

      assert %Node{
               connect_url: "https://tracker-adapter.acme.example/connect",
               sync_default_interval: 900,
               sync_minimum_interval: 300,
               sync_sends_changes: false
             } = reload(ctx.adapter)
    end

    test "sent again unchanged is refused 401, unsigned; built anew it is accepted", ctx do
      body = Jason.encode!(declaration(ctx))
      assert declare(ctx, body).status == 204

      conn = declare(ctx, body)
      assert conn.status == 401
      assert refusal(conn) == %{"error" => "unauthorized"}
      assert unsigned_answer?(conn)

      later = Jason.encode!(declaration(ctx, time: time(ctx, 1)))
      assert declare(ctx, later).status == 204
    end

    test "is held to 300 seconds either way of the clock", ctx do
      for offset <- [-300, 300] do
        assert declare(ctx, declaration(ctx, time: time(ctx, offset))).status == 204,
               inspect(offset)
      end

      for offset <- [-301, 301, -100_000] do
        conn = declare(ctx, declaration(ctx, time: time(ctx, offset)))
        assert conn.status == 401, inspect(offset)
        assert unsigned_answer?(conn)
      end
    end

    test "a stale one refused leaves its signature unrecorded, so it costs no replay", ctx do
      body = Jason.encode!(declaration(ctx, time: time(ctx, -301)))
      assert declare(ctx, body).status == 401
      assert Repo.aggregate("adapter_seen_requests", :count) == 0
    end

    test "a body the contract refuses is 400 invalid_request, signed, before its time is read",
         ctx do
      for body <- [
            "not json",
            "[]",
            ~s({"version":1,"version":1}),
            Jason.encode!(declaration(ctx, extra: true)),
            Jason.encode!(declaration(ctx, version: 2)),
            Jason.encode!(
              declaration(ctx, time: time(ctx, -1000), connect_url: "http://a.example")
            ),
            Jason.encode!(declaration(ctx, connect_url: "https://user@a.example.com/")),
            Jason.encode!(
              declaration(ctx,
                sync: %{
                  "default_interval" => 300,
                  "minimum_interval" => 900,
                  "sends_changes" => true
                }
              )
            )
          ] do
        conn = declare(ctx, body)
        assert conn.status == 400, body
        assert refusal(conn) == %{"error" => "invalid_request"}
        assert signed_answer?(conn)
      end

      assert reload(ctx.adapter).connect_url == nil
    end

    test "a body over 1 MiB is 413, before anything else", ctx do
      body = String.duplicate(" ", RawBody.max_bytes(:adapter) + 1)
      conn = declare(ctx, body, signature: "not a signature")
      assert conn.status == 413
    end
  end

  describe "refused before the body" do
    test "a key that is no adapter's, unknown, revoked, or of a deleted adapter: 401, unsigned",
         ctx do
      %{access_key: node_key, pair: node_pair} =
        enrolled_key_fixture(ctx.scope, node_fixture(ctx.scope))

      body = declaration(ctx)

      refused = [
        declare(ctx, body, as: {node_key.key_id, node_pair.secret}),
        declare(ctx, body, as: {"ak_0000000000000000", ctx.seed}),
        declare(ctx, body, as: {ctx.key.key_id, "not the secret"}),
        declare(ctx, body, as: {"AK_not_a_key_id", ctx.seed}),
        declare(ctx, body, signature: "AAAA"),
        declare(ctx, body, signature: nil)
      ]

      {:ok, _} = AccessKeys.revoke_access_key(ctx.scope, ctx.key)
      refused = refused ++ [declare(ctx, declaration(ctx, time: time(ctx, 1)))]

      for conn <- refused do
        assert conn.status == 401
        assert refusal(conn) == %{"error" => "unauthorized"}
        assert unsigned_answer?(conn)
      end

      assert reload(ctx.adapter).connect_url == nil
    end

    test "a deleted adapter's key is refused 401", ctx do
      {:ok, _} = Apiary.Adapters.delete_adapter(ctx.scope, ctx.adapter)
      conn = declare(ctx, declaration(ctx))
      assert conn.status == 401
      assert unsigned_answer?(conn)
    end

    test "a type other than application/json is 415, unsigned", ctx do
      for type <- ["text/plain", "application/cloudevents-batch+json", "json"] do
        conn = declare(ctx, declaration(ctx), content_type: type)
        assert conn.status == 415
        assert refusal(conn) == %{"error" => "unsupported_media_type"}
        assert unsigned_answer?(conn)
      end

      conn = declare(ctx, declaration(ctx), content_type: "Application/JSON; charset=utf-8")
      assert conn.status == 204
    end

    test "a signed header sent twice is 400 bad_request, unsigned", ctx do
      conn = declare(ctx, declaration(ctx), headers: [{"x-qory-instance-id", @instance_id}])
      assert conn.status == 400
      assert refusal(conn) == %{"error" => "bad_request"}
      assert unsigned_answer?(conn)
    end

    test "an instance id absent or of the wrong shape is 400 bad_request, signed", ctx do
      for instance_id <- [nil, "-starts-with-a-dash", String.duplicate("a", 65)] do
        conn = declare(ctx, declaration(ctx), instance_id: instance_id)
        assert conn.status == 400
        assert refusal(conn) == %{"error" => "bad_request"}
        assert signed_answer?(conn)
      end
    end

    test "a revision not served is 400 unsupported_contract_version, signed, with the code alone, before the body",
         ctx do
      for version <- [nil, "2", "0", "01", "1.0", " 1", "one"] do
        conn = declare(ctx, "not json", contract_version: version)
        assert conn.status == 400, inspect(version)
        assert conn.resp_body == ~s({"error":"unsupported_contract_version"})
        assert signed_answer?(conn)
      end

      conn =
        declare(ctx, declaration(ctx), headers: [{"x-qory-contract-version", "1"}])

      assert conn.resp_body == ~s({"error":"unsupported_contract_version"})
      assert AdapterRequest.revisions() == [1]
    end

    test "past the key's bucket, 429 rate_limited with Retry-After, signed", ctx do
      previous = Application.get_env(:apiary, AdapterRequest)
      Application.put_env(:apiary, AdapterRequest, rate: 1, burst: 1)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:apiary, AdapterRequest, previous),
          else: Application.delete_env(:apiary, AdapterRequest)
      end)

      assert declare(ctx, declaration(ctx)).status == 204
      conn = declare(ctx, declaration(ctx, time: time(ctx, 1)))
      assert conn.status == 429
      assert refusal(conn) == %{"error" => "rate_limited"}
      assert [_seconds] = get_resp_header(conn, "retry-after")
      assert signed_answer?(conn)
    end
  end

  describe "a GET" do
    defp get_conn(ctx, opts \\ []) do
      target = Keyword.get(opts, :target, "/v1/anything?after=c_1")
      timestamp = Keyword.get(opts, :timestamp, to_string(ctx.now))

      signature =
        sign_request(ctx.seed, ctx.key.key_id, @instance_id, "GET", target, timestamp || "")

      [
        {"x-qory-access-key-id", ctx.key.key_id},
        {"x-qory-instance-id", @instance_id},
        {"x-qory-contract-version", "1"},
        {"x-qory-signature-ed25519", signature},
        {"x-qory-timestamp", timestamp}
      ]
      |> Enum.reject(fn {_name, value} -> is_nil(value) end)
      |> Enum.reduce(Plug.Test.conn(:get, target), fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)
      |> AdapterRequest.call(AdapterRequest.init([]))
    end

    test "is verified, its timestamp held to the clock, and refused when seen before", ctx do
      conn = get_conn(ctx)
      refute conn.halted
      assert conn.assigns.access_key.id == ctx.key.id
      assert conn.assigns.contract_version == 1
      assert conn.assigns.instance_id == @instance_id

      again = get_conn(ctx)
      assert again.halted
      assert again.status == 401

      for timestamp <- [to_string(ctx.now - 301), to_string(ctx.now + 301), "soon", "", nil] do
        conn = get_conn(ctx, timestamp: timestamp)
        assert conn.halted, inspect(timestamp)
        assert conn.status == 401
      end

      refute get_conn(ctx, timestamp: to_string(ctx.now - 300)).halted
    end
  end

  describe "the integration contract" do
    @describetag :integrations_contract

    test "the refusals' bodies are the contract's refusal", ctx do
      schema = IntegrationsContract.schema!("refusal.schema.json")

      bodies = [
        declare(ctx, "not json").resp_body,
        declare(ctx, declaration(ctx), contract_version: "2").resp_body,
        declare(ctx, declaration(ctx), signature: nil).resp_body,
        declare(ctx, declaration(ctx), content_type: "text/plain").resp_body
      ]

      for body <- bodies do
        assert IntegrationsContract.validate(schema, Jason.decode!(body)) == :ok, body
      end
    end

    test "the contract's fixture key, held as an adapter's, declares the contract's fixture",
         ctx do
      key = IntegrationsContract.key!("access_key")
      IntegrationsContract.fixture_access_key!(ctx.scope, ctx.adapter)
      body = IntegrationsContract.file!("fixtures/adapter/adapter/acme-tracker.json")
      {:ok, time, 0} = DateTime.from_iso8601(Jason.decode!(body)["time"])
      at = DateTime.to_unix(time)
      Application.put_env(:apiary, :contract_now, fn -> at end)

      conn =
        IntegrationsContract.adapter_post(
          build_conn(),
          key.access_key_id,
          key.seed,
          "/v1/adapter",
          body,
          instance_id: key.instance_id
        )

      assert conn.status == 204
      assert signed_answer?(conn)
      assert reload(ctx.adapter).connect_url == Jason.decode!(body)["connect_url"]
    end
  end
end
