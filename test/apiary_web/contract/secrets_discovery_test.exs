defmodule ApiaryWeb.Contract.SecretsDiscoveryTest do
  # Discovery lists the secrets endpoint for a key allowed stored secrets, only with the
  # `factory` and `secrets` features both on; with either off, a secrets request that
  # verifies is given a signed 404. Not async: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures

  alias ApiaryWeb.Contract.SignedRequest

  setup do
    %{scope: scope} = sign_up_fixture()
    gateway = Apiary.NodesFixtures.gateway_fixture(scope)

    %{access_key: allowed, pair: pair} =
      Apiary.AccessKeysFixtures.enrolled_key_fixture(scope, gateway, %{allow_secrets: true})

    %{access_key: plain, secret: plain_seed} = contract_key_fixture(scope, node: gateway)
    %{allowed: {allowed, pair.secret}, plain: {plain, plain_seed}}
  end

  defp discovery({key, seed}),
    do: signed_get(build_conn(), key.key_id, seed, "/.well-known/qory-configuration")

  defp secrets_post({key, seed}) do
    body =
      Jason.encode!(%{
        "version" => 1,
        "run_id" => Ecto.UUID.generate(),
        "run_configuration" => "sha256=" <> String.duplicate("0", 64),
        "credentials" => ["model"],
        "timestamp" => SignedRequest.now()
      })

    signed_post(build_conn(), key.key_id, seed, body,
      target: "/v1/secrets",
      content_type: "application/json",
      delivery: nil
    )
  end

  @tag needs: :factory
  test "lists the secrets URL for a key allowed stored secrets", ctx do
    document = Jason.decode!(response(discovery(ctx.allowed), 200))
    assert document["secrets"] == %{"url" => ApiaryWeb.Endpoint.url() <> "/v1/secrets"}

    assert document |> Map.keys() |> Enum.sort() ==
             Enum.sort(~w(version node_id events run secrets apiary_public_key))

    refute Map.has_key?(Jason.decode!(response(discovery(ctx.plain), 200)), "secrets")
  end

  test "the document's member order puts secrets after run" do
    body =
      ApiaryWeb.Contract.Configuration.encode(%{
        node_id: "ng_example",
        url: "https://qory.example",
        apiary_public_key: [%{"alg" => "ed25519", "public_key" => "key"}],
        secrets: true
      })

    assert body ==
             ~s({"version":1,"node_id":"ng_example","events":{"url":"https://qory.example/v1/events","types":["*"]},) <>
               ~s("run":{"url":"https://qory.example/v1/runs"},"secrets":{"url":"https://qory.example/v1/secrets"},) <>
               ~s("apiary_public_key":[{"alg":"ed25519","public_key":"key"}]})
  end

  describe "with factory off" do
    @describetag with_features: [:observability, :security, :secrets]

    test "discovery lists no secrets URL, and a request that verifies is a signed 404", ctx do
      refute Map.has_key?(Jason.decode!(response(discovery(ctx.allowed), 200)), "secrets")

      conn = secrets_post(ctx.allowed)
      assert conn.status == 404
      assert signed_answer?(conn)
    end

    test "an unsigned request is answered as a path the router does not know" do
      post = fn path ->
        build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(path, "{}")
      end

      secrets = post.("/v1/secrets")
      unknown = post.("/v1/no-such-path")
      assert secrets.status == 404
      assert {secrets.status, secrets.resp_body} == {unknown.status, unknown.resp_body}
    end
  end

  describe "with secrets off" do
    @describetag with_features: [:observability, :security, :factory]

    test "discovery lists no secrets URL, and a request that verifies is a signed 404", ctx do
      refute Map.has_key?(Jason.decode!(response(discovery(ctx.allowed), 200)), "secrets")

      conn = secrets_post(ctx.allowed)
      assert conn.status == 404
      assert signed_answer?(conn)
    end
  end
end
