defmodule Apiary.Kinds.PatternTest do
  use ExUnit.Case, async: true

  alias Apiary.Kinds.{Pattern, Schema}

  test "a compiled pattern's $ is the end of the string, never before a final newline" do
    regex = Pattern.compile!("^[a-z]+$")
    assert Regex.match?(regex, "github")
    refute Regex.match?(regex, "github\n")
    # What PCRE does without the option.
    assert Regex.match?(~r/^[a-z]+$/, "github\n")
  end

  test "an argument matches whole, or not at all" do
    assert Pattern.whole_match?("[A-Z]+", "SHOP")
    refute Pattern.whole_match?("[A-Z]+", "SHOP\n")
    refute Pattern.whole_match?("[A-Z]+", "SHOP-1")
    refute Pattern.whole_match?("A|B", "AB")
    refute Pattern.whole_match?("(", "x")
  end

  test "end_only rewrites anchors, and leaves escapes, classes and data alone" do
    assert Pattern.end_only_source("^a$") == "^a\\z"
    assert Pattern.end_only_source("^(a|b$)$") == "^(a|b\\z)\\z"
    assert Pattern.end_only_source("^[$]\\$$") == "^[$]\\$\\z"
    assert Pattern.end_only_source("^[]$]x$") == "^[]$]x\\z"
    assert Pattern.end_only_source("^[^]$]$") == "^[^]$]\\z"

    schema = %{
      "pattern" => "^a$",
      "patternProperties" => %{"^x$" => %{"pattern" => "b$"}},
      "const" => %{"pattern" => "c$"},
      "properties" => %{"pattern" => %{"type" => "string", "pattern" => "d$"}}
    }

    assert Pattern.end_only(schema) == %{
             "pattern" => "^a\\z",
             "patternProperties" => %{"^x\\z" => %{"pattern" => "b\\z"}},
             "const" => %{"pattern" => "c$"},
             "properties" => %{"pattern" => %{"type" => "string", "pattern" => "d\\z"}}
           }
  end

  test "a schema validated with JSV reads $ as the contracts do" do
    {:ok, root} = Schema.build(%{"type" => "string", "pattern" => "^[a-z]+$"})
    assert Schema.validate("github", root) == :ok
    assert {:error, _} = Schema.validate("github\n", root)
  end
end
