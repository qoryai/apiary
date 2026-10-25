defmodule Apiary.Adapters.FeedTest do
  # An adapter's change feed (`Apiary.Adapters.Feed`): every entry of the contract's feed
  # fixtures appended and read back as the contract writes it, the entries the contract's
  # refused fixtures hold refused, the shapes held to their members and ranges, the order
  # entries are read in, a page and its cursor, a cursor past the end, one adapter's feed
  # apart from another's, and the last entry per collection_ref read from the start.
  use Apiary.DataCase, async: true

  import Apiary.NodesFixtures

  alias Apiary.Adapters.Feed
  alias Apiary.Repo

  @moduletag needs: :factory

  @fixtures Path.expand("../../fixtures/integration-contract/adapter", __DIR__)
  @url "https://control.example.com/work-items/wi_8Kx2mQ4vT9"
  @connection "ac_f1xt0re000000000"

  defp fixture(path), do: @fixtures |> Path.join(path) |> File.read!() |> Jason.decode!()

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
      for path <- ~w(changes/feed.json changes/feed-loopback.json changes/grants.json
                     changes/empty.json) do
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
      for path <- ~w(invalid/changes-sync-interval-30.json invalid/changes-unknown-kind.json
                     invalid/changes-work-item-status-linked.json
                     invalid/changes-work-item-url-http.json
                     invalid/changes-grant-status-taken-in.json
                     invalid/changes-grant-without-connection-id.json) do
        for change <- fixture(path)["changes"] do
          entry = Map.new(change, fn {k, v} -> {String.to_atom(k), v} end)
          raises(adapter, entry)
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
            %{kind: "grant", connection_id: @connection, grant_ref: "G_1", status: "unlinked"}
          ] do
        assert is_integer(append!(adapter, entry))
      end

      assert length(Feed.entries(adapter)) == 10
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

      assert Feed.entries(adapter) == []
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
