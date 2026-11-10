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

  defp option(title), do: %{"title" => title, "explanation" => "The #{title} store."}

  # Question `id`, asked by run `run`, decided for the option `chosen` by run `by`.
  defp decided(id, run, chosen, by),
    do:
      id
      |> open(run)
      |> Map.merge(%{
        "options" => [option("Redis"), option("Postgres")],
        "state" => "decided",
        "decision" => %{
          "option" => chosen,
          "reason" => "The other services use Redis.",
          "run" => by,
          "at" => @at
        }
      })

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

    test "refuses a new question that is not open or decided, or asked by another run" do
      newest = doc([open("q1", 12)])

      for state <- ["withdrawn", "answered", "closed"] do
        added = open("q2", 13) |> Map.put("state", state)

        assert Questions.check_run(newest, doc([open("q1", 12), added]), 13) ==
                 {:error, :new_not_open},
               state
      end

      # Open, with a decision.
      with_decision =
        Map.put(open("q2", 13), "decision", decided("q2", 13, "Redis", 13)["decision"])

      assert Questions.check_run(newest, doc([open("q1", 12), with_decision]), 13) ==
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

    test "refuses the question, context or options of an answered question changed" do
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
             ]}
          ] do
        assert Questions.check_run(newest, doc([Map.put(question, key, value)]), 13) ==
                 {:error, :answered_changed},
               key
      end

      assert Questions.check_run(newest, doc([Map.delete(question, "context")]), 13) ==
               {:error, :answered_changed}

      # An option's recommended is part of the options: a run adds it, removes it or moves
      # it on no answered question.
      plain = [
        %{"title" => "Yes", "explanation" => "Delete them."},
        %{"title" => "No", "explanation" => "Keep them."}
      ]

      recommended = fn [first, second] -> [Map.put(first, "recommended", true), second] end
      moved = fn [first, second] -> [first, Map.put(second, "recommended", true)] end

      for {from, to} <- [
            {plain, recommended.(plain)},
            {recommended.(plain), plain},
            {recommended.(plain), moved.(plain)}
          ] do
        kept = Map.put(question, "options", from)

        assert Questions.check_run(
                 doc([kept]),
                 doc([Map.put(kept, "options", to)]),
                 13
               ) == {:error, :answered_changed}

        assert Questions.check_run(doc([kept]), doc([kept]), 13) == :ok
      end

      # On an open question the options are the run's to change, recommended among them.
      open_one = Map.put(open("q3", 12), "options", plain)

      assert Questions.check_run(
               doc([open_one]),
               doc([Map.put(open_one, "options", recommended.(plain))]),
               13
             ) == :ok

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

    test "refuses follows changed on any question the newest version has" do
      newest =
        doc([open("q1", 12), Map.put(open("q2", 12), "follows", ["q1"]), answered("q3", 12)])

      for {id, follows} <- [{"q1", ["q2"]}, {"q2", []}, {"q2", ["q1", "q3"]}, {"q3", ["q1"]}] do
        pushed =
          update_in(newest, ["questions"], fn questions ->
            Enum.map(
              questions,
              &if(&1["id"] == id, do: Map.put(&1, "follows", follows), else: &1)
            )
          end)

        assert Questions.check_run(newest, pushed, 13) == {:error, :follows_changed},
               inspect({id, follows})
      end

      # Absent and empty are the same: the question follows from none.
      assert Questions.check_run(
               newest,
               update_in(newest, ["questions", Access.at(0)], &Map.put(&1, "follows", [])),
               13
             ) == :ok

      # A reopen keeps it too.
      reopen = newest |> update_in(["questions", Access.at(2)], &reopened(&1, 13))
      assert Questions.check_run(newest, reopen, 13) == :ok

      assert Questions.check_run(
               newest,
               update_in(reopen, ["questions", Access.at(2)], &Map.put(&1, "follows", ["q1"])),
               13
             ) == {:error, :follows_changed}
    end

    test "takes follows on a new question only to ids of questions before it" do
      newest = doc([open("q1", 12), answered("q2", 12)])

      added = fn follows -> Map.put(open("q3", 13), "follows", follows) end

      for follows <- [["q1"], ["q1", "q2"], []] do
        assert Questions.check_run(newest, doc(newest["questions"] ++ [added.(follows)]), 13) ==
                 :ok,
               inspect(follows)
      end

      # A new question before it in the same version counts.
      assert Questions.check_run(
               newest,
               doc(
                 newest["questions"] ++
                   [added.(["q1"]), Map.put(open("q4", 13), "follows", ["q3"])]
               ),
               13
             ) == :ok

      for follows <- [["q9"], ["q3"], ["q1", "q4"]] do
        assert Questions.check_run(
                 newest,
                 doc(newest["questions"] ++ [added.(follows), open("q4", 13)]),
                 13
               ) == {:error, :follows_unknown},
               inspect(follows)
      end

      # An earlier question placed after it changes the order.
      assert Questions.check_run(
               newest,
               doc([open("q1", 12), added.(["q2"]), answered("q2", 12)]),
               13
             ) == {:error, :order_changed}
    end

    test "keeps the questions of the newest version first, in its order" do
      q1 = open("q1", 12)
      q2 = Map.put(open("q2", 12), "follows", ["q1"])
      newest = doc([q1, q2])

      # Reordered, so q2 would follow a question after it.
      assert Questions.check_run(newest, doc([q2, q1]), 13) == {:error, :order_changed}

      # A new question before or between them.
      assert Questions.check_run(newest, doc([open("q3", 13), q1, q2]), 13) ==
               {:error, :order_changed}

      assert Questions.check_run(newest, doc([q1, open("q3", 13), q2]), 13) ==
               {:error, :order_changed}

      # A dropped question is id_dropped, whatever the order.
      assert Questions.check_run(newest, doc([q2]), 13) == {:error, :id_dropped}

      # New questions after them.
      assert Questions.check_run(newest, doc([q1, q2, open("q3", 13), open("q4", 13)]), 13) ==
               :ok

      # The first version has no order to keep.
      assert Questions.check_run(nil, doc([open("q2", 13), open("q1", 13)]), 13) == :ok
    end

    test "refuses a reopen that names another run" do
      newest = doc([answered("q1", 12)])

      assert Questions.check_run(newest, doc([reopened(answered("q1", 12), 99)]), 13) ==
               {:error, :reopened_run}

      assert Questions.check_run(newest, doc([reopened(answered("q1", 12), 13)]), 13) == :ok
    end

    test "compares numbers by value, as the schema's integers: 13.0 is run 13" do
      assert Questions.check_run(nil, doc([open("q1", 13.0)]), 13) == :ok
      assert Questions.check_run(nil, doc([open("q1", 13.5)]), 13) == {:error, :asked_run}

      newest = doc([answered("q1", 12)])

      assert Questions.check_run(newest, doc([answered("q1", 12.0)]), 13) == :ok

      assert Questions.check_run(newest, doc([answered("q1", 11.0)]), 13) ==
               {:error, :asked_changed}

      assert Questions.check_run(newest, doc([reopened(answered("q1", 12), 13.0)]), 13) == :ok
    end

    test "takes a decision by the run that asked the question, kept in every state" do
      decided = decided("q1", 13, "Redis", 13)

      assert Questions.check_run(nil, doc([decided]), 13) == :ok
      assert Questions.check_run(doc([decided]), doc([decided]), 14) == :ok

      # A later run withdraws the decided question, and the decision stays.
      withdrawn = Map.put(decided, "state", "withdrawn")
      assert Questions.check_run(doc([decided]), doc([withdrawn]), 14) == :ok

      # A member answered it, and a later run reopens the answer.
      answered =
        Map.merge(decided, %{
          "state" => "answered",
          "answer" => %{"option" => "Postgres", "by" => @by, "at" => @at}
        })

      assert Questions.check_run(doc([answered]), doc([answered]), 14) == :ok
      assert Questions.check_run(doc([answered]), doc([reopened(answered, 14)]), 14) == :ok

      # Numbers compare by value: 13.0 is run 13.
      assert Questions.check_run(nil, doc([decided("q1", 13, "Redis", 13.0)]), 13) == :ok
    end

    test "refuses a question of the newest version set to decided" do
      options = [option("Redis"), option("Postgres")]
      asked = Map.put(open("q1", 13), "options", options)
      decided = decided("q1", 13, "Redis", 13)

      # Open, withdrawn or answered in the newest version, by this run or an earlier one.
      for earlier <- [
            asked,
            Map.put(asked, "state", "withdrawn"),
            Map.merge(asked, %{
              "state" => "answered",
              "answer" => %{"option" => "Postgres", "by" => @by, "at" => @at}
            })
          ],
          run <- [13, 14] do
        assert Questions.check_run(doc([earlier]), doc([decided]), run) ==
                 {:error, :decided_not_new},
               inspect({earlier["state"], run})
      end

      # A decided question that a later run withdrew stays withdrawn.
      withdrawn = Map.put(decided, "state", "withdrawn")

      assert Questions.check_run(doc([withdrawn]), doc([decided]), 14) ==
               {:error, :decided_not_new}
    end

    test "takes a new question decided by the run that asks it" do
      newest = doc([open("q1", 12)])

      assert Questions.check_run(
               newest,
               doc([open("q1", 12), decided("q2", 13, "Redis", 13)]),
               13
             ) ==
               :ok

      assert Questions.check_run(nil, doc([decided("q1", 13, "Postgres", 13)]), 13) == :ok
    end

    test "refuses a new decided question whose decision is by another run, or on no option" do
      newest = doc([open("q1", 12)])

      # asked.run is the run's number, decision.run another run's.
      assert Questions.check_run(
               newest,
               doc([open("q1", 12), decided("q2", 13, "Redis", 12)]),
               13
             ) ==
               {:error, :decision_run}

      assert Questions.check_run(nil, doc([decided("q1", 13, "Memcached", 13)]), 13) ==
               {:error, :decision_option}

      # Asked by another run, the question is refused first for its asked.run.
      assert Questions.check_run(nil, doc([decided("q1", 12, "Redis", 12)]), 13) ==
               {:error, :asked_run}
    end

    test "refuses a decision on no option of its question" do
      for chosen <- ["Memcached", "redis", "Redis "] do
        assert Questions.check_run(nil, doc([decided("q1", 13, chosen, 13)]), 13) ==
                 {:error, :decision_option},
               chosen
      end

      # The option is checked before the run.
      assert Questions.check_run(nil, doc([decided("q1", 13, "Memcached", 12)]), 13) ==
               {:error, :decision_option}
    end

    test "keeps the question and options of a question with a decision in every state" do
      decided = decided("q1", 13, "Redis", 13)
      other = [option("Postgres"), option("Valkey")]

      # A later run sets the decided question back to open, the decision kept.
      open = Map.put(decided, "state", "open")
      assert Questions.check_run(doc([decided]), doc([open]), 14) == :ok

      assert Questions.check_run(doc([decided]), doc([Map.put(open, "options", other)]), 14) ==
               {:error, :decided_changed}

      # A member answered it, and a later run reopens the answer.
      answered =
        Map.merge(decided, %{
          "state" => "answered",
          "answer" => %{"option" => "Postgres", "by" => @by, "at" => @at}
        })

      reopened = reopened(answered, 14)
      assert Questions.check_run(doc([answered]), doc([reopened]), 14) == :ok

      # The reopen adds to the context what contradicts the answer, as for any answered
      # question; the question and options stay.
      added = Map.put(reopened, "context", "The baskets move to the storefront.")
      assert Questions.check_run(doc([answered]), doc([added]), 14) == :ok

      assert Questions.check_run(
               doc([answered]),
               doc([Map.put(added, "options", other)]),
               14
             ) == {:error, :decided_changed}

      # While it stays decided or answered, the context stays too.
      for earlier <- [decided, answered] do
        assert Questions.check_run(
                 doc([earlier]),
                 doc([Map.put(earlier, "context", "The baskets move.")]),
                 14
               ) ==
                 {:error, if(earlier == answered, do: :answered_changed, else: :decided_changed)}
      end

      # A later run withdraws it.
      withdrawn = Map.put(decided, "state", "withdrawn")
      assert Questions.check_run(doc([decided]), doc([withdrawn]), 14) == :ok

      assert Questions.check_run(doc([decided]), doc([Map.put(withdrawn, "options", [])]), 14) ==
               {:error, :decided_changed}

      # Dropped, the decision is refused.
      assert Questions.check_run(doc([answered]), doc([Map.delete(reopened, "decision")]), 14) ==
               {:error, :decision_changed}
    end

    test "refuses a decision changed, dropped or added on a question the newest version has" do
      decided = decided("q1", 13, "Redis", 13)
      newest = doc([decided])

      # A later run changes the option or the run of the decision.
      assert Questions.check_run(
               newest,
               doc([put_in(decided, ["decision", "option"], "Postgres")]),
               14
             ) ==
               {:error, :decision_changed}

      assert Questions.check_run(newest, doc([put_in(decided, ["decision", "run"], 14)]), 14) ==
               {:error, :decision_changed}

      # A withdraw drops the decision.
      withdrawn = decided |> Map.put("state", "withdrawn") |> Map.delete("decision")
      assert Questions.check_run(newest, doc([withdrawn]), 14) == {:error, :decision_changed}

      # A reopen of an answer drops the decision.
      answered =
        Map.merge(decided, %{
          "state" => "answered",
          "answer" => %{"option" => "Postgres", "by" => @by, "at" => @at}
        })

      assert Questions.check_run(
               doc([answered]),
               doc([answered |> reopened(14) |> Map.delete("decision")]),
               14
             ) == {:error, :decision_changed}

      # A decision added to an open question, which stays open.
      asked = Map.put(open("q1", 13), "options", [option("Redis"), option("Postgres")])

      assert Questions.check_run(
               doc([asked]),
               doc([Map.put(asked, "decision", decided["decision"])]),
               13
             ) ==
               {:error, :decision_changed}

      # Run 14 decides a question run 13 asked, with decision.run 13: the question is not
      # new.
      assert Questions.check_run(doc([asked]), doc([decided]), 14) == {:error, :decided_not_new}
    end

    test "refuses question, context or options changed on a decided question" do
      decided = decided("q1", 13, "Redis", 13)
      newest = doc([decided])

      for {key, value} <- [
            {"question", "Which store keeps the carts?"},
            {"context", "The baskets move to the storefront."},
            {"options", [option("Postgres"), option("Valkey")]},
            {"options", [option("Redis")]}
          ] do
        assert Questions.check_run(newest, doc([Map.put(decided, key, value)]), 14) ==
                 {:error, :decided_changed},
               key
      end

      # A run that learns more withdraws it and adds a new one, with other options.
      withdrawn = Map.put(decided, "state", "withdrawn")
      added = decided("q2", 14, "Valkey", 14) |> Map.put("options", [option("Valkey")])
      assert Questions.check_run(newest, doc([withdrawn, added]), 14) == :ok
    end

    test "refuses a decision by another run than the one that asked the question" do
      # Run 13 asks the question, and the decision is run 12's.
      assert Questions.check_run(nil, doc([decided("q1", 13, "Redis", 12)]), 13) ==
               {:error, :decision_run}

      assert Questions.check_run(nil, doc([decided("q1", 13, "Redis", 13.5)]), 13) ==
               {:error, :decision_run}
    end

    test "reasons/0 is each reason the check refuses for" do
      assert Questions.reasons() ==
               [
                 :id_dropped,
                 :asked_changed,
                 :follows_changed,
                 :order_changed,
                 :answer_changed,
                 :history_changed,
                 :reopen_not_kept,
                 :reopened_run,
                 :answered_changed,
                 :new_not_open,
                 :asked_run,
                 :follows_unknown,
                 :decision_option,
                 :decision_run,
                 :decided_not_new,
                 :decision_changed,
                 :decided_changed
               ]
    end
  end

  describe "open_in_take_in/2" do
    test "keeps the open questions whose asked.run or last reopened.run is a run given" do
      # Runs 12 and 13 are take in 1's, runs 20 and 21 take in 2's.
      ended = Map.put(answered("q5", 12)["answer"], "reopened", %{"run" => 13, "at" => @at})

      twice =
        answered("q5", 12)
        |> reopened(21)
        |> Map.update!("history", &[ended | &1])

      document =
        doc([
          open("q1", 12),
          open("q2", 20),
          answered("q3", 20),
          reopened(answered("q4", 12), 21),
          reopened(answered("q6", 12), 13),
          twice,
          Map.put(open("q7", 21), "state", "withdrawn")
        ])

      ids = fn runs ->
        document |> Questions.open_in_take_in(MapSet.new(runs)) |> Enum.map(& &1["id"])
      end

      assert ids.([20, 21]) == ["q2", "q4", "q5"]
      assert ids.([13]) == ["q6"]
      assert ids.([]) == []
      assert Questions.open_in_take_in(nil, MapSet.new([20])) == []
    end
  end

  describe "answer/4" do
    test "keeps an option's recommended on the question it answers" do
      options = [
        %{"title" => "Yes", "explanation" => "Why.", "recommended" => true},
        %{"title" => "No", "explanation" => "Why not."}
      ]

      document = doc([Map.put(open("q1", 12), "options", options)])

      for given <- [{"q1", "No", nil}, {"q1", nil, "Neither."}] do
        assert {:ok, %{"questions" => [%{"state" => "answered", "options" => ^options}]}} =
                 Questions.answer(document, [given], "Ann Example", ~U[2026-11-04 12:00:00Z])
      end
    end

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
