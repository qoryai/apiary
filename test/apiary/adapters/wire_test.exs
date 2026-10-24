defmodule Apiary.Adapters.WireTest do
  # The body of an adapter's declaration read as the integration contract has it
  # (`adapter.schema.json`): the contract's fixtures accepted, the declaration with a
  # setup_url among them, its invalid ones refused, each setup_url one for its setup_url
  # alone, and each field refused in turn, with every value that is not exactly what the
  # contract allows.
  use ExUnit.Case, async: true

  import Apiary.DescriptionFixtures, only: [contract_description: 0, contract_description: 1]

  alias Apiary.Adapters.Wire
  alias Apiary.Integrations.Description

  @fixtures Path.expand("../../fixtures/integration-contract/adapter", __DIR__)

  defp fixture(path), do: @fixtures |> Path.join(path) |> File.read!()

  @base %{
    "version" => 1,
    "time" => "2026-10-15T12:00:00Z",
    "connect_url" => "https://tracker-adapter.acme.example/connect",
    "sync" => %{"default_interval" => 900, "minimum_interval" => 300, "sends_changes" => false}
  }

  # A valid body: `@base` with the contract's description of an example tracker.
  defp valid, do: Map.put(@base, "description", contract_description())

  defp declaration(body), do: body |> Jason.encode!() |> read()

  defp read(raw), do: Wire.declaration(raw)

  defp put_sync(key, value), do: put_in(valid(), ["sync", key], value)

  describe "the contract's fixtures" do
    test "acme-tracker.json and code-host.json of fixtures/adapter/adapter are accepted as written" do
      assert {:ok, declaration} = read(fixture("adapter/acme-tracker.json"))

      assert %{
               time: ~U[2026-10-15 12:00:00Z],
               connect_url: "https://tracker-adapter.acme.example/connect",
               default_interval: 900,
               minimum_interval: 300,
               sends_changes: false,
               description: %Description{name: "example-tracker"} = description
             } = declaration

      assert Enum.sort(Map.keys(declaration)) ==
               ~w(connect_url default_interval description minimum_interval sends_changes setup_url time)a

      # Without a setup_url, the adapter has nothing to set up.
      assert declaration.setup_url == nil

      assert Description.item_noun(description) == %{one: "issue", other: "issues"}
      assert Description.collection_noun(description) == %{one: "project", other: "projects"}
      assert Description.items?(description)

      assert {:ok, %{default_interval: 3600, minimum_interval: 60, sends_changes: true}} =
               read(fixture("adapter/code-host.json"))
    end

    test "a description's numbers follow the description schema: 1e3 and 0.5 are read" do
      assert {:ok, %{description: description}} = read(fixture("adapter/settings-numbers.json"))

      assert description.document["settings"]["properties"]["weight"] ==
               %{"type" => "number", "maximum" => 1.0e3, "multipleOf" => 0.5}
    end

    test "acme-tracker-setup.json, with a setup_url and a query, is accepted as written" do
      assert {:ok, declaration} = read(fixture("adapter/acme-tracker-setup.json"))

      assert %{
               time: ~U[2026-10-15 12:00:00Z],
               connect_url: "https://tracker-adapter.acme.example/connect",
               setup_url: "https://tracker-adapter.acme.example/setup?site=main",
               description: %Description{}
             } = declaration
    end

    test "the schema's refusals and the control plane's are refused" do
      names =
        Path.wildcard(Path.join(@fixtures, "invalid/adapter-*.json")) ++
          Path.wildcard(Path.join(@fixtures, "refused-by-control-plane/adapter-*.json"))

      assert Enum.map(names, &Path.relative_to(&1, @fixtures)) == [
               "invalid/adapter-description-item-noun-upper-case.json",
               "invalid/adapter-description-string.json",
               "invalid/adapter-description-version-2.json",
               "invalid/adapter-description-without-roles.json",
               # Each refused for its setup_url alone: "setup_url" below.
               "invalid/adapter-setup-url-and-state.json",
               "invalid/adapter-setup-url-bare-state.json",
               "invalid/adapter-setup-url-fragment.json",
               "invalid/adapter-setup-url-http.json",
               "invalid/adapter-setup-url-state-first.json",
               "invalid/adapter-setup-url-state-percent-encoded.json",
               "invalid/adapter-setup-url-state.json",
               "invalid/adapter-sync-without-sends-changes.json",
               "invalid/adapter-without-description.json",
               "refused-by-control-plane/adapter-integer-with-fraction.json",
               "refused-by-control-plane/adapter-repeated-member.json"
             ]

      for name <- names, do: assert(read(File.read!(name)) == :error, name)
    end
  end

  describe "the description" do
    # `valid()` encoded, with the description's value written as `raw`.
    defp with_description(raw) do
      marker = "description-placeholder"

      valid()
      |> Map.put("description", marker)
      |> Jason.encode!()
      |> String.replace(~s("#{marker}"), raw)
    end

    test "is required, and must be one the description reader accepts" do
      assert declaration(Map.delete(valid(), "description")) == :error

      for value <- [nil, "x", [], 1, %{}, Map.delete(contract_description(), "roles")] do
        assert declaration(Map.put(valid(), "description", value)) == :error, inspect(value)
      end

      for name <- ~w(invalid/description-source-item-noun-upper-case.json
                     invalid/description-source-collection-noun-empty.json
                     refused-by-reader/description-member-repeated.json) do
        raw = File.read!(Path.expand("../../fixtures/integration-contract/" <> name, __DIR__))
        assert read(with_description(raw)) == :error, name
      end
    end

    test "with no source role, it gives the defaults" do
      assert {:ok, %{description: description}} =
               declaration(
                 Map.put(valid(), "description", contract_description("acme-tracker.json"))
               )

      assert Description.item_noun(description) == nil
      assert Description.collection_noun(description) == nil
      assert Description.items?(description)
    end

    test "is taken as the body writes it: its whitespace, escapes and numbers as sent" do
      raw = Jason.encode!(contract_description(), pretty: true)
      assert {:ok, _} = read(with_description(raw))

      # A member name written with an escape is the same member.
      escaped =
        String.replace(with_description(raw), ~s("description":), ~s("descr\\u0069ption":),
          global: false
        )

      assert escaped =~ ~s("descr\\u0069ption")
      assert {:ok, %{description: %Description{}}} = read(escaped)

      # A number with an exponent inside the description is the description schema's to
      # read, and it allows one.
      with_exponent =
        contract_description()
        |> put_in(["settings", "properties"], %{
          "weight" => %{"type" => "number", "maximum" => "max"}
        })
        |> Jason.encode!()
        |> String.replace(~s("max"), "1e3")

      assert {:ok, %{description: description}} = read(with_description(with_exponent))
      assert description.document["settings"]["properties"]["weight"]["maximum"] == 1.0e3
    end

    test "is refused with a member twice, at any depth inside it" do
      raw = Jason.encode!(contract_description())

      for repeated <- [
            String.replace(raw, ~s("version":1), ~s("version":1,"version":1)),
            String.replace(raw, ~s("type":"object"), ~s("type":"object","type":"object")),
            String.replace(raw, ~s("one":"issue"), ~s("one":"issue","one":"bug"))
          ] do
        assert repeated != raw
        assert read(with_description(repeated)) == :error, repeated
      end
    end

    test "is at most 262144 bytes as the body carries it, never as it encodes again" do
      # 4000 numbers written `1e5`, three bytes each, which Jason writes again as `1.0e5`,
      # five, in a role the schema does not name, and strings of at most 16384 bytes to
      # bring the value to exactly 262144 bytes: encoded again, it is 8000 bytes longer.
      with_pad = fn pad ->
        contract_description()
        |> put_in(["roles", "acme_role"], %{
          "numbers" => List.duplicate(List.duplicate("n", 1000), 4),
          "pad" => pad
        })
        |> Jason.encode!()
        |> String.replace(~s("n"), "1e5")
      end

      # Inside its brackets the pad's list holds `count` strings, each with its quotes, and
      # a comma between two: `needed` bytes in all.
      needed = 262_144 - byte_size(with_pad.([]))
      count = div(needed, 16_384 + 3) + 1
      letters = needed - 3 * count + 1

      lengths =
        for i <- 1..count, do: div(letters, count) + if(i <= rem(letters, count), do: 1, else: 0)

      at_limit = with_pad.(Enum.map(lengths, &String.duplicate("p", &1)))

      assert byte_size(at_limit) == 262_144
      assert Enum.max(lengths) <= 16_384

      # Its values, counted as the reader counts them, stay under the reader's 4096: the
      # value is read, or refused, for its size alone.
      values = at_limit |> Jason.decode!() |> count_values()
      assert values < 4096, "#{values} values"
      assert byte_size(at_limit |> Jason.decode!() |> Jason.encode!()) == 262_144 + 8000

      assert {:ok, %{description: description}} = read(with_description(at_limit))

      assert description.document["roles"]["acme_role"]["numbers"] ==
               List.duplicate(List.duplicate(1.0e5, 1000), 4)

      # Whitespace around the value is the body's, not the value's.
      assert {:ok, _} = read(with_description("\n  " <> at_limit <> "  \n"))

      # One byte more, whitespace inside the value included, is refused.
      over = String.replace_suffix(at_limit, "}", " }")
      assert byte_size(over) == 262_145
      assert Jason.decode!(over) == Jason.decode!(at_limit)
      assert read(with_description(over)) == :error
      assert Description.parse(over) == {:error, {:description_invalid, [:too_large]}}
    end
  end

  # The values of a decoded document, the document itself, every entry and every
  # member's value, as `Apiary.Kinds.Bounds` counts them.
  defp count_values(%{} = map),
    do: 1 + (map |> Map.values() |> Enum.map(&count_values/1) |> Enum.sum())

  defp count_values(list) when is_list(list),
    do: 1 + (list |> Enum.map(&count_values/1) |> Enum.sum())

  defp count_values(_scalar), do: 1

  describe "the scan for the description's bytes" do
    test "steps over the strings, objects and lists before it, whatever they hold" do
      raw =
        ~S({"a":"{[\"}]\\","b":{"c":"}\"{","d":[1,"]",{"e":"\\\""}]},) <>
          ~S("description" : {"x":"}{\""} , "z":1})

      assert {:ok, _} = Wire.decode(raw)
      assert Wire.member_value(raw, "description") == {:ok, ~S({"x":"}{\""})}
    end

    test "takes the top-level member, not one nested before it" do
      raw =
        ~S({"meta":{"description":"inner","list":[{"description":[1]}]},"description":[2,3]})

      assert {:ok, _} = Wire.decode(raw)
      assert Wire.member_value(raw, "description") == {:ok, "[2,3]"}
      assert Wire.member_value(~S({"a":{"description":1}}), "description") == :error
      assert Wire.member_value(~S({"Description":1}), "description") == :error
    end

    test "finds the member last, its value without the whitespace around it" do
      assert Wire.member_value(~s({"a":1,"description":"text"\n}), "description") ==
               {:ok, ~s("text")}

      assert Wire.member_value(~s({"description":12.5e3}), "description") == {:ok, "12.5e3"}
      assert Wire.member_value(~s({"a":[],"description":true }), "description") == {:ok, "true"}
      assert Wire.member_value(~s({"description":{}}), "description") == {:ok, "{}"}
    end

    test "reads a member's name with its escapes" do
      assert Wire.member_value(~S({"descr\u0069ption":{"y":1}}), "description") ==
               {:ok, ~S({"y":1})}

      assert Wire.member_value(~S({"description\/":1,"description":2}), "description") ==
               {:ok, "2"}
    end

    test "answers :error, never raises, on a body it cannot read" do
      for raw <- [
            "",
            " ",
            "{",
            "[]",
            ~S({"a"),
            ~S({"a":),
            ~S({"a":"x),
            "{\"a\":\"\\",
            ~S({"a":{),
            ~S({"a":{"b":"}),
            ~S({"a":[1,{]),
            ~S({"descr\u00),
            ~s(\uFEFF{"description":1}),
            ~s({"a":1,\f"description":1}),
            ~s({"a"\f:1,"description":1})
          ] do
        assert Wire.member_value(raw, "description") == :error, inspect(raw)
      end

      assert Wire.member_value(nil, "description") == :error
    end

    test "a declaration is read with its description first, in the middle or last" do
      description =
        put_in(contract_description(), ["roles", "acme_role"], %{
          "text" => "}{\"][\\",
          "description" => %{"description" => "inner"}
        })

      members = valid() |> Map.put("description", description) |> Enum.sort()

      {[{"description", _} = first], rest} =
        Enum.split_with(members, &(elem(&1, 0) == "description"))

      for order <- [
            [first | rest],
            Enum.take(rest, 2) ++ [first | Enum.drop(rest, 2)],
            rest ++ [first]
          ] do
        raw = order |> Jason.OrderedObject.new() |> Jason.encode!()
        assert {:ok, %{description: got}} = read(raw), raw
        assert got.document == description
      end
    end

    test "a body with a byte order mark or whitespace JSON does not have is refused" do
      raw = Jason.encode!(valid())
      assert {:ok, _} = read(raw)

      for changed <- [
            "\uFEFF" <> raw,
            String.replace(raw, ~s(,"description":), ~s(,\f"description":)),
            String.replace(raw, ~s(,"description":), ~s(,\u00A0"description":)),
            String.replace(raw, ~s(,"description":), ~s(,\v"description":))
          ] do
        assert changed != raw
        assert read(changed) == :error, inspect(changed)
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
      assert Wire.declaration(raw) == :error, raw
    end

    assert Wire.decode(nil) == :error
  end

  test "exactly the members the contract names, at the top and in sync" do
    assert {:ok, _} = declaration(valid())

    for key <- Map.keys(valid()) do
      assert declaration(Map.delete(valid(), key)) == :error, "without #{key}"
    end

    assert declaration(Map.put(valid(), "name", "Acme")) == :error

    for key <- Map.keys(valid()["sync"]) do
      assert declaration(update_in(valid(), ["sync"], &Map.delete(&1, key))) == :error,
             "without sync.#{key}"
    end

    assert declaration(put_sync("full_listing", 86_400)) == :error
  end

  test "version is the integer 1" do
    # Jason writes 1.0 as `1.0`, so the body carries the version with a fraction.
    assert Jason.encode!(Map.put(valid(), "version", 1.0)) =~ ~s("version":1.0})

    for version <- [2, 0, "1", 1.0, nil, true] do
      assert declaration(Map.put(valid(), "version", version)) == :error, inspect(version)
    end

    assert {:ok, _} = read(Jason.encode!(valid()))
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
      assert declaration(Map.put(valid(), "time", time)) == :error, inspect(time)
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
        assert {:ok, %{connect_url: ^url}} = declaration(Map.put(valid(), "connect_url", url))
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
        assert declaration(Map.put(valid(), "connect_url", url)) == :error, inspect(url)
      end
    end
  end

  # One test per rule in the description of `$defs/url` (`definitions.schema.json`).
  describe "url?/1" do
    test "a URL is at most 2048 characters" do
      assert Wire.url?("https://a.example/" <> String.duplicate("a", 2048 - 18))
      refute Wire.url?("https://a.example/" <> String.duplicate("a", 2048 - 17))
    end

    test "a URL starts with https:// and a host" do
      assert Wire.url?("https://a.example")

      for url <- [
            "http://a.example/",
            "HTTPS://a.example/",
            "https:a.example/",
            "https://",
            "https:///x"
          ] do
        refute Wire.url?(url), url
      end
    end

    test "a host name is letters, digits and the characters -._~!$&'()*+,;=" do
      assert Wire.url?("https://Az09-._~!$&'()*+,;=/x")

      for url <- [
            "https://a\"b/",
            "https://a<b/",
            "https://a{b/",
            "https://a[b/",
            "https://a]b/",
            "https://a|b/"
          ] do
        refute Wire.url?(url), url
      end
    end

    test "a host name takes the percent-encodings %80 to %FF in either case, and %25" do
      for url <- [
            "https://ex%c3%a9mple.com/",
            "https://ex%C3%A9mple.com/",
            "https://ex%80mple.com/",
            "https://ex%FFmple.com/",
            "https://ex%ffmple.com/",
            "https://ex%25mple.com/"
          ] do
        assert Wire.url?(url), url
      end

      for url <- [
            "https://ex%41mple.com/x",
            "https://ex%7Fmple.com/",
            "https://ex%00mple.com/",
            "https://ex%2fmple.com/",
            "https://ex%2Fmple.com/"
          ] do
        refute Wire.url?(url), url
      end
    end

    test "a host is an IPv6 address in brackets as RFC 3986 writes one" do
      for url <- [
            "https://[::1]",
            "https://[::]/x",
            "https://[2001:db8::1]/x",
            "https://[1:2:3:4:5:6:7:8]/x",
            "https://[::ffff:192.0.2.1]/x",
            "https://[1::2:3:4:5:6:7]/x"
          ] do
        assert Wire.url?(url), url
      end

      for url <- [
            "https://[1:2:3:4:5:6:7:8:9]/x",
            "https://[1:2:3:4:5:6:7]/x",
            "https://[1::2::3]/x",
            "https://[12345::1]/x",
            "https://[::ffff:192.0.2.256]/x",
            "https://[v1.x]/x",
            "https://[fe80::1%25eth0]/x",
            "https://[a.example]/x",
            "https://[]/x"
          ] do
        refute Wire.url?(url), url
      end
    end

    test "only a port, a path, a query or a fragment follows an IPv6 address's closing bracket" do
      for url <- [
            "https://[::1]:8080/x",
            "https://[::1]:/x",
            "https://[::1]/x",
            "https://[::1]?x",
            "https://[::1]#x"
          ] do
        assert Wire.url?(url), url
      end

      for url <- [
            "https://[::1]ab/x",
            "https://[::1].x/",
            "https://[::1]]/x",
            "https://[::1]a.example/"
          ] do
        refute Wire.url?(url), url
      end
    end

    test "no user information comes before the host" do
      for url <- [
            "https://user@a.example/",
            "https://user:pass@a.example/",
            "https://@a.example/",
            "https://a@[::1]/"
          ] do
        refute Wire.url?(url), url
      end

      assert Wire.url?("https://a.example/@x")
    end

    test "a colon after the host stands alone or is followed by a port of at most 5 digits from 1 to 65535" do
      for url <- [
            "https://a.example:",
            "https://a.example:/x",
            "https://a.example:1/x",
            "https://a.example:65535/x",
            "https://a.example:00080/x",
            "https://a.example:00001"
          ] do
        assert Wire.url?(url), url
      end

      for url <- [
            "https://a.example:0/x",
            "https://a.example:00000/x",
            "https://a.example:65536/x",
            "https://a.example:000080/x",
            "https://a.example:44x/x",
            "https://a.example::80/x",
            "https://a.example:-1/x"
          ] do
        refute Wire.url?(url), url
      end
    end

    test "a path, a query and a fragment are each optional, in that order, with RFC 3986's characters" do
      for url <- [
            "https://a.example/a/b;c=d/:@!$&'()*+,~-._",
            "https://a.example?q=1&r=/?",
            "https://a.example/x?q=1#f/?:@",
            "https://a.example#f",
            "https://a.example//x"
          ] do
        assert Wire.url?(url), url
      end

      for url <- [
            "https://a.example/a[b]",
            "https://a.example/?a[b]=1",
            "https://a.example/#a[b]",
            "https://a.example/x#a#b"
          ] do
        refute Wire.url?(url), url
      end
    end

    test "every % starts a percent-encoding, % and two hexadecimal digits" do
      assert Wire.url?("https://a.example/%41%7e?%2F#%fF")

      for url <- [
            "https://a.example/%zz",
            "https://a.example/%4",
            "https://a.example/?%",
            "https://a.example/#%g0",
            "https://a%.example/"
          ] do
        refute Wire.url?(url), url
      end
    end

    test "a URL has no character outside RFC 3986's" do
      for url <- [
            "https://a.example/con nect",
            "https://a.example/x\n",
            "https://a.example/\\x",
            "https://a.example/<x>",
            "https://a.example/\"x\"",
            "https://a.example/x^y",
            "https://a.example/x`y",
            "https://bücher.example/",
            "https://a.example/\u0000"
          ] do
        refute Wire.url?(url), inspect(url)
      end
    end

    test "anything other than a string is refused" do
      for value <- [nil, 42, :"https://a.example", ~c"https://a.example"] do
        refute Wire.url?(value), inspect(value)
      end
    end
  end

  describe "setup_url" do
    # Each of the contract's invalid setup_url fixtures, its setup_url as written, and the
    # same address with its fault taken out.
    @setup_url_faults [
      {"adapter-setup-url-and-state.json",
       "https://tracker-adapter.acme.example/setup?site=main&state=x",
       "https://tracker-adapter.acme.example/setup?site=main"},
      {"adapter-setup-url-bare-state.json", "https://tracker-adapter.acme.example/setup?state",
       "https://tracker-adapter.acme.example/setup"},
      {"adapter-setup-url-fragment.json", "https://tracker-adapter.acme.example/setup#start",
       "https://tracker-adapter.acme.example/setup"},
      {"adapter-setup-url-http.json", "http://tracker-adapter.acme.example/setup",
       "https://tracker-adapter.acme.example/setup"},
      {"adapter-setup-url-state-first.json",
       "https://tracker-adapter.acme.example/setup?state&x=1",
       "https://tracker-adapter.acme.example/setup?x=1"},
      {"adapter-setup-url-state-percent-encoded.json",
       "https://tracker-adapter.acme.example/setup?%73tate=1",
       "https://tracker-adapter.acme.example/setup"},
      {"adapter-setup-url-state.json", "https://tracker-adapter.acme.example/setup?state=x",
       "https://tracker-adapter.acme.example/setup"}
    ]

    test "each invalid fixture is refused for its setup_url: with the fault taken out, it is accepted" do
      assert Enum.map(@setup_url_faults, &elem(&1, 0)) ==
               @fixtures
               |> Path.join("invalid/adapter-setup-url-*.json")
               |> Path.wildcard()
               |> Enum.map(&Path.basename/1)

      for {name, written, fixed} <- @setup_url_faults do
        raw = fixture("invalid/" <> name)
        body = Jason.decode!(raw)
        assert body["setup_url"] == written, name

        assert read(raw) == :error, name
        refute Wire.setup_url?(written), name

        # The same body with the address's fault taken out, or with no setup_url, is read.
        assert {:ok, %{setup_url: ^fixed}} = declaration(Map.put(body, "setup_url", fixed)),
               name

        assert {:ok, %{setup_url: nil}} = declaration(Map.delete(body, "setup_url")), name
      end
    end

    test "is optional, and nil when the body gives none" do
      assert {:ok, %{setup_url: nil}} = declaration(valid())
    end

    test "an https URI with no fragment and no state parameter is accepted, any other query too" do
      for url <- [
            "https://a.example",
            "https://a.example/setup",
            "https://a.example:8443/setup",
            "https://a.example/setup?site=main",
            "https://a.example/setup?site=main&x=%41",
            "https://a.example/setup?",
            "https://a.example/setup?states=1",
            "https://a.example/setup?xstate=1",
            "https://a.example/setup?a=state",
            "https://a.example/setup?a=1&states",
            "https://a.example/setup?State=1",
            "https://a.example/state?site=main",
            "https://a.example/setup?site=a/state",
            "https://[2001:db8::1]/setup"
          ] do
        assert Wire.setup_url?(url), url
        assert {:ok, %{setup_url: ^url}} = declaration(Map.put(valid(), "setup_url", url))
      end

      long = "https://a.example/" <> String.duplicate("a", 2048 - 18)
      assert byte_size(long) == 2048
      assert Wire.setup_url?(long)
    end

    test "a fragment, a state parameter in any form, or what no connect address may be is refused" do
      for url <- [
            "https://a.example/setup#",
            "https://a.example/setup#start",
            "https://a.example/setup?site=main#start",
            "https://a.example/setup?state",
            "https://a.example/setup?state=",
            "https://a.example/setup?state=x",
            "https://a.example/setup?state&x=1",
            "https://a.example/setup?x=1&state",
            "https://a.example/setup?x=1&state=y",
            "https://a.example/setup?x=1&&state=y",
            "https://a.example/setup?%73tate=1",
            "https://a.example/setup?st%61te=1",
            "https://a.example/setup?%73%74%61%74%65=1",
            "https://a.example/setup?x=1&stat%65",
            "http://a.example/setup",
            "https://user@a.example/setup",
            "https://a.example:0/setup",
            "https://a.example/se tup",
            "https://a.example/%zz",
            "https://a.example/" <> String.duplicate("a", 2048 - 17),
            "",
            nil,
            42
          ] do
        refute Wire.setup_url?(url), inspect(url)
        assert declaration(Map.put(valid(), "setup_url", url)) == :error, inspect(url)
      end
    end
  end

  describe "sync" do
    test "the intervals are integers from 60 to 86,400, the minimum at most the default" do
      for {default, minimum} <- [{60, 60}, {86_400, 86_400}, {86_400, 60}, {900, 900}] do
        assert {:ok, %{default_interval: ^default, minimum_interval: ^minimum}} =
                 declaration(
                   put_in(valid(), ["sync"], %{
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
      raw = Jason.encode!(valid())
      assert {:ok, %{default_interval: 900}} = read(raw)

      for written <- ["900.0", "9e2", "9E2", "900e0"] do
        changed =
          String.replace(raw, ~s("default_interval":900,), ~s("default_interval":#{written},))

        assert changed != raw, written
        assert read(changed) == :error, written
      end
    end

    test "sends_changes is a boolean" do
      for value <- ["true", 1, 0, nil] do
        assert declaration(put_sync("sends_changes", value)) == :error, inspect(value)
      end
    end

    test "sync is an object" do
      for value <- [[], "x", nil, 900] do
        assert declaration(Map.put(valid(), "sync", value)) == :error, inspect(value)
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
                    target: %{system: "github.com", path: "acme/shop"},
                    items: true
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
               {:ok,
                %{
                  time: ~U[2026-10-15 12:00:00Z],
                  connection_id: "ac_c0deh0st00000000",
                  collection_ref: "R_1001"
                }}
    end

    test "the contract's invalid ones are refused" do
      assert listing("invalid/source-collections-no-listing.json") == :error
      assert listing("invalid/source-collections-part-10001.json") == :error

      for name <- ~w(null string true) do
        assert listing("invalid/source-collections-items-#{name}.json") == :error, name
      end

      for name <- ~w(201 empty nul) do
        assert listing("invalid/source-collections-environment-ref-#{name}.json") == :error,
               name
      end

      assert source_disconnect("invalid/sources-disconnect-with-reason.json") == :error
      assert source_disconnect("invalid/sources-disconnect-without-connection-id.json") == :error
      assert Wire.listing([]) == :error
      assert Wire.source_disconnect(nil) == :error
    end

    test "a collection's items is false when given, and true when not; any other value is refused" do
      {:ok, body} = Wire.decode(fixture("source-collections/code-host-items-false.json"))
      [_with_environment, without_items] = body["collections"]

      assert {:ok,
              %{collections: [%{ref: "C_2001", items: true}, %{ref: "C_2002", items: false}]}} =
               Wire.listing(body)

      for value <- [true, nil, "false", 0, %{}] do
        assert Wire.listing(
                 Map.put(body, "collections", [Map.put(without_items, "items", value)])
               ) == :error,
               inspect(value)
      end
    end

    test "a collection's environment_ref is read as given, and is nil when absent" do
      assert {:ok,
              %{
                collections: [
                  %{ref: "C_2001", environment_ref: "env-3f2a91c4"},
                  %{ref: "C_2002", environment_ref: nil}
                ]
              }} = listing("source-collections/code-host-environment-ref.json")

      assert {:ok, %{collections: [%{environment_ref: nil}]}} =
               listing("source-collections/code-host.json")

      {:ok, body} = Wire.decode(fixture("source-collections/code-host-environment-ref.json"))
      [first | rest] = body["collections"]
      with_ref = &Map.put(body, "collections", [Map.put(first, "environment_ref", &1) | rest])

      # 1 to 200 code points, as a ref; a string, never null.
      for ref <- ["e", String.duplicate("😀", 200), String.duplicate("e\u0301", 100)] do
        assert {:ok, %{collections: [%{environment_ref: ^ref} | _]}} =
                 Wire.listing(with_ref.(ref))
      end

      for ref <- ["", String.duplicate("😀", 201), "a\u0000b", nil, 7, ["env"], %{}] do
        assert Wire.listing(with_ref.(ref)) == :error, inspect(ref)
      end
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

    test "a disconnect's connection_id is required, and is a connection's public id" do
      {:ok, body} = Wire.decode(fixture("sources-disconnect/code-host.json"))
      assert Wire.source_disconnect(Map.delete(body, "connection_id")) == :error

      for id <- [
            nil,
            "",
            7,
            ["ac_c0deh0st00000000"],
            "ac_c0deh0st0000000",
            "ac_c0deh0st000000000",
            "AC_C0DEH0ST00000000",
            "na_c0deh0st00000000",
            "sc_c0deh0st00000000",
            "ac_c0deh0st0000000u"
          ] do
        assert Wire.source_disconnect(Map.put(body, "connection_id", id)) == :error, inspect(id)
      end
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
