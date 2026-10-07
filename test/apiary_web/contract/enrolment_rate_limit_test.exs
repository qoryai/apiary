defmodule ApiaryWeb.Contract.EnrolmentRateLimitTest do
  # The limits come from the application environment, which every test shares.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Repo, SigningKey}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode, PublicKey}
  alias Apiary.Audit.Entry
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

  # A request from `address` with exactly `headers`, a header twice included: straight to
  # the endpoint, as `post/3` wants a content type with a body.
  defp enrol_with(address, body, headers) do
    %{build_conn() | req_headers: headers}
    |> Map.put(:remote_ip, address)
    |> Plug.Adapters.Test.Conn.conn(:post, @path, body)
    |> ApiaryWeb.Endpoint.call(ApiaryWeb.Endpoint.init([]))
  end

  defp json, do: {"content-type", "application/json"}
  defp version(value \\ "1"), do: {"x-qory-contract-version", value}

  # Spends the whole of `address`'s bucket, `burst` of it, on bodies the schema refuses.
  defp spend(address, burst) do
    for _ <- 1..burst, do: assert(enrol(address, "{}").status == 400)
    assert enrol(address, "{}").status == 429
  end

  describe "the address's limit, in the contract's order" do
    setup do
      limits(rate: 0, burst: 2)
    end

    test "4: past it, 429 rate_limited, unsigned, with Retry-After" do
      address = {192, 0, 2, 40}
      spend(address, 2)

      conn = enrol_with(address, "{}", [json(), version()])
      assert conn.status == 429
      assert Jason.decode!(conn.resp_body) == %{"error" => "rate_limited"}
      assert get_resp_header(conn, "retry-after") == ["1"]
      assert get_resp_header(conn, "x-qory-signature-ed25519") == []
    end

    test "2 and 3 before 4: past it, a wrong content type is 415 and a header sent twice 400 bad_request" do
      address = {192, 0, 2, 41}
      spend(address, 2)

      conn = enrol_with(address, "{}", [{"content-type", "text/plain"}, version()])
      assert conn.status == 415
      assert Jason.decode!(conn.resp_body) == %{"error" => "unsupported_media_type"}
      assert get_resp_header(conn, "x-qory-signature-ed25519") == []
      assert get_resp_header(conn, "retry-after") == []

      conn = enrol_with(address, "{}", [json(), version(), version()])
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body) == %{"error" => "bad_request"}
      assert get_resp_header(conn, "retry-after") == []
    end

    test "4 before 5 and 6: past it, a version not served is 429" do
      address = {192, 0, 2, 42}
      spend(address, 2)

      for headers <- [[json(), version("2")], [json()]] do
        conn = enrol_with(address, "{}", headers)
        assert conn.status == 429
        assert Jason.decode!(conn.resp_body) == %{"error" => "rate_limited"}
        assert get_resp_header(conn, "retry-after") == ["1"]
      end
    end

    test "a request refused at 1, 2 or 3 spends none of it" do
      address = {192, 0, 2, 43}

      for _ <- 1..3 do
        assert enrol_with(address, String.duplicate(" ", 8 * 1024 + 1), [json(), version()]).status ==
                 413

        assert enrol_with(address, "{}", [{"content-type", "text/plain"}, version()]).status ==
                 415

        assert enrol_with(address, "{}", [json(), json(), version()]).status == 400
      end

      spend(address, 2)
    end
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

    test "is not spent, and nothing is written, by a request refused before the code: 413, 415, 400 bad_request, 429 by address, 400 unsupported_contract_version, 400 invalid_request",
         %{scope: scope, node: node} do
      limits(rate: 0, burst: 3, code_rate: 0, code_burst: 1)
      %{code: code, row: row} = code(scope, node)
      pair = ed25519_key_pair()
      valid = body(code, pair)
      invalid = valid |> Jason.decode!() |> Map.put("name", "-build") |> Jason.encode!()

      counts = fn -> Enum.map([AccessKey, PublicKey, Entry], &Repo.aggregate(&1, :count)) end
      before = counts.()

      over = {192, 0, 2, 50}
      for _ <- 1..3, do: assert(enrol(over, "{}").status == 400)
      assert enrol(over, valid).status == 429

      address = {192, 0, 2, 51}
      long = valid <> String.duplicate(" ", 8 * 1024)

      for {body, headers, status} <- [
            {long, [json(), version()], 413},
            {valid, [{"content-type", "text/plain"}, version()], 415},
            {valid, [json(), version(), version()], 400},
            {valid, [json(), version("2")], 400},
            {invalid, [json(), version()], 400}
          ] do
        assert enrol_with(address, body, headers).status == status
      end

      assert counts.() == before
      assert Repo.get!(EnrolmentCode, row.id).used_at == nil

      # The code's one token is still there; the address's third is spent on it.
      conn = enrol(address, valid)
      assert conn.status == 201
      assert signed?(conn, valid)
      assert Repo.get_by!(AccessKey, public_key: pair.public_key)
    end

    test "is not spent by a proof that does not verify under the key", %{
      scope: scope,
      node: node
    } do
      %{code: code} = code(scope, node)
      pair = ed25519_key_pair()

      for _ <- 1..3 do
        assert enrol(body(code, ed25519_key_pair(), public_key: pair.encoded)).status == 409
      end

      assert enrol(body(code, pair)).status == 201
    end
  end
end
