defmodule Apiary.Adapters.CallWireTest do
  # The bodies of the calls for a run's credential, to resolve addresses and to read a
  # document, and their answers (`Apiary.Adapters.CallWire`), against the integration
  # contract's fixtures: each valid one accepted, each invalid one refused, and the
  # rules the schemas leave to the reader, checked one by one.
  use ExUnit.Case, async: true

  alias Apiary.Adapters.{CallWire, Wire}

  @fixtures Path.expand("../../fixtures/integration-contract/adapter", __DIR__)

  defp fixture(path) do
    {:ok, body} = @fixtures |> Path.join(path) |> File.read!() |> Wire.decode()
    body
  end

  # The fixtures' time, and a moment before every expires_at in them.
  @now ~U[2026-10-15 12:00:00Z]

  @paths %{
    "run-credential" => "run-credential",
    "resolve" => "resolve",
    "read" => "read"
  }

  defp call_path(name) do
    Enum.find_value(@paths, fn {prefix, path} ->
      if String.starts_with?(name, prefix <> "-") or name == prefix, do: path
    end)
  end

  defp answer(path, body, call \\ nil), do: CallWire.answer(path, body, call || call(path), @now)

  # The call each answer fixture answers.
  defp call("run-credential"), do: fixture("run-credential/read-harness.json")
  defp call("resolve"), do: fixture("resolve/two-addresses.json")
  defp call("read"), do: fixture("read/at-a-name.json")

  test "the valid calls are accepted as written" do
    for {dir, path} <- [
          {"run-credential", "run-credential"},
          {"resolve", "resolve"},
          {"read", "read"}
        ],
        file <- Path.wildcard(Path.join([@fixtures, dir, "*.json"])) do
      assert CallWire.call?(path, fixture(Path.relative_to(file, @fixtures))), file
    end

    refute CallWire.call?("other", fixture("resolve/two-addresses.json"))
  end

  test "the valid answers are read as written" do
    assert {:ok, %{"token" => "fixture-access-token-for-tests-only"}} =
             answer("run-credential", fixture("run-credential-answer/read.json"))

    assert {:ok, %{"apply" => [%{"scheme" => "basic", "username" => "x-access"}]}} =
             answer("run-credential", fixture("run-credential-answer/write-without-expiry.json"))

    assert answer("resolve", fixture("resolve-answer/one-covered.json")) ==
             {:ok,
              [
                %{
                  address: "https://code.example.com/acme/harness",
                  grant_ref: "G_1",
                  resource_ref: "R_1001"
                },
                %{address: "reader@code.example.com:acme/tools", covered: false}
              ]}

    assert answer("read", fixture("read-answer/at-a-fixed-version.json")) ==
             {:ok,
              %{
                resolved_at: "3f2a91c4d5e6f708192a3b4c5d6e7f8091a2b3c4",
                content: "harness:\n  extends:\n    ref: v1\n",
                found: true
              }}

    assert answer("read", fixture("read-answer/no-document.json")) ==
             {:ok,
              %{
                resolved_at: "3f2a91c4d5e6f708192a3b4c5d6e7f8091a2b3c4",
                content: nil,
                found: false
              }}
  end

  test "each invalid call and answer of the contract is refused" do
    names =
      @fixtures
      |> Path.join("invalid/{run-credential,resolve,read}*.json")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)

    assert length(names) == 39

    for name <- names do
      body = fixture("invalid/" <> name)
      path = call_path(name)

      if String.contains?(name, "-answer-"),
        do: assert(answer(path, body) == :error, name),
        else: refute(CallWire.call?(path, body), name)
    end
  end

  describe "a run credential's answer" do
    defp credential(changes) do
      body = fixture("run-credential-answer/read.json")
      put_in(body, ["credential"], Map.merge(body["credential"], changes))
    end

    test "expires_at is later than the call, with a zone, in any offset" do
      for value <- ["2026-10-15T12:00:01Z", "2026-10-15T15:00:00+02:00", "2026-10-15t13:00:00z"],
          do: assert({:ok, _} = answer("run-credential", credential(%{"expires_at" => value})))

      for value <- [
            "2026-10-15T12:00:00Z",
            "2026-10-15T13:00:00+02:00",
            "2026-10-15 13:00:00Z",
            1
          ] do
        assert answer("run-credential", credential(%{"expires_at" => value})) == :error,
               inspect(value)
      end
    end

    test "the token is 1 to 16,384 bytes, counted in bytes" do
      assert {:ok, _} =
               answer("run-credential", credential(%{"token" => String.duplicate("é", 8192)}))

      for token <- [String.duplicate("é", 8193), "", 1] do
        assert answer("run-credential", credential(%{"token" => token})) == :error
      end
    end

    test "each apply item has hosts, a scheme, and only the members the contract allows" do
      item = %{"hosts" => ["code.example.com"], "scheme" => "bearer"}

      for good <- [
            item,
            %{item | "scheme" => "header"} |> Map.put("header", "X-Token"),
            Map.put(item, "paths", ["/", "/api/*"])
          ] do
        assert {:ok, _} = answer("run-credential", credential(%{"apply" => [good]})),
               inspect(good)
      end

      for bad <- [
            Map.delete(item, "hosts"),
            Map.delete(item, "scheme"),
            %{item | "scheme" => "digest"},
            %{item | "hosts" => []},
            %{item | "hosts" => ["code.example.com", "code.example.com"]},
            %{item | "hosts" => ["Code.example.com"]},
            Map.put(item, "username", "a:b"),
            Map.put(item, "header", "X Token"),
            Map.put(item, "paths", []),
            Map.put(item, "paths", ["api/*"]),
            Map.put(item, "paths", ["/a*b"]),
            Map.put(item, "other", 1)
          ] do
        assert answer("run-credential", credential(%{"apply" => [bad]})) == :error, inspect(bad)
      end

      assert answer("run-credential", credential(%{"apply" => []})) == :error
      assert answer("run-credential", credential(%{"other" => 1})) == :error
    end
  end

  describe "a resolve answer" do
    test "has one result for each address, in the call's order" do
      body = fixture("resolve-answer/one-covered.json")
      [first, second] = body["results"]

      for results <- [[first], [second, first], [first, second, second]] do
        assert answer("resolve", %{body | "results" => results}) == :error
      end

      assert answer("resolve", %{body | "results" => [first, %{second | "address" => "other"}]}) ==
               :error

      assert answer("resolve", Map.put(body, "other", 1)) == :error

      assert answer("resolve", %{body | "results" => [Map.put(first, "covered", false), second]}) ==
               :error

      assert answer("resolve", %{body | "results" => [%{first | "grant_ref" => ""}, second]}) ==
               :error
    end
  end

  describe "a read answer" do
    test "its content is at most 262,144 bytes, counted in bytes" do
      body = fixture("read-answer/at-a-fixed-version.json")

      assert {:ok, %{found: true}} =
               answer("read", %{body | "content" => String.duplicate("é", 131_072)})

      assert answer("read", %{body | "content" => String.duplicate("é", 131_073)}) == :error
      assert {:ok, %{content: ""}} = answer("read", %{body | "content" => ""})
      assert answer("read", %{body | "resolved_at" => "a b"}) == :error
      assert answer("read", Map.put(body, "other", 1)) == :error
    end
  end

  test "an answer of another version or revision is refused" do
    body = fixture("read-answer/no-document.json")
    assert answer("read", %{body | "revision" => 2}) == :error
    assert answer("read", %{body | "version" => 2}) == :error
    assert answer("read", Map.delete(body, "revision")) == :error
  end

  test "a ref, an address, a document's path and a version ref, one by one" do
    assert CallWire.ref?("G_1")
    assert CallWire.ref?(String.duplicate("é", 200))
    refute CallWire.ref?(String.duplicate("a", 201))
    refute CallWire.ref?("")
    refute CallWire.ref?("a\u0000b")

    assert CallWire.address?("reader@code.example.com:acme/tools")
    refute CallWire.address?("a b")
    refute CallWire.address?(String.duplicate("a", 2049))

    for path <- ["qory.yaml", "docs/qory.yaml", ".qory/a", "..a/b", "a/.b", "é/ü"],
        do: assert(CallWire.document_path?(path), path)

    for path <- ["", "/a", "a/", "a//b", ".", "..", "a/./b", "a/../b", "a\u0000"],
        do: refute(CallWire.document_path?(path), inspect(path))

    assert CallWire.version_ref?("refs/heads/main")
    refute CallWire.version_ref?("a b")
    refute CallWire.version_ref?(String.duplicate("a", 256))
  end
end
