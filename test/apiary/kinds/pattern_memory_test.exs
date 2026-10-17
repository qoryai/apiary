defmodule Apiary.Kinds.PatternMemoryTest do
  use ExUnit.Case, async: true

  alias Apiary.Kinds.PatternMemory

  # The most a compile holds: what a pattern whose code is past PCRE's limit is counted.
  defp cap, do: PatternMemory.estimate("(?:a){65535}")

  describe "estimate/2" do
    # Measured on OTP 29 (PCRE2 10.47): the bytes each source holds once compiled as JSV
    # compiles a "pattern" (`$` written `\z`, `\p{Letter}` written `\p{L}`, and
    # `Regex.compile(_, "u")`), with two bytes, "z1", added at its end; the node's memory
    # outside process heaps, read with the compiled patterns held, per pattern, the
    # greater of the reading with the sources' binaries and the one without.
    @measured [
      {"abc", 484},
      {String.duplicate("a", 1000), 3353},
      {"^" <> String.duplicate("a", 16_000), 48_371},
      {String.duplicate("ä", 500), 2859},
      {String.duplicate("𝄞", 250), 2595},
      {"\\Q" <> String.duplicate("𝄞", 1000) <> "\\E", 9482},
      {"[a-z]", 371},
      {"[" <> String.duplicate("a-z", 333) <> "]", 1386},
      {"[^\\x{100}-\\x{10FFFF}]", 612},
      {"[\\p{L}\\p{N}_-]", 424},
      {"[" <> String.duplicate("\\w\\d\\s\\p{Lu}", 200) <> "]", 5220},
      {"\\p{Letter}+", 376},
      {"\\w+\\d+\\s+", 368},
      {String.duplicate("\\p{L}", 1000), 8408},
      {String.duplicate("\\x{10FFFF}", 1000), 16_304},
      {String.duplicate("\\p{L}{3}", 1000), 14_364},
      {"(?i)" <> String.duplicate("k", 1000), 4356},
      {"(?i)" <> String.duplicate("𐐀", 1000), 9362},
      {"(?i)" <> String.duplicate("[ǅ-ǈ𐐀]", 500), 18_593},
      {"a{65535}", 576},
      {"[a-z]{1,40}", 382},
      {String.duplicate("[a-z]{2,9}", 1000), 49_311},
      {"(?:a){10}b", 665},
      {"(?:a){1000}b", 8601},
      {"(?:a){7900}b", 63_796},
      {"(?:ab){5000}", 50_584},
      {"(a){5000}", 50_590},
      {"(?:a|b){4000}", 52_600},
      {"(?:[a-z]){1000}", 39_584},
      {"(?:(?:a){10}){100}", 9185},
      {"(?:(?:a){10}){700}", 60_581},
      {"(?:a){0,4000}", 60_586},
      {"(?:a){4000,}", 32_592},
      {"(?:a){ 7000 }b", 56_594},
      {"(?:a)(?#c){7000}b", 56_591},
      {"(?:a)\\E{7000}b", 56_579},
      {"(a)(?1){5000}", 15_600},
      {"(a)" <> String.duplicate("\\1", 1000), 5395},
      {Enum.map_join(1..1000, "|", &"a#{&1}"), 19_360},
      {"(?<=" <> Enum.map_join(1..500, "|", &String.duplicate("b", rem(&1, 7) + 1)) <> ")x",
       11_455},
      {String.duplicate("(?=a)(?!b)(?<=c)(?<!d)", 125), 9202},
      {"(?=(?:a){5000})", 40_600},
      {Enum.map_join(1..2000, &"(?<n#{&1}>)"), 53_328},
      {"(?J)(?<" <> String.duplicate("a", 128) <> ">)" <> String.duplicate("(?<b>)", 1500),
       218_841},
      {"^[a-z0-9]{1,40}$", 398},
      {"^[A-Za-z0-9.]{1,64}$", 520},
      {"^https://", 593},
      {"^(a+)+$", 488}
    ]

    test "is at least what each family of patterns was measured to hold" do
      for {source, measured} <- @measured do
        estimate = PatternMemory.estimate(source <> "z1")
        assert estimate >= measured, "#{inspect(source)}: #{estimate} < #{measured}"
      end
    end

    # Measured the same way, each source compiled as `Apiary.Kinds.RegexFormat` compiles
    # a value, `Regex.compile/1` with no options: each byte of a character is one.
    @measured_bytes [
      {String.duplicate("ä", 500), 4345},
      {String.duplicate("𝄞", 250), 4349},
      {"\\Q" <> String.duplicate("𝄞", 1000) <> "\\E", 16_348},
      {"(?i)" <> String.duplicate("𐐀", 1000), 16_360},
      {"(?i)" <> String.duplicate("[ǅ-ǈ𐐀]", 500), 27_857},
      {String.duplicate("\\x{ff}", 1000), 14_342},
      {String.duplicate("\\p{L}", 1000), 13_345},
      {String.duplicate("[a-z]{2,9}", 1000), 58_401},
      {"(?:a){7900}b", 63_797},
      {"(?J)(?<" <> String.duplicate("a", 128) <> ">)" <> String.duplicate("(?<b>)", 1500),
       227_258}
    ]

    test "with no options, is at least what each family was measured to hold" do
      for {source, measured} <- @measured_bytes do
        estimate = PatternMemory.estimate(source <> "z1", [])
        assert estimate >= measured, "#{inspect(source)}: #{estimate} < #{measured}"
      end
    end

    test "counts a pattern's code at most at the cap, and its names beyond it" do
      assert PatternMemory.estimate("(?:a){7900}b") == cap()
      assert PatternMemory.estimate("(?:(?:(?:a){1000}){1000}){1000}") == cap()

      names = "(?J)(?<" <> String.duplicate("a", 128) <> ">)" <> String.duplicate("(?<b>)", 1500)
      assert PatternMemory.estimate(names) > cap()
    end

    test "counts at the cap what it does not read" do
      for source <- ["(?x)a", "(?ix-s)a", "(?x:a)", "(?C1)a", "(?C)a", "(*ACCEPT)", "(?*a)"] do
        assert PatternMemory.estimate(source) == cap(), inspect(source)
      end

      assert PatternMemory.estimate("a", [:caseless]) == cap()
      assert PatternMemory.estimate("a", [:unicode, :ucp]) < cap()
    end

    test "a quantifier after a comment, a lone \\E or options applies to the group before" do
      for source <- [
            "(?:a)(?#c){7000}b",
            "(?:a)\\E{7000}b",
            "(?:a)\\Q\\E{7000}b",
            "(?:a)(?i){7000}b"
          ] do
        assert PatternMemory.estimate(source) == cap(), inspect(source)
      end
    end

    test "a class ends where PCRE ends it" do
      # PCRE reads [:alpha:] inside the class and ends it at the next "]", so the group
      # that follows is repeated.
      assert PatternMemory.estimate("[[:alpha:][](?:a){7000}]") == cap()
      assert PatternMemory.estimate("[\\Q]\\E[](?:a){7000}]") == cap()
      assert PatternMemory.estimate("[]a](?:a){7000}") == cap()
    end
  end

  describe "schema/1" do
    defp one(source), do: PatternMemory.estimate(source)

    # A schema whose properties r0, r1, ... refer to `refs` in turn, its definitions `defs`.
    defp refers(refs, defs, extra \\ %{}) do
      Map.merge(
        %{
          "type" => "object",
          "properties" =>
            Map.new(Enum.with_index(refs), fn {ref, i} -> {"r#{i}", %{"$ref" => ref}} end),
          "$defs" => defs
        },
        extra
      )
    end

    defp deep(n, leaf), do: Enum.reduce(1..n, leaf, fn _, inner -> %{"allOf" => [inner]} end)

    test "counts patterns, keys of patternProperties and patterns of propertyNames" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "a" => %{"pattern" => "^a$"},
          "b" => %{"patternProperties" => %{"^k1$" => true, "^k2$" => %{}}},
          "c" => %{"propertyNames" => %{"pattern" => "^n$"}}
        }
      }

      assert PatternMemory.schema(schema) == one("^a$") + one("^k1$") + one("^k2$") + one("^n$")
      assert PatternMemory.schema(%{"type" => "object"}) == 0
    end

    # The times JSV 0.23 compiled the pattern while it built each schema, traced: at
    # least that many estimates of it are counted.
    test "counts a pattern again for each distinct reference that builds it" do
      p = "^p$"

      cases = [
        # One string twice: built once.
        {refers(["#/$defs/d", "#/$defs/d"], %{"d" => %{"pattern" => p}}), 1},
        # Three pointers, each into the one before: built three times.
        {refers(["#/$defs/d", "#/$defs/d/allOf/0", "#/$defs/d/allOf/0/allOf/0"], %{
           "d" => deep(2, %{"pattern" => p})
         }), 3},
        # Two spellings of one index: built twice.
        {refers(["#/$defs/d/allOf/0", "#/$defs/d/allOf/00"], %{"d" => deep(1, %{"pattern" => p})}),
         2},
        # A pointer and its percent-encoding: built once.
        {refers(["#/$defs/d", "#/%24defs/d"], %{"d" => %{"pattern" => p}}), 1},
        # An anchor and a pointer to one place: built twice.
        {refers(["#a", "#/$defs/d"], %{"d" => %{"$anchor" => "a", "pattern" => p}}), 2},
        # A pointer into a const: built once.
        {refers(["#/$defs/c/const"], %{"c" => %{"const" => %{"pattern" => p}}}), 1},
        # A pointer to a property built from the root: built twice.
        {%{
           "type" => "object",
           "properties" => %{"a" => %{"pattern" => p}, "b" => %{"$ref" => "#/properties/a"}}
         }, 2},
        # A nested $id, referred to by it and by a pointer: built once.
        {refers(["urn:n", "#/$defs/n"], %{"n" => %{"$id" => "urn:n", "pattern" => p}}), 1},
        # 64 pointers, each into the one before: built 64 times.
        {refers(
           for(i <- 0..63, do: "#/$defs/d" <> String.duplicate("/allOf/0", i)),
           %{"d" => deep(63, %{"pattern" => p})}
         ), 64}
      ]

      for {schema, built} <- cases do
        assert PatternMemory.schema(schema) >= built * one(p), inspect(schema, limit: 4)
      end
    end

    test "counts an unresolved reference as the whole schema and the meta-schemas" do
      whole = %{"type" => "object", "properties" => %{"a" => %{"pattern" => "^w$"}}}

      # A build of the draft 2020-12 meta-schema compiles its 2 patterns, traced.
      meta = one("^[A-Za-z_][-A-Za-z0-9._]*$") + one("^[^#]*#?$")

      for ref <- ["https://json-schema.org/draft/2020-12/schema", "other.json#/a", "#/nowhere"] do
        schema = put_in(whole, ["properties", "b"], %{"$ref" => ref})
        assert PatternMemory.schema(schema) >= 2 * one("^w$") + meta, ref
      end
    end

    test "counts a $dynamicRef as the whole schema and every dynamic anchor of its name" do
      schema =
        refers([], %{
          "t" => %{
            "$dynamicAnchor" => "t",
            "pattern" => "^t$",
            "allOf" => [%{"$dynamicAnchor" => "t", "pattern" => "^u$"}]
          }
        })
        |> put_in(["properties", "a"], %{"$dynamicRef" => "#t"})

      assert PatternMemory.schema(schema) >= 2 * one("^t$") + 3 * one("^u$")
    end
  end
end
