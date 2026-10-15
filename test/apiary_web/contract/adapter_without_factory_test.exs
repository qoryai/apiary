defmodule ApiaryWeb.Contract.AdapterWithoutFactoryTest do
  # An instance without the feature adapters belong to: an adapter's request that
  # verifies is answered a signed 404, one that does not is told 401, and one with no
  # signature at all is answered as a path the router does not know. Not async: the
  # features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures, only: [signed_answer?: 1, unsigned_answer?: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{IntegrationsContract, Repo}
  alias Apiary.Nodes.Node

  # The adapter is made where the feature is on, before it is turned off.
  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    adapter = adapter_fixture(scope)
    %{access_key: key, pair: pair} = enrolled_key_fixture(scope, adapter)
    previous = Application.get_env(:apiary, :features)
    {:ok, features} = Apiary.Features.parse("observability,security")
    Application.put_env(:apiary, :features, features)
    on_exit(fn -> Application.put_env(:apiary, :features, previous) end)
    %{adapter: adapter, key: key, seed: pair.secret}
  end

  defp body do
    Jason.encode!(%{
      "version" => 1,
      "time" => DateTime.utc_now(:second) |> DateTime.to_iso8601(),
      "connect_url" => "https://tracker-adapter.acme.example/connect",
      "sync" => %{"default_interval" => 900, "minimum_interval" => 300, "sends_changes" => false}
    })
  end

  test "a request that verifies is answered a signed 404, and changes nothing", ctx do
    conn =
      IntegrationsContract.adapter_post(
        build_conn(),
        ctx.key.key_id,
        ctx.seed,
        "/v1/adapter",
        body()
      )

    assert conn.status == 404
    assert signed_answer?(conn)
    assert Repo.get!(Node, ctx.adapter.id).connect_url == nil
  end

  test "a request that does not verify is told 401, unsigned", ctx do
    conn =
      IntegrationsContract.adapter_post(
        build_conn(),
        ctx.key.key_id,
        "not the secret",
        "/v1/adapter",
        body()
      )

    assert conn.status == 401
    assert unsigned_answer?(conn)
  end

  test "a request with no signature is answered as a path the router does not know" do
    assert answer("/v1/adapter") == answer("/v1/no-such-endpoint")
  end

  # The status and body a POST of the body to `path` is answered, whether the endpoint
  # sends it or raises it.
  defp answer(path) do
    conn = request(path)
    {conn.status, conn.resp_body}
  rescue
    _error ->
      {status, _headers, body} = assert_error_sent(:not_found, fn -> request(path) end)
      {status, body}
  end

  defp request(path) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, body())
  end
end
