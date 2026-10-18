defmodule ApiaryWeb.Contract.AdapterKeysTest do
  # An adapter's key at the Forager contract's endpoints: it enrols there as any node's
  # key does, its kind and na_ id in the answer, and a request signed under it is refused
  # as a key that is no node's. The pinned Forager contract's fixtures name no adapter, so
  # the answer is read here, not against them.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Apiary.AccessKeysFixtures

  import Apiary.ContractFixtures,
    only: [
      attach_body: 1,
      first_events: 0,
      registration: 0,
      signed_attach: 6,
      signed_get: 5,
      signed_post: 5,
      signed_register: 5
    ]

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Repo, SigningKey}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.Nodes.Instance

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()

    %{
      scope: scope,
      admin: instance_admin_scope(),
      adapter: adapter_fixture(name: unique_adapter_name("Acme tracker"))
    }
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
       %{admin: admin, adapter: adapter} do
    {:ok, _row, code} = AccessKeys.create_enrolment_code(admin, adapter, %{allow_secrets: true})
    assert EnrolmentCode.of_kind?(code, :adapter)
    conn = enrol(code <> "." <> SigningKey.fingerprint(), ed25519_key_pair())

    assert %{
             "version" => 1,
             "node_id" => node_id,
             "node_kind" => "adapter",
             "stored_secrets" => false
           } = json_response(conn, 201)

    assert node_id == adapter.public_id
  end

  test "a request signed under an adapter's key is refused at every endpoint of a node's",
       %{scope: scope, admin: admin, adapter: adapter} do
    %{access_key: key, pair: pair} = enrolled_key_fixture(admin, adapter)
    assert {:ok, _verified} = AccessKeys.fetch_for_verification(key.key_id)

    run_id = Ecto.UUID.generate()
    {_subject, events} = first_events()

    answers = [
      discovery:
        signed_get(build_conn(), key.key_id, pair.secret, "/.well-known/qory-configuration", []),
      events: signed_post(build_conn(), key.key_id, pair.secret, events, []),
      register: signed_register(build_conn(), key.key_id, pair.secret, registration(), []),
      run: signed_get(build_conn(), key.key_id, pair.secret, "/v1/runs/#{run_id}", []),
      attach:
        signed_attach(
          build_conn(),
          key.key_id,
          pair.secret,
          run_id,
          attach_body("rk_example"),
          []
        ),
      outcome:
        signed_post(build_conn(), key.key_id, pair.secret, %{"version" => 1},
          target: "/v1/runs/#{run_id}/outcome",
          content_type: "application/json",
          delivery: nil
        )
    ]

    for {endpoint, conn} <- answers do
      assert json_response(conn, 401) == %{"error" => "unauthorized"}, "#{endpoint} answered"
    end

    # Nothing the key was refused for is recorded as its use, or as an instance of the
    # adapter's.
    assert Repo.get!(AccessKey, key.id).last_used_at == nil
    assert Repo.aggregate(from(i in Instance, where: i.node_id == ^adapter.id), :count) == 0

    # A key enrolled the same way on a node of an organisation is answered.
    node = node_fixture(scope)
    %{access_key: node_key, pair: node_pair} = enrolled_key_fixture(scope, node)

    conn =
      signed_get(
        build_conn(),
        node_key.key_id,
        node_pair.secret,
        "/.well-known/qory-configuration",
        []
      )

    assert json_response(conn, 200)["node_id"] == node.public_id
  end
end
