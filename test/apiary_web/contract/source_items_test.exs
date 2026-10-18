defmodule ApiaryWeb.Contract.SourceItemsTest do
  # `POST /v1/source-items`, signed with an adapter's access key, through
  # `ApiaryWeb.Contract.AdapterRequest`: every body of the contract's `source-items/`
  # fixtures accepted, with a signed 204, and every one of its invalid ones refused; the
  # refusals before the body in their order, 413, 415, 400, then 401, then the body's
  # 400, then its time's 401; each refusal of the items in the contract's order, its code
  # and body as the contract's refusal fixtures have them, signed; the time's window and
  # the replay rule; and the path read raw also when written with escapes.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1, unsigned_answer?: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SourcesFixtures, only: [item: 1, key_scope: 1]
  import Apiary.WorkItemsFixtures, only: [source_collection_fixture: 3]

  alias Apiary.{Edition, EditionStubs, Repo}
  alias Apiary.Adapters.{Collection, Connections}
  alias Apiary.Sources.{Item, Listing}
  alias ApiaryWeb.Contract.{RawBody, SignedRequest}

  @moduletag needs: :factory

  @fixtures Path.expand("../../fixtures/integration-contract/adapter", __DIR__)
  @target "/v1/source-items"
  @invalid %{"error" => "invalid_request"}
  @unauthorized %{"error" => "unauthorized"}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{adapter: adapter, access_key: key, pair: pair} = connectable_adapter_fixture()
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)

    # The collections the contract's bodies name, each linked to the scope's workspace.
    collections =
      Map.new(["TRK", "OPS", "R_1001"], fn ref ->
        {ref, source_collection_fixture(scope, connection, %{external_ref: ref})}
      end)

    %{
      scope: scope,
      adapter: adapter,
      key: key,
      seed: pair.secret,
      connection: connection,
      collections: collections
    }
  end

  defp fixture(path), do: @fixtures |> Path.join(path) |> File.read!() |> Jason.decode!()
  defp raw_fixture(path), do: @fixtures |> Path.join(path) |> File.read!()

  defp fixtures(pattern) do
    @fixtures
    |> Path.join(pattern)
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, @fixtures))
    |> Enum.sort()
  end

  defp now_time(offset) do
    (SignedRequest.now() + offset) |> DateTime.from_unix!() |> DateTime.to_iso8601()
  end

  # A fixture made fresh: its time the clock's, plus `offset` seconds.
  defp fresh(path, offset \\ 0), do: path |> fixture() |> Map.put("time", now_time(offset))

  defp send_post(ctx, body, opts \\ []) do
    signed_post(
      build_conn(),
      Keyword.get(opts, :key_id, ctx.key.key_id),
      Keyword.get(opts, :seed, ctx.seed),
      body,
      Keyword.merge([target: @target, content_type: "application/json", delivery: nil], opts)
    )
  end

  defp event(ref, offset) do
    %{"version" => 1, "time" => now_time(offset), "collection_ref" => ref, "items" => [item("A")]}
  end

  defp refs(%Collection{id: collection_id}, state) do
    Repo.all(
      from i in Item,
        where: i.collection_id == ^collection_id and i.state == ^state,
        order_by: i.external_ref,
        select: i.external_ref
    )
  end

  defp count(schema), do: Repo.aggregate(schema, :count)

  defp refusal(name), do: fixture("refusal/#{name}.json")

  describe "the contract's bodies" do
    test "each of source-items/ is a signed 204 with no body, and its items are kept", ctx do
      paths = fixtures("source-items/*.json")
      assert paths != []

      for path <- paths do
        conn = send_post(ctx, fresh(path))
        assert conn.status == 204, path
        assert conn.resp_body == ""
        assert signed_answer?(conn), path
      end

      # The last complete listing of the tracker named TRK-3 alone.
      assert refs(ctx.collections["TRK"], :open) == ["TRK-3"]

      assert refs(ctx.collections["TRK"], :closed) ==
               ~w(TRK-1 TRK-10 TRK-11 TRK-1231 TRK-2 TRK-9)

      assert refs(ctx.collections["OPS"], :open) == []

      assert %Item{title: "Prices show without tax", state: :open, labels: labels} =
               Repo.get_by!(Item, collection_id: ctx.collections["R_1001"].id)

      assert labels == ["bug", "good first issue"]
    end

    test "each invalid one is 400 invalid_request, signed, before its time is read", ctx do
      paths = fixtures("invalid/source-items-*.json")
      assert paths != []

      # Sent as written, their times not made fresh: the body is refused before its time
      # is read.
      for path <- paths do
        conn = send_post(ctx, raw_fixture(path))
        assert json_response(conn, 400) == @invalid, path
        assert signed_answer?(conn), path
      end

      assert count(Item) == 0
    end

    test "a body past a bound of the request is 400 invalid_request, signed", ctx do
      body = fresh("source-items/code-host-event.json")
      [item] = body["items"]

      for bad <- [
            Map.put(body, "version", 2),
            Map.put(body, "extra", true),
            Map.delete(body, "time"),
            Map.put(body, "collection_ref", ""),
            Map.put(body, "collection_ref", String.duplicate("r", 201)),
            Map.put(body, "collection_ref", 1001),
            Map.put(body, "items", []),
            Map.put(body, "items", List.duplicate(item, 101)),
            Map.put(body, "items", [Map.put(item, "ref", "")])
          ] do
        conn = send_post(ctx, bad)
        assert json_response(conn, 400) == @invalid, inspect(bad, limit: 5)
        assert signed_answer?(conn)
      end

      raw = Jason.encode!(body)

      for broken <- [
            String.replace(raw, ~s("version":1), ~s("version":1,"version":1)),
            String.replace(raw, ~s("comment_count":2), ~s("comment_count":2.0)),
            "[]",
            "not json"
          ] do
        conn = send_post(ctx, broken)
        assert json_response(conn, 400) == @invalid, broken
        assert signed_answer?(conn)
      end

      assert count(Item) == 0
    end
  end

  describe "the refusals before the body" do
    test "413, then 415, then 400 bad_request, then 401, each unsigned, then the body's 400, signed",
         ctx do
      body = fresh("source-items/code-host-event.json")
      over = String.duplicate(" ", RawBody.max_bytes(:adapter) + 1)
      twice = [headers: [{"x-qory-access-key-id", ctx.key.key_id}]]
      wrong_key = [seed: "not the secret"]

      # Over 1 MiB, of the wrong type, a header twice and a wrong signature: 413.
      conn = send_post(ctx, over, [content_type: "text/plain"] ++ twice ++ wrong_key)
      assert json_response(conn, 413) == %{"error" => "payload_too_large"}
      assert unsigned_answer?(conn)

      # Of the wrong type, a header twice and a wrong signature: 415.
      conn = send_post(ctx, body, [content_type: "text/plain"] ++ twice ++ wrong_key)
      assert json_response(conn, 415) == %{"error" => "unsupported_media_type"}
      assert unsigned_answer?(conn)

      # A header twice and a wrong signature: 400 bad_request.
      conn = send_post(ctx, body, twice ++ wrong_key)
      assert json_response(conn, 400) == %{"error" => "bad_request"}
      assert unsigned_answer?(conn)

      # A wrong signature over a body the contract refuses: 401.
      conn = send_post(ctx, Map.put(body, "version", 2), wrong_key)
      assert json_response(conn, 401) == @unauthorized
      assert unsigned_answer?(conn)

      # Verified, a body the contract refuses with a stale time: 400 invalid_request.
      conn = send_post(ctx, body |> Map.put("version", 2) |> Map.put("time", now_time(-310)))
      assert json_response(conn, 400) == @invalid
      assert signed_answer?(conn)

      assert count(Item) == 0
    end

    test "a stale or future time, or a replay, is 401, unsigned, and changes nothing", ctx do
      for offset <- [-310, 310] do
        conn = send_post(ctx, fresh("source-items/code-host-event.json", offset))
        assert json_response(conn, 401) == @unauthorized, "#{offset}"
        assert unsigned_answer?(conn)
      end

      assert count(Item) == 0

      raw = Jason.encode!(fresh("source-items/code-host-event.json"))
      conn = send_post(ctx, raw)
      assert conn.status == 204
      assert signed_answer?(conn)
      kept = Repo.one!(Item)

      conn = send_post(ctx, raw)
      assert json_response(conn, 401) == @unauthorized
      assert unsigned_answer?(conn)
      assert Repo.one!(Item) == kept
    end
  end

  describe "the refusals of the items" do
    test "forbidden, then connection_ended, then connection_suspended, then collection_not_linked; each the contract's body, signed",
         ctx do
      unlinked =
        source_collection_fixture(ctx.scope, ctx.connection, %{
          external_ref: "UNLINKED",
          workspace_id: nil
        })

      # Not linked: a live collection linked to no workspace, and a ref with none.
      for {ref, offset} <- [{unlinked.external_ref, 0}, {"NEVER", 1}] do
        conn = send_post(ctx, event(ref, offset))
        assert json_response(conn, 409) == refusal("collection-not-linked"), ref
        assert signed_answer?(conn)
      end

      # Suspended before not linked, for a live collection; a ref with none is not linked.
      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [ctx.scope.organisation.id])

      for {ref, offset} <- [{"TRK", 2}, {unlinked.external_ref, 3}] do
        conn = send_post(ctx, event(ref, offset))
        assert json_response(conn, 409) == refusal("connection-suspended"), ref
        assert signed_answer?(conn)
      end

      conn = send_post(ctx, event("NEVER", 4))
      assert json_response(conn, 409) == refusal("collection-not-linked")

      # Ended before suspended.
      {:ok, _} = Connections.end_connection(key_scope(ctx.key), ctx.connection.public_id)
      conn = send_post(ctx, event("TRK", 5))
      assert json_response(conn, 409) == refusal("connection-ended")
      assert signed_answer?(conn)

      # Forbidden before all, whatever the ref.
      Edition.put_test_stub(__MODULE__.NoPost)

      for {ref, offset} <- [{"TRK", 6}, {"NEVER", 7}] do
        conn = send_post(ctx, event(ref, offset))
        assert json_response(conn, 403) == %{"error" => "forbidden"}, ref
        assert signed_answer?(conn)
      end

      assert count(Item) == 0
    end

    test "a part that disagrees with the listing's parts before it is 400, signed, and changes nothing",
         ctx do
      body = fresh("source-items/acme-tracker-listing-1-part-2.json")
      assert send_post(ctx, body).status == 204
      kept = Repo.all(Item)

      again = body |> Map.put("time", now_time(1)) |> put_in(["listing", "part"], 3)
      conn = send_post(ctx, again)
      assert json_response(conn, 400) == @invalid
      assert signed_answer?(conn)
      assert Repo.all(Item) == kept
      assert [%Listing{parts: [2]}] = Repo.all(Listing)
    end
  end

  test "the path read raw also when written with escapes", ctx do
    conn =
      send_post(ctx, fresh("source-items/code-host-event.json"), target: "/v1/source-%69tems")

    assert conn.status == 204
    assert signed_answer?(conn)
    assert count(Item) == 1
  end

  defmodule NoPost do
    @moduledoc false
    def check(_scope, :"source_item.post", _subject), do: {:error, :forbidden}
    def check(scope, action, subject), do: Apiary.Edition.module().check(scope, action, subject)
  end
