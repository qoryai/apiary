defmodule ApiaryWeb.Contract.ChangesHoldTest do
  # `GET /v1/work-items/changes` against the contract's signed GET and its signed answer,
  # byte for byte, with the contract's clock set to the second they are signed at; and the
  # hold: a read with nothing after its cursor waits for an entry that commits, up to the
  # hold, and answers nothing once the hold passes. Not async: the clock and the hold are
  # the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.ContractFixtures, only: [signed_get: 5, signed_answer?: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures, only: [instance_admin_scope: 0]

  alias Apiary.Repo
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Adapters.Feed
  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias ApiaryWeb.Contract.ChangesController

  @moduletag needs: :factory

  @fixtures Path.expand("../../fixtures/integration-contract/adapter", __DIR__)
  # 2026-10-15T12:00:00Z, the second every signed fixture is signed at.
  @signed_at 1_792_065_600

  defp fixture(path), do: @fixtures |> Path.join(path) |> File.read!() |> Jason.decode!()

  defp entry(change), do: Map.new(change, fn {k, v} -> {String.to_existing_atom(k), v} end)

  defp append!(adapter, entries) do
    Repo.transaction(fn -> for e <- List.wrap(entries), do: Feed.append(adapter, e) end)
  end

  describe "the contract's signed GET and answer" do
    # `signed/get-changes.json` reads after c_00000040 under the fixture access key, and
    # `signed/answer-changes.json` is its answer: the six entries of `changes/feed.json`,
    # ending at c_00000046, signed under the fixture server key.
    setup do
      Application.put_env(:apiary, :contract_now, fn -> @signed_at end)
      on_exit(fn -> Application.delete_env(:apiary, :contract_now) end)

      adapter = adapter_fixture()
      %{"access_key" => entry} = fixture("signed/keys.json")
      "qak_" <> encoded = entry["secret"]
      {:ok, seed} = Ed25519.decode(encoded, 32)
      {public_key, _secret} = :crypto.generate_key(:eddsa, :ed25519, seed)

      # The fixture key, held on the adapter as the instance under test holds it: written
      # straight into the table, past the key checks, which refuse every fixture key.
      %AccessKey{
        id: Ecto.UUID.generate(),
        organisation_id: nil,
        workspace_id: nil,
        node_id: adapter.id,
        key_id: entry["access_key_id"],
        public_key: public_key,
        created_by_id: instance_admin_scope().user.id,
        arrived_by: :browser,
        received_at: DateTime.utc_now()
      }
      |> AccessKey.insert_changeset(%{allow_secrets: false, label: "integration fixture"})
      |> AccessKey.put_integrity()
      |> Repo.insert!()

      %{adapter: adapter}
    end

    test "is answered with the fixture's body, byte for byte, and its signature", %{
      adapter: adapter
    } do
      append!(adapter, for(i <- 1..40, do: %{kind: "sync", interval: 60 + i}))
      append!(adapter, Enum.map(fixture("changes/feed.json")["changes"], &entry/1))

      request = fixture("signed/get-changes.json")
      answer = fixture("signed/answer-changes.json")

      conn =
        request["headers"]
        |> Enum.reduce(build_conn(), fn {name, value}, conn ->
          put_req_header(conn, String.downcase(name), value)
        end)
        |> get(request["target"])

      assert conn.status == 200
      assert conn.resp_body == answer["body"]
      assert signed_answer?(conn)

      # Under the fixture's server key, the answer string of this body is the fixture's
      # signature.
      %{"server_key" => %{"seed" => server_seed}} = fixture("signed/keys.json")
      {:ok, server_seed} = Ed25519.decode(server_seed, 32)

      message =
        SignedMessage.answer(
          200,
          request["headers"]["X-Qory-Signature-Ed25519"],
          conn.resp_body,
          nil,
          nil
        )

      assert Ed25519.encode(:crypto.sign(:eddsa, :none, message, [server_seed, :ed25519])) ==
               answer["headers"]["X-Qory-Signature-Ed25519"]

      # The same request again is a replay.
      replayed =
        request["headers"]
        |> Enum.reduce(build_conn(), fn {name, value}, conn ->
          put_req_header(conn, String.downcase(name), value)
        end)
        |> get(request["target"])

      assert json_response(replayed, 401) == %{"error" => "unauthorized"}
    end
  end

  describe "the hold" do
    setup do
      previous = Application.get_env(:apiary, ChangesController)
      on_exit(fn -> Application.put_env(:apiary, ChangesController, previous) end)

      %{adapter: adapter, access_key: key, pair: pair} = connectable_adapter_fixture()
      %{adapter: adapter, key: key, seed: pair.secret}
    end

    defp hold(ms, poll),
      do: Application.put_env(:apiary, ChangesController, hold: ms, poll: poll)

    defp read(ctx, query \\ "", opts \\ []),
      do:
        signed_get(
          build_conn(),
          ctx.key.key_id,
          ctx.seed,
          "/v1/work-items/changes" <> query,
          opts
        )

    test "a read with nothing after its cursor answers the entry that commits meanwhile", ctx do
      hold(5_000, 20)
      append!(ctx.adapter, %{kind: "sync", interval: nil})

      writer =
        Task.async(fn ->
          Process.sleep(200)
          append!(ctx.adapter, %{kind: "collection", collection_ref: "TRK", status: "linked"})
        end)

      started = System.monotonic_time(:millisecond)
      conn = read(ctx, "?after=c_00000001")
      took = System.monotonic_time(:millisecond) - started
      Task.await(writer)

      assert conn.status == 200
      assert signed_answer?(conn)

      assert Jason.decode!(conn.resp_body) == %{
               "version" => 1,
               "revision" => 1,
               "cursor" => "c_00000002",
               "changes" => [
                 %{"kind" => "collection", "collection_ref" => "TRK", "status" => "linked"}
               ]
             }

      assert took >= 150 and took < 5_000
    end

    test "with nothing for the whole hold, it answers no changes and the same cursor", ctx do
      hold(300, 50)
      started = System.monotonic_time(:millisecond)
      conn = read(ctx)
      took = System.monotonic_time(:millisecond) - started

      assert Jason.decode!(conn.resp_body)["changes"] == []
      assert Jason.decode!(conn.resp_body)["cursor"] == "c_00000000"
      assert took >= 300
    end

    test "a page that holds entries is answered at once", ctx do
      hold(5_000, 20)
      append!(ctx.adapter, %{kind: "sync", interval: nil})
      started = System.monotonic_time(:millisecond)
      conn = read(ctx)
      assert System.monotonic_time(:millisecond) - started < 2_000
      assert [%{"kind" => "sync"}] = Jason.decode!(conn.resp_body)["changes"]
    end
  end

  describe "the cap on holds" do
    setup do
      previous = Application.get_env(:apiary, ChangesController)
      on_exit(fn -> Application.put_env(:apiary, ChangesController, previous) end)
      Application.put_env(:apiary, ChangesController, hold: 1_500, poll: 20)

      %{adapter: adapter, access_key: key, pair: pair} = connectable_adapter_fixture()
      %{adapter: adapter, key: key, seed: pair.secret}
    end

    defp get_at(ctx, timestamp, query \\ ""),
      do:
        signed_get(build_conn(), ctx.key.key_id, ctx.seed, "/v1/work-items/changes" <> query,
          timestamp: timestamp
        )

    # How many of the key's slots are held now.
    defp slots(ctx) do
      Enum.count(1..ChangesController.holds_per_key(), fn n ->
        Registry.lookup(ChangesController.Holds, {ctx.key.id, n}) != []
      end)
    end

    defp until_slots(ctx, count, tries \\ 200) do
      cond do
        slots(ctx) == count -> :ok
        tries == 0 -> flunk("the key holds #{slots(ctx)} slots, not #{count}")
        true -> Process.sleep(10) && until_slots(ctx, count, tries - 1)
      end
    end

    defp timed(fun) do
      started = System.monotonic_time(:millisecond)
      result = fun.()
      {System.monotonic_time(:millisecond) - started, result}
    end

    defp body(conn), do: Jason.decode!(conn.resp_body)

    test "two reads of a key hold; the third is answered at once, empty, and another key holds",
         ctx do
      now = ApiaryWeb.Contract.SignedRequest.now()
      assert ChangesController.holds_per_key() == 2

      holders =
        for offset <- [0, 1], do: Task.async(fn -> timed(fn -> get_at(ctx, now - offset) end) end)

      until_slots(ctx, 2)

      {took, third} = timed(fn -> get_at(ctx, now - 2) end)
      assert took < 1_000
      assert third.status == 200
      assert signed_answer?(third)

      assert body(third) == %{
               "version" => 1,
               "revision" => 1,
               "cursor" => "c_00000000",
               "changes" => []
             }

      # Another key's read holds while this key's two do.
      other = connectable_adapter_fixture()
      other = %{adapter: other.adapter, key: other.access_key, seed: other.pair.secret}
      {other_took, other_conn} = timed(fn -> get_at(other, now) end)
      assert other_took >= 1_400
      assert body(other_conn)["changes"] == []

      for {held, conn} <- Task.await_many(holders, 5_000) do
        assert held >= 1_400
        assert body(conn)["changes"] == []
      end

      # The holds over, the key's slots are free, and a read holds again.
      until_slots(ctx, 0)
      assert slots(other) == 0
      {again, _conn} = timed(fn -> get_at(ctx, now - 3) end)
      assert again >= 1_400
    end

    test "a read that finds entries is answered at once, whatever the key holds", ctx do
      now = ApiaryWeb.Contract.SignedRequest.now()
      append!(ctx.adapter, %{kind: "sync", interval: nil})

      holders =
        for offset <- [0, 1],
            do: Task.async(fn -> get_at(ctx, now - offset, "?after=c_00000001") end)

      until_slots(ctx, 2)

      {took, conn} = timed(fn -> get_at(ctx, now - 2) end)
      assert took < 1_000
      assert [%{"kind" => "sync"}] = body(conn)["changes"]
      assert slots(ctx) == 2

      Task.await_many(holders, 5_000)
      until_slots(ctx, 0)
    end

    test "a hold's slot is freed when its process is killed mid-hold", ctx do
      # One read, then a long sleep, so the kill lands while it sleeps, not mid-query.
      Application.put_env(:apiary, ChangesController, hold: 5_000, poll: 5_000)
      now = ApiaryWeb.Contract.SignedRequest.now()
      parent = self()

      holder =
        spawn(fn ->
          receive do
            :go -> send(parent, {:done, get_at(ctx, now)})
          end
        end)

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), holder)
      send(holder, :go)
      until_slots(ctx, 1)
      Process.sleep(100)

      Process.exit(holder, :kill)
      until_slots(ctx, 0)
      refute_received {:done, _conn}

      # Both slots are there to take again.
      Application.put_env(:apiary, ChangesController, hold: 300, poll: 20)
      holders = for offset <- [1, 2], do: Task.async(fn -> get_at(ctx, now - offset) end)
      until_slots(ctx, 2)
      Task.await_many(holders, 5_000)
      until_slots(ctx, 0)
    end
  end
end
