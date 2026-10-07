defmodule ApiaryWeb.Contract.EnrolmentRateLimitTest do
  # The limits come from the application environment, which every test shares.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Repo, SigningKey}
  alias Apiary.AccessKeys.EnrolmentCode
  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias ApiaryWeb.Contract.EnrolmentController

  @path "/.well-known/qory-enrolment"

  setup do
    config = Application.get_env(:apiary, EnrolmentController)
    on_exit(fn -> Application.put_env(:apiary, EnrolmentController, config) end)
  end

  defp limits(limits), do: Application.put_env(:apiary, EnrolmentController, limits)

  defp enrol(address, body) do
    build_conn()
    |> Map.put(:remote_ip, address)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-qory-contract-version", "1")
    |> post(@path, body)
  end

  test "an address over its limit is 429 unsigned, with Retry-After, before the body is read; another address is not" do
    limits(rate: 1, burst: 2)
    address = {192, 0, 2, 17}

    for _ <- 1..2, do: assert(enrol(address, "{}").status == 400)

    conn = enrol(address, "{}")
    assert conn.status == 429
    assert Jason.decode!(conn.resp_body) == %{"error" => "rate_limited"}
    assert get_resp_header(conn, "retry-after") == ["1"]
    assert get_resp_header(conn, "x-qory-signature-ed25519") == []

    assert enrol({192, 0, 2, 18}, "{}").status == 400
  end

  describe "a code's own limit" do
    setup do
      limits(rate: 1000, burst: 100_000, code_rate: 1, code_burst: 2)
      %{scope: scope} = sign_up_fixture()
      %{scope: scope, node: node_fixture(scope, %{name: "build-01"})}
    end

    defp code(scope, node) do
      {:ok, row, code} = AccessKeys.create_enrolment_code(scope, node, %{})
      %{row: row, code: code <> "." <> SigningKey.fingerprint()}
    end

    defp body(code, pair, opts \\ []) do
      public_key = Keyword.get(opts, :public_key, pair.encoded)
      timestamp = System.os_time(:second)
      message = SignedMessage.enrolment(code, public_key, "build-01", timestamp)
      proof = :crypto.sign(:eddsa, :none, message, [pair.secret, :ed25519]) |> Ed25519.encode()

      Jason.encode!(%{
        version: 1,
        code: code,
        name: "build-01",
        public_key: public_key,
        timestamp: timestamp,
        proof: Keyword.get(opts, :proof, proof)
      })
    end

    defp enrol(body), do: enrol({192, 0, 2, 33}, body)

    defp signed?(conn, body) do
      %{"proof" => proof} = Jason.decode!(body)

      with [signature] <- get_resp_header(conn, "x-qory-signature-ed25519"),
           {:ok, signature} <- Ed25519.decode(signature, 64) do
        message = SignedMessage.enrolment_answer(conn.status, proof, conn.resp_body)
        Ed25519.verify(message, signature, SigningKey.public_key())
      else
        _ -> false
      end
    end

    test "past it, a proven key is 429, signed, with Retry-After and the server's keys; another code is not",
         %{scope: scope, node: node} do
      %{code: code} = code(scope, node)
      pair = ed25519_key_pair()

      # The enrolment, then its repeat: two of the code's two.
      for _ <- 1..2, do: assert(enrol(body(code, pair)).status == 201)

      body = body(code, pair)
      conn = enrol(body)
      assert conn.status == 429
      assert get_resp_header(conn, "retry-after") == ["1"]
      assert get_resp_header(conn, "cache-control") == ["no-store, no-transform"]
      assert signed?(conn, body)

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "rate_limited",
               "apiary_public_key" => SigningKey.apiary_public_key()
             }

      %{code: other} = code(scope, node_fixture(scope))
      assert enrol(body(other, ed25519_key_pair())).status == 201
    end

    test "comes after the key and the proof: with the code's limit spent, a bad proof or a key of small order is 409 unsigned, not 429",
         %{scope: scope, node: node} do
      %{code: code, row: row} = code(scope, node)
      %{pair: held} = node_key_fixture(scope, node_fixture(scope))

      # Two signed refusals spend the code's two.
      for _ <- 1..2 do
        body = body(code, held)
        conn = enrol(body)
        assert conn.status == 409
        assert signed?(conn, body)
      end

      assert enrol(body(code, held)).status == 429

      pair = ed25519_key_pair()

      for body <- [
            body(code, ed25519_key_pair(), public_key: pair.encoded),
            body(code, pair, public_key: "AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
          ] do
        conn = enrol(body)
        assert conn.status == 409
        assert Jason.decode!(conn.resp_body) == %{"error" => "key_invalid"}
        assert get_resp_header(conn, "x-qory-signature-ed25519") == []
      end

      assert Repo.get!(EnrolmentCode, row.id).used_at == nil
    end

    test "comes before the ledger and the limit of the node: past it, either is 429", %{
      scope: scope,
      node: node
    } do
      node_key_fixture(scope, node)
      node_key_fixture(scope, node)
      %{code: code} = code(scope, node)

      for _ <- 1..2, do: assert(enrol(body(code, ed25519_key_pair())).status == 409)

      %{pair: held} = node_key_fixture(scope, node_fixture(scope))
      assert enrol(body(code, held)).status == 429
      assert enrol(body(code, ed25519_key_pair())).status == 429
    end

    test "is not spent by a code refused or a key unproven", %{scope: scope, node: node} do
      %{code: code} = code(scope, node)
      pair = ed25519_key_pair()

      for _ <- 1..3 do
        assert enrol(body(code, ed25519_key_pair(), public_key: pair.encoded)).status == 409
      end

      assert enrol(body(code, pair)).status == 201
    end
  end
end
