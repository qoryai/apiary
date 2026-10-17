defmodule ApiaryWeb.Contract.SourceCollectionsControllerTest do
  # `POST /v1/source-collections` and `POST /v1/sources/disconnect`, signed with an
  # adapter's access key, through `ApiaryWeb.Contract.AdapterRequest`: the contract's
  # fixtures accepted, and its invalid ones refused; each refusal's code and body as the
  # contract's refusal fixtures have them, signed; the time's window and the replay rule;
  # the body's bounds; and the disconnect's signed 204 for a ref with no live collection.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1, unsigned_answer?: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Edition, EditionStubs, Repo}
  alias Apiary.Adapters.{Collection, Connection, Connections, Feed}
  alias ApiaryWeb.Contract.{RawBody, SignedRequest}

  @moduletag needs: :factory

  @fixtures Path.expand("../../fixtures/integration-contract/adapter", __DIR__)
  @listing "/v1/source-collections"
  @disconnect "/v1/sources/disconnect"
  @invalid %{"error" => "invalid_request"}

  setup do
    %{scope: scope} = sign_up_fixture()
    # A second workspace, so a collection is linked to none as it is made.
    workspace_fixture(scope.organisation)
    %{adapter: adapter, access_key: key, pair: pair} = connectable_adapter_fixture()
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    %{scope: scope, adapter: adapter, key: key, seed: pair.secret, connection: connection}
  end

  defp fixture(path), do: @fixtures |> Path.join(path) |> File.read!() |> Jason.decode!()

  defp now_time(offset \\ 0) do
    (SignedRequest.now() + offset) |> DateTime.from_unix!() |> DateTime.to_iso8601()
  end

  # A fixture made fresh, for this test's connection.
  defp fresh(path, ctx) do
    fixture(path)
    |> Map.put("time", now_time())
    |> then(fn body ->
      if Map.has_key?(body, "connection_id"),
        do: Map.put(body, "connection_id", ctx.connection.public_id),
        else: body
    end)
  end

  defp send_post(ctx, target, body, opts \\ []) do
    signed_post(
      build_conn(),
      Keyword.get(opts, :key_id, ctx.key.key_id),
      Keyword.get(opts, :seed, ctx.seed),
      body,
      Keyword.merge([target: target, content_type: "application/json", delivery: nil], opts)
    )
  end

  defp live(connection) do
    Repo.all(
      from c in Collection,
        where: c.connection_id == ^connection.id and is_nil(c.ended_at),
        order_by: c.external_ref,
        select: c.external_ref
    )
  end

  defp refusal(name), do: fixture("refusal/#{name}.json")

  describe "the listing" do
    test "the contract's listing in two parts, and the code host's with its target", ctx do
      for path <- ["acme-tracker-part-1", "acme-tracker-part-2"] do
        conn = send_post(ctx, @listing, fresh("source-collections/#{path}.json", ctx))
        assert conn.status == 204, path
        assert conn.resp_body == ""
        assert signed_answer?(conn)
      end

      assert live(ctx.connection) == ["OPS", "TRK"]

      conn = send_post(ctx, @listing, fresh("source-collections/code-host.json", ctx))
      assert conn.status == 204

      # Complete, and started later, it leaves out the tracker's two.
      assert live(ctx.connection) == ["R_1001"]

      assert %Collection{target_system: "github.com", target_path: "acme/shop"} =
               Repo.get_by!(Collection, external_ref: "R_1001")
    end

    test "the contract's invalid listing, and each bound past its limit, is 400 invalid_request",
         ctx do
      body = fresh("source-collections/code-host.json", ctx)
      [collection] = body["collections"]
      collection_with = &Map.put(body, "collections", [Map.merge(collection, &1)])
      listing_with = &Map.put(body, "listing", Map.merge(body["listing"], &1))

      bodies = [
        fresh("invalid/source-collections-no-listing.json", ctx),
        Map.put(body, "version", 2),
        Map.put(body, "connection_id", "ac_short"),
        Map.put(body, "connection_id", "na_0000000000000000"),
        Map.put(body, "extra", true),
        Map.put(body, "collections", List.duplicate(collection, 101)),
        collection_with.(%{"ref" => ""}),
        collection_with.(%{"ref" => String.duplicate("é", 201)}),
        collection_with.(%{"ref" => "a\u0000b"}),
        collection_with.(%{"url" => "http://github.com/acme/shop"}),
        collection_with.(%{"url" => "https://" <> String.duplicate("a", 2041)}),
        collection_with.(%{"title" => ""}),
        collection_with.(%{"title" => String.duplicate("t", 1025)}),
        collection_with.(%{"target" => %{"system" => "GitHub.com", "path" => "acme/shop"}}),
        collection_with.(%{"target" => %{"system" => "github.com", "path" => ""}}),
        collection_with.(%{"target" => %{"system" => "github.com"}}),
        collection_with.(%{"target" => nil}),
        collection_with.(%{"name" => "x"}),
        Map.put(body, "collections", [Map.delete(collection, "title")]),
        listing_with.(%{"id" => ""}),
        listing_with.(%{"id" => String.duplicate("i", 201)}),
        listing_with.(%{"part" => 0}),
        listing_with.(%{"part" => 10_001}),
        listing_with.(%{"part" => "1"}),
        listing_with.(%{"complete" => "true"}),
        listing_with.(%{"started_at" => "2026-10-15T11:59:58.5Z"}),
        Map.put(body, "listing", Map.delete(body["listing"], "complete"))
      ]

      for body <- bodies do
        conn = send_post(ctx, @listing, body)
        assert json_response(conn, 400) == @invalid, inspect(body, limit: 5)
        assert signed_answer?(conn)
      end

      raw = Jason.encode!(body)

      for broken <- [
            String.replace(raw, ~s("part":1), ~s("part":1.0)),
            String.replace(raw, ~s("version":1), ~s("version":1,"version":1))
          ] do
        assert json_response(send_post(ctx, @listing, broken), 400) == @invalid, broken
      end

      assert Repo.aggregate(Collection, :count) == 0

      # At the bounds, it is taken.
      edge =
        collection_with.(%{
          "ref" => String.duplicate("é", 200),
          "title" => String.duplicate("t", 1024)
        })
        |> Map.put("listing", Map.merge(body["listing"], %{"id" => String.duplicate("i", 200)}))

      assert send_post(ctx, @listing, edge).status == 204
    end

    test "a body just over a bound, or packed to 1 MiB with collections, is refused at once",
         ctx do
      body = fresh("source-collections/code-host.json", ctx)
      [collection] = body["collections"]

      # 101 collections, then as many empty objects as fit under 1 MiB, then as many
      # strings: each is refused on the count before any collection is read.
      for collections <- [
            List.duplicate(collection, 101),
            List.duplicate(%{}, 300_000),
            List.duplicate("x", 200_000)
          ] do
        raw = Jason.encode!(Map.put(body, "collections", collections))
        assert byte_size(raw) <= RawBody.max_bytes(:adapter)

        {micros, conn} = :timer.tc(fn -> send_post(ctx, @listing, raw) end)
        assert json_response(conn, 400) == @invalid
        assert micros < 1_000_000, "#{length(collections)} took #{micros} µs"
      end

      assert Repo.aggregate(Collection, :count) == 0
    end

    test "a body over 1 MiB is 413, before anything else", ctx do
      body = fresh("source-collections/code-host.json", ctx)

      raw =
        Jason.encode!(Map.put(body, "pad", String.duplicate("x", RawBody.max_bytes(:adapter))))

      conn = send_post(ctx, @listing, raw)
      assert json_response(conn, 413) == %{"error" => "payload_too_large"}
      assert Repo.aggregate(Collection, :count) == 0
    end

    test "a part that disagrees with the listing's parts before it is 400, and changes nothing",
         ctx do
      body = fresh("source-collections/acme-tracker-part-2.json", ctx)
      assert send_post(ctx, @listing, body).status == 204

      again =
        body
        |> Map.put("time", now_time(1))
        |> Map.put("listing", Map.merge(body["listing"], %{"part" => 3}))

      conn = send_post(ctx, @listing, again)
      assert json_response(conn, 400) == @invalid
      assert signed_answer?(conn)
      assert live(ctx.connection) == ["OPS"]
    end

    test "refusals: connection_unknown, connection_ended, connection_suspended, forbidden; each the contract's body, signed",
         ctx do
      body = fresh("source-collections/code-host.json", ctx)

      # Pending, or not held: connection_unknown.
      %{scope: second} = sign_up_fixture()
      {pending, _} = connection_fixture(second, ctx.adapter, :pending)

      for id <- [pending.public_id, "ac_0000000000000000"] do
        conn = send_post(ctx, @listing, Map.put(body, "connection_id", id))
        assert json_response(conn, 403) == refusal("connection-unknown")
        assert signed_answer?(conn)
      end

      # Suspended.
      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [ctx.scope.organisation.id])
      conn = send_post(ctx, @listing, Map.put(body, "time", now_time(1)))
      assert json_response(conn, 409) == refusal("connection-suspended")
      assert signed_answer?(conn)

      # Ended.
      {:ok, verified} = Apiary.AccessKeys.fetch_for_verification(ctx.key.key_id)
      key_scope = Apiary.Accounts.Scope.for_access_key(verified)
      {:ok, _} = Connections.end_connection(key_scope, ctx.connection.public_id)
      conn = send_post(ctx, @listing, Map.put(body, "time", now_time(2)))
      assert json_response(conn, 409) == refusal("connection-ended")
      assert signed_answer?(conn)

      # Forbidden, whatever the connection.
      Edition.put_test_stub(__MODULE__.NoPost)

      for id <- [ctx.connection.public_id, "ac_0000000000000000"] do
        conn =
          send_post(
            ctx,
            @listing,
            body |> Map.put("connection_id", id) |> Map.put("time", now_time(3))
          )

        assert json_response(conn, 403) == %{"error" => "forbidden"}
        assert signed_answer?(conn)
      end

      assert Repo.aggregate(Collection, :count) == 0
    end

    test "a stale time or a replay is 401, unsigned, and changes nothing", ctx do
      body = fresh("source-collections/code-host.json", ctx)

      for offset <- [-301, 301] do
        conn = send_post(ctx, @listing, Map.put(body, "time", now_time(offset)))
        assert json_response(conn, 401) == %{"error" => "unauthorized"}
        assert unsigned_answer?(conn)
      end

      raw = Jason.encode!(body)
      assert send_post(ctx, @listing, raw).status == 204

      conn = send_post(ctx, @listing, raw)
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert unsigned_answer?(conn)
    end
  end

  describe "the disconnect" do
    setup ctx do
      conn = send_post(ctx, @listing, fresh("source-collections/code-host.json", ctx))
      assert conn.status == 204
      :ok
    end

    test "the contract's disconnect ends the collection, then is a signed 204 that changes nothing",
         ctx do
      {:ok, _} = set_collection_workspace(Repo.one!(Collection), ctx.scope.workspace)

      conn = send_post(ctx, @disconnect, fresh("sources-disconnect/code-host.json", ctx))
      assert conn.status == 204
      assert conn.resp_body == ""
      assert signed_answer?(conn)
      assert live(ctx.connection) == []
      entries = Feed.entries(ctx.adapter)

      assert [%{kind: "collection", data: %{"collection_ref" => "R_1001"}}] =
               for(%{kind: "collection"} = e <- entries, do: e)

      for ref <- ["R_1001", "NEVER"] do
        body = fresh("sources-disconnect/code-host.json", ctx)

        conn =
          send_post(
            ctx,
            @disconnect,
            Map.merge(body, %{"collection_ref" => ref, "time" => now_time(1)})
          )

        assert conn.status == 204, ref
        assert signed_answer?(conn)
      end

      assert Feed.entries(ctx.adapter) == entries
    end

    test "the contract's invalid disconnect, and each bound past its limit, is 400", ctx do
      body = fresh("sources-disconnect/code-host.json", ctx)

      for bad <- [
            fresh("invalid/sources-disconnect-with-reason.json", ctx),
            Map.put(body, "collection_ref", ""),
            Map.put(body, "collection_ref", String.duplicate("r", 201)),
            Map.put(body, "collection_ref", 1001),
            Map.put(body, "version", 2),
            Map.delete(body, "time")
          ] do
        conn = send_post(ctx, @disconnect, bad)
        assert json_response(conn, 400) == @invalid, inspect(bad)
        assert signed_answer?(conn)
      end

      assert live(ctx.connection) == ["R_1001"]
    end

    test "suspended for a live collection; never connection_unknown or connection_ended", ctx do
      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [ctx.scope.organisation.id])

      conn = send_post(ctx, @disconnect, fresh("sources-disconnect/code-host.json", ctx))
      assert json_response(conn, 409) == refusal("connection-suspended")
      assert signed_answer?(conn)
      assert live(ctx.connection) == ["R_1001"]

      {:ok, verified} = Apiary.AccessKeys.fetch_for_verification(ctx.key.key_id)
      key_scope = Apiary.Accounts.Scope.for_access_key(verified)
      {:ok, _} = Connections.end_connection(key_scope, ctx.connection.public_id)

      conn =
        send_post(
          ctx,
          @disconnect,
          Map.put(fresh("sources-disconnect/code-host.json", ctx), "time", now_time(1))
        )

      assert conn.status == 204
      assert Repo.get!(Connection, ctx.connection.id).state == :ended
    end

    test "forbidden first, for any ref", ctx do
      Edition.put_test_stub(EditionStubs.NoDisconnect)

      for {ref, offset} <- [{"R_1001", 0}, {"NEVER", 1}] do
        body = fresh("sources-disconnect/code-host.json", ctx)

        conn =
          send_post(
            ctx,
            @disconnect,
            Map.merge(body, %{"collection_ref" => ref, "time" => now_time(offset)})
          )

        assert json_response(conn, 403) == %{"error" => "forbidden"}
        assert signed_answer?(conn)
      end

      assert live(ctx.connection) == ["R_1001"]
    end

    test "the path read raw also when written with escapes", ctx do
      conn =
        send_post(
          ctx,
          "/v1/sources/%64isconnect",
          fresh("sources-disconnect/code-host.json", ctx)
        )

      assert conn.status == 204
      assert live(ctx.connection) == []
    end
  end

  defmodule NoPost do
    @moduledoc false
    def check(_scope, :"source_item.post", _subject), do: {:error, :forbidden}
    def check(scope, action, subject), do: Apiary.Edition.module().check(scope, action, subject)
  end
end
