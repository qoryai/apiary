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

  @tag :feature_sets
  test "a valid request gets the version 1 document, signed, with its node, its workspace, the run endpoint and the digest",
       %{conn: conn, key: key, secret: secret} do
    conn = signed_get(conn, key.key_id, secret, contract_version: 1)
    base = ApiaryWeb.Endpoint.url()

    assert json_response(conn, 200) ==
             Map.merge(
               %{
                 "version" => 1,
                 "node_id" => key.node.public_id,
                 "workspaces" => [key.workspace.public_id],
                 "events" => %{"url" => base <> "/v1/events", "types" => ["*"]},
                 "run" => %{"url" => base <> "/v1/runs"},
                 "apiary_public_key" => SigningKey.apiary_public_key()
               },
               secrets(base)
             )

    # The contract's order of members.
    assert conn.resp_body =~
             ~r/\A\{"version":1,"node_id":"nd_[^"]+","workspaces":\["ws_[^"]+"\],"events":\{[^}]+\},"run":\{"url":"[^"]+"\},("secrets":\{"url":"[^"]+"\},)?"apiary_public_key":/

    [digest] = get_resp_header(conn, "x-qory-configuration")
    assert digest == ApiaryWeb.Contract.ConfigurationController.digest(conn.resp_body)
    assert digest == Configuration.digest(key)
    assert digest =~ ~r/^sha256=[0-9a-f]{64}$/

    assert signed_answer?(conn)
    assert get_resp_header(conn, "cache-control") == ["no-store, no-transform"]
  end

  test "the run endpoint's URL has no query, no fragment and no trailing slash",
       %{key: key, secret: secret} do
    url = json_response(signed_get(build_conn(), key.key_id, secret), 200)["run"]["url"]
    uri = URI.parse(url)

    assert uri.scheme in ["http", "https"]
    assert uri.query == nil
    assert uri.fragment == nil
    refute String.ends_with?(url, "/")
    assert uri.path == "/v1/runs"
    assert url == ApiaryWeb.Endpoint.url() <> Configuration.run_path()
  end

  # Only the security feature lets a workspace have a policy.
  @tag needs: :security
  test "a workspace's policy changes neither the document nor its digest",
       %{scope: scope, key: key, secret: secret} do
    before = signed_get(build_conn(), key.key_id, secret)
    {:ok, _rule} = Apiary.Policy.allow(scope, nil, %{host: "api.example"})
    later = signed_get(build_conn(), key.key_id, secret)

    assert later.resp_body == before.resp_body

    assert get_resp_header(later, "x-qory-configuration") ==
             get_resp_header(before, "x-qory-configuration")
  end

  test "each node has its own document and digest; a pool's names the pool",
       %{scope: scope, key: key, secret: secret} do
    pool = pool_fixture(scope)
    %{access_key: pool_key, secret: pool_secret} = contract_key_fixture(scope, node: pool)

    one = signed_get(build_conn(), key.key_id, secret)
    other = signed_get(build_conn(), pool_key.key_id, pool_secret)

    assert json_response(other, 200)["node_id"] == pool.public_id
    assert pool.public_id =~ ~r/\Anp_/
    assert json_response(other, 200)["workspaces"] == [scope.workspace.public_id]

    assert get_resp_header(one, "x-qory-configuration") !=
             get_resp_header(other, "x-qory-configuration")
  end

  test "a key lists the workspace its node belongs to, each workspace its own",
       %{scope: scope, key: key, secret: secret} do
    workspace = workspace_fixture(scope.organisation)
    inside = workspace_scope(scope.user, workspace)
    %{access_key: other_key, secret: other_secret} = contract_key_fixture(inside)

    one = json_response(signed_get(build_conn(), key.key_id, secret), 200)
    other = json_response(signed_get(build_conn(), other_key.key_id, other_secret), 200)

    assert one["workspaces"] == [scope.workspace.public_id]
    assert other["workspaces"] == [workspace.public_id]
    assert workspace.public_id != scope.workspace.public_id
    assert Configuration.digest(key) != Configuration.digest(other_key)
  end

  @tag :feature_sets
  test "a gateway's key is given a document without workspaces",
       %{scope: scope, key: key} do
    gateway = gateway_fixture(scope)

    %{access_key: gateway_key, secret: gateway_secret} =
      contract_key_fixture(scope, node: gateway)

    conn = signed_get(build_conn(), gateway_key.key_id, gateway_secret)
    document = json_response(conn, 200)
    base = ApiaryWeb.Endpoint.url()

    assert document ==
             Map.merge(
               %{
                 "version" => 1,
                 "node_id" => gateway.public_id,
                 "events" => %{"url" => base <> "/v1/events", "types" => ["*"]},
                 "run" => %{"url" => base <> "/v1/runs"},
                 "apiary_public_key" => SigningKey.apiary_public_key()
               },
               secrets(base)
             )

    # The members in the contract's order, and the digest the answer names.
    assert conn.resp_body =~ ~r/\A\{"version":1,"node_id":"ng_[^"]+","events":/

    assert get_resp_header(conn, "x-qory-configuration") == [Configuration.digest(gateway_key)]
    assert Configuration.digest(gateway_key) != Configuration.digest(key)
    assert signed_answer?(conn)
  end

  test "an organisation's gateway is given the same document, which a new workspace leaves as it is",
       %{scope: scope} do
    gateway = organisation_gateway_fixture(scope)

    %{access_key: gateway_key, secret: gateway_secret} =
      contract_key_fixture(scope, node: gateway)

    assert gateway_key.workspace == nil

    conn = signed_get(build_conn(), gateway_key.key_id, gateway_secret)
    document = json_response(conn, 200)
    assert document["node_id"] == gateway.public_id
    refute Map.has_key?(document, "workspaces")
    assert signed_answer?(conn)

    [digest] = get_resp_header(conn, "x-qory-configuration")
    assert digest == Configuration.digest(gateway_key)
    assert digest == ApiaryWeb.Contract.ConfigurationController.digest(conn.resp_body)

    # A workspace it may serve is added: nothing of the document changes.
    workspace_fixture(scope.organisation)
    again = signed_get(build_conn(), gateway_key.key_id, gateway_secret)
    assert again.resp_body == conn.resp_body
    assert get_resp_header(again, "x-qory-configuration") == [digest]
  end

  test "encode/1 without workspaces writes no such member" do
    keys = [%{"alg" => "ed25519", "public_key" => "k"}]

    body =
      Configuration.encode(%{
        node_id: "ng_0000000000000000",
        url: "https://qory.example",
        apiary_public_key: keys
      })

    assert body =~ ~r/\A\{"version":1,"node_id":"ng_0000000000000000","events":/
    refute body =~ "workspaces"
  end

  test "encode/1 lists the workspaces in the order it is given" do
    keys = [%{"alg" => "ed25519", "public_key" => "k"}]

    body =
      Configuration.encode(%{
        node_id: "ng_0000000000000000",
        workspaces: ["ws_0000000000000000", "ws_1111111111111111"],
        url: "https://qory.example",
        apiary_public_key: keys
      })

    assert body =~ ~s("workspaces":["ws_0000000000000000","ws_1111111111111111"])
  end

  @tag :contract
  test "the document's bytes are the contract's known answer for its node, workspace, URL and key" do
    %{"apiary_public_key" => keys, "workspaces" => [_] = workspaces} =
      known = known_answers!("discovery")

    body =
      Configuration.encode(%{
        node_id: known["node_id"],
        workspaces: workspaces,
        url: "https://qory.example",
        apiary_public_key: keys
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
    assert instance.node_instance_id == instance_id()
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

  test "a stale or malformed timestamp is 401, unsigned", %{key: key, secret: secret} do
    # Each integer is seconds from the clock, read just before its request. The server
    # reads its clock a moment later, so each timestamp arrives a little older: -301 and
    # 299 sit one second from the window's edge, since that moves them away from it;
    # -290 and 310, which it moves towards the edge, keep 10 seconds from it.
    stamped = fn offset -> System.os_time(:second) + offset end
    now = System.os_time(:second)

    for timestamp <- [-301, 310, "soon", "12.5", "", "+#{now}", " #{now}", nil] do
      timestamp = if is_integer(timestamp), do: stamped.(timestamp), else: timestamp
      conn = signed_get(build_conn(), key.key_id, secret, timestamp: timestamp)
      assert json_response(conn, 401) == @unauthorized
      assert unsigned_answer?(conn)
    end

    for offset <- [-290, 299] do
      conn = signed_get(build_conn(), key.key_id, secret, timestamp: stamped.(offset))
      assert json_response(conn, 200)
    end
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

  # The secrets endpoint every key's document lists with the `registry` feature on.
  defp secrets(base) do
    if Apiary.Features.on?(:registry),
      do: %{"secrets" => %{"url" => base <> "/v1/secrets"}},
      else: %{}
  end
end
