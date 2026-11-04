defmodule Apiary.Explore.QuestionsTest do
  # A work item's questions document (`Apiary.Explore.Questions`), with no database: the
  # check of a version a run pushes against the newest version, each reason it refuses
  # one for and the versions it takes, and the answers a member gives.
  use ExUnit.Case, async: true

  alias Apiary.Explore.Questions

  @at "2026-11-04T10:00:00Z"
  @by %{"name" => "Ann Example"}

  defp open(id, run),
    do: %{
      "id" => id,
      "question" => "Which #{id}?",
      "options" => [],
      "state" => "open",
      "asked" => %{"run" => run, "at" => @at}
    }

  defp answered(id, run, note \\ "The small one."),
    do:
      id
      |> open(run)
      |> Map.merge(%{
        "state" => "answered",
        "answer" => %{"option" => nil, "note" => note, "by" => @by, "at" => @at}
      })

  defp doc(questions), do: %{"questions" => questions}

  # A question run `run` reopened: its answer moved, unchanged, into its history.
  defp reopened(%{"answer" => answer} = question, run) do
    question
    |> Map.delete("answer")
    |> Map.put("state", "open")
    |> Map.put("history", [Map.put(answer, "reopened", %{"run" => run, "at" => @at})])
  end

  describe "check_run/3" do
    test "takes a first version whose questions are open and asked by the run" do
      assert Questions.check_run(nil, doc([open("q1", 12), open("q2", 12)]), 12) == :ok
    end

    test "takes questions added, withdrawn and reopened, the answers kept" do
      newest = doc([answered("q1", 12), open("q2", 12), answered("q3", 12)])

      pushed =
        doc([
          answered("q1", 12),
          Map.put(open("q2", 12), "state", "withdrawn"),
          reopened(answered("q3", 12), 13),
          Map.put(open("q4", 13), "follows", ["q3"])
        ])

      assert Questions.check_run(newest, pushed, 13) == :ok
    end

    test "refuses a version that drops an id" do
      newest = doc([open("q1", 12), open("q2", 12)])
      assert Questions.check_run(newest, doc([open("q1", 12)]), 13) == {:error, :id_dropped}
    end

    test "refuses an answer added, changed or removed by the run" do
      newest = doc([open("q1", 12), answered("q2", 12)])

      assert Questions.check_run(newest, doc([answered("q1", 12), answered("q2", 12)]), 13) ==
               {:error, :answer_changed}

      assert Questions.check_run(
               newest,
               doc([open("q1", 12), answered("q2", 12, "Another.")]),
               13
             ) == {:error, :answer_changed}

      withdrawn = answered("q2", 12) |> Map.delete("answer") |> Map.put("state", "withdrawn")

      assert Questions.check_run(newest, doc([open("q1", 12), withdrawn]), 13) ==
               {:error, :answer_changed}
    end

    test "refuses a history changed, or given to a new question" do
      earlier = reopened(answered("q1", 12), 13)
      newest = doc([earlier])

      changed =
        put_in(earlier, ["history", Access.at(0), "note"], "Another.")

      assert Questions.check_run(newest, doc([changed]), 14) == {:error, :history_changed}

      new = Map.put(open("q2", 14), "history", earlier["history"])
      assert Questions.check_run(newest, doc([earlier, new]), 14) == {:error, :history_changed}
    end

    test "refuses a reopen that does not move the answer, unchanged, into the history" do
      question = answered("q1", 12)
      newest = doc([question])
      bare = question |> Map.delete("answer") |> Map.put("state", "open")

      assert Questions.check_run(newest, doc([bare]), 13) == {:error, :reopen_not_kept}

      altered =
        put_in(reopened(question, 13), ["history", Access.at(0), "note"], "Another.")

      assert Questions.check_run(newest, doc([altered]), 13) == {:error, :reopen_not_kept}
    end

    test "refuses a new question that is not open, or asked by another run" do
      newest = doc([open("q1", 12)])

      added = open("q2", 13) |> Map.put("state", "withdrawn")

      assert Questions.check_run(newest, doc([open("q1", 12), added]), 13) ==
               {:error, :new_not_open}

      assert Questions.check_run(newest, doc([open("q1", 12), open("q2", 12)]), 13) ==
               {:error, :asked_run}

      assert Questions.check_run(nil, doc([open("q1", 12)]), 13) == {:error, :asked_run}
    end

    test "refuses asked changed on any question the newest version has" do
      newest = doc([open("q1", 12), answered("q2", 12)])
      other_run = %{"run" => 1, "at" => "2020-01-01T00:00:00Z"}

      for id <- ["q1", "q2"] do
        pushed =
          update_in(newest, ["questions"], fn questions ->
            Enum.map(
              questions,
              &if(&1["id"] == id, do: Map.put(&1, "asked", other_run), else: &1)
            )
          end)

        assert Questions.check_run(newest, pushed, 13) == {:error, :asked_changed}, id
      end

      # A reopen keeps it too.
      moved = Map.put(reopened(answered("q2", 12), 13), "asked", other_run)

      assert Questions.check_run(newest, doc([open("q1", 12), moved]), 13) ==
               {:error, :asked_changed}
    end

    test "refuses the question, context, options or follows of an answered question changed" do
      question =
        "q1"
        |> answered(12)
        |> Map.merge(%{
          "question" => "Delete the old records?",
          "context" => "They are from 2020.",
          "options" => [
            %{"title" => "Yes", "explanation" => "Delete them."},
            %{"title" => "No", "explanation" => "Keep them."}
          ],
          "follows" => []
        })

      newest = doc([question])

      for {key, value} <- [
            {"question", "Keep the old records?"},
            {"context", "They are from 2021."},
            {"options",
             [
               %{"title" => "Yes", "explanation" => "Keep them."},
               %{"title" => "No", "explanation" => "Delete them."}
             ]},
            {"follows", ["q0"]}
          ] do
        assert Questions.check_run(newest, doc([Map.put(question, key, value)]), 13) ==
                 {:error, :answered_changed},
               key
      end

      assert Questions.check_run(newest, doc([Map.delete(question, "context")]), 13) ==
               {:error, :answered_changed}

      # An open question's text is the run's to change, and so is a reopened one's.
      open = Map.merge(open("q2", 12), %{"question" => "Which month?"})

      assert Questions.check_run(
               doc([question, open]),
               doc([
                 question |> reopened(13) |> Map.put("question", "Delete the 2020 records?"),
                 Map.put(open, "question", "Which month of 2020?")
               ]),
               13
             ) == :ok
    end

    test "refuses a reopen that names another run" do
      newest = doc([answered("q1", 12)])

      assert Questions.check_run(newest, doc([reopened(answered("q1", 12), 99)]), 13) ==
               {:error, :reopened_run}

      assert Questions.check_run(newest, doc([reopened(answered("q1", 12), 13)]), 13) == :ok
    end

    test "reasons/0 is each reason the check refuses for" do
      assert Questions.reasons() ==
               [
                 :id_dropped,
                 :asked_changed,
                 :answer_changed,
                 :history_changed,
                 :reopen_not_kept,
                 :reopened_run,
                 :answered_changed,
                 :new_not_open,
                 :asked_run
               ]
    end
  end

  describe "answer/4" do
    test "answers the open questions given, an option or a note, and leaves the rest" do
      document =
        doc([
          Map.put(open("q1", 12), "options", [%{"title" => "Yes", "explanation" => "Why."}]),
          open("q2", 12),
          open("q3", 12),
          answered("q4", 12)
        ])

      at = ~U[2026-11-04 12:00:00.123456Z]

      assert {:ok, %{"questions" => [q1, q2, q3, q4]}} =
               Questions.answer(
                 document,
                 [{"q1", "Yes", nil}, {"q2", nil, "The spring sale."}, {"q4", nil, "Again."}],
                 "Ann Example",
                 at
               )

      assert q1["answer"] == %{"option" => "Yes", "by" => @by, "at" => "2026-11-04T12:00:00Z"}

      assert q2["answer"] == %{
               "option" => nil,
               "note" => "The spring sale.",
               "by" => @by,
               "at" => "2026-11-04T12:00:00Z"
             }

      assert q3 == open("q3", 12)
      assert q4 == answered("q4", 12)
    end

    test "an empty option is a member's own answer: option null, with its note" do
      document = doc([open("q1", 12), open("q2", 12)])
      at = ~U[2026-11-04 12:00:00Z]

      assert {:ok, %{"questions" => [q1, _q2]} = answered} =
               Questions.answer(document, [{"q1", "", "The saved one."}], "Ann Example", at)

      assert %{"option" => nil, "note" => "The saved one."} = q1["answer"]
      assert Jason.encode!(answered) =~ ~s("option":null)

      assert Questions.answer(document, [{"q1", " ", nil}], "Ann Example", at) ==
               {:error, {:note_required, "q1"}}
    end

    test "an answer with no option and no note is refused" do
      document = doc([open("q1", 12), open("q2", 12)])

      for note <- [nil, "", " \n "] do
        assert Questions.answer(
                 document,
                 [{"q1", nil, "Yes."}, {"q2", nil, note}],
                 "Ann",
                 DateTime.utc_now()
               ) ==
                 {:error, {:note_required, "q2"}}
      end
    end

    test "words/1 is the option's title, else the note" do
      assert Questions.words(%{"option" => "Yes"}) == {"Yes", false}

      assert Questions.words(%{"option" => nil, "note" => "The spring sale."}) ==
               {"The spring sale.", true}
    end
  end
end
