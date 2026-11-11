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
  alias Apiary.Contract.{Ed25519, Enrolment, SignedMessage}
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

    conn =
      build_conn()
      |> Map.put(:remote_ip, Keyword.get(opts, :remote_ip, {127, 0, 0, 1}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-qory-contract-version", "1")
      |> post(@enrolment, enrolment_body(code, pair, name))

    {conn, pair}
  end

  # The signed body of an enrolment request.
  defp enrolment_body(code, pair, name) do
    timestamp = System.os_time(:second)
    message = SignedMessage.enrolment(code, pair.encoded, name, timestamp)
    proof = :crypto.sign(:eddsa, :none, message, [pair.secret, :ed25519]) |> Ed25519.encode()

    Jason.encode!(%{
      version: 1,
      code: code,
      name: name,
      public_key: pair.encoded,
      timestamp: timestamp,
      proof: proof
    })
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

      assert AccessKeys.create_diagnostics_code(owner) == {:error, :not_found}
      assert AccessKeys.list_diagnostics_keys(owner) == []
      assert AccessKeys.diagnostics_node(owner) == nil

      %{key: key} = diagnostics_key!(admin)
      assert AccessKeys.revoke_diagnostics_key(owner, key) == {:error, :not_found}
      assert [%AccessKey{}] = AccessKeys.list_diagnostics_keys(admin)
    end

    test "its code enrols nothing once its maker is no longer an instance admin",
         %{admin: admin} do
      {:ok, _row, code} = AccessKeys.create_diagnostics_code(admin)
      # Another admin first: the instance keeps one.
      {:ok, _} = Apiary.Organisations.grant_instance_admin(member_fixture(admin).user)
      {:ok, _} = Apiary.Organisations.revoke_instance_admin(admin.user)

      {conn, _pair} = enrol(code <> "." <> SigningKey.fingerprint())

      assert conn.status == 401
      refute Repo.get_by(AccessKey, created_by_id: admin.user.id)
    end

    # The maker's check asks `diagnostics_key.create`, of the feature `observability`, and
    # not `adapter.setup`: under QORY_FEATURES=observability, `factory` is off.
    @tag :feature_sets
    @tag needs: :observability
    test "its code enrols with observability on, with factory on or off", %{admin: admin} do
      unless Apiary.Features.on?(:factory) do
        assert Apiary.Access.authorize(admin, :"adapter.setup", admin.organisation) ==
                 {:error, :not_found}
      end

      {:ok, _row, code} = AccessKeys.create_diagnostics_code(admin)

      {conn, _pair} = enrol(code <> "." <> SigningKey.fingerprint())

      assert conn.status == 201, conn.resp_body
    end

    # The maker's check asks `diagnostics_key.create`, whose feature went after the code was
    # made, as across a restart.
    @tag :feature_sets
    @tag needs: :observability
    test "its code made with observability on does not enrol with it off", %{admin: admin} do
      {:ok, _row, code} = AccessKeys.create_diagnostics_code(admin)
      pair = Apiary.AccessKeysFixtures.ed25519_key_pair()

      {:ok, request} =
        Enrolment.decode(enrolment_body(code <> "." <> SigningKey.fingerprint(), pair, "laptop"))

      previous = Application.get_env(:apiary, :features)
      on_exit(fn -> Application.put_env(:apiary, :features, previous) end)
      Application.put_env(:apiary, :features, Apiary.Features.enabled() -- [:observability])

      assert AccessKeys.enrol(request) == {:error, :unauthorized}
      refute Repo.get_by(AccessKey, created_by_id: admin.user.id)
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

    test "returns a run by its rn_ id, a run of another organisation too",
         %{admin: admin, key: key, seed: seed, run: run} do
      # The run is in the organisation of another sign-up than the key's admin.
      refute run.organisation_id == admin.organisation.id

      conn = diagnose(key.key_id, seed, run.public_id)
      assert conn.status == 200
      assert signed_answer?(conn)
      assert Jason.decode!(conn.resp_body)["run"]["id"] == run.public_id
    end

    test "answers a run of a workspace marked for deletion", %{key: key, seed: seed} do
      %{scope: other} = sign_up_fixture()
      workspace = workspace_fixture(other.organisation)
      run = run_fixture(workspace_scope(other.user, workspace), %{public_id: Run.new_public_id()})
      {:ok, _marked} = Apiary.Deletion.delete_workspace(other, workspace.id, workspace.slug)

      conn = diagnose(key.key_id, seed, run.public_id)
      assert conn.status == 200, conn.resp_body
      assert Jason.decode!(conn.resp_body)["run"]["id"] == run.public_id
    end

    # A number is unique only in its workspace, and the key reads every workspace.
    test "a run's number is not found, as a number of no run",
         %{key: key, seed: seed, run: run} do
      assert is_integer(run.number)

      for id <- [
            Integer.to_string(run.number),
            "99999999",
            "9223372036854775808",
            "0",
            "-#{run.number}",
            "%23#{run.number}",
            "Run%20#{run.number}"
          ] do
        conn = diagnose(key.key_id, seed, id)
        assert conn.status == 404, id
        assert signed_answer?(conn)
        assert Jason.decode!(conn.resp_body) == %{"error" => "not_found"}
      end
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
            {verb, path} not in [{:get, "/v1/runs/:run_id/diagnostics"}, {:get, "/v1/runs"}],
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

  describe "GET /v1/runs" do
    setup %{admin: admin} do
      %{key: key, seed: seed} = diagnostics_key!(admin)
      %{scope: scope} = sign_up_fixture()
      %{scope: other} = sign_up_fixture()
      %{key: key, seed: seed, scope: scope, other: other}
    end

    defp list(key, seed, query, opts \\ []) do
      target = if query == "", do: "/v1/runs", else: "/v1/runs?" <> query
      signed_get(build_conn(), key.key_id, seed, target, opts)
    end

    # The answer's page, signed and valid under the run list's schema.
    defp page!(conn) do
      assert conn.status == 200, conn.resp_body
      assert signed_answer?(conn)
      assert [<<"application/json", _::binary>>] = get_resp_header(conn, "content-type")
      page = Jason.decode!(conn.resp_body)
      assert DiagnosticsSchema.validate(DiagnosticsSchema.runs(), page) == :ok
      page
    end

    # A refusal of the query, signed and valid under the refusal's schema.
    defp refused!(conn, parameter) do
      assert conn.status == 400, conn.resp_body
      assert signed_answer?(conn)
      body = Jason.decode!(conn.resp_body)
      assert DiagnosticsSchema.validate(DiagnosticsSchema.runs_refusal(), body) == :ok
      assert body == %{"error" => "invalid_request", "parameter" => parameter}
    end

    defp ids(page), do: Enum.map(page["runs"], & &1["id"])

    defp run_at!(scope, at, attrs \\ %{}) do
      run_fixture(scope, Map.merge(%{public_id: Run.new_public_id(), inserted_at: at}, attrs))
    end

    defp workspace(scope), do: "workspace=#{scope.organisation.slug}%2F#{scope.workspace.slug}"

    test "lists the runs of every organisation, signed, and records only the key's use",
         %{key: key, seed: seed, scope: scope, other: other} do
      first = run_at!(scope, ~U[2026-11-01 08:00:00.000000Z])
      second = run_at!(other, ~U[2026-11-01 09:00:00.000000Z], %{state: "running"})
      entries = Repo.aggregate(Entry, :count)

      page = page!(list(key, seed, "", user_agent: "qory/0.9.0"))
      assert ids(page) == [second.public_id, first.public_id]
      assert page["next"] == nil

      assert [%{"organisation" => %{"slug" => slug}, "workspace" => workspace} | _] =
               page["runs"]

      assert slug == other.organisation.slug
      assert workspace == %{"id" => other.workspace.public_id, "slug" => other.workspace.slug}
      assert %DateTime{} = Repo.get!(AccessKey, key.id).last_used_at
      # No read of a run is recorded.
      assert Repo.aggregate(Entry, :count) == entries
    end

    test "filters by workspace, state and since",
         %{key: key, seed: seed, scope: scope, other: other} do
      a = run_at!(scope, ~U[2026-11-01 08:00:00.000000Z], %{state: "completed"})
      b = run_at!(scope, ~U[2026-11-01 09:00:00.000000Z], %{state: "failed"})
      c = run_at!(other, ~U[2026-11-01 10:00:00.000000Z], %{state: "failed"})

      assert ids(page!(list(key, seed, workspace(scope)))) == [b.public_id, a.public_id]
      assert ids(page!(list(key, seed, "state=failed"))) == [c.public_id, b.public_id]

      assert ids(page!(list(key, seed, workspace(other) <> "&state=failed"))) ==
               [c.public_id]

      assert ids(page!(list(key, seed, "since=2026-11-01T09:00:00Z"))) ==
               [c.public_id, b.public_id]

      assert ids(page!(list(key, seed, "since=2026-11-01T09:00:00.000000001Z"))) ==
               [c.public_id]

      # A state no run has is an empty page.
      assert page!(list(key, seed, "state=cancelled")) == %{"runs" => [], "next" => nil}
    end

    @tag needs: :factory
    test "filters by workflow and work item", %{key: key, seed: seed, scope: scope} do
      place = Apiary.DispatchedRunsFixtures.handover_place_fixture(scope)

      %{run: run, dispatch_run: queued} =
        Apiary.DispatchedRunsFixtures.handed_over_fixture(scope, place.key)

      {1, _} =
        Repo.update_all(
          from(h in Apiary.Harnesses.RunHarness, where: h.dispatch_run_id == ^queued.id),
          set: [state: :resolved, origin: :none, workflow: "hello"]
        )

      number = Repo.get!(Apiary.WorkItems.WorkItem, queued.work_item_id).number
      _plain = run_at!(scope, DateTime.add(run.inserted_at, 1, :second))

      assert ids(page!(list(key, seed, "workflow=hello"))) == [run.public_id]
      assert page!(list(key, seed, "workflow=other"))["runs"] == []

      assert [row] = page!(list(key, seed, workspace(scope) <> "&work_item=#{number}"))["runs"]
      assert row["id"] == run.public_id
      assert row["workflow"] == "hello"
      assert row["work_item_number"] == number
      assert is_binary(row["work_item_title"])

      assert page!(list(key, seed, workspace(scope) <> "&work_item=#{number + 1}"))["runs"] ==
               []
    end

    test "pages with before and next across runs created at the same time",
         %{key: key, seed: seed, scope: scope, other: other} do
      at = ~U[2026-11-01 10:00:00.123456Z]
      run_at!(scope, at, %{public_id: "rn_000000000000000a"})
      run_at!(other, at, %{public_id: "rn_000000000000000b"})
      run_at!(scope, at, %{public_id: "rn_000000000000000c"})
      earlier = run_at!(other, DateTime.add(at, -1, :second))

      first = page!(list(key, seed, "limit=2"))
      assert ids(first) == ["rn_000000000000000c", "rn_000000000000000b"]
      assert first["next"] == "rn_000000000000000b"

      second = page!(list(key, seed, "limit=2&before=" <> first["next"]))
      assert ids(second) == ["rn_000000000000000a", earlier.public_id]
      assert second["next"] == nil
    end

    test "has 25 rows by default and 100 at most", %{key: key, seed: seed, scope: scope} do
      now = DateTime.utc_now()
      for n <- 1..101, do: run_at!(scope, DateTime.add(now, -n, :second))

      default = page!(list(key, seed, ""))
      assert length(default["runs"]) == 25
      assert default["next"] == List.last(default["runs"])["id"]

      most = page!(list(key, seed, "limit=100"))
      assert length(most["runs"]) == 100
      assert most["next"] == List.last(most["runs"])["id"]

      refused!(list(key, seed, "limit=101"), "limit")
    end

    test "refuses each parameter that breaks its rule, with its name",
         %{key: key, seed: seed, scope: scope} do
      run_at!(scope, DateTime.utc_now())

      for {query, parameter} <- [
            {"status=running", "status"},
            {"state=running&state=failed", "state"},
            {"limit=", "limit"},
            {"=1", ""},
            {"limit=0", "limit"},
            {"work_item=7", "work_item"},
            {workspace(scope) <> "&work_item=9223372036854775808", "work_item"},
            {"workspace=example", "workspace"},
            {"workspace=#{scope.organisation.slug}%2Fno-such-workspace", "workspace"},
            {"workflow=Hello", "workflow"},
            {"state=waiting", "state"},
            {"since=2026-11-01T00:00:60Z", "since"},
            {"before=rn_short", "before"},
            {"before=" <> Run.new_public_id(), "before"},
            {"a%01b=1", "a\u{FFFD}b"}
          ] do
        refused!(list(key, seed, query), parameter)
      end
    end

    test "refuses every other kind of key, and a revoked diagnostics key",
         %{admin: admin, key: key, seed: seed, scope: scope} do
      %{access_key: node_key, secret: node_seed} =
        Apiary.AccessKeysFixtures.access_key_fixture(scope)

      gateway = Apiary.NodesFixtures.gateway_fixture(scope)

      %{access_key: gateway_key, secret: gateway_seed} =
        contract_key_fixture(scope, node: gateway)

      pool = Apiary.NodesFixtures.pool_fixture(scope)

      %{access_key: pool_key, pair: pool_pair} =
        Apiary.AccessKeysFixtures.node_key_fixture(scope, pool)

      for {other, other_seed} <- [
            {node_key, node_seed},
            {gateway_key, gateway_seed},
            {pool_key, pool_pair.secret}
          ] do
        conn = list(other, other_seed, "limit=1")
        assert conn.status == 401, inspect(Repo.get!(Node, other.node_id).kind)
        assert_unauthorized(conn)
      end

      assert page!(list(key, seed, "limit=1"))
      assert {:ok, %AccessKey{}} = AccessKeys.revoke_diagnostics_key(admin, key)
      assert_unauthorized(list(key, seed, "limit=1"))
      # The query is read after the signed check: a bad one gets the same 401.
      assert_unauthorized(list(key, seed, "limit=0"))
    end

    @tag needs: :factory
    test "refuses an adapter's key", %{admin: admin} do
      {:ok, adapter} = Apiary.Adapters.create_adapter(admin, %{name: "acme-tracker"})

      %{access_key: key, pair: pair} =
        Apiary.AccessKeysFixtures.enrolled_key_fixture(admin, adapter)

      assert_unauthorized(list(key, pair.secret, "limit=1"))
    end

    test "checks run.list_instance through Apiary.Access before it lists the runs",
         %{key: key, seed: seed} do
      assert page!(list(key, seed, "limit=1"))

      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ListsNoRuns)
      assert_unauthorized(list(key, seed, "limit=1"))
    end

    # Under the contract, a query that is not valid UTF-8 after percent-decoding gets 400
    # with a body the contract does not define. Plug's query decoding raises a 400 error
    # (`Plug.Conn.InvalidQueryError`) before the router, so no parameter is refused.
    test "refuses a query that is not valid UTF-8 without invalid_request",
         %{key: key, seed: seed} do
      {400, _headers, body} = assert_error_sent(400, fn -> list(key, seed, "a%FFb=1") end)
      refute body =~ "invalid_request"
    end

    # The router logs a route's dispatch at debug with its parameters, the query's among
    # them; the run list's route is not logged. The run diagnostics route, which is, shows
    # that the capture sees the line.
    test "logs no parameters of the query", %{key: key, seed: seed, scope: scope} do
      run = run_at!(scope, DateTime.utc_now())
      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)

      shown =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert diagnose(key.key_id, seed, run.public_id).status == 200
        end)

      assert shown =~ ~s(Parameters: %{"run_id" => "#{run.public_id}"})

      listed =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          page!(list(key, seed, workspace(scope) <> "&before=" <> run.public_id))
        end)

      # Neither the router's lines nor the debug lines of the page's database queries.
      # The key's lookup and the record of its use are logged, and contain neither value.
      refute listed =~ "Processing with"
      refute listed =~ "Parameters"
      assert listed =~ "QUERY OK"
      refute listed =~ run.public_id
      refute listed =~ ~s("#{scope.workspace.slug}")
      refute listed =~ ~s("#{scope.organisation.slug}")
    end

    # The features are the node's: observability, which every other needs, cannot be
    # left out of a set the tag parses, so the test switches it off for its run.
    @tag with_features: [:observability]
    test "is not found without the observability feature", %{key: key, seed: seed} do
      Application.put_env(:apiary, :features, [])

      conn = list(key, seed, "limit=1")
      assert conn.status == 404
      refute conn.resp_body =~ "runs"
    end
  end
end
