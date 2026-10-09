defmodule Apiary.Contract.SignedFixturesTest do
  @moduledoc """
  Replays the contract's signed requests, `fixtures/signed/*.json` of Forager's
  contract directory at the commit in `.forager-contract-ref`: one request per file, signed
  with Ed25519 under the contract's fixture access key, with the status a receiver answers
  and, for a coded refusal, its code. The receiver holds the fixture access key under
  `ak_f1xt0re000000000` on a node, and sets its clock to the second the fixtures are
  signed around, 1700000000. The clock is in the application
  environment, so this module is not async.

  Every answer is checked for its signature too: a `401`, and a refusal before
  verification, go out unsigned; every other answer is signed under the instance's key
  (`Apiary.SigningKey`), bound to the request's signature.
  """
  use ApiaryWeb.ConnCase, async: false

  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{ContractSchema, Repo, SigningKey}
  alias Apiary.Runs.{Event, Run}

  @moduletag :contract

  @clock 1_700_000_000
  @served ["/.well-known/qory-configuration", "/v1/events", "/v1/run-configuration"]

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

  defp served?(%{"target" => target}), do: URI.parse(target).path in @served

  # Refused before verification: a header the signature depends on sent twice.
  defp before_verification?(%{"headers" => headers}),
    do: Enum.any?(headers, fn {_name, value} -> is_list(value) end)

  defp fixture!(name) do
    {^name, fixture} = List.keyfind(@fixtures, name, 0)
    fixture
  end

  test "the fixtures are there, and the ones expected" do
    names = Enum.map(@fixtures, &elem(&1, 0))
    assert length(names) == 11

    for name <-
          ~w(batch-valid.json batch-replayed.json batch-tampered.json batch-unknown-key.json
             get-configuration-valid.json get-configuration-stale.json
             get-configuration-bad-signature.json get-configuration-header-twice.json
             get-configuration-no-instance-id.json get-run-configuration-valid.json
             get-run-configuration-labels-valid.json),
        do: assert(name in names, name)

    for name <- @skipped, do: assert(name in names)
  end

  for {name, fixture} <- @fixtures, name not in @skipped do
    @name name
    # The run configuration is the security feature's: absent, not answered, without it.
    if fixture |> Map.fetch!("target") |> URI.parse() |> Map.fetch!(:path) ==
         "/v1/run-configuration",
       do: @tag(needs: :security)

    test "#{name} is answered as the contract expects" do
      fixture = fixture!(@name)
      assert served?(fixture)

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

  @tag needs: :security
  test "get-run-configuration-valid: the answer is a run configuration under its digest" do
    conn = replay(fixture!("get-run-configuration-valid.json"))
    assert conn.status == 200
    assert :ok = Apiary.Policy.Schema.validate(conn.resp_body)

    [digest] = Plug.Conn.get_resp_header(conn, "x-qory-run-configuration")
    assert digest == Apiary.Policy.Render.digest(conn.resp_body)
    assert Plug.Conn.get_resp_header(conn, "etag") == [~s("#{digest}")]
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

  test "fixtures/invalid/batch-*.json are refused, signed, as invalid_request" do
    %{seed: seed, access_key_id: key_id} = fixture_key!("access_key")

    for file <- contract_dir() |> Path.join("fixtures/invalid/batch-*.json") |> Path.wildcard() do
      conn = signed_post(build_conn(), key_id, seed, File.read!(file))
      assert json_response(conn, 400) == %{"error" => "invalid_request"}, Path.basename(file)
      assert signed_answer?(conn)
    end
  end

  test "fixtures/invalid/event-ping-interval-too-long.json, as a batch, is invalid_request" do
    %{seed: seed, access_key_id: key_id} = fixture_key!("access_key")
    ping = contract_json!("invalid/event-ping-interval-too-long.json")
    assert ping["data"]["interval_seconds"] > 300

    conn = signed_post(build_conn(), key_id, seed, [ping])
    assert json_response(conn, 400) == %{"error" => "invalid_request"}
    assert signed_answer?(conn)
    assert Repo.aggregate(Run, :count) == 0
  end

  defp configuration_schema,
    do: ContractSchema.schema!(contract_dir(), "configuration.schema.json")
end
