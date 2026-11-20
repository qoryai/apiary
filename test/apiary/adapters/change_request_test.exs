defmodule Apiary.Adapters.ChangeRequestTest do
  # A `change_request` entry against the integrations contract's `changes.schema.json`,
  # vendored under `priv/contract/integration/`: its title, text and data, its id and kind,
  # and `previous`. A refusal is asserted by where in the entry the schema refuses it, so
  # an entry refused for another reason fails the test.
  use ExUnit.Case, async: true

  alias Apiary.Adapters.ChangeRequest

  defp entry(changes \\ %{}) do
    Map.merge(
      %{
        "kind" => "change_request",
        "change_request_id" => "av_7k2m9q4v1x8z3c5d",
        "change_kind" => "reply",
        "target" => %{"collection" => "SUPPORT"},
        "title" => "Delivery dates in the checkout",
        "text" => "The checkout page shows the delivery date of each order line.",
        "data" => %{"conversation" => "cv_1042", "text" => "Your order line dates are shown."}
      },
      changes
    )
  end

  # The error locations (`#/title` for the member `title`) of a refused entry.
  defp locations(entry) do
    assert {:error, %{valid: false, count: count, errors: errors}} = ChangeRequest.validate(entry)
    assert count >= 1
    Enum.map(errors, & &1.instanceLocation)
  end

  # The entry with `value` as its member `key` is refused at that member.
  defp refused(key, value) do
    assert "#/#{key}" in locations(entry(%{key => value})), "#{key}: #{inspect(value)}"
  end

  test "a valid entry passes" do
    assert ChangeRequest.validate(entry()) == :ok
    assert ChangeRequest.validate(entry(%{"ref" => "CASE-1042"})) == :ok
  end

  describe "the title" do
    test "is 1 to 256 characters on one line" do
      assert ChangeRequest.validate(entry(%{"title" => String.duplicate("é", 256)})) == :ok

      assert ChangeRequest.validate(
               entry(%{"title" => "A title with a zero-width joiner: 👩\u{200D}💻"})
             ) == :ok

      refused("title", "")
      refused("title", String.duplicate("é", 257))
      refused("title", "Show delivery dates\nat checkout")
    end

    test "has no hidden character and at least one character that is not a space" do
      refused("title", "Show delivery\u{200B}dates")
      refused("title", "Show delivery\u{202E}dates")
      refused("title", "Show delivery\u{E0041}dates")
      refused("title", "   ")
      refused("title", "\u{A0}\u{3000}")
    end
  end

  describe "the text" do
    test "has no U+0000 and at most 20,000 characters" do
      assert ChangeRequest.validate(entry(%{"text" => String.duplicate("é", 20_000)})) == :ok
      assert ChangeRequest.validate(entry(%{"text" => ""})) == :ok

      refused("text", "A text with a NUL" <> <<0>> <> " in it")
      refused("text", String.duplicate("é", 20_001))
    end

    test "may have the line that marks a block: the marker rule is not the envelope's" do
      text = "<!-- qory:start -->\nThe checkout page shows the dates.\n<!-- qory:end -->"
      assert ChangeRequest.validate(entry(%{"text" => text})) == :ok
    end
  end

  describe "the data" do
    test "is a JSON object" do
      assert ChangeRequest.validate(entry(%{"data" => %{}})) == :ok

      for data <- ["branch", ["a"], nil, 1], do: refused("data", data)
    end

    test "has no string with U+0000 in it, at any depth" do
      assert "#/data/text" in locations(entry(%{"data" => %{"text" => "a" <> <<0>> <> "b"}}))
    end
  end

  describe "the id, the kind and the previous version" do
    test "the id starts with av_ and has 16 characters of the id alphabet" do
      refused("change_request_id", "wi_7k2m9q4v1x8z3c5d")
      refused("change_request_id", "av_7k2m9q4v1x8z3c5")
    end

    test "the change kind is lower-case words joined by hyphens" do
      assert ChangeRequest.validate(entry(%{"change_kind" => "pull-request"})) == :ok
      refused("change_kind", "Reply")
      refused("change_kind", "reply_all")
    end

    test "previous has a title, an address or both, and no other member alone" do
      assert ChangeRequest.validate(entry(%{"previous" => %{"title" => "Dates"}})) == :ok
      refused("previous", %{})
      refused("previous", "Dates")
      assert "#/previous/title" in locations(entry(%{"previous" => %{"title" => "a\nb"}}))
    end
  end

  test "a member that the schema requires is missing" do
    for key <- ~w(kind change_request_id change_kind target title text data) do
      assert "#" in locations(Map.delete(entry(), key)), key
    end
  end

  test "an entry that is no map is refused at the entry" do
    for value <- [nil, "reply", [], 1] do
      assert "#" in locations(value), inspect(value)
    end
  end
end
