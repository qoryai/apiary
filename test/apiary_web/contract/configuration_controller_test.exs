defmodule ApiaryWeb.Contract.ConfigurationControllerTest do
  use ApiaryWeb.ConnCase, async: true

  import Apiary.ContractFixtures, except: [signed_get: 4, signed_get: 5]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Repo, SigningKey}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.ContractFixtures
  alias ApiaryWeb.Contract.Configuration

  @path "/.well-known/qory-configuration"
  @unauthorized %{"error" => "unauthorized"}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{access_key: key, secret: secret} = contract_key_fixture(scope)
    %{scope: scope, key: key, secret: secret}
  end

  # Discovery, as the gateway fetches it unless told otherwise (`:path` for another target;
  # the rest as `Apiary.ContractFixtures.signed_get/5` reads them).
  defp signed_get(conn, key_id, secret, opts \\ []) do
    {path, opts} = Keyword.pop(opts, :path, @path)

    ContractFixtures.signed_get(
      conn,
      key_id,
      secret,
      path,
      Keyword.put_new(opts, :user_agent, "qory-forager/0.9.1")
    )
  end

  defp key!(key), do: Repo.get!(AccessKey, key.id)

  @tag needs: :security
  test "a workspace whose policy somebody made is named the run section; the digest differs",
       %{scope: scope, key: key, secret: secret} do
    unmanaged = signed_get(build_conn(), key.key_id, secret)
    {:ok, _rule} = Apiary.Policy.allow(scope, nil, %{host: "api.example"})
    managed = signed_get(build_conn(), key.key_id, secret)
    base = ApiaryWeb.Endpoint.url()

    assert json_response(managed, 200) == %{
             "version" => 1,
             "node_id" => key.node.public_id,
             "events" => %{"url" => base <> "/v1/events", "types" => ["*"]},
             "run" => %{"url" => base <> "/v1/run-configuration"},
             "apiary_public_key" => SigningKey.apiary_public_key()
           }

    [digest] = get_resp_header(managed, "x-qory-configuration")
    assert digest == ApiaryWeb.Contract.ConfigurationController.digest(managed.resp_body)
    assert digest == Configuration.digest(key.node, true)
    assert [digest] != get_resp_header(unmanaged, "x-qory-configuration")
    assert signed_answer?(managed)

    # Another workspace's policy changes nothing here.
    %{scope: other} = sign_up_fixture()
    %{access_key: other_key, secret: other_secret} = contract_key_fixture(other)

    refute Map.has_key?(
             json_response(signed_get(build_conn(), other_key.key_id, other_secret), 200),
             "run"
           )
  end

  test "a valid request gets the version 1 document, signed, with its node and digest",
       %{conn: conn, key: key, secret: secret} do
    conn = signed_get(conn, key.key_id, secret, contract_version: 1)
    base = ApiaryWeb.Endpoint.url()

    assert json_response(conn, 200) == %{
             "version" => 1,
             "node_id" => key.node.public_id,
             "events" => %{"url" => base <> "/v1/events", "types" => ["*"]},
             "apiary_public_key" => SigningKey.apiary_public_key()
           }

    # The contract's order of members.
    assert conn.resp_body =~ ~r/\A\{"version":1,"node_id":"nd_[^"]+","events":/

    # No run section until somebody has made the workspace's policy: until then its
    # machines keep the policy of their own Forager file.
    refute Map.has_key?(json_response(conn, 200), "run")

    [digest] = get_resp_header(conn, "x-qory-configuration")
    assert digest == ApiaryWeb.Contract.ConfigurationController.digest(conn.resp_body)
    assert digest == Configuration.digest(key.node, false)
    assert digest =~ ~r/^sha256=[0-9a-f]{64}$/

    assert signed_answer?(conn)
    assert get_resp_header(conn, "cache-control") == ["no-store, no-transform"]
  end

  test "each node has its own document and digest; a pool's names the pool",
       %{scope: scope, key: key, secret: secret} do
    pool = pool_fixture(scope)
    %{access_key: pool_key, secret: pool_secret} = contract_key_fixture(scope, node: pool)

    one = signed_get(build_conn(), key.key_id, secret)
    other = signed_get(build_conn(), pool_key.key_id, pool_secret)

    assert json_response(other, 200)["node_id"] == pool.public_id
    assert pool.public_id =~ ~r/\Anp_/

    assert get_resp_header(one, "x-qory-configuration") !=
             get_resp_header(other, "x-qory-configuration")
  end

  @tag :contract
  test "the document's bytes are the contract's known answer for its node, URL and key" do
    %{"apiary_public_key" => keys} = known = known_answers!("discovery")

    body =
      Configuration.encode(%{
        node_id: known["node_id"],
        url: "https://qory.example",
        apiary_public_key: keys,
        run?: false
      })

    assert body == contract_file!("known-answers/discovery.json")
  end

  test "a request with a query string signs the path and the query as received", %{
    conn: conn,
    key: key,
    secret: secret
  } do
    conn = signed_get(conn, key.key_id, secret, path: @path <> "?b=2&a=1")
    assert json_response(conn, 200)["version"] == 1

    # The same query signed without it fails.
    timestamp = to_string(System.os_time(:second))

    conn =
      signed_get(build_conn(), key.key_id, secret,
        path: @path <> "?b=2&a=1",
        timestamp: timestamp,
        signature: sign_request(secret, key.key_id, instance_id(), "GET", @path, timestamp)
      )

    assert json_response(conn, 401) == @unauthorized
  end

  test "success touches the key", %{conn: conn, key: key, secret: secret} do
    assert key!(key).last_used_at == nil
    signed_get(conn, key.key_id, secret, contract_version: 1, user_agent: "qory-forager/1.2.3")

    touched = key!(key)
    assert touched.last_used_at
    assert touched.last_forager_version == "1.2.3"
    assert touched.last_contract_version == 1

    signed_get(build_conn(), key.key_id, secret, user_agent: "curl/8.0")
    touched = key!(key)
    assert touched.last_forager_version == nil
    assert touched.last_contract_version == 1
  end

  test "the instance is recorded as seen on the key's node", %{key: key, secret: secret} do
    assert json_response(signed_get(build_conn(), key.key_id, secret), 200)

    assert [instance] = Repo.all(Apiary.Nodes.Instance)
    assert instance.node_id == key.node_id
    assert instance.instance_id == instance_id()
    assert instance.name == "build-01"
    assert instance.access_key_id == key.id
  end

  test "a key id that is not valid UTF-8 is 401, not a crash", %{conn: conn, secret: secret} do
    for key_id <- [
          "ak_" <> <<0xFF, 0xFE>> <> "00000000000000",
          <<0xC3, 0x28>>,
          "ak_0000000000000000\0",
          "ak_000000000000000",
          "AK_0000000000000000",
          "ak_000000000000000i",
          String.duplicate("a", 10_000)
        ] do
      conn = signed_get(conn, key_id, secret)
      assert json_response(conn, 401) == @unauthorized
      assert unsigned_answer?(conn)
    end
  end

  test "an over-long User-Agent succeeds and is recorded truncated", %{
    conn: conn,
    key: key,
    secret: secret
  } do
    long = "qory-forager/" <> String.duplicate("9", 5_000)

    assert %{"version" => 1} =
             conn |> signed_get(key.key_id, secret, user_agent: long) |> json_response(200)

    touched = key!(key)
    assert touched.last_used_at
    assert touched.last_forager_version == String.duplicate("9", 80)
  end

  test "a User-Agent that is not printable text succeeds and records no version", %{
    conn: conn,
    key: key,
    secret: secret
  } do
    for user_agent <- [
          "qory-forager/" <> <<0xFF, 0xFE>>,
          "qory-forager/1.0\e[31m",
          "qory-forager/1\0"
        ] do
      conn = signed_get(conn, key.key_id, secret, user_agent: user_agent)
      assert %{"version" => 1} = json_response(conn, 200)
      assert key!(key).last_forager_version == nil
    end
  end

  test "a contract version other than 1, absent or sent twice, is 400, signed, and says what is served",
       %{key: key, secret: secret} do
    for version <- [nil, [1, 1], 2, 0, -1, "one", "1.0", "", "99999999999999999999"] do
      conn = signed_get(build_conn(), key.key_id, secret, contract_version: version)

      assert json_response(conn, 400) == %{
               "error" => "unsupported_contract_version",
               "supported" => [1]
             }

      assert get_resp_header(conn, "x-qory-configuration") == []
      assert signed_answer?(conn)
      assert key!(key).last_contract_version == nil
    end

    conn = signed_get(build_conn(), key.key_id, secret, contract_version: 1)
    assert %{"version" => 1} = json_response(conn, 200)
    assert key!(key).last_contract_version == 1

    # A refused request leaves what was recorded.
    assert signed_get(build_conn(), key.key_id, secret, contract_version: 2).status == 400
    assert key!(key).last_contract_version == 1
  end

  test "a request that does not verify is 401 whatever its contract version", %{
    key: key,
    secret: secret
  } do
    for version <- [nil, 2, 1] do
      conn =
        signed_get(build_conn(), key.key_id, secret,
          contract_version: version,
          signature: String.duplicate("A", 86)
        )

      assert json_response(conn, 401) == @unauthorized
    end
  end

  test "a signature under another key is 401", %{conn: conn, key: key} do
    conn = signed_get(conn, key.key_id, "another key")
    assert json_response(conn, 401) == @unauthorized
  end

  test "a stale or malformed timestamp is 401, unsigned", %{conn: conn, key: key, secret: secret} do
    now = System.os_time(:second)

    for timestamp <- [now - 301, now + 301, "soon", "12.5", "", "+#{now}", " #{now}", nil] do
      conn = signed_get(build_conn(), key.key_id, secret, timestamp: timestamp)
      assert json_response(conn, 401) == @unauthorized
      assert unsigned_answer?(conn)
    end

    assert json_response(signed_get(conn, key.key_id, secret, timestamp: now - 299), 200)
    assert json_response(signed_get(build_conn(), key.key_id, secret, timestamp: now + 299), 200)
  end

  test "an unknown key is 401", %{conn: conn, secret: secret} do
    conn = signed_get(conn, "ak_0000000000000000", secret)
    assert json_response(conn, 401) == @unauthorized
  end

  test "a revoked key is 401 at once", %{conn: conn, key: key, secret: secret, scope: scope} do
    {:ok, _} = AccessKeys.revoke_access_key(scope, key)
    conn = signed_get(conn, key.key_id, secret)
    assert json_response(conn, 401) == @unauthorized
  end

  test "a key of an organisation deleted is 401, as a revoked one, until it is cancelled",
       %{conn: conn, key: key, secret: secret, scope: scope} do
    {:ok, _} = Apiary.Deletion.delete_organisation(scope, scope.organisation.slug)
    assert json_response(signed_get(conn, key.key_id, secret), 401) == @unauthorized

    {:ok, _} = Apiary.Deletion.restore_organisation(scope, scope.organisation.id)
    assert json_response(signed_get(build_conn(), key.key_id, secret), 200)
  end

  test "a key of a workspace deleted is 401, as a revoked one", %{conn: conn, scope: scope} do
    workspace = workspace_fixture(scope.organisation)
    inside = workspace_scope(scope.user, workspace)
    %{access_key: key, secret: secret} = contract_key_fixture(inside)
    assert json_response(signed_get(conn, key.key_id, secret), 200)

    {:ok, _} = Apiary.Deletion.delete_workspace(scope, workspace.id, workspace.slug)
    assert json_response(signed_get(build_conn(), key.key_id, secret), 401) == @unauthorized
  end

  test "missing headers are 401 with the same body, unsigned", %{key: key, secret: secret} do
    assert json_response(get(build_conn(), @path), 401) == @unauthorized
    timestamp = to_string(System.os_time(:second))

    headers = [
      {"x-qory-access-key-id", key.key_id},
      {"x-qory-instance-id", instance_id()},
      {"x-qory-timestamp", timestamp},
      {"x-qory-contract-version", "1"},
      {"x-qory-signature-ed25519",
       sign_request(secret, key.key_id, instance_id(), "GET", @path, timestamp)}
    ]

    assert json_response(get(%{build_conn() | req_headers: headers}, @path), 200)

    for missing <- ["x-qory-access-key-id", "x-qory-signature-ed25519"] do
      conn = get(%{build_conn() | req_headers: List.keydelete(headers, missing, 0)}, @path)
      assert json_response(conn, 401) == @unauthorized
      assert unsigned_answer?(conn)
    end
  end
end
