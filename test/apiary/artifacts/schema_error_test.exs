defmodule Apiary.Artifacts.SchemaErrorTest do
  use ExUnit.Case, async: true

  alias Apiary.Artifacts.SchemaError

  @schema %{
    "type" => "object",
    "properties" => %{
      "gaps" => %{"type" => "array", "items" => %{"type" => "string", "maxLength" => 3}},
      "n" => %{"type" => "integer"}
    }
  }

  defp first(document, schema \\ @schema) do
    {:error, error} = JSV.validate(document, JSV.build!(schema), cast: false)
    SchemaError.first(error)
  end

  test "is the deepest message at the first data path, the same on each run" do
    document = %{"gaps" => ["ok", 5, "toolong"], "n" => "x"}

    assert first(document) == %{path: "#/gaps/1", error: "value is not of type string"}
    assert Enum.uniq(for _n <- 1..20, do: first(document)) == [first(document)]
  end

  test "is a message at the root where the root fails" do
    assert first(%{}, %{"required" => ["gaps"]}) ==
             %{path: "#", error: "property 'gaps' is required"}
  end

  test "cuts the path to 256 bytes and the error to 300 characters on a character" do
    name = String.duplicate("é", 400)
    schema = %{"type" => "object", "additionalProperties" => false}
    %{path: path, error: error} = first(%{name => 1}, schema)

    assert path == "#"
    assert String.valid?(error)
    assert String.length(error) == 300

    deep = %{"properties" => %{name => %{"type" => "integer"}}}
    %{path: path} = first(%{name => "x"}, deep)
    assert path == "#/" <> String.duplicate("é", 127)
  end

  test "replaces control characters in the path and the error" do
    name = "a\u0007b\u001Bc"
    %{error: error} = first(%{name => 1}, %{"additionalProperties" => false})
    refute error =~ ~r/[\x00-\x1F]/
    assert error =~ "a�b�c"

    %{path: path} =
      first(%{name => "x"}, %{"properties" => %{name => %{"type" => "integer"}}})

    assert path == "#/a�b�c"
  end
end
