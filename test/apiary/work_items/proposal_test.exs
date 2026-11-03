defmodule Apiary.WorkItems.ProposalTest do
  # The result as the pages draw it, and the checks of what a member gives Explore: the
  # answers to a run's questions, each an option's title or the member's text, and a
  # comment on a proposal.
  use ExUnit.Case, async: true

  import Apiary.WorkItemsFixtures, only: [understood_result: 0, understood_result: 1]

  alias Apiary.WorkItems.Proposal

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

  defp q(text, titles \\ []),
    do: %{question: text, options: for(t <- titles, do: %{title: t, explanation: "Why #{t}."})}

  describe "the result as the pages draw it" do
    test "from_result/1 is the proposal's Markdown, nil for a result stored before" do
      assert Proposal.from_result(understood_result(%{"message" => "## What this is\n\nA."})) ==
               %{message: "## What this is\n\nA."}

      stored_before =
        understood_result()
        |> Map.delete("message")
        |> Map.put("understanding", "The basket keeps the price.")

      assert Proposal.from_result(stored_before) == %{message: nil}
    end

    test "questions/1 is each question with its options, and a text offers none" do
      result = %{
        "verdict" => "not_understood",
        "questions" => [
          %{
            "question" => "Which refund applies to **this order**?",
            "options" => [
              %{"title" => "Full refund", "explanation" => "The policy covers it."},
              %{"title" => "Store credit", "explanation" => "No return is needed."}
            ]
          },
          %{"question" => "Which order number?", "options" => []},
          "Stored before options?"
        ]
      }

      assert Proposal.questions(result) == [
               %{
                 question: "Which refund applies to **this order**?",
                 options: [
                   %{title: "Full refund", explanation: "The policy covers it."},
                   %{title: "Store credit", explanation: "No return is needed."}
                 ]
               },
               %{question: "Which order number?", options: []},
               %{question: "Stored before options?", options: []}
             ]
    end
  end

  describe "check_answers/2" do
    test "an option's title is not the member's text; the member's text is, trimmed" do
      questions = [q("A?", ["Yes", "No"]), q("B?", ["Phones"]), q("C?")]

      assert Proposal.check_answers(questions, %{
               "1" => %{"option" => "No"},
               "2" => %{"custom" => " Test on two phones\r\n", "option" => ""},
               "3" => " Free text\r\n"
             }) ==
               {:ok,
                [
                  {1, "A?", "No", false},
                  {2, "B?", "Test on two phones", true},
                  {3, "C?", "Free text", true}
                ]}
    end

    test "an option is read as the form gives it back, and kept as the run wrote it" do
      assert Proposal.check_answers([q("A?", ["Keep it\nas is"])], %{
               "1" => %{"option" => " Keep it\r\nas is "}
             }) == {:ok, [{1, "A?", "Keep it\nas is", false}]}
    end

    test "an option title the question does not have is refused" do
      questions = [q("A?", ["Yes", "No"]), q("B?")]

      assert Proposal.check_answers(questions, %{
               "1" => %{"option" => "Maybe"},
               "2" => "Text"
             }) == {:error, :invalid}

      # A question with no options takes no option.
      assert Proposal.check_answers([q("B?")], %{"1" => %{"option" => "Yes"}}) ==
               {:error, :invalid}

      # The title of another question's option.
      assert Proposal.check_answers([q("A?", ["Yes"]), q("B?", ["Later"])], %{
               "1" => %{"option" => "Later"},
               "2" => %{"option" => "Later"}
             }) == {:error, :invalid}
    end

    test "one answer per question: an option and a text together are refused" do
      assert Proposal.check_answers([q("A?", ["Yes"])], %{
               "1" => %{"option" => "Yes", "custom" => "Also this"}
             }) == {:error, :invalid}
    end

    test "no option and no text is blank" do
      questions = [q("A?", ["Yes"]), q("B?", ["No"]), q("C?")]

      assert Proposal.check_answers(questions, %{
               "1" => %{},
               "2" => %{"option" => " ", "custom" => "\r\n"},
               "3" => "  "
             }) == {:error, %{"1" => :blank, "2" => :blank, "3" => :blank}}
    end

    test "a text too long, or with a character a run's input refuses" do
      long = String.duplicate("é", 2001)
      questions = [q("A?"), q("B?"), q("C?")]

      assert Proposal.check_answers(questions, %{
               "1" => %{"custom" => long},
               "2" => %{"custom" => "zero​width"},
               "3" => "bell\a"
             }) ==
               {:error, %{"1" => {:too_long, 2000}, "2" => :characters, "3" => :characters}}

      # Code points, not graphemes: 2,000 accented letters written with combining marks
      # are 4,000 code points.
      combining = String.duplicate("é", 1001)

      assert {:error, %{"1" => {:too_long, 2000}}} =
               Proposal.check_answers([q("A?")], %{"1" => combining})

      assert {:ok, _} = Proposal.check_answers([q("A?")], %{"1" => String.duplicate("é", 2000)})

      assert {:ok, [{1, "A?", "a\tb\nc", true}]} =
               Proposal.check_answers([q("A?")], %{"1" => "a\tb\nc"})
    end

    test "an answer of more bytes than its code points can hold is too long, first" do
      assert Proposal.check_answers([q("A?")], %{"1" => String.duplicate("a", 8001)}) ==
               {:error, %{"1" => {:too_long, 2000}}}

      assert {:ok, _} =
               Proposal.check_answers([q("A?")], %{"1" => String.duplicate("\u{1F600}", 2000)})

      assert Proposal.check_answers([q("A?"), q("B?")], %{
               "1" => String.duplicate("a", 8000) <> "​",
               "2" => %{"custom" => String.duplicate(" ", 8001)}
             }) ==
               {:error, %{"1" => {:too_long, 2000}, "2" => {:too_long, 2000}}}
    end

    test "a 10 MB answer or option is refused without counting it" do
      text = String.duplicate("a", @ten_mb)

      assert bounded(fn -> Proposal.check_answers([q("A?")], %{"1" => text}) end) ==
               {:error, %{"1" => {:too_long, 2000}}}

      assert bounded(fn ->
               Proposal.check_answers([q("A?", ["a"])], %{"1" => %{"option" => text}})
             end) == {:error, :invalid}
    end

    test "invalid UTF-8 is a character the input refuses" do
      assert Proposal.check_answers([q("A?")], %{"1" => <<0xFF, 0xFE>>}) ==
               {:error, %{"1" => :characters}}

      assert Proposal.check_answers([q("A?", ["a"])], %{"1" => %{"option" => <<0xFF>>}}) ==
               {:error, :invalid}
    end

    test "a form missing a question, naming another, or giving no text, is refused" do
      assert Proposal.check_answers([q("A?"), q("B?")], %{"1" => "Yes"}) == {:error, :invalid}

      assert Proposal.check_answers([q("A?")], %{"1" => "Yes", "2" => "No"}) ==
               {:error, :invalid}

      assert Proposal.check_answers([q("A?")], %{"q1" => "Yes"}) == {:error, :invalid}
      assert Proposal.check_answers([q("A?")], %{"1" => ["Yes"]}) == {:error, :invalid}

      assert Proposal.check_answers([q("A?")], %{"1" => %{"other" => "Yes"}}) ==
               {:error, :invalid}

      assert Proposal.check_answers([q("A?")], %{"1" => %{"custom" => 1}}) == {:error, :invalid}
      assert Proposal.check_answers([q("A?")], "Yes") == {:error, :invalid}
    end
  end

  describe "check_comment/1" do
    test "a comment is trimmed, its line breaks line feeds" do
      assert Proposal.check_comment(" Offer a replacement first.\r\nThen a refund. ") ==
               {:ok, "Offer a replacement first.\nThen a refund."}
    end

    test "a blank comment, one over 2,000 characters, or one with a refused character" do
      assert Proposal.check_comment(" \r\n ") == {:error, :blank}
      assert Proposal.check_comment(String.duplicate("é", 2001)) == {:error, {:too_long, 2000}}
      assert {:ok, _} = Proposal.check_comment(String.duplicate("é", 2000))
      assert Proposal.check_comment("zero​width") == {:error, :characters}
      assert Proposal.check_comment(<<0xFF>>) == {:error, :characters}
      assert Proposal.check_comment(nil) == {:error, :invalid}
    end

    test "a 10 MB comment is refused without counting it" do
      text = String.duplicate("a", @ten_mb)
      assert bounded(fn -> Proposal.check_comment(text) end) == {:error, {:too_long, 2000}}
    end
  end
end
