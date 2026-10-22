defmodule Apiary.Contract.StackTest do
  # A run's stack as the run contract takes it (`Apiary.Contract.Stack`): the patterns of
  # the vendored `documents.schema.json`, character for character, and each case the
  # rules accept or refuse.
  use ExUnit.Case, async: true

  alias Apiary.Contract.Stack

  @documents Path.expand("../../fixtures/contract/run/v1/documents.schema.json", __DIR__)

  defp definitions, do: @documents |> File.read!() |> Jason.decode!() |> Map.fetch!("$defs")

  test "the name pattern is the vendored stack_name's" do
    assert Stack.name_pattern() == definitions()["stack_name"]["pattern"]
  end

  test "the reference pattern, its exclusions and its length are the vendored stack_reference's" do
    rule = definitions()["stack_reference"]

    assert Stack.reference_pattern() == rule["pattern"]
    assert Stack.reference_exclusions() == Enum.map(rule["allOf"], & &1["not"]["pattern"])
    assert Stack.max_length() == rule["maxLength"]
  end

  test "the vendored stack is a name or a reference" do
    assert definitions()["stack"]["oneOf"] == [
             %{"$ref" => "#/$defs/stack_name"},
             %{"$ref" => "#/$defs/stack_reference"}
           ]
  end

  describe "a name" do
    test "of a lower-case letter, letters, digits and hyphens is taken" do
      assert Stack.name?("software-standard")
      assert Stack.valid?("software-standard")
      refute Stack.reference?("software-standard")
    end

    test "of 65 characters is refused, 64 taken" do
      assert Stack.name?("a" <> String.duplicate("b", 63))
      refute Stack.name?("a" <> String.duplicate("b", 64))
    end

    test "with a capital, a leading digit or a final newline is refused" do
      refute Stack.valid?("Software")
      refute Stack.valid?("1software")
      refute Stack.valid?("software\n")
    end
  end

  describe "a reference" do
    test "with a host, a path, a ref and a folder is taken" do
      assert Stack.reference?("https://code.example.com/team/stacks#main:core")
      assert Stack.valid?("https://code.example.com/team/stacks#main:core")
      refute Stack.name?("https://code.example.com/team/stacks#main:core")
    end

    test "with a port, an IPv6 host, a tag and the root folder is taken" do
      assert Stack.reference?("https://[2001:db8::1]:8443/stacks#v1.2.0:.")
    end

    test "with a commit and a nested folder is taken" do
      commit = String.duplicate("0123456789", 4)
      assert Stack.reference?("https://code.example.com/stacks##{commit}:stacks/general/explore")
    end

    test "with user information, a query or plain http is refused" do
      refute Stack.valid?("https://user@code.example.com/stacks#main:core")
      refute Stack.valid?("https://code.example.com/stacks?x=1#main:core")
      refute Stack.valid?("http://code.example.com/stacks#main:core")
    end

    test "without a ref or a folder is refused" do
      refute Stack.valid?("https://code.example.com/stacks")
      refute Stack.valid?("https://code.example.com/stacks#main")
      refute Stack.valid?("https://code.example.com/stacks#:core")
    end

    test "with two dots in the ref or a folder name of two dots is refused" do
      refute Stack.valid?("https://code.example.com/stacks#main..next:core")
      refute Stack.valid?("https://code.example.com/stacks#main:core/../other")
    end

    test "with a ref of 256 characters is refused, 255 taken" do
      assert Stack.reference?("https://code.example.com/s##{String.duplicate("r", 255)}:core")
      refute Stack.reference?("https://code.example.com/s##{String.duplicate("r", 256)}:core")
    end

    test "with a folder of 256 characters is refused, 255 taken" do
      assert Stack.reference?("https://code.example.com/s#main:#{String.duplicate("f", 255)}")
      refute Stack.reference?("https://code.example.com/s#main:#{String.duplicate("f", 256)}")
    end

    test "of 2,561 characters is refused, 2,560 taken" do
      head = "https://code.example.com/"
      tail = "#main:core"
      path = String.duplicate("p", 2560 - String.length(head) - String.length(tail))
      assert Stack.reference?(head <> path <> tail)
      refute Stack.reference?(head <> path <> "p" <> tail)
    end

    test "with a final newline is refused" do
      refute Stack.valid?("https://code.example.com/stacks#main:core\n")
    end
  end
end
