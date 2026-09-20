defmodule ApiaryWeb.Contract.ConfigurationControllerTest do
  use ApiaryWeb.ConnCase, async: true

  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.AccessKeys
  alias Apiary.Contract.Signature

  @path "/.well-known/qory-configuration"
  @unauthorized %{"error" => "unauthorized"}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{access_key: key, secret: secret} = access_key_fixture(scope)
    %{scope: scope, key: key, secret: secret}
  end

  defp signed_get(conn, key_id, secret, opts \\ []) do
    path = Keyword.get(opts, :path, @path)
    timestamp = Keyword.get(opts, :timestamp, System.os_time(:second))
    canonical = Signature.canonical_string("GET", path, timestamp)
    signature = Keyword.get(opts, :signature, Signature.sign(secret, canonical))
    user_agent = Keyword.get(opts, :user_agent, "qory-runner/0.9.1")

    conn
    |> put_req_header("x-qory-access-key", key_id)
    |> put_req_header("x-qory-timestamp", to_string(timestamp))
    |> put_req_header("x-qory-signature-256", signature)
    |> put_req_header("user-agent", user_agent)
    |> then(fn conn ->
      case Keyword.get(opts, :contract_version) do
        nil -> conn
        version -> put_req_header(conn, "x-qory-contract-version", to_string(version))
      end
    end)
    |> get(path)
  end

  test "a valid request gets the version 1 document with the events section and its digest",
       %{conn: conn, key: key, secret: secret} do
    conn = signed_get(conn, key.key_id, secret, contract_version: 1)
    base = ApiaryWeb.Endpoint.url()

    assert json_response(conn, 200) == %{
             "version" => 1,
             "events" => %{"url" => base <> "/v1/events", "types" => ["*"]}
           }

    # No run section until the run configuration exists: a runner refuses to run
    # when a named section does not answer.
    refute Map.has_key?(json_response(conn, 200), "run")

    [digest] = get_resp_header(conn, "x-qory-configuration")
    assert digest == ApiaryWeb.Contract.ConfigurationController.digest(conn.resp_body)
    assert digest =~ ~r/^sha256=[0-9a-f]{64}$/
  end

  test "a request with a query string signs the path and the query as received", %{
    conn: conn,
    key: key,
    secret: secret
  } do
    conn = signed_get(conn, key.key_id, secret, path: @path <> "?b=2&a=1")
    assert json_response(conn, 200)["version"] == 1

    # The same query signed without it fails.
    canonical = Signature.canonical_string("GET", @path, System.os_time(:second))

    conn =
      signed_get(build_conn(), key.key_id, secret,
        path: @path <> "?b=2&a=1",
        signature: Signature.sign(secret, canonical)
      )

    assert json_response(conn, 401) == @unauthorized
  end

  test "success touches the key", %{conn: conn, key: key, secret: secret, scope: scope} do
    assert AccessKeys.get_access_key!(scope, key.id).last_used_at == nil
    signed_get(conn, key.key_id, secret, contract_version: 1, user_agent: "qory-runner/1.2.3")

    touched = AccessKeys.get_access_key!(scope, key.id)
    assert touched.last_used_at
    assert touched.last_runner_version == "1.2.3"
    assert touched.last_contract_version == 1

    signed_get(build_conn(), key.key_id, secret, user_agent: "curl/8.0")
    touched = AccessKeys.get_access_key!(scope, key.id)
    assert touched.last_runner_version == nil
    assert touched.last_contract_version == nil
  end

  test "M2: a key id that is not valid UTF-8 is 401, not a crash", %{conn: conn, secret: secret} do
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
    end
  end

  test "M2: an over-long User-Agent succeeds and is recorded truncated", %{
    conn: conn,
    key: key,
    secret: secret,
    scope: scope
  } do
    long = "qory-runner/" <> String.duplicate("9", 5_000)

    assert %{"version" => 1} =
             conn |> signed_get(key.key_id, secret, user_agent: long) |> json_response(200)

    touched = AccessKeys.get_access_key!(scope, key.id)
    assert touched.last_used_at
    assert touched.last_runner_version == String.duplicate("9", 80)
  end

  test "M2: a User-Agent that is not printable text succeeds and records no version", %{
    conn: conn,
    key: key,
    secret: secret,
    scope: scope
  } do
    for user_agent <- [
          "qory-runner/" <> <<0xFF, 0xFE>>,
          "qory-runner/1.0\e[31m",
          "qory-runner/1\0"
        ] do
      conn = signed_get(conn, key.key_id, secret, user_agent: user_agent)
      assert %{"version" => 1} = json_response(conn, 200)
      assert AccessKeys.get_access_key!(scope, key.id).last_runner_version == nil
    end
  end

  test "M2: an oversized contract version succeeds and is not recorded", %{
    conn: conn,
    key: key,
    secret: secret,
    scope: scope
  } do
    for version <- ["99999999999999999999", "2147483648", "32768", "-1"] do
      conn = signed_get(conn, key.key_id, secret, contract_version: version)
      assert %{"version" => 1} = json_response(conn, 200)

      touched = AccessKeys.get_access_key!(scope, key.id)
      assert touched.last_used_at
      assert touched.last_contract_version == nil
    end

    signed_get(conn, key.key_id, secret, contract_version: 32_767)
    assert AccessKeys.get_access_key!(scope, key.id).last_contract_version == 32_767
  end

  test "the secondary secret verifies during a rotation", %{
    conn: conn,
    key: key,
    secret: old_secret,
    scope: scope
  } do
    {:ok, key, new_secret} = AccessKeys.rotate_access_key(scope, key)
    assert json_response(signed_get(conn, key.key_id, old_secret), 200)["version"] == 1
    assert json_response(signed_get(build_conn(), key.key_id, new_secret), 200)["version"] == 1

    {:ok, key} = AccessKeys.retire_previous_secret(scope, key)
    assert json_response(signed_get(build_conn(), key.key_id, old_secret), 401) == @unauthorized
  end

  test "a tampered signature is 401", %{conn: conn, key: key, secret: secret} do
    conn = signed_get(conn, key.key_id, secret, signature: Signature.sign("wrong", "x"))
    assert json_response(conn, 401) == @unauthorized
  end

  test "a stale or malformed timestamp is 401", %{conn: conn, key: key, secret: secret} do
    now = System.os_time(:second)

    for timestamp <- [now - 301, now + 301, "soon", "12.5", ""] do
      conn = signed_get(build_conn(), key.key_id, secret, timestamp: timestamp)
      assert json_response(conn, 401) == @unauthorized
    end

    assert json_response(signed_get(conn, key.key_id, secret, timestamp: now - 299), 200)
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

  test "missing headers are 401 with the same body", %{conn: conn, key: key, secret: secret} do
    assert json_response(get(conn, @path), 401) == @unauthorized

    timestamp = System.os_time(:second)
    signature = Signature.sign(secret, Signature.canonical_string("GET", @path, timestamp))

    headers = [
      {"x-qory-access-key", key.key_id},
      {"x-qory-timestamp", to_string(timestamp)},
      {"x-qory-signature-256", signature}
    ]

    for {missing, _} <- headers do
      conn =
        Enum.reduce(headers, build_conn(), fn
          {^missing, _}, conn -> conn
          {name, value}, conn -> put_req_header(conn, name, value)
        end)
        |> get(@path)

      assert json_response(conn, 401) == @unauthorized
    end
  end
end
