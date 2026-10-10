defmodule Apiary.Contract.SignedFixturesTest do
  @moduledoc """
  Replays the contract's signed requests, `fixtures/signed/*.json` of Forager's
  contract directory at the commit in `.forager-contract-ref`: one request per file, signed
  with Ed25519 under the contract's fixture access key, with the status a receiver answers
  and, for a coded refusal, its code. The receiver holds the fixture access key under
  `ak_f1xt0re000000000` on a node, and sets its clock to the second the fixtures are
  signed around, 1700000000. The clock is in the application
  environment, so this module is not async.

  The registrations are a sequence, in the order of their names: a fixture that the
  contract says is replayed after another is replayed after it here
  (`@replayed_after`), each test on a database of its own.

  Every answer is checked for its signature too: a `401`, and a refusal before
  verification, go out unsigned; every other answer is signed under the instance's key
  (`Apiary.SigningKey`), bound to the request's signature.
  """
  use ApiaryWeb.ConnCase, async: false

  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{ContractSchema, Repo, SigningKey}
  alias Apiary.Runs.{Event, Projector, Run}

  @moduletag :contract

  @clock 1_700_000_000
  @served ["/.well-known/qory-configuration", "/v1/events", "/v1/runs"]
  @run "0191f2a4-3c5e-7b8d-9e0f-1a2b3c4d5e6f"

  # The fixtures each is replayed after, as its note says: the first acceptance of the run
  # (register-replayed), then the repeat of it (register-valid), then the reload.
  # register-instance-limit's node allows one live instance, the fixture instance's run.
  @replayed_after %{
    "register-valid.json" => ["register-replayed.json"],
    "register-run-id-used.json" => ["register-replayed.json"],
    "register-instance-limit.json" => ["register-replayed.json"],
    "reload-valid.json" => ["register-replayed.json", "register-valid.json"]
  }

  # Every file whose target is served is replayed; a file named here is not.
  @skipped []

  @fixtures signed_fixtures()

  setup do
    Application.put_env(:apiary, :contract_now, fn -> @clock end)
    on_exit(fn -> Application.delete_env(:apiary, :contract_now) end)

    %{scope: scope} = sign_up_fixture()
    node = node_fixture(scope)
    fixture_access_key!(scope, node, "access_key")

    # A workspace serves a run configuration once somebody has made its policy; an
    # instance without the security feature serves none, and its fixtures are left out
    # below.
    if Apiary.Features.on?(:security),
      do: {:ok, _rule} = Apiary.Policy.allow(scope, nil, %{host: "api.example"})

    %{scope: scope, node: node}
  end

  # A header the fixture sends twice is a list of its values, each sent.
  defp replay(%{"method" => method, "target" => target, "headers" => headers, "body" => body}) do
    headers =
      Enum.flat_map(headers, fn
        {name, values} when is_list(values) -> Enum.map(values, &{String.downcase(name), &1})
        {name, value} -> [{String.downcase(name), value}]
      end)

    build_conn()
    |> Map.put(:req_headers, headers)
    |> dispatch(ApiaryWeb.Endpoint, method |> String.downcase() |> String.to_atom(), target, body)
  end

  defp served?(%{"target" => target}) do
    path = URI.parse(target).path
    path in @served or path == "/v1/runs/" <> @run
  end

  # Refused before verification: a header the signature depends on sent twice.
  defp before_verification?(%{"headers" => headers}),
    do: Enum.any?(headers, fn {_name, value} -> is_list(value) end)

  defp fixture!(name) do
    {^name, fixture} = List.keyfind(@fixtures, name, 0)
    fixture
  end

  test "the fixtures are there, and the ones expected" do
    names = Enum.map(@fixtures, &elem(&1, 0))
    assert length(names) == 16

    for name <-
          ~w(batch-valid.json batch-replayed.json batch-tampered.json batch-unknown-key.json
             get-configuration-valid.json get-configuration-stale.json
             get-configuration-bad-signature.json get-configuration-header-twice.json
             get-configuration-no-instance-id.json register-valid.json
             register-replayed.json register-run-id-used.json register-instance-limit.json
             register-stale.json register-interval-too-long.json reload-valid.json),
        do: assert(name in names, name)

    for {name, before} <- @replayed_after, other <- [name | before], do: assert(other in names)

    for name <- @skipped, do: assert(name in names)
  end

  for {name, _fixture} <- @fixtures, name not in @skipped do
    @name name
    # A reload is answered only where the workspace serves a run configuration, which is
    # the security feature's: without it, no reload is answered.
    if String.starts_with?(name, "reload-"), do: @tag(needs: :security)

    test "#{name} is answered as the contract expects" do
      fixture = fixture!(@name)
      assert served?(fixture)

      for before <- Map.get(@replayed_after, @name, []),
          do: assert(replay(fixture!(before)).status == 200, before)

      conn = replay(fixture)
      assert conn.status == fixture["expect"], fixture["note"]

      if code = fixture["expect_code"],
        do: assert(Jason.decode!(conn.resp_body)["error"] == code, fixture["note"])

      cond do
        conn.status == 401 ->
          assert conn.resp_body == ~s({"error":"unauthorized"})
          assert unsigned_answer?(conn)
          assert Repo.aggregate(Event, :count) == 0

        before_verification?(fixture) ->
          assert unsigned_answer?(conn)

        true ->
          assert signed_answer?(conn), fixture["note"]
      end
    end
  end

  test "every fixture's target is served" do
    for {name, fixture} <- @fixtures, do: assert(served?(fixture), name)
  end

  test "get-configuration-valid: the document names the key's node and the instance's key",
       %{node: node} do
    conn = replay(fixture!("get-configuration-valid.json"))
    assert conn.status == 200
    document = Jason.decode!(conn.resp_body)

    assert document["node_id"] == node.public_id
    assert document["apiary_public_key"] == SigningKey.apiary_public_key()
    assert :ok = ContractSchema.validate(configuration_schema(), document)

    [digest] = Plug.Conn.get_resp_header(conn, "x-qory-configuration")
    assert digest == ApiaryWeb.Contract.Configuration.digest(conn.resp_body)
  end

  test "register-replayed, then register-valid: one run, the same answer again", %{node: node} do
    first = replay(fixture!("register-replayed.json"))
    assert first.status == 200
    assert :ok = Apiary.Policy.Schema.validate(first.resp_body)

    [digest] = Plug.Conn.get_resp_header(first, "x-qory-run-configuration")
    assert digest == Apiary.Policy.Render.digest(first.resp_body)
    assert Plug.Conn.get_resp_header(first, "etag") == [~s("#{digest}")]

    # The run, registered under the fixture access key, on its node, from the instance the
    # request claimed, projected from sequence 1.
    run = Repo.one!(Run)
    assert run.run_id == @run
    assert run.node_id == node.id
    assert run.instance_id == instance_id()
    assert run.projected_sequence == 1
    assert run.registration_labels == %{"forge" => "github.com", "repository" => "acme/shop"}

    again = replay(fixture!("register-valid.json"))
    assert again.status == 200
    assert again.resp_body == first.resp_body

    for header <- ~w(x-qory-run-configuration etag x-qory-configuration),
        do: assert(get_resp_header(again, header) == get_resp_header(first, header), header)

    assert Repo.aggregate(Run, :count) == 1
  end

  @tag needs: :security
  test "reload-valid: the run's own run configuration, under the registration's digest" do
    registered = replay(fixture!("register-valid.json"))
    assert registered.status == 200

    conn = replay(fixture!("reload-valid.json"))
    assert conn.status == 200
    assert conn.resp_body == registered.resp_body

    for header <- ~w(x-qory-run-configuration etag x-qory-configuration),
        do: assert(get_resp_header(conn, header) == get_resp_header(registered, header), header)
  end

  test "the refused registrations store no run" do
    for name <- ~w(register-stale.json register-interval-too-long.json) do
      assert replay(fixture!(name)).status in [400, 401], name
      assert Repo.aggregate(Run, :count) == 0, name
    end

    assert replay(fixture!("register-replayed.json")).status == 200
    assert replay(fixture!("register-run-id-used.json")).status == 409
    assert replay(fixture!("register-instance-limit.json")).status == 409
    assert Repo.all(Run) |> Enum.map(& &1.run_id) == [@run]
  end

  test "fixtures/run-registration/*.json, signed here at their time, are registered" do
    %{seed: seed, access_key_id: key_id} = fixture_key!("access_key")
    files = contract_dir() |> Path.join("fixtures/run-registration/*.json") |> Path.wildcard()
    assert files != []

    for file <- files do
      body = File.read!(file)
      {:ok, time, 0} = DateTime.from_iso8601(Jason.decode!(body)["time"])
      Application.put_env(:apiary, :contract_now, fn -> DateTime.to_unix(time) end)

      conn = signed_register(build_conn(), key_id, seed, body)
      assert conn.status == 200, Path.basename(file)
      assert signed_answer?(conn), Path.basename(file)
    end
  end

  test "fixtures/invalid/run-registration-*.json are refused, signed, as invalid_request" do
    %{seed: seed, access_key_id: key_id} = fixture_key!("access_key")
    pattern = Path.join(contract_dir(), "fixtures/invalid/run-registration-*.json")
    files = Path.wildcard(pattern)
    assert files != []

    for file <- files do
      conn = signed_register(build_conn(), key_id, seed, File.read!(file))
      assert %{"error" => "invalid_request"} = json_response(conn, 400), Path.basename(file)
      assert signed_answer?(conn)
    end

    assert Repo.aggregate(Run, :count) == 0
  end

  test "fixtures/invalid/configuration-*.json fail the schema the discovery document passes" do
    document = replay(fixture!("get-configuration-valid.json")).resp_body |> Jason.decode!()
    assert :ok = ContractSchema.validate(configuration_schema(), document)

    pattern = Path.join(contract_dir(), "fixtures/invalid/configuration-*.json")
    files = Path.wildcard(pattern)
    assert Enum.any?(files, &(Path.basename(&1) == "configuration-run-url-query.json"))

    for file <- files do
      assert {:error, _} =
               ContractSchema.validate(configuration_schema(), Jason.decode!(File.read!(file))),
             Path.basename(file)
    end
  end

  test "batch-valid and then batch-replayed: both 202, nothing stored twice", %{node: node} do
    valid = fixture!("batch-valid.json")
    replayed = fixture!("batch-replayed.json")

    assert replay(valid).status == 202
    count = Repo.aggregate(Event, :count)
    assert count == valid["body"] |> Jason.decode!() |> length()

    # The run is on the key's node, from the instance the request claimed.
    run = Repo.one!(Run)
    assert run.node_id == node.id
    assert run.instance_id == instance_id()

    assert replay(replayed).status == 202
    assert Repo.aggregate(Event, :count) == count
  end

  test "fixtures/batch/*.json, signed here under the fixture access key, are accepted" do
    %{seed: seed, access_key_id: key_id} = fixture_key!("access_key")

    for file <- contract_dir() |> Path.join("fixtures/batch/*.json") |> Path.wildcard() do
      conn = signed_post(build_conn(), key_id, seed, File.read!(file))
      assert conn.status == 202, Path.basename(file)
      assert signed_answer?(conn), Path.basename(file)
    end
  end

  test "the batches of a run a gateway opened: no session, and it ends cancelled when quiet, lost when the gateway was lost, or as its starter said" do
    %{seed: seed, access_key_id: key_id} = fixture_key!("access_key")

    project = fn files ->
      Repo.delete_all(Run)

      for file <- files do
        conn = signed_post(build_conn(), key_id, seed, contract_file!("batch/" <> file))
        assert conn.status == 202, file
      end

      {:ok, run} = Projector.project(Repo.one!(Run))
      run
    end

    run = project.(["gateway-first.json", "gateway-quiet.json"])

    assert run.opened_by == "gateway"
    assert Run.no_session?(run)
    assert {run.runtime, run.command, run.host} == {nil, nil, nil}
    assert run.labels["run_key"] == "rk-0001"
    assert {run.state, run.reason, run.quiet_seconds} == {"cancelled", "quiet", 1800}
    assert {run.exit_code, run.duration_ms} == {nil, 1_804_900}

    run = project.(["gateway-first.json", "gateway-lost.json"])

    assert run.opened_by == "gateway"

    assert {run.state, run.reason, run.quiet_seconds, run.exit_code} ==
             {"lost", "gateway_lost", nil, nil}

    assert run.lost_at == run.exited_at

    run = project.(["gateway-first.json", "gateway-outcome.json"])

    assert {run.opened_by, run.state, run.reason, run.exit_code} ==
             {"gateway", "completed", "all_checks_passed", nil}
  end

  test "the exits of a session's run: its starter's outcome and reason, or stopped with no outcome" do
    %{seed: seed, access_key_id: key_id} = fixture_key!("access_key")

    for {file, expected} <- [
          {"session-outcome.json", {"failed", "checks_failed", 0}},
          {"session-stopped.json", {"cancelled", "stopped", -1}}
        ] do
      Repo.delete_all(Run)

      for batch <- ["first.json", file] do
        conn = signed_post(build_conn(), key_id, seed, contract_file!("batch/" <> batch))
        assert conn.status == 202, batch
      end

      {:ok, run} = Projector.project(Repo.one!(Run))
      assert run.opened_by == "session"
      assert {run.state, run.reason, run.exit_code} == expected, file
    end
  end

  test "a refusal of the server's with its status is stored as sent, a code the list does not hold included" do
    %{seed: seed, access_key_id: key_id} = fixture_key!("access_key")

    for {file, code} <- [
          {"refused-not-found.json", "not_found"},
          {"refused-unlisted-server-code.json", "example_server_code"}
        ] do
      Repo.delete_all(Run)
      conn = signed_post(build_conn(), key_id, seed, contract_file!("batch/" <> file))
      assert conn.status == 202, file

      assert [%Event{type: "dev.qory.run.refused", data: data}] = Repo.all(Event)
      assert data == %{"code" => code, "status" => 404}, file
    end
  end

  test "fixtures/invalid/batch-*.json are refused, signed, as invalid_request" do
    %{seed: seed, access_key_id: key_id} = fixture_key!("access_key")

    for file <- contract_dir() |> Path.join("fixtures/invalid/batch-*.json") |> Path.wildcard() do
      conn = signed_post(build_conn(), key_id, seed, File.read!(file))
      assert json_response(conn, 400) == %{"error" => "invalid_request"}, Path.basename(file)
      assert signed_answer?(conn)
    end
  end

  # The record's registration is never posted: a batch that holds one is refused.
  test "fixtures/invalid/event-registered-interval-too-long.json, as a batch, is invalid_request" do
    %{seed: seed, access_key_id: key_id} = fixture_key!("access_key")
    registered = contract_json!("invalid/event-registered-interval-too-long.json")
    assert registered["type"] == "dev.qory.run.registered"

    conn = signed_post(build_conn(), key_id, seed, [registered])
    assert json_response(conn, 400) == %{"error" => "invalid_request"}
    assert signed_answer?(conn)
    assert Repo.aggregate(Run, :count) == 0
  end

  defp configuration_schema,
    do: ContractSchema.schema!(contract_dir(), "configuration.schema.json")
end
