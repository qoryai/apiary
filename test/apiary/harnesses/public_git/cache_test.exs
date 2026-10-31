defmodule Apiary.Harnesses.PublicGit.CacheTest do
  use ExUnit.Case, async: true

  alias Apiary.Harnesses.PublicGit.Cache

  @git "https://github.com/acme/harness"
  @commit String.duplicate("a", 40)

  # A cache with a name and a budget for each test, so no other test's entries count.
  setup context do
    name = :"cache_#{System.unique_integer([:positive])}"
    start_supervised!({Cache, name: name, budget: context[:budget] || 1_000})
    %{name: name}
  end

  # The bytes an entry counts: its content, its key, and 64.
  defp bytes(path, content),
    do: byte_size(content || "") + byte_size(@git) + byte_size(@commit) + byte_size(path) + 64

  test "keeps a file and a file the commit does not have, and misses any other key", %{name: name} do
    assert Cache.get({@git, @commit, "harness.yaml"}, name) == :miss

    :ok = Cache.put({@git, @commit, "harness.yaml"}, "name: a\n", name)
    :ok = Cache.put({@git, @commit, "qory.yaml"}, nil, name)

    assert Cache.get({@git, @commit, "harness.yaml"}, name) == {:ok, "name: a\n"}
    assert Cache.get({@git, @commit, "qory.yaml"}, name) == {:ok, nil}
    assert Cache.get({@git, String.duplicate("b", 40), "harness.yaml"}, name) == :miss
    assert Cache.get({"https://github.com/other/harness", @commit, "harness.yaml"}, name) == :miss

    assert Cache.bytes(name) == bytes("harness.yaml", "name: a\n") + bytes("qory.yaml", nil)
  end

  test "a second put of a key keeps the first", %{name: name} do
    :ok = Cache.put({@git, @commit, "a"}, "one", name)
    :ok = Cache.put({@git, @commit, "a"}, "two", name)
    assert Cache.get({@git, @commit, "a"}, name) == {:ok, "one"}
    assert Cache.bytes(name) == bytes("a", "one")
  end

  @tag budget: 600
  test "removes the oldest entries until a new one fits, and never passes the budget",
       %{name: name} do
    content = String.duplicate("x", 100)
    # Each entry counts 100 + 31 + 40 + 1 + 64 = 236 bytes: two fit in 600.
    for path <- ~w(a b c), do: :ok = Cache.put({@git, @commit, path}, content, name)

    assert Cache.get({@git, @commit, "a"}, name) == :miss
    assert Cache.get({@git, @commit, "b"}, name) == {:ok, content}
    assert Cache.get({@git, @commit, "c"}, name) == {:ok, content}
    assert Cache.bytes(name) == 2 * bytes("a", content)
    assert Cache.bytes(name) <= 600

    # One larger entry takes the room of both.
    :ok = Cache.put({@git, @commit, "d"}, String.duplicate("y", 300), name)
    assert Cache.get({@git, @commit, "b"}, name) == :miss
    assert Cache.get({@git, @commit, "c"}, name) == :miss
    assert Cache.bytes(name) == bytes("d", String.duplicate("y", 300))
  end

  @tag budget: 300
  test "an entry larger than the budget is not kept, and removes nothing", %{name: name} do
    :ok = Cache.put({@git, @commit, "a"}, "small", name)
    :ok = Cache.put({@git, @commit, "b"}, String.duplicate("x", 300), name)

    assert Cache.get({@git, @commit, "b"}, name) == :miss
    assert Cache.get({@git, @commit, "a"}, name) == {:ok, "small"}
  end

  test "a cache that is not running misses, and takes no put" do
    assert Cache.get({@git, @commit, "a"}, :no_such_cache) == :miss
    assert Cache.put({@git, @commit, "a"}, "x", :no_such_cache) == :ok
  end
end
