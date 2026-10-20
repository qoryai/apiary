defmodule ApiaryWeb.Contract.SourceItemCommentsTest do
  # `POST /v1/source-items/comments`, signed with an adapter's access key, through
  # `ApiaryWeb.Contract.AdapterRequest`: every body of the contract's
  # `source-item-comments/` fixtures accepted, with a signed 204, and every one of its
  # invalid ones refused; the refusals before the body in their order, 413, 415, 400, then
  # 401, then the body's 400, then its time's 401; each refusal of the comments in the
  # contract's order, an `item_ref` the adapter has no item for answered
  # collection_not_linked, each code and body as the contract's refusal fixtures have
  # them, signed; the time's window and the replay rule; and the path read raw also when
  # written with escapes.
  use ApiaryWeb.ConnCase, async: true

  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1, unsigned_answer?: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SourcesFixtures, only: [item: 1, items_body: 2, comment: 1, key_scope: 1]
  import Apiary.WorkItemsFixtures, only: [source_collection_fixture: 3, source_item_fixture: 2]

  alias Apiary.{Edition, EditionStubs, Repo, Sources}
  alias Apiary.Adapters.Connections
  alias Apiary.Sources.{Comment, Item}
  alias ApiaryWeb.Contract.{RawBody, SignedRequest}

  @moduletag needs: :factory

  @fixtures Path.expand("../../fixtures/integration-contract/adapter", __DIR__)
  @target "/v1/source-items/comments"
  @invalid %{"error" => "invalid_request"}
  @unauthorized %{"error" => "unauthorized"}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{adapter: adapter, access_key: key, pair: pair} = connectable_adapter_fixture()
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    key_scope = key_scope(key)

    # The items the contract's bodies name, of collections linked to the scope's
    # workspace.
    for {collection_ref, refs} <- [{"TRK", ~w(TRK-1 TRK-3 TRK-9)}, {"R_1001", ~w(I_2001)}] do
      source_collection_fixture(scope, connection, %{external_ref: collection_ref})

      {:ok, :accepted} =
        Sources.post_items(key_scope, items_body(collection_ref, Enum.map(refs, &item/1)))
    end

    %{scope: scope, key: key, seed: pair.secret, connection: connection, key_scope: key_scope}
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

  defp comments(item_ref, offset) do
    %{
      "version" => 1,
      "time" => now_time(offset),
      "item_ref" => item_ref,
      "comments" => [comment("C")]
    }
  end

  defp comments_of(ref) do
    item = Repo.get_by!(Item, external_ref: ref)

    Comment
    |> Repo.all()
    |> Enum.filter(&(&1.item_id == item.id))
    |> Enum.sort_by(& &1.external_ref)
  end

  defp count(schema), do: Repo.aggregate(schema, :count)

  defp refusal(name), do: fixture("refusal/#{name}.json")

  describe "the contract's bodies" do
    test "each of source-item-comments/ is a signed 204 with no body, and its comments are kept",
         ctx do
      paths = fixtures("source-item-comments/*.json")
      assert paths != []

      for path <- paths do
        conn = send_post(ctx, fresh(path))
        assert conn.status == 204, path
        assert conn.resp_body == ""
        assert signed_answer?(conn), path
      end

      assert [%Comment{external_ref: "C-11"}, %Comment{external_ref: "C-12"}] =
               comments_of("TRK-1")

      assert [%Comment{external_ref: "C-91", truncated: ["body"]}] = comments_of("TRK-9")
      assert [%Comment{external_ref: "IC_3001", deleted_at: %DateTime{}}] = comments_of("I_2001")
      assert comments_of("TRK-3") == []
    end

    test "each invalid one is 400 invalid_request, signed, before its time is read", ctx do
      paths = fixtures("invalid/source-item-comments-*.json")
      assert paths != []

      # Sent as written, their times not made fresh: the body is refused before its time
      # is read.
      for path <- paths do
        conn = send_post(ctx, raw_fixture(path))
        assert json_response(conn, 400) == @invalid, path
        assert signed_answer?(conn), path
      end

      assert count(Comment) == 0
    end

    test "a body past a bound of the request is 400 invalid_request, signed", ctx do
      body = fresh("source-item-comments/acme-tracker-complete.json")
      [first | _] = body["comments"]

      for bad <- [
            Map.put(body, "version", 2),
            Map.put(body, "extra", true),
            Map.delete(body, "time"),
            Map.put(body, "item_ref", ""),
            Map.put(body, "item_ref", String.duplicate("r", 201)),
            Map.put(body, "item_ref", 1),
            Map.put(body, "complete", %{}),
            Map.put(body, "comments", List.duplicate(first, 101)),
            Map.put(body, "comments", [Map.put(first, "deleted", false)])
          ] do
        conn = send_post(ctx, bad)
        assert json_response(conn, 400) == @invalid, inspect(bad, limit: 5)
        assert signed_answer?(conn)
      end

      raw = Jason.encode!(body)

      for broken <- [
            String.replace(raw, ~s("version":1), ~s("version":1,"version":1)),
            "[]",
            "not json"
          ] do
        conn = send_post(ctx, broken)
        assert json_response(conn, 400) == @invalid, broken
        assert signed_answer?(conn)
      end

      assert count(Comment) == 0
    end
  end

  describe "the refusals before the body" do
    test "413, then 415, then 400 bad_request, then 401, each unsigned, then the body's 400, signed",
         ctx do
      body = fresh("source-item-comments/acme-tracker-complete.json")
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

      assert count(Comment) == 0
    end

    test "a stale or future time, or a replay, is 401, unsigned, and changes nothing", ctx do
      for offset <- [-310, 310] do
        conn = send_post(ctx, fresh("source-item-comments/code-host-deleted.json", offset))
        assert json_response(conn, 401) == @unauthorized, "#{offset}"
        assert unsigned_answer?(conn)
      end

      assert count(Comment) == 0

      raw = Jason.encode!(fresh("source-item-comments/code-host-deleted.json"))
      conn = send_post(ctx, raw)
      assert conn.status == 204
      assert signed_answer?(conn)
      kept = Repo.one!(Comment)

      conn = send_post(ctx, raw)
      assert json_response(conn, 401) == @unauthorized
      assert unsigned_answer?(conn)
      assert Repo.one!(Comment) == kept
    end
  end

  describe "the refusals of the comments" do
    test "forbidden, then connection_ended, then connection_suspended, then collection_not_linked; each the contract's body, signed",
         ctx do
      unlinked =
        source_collection_fixture(ctx.scope, ctx.connection, %{
          external_ref: "UNLINKED",
          workspace_id: nil
        })

      source_item_fixture(ctx.scope, collection: unlinked, external_ref: "U-1")

      # Not linked: an item of a collection linked to no workspace, and an item_ref the
      # adapter has no item for.
      for {ref, offset} <- [{"U-1", 0}, {"NEVER", 1}] do
        conn = send_post(ctx, comments(ref, offset))
        assert json_response(conn, 409) == refusal("collection-not-linked"), ref
        assert signed_answer?(conn)
      end

      # Suspended before not linked, for an item of a live collection; an item_ref with no
      # item is not linked.
      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [ctx.scope.organisation.id])

      for {ref, offset} <- [{"TRK-1", 2}, {"U-1", 3}] do
        conn = send_post(ctx, comments(ref, offset))
        assert json_response(conn, 409) == refusal("connection-suspended"), ref
        assert signed_answer?(conn)
      end

      conn = send_post(ctx, comments("NEVER", 4))
      assert json_response(conn, 409) == refusal("collection-not-linked")

      # Ended before suspended.
      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)
      conn = send_post(ctx, comments("TRK-1", 5))
      assert json_response(conn, 409) == refusal("connection-ended")
      assert signed_answer?(conn)

      # Forbidden before all, whatever the item_ref.
      Edition.put_test_stub(__MODULE__.NoPost)

      for {ref, offset} <- [{"TRK-1", 6}, {"NEVER", 7}] do
        conn = send_post(ctx, comments(ref, offset))
        assert json_response(conn, 403) == %{"error" => "forbidden"}, ref
        assert signed_answer?(conn)
      end

      assert count(Comment) == 0
    end
  end

  test "the path read raw also when written with escapes", ctx do
    conn =
      send_post(ctx, fresh("source-item-comments/code-host-deleted.json"),
        target: "/v1/source-items/%63omments"
      )

    assert conn.status == 204
    assert signed_answer?(conn)
    assert [%Comment{external_ref: "IC_3001"}] = comments_of("I_2001")
  end

  defmodule NoPost do
    @moduledoc false
    def check(_scope, :"source_item.post", _subject), do: {:error, :forbidden}
    def check(scope, action, subject), do: Apiary.Edition.module().check(scope, action, subject)
  end
end
