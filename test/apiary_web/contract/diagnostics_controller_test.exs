defmodule ApiaryWeb.Contract.DiagnosticsControllerTest do
  # A diagnostics key, end to end: an instance admin makes its code
  # (`Apiary.AccessKeys.create_diagnostics_code/2`), the computer enrols the key at the
  # enrolment endpoint, and `GET /v1/runs/<run id>/diagnostics`, signed with it, answers
  # any run of the instance (`ApiaryWeb.Contract.DiagnosticsController`). The key passes
  # no other route's check, and no other kind of key passes this route's. Its making,
  # its use and its revocation, with their Activity entries and its limit. Not async: the
  # instance admin's test hides the instance's organisation, a row every test shares.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.{AccessKeys, DiagnosticsSchema, Repo, SigningKey}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Audit.Entry
  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.Nodes.{Instance, Node}
  alias Apiary.Runs.Run

  @enrolment "/.well-known/qory-enrolment"

  setup do
    _hidden = Apiary.EditionKit.hide_instance_organisation()
    # The first sign-up makes the instance organisation, whose trail has the entries.
    %{scope: admin} = sign_up_fixture()
    true = Apiary.Access.instance_admin?(admin)
    instance = Apiary.Edition.instance_organisation_id()
    ^instance = admin.organisation.id
    # Signed in just now: making a code asks for a recent sign-in.
    admin = put_in(admin.user.authenticated_at, DateTime.utc_now())
    %{admin: admin, instance: instance}
  end

  # The enrolment request `qory apiary enrol` sends, for a fresh key pair: the answer's
  # conn, and the pair.
  defp enrol(code, opts \\ []) do
    pair = Apiary.AccessKeysFixtures.ed25519_key_pair()
    name = Keyword.get(opts, :name, "laptop")
    timestamp = System.os_time(:second)
    message = SignedMessage.enrolment(code, pair.encoded, name, timestamp)
    proof = :crypto.sign(:eddsa, :none, message, [pair.secret, :ed25519]) |> Ed25519.encode()

    body =
      Jason.encode!(%{
        version: 1,
        code: code,
        name: name,
        public_key: pair.encoded,
        timestamp: timestamp,
        proof: proof
      })

    conn =
      build_conn()
      |> Map.put(:remote_ip, Keyword.get(opts, :remote_ip, {127, 0, 0, 1}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-qory-contract-version", "1")
      |> post(@enrolment, body)

    {conn, pair}
  end

  # A diagnostics key, enrolled: the key as stored, and the seed that signs as it.
  defp diagnostics_key!(admin, opts \\ []) do
    {:ok, _row, code} = AccessKeys.create_diagnostics_code(admin, %{label_hint: opts[:label]})
    {conn, pair} = enrol(code <> "." <> SigningKey.fingerprint(), opts)
    assert conn.status == 201, conn.resp_body
    %{"access_key_id" => key_id} = Jason.decode!(conn.resp_body)
    %{key: Repo.get_by!(AccessKey, key_id: key_id), seed: pair.secret}
  end

  defp diagnose(key_id, seed, run_id, opts \\ []),
    do: signed_get(build_conn(), key_id, seed, "/v1/runs/#{run_id}/diagnostics", opts)

  describe "the key" do
    test "is made with a code on the computer: the instance keeps its public half, in the instance's node",
         %{admin: admin, instance: instance} do
      {:ok, row, code} = AccessKeys.create_diagnostics_code(admin, %{label_hint: "laptop"})
      assert "qecd_" <> _ = code
      refute row.allow_secrets

      {conn, pair} = enrol(code <> "." <> SigningKey.fingerprint())
      assert conn.status == 201

      assert %{"node_kind" => "diagnostics", "node_id" => "dg_" <> _ = node_id} =
               answer = Jason.decode!(conn.resp_body)

      assert answer["stored_secrets"] == false

      key = Repo.get_by!(AccessKey, key_id: answer["access_key_id"])
      assert key.public_key == pair.public_key
      assert key.label == "laptop"
      assert key.created_by_id == admin.user.id
      assert is_nil(key.organisation_id) and is_nil(key.workspace_id)

      node = Repo.get!(Node, key.node_id)
      assert %Node{kind: :diagnostics, public_id: ^node_id, organisation_id: nil} = node
      assert AccessKeys.diagnostics_scope(%{key | node: node}) == :instance

      # The second code uses the same node.
      %{key: second} = diagnostics_key!(admin)
      assert second.node_id == node.id

      # Its code and its key, in the instance organisation's trail, said as a diagnostics
      # key's.
      entries =
        Repo.all(
          from e in Entry,
            where: e.organisation_id == ^instance,
            where: e.action in ["access_key.create_code", "access_key.add"],
            order_by: [asc: e.inserted_at]
        )

      assert [_, _, _, _] = entries
      for entry <- entries, do: assert(entry.details["node_id"] == node_id)
    end

    test "is made and read by an instance admin alone", %{admin: admin} do
      %{scope: owner} = sign_up_fixture()
      refute Apiary.Access.instance_admin?(owner)

      assert AccessKeys.create_diagnostics_code(owner) == {:error, :forbidden}
      assert AccessKeys.list_diagnostics_keys(owner) == []
      assert AccessKeys.diagnostics_node(owner) == nil

      %{key: key} = diagnostics_key!(admin)
      assert AccessKeys.revoke_diagnostics_key(owner, key) == {:error, :forbidden}
      assert [%AccessKey{}] = AccessKeys.list_diagnostics_keys(admin)
    end

    test "is revoked by an instance admin, with an entry, and is refused from then on",
         %{admin: admin, instance: instance} do
      %{key: key, seed: seed} = diagnostics_key!(admin)
      run = run_fixture(scope_fixture(), %{public_id: Run.new_public_id()})
      assert diagnose(key.key_id, seed, run.public_id).status == 200

      # The paths of another kind's keys do not reach it.
      assert {:error, :not_found} = AccessKeys.revoke_access_key(admin, key)

      assert {:ok, %AccessKey{revoked_at: %DateTime{}}} =
               AccessKeys.revoke_diagnostics_key(admin, key)

      assert {:ok, %AccessKey{}} = AccessKeys.revoke_diagnostics_key(admin, key)
      assert AccessKeys.list_diagnostics_keys(admin) == []

      conn = diagnose(key.key_id, seed, run.public_id)
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}

      assert [%Entry{details: %{"node_id" => "dg_" <> _, "reason" => "revoked"}}] =
               Repo.all(
                 from e in Entry,
                   where: e.organisation_id == ^instance and e.action == "access_key.revoke"
               )
    end

    test "is held to the limit of keys the instance holds", %{admin: admin} do
      limit = AccessKeys.diagnostics_key_limit()

      for n <- 1..limit, do: diagnostics_key!(admin, remote_ip: {10, 0, 0, n})

      {:ok, _row, code} = AccessKeys.create_diagnostics_code(admin)
      {conn, _pair} = enrol(code <> "." <> SigningKey.fingerprint(), remote_ip: {10, 0, 1, 1})
      assert conn.status == 409
      assert Jason.decode!(conn.resp_body)["error"] == "key_limit"
      assert length(AccessKeys.list_diagnostics_keys(admin)) == limit
    end
  end

  # A refusal of the signed check: 401, unsigned, the one body for every cause.
  defp assert_unauthorized(conn) do
    assert conn.status == 401
    assert get_resp_header(conn, "x-qory-signature-ed25519") == []
    assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}
  end

  describe "GET /v1/runs/<run id>/diagnostics" do
    setup %{admin: admin} do
      %{key: key, seed: seed} = diagnostics_key!(admin)
      %{scope: other} = sign_up_fixture()
      run = run_fixture(other, %{public_id: Run.new_public_id()})
      events_fixture(run, [{1, "run.started", %{"note" => "ok"}}])
      %{key: key, seed: seed, run: run}
    end

    test "answers any run of the instance, signed, with its log and machine logs, and records the use",
         %{key: key, seed: seed, run: run} do
      assert is_nil(key.last_used_at)

      conn = diagnose(key.key_id, seed, run.public_id, user_agent: "qory/0.9.0")
      assert conn.status == 200
      assert signed_answer?(conn)
      assert [<<"application/json", _::binary>>] = get_resp_header(conn, "content-type")

      document = Jason.decode!(conn.resp_body)
      assert DiagnosticsSchema.validate(DiagnosticsSchema.root(), document) == :ok
      assert document["run"]["id"] == run.public_id
      assert document["machine_logs"] == []
      assert document["log"] == %{"text" => "", "truncated" => false}

      key = Repo.get!(AccessKey, key.id)
      assert %DateTime{} = key.last_used_at
      # No instance is recorded as seen on the diagnostics node: it runs nothing.
      refute Repo.exists?(from i in Instance, where: i.node_id == ^key.node_id)
    end

    test "a run id of no run, or outside the form, is not found",
         %{key: key, seed: seed, run: run} do
      for id <- [Run.new_public_id(), "not-a-run", run.id] do
        conn = diagnose(key.key_id, seed, id)
        assert conn.status == 404, id
        assert signed_answer?(conn)
        assert Jason.decode!(conn.resp_body) == %{"error" => "not_found"}
      end
    end

    test "refuses a stale request, a bad signature and a contract version not served",
         %{key: key, seed: seed, run: run} do
      other = Apiary.AccessKeysFixtures.ed25519_key_pair()

      # The same unsigned 401 for every cause.
      for conn <- [
            diagnose(key.key_id, seed, run.public_id,
              timestamp: ApiaryWeb.Contract.SignedRequest.now() - 1_000
            ),
            diagnose(key.key_id, other.secret, run.public_id),
            diagnose(AccessKey.generate_key_id(), seed, run.public_id)
          ] do
        assert_unauthorized(conn)
      end

      conn = diagnose(key.key_id, seed, run.public_id, contract_version: "2")
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] == "unsupported_contract_version"
    end

    test "refuses every other kind of key", %{run: run} do
      %{scope: scope} = sign_up_fixture()

      %{access_key: node_key, secret: node_seed} =
        Apiary.AccessKeysFixtures.access_key_fixture(scope)

      gateway = Apiary.NodesFixtures.gateway_fixture(scope)

      %{access_key: gateway_key, secret: gateway_seed} =
        contract_key_fixture(scope, node: gateway)

      pool = Apiary.NodesFixtures.pool_fixture(scope)

      %{access_key: pool_key, pair: pool_pair} =
        Apiary.AccessKeysFixtures.node_key_fixture(scope, pool)

      for {key, seed} <- [
            {node_key, node_seed},
            {gateway_key, gateway_seed},
            {pool_key, pool_pair.secret}
          ] do
        conn = diagnose(key.key_id, seed, run.public_id)
        assert conn.status == 401, inspect(Repo.get!(Node, key.node_id).kind)
        assert_unauthorized(conn)
      end
    end

    @tag needs: :factory
    test "refuses an adapter's key", %{admin: admin, run: run} do
      {:ok, adapter} = Apiary.Adapters.create_adapter(admin, %{name: "acme-tracker"})

      %{access_key: key, pair: pair} =
        Apiary.AccessKeysFixtures.enrolled_key_fixture(admin, adapter)

      assert_unauthorized(diagnose(key.key_id, pair.secret, run.public_id))
    end

    test "the key passes no other signed route", %{key: key, seed: seed, run: run} do
      routes =
        for %{verb: verb, path: path, plug: plug} <- Phoenix.Router.routes(ApiaryWeb.Router),
            String.starts_with?(path, "/v1/") or path == "/.well-known/qory-configuration",
            path != "/v1/runs/:run_id/diagnostics",
            do: {verb, path, plug}

      assert length(routes) > 20

      for {verb, path, plug} <- routes do
        target =
          path
          |> String.replace(":run_id", run.public_id)
          |> String.replace(":dispatch_id", "dp_0000000000000000")

        conn =
          case verb do
            :get ->
              signed_get(build_conn(), key.key_id, seed, target)

            :post ->
              type =
                if path == "/v1/events",
                  do: "application/cloudevents-batch+json",
                  else: "application/json"

              signed_post(build_conn(), key.key_id, seed, "{}",
                target: target,
                content_type: type
              )
          end

        # Refused by the signed check, or, for a route of a feature the instance does not
        # have, not found before any check.
        gated? = not is_nil(ApiaryWeb.Features.gate(plug))
        assert conn.status == 401 or (gated? and conn.status == 404), "#{verb} #{path}"
        refute conn.status in 200..299
      end
    end

    test "the key relays no enrolment, as a gateway's key does", %{key: key, seed: seed} do
      body = ~s({"version":1})

      relayed = fn key_id, seed ->
        signature = sign_request(seed, key_id, instance_id(), "POST", @enrolment, body)

        Plug.Test.conn(:post, @enrolment, body)
        |> Plug.Conn.assign(:raw_body, body)
        |> put_req_header("x-qory-access-key-id", key_id)
        |> put_req_header("x-qory-instance-id", instance_id())
        |> put_req_header("x-qory-signature-ed25519", signature)
        |> ApiaryWeb.Contract.SignedRequest.relayed()
      end

      assert relayed.(key.key_id, seed) == :unauthorized

      %{scope: scope} = sign_up_fixture()
      gateway = Apiary.NodesFixtures.gateway_fixture(scope)

      %{access_key: gateway_key, secret: gateway_seed} =
        contract_key_fixture(scope, node: gateway)

      assert {:ok, %AccessKey{}} = relayed.(gateway_key.key_id, gateway_seed)
    end
  end
end
