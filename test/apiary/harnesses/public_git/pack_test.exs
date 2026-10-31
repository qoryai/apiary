defmodule Apiary.Harnesses.PublicGit.PackTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Apiary.Harnesses.PublicGit.Pack
  alias Apiary.PackBuilder, as: B

  @fixtures "test/fixtures/public_git"

  defp read(pack, opts \\ []), do: Pack.read(pack, opts)

  # What Pack.read/1 returns in a process whose heap may not pass `limit` bytes:
  # `:killed` for one that passes it.
  defp read_in_heap(pack, limit) do
    words = div(limit, :erlang.system_info(:wordsize))

    {_pid, monitor} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: words, kill: true, error_logger: false})
        exit({:read, Pack.read(pack)})
      end)

    receive do
      {:DOWN, ^monitor, :process, _pid, {:read, result}} -> result
      {:DOWN, ^monitor, :process, _pid, reason} -> reason
    end
  end

  describe "objects" do
    test "reads whole objects by their ids" do
      pack = B.pack([{:blob, "hello\n"}, {:tree, ""}, {:commit, "tree x\n"}])

      assert {:ok, %{objects: objects, inflated: inflated}} = read(pack)
      assert objects[B.id(:blob, "hello\n")] == {:blob, "hello\n"}
      assert objects[B.id(:tree, "")] == {:tree, ""}
      # Each object counts 256 bytes beside its bytes.
      assert inflated == byte_size("hello\n") + byte_size("tree x\n") + 3 * 256
    end

    test "applies an offset delta and a reference delta, in either order in the pack" do
      base = "the quick brown fox"
      result = "quick brown fox ran fast"
      delta = B.delta(19, byte_size(result), [{:copy, 4, 15}, {:insert, " ran fast"}])

      assert {:ok, %{objects: objects}} = read(B.pack([{:blob, base}, {:ofs, 0, delta}]))
      assert objects[B.id(:blob, result)] == {:blob, result}

      # A reference delta before its base.
      pack = B.pack([{:ref, B.id(:blob, base), delta}, {:blob, base}])
      assert {:ok, %{objects: objects}} = read(pack)
      assert objects[B.id(:blob, result)] == {:blob, result}
    end

    test "resolves a chain of deltas, and refuses one longer than the depth cap" do
      chain = for _ <- 1..5, do: {:ofs, 0, B.delta(1, 1, [{:copy, 0, 1}])}

      # Each delta on the one before it.
      entries =
        [{:blob, "a"}] ++
          Enum.with_index(chain, fn {:ofs, _, delta}, i -> {:ofs, i, delta} end)

      assert {:ok, _} = read(B.pack(entries), max_depth: 5)
      assert read(B.pack(entries), max_depth: 4) == {:error, :invalid}
    end

    test "reads a SHA-256 pack" do
      pack = B.pack([{:blob, "x"}], hash: :sha256)
      assert {:ok, %{objects: objects}} = read(pack, hash: :sha256)
      assert objects[B.id(:blob, "x", :sha256)] == {:blob, "x"}
    end

    test "reads a tree's entries and a commit's tree" do
      id = :crypto.hash(:sha, "f")
      tree = "100644 harness.yaml" <> <<0>> <> id <> "40000 stacks" <> <<0>> <> id

      assert Pack.tree_entry(tree, "stacks", 20) == {:ok, "40000", id}
      assert Pack.tree_entry(tree, "harness.yaml", 20) == {:ok, "100644", id}
      assert Pack.tree_entry(tree, "qory.yaml", 20) == :none
      assert Pack.tree_entry("100644 a" <> <<0>> <> "short", "a", 20) == :invalid
      assert Pack.tree_entry("1x0644 a" <> <<0>> <> id, "a", 20) == :invalid

      hex = String.duplicate("ab", 20)

      assert Pack.commit_tree("tree #{hex}\nparent x\n", 20) ==
               {:ok, Base.decode16!(hex, case: :lower)}

      assert Pack.commit_tree("parent #{hex}\n", 20) == :invalid
    end
  end

  describe "hostile packs" do
    test "a blob that declares 64 MiB, a zlib bomb, is too large before it is inflated" do
      assert read(File.read!(Path.join(@fixtures, "zlib-bomb.pack"))) == {:error, :too_large}
    end

    test "a stream that inflates past its declared size stops there" do
      assert read(File.read!(Path.join(@fixtures, "zlib-bomb-understated.pack"))) ==
               {:error, :invalid}
    end

    test "a delta that declares a result of 1 GiB is too large before it is applied" do
      assert read(File.read!(Path.join(@fixtures, "oversized-delta.pack"))) ==
               {:error, :too_large}
    end

    test "the objects of a pack together stay within the budget" do
      pack = B.pack([{:blob, String.duplicate("a", 600)}, {:blob, String.duplicate("b", 600)}])
      assert {:ok, _} = read(pack, budget: 1200 + 2 * 256)
      assert read(pack, budget: 1199 + 2 * 256) == {:error, :too_large}
    end

    test "a delta's result counts toward the budget" do
      pack =
        B.pack([{:blob, "abc"}, {:ofs, 0, B.delta(3, 300, List.duplicate({:copy, 0, 3}, 100))}])

      assert {:ok, _} = read(pack, budget: 3 + 300 + 100 * 3 + 2 * 256)
      assert read(pack, budget: 3 + 300 + 2 * 256) == {:error, :too_large}
    end

    test "a delta of millions of one-byte copies is applied in a bounded heap" do
      count = 5_500_000
      delta = B.delta(1, count, []) <> :binary.copy(<<0x90, 0x01>>, count)
      result = :binary.copy("a", count)

      assert {:ok, %{objects: objects}} =
               read_in_heap(B.pack([{:blob, "a"}, {:ofs, 0, delta}]), 32 * 1024 * 1024)

      assert objects[B.id(:blob, result)] == {:blob, result}
    end

    test "a delta of millions of one-byte inserts is applied in a bounded heap" do
      count = 5_500_000
      delta = B.delta(1, count, []) <> :binary.copy(<<0x01, ?b>>, count)
      result = :binary.copy("b", count)

      assert {:ok, %{objects: objects}} =
               read_in_heap(B.pack([{:blob, "a"}, {:ofs, 0, delta}]), 32 * 1024 * 1024)

      assert objects[B.id(:blob, result)] == {:blob, result}
    end

    test "a delta whose result passes its declared size, or falls short of it, is invalid" do
      for size <- [2, 4] do
        pack = B.pack([{:blob, "abc"}, {:ofs, 0, B.delta(3, size, [{:copy, 0, 3}])}])
        assert read(pack) == {:error, :invalid}
      end
    end

    test "a delta that copies past its base, or names another base size, is invalid" do
      for delta <- [
            B.delta(3, 4, [{:copy, 0, 4}]),
            B.delta(3, 1, [{:copy, 3, 1}]),
            B.delta(4, 3, [{:copy, 0, 3}])
          ] do
        assert read(B.pack([{:blob, "abc"}, {:ofs, 0, delta}])) == {:error, :invalid}
      end
    end

    test "a reference delta on itself, two on each other, or on a missing base, is invalid" do
      delta = B.delta(1, 1, [{:copy, 0, 1}])
      self_id = B.id(:blob, "a")

      # Its result is "a", whose id is its base's.
      assert read(B.pack([{:ref, self_id, delta}])) == {:error, :invalid}

      a = :crypto.hash(:sha, "a")
      b = :crypto.hash(:sha, "b")
      assert read(B.pack([{:ref, a, delta}, {:ref, b, delta}])) == {:error, :invalid}

      assert read(B.pack([{:blob, "x"}, {:ref, :crypto.hash(:sha, "missing"), delta}])) ==
               {:error, :invalid}
    end

    test "an offset delta that points at no object, or past the pack's start, is invalid" do
      delta = B.delta(3, 3, [{:copy, 0, 3}])
      good = B.pack([{:blob, "abc"}, {:ofs, 0, delta}])
      assert {:ok, _} = read(good)

      # One byte back is inside the blob; 127 bytes back is before the first object.
      for back <- [1, 127] do
        pack =
          B.pack([{:blob, "abc"}, {:raw, 6, byte_size(delta), <<back>> <> :zlib.compress(delta)}])

        assert read(pack) == {:error, :invalid}
      end
    end

    test "a pack of more objects than the cap is too large, before any is inflated" do
      blobs = for n <- 1..11, do: {:blob, <<n>>}
      assert {:ok, %{objects: objects}} = read(B.pack(blobs), max_objects: 11)
      assert map_size(objects) == 11
      assert read(B.pack(blobs), max_objects: 10) == {:error, :too_large}

      # The default cap: 50,001 one-byte blobs, about 600 KB of pack.
      many = for n <- 0..50_000, do: {:blob, <<rem(n, 256)>> <> <<div(n, 256)::16>>}
      assert read(B.pack(many)) == {:error, :too_large}
    end

    test "each object counts 256 bytes against the budget, however small" do
      blobs = for n <- 1..10, do: {:blob, <<n>>}
      assert {:ok, %{inflated: 2570}} = read(B.pack(blobs), budget: 2570)
      assert read(B.pack(blobs), budget: 2569) == {:error, :too_large}
    end

    test "an object of an unknown type, a count over the bytes, or a wrong checksum is invalid" do
      assert read(B.pack([{:raw, 5, 1, :zlib.compress("a")}])) == {:error, :invalid}
      assert read(B.pack([{:blob, "a"}], count: 2)) == {:error, :invalid}
      assert read(B.pack([{:blob, "a"}], count: 1_000_000)) == {:error, :invalid}
      pack = B.pack([{:blob, "a"}])
      assert read(binary_part(pack, 0, byte_size(pack) - 1) <> "x") == {:error, :invalid}
    end
  end

  describe "properties" do
    property "a pack built from any blobs reads back every blob" do
      check all(blobs <- list_of(binary(max_length: 300), min_length: 1, max_length: 8)) do
        assert {:ok, %{objects: objects}} = read(B.pack(Enum.map(blobs, &{:blob, &1})))
        for blob <- blobs, do: assert(objects[B.id(:blob, blob)] == {:blob, blob})
      end
    end

    property "a truncated pack is refused, never raised on" do
      check all(
              blobs <- list_of(binary(max_length: 200), min_length: 1, max_length: 4),
              cut <- integer(0..400)
            ) do
        pack = B.pack(Enum.map(blobs, &{:blob, &1}))
        cut = min(cut, byte_size(pack) - 1)
        assert {:error, _} = read(binary_part(pack, 0, cut))
      end
    end

    property "any bytes, or a pack with bytes changed, read or are refused, never raised on" do
      check all(
              blob <- binary(max_length: 200),
              at <- integer(0..1000),
              byte <- integer(0..255),
              noise <- binary(max_length: 200)
            ) do
        pack = B.pack([{:blob, blob}, {:ofs, 0, B.delta(byte_size(blob), 0, [])}])
        at = rem(at, byte_size(pack))
        <<head::binary-size(^at), _::8, tail::binary>> = pack
        changed = head <> <<byte>> <> tail

        for bytes <- [changed, noise, "PACK" <> noise] do
          assert match?({:ok, %{objects: _}}, read(bytes)) or match?({:error, _}, read(bytes))
        end
      end
    end

    property "a delta of any instructions reads within its declared size, or is refused" do
      check all(
              base <- binary(min_length: 1, max_length: 64),
              ops <-
                list_of(
                  one_of([
                    map(binary(min_length: 1, max_length: 20), &{:insert, &1}),
                    map({integer(0..80), integer(1..80)}, fn {o, s} -> {:copy, o, s} end)
                  ]),
                  max_length: 6
                ),
              declared <- integer(0..400)
            ) do
        delta = B.delta(byte_size(base), declared, ops)

        case read(B.pack([{:blob, base}, {:ofs, 0, delta}])) do
          {:ok, %{objects: objects}} ->
            assert Enum.all?(objects, fn {_id, {_type, data}} ->
                     byte_size(data) <= max(declared, byte_size(base))
                   end)

          {:error, reason} ->
            assert reason in [:invalid, :too_large]
        end
      end
    end

    property "many tiny objects read within the object cap and the budget, or are too large" do
      check all(
              n <- integer(1..400),
              max_objects <- integer(1..400),
              budget <- integer(0..120_000)
            ) do
        blobs = for i <- 1..n, do: {:blob, <<i::16>>}

        case read(B.pack(blobs), max_objects: max_objects, budget: budget) do
          {:ok, %{objects: objects, inflated: inflated}} ->
            assert n <= max_objects
            assert map_size(objects) == n
            assert inflated == n * (2 + 256) and inflated <= budget

          {:error, reason} ->
            assert reason == :too_large
            assert n > max_objects or n * (2 + 256) > budget
        end
      end
    end

    property "a reference delta chain in any order resolves, and a cycle never does" do
      check all(n <- integer(1..6), seed <- integer()) do
        :rand.seed(:exsss, {seed, 1, 2})
        # Blob "a", then each delta appends one byte to the one before.
        results = for i <- 0..n, do: String.duplicate("a", i + 1)

        deltas =
          for i <- 1..n do
            base = Enum.at(results, i - 1)

            {:ref, B.id(:blob, base),
             B.delta(byte_size(base), i + 1, [{:copy, 0, i}, {:insert, "a"}])}
          end

        entries = Enum.shuffle([{:blob, "a"} | deltas])
        assert {:ok, %{objects: objects}} = read(B.pack(entries))
        assert map_size(objects) == n + 1

        # Without the blob, every delta waits on a base that never comes.
        assert read(B.pack(Enum.shuffle(deltas))) == {:error, :invalid}
      end
    end
  end
end
