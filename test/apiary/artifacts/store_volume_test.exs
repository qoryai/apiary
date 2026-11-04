defmodule Apiary.Artifacts.Store.VolumeTest do
  # Not async: the store's root is the application's setting.
  use ExUnit.Case, async: false

  alias Apiary.Artifacts.Store
  alias Apiary.Artifacts.Store.Volume

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "store")
    previous = Application.get_env(:apiary, :artifacts_dir)
    Application.put_env(:apiary, :artifacts_dir, root)
    on_exit(fn -> Application.put_env(:apiary, :artifacts_dir, previous) end)
    %{root: root}
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp staging(root), do: Path.wildcard(Path.join(root, ".staging-*"), match_dot: true)

  test "is the store in use unless the configuration sets another" do
    assert Store.impl() == Volume
  end

  test "keeps a content at a path made from its digest alone", %{root: root} do
    digest = sha256("gift cards")
    assert {:ok, staged} = Volume.stage({:binary, "gift cards"}, 100)
    assert %{sha256: ^digest, size: 10} = staged
    assert Path.dirname(staged.path) == root
    assert File.stat!(staged.path).mode |> Bitwise.band(0o777) == 0o600

    assert {:ok, ^digest} = Volume.commit(staged)
    <<a::binary-size(2), b::binary-size(2), _rest::binary>> = digest
    path = Path.join([root, a, b, digest])
    assert {:ok, ^path} = Volume.open(digest)
    assert File.read!(path) == "gift cards"
    assert staging(root) == []
  end

  test "keeps the same content once", %{root: root} do
    {:ok, one} = Volume.stage({:binary, "same"}, 100)
    {:ok, two} = Volume.stage({:binary, "same"}, 100)
    assert {:ok, key} = Volume.commit(one)
    assert {:ok, ^key} = Volume.commit(two)

    assert Path.wildcard(Path.join(root, "*/*/*")) == [
             Path.join([root, binary_part(key, 0, 2), binary_part(key, 2, 2), key])
           ]

    assert staging(root) == []
  end

  test "removes at a commit the staged copies of the root older than an hour", %{root: root} do
    {:ok, left} = Volume.stage({:binary, "left by a killed push"}, 100)
    {:ok, fresh} = Volume.stage({:binary, "a push in progress"}, 100)
    File.touch!(left.path, System.os_time(:second) - 3601)
    # Another old file of the root, not a staged copy, stays.
    other = Path.join(root, "notes.tmp")
    File.write!(other, "other")
    File.touch!(other, System.os_time(:second) - 7200)

    {:ok, staged} = Volume.stage({:binary, "gift cards"}, 100)
    assert {:ok, _key} = Volume.commit(staged)

    assert staging(root) == [fresh.path]
    assert File.exists?(other)
    assert {:ok, _key} = Volume.commit(fresh)
  end

  test "reads a path in chunks and stops past the limit", %{root: root, tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source")
    File.write!(source, :binary.copy("x", 300_000))

    assert {:error, :too_large} = Volume.stage({:path, source}, 299_999)
    assert staging(root) == []

    assert {:ok, %{size: 300_000} = staged} = Volume.stage({:path, source}, 300_000)
    assert staged.sha256 == sha256(File.read!(source))
    Volume.discard(staged)
    assert staging(root) == []
  end

  test "refuses a binary over the limit before it writes a byte", %{root: root} do
    assert {:error, :too_large} = Volume.stage({:binary, "12345"}, 4)
    assert staging(root) == []
  end

  test "refuses a source that cannot be read", %{tmp_dir: tmp_dir} do
    assert {:error, :unreadable} = Volume.stage({:path, Path.join(tmp_dir, "missing")}, 10)
    assert {:error, :unreadable} = Volume.stage({:path, tmp_dir}, 10)
    assert {:error, :unreadable} = Volume.stage(:other, 10)
  end

  test "makes no path from a key that is not a digest" do
    for key <- ["../../etc/passwd", String.duplicate("A", 64), String.duplicate("a", 63), "", nil] do
      assert {:error, :invalid_key} = Volume.open(key)
      assert {:error, :invalid_key} = Volume.path(key)
    end

    assert {:error, :not_found} = Volume.open(String.duplicate("0", 64))
  end

  test "has nothing to do with no root set" do
    Application.put_env(:apiary, :artifacts_dir, " ")
    assert Volume.root() == nil
    assert {:error, :no_root} = Volume.stage({:binary, "a"}, 10)
    assert {:error, :no_root} = Volume.open(String.duplicate("0", 64))
  end
end
