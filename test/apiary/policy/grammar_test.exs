defmodule Apiary.Policy.GrammarTest do
  use ExUnit.Case, async: true

  alias Apiary.Policy.Grammar

  test "a final newline is not part of a host or a path, whatever `$` would say" do
    assert Grammar.host?("api.example")
    refute Grammar.host?("api.example\n")
    refute Grammar.host?("*.example\n")
    assert Grammar.path?("/a/*")
    refute Grammar.path?("/a\n")
  end

  test "a path holds no space or control character of any script" do
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
  end

  test "covers?/2 and matches?/2 are Forager's" do
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
