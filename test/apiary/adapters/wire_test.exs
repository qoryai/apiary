defmodule Apiary.Adapters.WireTest do
  # The body of an adapter's declaration read as the integration contract has it
  # (`adapter.schema.json`): the contract's fixtures accepted, and each field refused in
  # turn, with every value that is not exactly what the contract allows.
  use ExUnit.Case, async: true

  alias Apiary.Adapters.Wire

  @fixtures Path.expand("../../fixtures/integration-contract/adapter", __DIR__)

  defp fixture(path), do: @fixtures |> Path.join(path) |> File.read!()

  @valid %{
    "version" => 1,
    "time" => "2026-10-15T12:00:00Z",
    "connect_url" => "https://tracker-adapter.acme.example/connect",
    "sync" => %{"default_interval" => 900, "minimum_interval" => 300, "sends_changes" => false}
  }

  defp declaration(body), do: body |> Jason.encode!() |> read()

  defp read(raw) do
    with {:ok, body} <- Wire.decode(raw), do: Wire.declaration(body)
  end

  defp put_sync(key, value), do: put_in(@valid, ["sync", key], value)

  describe "the contract's fixtures" do
    test "the declarations of fixtures/adapter/adapter are accepted as written" do
      assert {:ok, declaration} = read(fixture("adapter/acme-tracker.json"))

      assert declaration == %{
               time: ~U[2026-10-15 12:00:00Z],
               connect_url: "https://tracker-adapter.acme.example/connect",
               default_interval: 900,
               minimum_interval: 300,
               sends_changes: false
             }

      assert {:ok, %{default_interval: 3600, minimum_interval: 60, sends_changes: true}} =
               read(fixture("adapter/code-host.json"))
    end

    test "the schema's refusal and the control plane's are refused" do
      for path <- [
            "invalid/adapter-sync-without-sends-changes.json",
            "refused-by-control-plane/adapter-integer-with-fraction.json",
            "refused-by-control-plane/adapter-repeated-member.json"
          ] do
        assert read(fixture(path)) == :error, path
      end
    end
  end

  test "a body that is no JSON object, or repeats a member at any depth, is refused" do
    for raw <- [
          "",
          "null",
          "[]",
          "1",
          ~s("text"),
          "{",
          ~s({"version":1,"version":1}),
          ~s({"a":{"b":1,"b":2}}),
          ~s({"a":[{"b":1,"b":2}]})
        ] do
      assert with({:ok, body} <- Wire.decode(raw), do: Wire.declaration(body)) == :error, raw
    end

    assert Wire.decode(nil) == :error
  end

  test "exactly the members the contract names, at the top and in sync" do
    assert {:ok, _} = declaration(@valid)

    for key <- Map.keys(@valid) do
      assert declaration(Map.delete(@valid, key)) == :error, "without #{key}"
    end

    assert declaration(Map.put(@valid, "name", "Acme")) == :error

    for key <- Map.keys(@valid["sync"]) do
      assert declaration(update_in(@valid, ["sync"], &Map.delete(&1, key))) == :error,
             "without sync.#{key}"
    end

    assert declaration(put_sync("full_listing", 86_400)) == :error
  end

  test "version is the integer 1" do
    for version <- [2, 0, "1", 1.0, nil, true] do
      assert declaration(Map.put(@valid, "version", version)) == :error, inspect(version)
    end

    assert read(
             ~s({"version":1.0,"time":"2026-10-15T12:00:00Z","connect_url":"https://a.example/c","sync":{"default_interval":900,"minimum_interval":300,"sends_changes":false}})
           ) ==
             :error
  end

  test "time is RFC 3339 in UTC with whole seconds" do
    for time <- [
          "2026-10-15T12:00:00.000Z",
          "2026-10-15T12:00:00+00:00",
          "2026-10-15T12:00:00",
          "2026-10-15 12:00:00Z",
          "2026-10-15t12:00:00z",
          "2026-02-30T12:00:00Z",
          "2026-10-15T25:00:00Z",
          "1792065600",
          1_792_065_600,
          nil
        ] do
      assert declaration(Map.put(@valid, "time", time)) == :error, inspect(time)
    end
  end

  describe "connect_url" do
    test "an https URI with a host is accepted, with a port, a path, a query or a fragment" do
      for url <- [
            "https://a.example",
            "https://a.example/",
            "https://a.example:8443/connect",
            "https://a.example/connect?install=1&x=%41#top",
            "https://[2001:db8::1]/connect",
            "https://192.0.2.10/connect"
          ] do
        assert Wire.url?(url), url
        assert {:ok, %{connect_url: ^url}} = declaration(Map.put(@valid, "connect_url", url))
      end

      long = "https://a.example/" <> String.duplicate("a", 2048 - 18)
      assert byte_size(long) == 2048
      assert Wire.url?(long)
    end

    test "anything else is refused" do
      for url <- [
            "http://a.example/connect",
            "HTTPS://a.example/connect",
            "https://",
            "https:///connect",
            "https://user@a.example/connect",
            "https://user:pass@a.example/connect",
            "https://a.example@b.example/connect",
            "https://a.example:0/connect",
            "https://a.example:65536/connect",
            "https://a.example:44x/connect",
            "https://a.example/con nect",
            "https://a.example/connect\n",
            "https://a.example/\\connect",
            "https://a.example/<script>",
            "https://a.example/\"x\"",
            "https://a.example/%zz",
            "https://a.example/%4",
            "https://a.example/connect#a#b",
            "https://bücher.example/connect",
            "javascript:alert(1)",
            "https://a.example/" <> String.duplicate("a", 2048 - 17),
            "",
            nil,
            42
          ] do
        refute Wire.url?(url), inspect(url)
        assert declaration(Map.put(@valid, "connect_url", url)) == :error, inspect(url)
      end
    end
  end

  describe "sync" do
    test "the intervals are integers from 60 to 86,400, the minimum at most the default" do
      for {default, minimum} <- [{60, 60}, {86_400, 86_400}, {86_400, 60}, {900, 900}] do
        assert {:ok, %{default_interval: ^default, minimum_interval: ^minimum}} =
                 declaration(
                   put_in(@valid, ["sync"], %{
                     "default_interval" => default,
                     "minimum_interval" => minimum,
                     "sends_changes" => true
                   })
                 )
      end

      for value <- [59, 86_401, 0, -60, 900.5, "900", nil, true] do
        assert declaration(put_sync("default_interval", value)) == :error, inspect(value)
        assert declaration(put_sync("minimum_interval", value)) == :error, inspect(value)
      end

      assert declaration(put_sync("minimum_interval", 901)) == :error
    end

    test "an interval written with a fraction or an exponent is refused" do
      for written <- ["900.0", "9e2", "9E2", "900e0"] do
        raw =
          ~s({"version":1,"time":"2026-10-15T12:00:00Z","connect_url":"https://a.example/c",) <>
            ~s("sync":{"default_interval":#{written},"minimum_interval":300,"sends_changes":false}})

        assert read(raw) == :error, written
      end
    end

    test "sends_changes is a boolean" do
      for value <- ["true", 1, 0, nil] do
        assert declaration(put_sync("sends_changes", value)) == :error, inspect(value)
      end
    end

    test "sync is an object" do
      for value <- [[], "x", nil, 900] do
        assert declaration(Map.put(@valid, "sync", value)) == :error, inspect(value)
      end
    end
  end

  describe "a listing of collections and a disconnect" do
    defp listing(path),
      do: with({:ok, body} <- Wire.decode(fixture(path)), do: Wire.listing(body))

    defp source_disconnect(path),
      do: with({:ok, body} <- Wire.decode(fixture(path)), do: Wire.source_disconnect(body))

    test "the contract's listings and disconnect are read as written" do
      assert {:ok,
              %{
                time: ~U[2026-10-15 12:00:00Z],
                connection_id: "ac_c0deh0st00000000",
                collections: [
                  %{
                    ref: "R_1001",
                    url: "https://github.com/acme/shop",
                    title: "acme/shop",
                    target: %{system: "github.com", path: "acme/shop"}
                  }
                ],
                listing: %{
                  id: "collections-7",
                  part: 1,
                  started_at: ~U[2026-10-15 11:59:58Z],
                  complete: true
                }
              }} = listing("source-collections/code-host.json")

      assert {:ok, %{collections: [%{ref: "TRK", target: nil}], listing: %{complete: false}}} =
               listing("source-collections/acme-tracker-part-1.json")

      assert {:ok, %{listing: %{part: 2, complete: true}}} =
               listing("source-collections/acme-tracker-part-2.json")

      assert source_disconnect("sources-disconnect/code-host.json") ==
               {:ok, %{time: ~U[2026-10-15 12:00:00Z], collection_ref: "R_1001"}}
    end

    test "the contract's invalid ones are refused" do
      assert listing("invalid/source-collections-no-listing.json") == :error
      assert listing("invalid/source-collections-part-10001.json") == :error
      assert source_disconnect("invalid/sources-disconnect-with-reason.json") == :error
      assert Wire.listing([]) == :error
      assert Wire.source_disconnect(nil) == :error
    end

    test "a ref named twice in one part is taken as named last" do
      {:ok, body} = Wire.decode(fixture("source-collections/code-host.json"))
      [one] = body["collections"]

      twice =
        Map.put(body, "collections", [
          one,
          %{"ref" => "B", "url" => "https://b.example", "title" => "B"},
          Map.put(one, "title", "renamed")
        ])

      assert {:ok, %{collections: [%{ref: "B"}, %{ref: "R_1001", title: "renamed"}]}} =
               Wire.listing(twice)
    end

    test "lengths are counted in code points" do
      {:ok, body} = Wire.decode(fixture("sources-disconnect/code-host.json"))

      # 200 code points of four bytes each, and of a base letter with a combining mark.
      assert {:ok, _} =
               Wire.source_disconnect(Map.put(body, "collection_ref", String.duplicate("😀", 200)))

      assert {:ok, _} =
               Wire.source_disconnect(
                 Map.put(body, "collection_ref", String.duplicate("e\u0301", 100))
               )

      assert Wire.source_disconnect(Map.put(body, "collection_ref", String.duplicate("😀", 201))) ==
               :error
    end
  end
end