end

defmodule ApiaryWeb.Contract.SourceItemsSignedTest do
  # The contract's signed `POST /v1/source-items`, vendored from the commit in
  # `.integration-contract-ref` under `test/fixtures/integration-contract/adapter/signed/`:
  # sent through the endpoint exactly as written, under the access key of `keys.json` held
  # on an adapter connected to an organisation whose workspace is linked to the
  # collection it names, with the contract's clock set to the second it was signed at, it
  # is a signed 204 that keeps its item; sent again, it is a replay, 401. Where the
  # feature is off, it and a signed post of comments are a signed 404. Not async: the
  # clock and the features are the whole node's, and the fixture key's id is one for every
  # test.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1, unsigned_answer?: 1]
  import Apiary.SourcesFixtures, only: [comment: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures, only: [source_collection_fixture: 3]

  alias Apiary.Repo
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Contract.Ed25519
  alias Apiary.Sources.{Comment, Item}

  @moduletag needs: :factory

  @fixtures Path.expand("../../fixtures/integration-contract/adapter/signed", __DIR__)
  # 2026-10-15T12:00:00Z, the second every signed fixture is signed at.
  @signed_at 1_792_065_600

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  setup do
    on_exit(fn -> Application.delete_env(:apiary, :contract_now) end)
    Application.put_env(:apiary, :contract_now, fn -> @signed_at end)

    %{scope: scope} = sign_up_fixture()

    %{adapter: adapter} =
      connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})

    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    collection = source_collection_fixture(scope, connection, %{external_ref: "R_1001"})

    %{"access_key" => entry} = fixture("keys.json")
    {:ok, public_key} = Ed25519.decode(entry["public_key"], 32)

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
        created_by_id: instance_admin_scope().user.id,
        arrived_by: :browser,
        received_at: DateTime.utc_now()
      }
      |> AccessKey.insert_changeset(%{allow_secrets: false, label: "integration fixture"})
      |> AccessKey.put_integrity()
      |> Repo.insert!()

    %{key: key, collection: collection}
  end

  # The fixture's request sent through the endpoint: its method, target, headers and raw
  # body exactly as written.
  defp send_fixture(%{"method" => "POST", "target" => target, "headers" => headers} = fixture) do
    headers
    |> Enum.reduce(build_conn(), fn {name, value}, conn ->
      Plug.Conn.put_req_header(conn, String.downcase(name), value)
    end)
    |> Phoenix.ConnTest.dispatch(ApiaryWeb.Endpoint, :post, target, fixture["body"])
  end

  test "is a signed 204 that keeps its item, and a replay sent again", ctx do
    fixture = fixture("post-source-items.json")
    assert fixture["target"] == "/v1/source-items"

    conn = send_fixture(fixture)
    assert conn.status == 204
    assert conn.resp_body == ""
    assert signed_answer?(conn)

    assert %Item{external_ref: "I_2001", title: "Prices show without tax"} =
             kept = Repo.get_by!(Item, collection_id: ctx.collection.id)

    assert %DateTime{} = Repo.get!(AccessKey, ctx.key.id).last_used_at

    replayed = send_fixture(fixture)
    assert json_response(replayed, 401) == %{"error" => "unauthorized"}
    assert unsigned_answer?(replayed)
    assert Repo.get_by!(Item, collection_id: ctx.collection.id) == kept
  end

  test "a body changed by one byte does not verify, and keeps nothing", _ctx do
    fixture = fixture("post-source-items.json")
    conn = send_fixture(%{fixture | "body" => fixture["body"] <> " "})
    assert json_response(conn, 401) == %{"error" => "unauthorized"}
    assert unsigned_answer?(conn)
    assert Repo.aggregate(Item, :count) == 0
  end

  test "past 300 seconds from the second it was signed at, it is 401", _ctx do
    fixture = fixture("post-source-items.json")

    for offset <- [-310, 310] do
      Application.put_env(:apiary, :contract_now, fn -> @signed_at + offset end)
      conn = send_fixture(fixture)
      assert json_response(conn, 401) == %{"error" => "unauthorized"}, "#{offset}"
    end

    assert Repo.aggregate(Item, :count) == 0
  end

  describe "where the feature is off" do
    # The adapter and its key are made where the feature is on; it is turned off after.
    setup do
      previous = Application.get_env(:apiary, :features)
      {:ok, features} = Apiary.Features.parse("observability,security")
      Application.put_env(:apiary, :features, features)
      on_exit(fn -> Application.put_env(:apiary, :features, previous) end)
      :ok
    end

    test "the signed items and a signed post of comments are 404 not_found, signed, and keep nothing",
         _ctx do
      refute Apiary.Features.on?(:factory)

      conn = send_fixture(fixture("post-source-items.json"))
      assert json_response(conn, 404) == %{"error" => "not_found"}
      assert signed_answer?(conn)

      %{"access_key" => entry} = fixture("keys.json")
      "qak_" <> encoded = entry["secret"]
      {:ok, seed} = Ed25519.decode(encoded, 32)

      body = %{
        "version" => 1,
        "time" => @signed_at |> DateTime.from_unix!() |> DateTime.to_iso8601(),
        "item_ref" => "I_2001",
        "comments" => [comment("C")]
      }

      conn =
        signed_post(build_conn(), entry["access_key_id"], seed, body,
          target: "/v1/source-items/comments",
          content_type: "application/json",
          delivery: nil,
          instance_id: entry["instance_id"]
        )

      assert json_response(conn, 404) == %{"error" => "not_found"}
      assert signed_answer?(conn)

      assert Repo.aggregate(Item, :count) == 0
      assert Repo.aggregate(Comment, :count) == 0
      assert Repo.aggregate("adapter_seen_requests", :count) == 0
    end
  end
end
