defmodule Apiary.Contract.SignedFixturesTest do
  @moduledoc """
  Replays `fixtures/signed/*.json` of the server contract: one signed request per
  file, under the published key and secret, with the status a receiver answers.
  The fixtures are signed around the second 1700000000, where a receiver under
  test sets its clock; the clock is in the application environment, so this
  module is not async.
  """
  use ApiaryWeb.ConnCase, async: false

  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Repo
  alias Apiary.Runs.Event

  @moduletag :contract

  @clock 1_700_000_000
  @served ["/.well-known/qory-configuration", "/v1/events", "/v1/run-configuration"]

  # Every file whose target is served is replayed; a file named here is not.
  @skipped []

  @files (case Apiary.ContractFixtures.contract_dir() do
            nil -> []
            dir -> dir |> Path.join("fixtures/signed/*.json") |> Path.wildcard() |> Enum.sort()
          end)

  setup do
    Application.put_env(:apiary, :contract_now, fn -> @clock end)
    on_exit(fn -> Application.delete_env(:apiary, :contract_now) end)

    %{scope: scope} = sign_up_fixture()
    published_key_fixture(scope)
    # A hive serves a run configuration once somebody has made its policy; an instance
    # without the security feature serves none, and its fixtures are left out below.
    if Apiary.Features.on?(:security),
      do: {:ok, _rule} = Apiary.Policy.allow(scope, nil, %{host: "api.example"})

    %{scope: scope}
  end

  defp replay(%{"method" => method, "target" => target, "headers" => headers, "body" => body}) do
    headers = Enum.map(headers, fn {name, value} -> {String.downcase(name), value} end)

    build_conn()
    |> Map.put(:req_headers, headers)
    |> dispatch(ApiaryWeb.Endpoint, method |> String.downcase() |> String.to_atom(), target, body)
  end

  defp served?(%{"target" => target}), do: URI.parse(target).path in @served

  test "the fixtures are there, and the ones expected" do
    names = Enum.map(@files, &Path.basename/1)
    assert "batch-valid.json" in names
    assert "get-configuration-valid.json" in names
    assert "get-run-configuration-valid.json" in names
    for name <- @skipped, do: assert(name in names)
  end

  for file <- @files, Path.basename(file) not in @skipped do
    @file_path file
    # The run configuration is the security feature's: absent, not answered, without it.
    if file
       |> File.read!()
       |> Jason.decode!()
       |> Map.fetch!("target")
       |> URI.parse()
       |> Map.fetch!(:path) == "/v1/run-configuration",
       do: @tag(needs: :security)

    test "#{Path.basename(file)} is answered as the contract expects" do
      fixture = @file_path |> File.read!() |> Jason.decode!()

      if served?(fixture) do
        conn = replay(fixture)
        assert conn.status == fixture["expect"], fixture["note"]

        if conn.status == 401 do
          assert conn.resp_body == ~s({"error":"unauthorized"})
          assert Repo.aggregate(Event, :count) == 0
        end
      end
    end
  end

  test "every fixture's target is served" do
    for file <- @files do
      assert file |> File.read!() |> Jason.decode!() |> served?(), Path.basename(file)
    end
  end

  @tag needs: :security
  test "get-run-configuration-valid: the answer is a run configuration under its digest" do
    fixture =
      contract_dir()
      |> Path.join("fixtures/signed/get-run-configuration-valid.json")
      |> File.read!()
      |> Jason.decode!()

    conn = replay(fixture)
    assert conn.status == 200
    assert :ok = Apiary.Policy.Schema.validate(conn.resp_body)

    [digest] = Plug.Conn.get_resp_header(conn, "x-qory-run-configuration")
    assert digest == Apiary.Policy.Render.digest(conn.resp_body)
    assert Plug.Conn.get_resp_header(conn, "etag") == [~s("#{digest}")]
  end

  test "batch-valid and then batch-replayed: both 202, nothing stored twice" do
    [valid, replayed] =
      for name <- ["batch-valid.json", "batch-replayed.json"] do
        contract_dir() |> Path.join("fixtures/signed/#{name}") |> File.read!() |> Jason.decode!()
      end

    assert replay(valid).status == 202
    count = Repo.aggregate(Event, :count)
    assert count == valid["body"] |> Jason.decode!() |> length()

    assert replay(replayed).status == 202
    assert Repo.aggregate(Event, :count) == count
  end

  test "fixtures/batch/*.json, signed here with the published secret, are accepted" do
    for file <- contract_dir() |> Path.join("fixtures/batch/*.json") |> Path.wildcard() do
      body = File.read!(file)
      conn = signed_post(build_conn(), published_key_id(), published_secret(), body)
      assert conn.status == 202, Path.basename(file)
    end
  end

  test "fixtures/invalid/batch-*.json are refused as no batch" do
    for file <- contract_dir() |> Path.join("fixtures/invalid/batch-*.json") |> Path.wildcard() do
      body = File.read!(file)
      conn = signed_post(build_conn(), published_key_id(), published_secret(), body)
      assert conn.status == 400, Path.basename(file)
    end
  end
end
