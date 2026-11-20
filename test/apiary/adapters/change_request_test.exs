defmodule Apiary.Adapters.ChangeRequestTest do
  # A `change_request` entry against the integrations contract's `changes.schema.json`,
  # vendored under `priv/contract/integration/`: its title and text, and its data, as the
  # contract's refused fixtures (`invalid/changes-change-request-*.json`) have them.
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

  defp refused(changes) do
    assert {:error, %{valid: false, count: count, errors: [_ | _]}} =
             ChangeRequest.validate(entry(changes))

    assert count >= 1
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

      refused(%{"title" => ""})
      refused(%{"title" => String.duplicate("é", 257)})
      refused(%{"title" => "Show delivery dates\nat checkout"})
    end

    test "has no hidden character and at least one character that is not a space" do
      refused(%{"title" => "Show delivery\u{200B}dates"})
      refused(%{"title" => "Show delivery\u{202E}dates"})
      refused(%{"title" => "Show delivery\u{E0041}dates"})
      refused(%{"title" => "   "})
      refused(%{"title" => "\u{A0}\u{3000}"})
    end
  end

  describe "the text" do
    test "has no U+0000 and at most 20,000 characters" do
      assert ChangeRequest.validate(entry(%{"text" => String.duplicate("é", 20_000)})) == :ok
      assert ChangeRequest.validate(entry(%{"text" => ""})) == :ok

      refused(%{"text" => "A text with a NUL" <> <<0>> <> " in it"})
      refused(%{"text" => String.duplicate("é", 20_001)})
    end

    test "may have the line that marks a block: the marker rule is not the envelope's" do
      text = "<!-- qory:start -->\nThe checkout page shows the dates.\n<!-- qory:end -->"
      assert ChangeRequest.validate(entry(%{"text" => text})) == :ok
    end
  end

  describe "the data" do
    test "is a JSON object" do
      assert ChangeRequest.validate(entry(%{"data" => %{}})) == :ok

      for data <- ["branch", ["a"], nil, 1] do
        refused(%{"data" => data})
      end
    end

    test "is required, with the title, the text, the kind and the target" do
      for key <- ~w(data title text change_kind target change_request_id) do
        assert {:error, %{valid: false}} = ChangeRequest.validate(Map.delete(entry(), key)), key
      end
    end
  end

  test "an entry that is no map is refused" do
    for value <- [nil, "reply", [], 1] do
      assert {:error, %{valid: false}} = ChangeRequest.validate(value), inspect(value)
    end
  end
end
