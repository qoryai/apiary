defmodule ApiaryWeb.Contract.EnrolmentControllerTest do
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Deletion, Nodes, Repo, SigningKey}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode, PublicKey}
  alias Apiary.Audit.Entry
  alias Apiary.Contract.{Ed25519, SignedMessage}

  @path "/.well-known/qory-enrolment"

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, node: node_fixture(scope, %{name: "build-01"})}
  end

  # A code of `node`, as the page shows it: the code, then `.` and the instance's
  # fingerprint.
  defp code(scope, node, attrs \\ %{}) do
    {:ok, row, code} = AccessKeys.create_enrolment_code(scope, node, attrs)
    %{row: row, code: code <> "." <> SigningKey.fingerprint()}
  end

  # The request body `qory access-key enrol` sends, its proof signed under `pair`.
  defp body(code, pair, opts \\ []) do
    name = Keyword.get(opts, :name, "build-01")
    timestamp = Keyword.get(opts, :timestamp, System.os_time(:second))
    public_key = Keyword.get(opts, :public_key, pair.encoded)
    message = SignedMessage.enrolment(code, public_key, name, timestamp)
    proof = :crypto.sign(:eddsa, :none, message, [pair.secret, :ed25519]) |> Ed25519.encode()

    Jason.encode!(%{
      version: 1,
      code: code,
      name: name,
      public_key: public_key,
      timestamp: timestamp,
      proof: Keyword.get(opts, :proof, proof)
    })
  end

  defp enrol(body, opts \\ []) do
    build_conn()
    |> Map.put(:remote_ip, Keyword.get(opts, :remote_ip, {127, 0, 0, 1}))
    |> put_req_header("content-type", "application/json")
    |> then(fn conn ->
      case Keyword.get(opts, :version, "1") do
        nil -> conn
        version -> put_req_header(conn, "x-qory-contract-version", version)
      end
    end)
    |> post(@path, body)
  end

  # The answer's signature verifies under the instance's key, line 3 being the proof.
  defp assert_signed(conn, body) do
    %{"proof" => proof} = Jason.decode!(body)
    assert [signature] = get_resp_header(conn, "x-qory-signature-ed25519")
    assert {:ok, signature} = Ed25519.decode(signature, 64)
    message = SignedMessage.answer(conn.status, proof, conn.resp_body, nil, nil)
    assert Ed25519.verify(message, signature, SigningKey.public_key())
    assert get_resp_header(conn, "cache-control") == ["no-store, no-transform"]
    assert [<<"application/json", _::binary>>] = get_resp_header(conn, "content-type")
    Jason.decode!(conn.resp_body)
  end

  defp assert_unsigned(conn), do: assert(get_resp_header(conn, "x-qory-signature-ed25519") == [])

  defp apiary_public_key, do: SigningKey.apiary_public_key()

  describe "a code accepted" do
    test "makes the key awaiting approval and answers 201, signed, with its id and node", %{
      scope: scope,
      node: node
    } do
      %{row: row, code: code} = code(scope, node)
      pair = ed25519_key_pair()
      body = body(code, pair)

      conn = enrol(body)
      assert conn.status == 201
      answer = assert_signed(conn, body)

      key = Repo.get_by!(AccessKey, public_key: pair.public_key)

      assert answer == %{
               "version" => 1,
               "access_key_id" => key.key_id,
               "node_id" => node.public_id,
               "node_kind" => "node",
               "approved" => false,
               "stored_secrets" => false,
               "apiary_public_key" => apiary_public_key()
             }

      # The members in the contract's order.
      assert conn.resp_body =~ ~r/\A\{"version":1,"access_key_id":"ak_[a-z0-9]{16}","node_id":/

      assert AccessKey.status(key) == :pending
      assert key.node_id == node.id
      assert key.arrived_by == :code
      assert key.enrolment_code_id == row.id
      assert key.label == "build-01"
      assert key.created_by_id == scope.user.id
      assert AccessKey.verify_integrity(key) == :ok

      used = Repo.get!(EnrolmentCode, row.id)
      assert used.used_by_key_id == key.key_id
      assert used.public_key == pair.public_key
      assert %DateTime{} = used.used_at
      assert EnrolmentCode.verify_integrity(used) == :ok

      assert %PublicKey{state: :pending, key_id: key_id} = Repo.get(PublicKey, pair.public_key)
      assert key_id == key.key_id
    end

    test "leaves the entry of the key's arrival, by the key, never the code or the proof", %{
      scope: scope,
      node: node
    } do
      %{row: row, code: code} = code(scope, node)
      pair = ed25519_key_pair()
      body = body(code, pair)
      assert enrol(body).status == 201
      key = Repo.get_by!(AccessKey, public_key: pair.public_key)

      assert [entry] =
               Repo.all(
                 from e in Entry,
                   where: e.subject_kind == "access_key" and e.subject_id == ^key.id
               )

      assert entry.action == "access_key.add"
      assert {entry.actor_kind, entry.actor_id} == {:access_key, key.id}
      assert entry.workspace_id == node.workspace_id
      assert entry.remote_ip == "127.0.0.1"

      assert entry.after == %{
               "label" => "build-01",
               "key_id" => key.key_id,
               "fingerprint" => Ed25519.fingerprint(pair.public_key),
               "allow_secrets" => false,
               "arrived_by" => "code"
             }

      assert entry.details == %{"node_id" => node.public_id, "code_id" => row.id}

      dump = inspect(entry)
      %{"proof" => proof} = Jason.decode!(body)
      refute dump =~ String.slice(code, 4, 26)
      refute dump =~ proof
    end

    test "carries the code's stored-secrets flag and label hint, and a pool's kind", %{
      scope: scope
    } do
      pool = pool_fixture(scope)
      %{code: code} = code(scope, pool, %{allow_secrets: true, label_hint: "spot-runners"})
      pair = ed25519_key_pair()
      body = body(code, pair, name: "ip-10-0-0-1")

      conn = enrol(body)
      assert conn.status == 201
      answer = assert_signed(conn, body)
      assert answer["node_id"] == pool.public_id
      assert answer["node_kind"] == "pool"
      assert answer["stored_secrets"] == true

      key = Repo.get_by!(AccessKey, public_key: pair.public_key)
      assert key.allow_secrets
      assert key.label == "spot-runners"
    end

    test "a label a key of the node in use has already gets -2, -3 and on", %{
      scope: scope,
      node: node
    } do
      node_key_fixture(scope, node, %{label: "build-01"})

      %{code: code} = code(scope, node)
      pair = ed25519_key_pair()
      assert enrol(body(code, pair)).status == 201
      assert Repo.get_by!(AccessKey, public_key: pair.public_key).label == "build-01-2"
    end
  end

  describe "the code refused, 401 unsigned" do
    setup %{scope: scope, node: node} do
      Map.put(code(scope, node), :pair, ed25519_key_pair())
    end

    defp assert_unauthorized(conn) do
      assert conn.status == 401
      assert conn.resp_body == ~s({"error":"unauthorized"})
      assert_unsigned(conn)
    end

    test "a code used, by another key", %{code: code, pair: pair} do
      assert enrol(body(code, pair)).status == 201
      assert_unauthorized(enrol(body(code, ed25519_key_pair())))
    end

    test "a code expired", %{row: row, code: code, pair: pair} do
      row
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      |> EnrolmentCode.put_integrity()
      |> Repo.update!()

      assert_unauthorized(enrol(body(code, pair)))
    end

    test "a code cancelled", %{scope: scope, row: row, code: code, pair: pair} do
      {:ok, _} = AccessKeys.cancel_code(scope, row)
      assert_unauthorized(enrol(body(code, pair)))
    end

    test "a code never made, a code of another server's key, and a code with two fingerprints",
         %{code: code, pair: pair} do
      [head, fingerprint] = String.split(code, ".")
      other = "qec_" <> String.duplicate("0", 26) <> "." <> fingerprint
      assert_unauthorized(enrol(body(other, pair)))

      foreign = head <> "." <> Ed25519.fingerprint(ed25519_key_pair().public_key)
      assert_unauthorized(enrol(body(foreign, pair)))

      rotation = code <> "." <> Ed25519.fingerprint(ed25519_key_pair().public_key)
      assert_unauthorized(enrol(body(rotation, pair)))

      # The code itself is untouched: it still enrols.
      assert enrol(body(code, pair)).status == 201
    end

    test "a code of a deleted node", %{scope: scope, node: node, code: code, pair: pair} do
      {:ok, _} = Nodes.delete_node(scope, node)
      assert_unauthorized(enrol(body(code, pair)))
    end

    test "a code of a workspace marked for deletion", %{scope: scope, node: node, pair: pair} do
      workspace = workspace_fixture(scope.organisation)
      other = %{scope | workspace: workspace}
      %{code: code} = code(other, node_fixture(other))
      {:ok, _} = Deletion.delete_workspace(scope, workspace.id, workspace.slug)
      assert_unauthorized(enrol(body(code, pair)))
      _ = node
    end

    @tag :capture_log
    test "a code row changed outside the application", %{row: row, code: code, pair: pair} do
      Repo.update_all(from(c in EnrolmentCode, where: c.id == ^row.id),
        set: [allow_secrets: true]
      )

      assert_unauthorized(enrol(body(code, pair)))
    end
  end

  describe "the key refused, 409 key_invalid signed" do
    setup %{scope: scope, node: node} do
      Map.put(code(scope, node), :pair, ed25519_key_pair())
    end

    defp assert_key_invalid(conn, body) do
      assert conn.status == 409

      assert assert_signed(conn, body) == %{
               "error" => "key_invalid",
               "apiary_public_key" => apiary_public_key()
             }
    end

    defp assert_code_unused(row) do
      assert %EnrolmentCode{used_at: nil, used_by_key_id: nil, public_key: nil} =
               Repo.get!(EnrolmentCode, row.id)
    end

    test "a proof that does not verify", %{row: row, code: code, pair: pair} do
      other = ed25519_key_pair()
      # Signed by another key than the one the body carries.
      body = body(code, other, public_key: pair.encoded)
      assert_key_invalid(enrol(body), body)
      assert_code_unused(row)
    end

    test "a proof over other lines than the body's", %{row: row, code: code, pair: pair} do
      signed = body(code, pair, name: "build-02") |> Jason.decode!()
      body = body(code, pair, proof: signed["proof"])
      assert_key_invalid(enrol(body), body)
      assert_code_unused(row)
    end

    test "a timestamp more than 300 seconds from the server's clock, either way", %{
      row: row,
      code: code,
      pair: pair
    } do
      now = System.os_time(:second)

      for timestamp <- [now - 400, now + 400] do
        body = body(code, pair, timestamp: timestamp)
        assert_key_invalid(enrol(body), body)
      end

      assert_code_unused(row)
      assert enrol(body(code, pair, timestamp: now - 250)).status == 201
    end

    test "a key the ledger holds already", %{scope: scope, node: node, row: row, code: code} do
      %{pair: pair} = node_key_fixture(scope, node_fixture(scope))
      body = body(code, pair)
      assert_key_invalid(enrol(body), body)
      assert_code_unused(row)
      assert Repo.aggregate(from(k in AccessKey, where: k.node_id == ^node.id), :count) == 0
    end

    test "a key of small order, and the torsion key", %{row: row, code: code, pair: pair} do
      for encoded <- [
            "xxdqcD1N2E-6PAt2DRBnDyogU_osOczGTsf9d5KsA3o",
            "AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "KH9r2npX9PKHPzv_Xl6pwmCmpjQ73zfHq800btWQTBE"
          ] do
        body = body(code, pair, public_key: encoded)
        assert_key_invalid(enrol(body), body)
      end

      assert_code_unused(row)
    end
  end

  describe "the node full, 409 key_limit signed" do
    test "while it holds a key awaiting approval", %{scope: scope, node: node} do
      pending_key_fixture(scope, node)
      %{row: row, code: code} = code(scope, node)
      body = body(code, ed25519_key_pair())

      conn = enrol(body)
      assert conn.status == 409

      assert assert_signed(conn, body) == %{
               "error" => "key_limit",
               "apiary_public_key" => apiary_public_key()
             }

      assert Repo.get!(EnrolmentCode, row.id).used_at == nil
    end

    test "while it holds two approved keys", %{scope: scope, node: node} do
      node_key_fixture(scope, node)
      node_key_fixture(scope, node)
      %{code: code} = code(scope, node)
      body = body(code, ed25519_key_pair())

      conn = enrol(body)
      assert conn.status == 409
      assert assert_signed(conn, body)["error"] == "key_limit"
    end

    test "but not while it holds one approved key", %{scope: scope, node: node} do
      node_key_fixture(scope, node)
      %{code: code} = code(scope, node)
      assert enrol(body(code, ed25519_key_pair())).status == 201
    end
  end

  describe "the same code again" do
    setup %{scope: scope, node: node} do
      Map.put(code(scope, node), :pair, ed25519_key_pair())
    end

    test "with the same public key, within the lifetime, is the same answer and changes nothing",
         %{row: row, code: code, pair: pair} do
      first = body(code, pair)
      assert enrol(first).status == 201
      key = Repo.get_by!(AccessKey, public_key: pair.public_key)
      used = Repo.get!(EnrolmentCode, row.id)
      entries = Repo.aggregate(Entry, :count)

      again = body(code, pair, timestamp: System.os_time(:second) + 1, name: "other-name")
      conn = enrol(again)
      assert conn.status == 201
      answer = assert_signed(conn, again)
      assert answer["access_key_id"] == key.key_id
      assert answer["approved"] == false

      assert Repo.aggregate(from(k in AccessKey, where: k.node_id == ^key.node_id), :count) == 1
      assert Repo.get!(EnrolmentCode, row.id) == used
      assert Repo.aggregate(Entry, :count) == entries
    end

    test "answers the key as it is now: approved once approved", %{
      scope: scope,
      code: code,
      pair: pair
    } do
      assert enrol(body(code, pair)).status == 201
      key = Repo.get_by!(AccessKey, public_key: pair.public_key)
      {:ok, _} = AccessKeys.approve(scope, key)

      again = body(code, pair)
      conn = enrol(again)
      assert conn.status == 201
      assert assert_signed(conn, again)["approved"] == true
    end

    test "still needs a proof that verifies, and a fresh timestamp", %{code: code, pair: pair} do
      assert enrol(body(code, pair)).status == 201

      stale = body(code, pair, timestamp: System.os_time(:second) - 400)
      assert enrol(stale).status == 409

      forged = body(code, ed25519_key_pair(), public_key: pair.encoded)
      assert enrol(forged).status == 409
    end

    test "is 401 once the key is rejected, or the code's lifetime is over", %{
      scope: scope,
      row: row,
      code: code,
      pair: pair
    } do
      assert enrol(body(code, pair)).status == 201
      key = Repo.get_by!(AccessKey, public_key: pair.public_key)
      {:ok, _} = AccessKeys.reject(scope, key)
      assert enrol(body(code, pair)).status == 401

      %{row: row2, code: code2} = code(scope, node_fixture(scope))
      pair2 = ed25519_key_pair()
      assert enrol(body(code2, pair2)).status == 201

      row2
      |> Repo.reload!()
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      |> EnrolmentCode.put_integrity()
      |> Repo.update!()

      assert enrol(body(code2, pair2)).status == 401
      _ = row
    end
  end

  describe "a request the schema refuses, 400 unsigned" do
    setup %{scope: scope, node: node} do
      Map.put(code(scope, node), :pair, ed25519_key_pair())
    end

    defp assert_invalid(conn, names) do
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_request", "names" => names}
      assert_unsigned(conn)
    end

    test "names the members at fault, and changes nothing", %{row: row, code: code, pair: pair} do
      valid = body(code, pair) |> Jason.decode!()

      for {change, names} <- [
            {&Map.put(&1, "version", 2), ["version"]},
            {&Map.put(&1, "version", 1.0), ["version"]},
            {&Map.put(&1, "code", String.downcase(&1["code"])), ["code"]},
            {&Map.put(&1, "code", String.replace(&1["code"], ".", "-", global: false)), ["code"]},
            {&Map.put(&1, "name", "-build"), ["name"]},
            {&Map.put(&1, "name", String.duplicate("a", 65)), ["name"]},
            {&Map.put(&1, "public_key", &1["public_key"] <> "="), ["public_key"]},
            {&Map.put(&1, "timestamp", 1.7e9), ["timestamp"]},
            {&Map.put(&1, "timestamp", -1), ["timestamp"]},
            {&Map.put(&1, "timestamp", Integer.pow(2, 53)), ["timestamp"]},
            {&Map.put(&1, "timestamp", "1700000000"), ["timestamp"]},
            {&Map.delete(&1, "proof"), ["proof"]},
            {&Map.put(&1, "proof", String.slice(&1["proof"], 1..-1//1)), ["proof"]}
          ] do
        assert_invalid(enrol(Jason.encode!(change.(valid))), names)
      end

      assert Repo.get!(EnrolmentCode, row.id).used_at == nil
    end

    test "a member the schema does not define, a member twice, or not an object", %{
      code: code,
      pair: pair
    } do
      valid = body(code, pair)
      assert_invalid(enrol(String.replace(valid, "{", ~s({"extra":1,), global: false)), [])

      twice = String.replace(valid, "{", ~s({"name":"build-02",), global: false)
      assert_invalid(enrol(twice), ["name"])

      for body <- ["", "[]", "null", "{", ~s("x")], do: assert_invalid(enrol(body), [])
    end

    test "an X-Qory-Contract-Version absent or not served", %{code: code, pair: pair} do
      for version <- [nil, "2", "x"] do
        conn = enrol(body(code, pair), version: version)
        assert conn.status == 400
        assert Jason.decode!(conn.resp_body)["error"] == "unsupported_contract_version"
        assert_unsigned(conn)
      end
    end

    test "a body over 8 KiB is 413", %{code: code, pair: pair} do
      body = body(code, pair)
      conn = enrol(body <> String.duplicate(" ", 8 * 1024))
      assert conn.status == 413
      assert_unsigned(conn)
    end
  end

  test "the endpoint answers POST alone" do
    assert get(build_conn(), @path).status == 404
  end

  test "nothing of the request reaches the log", %{scope: scope, node: node} do
    %{code: code} = code(scope, node)
    pair = ed25519_key_pair()
    body = body(code, pair)
    %{"proof" => proof} = Jason.decode!(body)

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        assert enrol(body).status == 201
        assert enrol(body(code, ed25519_key_pair())).status == 401
      end)

    refute log =~ String.slice(code, 4, 26)
    refute log =~ proof
    refute log =~ pair.encoded
  end
end
