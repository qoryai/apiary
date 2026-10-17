defmodule ApiaryWeb.Contract.ChangesControllerTest do
  # `GET /v1/work-items/changes`, an adapter's read of its change feed, through
  # `ApiaryWeb.Contract.AdapterRequest`: the contract's feed fixtures served as written,
  # the answer held to the schema's members, pages and cursors, an empty page, a garbled
  # or stale cursor, one adapter's key never reading another's feed, the refusals in their
  # order, the answer signed, and the request's signature, freshness and replay.
  use ApiaryWeb.ConnCase, async: true

  import Apiary.ContractFixtures, only: [signed_get: 5, signed_answer?: 1, unsigned_answer?: 1]
  import Apiary.NodesFixtures

  alias Apiary.{Edition, Repo}
  alias Apiary.Adapters.Feed
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory

  @fixtures Path.expand("../../fixtures/integration-contract/adapter", __DIR__)
  @path "/v1/work-items/changes"
  @invalid %{"error" => "invalid_request"}
  @unauthorized %{"error" => "unauthorized"}

  # The edition narrows the rights of an adapter's key: its role does not read the feed.
  defmodule NoReadChanges do
    def check(_scope, :"work_item.read_changes", _subject), do: {:error, :forbidden}
    def check(scope, action, subject), do: Apiary.Edition.module().check(scope, action, subject)
  end

  defp fixture(path), do: @fixtures |> Path.join(path) |> File.read!() |> Jason.decode!()

  defp entry(change), do: Map.new(change, fn {k, v} -> {String.to_existing_atom(k), v} end)

  defp append!(adapter, entries) do
    Repo.transaction(fn -> for e <- List.wrap(entries), do: Feed.append(adapter, e) end)
  end

  defp changes(ctx, query \\ "", opts \\ []) do
    signed_get(
      build_conn(),
      Keyword.get(opts, :key_id, ctx.key.key_id),
      Keyword.get(opts, :seed, ctx.seed),
      @path <> query,
      opts
    )
  end

  # The answer's body, held to the schema's members: exactly version 1, the revision,
  # a cursor of 1 to 200 characters and the changes.
  defp page!(conn) do
    assert conn.status == 200
    assert signed_answer?(conn)
    body = Jason.decode!(conn.resp_body)
    assert Map.keys(body) |> Enum.sort() == ~w(changes cursor revision version)
    assert %{"version" => 1, "revision" => 1, "cursor" => cursor} = body
    assert byte_size(cursor) in 1..200
    body
  end

  setup do
    %{adapter: adapter, access_key: key, pair: pair} = connectable_adapter_fixture()
    %{adapter: adapter, key: key, seed: pair.secret}
  end

  describe "the contract's feed fixtures" do
    test "each feed is served as written, from the start", ctx do
      for {path, adapter_ctx} <- [
            {"changes/feed.json", ctx},
            {"changes/feed-loopback.json", fresh()},
            {"changes/empty.json", fresh()}
          ] do
        %{"changes" => written} = fixture(path)
        append!(adapter_ctx.adapter, Enum.map(written, &entry/1))

        body = adapter_ctx |> changes() |> page!()
        assert body["changes"] == written, path
        assert body["cursor"] == Feed.cursor(length(written)), path
      end
    end

    test "the refused answer fixtures are what an answer never is" do
      # Without a revision, or with an entry no writer appends: each is refused by the
      # schema, and the answers above always name the revision and hold only entries
      # `Apiary.Adapters.Feed.append/2` takes (its test refuses each entry).
      refute Map.has_key?(fixture("invalid/changes-without-revision.json"), "revision")

      for path <- ~w(invalid/changes-sync-interval-30.json invalid/changes-unknown-kind.json
                     invalid/changes-work-item-status-linked.json
                     invalid/changes-work-item-url-http.json),
          change <- fixture(path)["changes"] do
        assert_raise ArgumentError, fn ->
          Repo.transaction(fn ->
            Feed.append(fresh().adapter, Map.new(change, fn {k, v} -> {String.to_atom(k), v} end))
          end)
        end
      end
    end
  end

  describe "pages and cursors" do
    test "a page holds at most page_size/0, in order, and the cursor reads on", ctx do
      append!(ctx.adapter, for(i <- 1..205, do: %{kind: "sync", interval: 60 + i}))

      first = ctx |> changes() |> page!()
      assert length(first["changes"]) == 100
      assert first["cursor"] == "c_00000100"
      assert hd(first["changes"]) == %{"kind" => "sync", "interval" => 61}

      second = ctx |> changes("?after=c_00000100") |> page!()
      assert length(second["changes"]) == 100
      assert hd(second["changes"])["interval"] == 161

      third = ctx |> changes("?after=" <> second["cursor"]) |> page!()
      assert Enum.map(third["changes"], & &1["interval"]) == Enum.to_list(261..265)
      assert third["cursor"] == "c_00000205"

      # An empty page: no changes, and the same cursor.
      empty = ctx |> changes("?after=c_00000205") |> page!()
      assert empty["changes"] == []
      assert empty["cursor"] == "c_00000205"
    end

    test "an empty feed answers no changes and the start's cursor", ctx do
      body = ctx |> changes() |> page!()
      assert body == %{"version" => 1, "revision" => 1, "cursor" => "c_00000000", "changes" => []}

      again = ctx |> changes("?after=c_00000000") |> page!()
      assert again["cursor"] == "c_00000000"
    end

    test "a garbled cursor or query is 400 invalid_request, signed", ctx do
      append!(ctx.adapter, %{kind: "sync", interval: nil})

      for query <- [
            "?after=",
            "?after=c_1",
            "?after=c_000000001",
            "?after=C_00000001",
            "?after=00000001",
            "?after=c_0000000x",
            "?after=c%5F00000001",
            "?after=c_00000001&after=c_00000000",
            "?after=c_00000001&x=1",
            "?x=1",
            "?after=c_" <> String.duplicate("0", 5000),
            "?after=c_000000000000000000001",
            "?after"
          ] do
        conn = changes(ctx, query)
        assert json_response(conn, 400) == @invalid, query
        assert signed_answer?(conn), query
      end
    end

    test "a stale cursor, past the feed's end, is 400 invalid_request, signed", ctx do
      append!(ctx.adapter, %{kind: "sync", interval: nil})

      for query <- ["?after=c_00000002", "?after=c_99999999"] do
        conn = changes(ctx, query)
        assert json_response(conn, 400) == @invalid, query
        assert signed_answer?(conn)
      end
    end

    test "a key reads its adapter's feed and nothing of another's", ctx do
      other = fresh()

      append!(ctx.adapter, %{kind: "collection", collection_ref: "TRK", status: "linked"})

      append!(other.adapter, [
        %{kind: "collection", collection_ref: "OPS", status: "linked"},
        %{kind: "sync", interval: 600}
      ])

      assert (ctx |> changes() |> page!())["changes"] == [
               %{"kind" => "collection", "collection_ref" => "TRK", "status" => "linked"}
             ]

      assert [%{"collection_ref" => "OPS"}, %{"interval" => 600}] =
               (other |> changes() |> page!())["changes"]

      # The other's cursor is past this feed's end.
      assert json_response(changes(ctx, "?after=c_00000002"), 400) == @invalid
    end

    test "read from the start, the last entry per collection_ref is the link state", ctx do
      entries =
        for {ref, status} <- [
              {"TRK", "linked"},
              {"OPS", "linked"},
              {"TRK", "unlinked"},
              {"OPS", "unlinked"},
              {"OPS", "linked"}
            ],
            do: %{kind: "collection", collection_ref: ref, status: status}

      append!(ctx.adapter, entries)

      last =
        (ctx |> changes() |> page!())["changes"]
        |> Map.new(&{&1["collection_ref"], &1["status"]})

      assert last == %{"TRK" => "unlinked", "OPS" => "linked"}
    end
  end

  describe "the refusals, in order" do
    test "the request's own refusals come first, unsigned where the contract has them", ctx do
      # A signing header twice: 400 bad_request, unsigned.
      conn = changes(ctx, "?after=garbled", headers: [{"x-qory-access-key-id", ctx.key.key_id}])
      assert json_response(conn, 400) == %{"error" => "bad_request"}
      assert unsigned_answer?(conn)

      # A signature under another key: 401, unsigned, before the query is read.
      conn = changes(ctx, "?after=garbled", seed: "not the secret")
      assert json_response(conn, 401) == @unauthorized
      assert unsigned_answer?(conn)

      # A revision not served: 400 unsupported_contract_version, signed.
      conn = changes(ctx, "?after=garbled", contract_version: "2")
      assert json_response(conn, 400) == %{"error" => "unsupported_contract_version"}
      assert signed_answer?(conn)

      # A timestamp more than 300 seconds off, or none: 401, unsigned.
      for timestamp <- [SignedRequest.now() - 301, SignedRequest.now() + 301, nil] do
        conn = changes(ctx, "?after=garbled", timestamp: timestamp)
        assert json_response(conn, 401) == @unauthorized
        assert unsigned_answer?(conn)
      end
    end

    test "a garbled cursor is refused before the key's rights; the rights before a stale one",
         ctx do
      :ok = Edition.put_test_stub(NoReadChanges)

      assert json_response(changes(ctx, "?after=garbled"), 400) == @invalid

      for query <- ["", "?after=c_00000000", "?after=c_00000009"] do
        conn = changes(ctx, query)
        assert json_response(conn, 403) == %{"error" => "forbidden"}, query
        assert signed_answer?(conn)
      end
    end

    test "the same request sent again is a replay, 401, unsigned", ctx do
      append!(ctx.adapter, %{kind: "sync", interval: nil})
      now = SignedRequest.now()

      assert ctx |> changes("", timestamp: now) |> page!()
      replayed = changes(ctx, "", timestamp: now)
      assert json_response(replayed, 401) == @unauthorized
      assert unsigned_answer?(replayed)

      # Built anew, a second later, it is read again.
      assert ctx |> changes("", timestamp: now + 1) |> page!()
    end

    test "a revoked or deleted adapter's key is 401", ctx do
      {:ok, _} = Apiary.Adapters.delete_adapter(instance_admin(), ctx.adapter)
      assert json_response(changes(ctx), 401) == @unauthorized
    end
  end

  defp fresh do
    %{adapter: adapter, access_key: key, pair: pair} = connectable_adapter_fixture()
    %{adapter: adapter, key: key, seed: pair.secret}
  end

  defp instance_admin, do: Apiary.OrganisationsFixtures.instance_admin_scope()
end
