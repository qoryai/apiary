defmodule Apiary.WorkItems.ProposalTest do
  # The result as the pages draw it, and the checks of what a member gives Explore.
  use ExUnit.Case, async: true

  import Apiary.WorkItemsFixtures, only: [understood_result: 0, understood_result: 1]

  alias Apiary.WorkItems.Proposal

  defp proposal(attrs \\ %{}), do: Proposal.from_result(understood_result(attrs))

  defp form(attrs \\ %{}) do
    Map.merge(
      %{
        "complexity" => %{"level" => "standard", "reason" => "Two screens read the price."},
        "understanding" => "The basket keeps the price from before the sale.",
        "scope_in" => "Read the sale price in the basket",
        "scope_out" => "The invoice",
        "approach" => "Read the price from the catalogue each time."
      },
      attrs
    )
  end

  # `fun` run in a process whose heap is bounded at 2,000,000 words, about 16 MB, and that
  # is killed past it: its answer, or why it went down.
  defp bounded(fun) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: 2_000_000, kill: true, error_logger: false})
        send(parent, {self(), fun.()})
      end)

    receive do
      {^pid, answer} ->
        Process.demonitor(ref, [:flush])
        answer

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:down, reason}
    end
  end

  @ten_mb 10_000_000

  test "from_result/1 draws a proposal, and questions/1 a run's questions" do
    assert proposal() == %{
             complexity: %{level: :standard, reason: "Two screens read the price."},
             understanding: "The basket keeps the price from before the sale.",
             scope_in: ["Read the sale price in the basket"],
             scope_out: ["The invoice"],
             approach: "Read the price from the catalogue each time.",
             alternatives: [
               %{text: "Clear the basket at a sale.", reason: "It loses what people chose."}
             ],
             knowledge: [
               %{
                 text: "The catalogue holds the sale price.",
                 sources: ["https://docs.example.com/catalogue"]
               }
             ]
           }

    assert Proposal.from_result(Map.delete(understood_result(), "knowledge")).knowledge == []

    assert Proposal.questions(%{"verdict" => "not_understood", "questions" => ["A?", "B?"]}) ==
             ["A?", "B?"]
  end

  describe "check_answers/2" do
    test "every question answered, trimmed, with its position and question" do
      assert Proposal.check_answers(["A?", "B?"], %{"1" => " Yes\r\n", "2" => "No"}) ==
               {:ok, [{1, "A?", "Yes"}, {2, "B?", "No"}]}
    end

    test "a blank answer, one too long, or one with a character a run's input refuses" do
      long = String.duplicate("é", 2001)

      assert Proposal.check_answers(["A?", "B?", "C?", "D?"], %{
               "1" => "  ",
               "2" => long,
               "3" => "zero\u200Bwidth",
               "4" => "bell\a"
             }) ==
               {:error,
                %{"1" => :blank, "2" => {:too_long, 2000}, "3" => :characters, "4" => :characters}}

      # Code points, not graphemes: 2,000 accented letters written with combining marks
      # are 4,000 code points.
      combining = String.duplicate("e\u0301", 1001)

      assert {:error, %{"1" => {:too_long, 2000}}} =
               Proposal.check_answers(["A?"], %{"1" => combining})

      assert {:ok, _} = Proposal.check_answers(["A?"], %{"1" => String.duplicate("é", 2000)})
      assert {:ok, [{1, "A?", "a\tb\nc"}]} = Proposal.check_answers(["A?"], %{"1" => "a\tb\nc"})
    end

    test "an answer of more bytes than its code points can hold is too long, first" do
      assert Proposal.check_answers(["A?"], %{"1" => String.duplicate("a", 8001)}) ==
               {:error, %{"1" => {:too_long, 2000}}}

      # 2,000 code points of four bytes each are within the bound.
      assert {:ok, _} =
               Proposal.check_answers(["A?"], %{"1" => String.duplicate("\u{1F600}", 2000)})

      # Past the bound, the length is the reason, before its characters or white space.
      assert Proposal.check_answers(["A?", "B?"], %{
               "1" => String.duplicate("a", 8000) <> "\u200B",
               "2" => String.duplicate(" ", 8001)
             }) ==
               {:error, %{"1" => {:too_long, 2000}, "2" => {:too_long, 2000}}}
    end

    test "a 10 MB answer is refused without counting it" do
      answer = String.duplicate("a", @ten_mb)

      assert bounded(fn -> Proposal.check_answers(["A?"], %{"1" => answer}) end) ==
               {:error, %{"1" => {:too_long, 2000}}}
    end

    test "invalid UTF-8 is a character the input refuses" do
      assert Proposal.check_answers(["A?"], %{"1" => <<0xFF, 0xFE>>}) ==
               {:error, %{"1" => :characters}}
    end

    test "a form missing a question, naming another, or giving no text, is refused" do
      assert Proposal.check_answers(["A?", "B?"], %{"1" => "Yes"}) == {:error, :invalid}
      assert Proposal.check_answers(["A?"], %{"1" => "Yes", "2" => "No"}) == {:error, :invalid}
      assert Proposal.check_answers(["A?"], %{"q1" => "Yes"}) == {:error, :invalid}
      assert Proposal.check_answers(["A?"], %{"1" => ["Yes"]}) == {:error, :invalid}
      assert Proposal.check_answers(["A?"], "Yes") == {:error, :invalid}
    end
  end

  describe "changes/2" do
    test "the form as the edit page shows it changes nothing" do
      assert Proposal.changes(proposal(), form()) == {:ok, %{}}
    end

    test "a browser's line breaks and white space around a text change nothing" do
      p = proposal(%{"understanding" => "One line.\nTwo lines."})

      assert Proposal.changes(p, form(%{"understanding" => "\r\nOne line.\r\nTwo lines.  "})) ==
               {:ok, %{}}
    end

    test "a scope differs by its entries, each one line and trimmed" do
      p = proposal(%{"scope" => %{"in" => ["First\nentry", " Second "], "out" => []}})

      assert Proposal.changes(
               p,
               form(%{"scope_in" => "First entry\r\n\r\nSecond\n", "scope_out" => ""})
             ) ==
               {:ok, %{}}

      assert Proposal.changes(p, form(%{"scope_in" => "First entry", "scope_out" => "Later"})) ==
               {:ok, %{scope_in: ["First entry"], scope_out: ["Later"]}}
    end

    test "only the fields that differ, each in the proposal's form" do
      assert Proposal.changes(
               proposal(),
               form(%{
                 "complexity" => %{
                   "level" => "complex",
                   "reason" => "Two screens read the price."
                 },
                 "approach" => "Keep the price on the line.",
                 "understanding" => "  The basket keeps the price from before the sale."
               })
             ) ==
               {:ok,
                %{
                  complexity: %{level: :complex, reason: "Two screens read the price."},
                  approach: "Keep the price on the line."
                }}
    end

    test "the bounds of each field" do
      long = String.duplicate("a", 2001)

      assert Proposal.changes(
               proposal(),
               form(%{
                 "complexity" => %{"level" => "simple", "reason" => ""},
                 "understanding" => String.duplicate("a", 20_001),
                 "scope_in" => "\n \n",
                 "scope_out" => Enum.map_join(1..51, "\n", &"line #{&1}"),
                 "approach" => long
               })
             ) ==
               {:error,
                %{
                  reason: :blank,
                  understanding: {:too_long, 20_000},
                  scope_in: :blank,
                  scope_out: {:too_many_lines, 50},
                  approach: {:too_long, 2000}
                }}

      assert Proposal.changes(proposal(), form(%{"scope_in" => "ok\n" <> long})) ==
               {:error, %{scope_in: {:line_too_long, 2000}}}

      assert Proposal.changes(proposal(), form(%{"approach" => "a\u202Eb"})) ==
               {:error, %{approach: :characters}}

      assert {:ok, %{understanding: _}} =
               Proposal.changes(
                 proposal(),
                 form(%{"understanding" => String.duplicate("a", 20_000)})
               )

      assert {:ok, %{scope_out: []}} = Proposal.changes(proposal(), form(%{"scope_out" => " "}))
    end

    test "a text of more bytes than its code points can hold is too long, first" do
      assert Proposal.changes(
               proposal(),
               form(%{
                 "complexity" => %{"level" => "simple", "reason" => String.duplicate("a", 8001)},
                 "understanding" => String.duplicate("a", 80_001),
                 "approach" => String.duplicate(" ", 8001)
               })
             ) ==
               {:error,
                %{
                  reason: {:too_long, 2000},
                  understanding: {:too_long, 20_000},
                  approach: {:too_long, 2000}
                }}

      assert {:ok, %{understanding: _}} =
               Proposal.changes(
                 proposal(),
                 form(%{"understanding" => String.duplicate("\u{1F600}", 20_000)})
               )
    end

    test "a scope of more bytes than its lines can hold: too many lines, or a line too long" do
      many = Enum.map_join(1..60, "\n", fn _ -> String.duplicate("a", 7000) end)
      long = Enum.map_join(1..10, "\n", fn _ -> String.duplicate("a", 41_000) end)
      # Blank lines are no entries: one long line after a hundred of them is too long.
      padded = String.duplicate(" \r\n", 100) <> String.duplicate("a", 400_200)

      assert Proposal.changes(proposal(), form(%{"scope_in" => many, "scope_out" => many})) ==
               {:error, %{scope_in: {:too_many_lines, 50}, scope_out: {:too_many_lines, 50}}}

      # Lines are counted before the text is checked as UTF-8.
      invalid = Enum.map_join(1..60, "\n", fn _ -> String.duplicate(<<0xFF>>, 7000) end)

      assert Proposal.changes(proposal(), form(%{"scope_in" => invalid})) ==
               {:error, %{scope_in: {:too_many_lines, 50}}}

      assert Proposal.changes(proposal(), form(%{"scope_in" => long, "scope_out" => padded})) ==
               {:error, %{scope_in: {:line_too_long, 2000}, scope_out: {:line_too_long, 2000}}}

      # 50 lines of 2,000 code points of four bytes each are within the bound.
      most = Enum.map_join(1..50, "\n", fn _ -> String.duplicate("\u{1F600}", 2000) end)

      assert {:ok, %{scope_in: in_lines, scope_out: out_lines}} =
               Proposal.changes(proposal(), form(%{"scope_in" => most, "scope_out" => most}))

      assert length(in_lines) == 50 and length(out_lines) == 50
    end

    test "a 10 MB understanding or scope is refused without counting it" do
      understanding = String.duplicate("a", @ten_mb)
      line_feeds = String.duplicate("\n", @ten_mb)

      assert bounded(fn ->
               Proposal.changes(proposal(), form(%{"understanding" => understanding}))
             end) == {:error, %{understanding: {:too_long, 20_000}}}

      assert bounded(fn -> Proposal.changes(proposal(), form(%{"scope_in" => line_feeds})) end) ==
               {:error, %{scope_in: {:line_too_long, 2000}}}
    end

    test "a form missing a field, giving no text, or naming no level of the three, is refused" do
      assert Proposal.changes(proposal(), Map.delete(form(), "approach")) == {:error, :invalid}

      assert Proposal.changes(
               proposal(),
               form(%{"complexity" => %{"level" => "huge", "reason" => "x"}})
             ) ==
               {:error, :invalid}

      assert Proposal.changes(proposal(), form(%{"understanding" => ["x"]})) == {:error, :invalid}
      assert Proposal.changes(proposal(), nil) == {:error, :invalid}
    end

    test "encode/1 and decode/1 keep the changes as a JSON object and read them back" do
      changes = %{
        complexity: %{level: :simple, reason: "Small."},
        scope_out: [],
        approach: "Do it."
      }

      encoded = Proposal.encode(changes)

      assert encoded == %{
               "complexity" => %{"level" => "simple", "reason" => "Small."},
               "scope_out" => [],
               "approach" => "Do it."
             }

      assert encoded |> Jason.encode!() |> Jason.decode!() |> Proposal.decode() == changes
      assert Proposal.decode(%{"other" => 1}) == %{}
    end
  end
end
