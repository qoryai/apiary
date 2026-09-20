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
