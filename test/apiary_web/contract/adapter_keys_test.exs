defmodule ApiaryWeb.Contract.AdapterKeysTest do
  # An adapter's key at the Forager contract's endpoints: it enrols there as any node's
  # key does, its kind and na_ id in the answer, and a request signed under it is refused
  # as a key that is no node's. The pinned Forager contract's fixtures name no adapter, so
  # the answer is read here, not against them.
  use ApiaryWeb.ConnCase, async: true

  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures, only: [signed_get: 5]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, SigningKey}
  alias Apiary.Contract.{Ed25519, SignedMessage}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, adapter: adapter_fixture(scope, name: "Acme tracker")}
  end

  defp enrol(code, pair) do
    timestamp = System.os_time(:second)
    message = SignedMessage.enrolment(code, pair.encoded, "acme-tracker", timestamp)
    proof = :crypto.sign(:eddsa, :none, message, [pair.secret, :ed25519]) |> Ed25519.encode()

    body =
      Jason.encode!(%{
        version: 1,
        code: code,
        name: "acme-tracker",
        public_key: pair.encoded,
        timestamp: timestamp,
        proof: proof
      })

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-qory-contract-version", "1")
    |> post("/.well-known/qory-enrolment", body)
  end

  test "an adapter enrols with a code: adapter and its na_ id in the answer, no stored secrets",
       %{scope: scope, adapter: adapter} do
    {:ok, _row, code} = AccessKeys.create_enrolment_code(scope, adapter, %{allow_secrets: true})
    conn = enrol(code <> "." <> SigningKey.fingerprint(), ed25519_key_pair())

    assert %{
             "version" => 1,
             "node_id" => node_id,
             "node_kind" => "adapter",
             "stored_secrets" => false
           } = json_response(conn, 201)

    assert node_id == adapter.public_id
  end

  test "a request signed under an adapter's key is refused at the node's endpoints",
       %{conn: conn, scope: scope, adapter: adapter} do
    %{access_key: key, pair: pair} = enrolled_key_fixture(scope, adapter)
    assert {:ok, _verified} = AccessKeys.fetch_for_verification(key.key_id)

    for path <- ["/.well-known/qory-configuration"] do
      conn = signed_get(conn, key.key_id, pair.secret, path, [])
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    # A node's key of the same organisation is answered.
    %{access_key: node_key, secret: secret} = access_key_fixture(scope)

    conn =
      signed_get(build_conn(), node_key.key_id, secret, "/.well-known/qory-configuration", [])

    assert json_response(conn, 200)["node_id"] == node_key.node.public_id
  end
end
