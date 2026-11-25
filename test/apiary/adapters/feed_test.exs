defmodule Apiary.Adapters.FeedTest do
  # An adapter's change feed (`Apiary.Adapters.Feed`): every entry of the contract's feed
  # fixtures appended and read back as the contract writes it, the entries the contract's
  # refused fixtures hold refused, the shapes held to their members and ranges, the order
  # entries are read in, a page and its cursor, a cursor past the end, one adapter's feed
  # apart from another's, and the last entry per collection_ref read from the start.
  use Apiary.DataCase, async: true

  import Apiary.NodesFixtures

  alias Apiary.Adapters.{ChangeRequest, Feed}
  alias Apiary.Repo

  @moduletag needs: :factory

  @fixtures Path.expand("../../fixtures/integration-contract/adapter", __DIR__)
  @url "https://control.example.com/work-items/wi_8Kx2mQ4vT9"
  @connection "ac_f1xt0re000000000"

  defp fixture(path), do: @fixtures |> Path.join(path) |> File.read!() |> Jason.decode!()

  # The fixtures that match `pattern`, each by its path under the fixtures, in order.
  defp fixtures(pattern) do
    @fixtures
    |> Path.join(pattern)
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, @fixtures))
    |> Enum.sort()
  end

  # The contract's answers whose entries an answer never has: every refused answer under
  # `invalid/` but the one without `revision`, whose entries are good, and the failure
  # reports and replies, which are no answer; and five answers that the contract's open
  # schema accepts, as it ignores a member that it does not define:
  # `changes/unknown-kind.json`, `closed/changes-watch-with-ref.json` and the three
  # `closed/changes-change-request-*.json`. This writer raises on the entries of those
  # five: it has no entry kind `settings` or `change_request`, and no `ref` on a `watch`
  # entry.
  defp refused_entries do
    Enum.reject(
      fixtures("{closed,invalid}/changes-*.json") ++ ["changes/unknown-kind.json"],
      &(String.starts_with?(&1, [
          "closed/changes-failed-",
          "closed/changes-submitted-",
          "invalid/changes-failed-",
          "invalid/changes-submitted-"
        ]) or &1 == "invalid/changes-without-revision.json")
    )
  end

  # The contract's fixtures of change_request entries.
  @change_requests ~w(changes/change-request-bid-changes.json
                      changes/change-request-empty-data.json
                      changes/change-request-pull-request-another-host.json
                      changes/change-request-pull-request-earlier-commits.json
                      changes/change-request-pull-request-one-commit.json
                      changes/change-request-pull-request-two-versions.json
                      changes/change-request-pull-request.json
                      changes/change-request-reply-marker-line.json
                      changes/change-request-reply.json)

  # A change as the contract writes it, as `append/2` takes it.
  defp entry(%{} = change), do: Map.new(change, fn {k, v} -> {String.to_existing_atom(k), v} end)

  defp append!(adapter, entry) do
    {:ok, seq} = Repo.transaction(fn -> elem(Feed.append(adapter, entry), 1) end)
    seq
  end

  defp read!(adapter, after_seq, opts \\ []) do
    {:ok, page} = Feed.read(adapter, after_seq, 1, opts)
    %{page | changes: Enum.map(page.changes, &(&1 |> Jason.encode!() |> Jason.decode!()))}
  end

  defp raises(adapter, entry) do
    assert_raise ArgumentError, fn -> Repo.transaction(fn -> Feed.append(adapter, entry) end) end
  end

  setup do
    %{adapter: adapter_fixture()}
  end

  describe "the contract's fixtures" do
    test "every change of changes/ is appended and read back as written, in order", %{
      adapter: adapter
    } do
      assert fixtures("changes/change-request-*.json") == @change_requests
      paths = fixtures("changes/*.json") -- ["changes/unknown-kind.json"]

      assert paths -- @change_requests ==
               ~w(changes/comment.json changes/empty.json changes/feed-loopback.json
                  changes/feed.json changes/grants.json changes/watch.json)

      for path <- paths do
        adapter = if path == "changes/feed.json", do: adapter, else: adapter_fixture()
        %{"changes" => changes} = fixture(path)

        seqs = Enum.map(changes, &append!(adapter, entry(&1)))
        assert seqs == Enum.to_list(1..length(changes)//1), path

        page = read!(adapter, 0)
        assert page.changes == changes, path
        assert page.seq == length(changes), path
      end
    end

    test "the entries of the refused fixtures are refused, and nothing is written", %{
      adapter: adapter
    } do
      # 31 of these 50 fixtures have change_request entries: the 28 under invalid/ fail
      # the contract's check, and the 3 under closed/ pass it with a member the contract
      # does not define.
      paths = refused_entries()
      assert length(paths) == 50
      assert "invalid/changes-comment-author-name-unicode-spaces.json" in paths
      assert "invalid/changes-watch-work-item-id-wrong-prefix.json" in paths

      requests =
        for path <- paths, String.contains?(path, "change-request"), do: path

      assert length(requests) == 31

      for path <- paths do
        assert [_ | _] = fixture(path)["changes"], path

        for change <- fixture(path)["changes"] do
          entry = Map.new(change, fn {k, v} -> {String.to_atom(k), v} end)
          raises(adapter, entry)

          if path in requests do
            closed? = String.starts_with?(path, "closed/")
            assert closed? == (ChangeRequest.validate(change) == :ok), path
          end
        end
      end

      assert Feed.entries(adapter) == []
    end
  end

  describe "append/2" do
    test "takes each shape and its every value in range", %{adapter: adapter} do
      ref = String.duplicate("é", 200)

      for entry <- [
            %{
              kind: "work_item",
              work_item_id: "wi_" <> String.duplicate("a", 64),
              ref: ref,
              status: "taken_in",
              url: @url
            },
            %{
              kind: "work_item",
              work_item_id: "wi_A-_9",
              ref: "r",
              status: "undone",
              url: "http://localhost/w"
            },
            %{
              kind: "work_item",
              work_item_id: "wi_x",
              ref: "r",
              status: "undone",
              url: "http://[::1]:4000"
            },
            %{kind: "collection", collection_ref: ref, status: "linked"},
            %{kind: "collection", collection_ref: "TRK", status: "unlinked"},
            %{kind: "sync", interval: nil},
            %{kind: "sync", interval: 60},
            %{kind: "sync", interval: 86_400},
            %{kind: "grant", connection_id: @connection, grant_ref: ref, status: "linked"},
            %{kind: "grant", connection_id: @connection, grant_ref: "G_1", status: "unlinked"},
            %{
              kind: "comment",
              comment_id: "sc_0123456789abcdef",
              ref: ref,
              author_name: String.duplicate("é", 100),
              body: String.duplicate("é", 65_000)
            },
            # The most a comment entry takes as text: each character of its body and ref a
            # control character, written as six.
            %{
              kind: "comment",
              comment_id: "sc_0123456789abcdef",
              ref: String.duplicate("\u0001", 200),
              author_name: String.duplicate("\u{1D11E}", 100),
              body: String.duplicate("\u0001", 65_000)
            },
            %{
              kind: "comment",
              comment_id: "sc_ghjkmnpqrstvwxyz",
              ref: "r",
              author_name: "\u3000a\u200D",
              body: "a"
            },
            %{kind: "watch", work_item_id: "wi_" <> String.duplicate("a", 64), url: @url},
            %{kind: "watch", work_item_id: "wi_A-_9", url: "http://127.0.0.1:4000/w"}
          ] do
        assert is_integer(append!(adapter, entry))
      end

      assert length(Feed.entries(adapter)) == 15
    end

    test "refuses a member missing, extra or out of range", %{adapter: adapter} do
      good = %{
        kind: "work_item",
        work_item_id: "wi_x",
        ref: "TRK-1",
        status: "taken_in",
        url: @url
      }

      for bad <- [
            Map.delete(good, :url),
            Map.put(good, :extra, 1),
            %{good | work_item_id: "wi_"},
            %{good | work_item_id: "wi_" <> String.duplicate("a", 65)},
            %{good | work_item_id: "ac_x"},
            %{good | work_item_id: "wi_a.b"},
            %{good | ref: ""},
            %{good | ref: String.duplicate("a", 201)},
            %{good | ref: "a" <> <<0>>},
            %{good | ref: <<0xFF>>},
            %{good | ref: 1},
            %{good | status: "linked"},
            %{good | url: "http://control.example.com/w"},
            %{good | url: "http://localhost.example.com/w"},
            %{good | url: "ftp://control.example.com/w"},
            %{good | url: "https://user@control.example.com/w"},
            %{good | url: "https://control.example.com/a b"},
            %{good | url: "https://control.example.com/%zz"},
            %{good | url: "https://"},
            %{good | url: "https://control.example.com:0/w"},
            %{good | url: "https://control.example.com/" <> String.duplicate("a", 2048)},
            %{kind: "collection", collection_ref: "TRK", status: "taken_in"},
            %{kind: "collection", collection_ref: "", status: "linked"},
            %{kind: "collection", collection_ref: "TRK"},
            %{kind: "collection", collection_ref: "TRK", status: "linked", ref: "x"},
            %{kind: "sync", interval: 59},
            %{kind: "sync", interval: 86_401},
            %{kind: "sync", interval: 600.0},
            %{kind: "sync"},
            %{kind: "settings", interval: 600},
            %{kind: "grant", connection_id: @connection, grant_ref: "G_1", status: "taken_in"},
            %{
              kind: "grant",
              connection_id: "ag_f1xt0re000000000",
              grant_ref: "G_1",
              status: "linked"
            },
            %{kind: "grant", connection_id: @connection, grant_ref: "", status: "linked"},
            %{kind: "grant", connection_id: @connection, grant_ref: "G_1"},
            %{
              kind: "grant",
              connection_id: @connection,
              grant_ref: "G_1",
              status: "linked",
              x: 1
            },
            %{"kind" => "sync", "interval" => nil}
          ] do
        raises(adapter, bad)
      end

      comment = %{
        kind: "comment",
        comment_id: "sc_0123456789abcdef",
        ref: "TRK-1",
        author_name: "Dana Example",
        body: "Start with the basket."
      }

      for bad <- [
            Map.delete(comment, :body),
            Map.put(comment, :extra, 1),
            %{comment | comment_id: "sc_0123456789ABCDEF"},
            %{comment | comment_id: "sc_0123456789abcdeu"},
            %{comment | comment_id: "sc_0123456789abcde"},
            %{comment | comment_id: "cm_0123456789abcdef"},
            %{comment | comment_id: nil},
            %{comment | ref: ""},
            %{comment | ref: String.duplicate("a", 201)},
            %{comment | author_name: ""},
            %{comment | author_name: String.duplicate("a", 101)},
            %{comment | author_name: " \u00A0\u1680\u2000\u200A\u202F\u205F\u3000"},
            %{comment | author_name: "\t "},
            %{comment | author_name: "Dana\nExample"},
            %{comment | author_name: "Dana\u0085Example"},
            %{comment | author_name: "Dana \u202Eelpmaxe"},
            %{comment | author_name: "Dana\u2028Example"},
            %{comment | author_name: "Dana\u200BExample"},
            %{comment | author_name: <<0xFF>>},
            %{comment | author_name: nil},
            %{comment | body: ""},
            %{comment | body: String.duplicate("a", 65_001)},
            %{comment | body: "a" <> <<0>>},
            %{comment | body: <<0xFF>>},
            %{comment | body: nil}
          ] do
        raises(adapter, bad)
      end

      watch = %{kind: "watch", work_item_id: "wi_x", url: @url}

      for bad <- [
            Map.delete(watch, :url),
            Map.delete(watch, :work_item_id),
            Map.put(watch, :ref, "TRK-1"),
            Map.put(watch, :status, "taken_in"),
            %{watch | work_item_id: "wi_"},
            %{watch | work_item_id: "wi_" <> String.duplicate("a", 65)},
            %{watch | work_item_id: "ac_x"},
            %{watch | work_item_id: "wi_a.b"},
            %{watch | work_item_id: nil},
            %{watch | url: "http://control.example.com/w"},
            %{watch | url: "ftp://control.example.com/w"},
            %{watch | url: "https://user@control.example.com/w"},
            %{watch | url: "https://control.example.com/a b"},
            %{watch | url: "https://"},
            %{watch | url: "https://control.example.com/" <> String.duplicate("a", 2048)},
            %{watch | url: nil}
          ] do
        raises(adapter, bad)
      end

      assert Feed.entries(adapter) == []
    end

    test "the table takes a change_request entry's data up to 1,400,000 bytes, a comment's up to 400,000, any other up to 4,096",
         %{adapter: adapter} do
      insert = fn seq, kind, data ->
        Repo.transaction(fn ->
          Repo.insert_all("adapter_feed", [
            %{
              id: Ecto.UUID.bingenerate(),
              adapter_id: Ecto.UUID.dump!(adapter.id),
              seq: seq,
              kind: kind,
              data: data,
              inserted_at: DateTime.utc_now()
            }
          ])
        end)
      end

      # `{"b": "…"}` as text is 9 bytes more than its value.
      assert {:ok, {1, _}} = insert.(1, "comment", %{"b" => String.duplicate("a", 399_991)})
      assert {:ok, {1, _}} = insert.(2, "sync", %{"b" => String.duplicate("a", 4087)})

      assert {:ok, {1, _}} =
               insert.(3, "change_request", %{"b" => String.duplicate("a", 1_399_991)})

      for {seq, kind, size} <- [
            {4, "comment", 399_992},
            {5, "sync", 4088},
            {6, "change_request", 1_399_992},
            {7, "note", 1}
          ] do
        assert_raise Postgrex.Error, ~r/adapter_feed_(data|kind)_check/, fn ->
          insert.(seq, kind, %{"b" => String.duplicate("a", size)})
        end
      end
    end

    test "takes a change_request entry with data at the contract's bound, and reads it back",
         %{adapter: adapter} do
      %{"changes" => [change]} = fixture("changes/change-request-reply.json")

      # A string inside a part has at most 20,000 characters: 39 of them, and a last member
      # `"k49":"…"`, 9 bytes with its comma, whose value makes up the rest.
      full = Map.new(10..48, &{"k#{&1}", String.duplicate("a", 20_000)})
      rest = ChangeRequest.max_data() - byte_size(Jason.encode!(full)) - 9

      data =
        Map.put(
          full,
          "k49",
          String.duplicate("é", div(rest, 2)) <> String.duplicate("a", rem(rest, 2))
        )

      assert byte_size(Jason.encode!(data)) == ChangeRequest.max_data()

      change = %{change | "data" => data}
      assert append!(adapter, entry(change)) == 1
      assert read!(adapter, 0).changes == [change]

      over = %{change | "data" => %{data | "k49" => data["k49"] <> "a"}}

      assert ChangeRequest.validate(over) ==
               {:error,
                %{
                  valid: false,
                  count: 1,
                  errors: [%{kind: :maxBytes, instanceLocation: "#/data"}]
                }}

      raises(adapter, entry(over))
      assert length(Feed.entries(adapter)) == 1
    end

    test "writes only inside a transaction, and only to an adapter's feed", %{adapter: adapter} do
      assert_raise ArgumentError, fn -> Feed.append(adapter, %{kind: "sync", interval: nil}) end

      assert_raise ArgumentError, fn ->
        Repo.transaction(fn ->
          Feed.append(%{adapter | kind: :node}, %{kind: "sync", interval: nil})
        end)
      end
    end

    test "an entry rolled back gives its number back", %{adapter: adapter} do
      assert append!(adapter, %{kind: "sync", interval: nil}) == 1

      Repo.transaction(fn ->
        {:ok, 2} = Feed.append(adapter, %{kind: "sync", interval: 60})
        Repo.rollback(:undone)
      end)

      assert append!(adapter, %{kind: "sync", interval: 120}) == 2
      assert Enum.map(Feed.entries(adapter), & &1.seq) == [1, 2]
    end
  end

  describe "read/4" do
    test "pages in order, the cursor at the page's end, and an empty page where it ends", %{
      adapter: adapter
    } do
      for interval <- 60..64, do: append!(adapter, %{kind: "sync", interval: interval})

      assert %{seq: 2, changes: [%{"interval" => 60}, %{"interval" => 61}]} =
               read!(adapter, 0, limit: 2)

      assert %{seq: 4, changes: [%{"interval" => 62}, %{"interval" => 63}]} =
               read!(adapter, 2, limit: 2)

      assert %{seq: 5, changes: [%{"interval" => 64}]} = read!(adapter, 4, limit: 2)
      assert read!(adapter, 5, limit: 2) == %{seq: 5, changes: []}
      assert Feed.page_size() == 100
    end

    test "ends a page before its body passes 4 MiB, the longest cursor counted", %{
      adapter: adapter
    } do
      other = adapter_fixture()

      comment = fn body ->
        %{
          kind: "comment",
          comment_id: "sc_0123456789abcdef",
          ref: "TRK-1",
          author_name: "Dana Example",
          body: body
        }
      end

      for feed <- [adapter, other],
          _n <- 1..64,
          do: append!(feed, comment.(String.duplicate("a", 65_000)))

      {:ok, %{seq: 64, changes: [first | _] = written}} = Feed.read(adapter, 0, 1)
      used = Enum.sum_by(written, &byte_size(Jason.encode!(&1))) + 63
      # The body with no entry and a cursor of eighteen digits, the longest one.
      envelope = byte_size(Feed.body(1, %{seq: 999_999_999_999_999_999, changes: []}))
      room = Feed.max_body() - envelope
      # What an entry takes besides its body's characters.
      shape = byte_size(Jason.encode!(first)) - 65_000
      # The 65th entry, with its comma, fills the room to its last byte.
      fits = room - used - 1 - shape
      assert fits in 1..65_000

      append!(adapter, comment.(String.duplicate("a", fits)))
      append!(adapter, comment.("a"))
      append!(other, comment.(String.duplicate("a", fits + 1)))
      append!(other, comment.("a"))

      assert {:ok, %{seq: 65, changes: changes} = page} = Feed.read(adapter, 0, 1)
      assert length(changes) == 65
      assert byte_size(Feed.body(1, page)) <= Feed.max_body()
      assert byte_size(Feed.body(1, %{page | seq: 999_999_999_999_999_999})) == Feed.max_body()
      assert %{seq: 66, changes: [%{"body" => "a"}]} = read!(adapter, 65)

      # One byte more, and the page ends before it; the next page starts with it.
      assert {:ok, %{seq: 64, changes: changes}} = Feed.read(other, 0, 1)
      assert length(changes) == 64
      assert %{seq: 66, changes: [%{"body" => body}, %{"body" => "a"}]} = read!(other, 64)
      assert byte_size(body) == fits + 1
    end

    test "counts the bytes of a character, not the character", %{
      adapter: adapter
    } do
      # 65,000 characters of four bytes each: 16 entries fit in 4 MiB, the 17th does not.
      body = String.duplicate("\u{1D11E}", 65_000)
      append!(adapter, %{kind: "sync", interval: 60})

      for _n <- 1..17 do
        append!(adapter, %{
          kind: "comment",
          comment_id: "sc_0123456789abcdef",
          ref: "TRK-1",
          author_name: "Dana Example",
          body: body
        })
      end

      assert {:ok, %{seq: 17, changes: [%{} = sync | comments]} = page} = Feed.read(adapter, 0, 1)
      assert Jason.encode!(sync) == ~s({"kind":"sync","interval":60})
      assert length(comments) == 16
      assert byte_size(Feed.body(1, page)) <= Feed.max_body()

      assert {:ok, %{seq: 18, changes: [%{} = last]}} = Feed.read(adapter, 17, 1)
      assert byte_size(Jason.encode!(last)) > 4 * 65_000
    end

    test "an empty feed reads as nothing from the start; any cursor past the end is stale", %{
      adapter: adapter
    } do
      assert read!(adapter, 0) == %{seq: 0, changes: []}
      assert Feed.read(adapter, 1, 1) == {:error, :stale}

      append!(adapter, %{kind: "sync", interval: nil})
      assert Feed.read(adapter, 2, 1) == {:error, :stale}
      assert read!(adapter, 1) == %{seq: 1, changes: []}
    end

    test "one adapter's feed holds nothing of another's", %{adapter: adapter} do
      other = adapter_fixture()
      append!(adapter, %{kind: "collection", collection_ref: "TRK", status: "linked"})
      append!(other, %{kind: "collection", collection_ref: "OPS", status: "linked"})
      append!(other, %{kind: "sync", interval: 600})

      assert read!(adapter, 0).changes == [
               %{"kind" => "collection", "collection_ref" => "TRK", "status" => "linked"}
             ]

      assert [%{"collection_ref" => "OPS"}, %{"interval" => 600}] = read!(other, 0).changes
      # The other's cursor, past this feed's end, is stale here.
      assert Feed.read(adapter, 2, 1) == {:error, :stale}
    end

    test "read from the start, the last entry per collection_ref is the link state", %{
      adapter: adapter
    } do
      for {ref, status} <- [
            {"TRK", "linked"},
            {"OPS", "linked"},
            {"TRK", "unlinked"},
            {"DOC", "linked"},
            {"OPS", "unlinked"},
            {"TRK", "linked"}
          ] do
        append!(adapter, %{kind: "collection", collection_ref: ref, status: status})
      end

      append!(adapter, %{kind: "sync", interval: nil})

      last =
        adapter
        |> read!(0)
        |> Map.fetch!(:changes)
        |> Enum.filter(&(&1["kind"] == "collection"))
        |> Map.new(&{&1["collection_ref"], &1["status"]})

      assert last == %{"TRK" => "linked", "OPS" => "unlinked", "DOC" => "linked"}

      # Paged two at a time, the same.
      paged =
        Stream.unfold(0, fn after_seq ->
          case read!(adapter, after_seq, limit: 2) do
            %{changes: []} -> nil
            %{seq: seq, changes: changes} -> {changes, seq}
          end
        end)
        |> Enum.concat()

      assert paged == read!(adapter, 0).changes
    end
  end

  describe "cursors" do
    test "are c_ and at least eight digits, and read back only as written" do
      assert Feed.cursor(0) == "c_00000000"
      assert Feed.cursor(46) == "c_00000046"
      assert Feed.cursor(123_456_789) == "c_123456789"

      for seq <- [0, 46, 99_999_999, 123_456_789],
          do: assert(Feed.parse_cursor(Feed.cursor(seq)) == {:ok, seq})

      for bad <- [
            "",
            "c_",
            "c_46",
            "c_0000046",
            "c_000000046",
            "C_00000046",
            "c_0000004a",
            "c_-0000046",
            " c_00000046",
            "c_00000046\n",
            "c_" <> String.duplicate("9", 19),
            nil,
            46
          ],
          do: assert(Feed.parse_cursor(bad) == :error, inspect(bad))
    end
  end
end
