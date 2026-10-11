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

  describe "an entry that ends in a number is an address" do
    test "taken only as four decimal parts of 0 to 255, with no leading zero" do
      for host <- ~w(0.0.0.0 255.255.255.255 10.0.0.12 127.0.0.1 1.2.3.4 100.64.0.1 199.249.0.9) do
        assert Grammar.host?(host), host
      end
    end

    test "every other entry that ends in a number is refused" do
      for host <- ~w(
            127.1 2130706433 0x7f.0.0.1 0x7f000001 127.0.0.0x1 0x 1.2.3.0x 010.0.0.1 10.0.0.01
            00.0.0.0 10.0.0.256 256.0.0.1 1.2.3.4.5 1.2.3 example.123 api.example.0x1f
            *.0.0.1 *.10.0.0.1 *.1 *.example.123
          ) do
        refute Grammar.host?(host), host
      end
    end

    test "a host that does not end in a number is a name, as before" do
      for host <- ~w(1.2.3.4.example api.example *.example 0x7f.example 123.example
                     a1 *.10.0.0.1x example.0a 0xg) do
        assert Grammar.host?(host), host
      end

      # No `:` in the grammar: an IPv6 address is never an entry.
      for host <- ["::1", "[::1]", "::ffff:10.0.0.12", "fe80::1"], do: refute(Grammar.host?(host))
    end

    test "ends_in_number?/1 is WHATWG's test, a final dot left out" do
      for host <- ~w(1 0x 0x1F 0X1f a.1 a.0x a.1. 1.2.3.4) do
        assert Grammar.ends_in_number?(host), host
      end

      for host <- ["", ".", "a", "a.b", "1.a", "a.0xg", "a.1x", "a..", "a.-1"] do
        refute Grammar.ends_in_number?(host), inspect(host)
      end
    end
  end

  describe "matches?/2 with an address" do
    test "a canonical address matches the identical entry and nothing else" do
      assert Grammar.matches?(["10.0.0.12"], "10.0.0.12")
      assert Grammar.matches?(["10.0.0.12"], "10.0.0.12.")
      refute Grammar.matches?(["10.0.0.12"], "10.0.0.13")
      refute Grammar.matches?(["*.0.0.12"], "10.0.0.12")
    end

    test "an address in any other form matches no entry, whatever the list holds" do
      # `127.1` against an entry `127.1`, as a rule inserted before the grammar refused it.
      refute Grammar.matches?(["127.1", "127.0.0.1"], "127.1")
      refute Grammar.matches?(["2130706433", "127.0.0.1"], "2130706433")
      refute Grammar.matches?(["0x7f.0.0.1", "127.0.0.1"], "0x7f.0.0.1")
      refute Grammar.matches?(["0x7f.0.0.1", "127.0.0.1"], "0X7F.0.0.1")
      refute Grammar.matches?(["010.0.0.1", "10.0.0.1"], "010.0.0.1")
      refute Grammar.matches?(["*.0.0.1", "127.0.0.1"], "*.0.0.1")
      refute Grammar.matches?(["example.123", "*.123"], "example.123")
    end

    test "an IPv6 address matches no entry, an IPv4-mapped one included" do
      for host <- ["::1", "[::1]", "::ffff:10.0.0.12", "[::ffff:10.0.0.12]", "::ffff:a00:c"] do
        refute Grammar.matches?(["10.0.0.12", host, "*.12"], host), host
      end
    end

    test "a name keeps matching by suffix" do
      assert Grammar.matches?(["*.example"], "1.2.3.4.example")
      assert Grammar.matches?(["123.example"], "123.example")
    end
  end
end
