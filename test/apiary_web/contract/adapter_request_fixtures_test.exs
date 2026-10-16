defmodule ApiaryWeb.Contract.AdapterRequestFixturesTest do
  # `ApiaryWeb.Contract.AdapterRequest` against the integration contract's signed requests,
  # vendored from the commit in `.integration-contract-ref` under
  # `test/fixtures/integration-contract/adapter/signed/`: a POST and a GET signed under the
  # access key of `keys.json` at 2026-10-15T12:00:00Z verify under that key, held on an
  # adapter, with the contract's clock set to that second; each is fresh up to 300 seconds
  # either way and not after; each sent again is a replay. And the declaration's route
  # where the feature is off. Not async: the clock and the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Repo
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Contract.Ed25519
  alias ApiaryWeb.Contract.AdapterRequest

  @moduletag needs: :factory

  @fixtures Path.expand("../../fixtures/integration-contract/adapter/signed", __DIR__)
  # 2026-10-15T12:00:00Z, the second every signed fixture is signed at.
  @signed_at 1_792_065_600

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp set_clock(seconds), do: Application.put_env(:apiary, :contract_now, fn -> seconds end)

  setup do
    on_exit(fn -> Application.delete_env(:apiary, :contract_now) end)
    set_clock(@signed_at)

    adapter = adapter_fixture(name: "Acme tracker")
    admin = instance_admin_scope()
    %{"access_key" => entry} = fixture("keys.json")
    "qak_" <> encoded = entry["secret"]
    {:ok, seed} = Ed25519.decode(encoded, 32)
    {public_key, _secret} = :crypto.generate_key(:eddsa, :ed25519, seed)
    {:ok, ^public_key} = Ed25519.decode(entry["public_key"], 32)

    # The fixture key, held on the adapter as the instance under test holds it: written
    # straight into the table, past the key checks, which refuse every fixture key.
    key =
      %AccessKey{
        id: Ecto.UUID.generate(),
        organisation_id: nil,
        workspace_id: nil,
        node_id: adapter.id,
        key_id: entry["access_key_id"],
        public_key: public_key,
        created_by_id: admin.user.id,
        arrived_by: :browser,
        received_at: DateTime.utc_now()
      }
      |> AccessKey.insert_changeset(%{allow_secrets: false, label: "integration fixture"})
      |> AccessKey.put_integrity()
      |> Repo.insert!()

    %{adapter: adapter, key: key, seed: seed, instance_id: entry["instance_id"]}
  end

  # The fixture's request as a conn that reached the plug: its method, target, headers and
  # raw body exactly as written.
  defp request(%{"method" => method, "target" => target, "headers" => headers} = fixture) do
    body = fixture["body"]

    conn =
      Enum.reduce(headers, build_conn(method, target, nil), fn {name, value}, conn ->
        Plug.Conn.put_req_header(conn, String.downcase(name), value)
      end)

    if is_binary(body), do: Plug.Conn.assign(conn, :raw_body, body), else: conn
  end

  defp call(fixture), do: fixture |> request() |> AdapterRequest.call([])

  describe "the contract's signed POST" do
    test "verifies under the fixture key, and its body's time is accepted once", ctx do
      fixture = fixture("post-source-items.json")
      conn = call(fixture)

      refute conn.halted
      assert conn.assigns.access_key.id == ctx.key.id
      assert conn.assigns.instance_id == ctx.instance_id
      assert conn.assigns.contract_version == 1

      time = DateTime.from_unix!(@signed_at)
      assert {:ok, accepted} = AdapterRequest.accept(conn, time)
      assert accepted.private.adapter_request_accepted
      assert %DateTime{} = Repo.get!(AccessKey, ctx.key.id).last_used_at

      # The same request again verifies, and is a replay.
      assert AdapterRequest.accept(call(fixture), time) == :unauthorized
    end

    test "its time is fresh 300 seconds either way, and not past them", _ctx do
      fixture = fixture("post-source-items.json")
      time = DateTime.from_unix!(@signed_at)

      for offset <- [-301, 301] do
        set_clock(@signed_at + offset)
        assert AdapterRequest.accept(call(fixture), time) == :unauthorized, "#{offset}"
      end

      set_clock(@signed_at + 300)
      assert {:ok, _} = AdapterRequest.accept(call(fixture), time)
    end

    test "a body changed by one byte does not verify", _ctx do
      fixture = fixture("post-source-items.json")
      conn = call(%{fixture | "body" => fixture["body"] <> " "})
      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "the contract's signed GET" do
    test "verifies with its timestamp, once", ctx do
      fixture = fixture("get-changes.json")
      conn = call(fixture)

      refute conn.halted
      assert conn.assigns.access_key.id == ctx.key.id
      assert %DateTime{} = Repo.get!(AccessKey, ctx.key.id).last_used_at

      replayed = call(fixture)
      assert replayed.halted
      assert replayed.status == 401
      assert Jason.decode!(replayed.resp_body) == %{"error" => "unauthorized"}
    end

    test "its timestamp is fresh 300 seconds either way, and not past them", _ctx do
      fixture = fixture("get-changes.json")

      for offset <- [-301, 301] do
        set_clock(@signed_at + offset)
        conn = call(fixture)
        assert {conn.halted, conn.status} == {true, 401}, "#{offset}"
      end

      set_clock(@signed_at - 300)
      refute call(fixture).halted
    end

    test "a timestamp other than the one signed does not verify", _ctx do
      fixture = fixture("get-changes.json")
      headers = Map.put(fixture["headers"], "X-Qory-Timestamp", "#{@signed_at + 1}")
      set_clock(@signed_at + 1)
      conn = call(%{fixture | "headers" => headers})
      assert {conn.halted, conn.status} == {true, 401}
    end
  end

  describe "where the feature is off" do
    # The adapter and its key are made while the feature is on, then it is turned off.
    setup do
      made = connectable_adapter_fixture()
      previous = Application.get_env(:apiary, :features)
      {:ok, features} = Apiary.Features.parse("observability,security")
      Application.put_env(:apiary, :features, features)
      on_exit(fn -> Application.put_env(:apiary, :features, previous) end)
      made
    end

    test "a verified declaration is answered 404 not_found, signed, and stores nothing",
         %{adapter: adapter, access_key: key, pair: pair} do
      refute Apiary.Features.on?(:factory)

      body = %{
        "version" => 1,
        "time" => @signed_at |> DateTime.from_unix!() |> DateTime.to_iso8601(),
        "connect_url" => "https://tracker-adapter.acme.example/connect",
        "sync" => %{
          "default_interval" => 900,
          "minimum_interval" => 300,
          "sends_changes" => false
        }
      }

      conn =
        signed_post(build_conn(), key.key_id, pair.secret, body,
          target: "/v1/adapter",
          content_type: "application/json",
          delivery: nil
        )

      assert json_response(conn, 404) == %{"error" => "not_found"}
      assert signed_answer?(conn)
      assert Repo.get!(Apiary.Nodes.Node, adapter.id).sync_default_interval == nil
      assert Repo.aggregate("adapter_seen_requests", :count) == 0
    end
  end
end
