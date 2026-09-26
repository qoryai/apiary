defmodule Apiary.Policy.GrammarTest do
  use ExUnit.Case, async: true

  alias Apiary.Policy.Grammar

  test "a final newline is not part of a host, a path or a name, whatever `$` would say" do
    assert Grammar.host?("api.example")
    refute Grammar.host?("api.example\n")
    refute Grammar.host?("*.example\n")
    assert Grammar.path?("/a/*")
    refute Grammar.path?("/a\n")
    assert Grammar.credential_name?("product")
    refute Grammar.credential_name?("product\n")
    refute Grammar.argument?("acme/shop\n")
  end

  test "a path holds no space or control character of any script; an argument is one line" do
    for bad <- [
          "/a\u2028b",
          "/a\u2029b",
          "/a\u0085b",
          "/a\u00A0b",
          "/a\u3000b",
          "/a\u200Bb",
          "/a\tb"
        ] do
      refute Grammar.path?(bad), inspect(bad)
    end

    assert Grammar.path?("/ü/🐝/*")

    for bad <- ["a\u2028b", "a\u2029b", "a\u0085b", "a\nb", "a\u0000b"] do
      refute Grammar.argument?(bad), inspect(bad)
    end

    assert Grammar.argument?("acme/shop with a space, ü and 🐝")
  end

  test "an argument is at most 256 code points, as the schema's maxLength counts" do
    assert Grammar.argument?(String.duplicate("\u00E9", 256))
    refute Grammar.argument?(String.duplicate("\u00E9", 257))
    # 200 letters with a combining accent: 200 graphemes, 400 code points.
    refute Grammar.argument?(String.duplicate("e\u0301", 200))
    assert Grammar.argument?(String.duplicate("e\u0301", 128))
    refute Grammar.argument?("")
  end

  test "covers?/2 and matches?/2 are the runner's" do
    assert Grammar.covers?("*.example", "api.example")
    assert Grammar.covers?("*.example", "*.api.example")
    refute Grammar.covers?("*.example", "example")
    refute Grammar.covers?("*.example", "badexample")
    assert Grammar.matches?(["*.example"], "API.Example.")
    # An IP literal matches only an identical entry.
    refute Grammar.matches?(["*.0.0.1"], "127.0.0.1")
    assert Grammar.matches?(["127.0.0.1"], "127.0.0.1")
  end
end
