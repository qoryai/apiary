defmodule ApiaryWeb.Contract.EnrolmentAcceptsHelpers do
  # The enrolment request with an optional `accepts`, the kinds of node the machine enrols
  # as, and the checks of its signed `409` `kind_not_accepted`. The pinned Forager
  # contract's schema does not define `accepts` yet, so these read the answers with
  # Qory Apiary's verification helpers, not against the contract's fixtures.
  import ExUnit.Assertions
  import Phoenix.ConnTest
  import Plug.Conn

  alias Apiary.{AccessKeys, Repo, SigningKey}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Contract.{Ed25519, SignedMessage}

  @endpoint ApiaryWeb.Endpoint
  @kinds ~w(node pool gateway adapter)

  def kinds, do: @kinds

  def code(scope, node, attrs \\ %{}) do
    {:ok, row, code} = AccessKeys.create_enrolment_code(scope, node, attrs)
    %{row: row, code: code <> "." <> SigningKey.fingerprint()}
  end

  # The body `qory access-key enrol` sends, with `accepts` when given: the proof covers
  # the five lines alone, so `accepts` changes nothing it signs.
  def body(code, pair, opts \\ []) do
    timestamp = Keyword.get(opts, :timestamp, System.os_time(:second))
    message = SignedMessage.enrolment(code, pair.encoded, "build-01", timestamp)
    proof = :crypto.sign(:eddsa, :none, message, [pair.secret, :ed25519]) |> Ed25519.encode()

    fields = [
      {"version", 1},
      {"code", code},
      {"name", "build-01"},
      {"public_key", pair.encoded},
      {"timestamp", timestamp},
      {"proof", Keyword.get(opts, :proof, proof)}
    ]

    fields =
      case Keyword.fetch(opts, :accepts) do
        {:ok, accepts} -> fields ++ [{"accepts", accepts}]
        :error -> fields
      end

    Jason.encode!(Jason.OrderedObject.new(fields))
  end

  def enrol(body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-qory-contract-version", "1")
    |> post("/.well-known/qory-enrolment", body)
  end

  # The answer's signature verifies under the instance's key as an enrolment answer: the
  # enrolment answers' domain line, line 3 the request's proof as sent.
  def assert_signed(conn, body) do
    %{"proof" => proof} = Jason.decode!(body)
    assert [signature] = get_resp_header(conn, "x-qory-signature-ed25519")
    assert {:ok, signature} = Ed25519.decode(signature, 64)
    message = SignedMessage.enrolment_answer(conn.status, proof, conn.resp_body)
    assert String.starts_with?(message, "qory-enrol-answer-ed25519-v1\n")
    assert Ed25519.verify(message, signature, SigningKey.public_key())

    refute Ed25519.verify(
             SignedMessage.answer(conn.status, proof, conn.resp_body, nil, nil),
             signature,
             SigningKey.public_key()
           )

    assert get_resp_header(conn, "cache-control") == ["no-store, no-transform"]
    Jason.decode!(conn.resp_body)
  end

  def assert_unsigned(conn), do: assert(get_resp_header(conn, "x-qory-signature-ed25519") == [])

  # The signed 409, naming exactly the code's kind, its members in the order of
  # `key_limit`'s with `names` between.
  def assert_kind_not_accepted(conn, body, kind) do
    assert conn.status == 409
    keys = SigningKey.apiary_public_key()

    assert assert_signed(conn, body) == %{
             "error" => "kind_not_accepted",
             "names" => [kind],
             "apiary_public_key" => keys
           }

    assert conn.resp_body ==
             ~s({"error":"kind_not_accepted","names":["#{kind}"],"apiary_public_key":) <>
               Jason.encode!(keys) <> "}"
  end

  def assert_code_unused(row) do
    assert %EnrolmentCode{used_at: nil, used_by_key_id: nil, public_key: nil} =
             Repo.get!(EnrolmentCode, row.id)
  end

  def keys_of(node) do
    import Ecto.Query
    Repo.aggregate(from(k in AccessKey, where: k.node_id == ^node.id), :count)
  end

  # For a code of `node`, of `kind`: refused by every `accepts` that leaves the kind out,
  # signed, changing nothing; then enrolled by one that names it, and by one that names
  # every kind.
  def refused_then_enrolled(scope, node, kind) do
    %{row: row, code: code} = code(scope, node)
    others = @kinds -- [kind]

    for accepts <- [others, [hd(others)], Enum.reverse(others)] do
      body = body(code, pair(), accepts: accepts)
      assert_kind_not_accepted(enrol(body), body, kind)
      assert_code_unused(row)
      assert keys_of(node) == 0
    end

    body = body(code, pair(), accepts: [kind])
    conn = enrol(body)
    assert conn.status == 201
    assert assert_signed(conn, body)["node_kind"] == kind
    assert keys_of(node) == 1

    %{code: every} = code(scope, node)
    assert enrol(body(every, pair(), accepts: @kinds)).status == 201
  end

  def pair, do: Apiary.AccessKeysFixtures.ed25519_key_pair()
end

defmodule ApiaryWeb.Contract.EnrolmentAcceptsTest do
  use ApiaryWeb.ConnCase, async: true

  import ApiaryWeb.Contract.EnrolmentAcceptsHelpers
  import Apiary.AccessKeysFixtures, only: [ed25519_key_pair: 0, node_key_fixture: 2]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Repo}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Contract.Enrolment

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, node: node_fixture(scope, %{name: "build-01"})}
  end

  describe "accepts naming the code's kind" do
    test("a node", %{scope: scope, node: node}, do: refused_then_enrolled(scope, node, "node"))

    test("a pool", %{scope: scope}, do: refused_then_enrolled(scope, pool_fixture(scope), "pool"))

    test("a gateway", %{scope: scope},
      do: refused_then_enrolled(scope, gateway_fixture(scope, name: "edge"), "gateway")
    )

    test "absent, any kind enrols", %{scope: scope, node: node} do
      for target <- [node, pool_fixture(scope), gateway_fixture(scope, name: "edge-2")] do
        %{code: code} = code(scope, target)
        assert enrol(body(code, ed25519_key_pair())).status == 201
      end
    end
  end

  describe "accepts the schema refuses, 400 invalid_request unsigned" do
    test "an empty array, a repeat, an unknown kind, or not an array of kind words", %{
      scope: scope,
      node: node
    } do
      %{row: row, code: code} = code(scope, node)

      for accepts <- [
            [],
            ["node", "node"],
            ["node", "pool", "node"],
            ["robot"],
            ["node", "Node"],
            [nil],
            [1],
            nil,
            "node",
            %{"node" => true}
          ] do
        conn = enrol(body(code, ed25519_key_pair(), accepts: accepts))
        assert conn.status == 400, inspect(accepts)

        assert Jason.decode!(conn.resp_body) == %{
                 "error" => "invalid_request",
                 "names" => ["accepts"]
               }

        assert_unsigned(conn)
      end

      assert_code_unused(row)
      assert enrol(body(code, ed25519_key_pair(), accepts: ["node"])).status == 201
    end

    test "before the code is looked at: an unknown code is 400 too" do
      code = "qec_00000000000000000000000000." <> Apiary.SigningKey.fingerprint()
      conn = enrol(body(code, ed25519_key_pair(), accepts: []))
      assert conn.status == 400
      assert_unsigned(conn)
    end

    test "named with the other members at fault, in the schema's order", %{
      scope: scope,
      node: node
    } do
      %{code: code} = code(scope, node)

      body =
        code
        |> body(ed25519_key_pair(), accepts: ["robot"])
        |> Jason.decode!()
        |> Map.put("version", 2)
        |> Jason.encode!()

      assert Jason.decode!(enrol(body).resp_body)["names"] == ["version", "accepts"]
    end
  end

  describe "kind_not_accepted in the order of the answers" do
    test "after the code: an unknown, used or expired code is 401 unsigned", %{
      scope: scope,
      node: node
    } do
      unknown = "qec_00000000000000000000000000." <> Apiary.SigningKey.fingerprint()
      conn = enrol(body(unknown, ed25519_key_pair(), accepts: ["pool"]))
      assert conn.status == 401
      assert_unsigned(conn)

      %{code: code} = code(scope, node)
      assert enrol(body(code, ed25519_key_pair())).status == 201
      conn = enrol(body(code, ed25519_key_pair(), accepts: ["pool"]))
      assert conn.status == 401
      assert_unsigned(conn)
    end

    test "after the proof: a proof that does not verify is 409 key_invalid unsigned", %{
      scope: scope,
      node: node
    } do
      %{row: row, code: code} = code(scope, node)
      forged = body(code, ed25519_key_pair()) |> Jason.decode!() |> Map.get("proof")
      conn = enrol(body(code, ed25519_key_pair(), accepts: ["pool"], proof: forged))
      assert conn.status == 409
      assert Jason.decode!(conn.resp_body) == %{"error" => "key_invalid"}
      assert_unsigned(conn)
      assert_code_unused(row)
    end

    test "before key_limit: a node that holds two keys", %{scope: scope, node: node} do
      node_key_fixture(scope, node)
      node_key_fixture(scope, node)
      %{row: row, code: code} = code(scope, node)
      body = body(code, ed25519_key_pair(), accepts: ["gateway"])
      assert_kind_not_accepted(enrol(body), body, "node")
      assert_code_unused(row)

      conn = enrol(body(code, ed25519_key_pair(), accepts: ["node"]))
      assert conn.status == 409
      assert Jason.decode!(conn.resp_body)["error"] == "key_limit"
    end

    test "before the ledger: a key another access key holds", %{scope: scope, node: node} do
      %{pair: pair} = node_key_fixture(scope, node_fixture(scope))
      %{row: row, code: code} = code(scope, node)
      body = body(code, pair, accepts: ["pool"])
      assert_kind_not_accepted(enrol(body), body, "node")
      assert_code_unused(row)
    end

    test "before the code's limit, which it does not count", %{scope: scope, node: node} do
      %{row: row, code: code} = code(scope, node)
      {:ok, refused} = Enrolment.decode(body(code, ed25519_key_pair(), accepts: ["pool"]))
      limit = [rate: 1, burst: 1]

      for _ <- 1..5 do
        assert AccessKeys.enrol(refused, code_limit: limit) ==
                 {:error, {:kind_not_accepted, :node}}
      end

      {:ok, accepted} = Enrolment.decode(body(code, ed25519_key_pair(), accepts: ["node"]))
      assert {:ok, %AccessKey{}} = AccessKeys.enrol(accepted, code_limit: limit)
      assert %EnrolmentCode{used_at: %DateTime{}} = Repo.get!(EnrolmentCode, row.id)
    end

    test "a used code again, with the same key: refused for its kind, changing nothing", %{
      scope: scope,
      node: node
    } do
      %{row: row, code: code} = code(scope, node)
      pair = ed25519_key_pair()
      assert enrol(body(code, pair)).status == 201
      used = Repo.get!(EnrolmentCode, row.id)

      body = body(code, pair, accepts: ["pool"], timestamp: System.os_time(:second) + 1)
      assert_kind_not_accepted(enrol(body), body, "node")
      assert Repo.get!(EnrolmentCode, row.id) == used
      assert keys_of(node) == 1

      assert enrol(body(code, pair, accepts: ["node"])).status == 201
    end
  end
end

defmodule ApiaryWeb.Contract.EnrolmentAcceptsAdapterTest do
  use ApiaryWeb.ConnCase, async: true

  import ApiaryWeb.Contract.EnrolmentAcceptsHelpers
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  @moduletag needs: :factory

  test "an adapter's code: refused while accepts leaves the kind out, then enrolled" do
    %{scope: scope} = sign_up_fixture()
    refused_then_enrolled(scope, adapter_fixture(scope, name: "Acme tracker"), "adapter")
  end
end
