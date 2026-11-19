defmodule ApiaryWeb.WorkItemLive.VerifyTabTest do
  # The tab of a stage with a `verification` output (`ApiaryWeb.WorkItemLive.VerifyTab`):
  # the matrix of the acceptance criteria with their states and evidence, the "not
  # verified" list, the model families, the member who accepted the stage's escalation, and
  # one Scenarios frame with each scenario's film or pictures in scenario order, of the
  # verified commit, without a withdrawn name.
  #
  # The fake changes the whole node (`ApiaryWeb.WorkflowFake.install/0`), so the module is
  # not async.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.StagesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Artifacts, Processes, Repo, Stages, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Stages.Escalation
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.ArtifactComponents
  alias ApiaryWeb.WorkItemLive.VerifyTab
  alias ApiaryWeb.WorkflowFake

  @moduletag needs: [:factory, :workflow_model]

  @explore "st_r79kph11eg"
  @shape "st_p9w5cvh311"
  @verify "st_m1mqbeywdg"

  @commit String.duplicate("c", 40)
  @older String.duplicate("d", 40)

  @mp4 <<0, 0, 0, 24, "ftypisom", 0, 0, 2, 0, "isomiso2">>
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR">>

  @ac1 "After a reload, the total still includes the voucher."
  @ac2 "On a phone, the voucher line fits the payment step."
  @ac3 "An expired voucher leaves the total unchanged."
  @check "Check that the voucher line fits in the pictures of scenario 2, because the run could not measure the line on a phone screen."

  @criteria %{
    "summary" => "The checkout takes a voucher.",
    "criteria" => [
      %{"id" => "ac-1", "text" => @ac1, "check" => "Demo: Reload the payment step"},
      %{"id" => "ac-2", "text" => @ac2, "check" => "Demo: Pay on a phone"},
      %{"id" => "ac-3", "text" => @ac3, "check" => "Tests"}
    ]
  }

  @verification %{
    "target_version" => @commit,
    "matrix" => [
      %{
        "criterion" => "ac-1",
        "state" => "met",
        "evidence" => "Film: demo-video scenario-1 v1, step 2 passed."
      },
      %{
        "criterion" => "ac-3",
        "state" => "not_met",
        "evidence" => "Locked check `tests/voucher.test.ts` failed: 2 of 3 tests passed."
      }
    ],
    "not_verified" => [%{"criterion" => "ac-2", "reason" => @check}],
    "model_families" => ["claude", "deepseek"]
  }

  setup_all do
    previous = WorkflowFake.install()
    on_exit(fn -> WorkflowFake.uninstall(previous) end)
    :ok
  end

  setup :register_and_log_in_user

  setup %{scope: scope} do
    for {name, view} <- [
          {"demo-evidence", "file"},
          {"demo-script", "file"}
        ] do
      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{"name" => name, "base_view" => view})
    end

    save_process!(scope, ~w(verification demo-video screenshot demo-evidence explainer))
    :ok
  end

  # The process Explore, Shape, then Verify, whose outputs are `outputs`, none required.
  defp save_process!(scope, outputs) do
    [explore | _rest] = Processes.default_document("software")["stages"]
    gate = %{"kind" => "person", "approvers" => "members"}

    {:ok, version} =
      Processes.save(scope, scope.workspace, %{
        "schema" => "qory.process/v1",
        "stages" => [
          explore,
          %{"id" => @shape, "name" => "Shape", "sequence" => [], "outputs" => [], "gate" => gate},
          %{
            "id" => @verify,
            "name" => "Verify",
            "sequence" => [%{"workflow" => "verify-a-ticket"}],
            "outputs" => Enum.map(outputs, &%{"type" => &1, "required" => false}),
            "gate" => gate
          }
        ]
      })

    version
  end

  # A work item at Verify's gate, whose run of Verify pushed what `push` pushes, with the
  # run of the queue and the work item, then passed: at the gate, or, with the state
  # `:waiting_answers`, with the questions that the run asked still open.
  defp at_verify_gate!(scope, push, state \\ :at_gate) do
    {:ok, work_item} = WorkItems.take_in(scope, backlog_ticket_fixture(scope).public_id)
    work_item = Repo.get!(WorkItem, work_item.id) |> end_run!(understood_result())
    {:ok, _work_item} = WorkItems.confirm(scope, work_item, 1)
    work_item = Repo.get!(WorkItem, work_item.id)
    {:ok, _work_item} = Stages.approve(scope, work_item, nil, expect_stage: @shape)

    work_item =
      work_item
      |> then(&Repo.get!(WorkItem, &1.id))
      |> end_run!(fn run, _registered ->
        push.(run, Repo.get!(WorkItem, run.work_item_id))

        {:ok, _version} =
          Stages.Artifacts.push_json(
            {:run, run},
            Repo.get!(WorkItem, run.work_item_id),
            "verdict",
            %{"verdict" => "passed"},
            stage_id: run.stage_id
          )
      end)

    assert %WorkItem{stage_id: @verify, stage_state: ^state} = work_item
    work_item
  end

  defp push!(run, work_item, type, name, files) do
    {:ok, version} =
      Artifacts.push(
        {:run, run},
        work_item,
        type,
        for(
          {filename, binary} <- files,
          do: %{filename: filename, content_type: "application/octet-stream", binary: binary}
        ),
        name: name,
        stage_id: run.stage_id
      )

    version
  end

  defp steps(titles),
    do:
      for(
        {title, i} <- Enum.with_index(titles, 1),
        do: %{"step" => i, "title" => title, "expected" => "Result #{i} of #{title}."}
      )

  # A scenario's film or pictures, and its demo evidence of `commit`.
  defp scenario!(run, work_item, n, kind, commit \\ @commit) do
    name = "scenario-#{n}"
    titles = ["Open #{name}", "Reload #{name}"]

    {type, files} =
      case kind do
        :film ->
          {"demo-video",
           [
             {"#{name}.mp4", @mp4},
             {"#{name}.vtt", "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nOpen\n"}
           ]}

        :pictures ->
          {"screenshot", [{"#{name}-step-2.png", @png}, {"#{name}-step-1.png", @png}]}
      end

    media = push!(run, work_item, type, name, files)

    evidence = %{
      "scenario" => name,
      "title" => "Title of #{name}",
      "commit" => commit,
      "planned" => if(kind == :film, do: "film", else: "pictures"),
      "evidence" => if(kind == :film, do: "film", else: "pictures"),
      "verdict" => "passed",
      "script" => %{"type" => "demo-script", "name" => name, "version" => 1},
      "media" => %{"type" => type, "name" => name, "version" => media.number},
      "steps" => steps(titles)
    }

    push!(run, work_item, "demo-evidence", name, [{"#{name}.json", Jason.encode!(evidence)}])
    media
  end

  # The run's acceptance criteria `@criteria`, then its verification `document`.
  defp verification!(run, work_item, document \\ @verification) do
    push!(run, work_item, "acceptance-criteria", "main", [
      {"acceptance-criteria.json", Jason.encode!(@criteria)}
    ])

    push!(run, work_item, "verification", "main", [
      {"verification.json", Jason.encode!(document)}
    ])
  end

  # A run of the queue at Verify for `work_item`, of the take in `take_in`, after its
  # newest run.
  defp verify_run!(work_item, take_in) do
    newest = newest_run(work_item)

    %DispatchRun{organisation_id: work_item.organisation_id, workspace_id: work_item.workspace_id}
    |> DispatchRun.queue_changeset(%{
      work_item_id: work_item.id,
      step: newest.step,
      take_in: take_in,
      attempt: newest.attempt + 1,
      of: max(newest.of, newest.attempt + 1),
      queued_at: DateTime.utc_now()
    })
    |> Ecto.Changeset.put_change(:stage_id, @verify)
    |> Repo.insert!()
  end

  # The run, cancelled by a member.
  defp cancel!(scope, run) do
    Apiary.RunEventsFixtures.run_fixture(scope, %{
      dispatch_run_id: run.id,
      cancel_requested_at: DateTime.utc_now()
    })
  end

  defp explainer!(run, work_item) do
    {:ok, version} =
      Artifacts.push(
        {:run, run},
        work_item,
        "explainer",
        [
          %{
            filename: "explainer.md",
            content_type: "text/markdown",
            binary: "Words of the explainer."
          }
        ],
        stage_id: run.stage_id
      )

    version
  end

  # A verification of `@commit` whose matrix is `rows`, each `{criterion, state,
  # evidence}`, with nothing not verified.
  defp matrix(rows) do
    %{
      "target_version" => @commit,
      "matrix" =>
        for(
          {criterion, state, evidence} <- rows,
          do: %{"criterion" => criterion, "state" => state, "evidence" => evidence}
        ),
      "not_verified" => [],
      "model_families" => ["claude"]
    }
  end

  defp ids(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))
  end

  defp tab(conn, scope, work_item) do
    {:ok, view, _html} =
      live(
        conn,
        ~p"/#{scope.organisation}/#{scope.workspace}/work/#{work_item.number}/stages/#{@verify}"
      )

    view
  end

  # The tab of Explore, the stage of the proposal.
  defp item_page(conn, scope, work_item) do
    {:ok, view, _html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/work/#{work_item.number}/explore")

    view
  end

  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

  describe "the verification" do
    test "the matrix, the not verified list and the model families", %{conn: conn, scope: scope} do
      work_item = at_verify_gate!(scope, &verification!/2)
      view = tab(conn, scope, work_item)
      parts = "#work-item-tab-output-verification-parts"

      assert has_element?(view, "#work-item-tab-output-verification-h", "Verification")

      assert has_element?(
               view,
               "#work-item-tab-output-verification-s",
               "Version 1 · Model families: claude · deepseek"
             )

      # Each row: the criterion's id in upper case and its text from the newest acceptance
      # criteria, then, on a phone, the evidence.
      assert texts(view, "#{parts}-matrix tr td:first-child") == [
               "AC-1 #{@ac1} Film: demo-video scenario-1 v1, step 2 passed.",
               "AC-3 #{@ac3} Locked check `tests/voucher.test.ts` failed: 2 of 3 tests passed."
             ]

      assert texts(view, "#{parts}-matrix tr td:first-child > span.font-medium") ==
               ["AC-1", "AC-3"]

      assert texts(view, "#{parts}-matrix tr td:nth-child(2)") == ["Met", "Not met"]

      assert has_element?(
               view,
               "#{parts}-matrix-1 td.q-from-sm",
               "Locked check `tests/voucher.test.ts` failed"
             )

      assert has_element?(view, "#{parts}-matrix-0 .badge.bg-success-soft", "Met")
      assert has_element?(view, "#{parts}-matrix-1 .badge.bg-error-soft", "Not met")

      assert texts(view, "#{parts}-not-verified li > span") == ["AC-2 #{@ac2}", @check]

      # The verified version of the target is not shown.
      refute render(view) =~ @commit
      refute has_element?(view, "#{parts}-accepted-findings")

      assert has_element?(
               view,
               "#{parts} #work-item-tab-output-verification-row",
               "verification v1"
             )

      refute has_element?(view, "#{parts}-accepted")
    end

    test "after a member accepted the escalation: who, above the matrix; the row stays",
         %{conn: conn, scope: scope} do
      work_item = at_verify_gate!(scope, &verification!/2)

      Repo.insert!(%Escalation{
        organisation_id: work_item.organisation_id,
        workspace_id: work_item.workspace_id,
        work_item_id: work_item.id,
        stage_id: @verify,
        process_version_id: work_item.process_version_id,
        round: 1,
        cause: :run_stopped,
        resolution: :accept,
        resolved_by_id: scope.user.id,
        resolved_at: DateTime.add(DateTime.utc_now(), 1, :second),
        inserted_at: DateTime.utc_now()
      })

      view = tab(conn, scope, work_item)
      name = ApiaryWeb.People.short(scope.user.email)

      assert texts(view, "#work-item-tab-output-verification-parts > *") |> hd() ==
               "Accepted as it is by #{name}"

      assert has_element?(
               view,
               "#work-item-tab-output-verification-parts-matrix-1 .badge",
               "Not met"
             )

      refute has_element?(view, "#work-item-stage-gate", "Accepted as it is")
    end

    test "an escalation accepted before the verification shows no member",
         %{conn: conn, scope: scope} do
      work_item = at_verify_gate!(scope, &verification!/2)

      Repo.insert!(%Escalation{
        organisation_id: work_item.organisation_id,
        workspace_id: work_item.workspace_id,
        work_item_id: work_item.id,
        stage_id: @verify,
        process_version_id: work_item.process_version_id,
        round: 1,
        cause: :run_stopped,
        resolution: :accept,
        resolved_by_id: scope.user.id,
        resolved_at: DateTime.add(DateTime.utc_now(), -3600, :second),
        inserted_at: DateTime.add(DateTime.utc_now(), -3700, :second)
      })

      view = tab(conn, scope, work_item)
      assert has_element?(view, "#work-item-tab-output-verification-parts-matrix")
      refute has_element?(view, "#work-item-tab-output-verification-parts-accepted")
    end

    test "a criterion with no row in the newest acceptance criteria shows its id alone",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(
          scope,
          &verification!(&1, &2, matrix([{"ac-9", "met", "The test passed."}]))
        )

      view = tab(conn, scope, work_item)

      assert texts(view, "#work-item-tab-output-verification-parts-matrix tr td:first-child") ==
               ["AC-9 The test passed."]
    end
  end

  @proposal_ac2 "AC-2 Demo: on a phone, the voucher line wraps to two lines in the payment step."

  # The question of verify-a-ticket about a criterion that cannot be met: its criterion, its
  # context as two paragraphs, Why and Checked, and the three options the agent writes, the
  # first with the criterion's new wording (`proposal`).
  @ac_question %{
    "question" => "AC-2 can't be met as written",
    "about" => %{"type" => "acceptance-criteria", "name" => "main", "item" => "ac-2"},
    "context" =>
      "**Why:** The payment step is 320 px wide on a phone.\n\n**Checked:** The pictures of scenario 2.",
    "options" => [
      %{
        "title" => "Change AC-2",
        "explanation" => "The criterion takes the wording below.",
        "proposal" => @proposal_ac2,
        "recommended" => true
      },
      %{"title" => "Make it met another way", "explanation" => "Write in the note how."},
      %{
        "title" => "Withdraw AC-2",
        "explanation" => "AC-2 stays in the criteria, marked withdrawn by you."
      }
    ]
  }

  # The run of Verify pushes a matrix with AC-1 Met and AC-2 Not met, and asks `questions`.
  defp ac_question_run(questions) do
    fn run, work_item ->
      verification!(
        run,
        work_item,
        matrix([
          {"ac-1", "met", "`tests/total.test.ts` passed."},
          {"ac-2", "not_met", "The voucher line needs 360 px."}
        ])
      )

      registered = Repo.get_by!(Apiary.Runs.Run, dispatch_run_id: run.id)

      Apiary.WorkItemsFixtures.push_output!(
        run,
        registered,
        Apiary.WorkItemsFixtures.questions_result(questions)
      )
    end
  end

  defp waiting_at_verify!(scope, questions \\ [@ac_question]),
    do: at_verify_gate!(scope, ac_question_run(questions), :waiting_answers)

  defp questions_page(conn, scope, work_item) do
    {:ok, view, _html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/work/#{work_item.number}/questions")

    view
  end

  defp answer_of(work_item, id) do
    {_version, document} = Apiary.Explore.Questions.newest(Repo.get!(WorkItem, work_item.id))
    Enum.find(document["questions"], &(&1["id"] == id))["answer"]
  end

  defp send_answers(view, work_item, answers) do
    view
    |> element("#work-item-tab-questions-open-form")
    |> render_submit(%{"number" => "#{work_item.number}", "answers" => answers})
  end

  describe "a question about a criterion" do
    test "Change AC-2: with the proposal in a field it labels, on both tabs, and no quote",
         %{conn: conn, scope: scope} do
      work_item = waiting_at_verify!(scope)

      for {view, prefix} <- [
            {tab(conn, scope, work_item), "work-item-tab-questions"},
            {questions_page(conn, scope, work_item), "work-item-questions"}
          ] do
        question = "##{prefix}-question-1"
        field = "#{prefix}-open-answer-1-1"

        # The proposal is in the field, not in a quote: the one quote is the criterion's
        # text under the About line.
        assert texts(view, "#{question} blockquote") == [@ac2]
        assert has_element?(view, "#{question} strong", "Why:")
        assert has_element?(view, "#{question} strong", "Checked:")

        assert texts(view, "#{question} .q-xp-opt-t") == [
                 "Change AC-2:",
                 "Make it met another way",
                 "Withdraw AC-2",
                 "Give your own option"
               ]

        # The field is in the option's box, outside the radio's label, and labelled by the
        # option's words.
        assert has_element?(
                 view,
                 "##{field}-box ##{field}-wording[name='answers[q1][wording]'][aria-labelledby=#{field}-label]",
                 @proposal_ac2
               )

        assert has_element?(view, "label##{field}-label[for=#{field}]", "Change AC-2:")
        # The label is the words alone: its text keeps white space as written.
        assert view |> element("##{field}-label") |> render() =~ ~r/>Change AC-2:<\/label>\z/
        refute has_element?(view, "label textarea")
        assert has_element?(view, "##{field}-box", "Recommended by the agent")
        refute has_element?(view, "##{field}-wording[aria-invalid]")
      end
    end

    test "the label comes from the criterion, not from the option's title", %{
      conn: conn,
      scope: scope
    } do
      options = List.update_at(@ac_question["options"], 0, &Map.put(&1, "title", "Reword it"))
      work_item = waiting_at_verify!(scope, [Map.put(@ac_question, "options", options)])
      view = tab(conn, scope, work_item)

      assert has_element?(view, "#work-item-tab-questions-open-answer-1-1-label", "Change AC-2:")
      refute render(view) =~ "Reword it"

      send_answers(view, work_item, %{"q1" => %{"option" => "1", "wording" => "AC-2 Tests: new."}})

      confirm_spend(view)

      assert %{"option" => "Reword it", "note" => "Change AC-2: AC-2 Tests: new."} =
               answer_of(work_item, "q1")
    end

    test "an answered question shows the chosen option's proposal as a quote in read mode", %{
      conn: conn,
      scope: scope
    } do
      work_item = waiting_at_verify!(scope)
      view = tab(conn, scope, work_item)

      send_answers(view, work_item, %{"q1" => %{"option" => "1", "wording" => "AC-2 Tests: new."}})

      confirm_spend(view)

      # The next run runs: the page is in read mode, and the answered question is closed.
      # The quote is the run's wording; the member's wording is in the answer's note.
      view = questions_page(conn, scope, work_item)
      answer = "#work-item-questions-question-1-answer"

      assert texts(view, "#{answer} > span") == [
               "Change AC-2 Recommended by the agent",
               "Change AC-2: AC-2 Tests: new."
             ]

      assert texts(view, "#{answer}-proposal blockquote") == [@proposal_ac2]
      assert texts(view, "#work-item-questions-question-1 blockquote") == [@ac2, @proposal_ac2]
    end

    test "an option with no proposal has no field, whatever its title", %{
      conn: conn,
      scope: scope
    } do
      options =
        Enum.map(@ac_question["options"], &Map.delete(&1, "proposal"))
        |> List.update_at(0, &Map.put(&1, "explanation", @proposal_ac2))

      work_item = waiting_at_verify!(scope, [Map.put(@ac_question, "options", options)])
      view = tab(conn, scope, work_item)
      question = "#work-item-tab-questions-question-1"

      refute has_element?(view, "#{question} textarea[name='answers[q1][wording]']")

      assert texts(view, "#{question} .q-xp-opt-t") == [
               "Change AC-2",
               "Make it met another way",
               "Withdraw AC-2",
               "Give your own option"
             ]

      assert has_element?(view, "#{question} .q-xp-opt-e", @proposal_ac2)
    end

    test "a question about the work item has no quote and no field", %{
      conn: conn,
      scope: scope
    } do
      options = Enum.map(@ac_question["options"], &Map.delete(&1, "proposal"))

      question =
        @ac_question
        |> Map.put("about", %{"work_item" => true})
        |> Map.put("options", options)

      work_item = waiting_at_verify!(scope, [question])
      view = tab(conn, scope, work_item)

      refute has_element?(view, "#work-item-tab-questions-question-1 blockquote")
      refute has_element?(view, "#work-item-tab-questions-question-1 textarea[name$='[wording]']")
      assert has_element?(view, "#work-item-tab-questions-question-1 .q-xp-opt-t", "Change AC-2")
    end

    test "the member edits the wording of Change AC-2: the answer stores the edited wording", %{
      conn: conn,
      scope: scope
    } do
      work_item = waiting_at_verify!(scope)
      view = tab(conn, scope, work_item)
      edited = "AC-2 Demo: on a phone, the voucher line shows as an icon in the payment step."

      send_answers(view, work_item, %{
        "q1" => %{"option" => "1", "wording" => edited, "note" => "Ask design."}
      })

      confirm_spend(view)

      assert %{"option" => "Change AC-2", "note" => note} = answer_of(work_item, "q1")
      assert note == "Change AC-2: #{edited}\n\nAsk design."
    end

    test "the agent's wording, its line breaks given as CR LF or CR, is the option alone", %{
      conn: conn,
      scope: scope
    } do
      proposal = "AC-2 Demo: on a phone,\nthe voucher line wraps."
      options = List.update_at(@ac_question["options"], 0, &Map.put(&1, "proposal", proposal))

      for given <- [
            " #{proposal}\n",
            "AC-2 Demo: on a phone,\r\nthe voucher line wraps.",
            "AC-2 Demo: on a phone,\rthe voucher line wraps."
          ] do
        work_item = waiting_at_verify!(scope, [Map.put(@ac_question, "options", options)])
        view = tab(conn, scope, work_item)

        send_answers(view, work_item, %{"q1" => %{"option" => "1", "wording" => given}})
        confirm_spend(view)

        assert %{"option" => "Change AC-2"} = answer = answer_of(work_item, "q1")
        refute Map.has_key?(answer, "note"), inspect(given)
      end
    end

    test "a wording that makes the note too long shows its limit on its field, and sends nothing",
         %{conn: conn, scope: scope} do
      work_item = waiting_at_verify!(scope)
      view = tab(conn, scope, work_item)
      note = String.duplicate("n", 100)
      field = "#work-item-tab-questions-open-answer-1-1-wording"

      send_answers(view, work_item, %{
        "q1" => %{"option" => "1", "wording" => String.duplicate("w", 1_990), "note" => note}
      })

      # 2,000 characters less "Change AC-2: " (13) and the blank line and note (102).
      assert has_element?(
               view,
               "#{field}-error",
               "Shorten the new wording to at most 1,885 characters, or shorten your note."
             )

      assert has_element?(
               view,
               "#{field}[aria-invalid=true][aria-describedby=#{String.trim_leading(field, "#")}-error]"
             )

      refute has_element?(view, "#work-item-tab-questions-open-answer-1-error")
      refute has_element?(view, "#spend-dialog")
      assert answer_of(work_item, "q1") == nil

      # Focus moves to the wording field, not the note's.
      focus = view |> element("#work-item-tab-questions-open-focus-1-1[hidden]") |> render()
      assert focus =~ "#work-item-tab-questions-open-answer-1-1-wording"
    end

    test "Change AC-2 with the field cleared shows its line on the field, and sends nothing", %{
      conn: conn,
      scope: scope
    } do
      for wording <- ["", "  \n "] do
        work_item = waiting_at_verify!(scope)
        view = tab(conn, scope, work_item)
        field = "work-item-tab-questions-open-answer-1-1-wording"

        send_answers(view, work_item, %{
          "q1" => %{"option" => "1", "wording" => wording, "note" => "Ask design."}
        })

        assert has_element?(
                 view,
                 "##{field}-error",
                 "Write the new wording of AC-2, or pick another option."
               )

        assert has_element?(view, "##{field}[aria-invalid=true][aria-describedby=#{field}-error]")
        refute has_element?(view, "#spend-dialog")
        assert answer_of(work_item, "q1") == nil

        # Focus moves to the wording field.
        focus = view |> element("#work-item-tab-questions-open-focus-1-1[hidden]") |> render()
        assert focus =~ "##{field}"
      end
    end

    test "a wording with an invisible character shows the error on its field", %{
      conn: conn,
      scope: scope
    } do
      work_item = waiting_at_verify!(scope)
      view = tab(conn, scope, work_item)

      send_answers(view, work_item, %{"q1" => %{"option" => "1", "wording" => "AC-2​ new."}})

      assert has_element?(
               view,
               "#work-item-tab-questions-open-answer-1-1-wording-error",
               "Remove the control or invisible characters."
             )

      refute has_element?(view, "#spend-dialog")
    end

    test "an edit of the wording with no option picked picks Change AC-2", %{
      conn: conn,
      scope: scope
    } do
      work_item = waiting_at_verify!(scope)
      view = tab(conn, scope, work_item)
      refute has_element?(view, "#work-item-tab-questions-open-answer-1-1[checked]")

      view
      |> element("#work-item-tab-questions-open-form")
      |> render_change(%{
        "_target" => ["answers", "q1", "wording"],
        "number" => "#{work_item.number}",
        "answers" => %{"q1" => %{"wording" => "AC-2 Tests: new."}}
      })

      assert has_element?(view, "#work-item-tab-questions-open-answer-1-1[checked]")

      # An edit of the note picks nothing.
      other = waiting_at_verify!(scope)
      view = tab(conn, scope, other)

      view
      |> element("#work-item-tab-questions-open-form")
      |> render_change(%{
        "_target" => ["answers", "q1", "note"],
        "number" => "#{other.number}",
        "answers" => %{"q1" => %{"note" => "A note."}}
      })

      refute has_element?(view, "#work-item-tab-questions-open-answer-1-1[checked]")
    end

    test "the edited wording is one draft with the Questions tab", %{conn: conn, scope: scope} do
      work_item = waiting_at_verify!(scope)
      view = tab(conn, scope, work_item)
      edited = "AC-2 Demo: the voucher line shows as an icon."

      view
      |> element("#work-item-tab-questions-open-form")
      |> render_change(%{
        "number" => "#{work_item.number}",
        "answers" => %{"q1" => %{"option" => "1", "wording" => edited}}
      })

      render_patch(
        view,
        ~p"/#{scope.organisation}/#{scope.workspace}/work/#{work_item.number}/questions"
      )

      assert has_element?(view, "#work-item-questions-open-answer-1-1[checked]")
      assert has_element?(view, "#work-item-questions-open-answer-1-1-wording", edited)
    end

    test "the matrix row of a criterion with an open question links to it, under the outputs", %{
      conn: conn,
      scope: scope
    } do
      work_item = waiting_at_verify!(scope)
      view = tab(conn, scope, work_item)

      # Verify's outputs, then the frame Open questions, then the runs fold.
      html = render(view)
      at = &(:binary.match(html, ~s|id="#{&1}"|) |> elem(0))
      assert at.("work-item-tab-output-verification") < at.("work-item-tab-questions-open")
      assert at.("work-item-tab-questions-open") < at.("work-item-record")

      matrix = "#work-item-tab-output-verification-parts-matrix"

      assert texts(view, "#{matrix}-1 td:nth-child(2)") == ["Not met Answer question 1."]

      # The link leads to question 1 in the Open questions frame of Verify's tab, the tab
      # of the stage the questions wait at.
      path =
        ~p"/#{scope.organisation}/#{scope.workspace}/work/#{work_item.number}/stages/#{@verify}"

      assert has_element?(
               view,
               ~s|#{matrix}-1-answer[href="#{path}#work-item-tab-questions-question-1"]|,
               "Answer question 1."
             )

      assert has_element?(view, "#work-item-tab-questions-question-1")

      # AC-1 has no open question: its row has no link.
      refute has_element?(view, "#{matrix}-0 a")
    end

    test "a question about AC-2 shows AC-2's text from the newest criteria as a quote", %{
      conn: conn,
      scope: scope
    } do
      work_item = waiting_at_verify!(scope)

      for {view, prefix} <- [
            {tab(conn, scope, work_item), "work-item-tab-questions"},
            {questions_page(conn, scope, work_item), "work-item-questions"}
          ] do
        about = "##{prefix}-question-1-about"

        assert texts(view, about) == ["About acceptance criteria, AC-2"]

        # Verify made the criteria, and its tab shows its outputs other than the
        # verification as rows, with no table: the words link to the criteria's page.
        [criteria] = for a <- Artifacts.list(work_item), a.type == "acceptance-criteria", do: a
        [version] = criteria.versions

        path =
          ~p"/#{scope.organisation}/#{scope.workspace}/work/#{work_item.number}/artifacts/#{version.public_id}"

        assert has_element?(view, ~s|#{about} a[href="#{path}"]|, "acceptance criteria")

        assert texts(view, "#{about}-quote blockquote") == [@ac2]
      end
    end
  end

  describe "the scenarios" do
    test "one frame, in scenario order, each film with its steps and each picture with its step",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 10, :film)
          scenario!(run, work_item, 2, :pictures)
          scenario!(run, work_item, 1, :film)
        end)

      view = tab(conn, scope, work_item)

      assert has_element?(view, "#work-item-tab-output-demo-video-h", "Scenarios")
      assert has_element?(view, "#work-item-tab-output-demo-video-s", "Version 1 · 3 scenarios")
      refute has_element?(view, "#work-item-tab-output-screenshot")

      assert texts(view, "#work-item-tab-scenarios h3") == [
               "Scenario 1: Title of scenario-1",
               "Scenario 2: Title of scenario-2",
               "Scenario 10: Title of scenario-10"
             ]

      film = "#work-item-tab-scenarios-scenario-1"
      assert has_element?(view, "#{film} video source[type=\"video/mp4\"]")

      assert has_element?(
               view,
               "#{film} video track[kind=\"captions\"][label=\"scenario-1.vtt\"]"
             )

      assert has_element?(view, "#{film} figcaption", "scenario-1.mp4")

      # The captions start off: no track is the default one.
      refute has_element?(view, "#{film} video track[default]")
      refute has_element?(view, "#work-item-tab-scenarios video track[default]")

      assert texts(view, "#{film}-steps li") == [
               "Step 1: Open scenario-1 Expected: Result 1 of Open scenario-1.",
               "Step 2: Reload scenario-1 Expected: Result 2 of Reload scenario-1."
             ]

      assert has_element?(view, "#{film}-row", "demo video scenario-1 v1")

      pictures = "#work-item-tab-scenarios-scenario-2"

      assert has_element?(
               view,
               pictures,
               "Pictures, one for each step, 390 px wide."
             )

      assert texts(view, "#{pictures}-pictures figcaption") == [
               "Step 1: Open scenario-2 Expected: Result 1 of Open scenario-2.",
               "Step 2: Reload scenario-2 Expected: Result 2 of Reload scenario-2."
             ]

      assert [first, second] =
               view
               |> render()
               |> LazyHTML.from_document()
               |> LazyHTML.query("#{pictures}-pictures img")
               |> Enum.map(&(&1 |> LazyHTML.attribute("src") |> hd()))

      assert first =~ "scenario-2-step-1.png"
      assert second =~ "scenario-2-step-2.png"
      assert has_element?(view, "#{pictures}-row", "screenshot scenario-2 v1")

      # The demo evidence has one row per name, in name order.
      assert texts(view, "#work-item-tab-output-demo-evidence-row li > div") == [
               "demo evidence scenario-1 v1",
               "demo evidence scenario-2 v1",
               "demo evidence scenario-10 v1"
             ]
    end

    test "a Watch button under each film and under each set of pictures opens its page",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film)
          scenario!(run, work_item, 2, :pictures)
        end)

      view = tab(conn, scope, work_item)

      [film, pictures] =
        VerifyTab.queue(work_item, Artifacts.list(work_item), @verify, work_item.take_in)

      path = &ArtifactComponents.version_path(scope, work_item.number, &1.version.public_id)

      # A film: under the player, above its file name; its link carries the time and speed.
      watch = "#work-item-tab-scenarios-scenario-1-watch"

      assert has_element?(view, ~s(figure video + div #{watch}[href="#{path.(film)}"]), "Watch")
      assert has_element?(view, "#{watch}[phx-hook=WatchHandoff]")
      assert has_element?(view, ~s(#{watch}[data-version="#{film.version.public_id}"]))
      assert has_element?(view, ~s(#{watch}[data-film="0"]))
      assert has_element?(view, "#{watch} .hero-play-micro")
      assert has_element?(view, "figure > video + div + figcaption", "scenario-1.mp4")

      assert has_element?(
               view,
               ~s(#{watch}[title="Watch this scenario on its page, with the other scenarios beside it"])
             )

      # Pictures: under the row of pictures, above the artifact row; no film to read.
      watch = "#work-item-tab-scenarios-scenario-2-watch"
      assert has_element?(view, ~s(#{watch}[href="#{path.(pictures)}"]), "Watch")
      refute has_element?(view, "#{watch}[phx-hook]")
      assert has_element?(view, "#work-item-tab-scenarios-scenario-2-pictures + div #{watch}")

      assert has_element?(
               view,
               "#work-item-tab-scenarios-scenario-2-pictures + div + #work-item-tab-scenarios-scenario-2-row"
             )

      # The film has no Speed row on the tab.
      refute has_element?(view, "#work-item-tab-scenarios [phx-hook=VideoSpeed]")
    end

    test "only the scenarios of the verified commit", %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film)
          scenario!(run, work_item, 2, :film, @older)
        end)

      view = tab(conn, scope, work_item)

      assert texts(view, "#work-item-tab-scenarios h3") == ["Scenario 1: Title of scenario-1"]
    end

    test "a withdrawn scenario is not on the tab and not in the approval",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film)
          scenario!(run, work_item, 2, :film)

          for type <- ["demo-video", "demo-evidence"] do
            {:ok, _withdrawal} =
              Artifacts.withdraw({:run, run}, work_item, type,
                name: "scenario-2",
                stage_id: run.stage_id
              )
          end
        end)

      view = tab(conn, scope, work_item)

      assert texts(view, "#work-item-tab-scenarios h3") == ["Scenario 1: Title of scenario-1"]
      refute has_element?(view, "#work-item-stage-gate-output-demo-video--scenario-2--")
      assert has_element?(view, "#work-item-stage-gate-output-demo-video--scenario-1--")

      view |> form("#work-item-stage-gate-approve") |> render_submit()

      approvals =
        for %{type: "demo-video", name: name, versions: versions} <-
              Stages.artifact_index(work_item),
            into: %{},
            do: {name, Enum.flat_map(versions, & &1.approvals)}

      assert [_approval] = approvals["scenario-1"]
      assert approvals["scenario-2"] == []
    end

    test "a stage with no demo evidence: each film with its demo script's steps",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          push!(run, work_item, "demo-video", "scenario-3", [{"scenario-3.mp4", @mp4}])

          script = %{
            "scenario" => "scenario-3",
            "title" => "Title of scenario-3",
            "steps" => steps(["Open the cart"])
          }

          push!(run, work_item, "demo-script", "scenario-3", [
            {"scenario-3.json", Jason.encode!(script)}
          ])
        end)

      view = tab(conn, scope, work_item)

      assert texts(view, "#work-item-tab-scenarios h3") == ["Scenario 3: Title of scenario-3"]

      assert texts(view, "#work-item-tab-scenarios-demo-video-scenario-3-steps li") == [
               "Step 1: Open the cart Expected: Result 1 of Open the cart."
             ]
    end

    test "with no scenario of the verified commit, no Scenarios frame", %{
      conn: conn,
      scope: scope
    } do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film, @older)
        end)

      view = tab(conn, scope, work_item)

      assert has_element?(view, "#work-item-tab-output-verification")
      refute has_element?(view, "#work-item-tab-output-demo-video")
    end
  end

  describe "queue/4" do
    test "is the scenarios the tab shows: in scenario order, of the verified commit",
         %{scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 10, :film)
          scenario!(run, work_item, 2, :pictures)
          scenario!(run, work_item, 1, :film)
          scenario!(run, work_item, 3, :film, @older)
        end)

      queue = VerifyTab.queue(work_item, Artifacts.list(work_item), @verify, work_item.take_in)

      assert Enum.map(queue, &{&1.key, &1.kind, &1.number}) == [
               {"scenario-1", :film, 1},
               {"scenario-2", :pictures, 2},
               {"scenario-10", :film, 10}
             ]

      assert Enum.map(queue, & &1.version.artifact_id) ==
               Enum.map(queue, & &1.artifact.id)
    end

    test "queue/5 returns what it read, and a call with it uses it instead of reading again",
         %{scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film)
        end)

      artifacts = Artifacts.list(work_item)

      {[%{key: "scenario-1", title: "Title of scenario-1"}], reads} =
        VerifyTab.queue(work_item, artifacts, @verify, work_item.take_in, %{})

      [evidence] =
        for %{type: "demo-evidence"} = artifact <- artifacts, do: hd(artifact.versions)

      [verification] =
        for %{type: "verification"} = artifact <- artifacts, do: hd(artifact.versions)

      assert reads |> Map.keys() |> Enum.sort() ==
               Enum.sort([{:json, evidence.public_id}, {:json, verification.public_id}])

      # A value in `reads` that the store does not hold is what the call shows, so it read
      # nothing for that version.
      kept = Map.update!(reads, {:json, evidence.public_id}, &Map.put(&1, "title", "Kept"))

      assert {[%{key: "scenario-1", title: "Kept"}], ^kept} =
               VerifyTab.queue(work_item, artifacts, @verify, work_item.take_in, kept)
    end

    test "is empty for another stage and for another take in", %{scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film)
        end)

      artifacts = Artifacts.list(work_item)

      assert VerifyTab.queue(work_item, artifacts, @shape, work_item.take_in) == []
      assert VerifyTab.queue(work_item, artifacts, @verify, work_item.take_in + 1) == []
    end
  end

  describe "the findings accepted at an earlier stage's round limit" do
    @build "st_6ns22c4pav"

    @findings ["The total skips the voucher.", "The receipt shows no voucher line."]

    # A work item whose Build reached its round limit with the open findings `findings`,
    # 2 by default, which a member accepted as they are: Verify's run is queued, and has
    # pushed nothing.
    defp accepted_at_build!(scope, findings \\ @findings) do
      [explore | _rest] = Processes.default_document("software")["stages"]
      gate = %{"kind" => "person", "approvers" => "members"}
      review = %{"loop" => %{"rounds" => 1, "body" => [%{"workflow" => "review-changes"}]}}

      {:ok, _version} =
        Processes.save(scope, scope.workspace, %{
          "schema" => "qory.process/v1",
          "stages" => [
            explore,
            %{
              "id" => @build,
              "name" => "Build",
              "sequence" => [review],
              "outputs" => [],
              "gate" => %{"kind" => "none"}
            },
            %{
              "id" => @verify,
              "name" => "Verify",
              "sequence" => [%{"workflow" => "verify-a-ticket"}],
              "outputs" => [
                %{"type" => "verification", "required" => false},
                %{"type" => "explainer", "required" => false}
              ],
              "gate" => gate
            }
          ]
        })

      points = for text <- findings, do: %{"text" => text, "action" => "run_again"}
      verdict = %{"verdict" => "changes-requested"}
      verdict = if points == [], do: verdict, else: Map.put(verdict, "points", points)

      {:ok, work_item} = WorkItems.take_in(scope, backlog_ticket_fixture(scope).public_id)
      work_item = Repo.get!(WorkItem, work_item.id) |> end_run!(understood_result())
      {:ok, _work_item} = WorkItems.confirm(scope, work_item, 1)

      work_item =
        WorkItem
        |> Repo.get!(work_item.id)
        |> end_run!(fn run, _registered ->
          {:ok, _version} =
            Stages.Artifacts.push_json(
              {:run, run},
              Repo.get!(WorkItem, run.work_item_id),
              "verdict",
              verdict,
              stage_id: run.stage_id
            )
        end)

      assert %WorkItem{stage_id: @build, stage_state: :escalated} = work_item

      {:ok, _work_item} =
        Stages.resolve_escalation(scope, work_item, :accept, nil, expect_stage: @build)

      Repo.get!(WorkItem, work_item.id)
    end

    # Verify's run ends with what `push` pushes, and passes.
    defp verify_passes!(work_item, push) do
      end_run!(work_item, fn run, _registered ->
        push.(run, Repo.get!(WorkItem, run.work_item_id))

        {:ok, _version} =
          Stages.Artifacts.push_json(
            {:run, run},
            Repo.get!(WorkItem, run.work_item_id),
            "verdict",
            %{"verdict" => "passed"},
            stage_id: run.stage_id
          )
      end)
    end

    defp accepted_line(scope),
      do:
        ~r/\AAccepted as it is in Build by #{Regex.escape(ApiaryWeb.People.short(scope.user.email))}, .+\.\z/

    test "while Verify's run has pushed no verification, the accepted findings are a frame, open",
         %{conn: conn, scope: scope} do
      work_item = accepted_at_build!(scope)
      assert %WorkItem{stage_id: @verify, stage_state: :running} = work_item

      view = tab(conn, scope, work_item)
      frame = "#work-item-tab-accepted-findings"

      assert has_element?(view, "#{frame}-fold[open]")
      assert texts(view, "#{frame}-h") == ["Accepted findings"]
      assert has_element?(view, "#{frame}-by.q-xp-cap .hero-information-circle-micro")
      assert [by] = texts(view, "#{frame}-by")
      assert by =~ accepted_line(scope)
      assert texts(view, "#{frame}-list li") == @findings
      assert texts(view, "#{frame}-0") == [hd(@findings)]
      refute has_element?(view, "#work-item-tab-output-verification")

      # With no output frame, it follows the run line and the running block, and comes
      # before the record of runs.
      html = render(view)
      at = &(:binary.match(html, ~s|id="#{&1}"|) |> elem(0))
      assert at.("work-item-tab-run") < at.("work-item-tab-accepted-findings")
      assert at.("work-item-tab-wait") < at.("work-item-tab-accepted-findings")
    end

    test "where the workspace hides verification, the frame follows the last output frame",
         %{conn: conn, scope: scope} do
      work_item = accepted_at_build!(scope)

      # The workspace hides the standard type, as one made from a template that does not
      # list it: Verify's run cannot push a verification.
      {1, _rows} =
        Repo.update_all(
          from(w in Apiary.Organisations.Workspace, where: w.id == ^scope.workspace.id),
          set: [shown_standard_types: Apiary.Artifacts.Type.standard_names() -- ["verification"]]
        )

      work_item =
        work_item
        |> verify_passes!(fn run, work_item ->
          push!(run, work_item, "explainer", "main", [{"explainer.md", "# What changed"}])
        end)

      assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = work_item

      view = tab(conn, scope, work_item)
      html = render(view)
      at = &(:binary.match(html, ~s|id="#{&1}"|) |> elem(0))

      assert texts(view, "#work-item-tab-accepted-findings-list li") == @findings
      assert at.("work-item-tab-output-explainer") < at.("work-item-tab-accepted-findings")
      assert at.("work-item-tab-accepted-findings") < at.("work-item-record")
    end

    test "an accept with no findings shows no frame, heading or line", %{
      conn: conn,
      scope: scope
    } do
      work_item = accepted_at_build!(scope, [])
      assert %WorkItem{stage_id: @verify, stage_state: :running} = work_item

      view = tab(conn, scope, work_item)
      refute has_element?(view, "#work-item-tab-accepted-findings")
      refute render(view) =~ "Accepted as it is in"

      work_item = verify_passes!(work_item, &verification!/2)
      view = tab(conn, scope, work_item)
      assert has_element?(view, "#work-item-tab-output-verification-parts-not-verified")
      refute has_element?(view, "#work-item-tab-output-verification-parts-accepted-findings")
      refute render(view) =~ "Accepted as it is in"
    end

    test "with no accepted findings, Verify's tab has no frame for them", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_verify_gate!(scope, fn _run, _work_item -> :ok end)
      view = tab(conn, scope, work_item)

      refute has_element?(view, "#work-item-tab-output-verification")
      refute has_element?(view, "#work-item-tab-accepted-findings")
    end

    test "after a member accepts at Build's round limit with 2 open findings, Verify lists them",
         %{conn: conn, scope: scope} do
      findings = @findings
      work_item = scope |> accepted_at_build!() |> verify_passes!(&verification!/2)
      assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = work_item

      view = tab(conn, scope, work_item)
      section = "#work-item-tab-output-verification-parts-accepted-findings"

      assert texts(view, "#{section}-h") == ["Accepted findings"]

      assert [by] = texts(view, "#{section}-0-by")
      assert by =~ accepted_line(scope)

      # The verification frame shows them, so the separate frame is absent.
      refute has_element?(view, "#work-item-tab-accepted-findings")

      assert texts(view, "#{section}-0 li") == findings

      # The section follows Not verified.
      html = render(view)
      at = &(:binary.match(html, ~s|id="#{&1}"|) |> elem(0))

      assert at.("work-item-tab-output-verification-parts-not-verified") <
               at.(String.trim_leading(section, "#"))

      refute has_element?(view, "#{section}-1-by")
    end

    test "two accepts in one take in each have their line and list, in the order of the accepts",
         %{conn: conn, scope: scope} do
      later = ["The voucher field takes a used code.", "The total rounds the voucher down."]
      work_item = accepted_at_build!(scope)
      first = Repo.one!(from e in Escalation, where: e.work_item_id == ^work_item.id)
      verify = newest_run(work_item)

      # A second Build run asks for other changes and a member accepts them too; Verify's
      # run comes after it.
      run =
        %DispatchRun{organisation_id: verify.organisation_id, workspace_id: verify.workspace_id}
        |> DispatchRun.queue_changeset(%{
          work_item_id: work_item.id,
          step: Repo.get!(DispatchRun, first.run_id).step,
          take_in: verify.take_in,
          attempt: verify.attempt + 1,
          of: verify.attempt + 1,
          queued_at: DateTime.utc_now()
        })
        |> Ecto.Changeset.put_change(:stage_id, @build)
        |> Repo.insert!()

      points = for text <- later, do: %{"text" => text, "action" => "run_again"}

      {:ok, _version} =
        Stages.Artifacts.push_json(
          {:run, run},
          work_item,
          "verdict",
          %{"verdict" => "changes-requested", "points" => points},
          stage_id: @build
        )

      now = DateTime.utc_now()

      Repo.insert!(%Escalation{
        organisation_id: first.organisation_id,
        workspace_id: first.workspace_id,
        work_item_id: first.work_item_id,
        process_version_id: first.process_version_id,
        run_id: run.id,
        stage_id: @build,
        round: 1,
        cause: :round_limit,
        points: [],
        resolution: :accept,
        resolved_by_id: scope.user.id,
        resolved_at: now,
        inserted_at: now
      })

      {1, _rows} =
        Repo.update_all(from(r in DispatchRun, where: r.id == ^verify.id),
          set: [attempt: verify.attempt + 2, of: verify.attempt + 2]
        )

      # While Verify's run has pushed no verification: the separate frame.
      view = tab(conn, scope, work_item)
      frame = "work-item-tab-accepted-findings"

      assert [by] = texts(view, "##{frame}-by")
      assert by =~ accepted_line(scope)
      assert [by] = texts(view, "##{frame}-1-by")
      assert by =~ accepted_line(scope)
      assert texts(view, "##{frame}-list li") == @findings
      assert texts(view, "##{frame}-1-list li") == later

      html = render(view)
      at = &(:binary.match(html, ~s|id="#{&1}"|) |> elem(0))
      ids = for id <- ["by", "list", "1-by", "1-list"], do: "#{frame}-#{id}"
      assert Enum.map(ids, at) == Enum.sort(Enum.map(ids, at))

      # After the verification: the section in the verification frame.
      work_item = verify_passes!(work_item, &verification!/2)
      assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = work_item

      view = tab(conn, scope, work_item)
      section = "work-item-tab-output-verification-parts-accepted-findings"
      refute has_element?(view, "##{frame}")

      for k <- [0, 1] do
        assert [by] = texts(view, "##{section}-#{k}-by")
        assert by =~ accepted_line(scope)
      end

      assert texts(view, "##{section}-0 li") == @findings
      assert texts(view, "##{section}-1 li") == later

      html = render(view)
      at = &(:binary.match(html, ~s|id="#{&1}"|) |> elem(0))
      ids = for id <- ["0-by", "0", "1-by", "1"], do: "#{section}-#{id}"
      assert Enum.map(ids, at) == Enum.sort(Enum.map(ids, at))
    end
  end

  describe "a version a cancelled run wrote" do
    test "after an approval, it shows no newer version", %{conn: conn, scope: scope} do
      work_item = at_verify_gate!(scope, &verification!/2)
      newest = newest_run(work_item)

      run =
        %DispatchRun{
          organisation_id: work_item.organisation_id,
          workspace_id: work_item.workspace_id
        }
        |> DispatchRun.queue_changeset(%{
          work_item_id: work_item.id,
          step: newest.step,
          take_in: newest.take_in,
          attempt: newest.attempt + 1,
          of: max(newest.of, newest.attempt + 1),
          queued_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      {:ok, %{number: 2}} =
        Stages.Artifacts.push(
          {:run, run},
          work_item,
          "proposal",
          [
            %{
              filename: "proposal.md",
              content_type: "text/markdown",
              binary: understood_result()["message"]
            }
          ],
          stage_id: @explore
        )

      view = item_page(conn, scope, work_item)
      assert has_element?(view, "#work-item-marks-proposal-main-m", "Approved v1; v2 is newer")

      Apiary.RunEventsFixtures.run_fixture(scope, %{
        dispatch_run_id: run.id,
        cancel_requested_at: DateTime.utc_now()
      })

      view = item_page(conn, scope, work_item)
      assert has_element?(view, "#work-item-artifact-list", "proposal v1")
      refute has_element?(view, "#work-item-marks-proposal-main-m")
      refute has_element?(view, "#work-item-marks", "Changed after approval")
    end
  end

  describe "verification/1 and criteria/1" do
    test "read the JSON documents; a value of another shape is nil" do
      assert VerifyTab.verification(@verification) == %{
               commit: @commit,
               rows: [
                 %{
                   criterion: "ac-1",
                   state: :met,
                   evidence: "Film: demo-video scenario-1 v1, step 2 passed."
                 },
                 %{
                   criterion: "ac-3",
                   state: :not_met,
                   evidence: "Locked check `tests/voucher.test.ts` failed: 2 of 3 tests passed."
                 }
               ],
               not_verified: [%{criterion: "ac-2", reason: @check}],
               families: ["claude", "deepseek"]
             }

      assert %{summary: "The checkout takes a voucher.", criteria: [first | _rest]} =
               VerifyTab.criteria(@criteria)

      assert first == %{
               id: "ac-1",
               text: @ac1,
               check: "Demo: Reload the payment step",
               removed: nil
             }

      for value <- ["## Matrix\n\n| Criterion | State |", nil, %{"matrix" => "x"}, []] do
        assert VerifyTab.verification(value) == nil, inspect(value)
        assert VerifyTab.criteria(value) == nil, inspect(value)
      end
    end
  end

  describe "the tab's frames" do
    test "every frame is open; the demo evidence and the explainer have their row only",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film)
          explainer!(run, work_item)
        end)

      view = tab(conn, scope, work_item)

      for type <- ["verification", "demo-video", "demo-evidence", "explainer"] do
        assert has_element?(view, "#work-item-tab-output-#{type}-fold[open]")
      end

      explainer = "#work-item-tab-output-explainer"
      assert has_element?(view, "#{explainer}-s", "Version 1")
      assert has_element?(view, "#{explainer}-row", "explainer v1")
      refute has_element?(view, explainer, "Words of the explainer.")
      refute has_element?(view, "#{explainer}-text")
      assert has_element?(view, "#work-item-tab-output-demo-evidence-s", "Version 1")
    end

    test "the rows and the tab's Artifacts list show the plain label",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film)
        end)

      view = tab(conn, scope, work_item)

      assert has_element?(
               view,
               "#work-item-tab-scenarios-scenario-1-row",
               "demo video scenario-1 v1"
             )

      assert has_element?(
               view,
               "#work-item-tab-output-demo-evidence-row",
               "demo evidence scenario-1 v1"
             )

      # The tab's Artifacts list has the same words; the page's other lists and the
      # artifact page keep the type's id.
      assert has_element?(view, "#work-item-artifact-list", "demo video scenario-1 v1")
      refute has_element?(view, "#work-item-artifact-list", "demo-video scenario-1 v1")

      explore = item_page(conn, scope, work_item)
      refute has_element?(explore, "#work-item-artifact-list", "demo video scenario-1 v1")
    end

    test "a scenario has no bottom padding, as the signed-off picture draws it",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film)
          scenario!(run, work_item, 2, :pictures)
        end)

      view = tab(conn, scope, work_item)

      for id <- ["scenario-1", "scenario-2"] do
        [class] =
          view
          |> render()
          |> LazyHTML.from_document()
          |> LazyHTML.query("#work-item-tab-scenarios-#{id}")
          |> LazyHTML.attribute("class")

        assert class =~ "border-b"
        refute class =~ "pb-"
      end
    end

    test "the gate card lists the films and pictures together, in scenario order",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 10, :film)
          scenario!(run, work_item, 2, :pictures)
          scenario!(run, work_item, 1, :film)
          explainer!(run, work_item)
        end)

      view = tab(conn, scope, work_item)

      assert ids(view, "#work-item-stage-gate-outputs li") ==
               Enum.map(
                 ~w(verification demo-video--scenario-1-- screenshot--scenario-2--
                    demo-video--scenario-10-- demo-evidence--scenario-1--
                    demo-evidence--scenario-2-- demo-evidence--scenario-10-- explainer),
                 &"work-item-stage-gate-output-#{&1}"
               )

      assert has_element?(
               view,
               "#work-item-stage-gate-output-screenshot--scenario-2--",
               "screenshot scenario-2 v1"
             )
    end
  end

  describe "the matrix's evidence" do
    test "links each scenario of the Scenarios frame; other text stays text, escaped",
         %{conn: conn, scope: scope} do
      check =
        "Check that the voucher line fits in the pictures of scenario 2, because the run could not measure the line."

      text =
        matrix([
          {"ac-1", "met", "Demo video: scenario 1"},
          {"ac-2", "not_met", check},
          {"ac-3", "met", "Pictures: scenario 7"},
          {"ac-4", "met", "<script>alert(1)</script> <img src=x onerror=alert(2)>"}
        ])

      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item, text)
          scenario!(run, work_item, 1, :film)
          scenario!(run, work_item, 2, :pictures)
        end)

      view = tab(conn, scope, work_item)
      matrix = "#work-item-tab-output-verification-parts-matrix"

      for cell <- ["td.q-from-sm", "td:first-child div"] do
        assert has_element?(
                 view,
                 ~s|#{matrix}-0 #{cell} a[href="#work-item-tab-scenarios-scenario-1"]|,
                 "Demo video: scenario 1"
               )

        assert has_element?(
                 view,
                 ~s|#{matrix}-1 #{cell} a[href="#work-item-tab-scenarios-scenario-2"]|,
                 "the pictures of scenario 2"
               )
      end

      assert texts(view, "#{matrix}-1 td.q-from-sm") == [check]
      assert has_element?(view, "#work-item-tab-scenarios-scenario-1")
      assert has_element?(view, "#work-item-tab-scenarios-scenario-2")

      assert has_element?(view, "#{matrix}-2 td.q-from-sm", "Pictures: scenario 7")
      refute has_element?(view, "#{matrix}-2 a")

      assert has_element?(view, "#{matrix}-3 td.q-from-sm", "<script>alert(1)</script>")
      refute has_element?(view, "#{matrix} script")
      refute has_element?(view, "#{matrix} img")
    end

    test "evidence_parts/2 links the three phrases whole, and no other text" do
      anchors = %{1 => "a-1", 2 => "a-2"}

      assert VerifyTab.evidence_parts("Demo video: scenario 1", anchors) ==
               [{:link, "Demo video: scenario 1", "a-1"}]

      assert VerifyTab.evidence_parts("Pictures: scenario 2", anchors) ==
               [{:link, "Pictures: scenario 2", "a-2"}]

      assert VerifyTab.evidence_parts(
               "Check that the voucher line fits in the pictures of scenario 2, because the run could not.",
               anchors
             ) ==
               [
                 "Check that the voucher line fits in ",
                 {:link, "the pictures of scenario 2", "a-2"},
                 ", because the run could not."
               ]

      # Another number, another wording and a scenario not listed stay text.
      for text <- [
            "Film: demo-video scenario-1 v1, scenario-12 too.",
            "scenario 2 passed",
            "Demo video: scenario 7",
            "Pictures: scenario 12"
          ] do
        assert VerifyTab.evidence_parts(text, anchors) == [text]
      end

      assert VerifyTab.evidence_parts("Pictures: scenario 2", %{}) == ["Pictures: scenario 2"]
    end

    test "evidence_parts/2 matches the phrases case-sensitively and reads the number as an integer" do
      anchors = %{1 => "a-1", 2 => "a-2"}

      for text <- [
            "demo video: scenario 1",
            "The pictures of scenario 2",
            "pictures: scenario 2"
          ] do
        assert VerifyTab.evidence_parts(text, anchors) == [text]
      end

      assert VerifyTab.evidence_parts("Pictures: scenario 02", anchors) ==
               [{:link, "Pictures: scenario 02", "a-2"}]
    end
  end

  describe "the scenarios read" do
    test "a cancelled run's verification does not change the verified commit",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film)
        end)

      run = verify_run!(work_item, work_item.take_in)
      verification!(run, work_item, %{@verification | "target_version" => @older})
      cancel!(scope, run)

      view = tab(conn, scope, work_item)

      assert texts(view, "#work-item-tab-scenarios h3") == ["Scenario 1: Title of scenario-1"]
    end

    test "a scenario's row shows the film its evidence names, not a newer one",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film)
          push!(run, work_item, "demo-video", "scenario-1", [{"scenario-1.mp4", @mp4 <> "2"}])
        end)

      view = tab(conn, scope, work_item)

      assert has_element?(
               view,
               "#work-item-tab-scenarios-scenario-1-row",
               "demo video scenario-1 v1"
             )

      refute has_element?(view, "#work-item-tab-scenarios-scenario-1-row", "v2")
    end

    test "two scenarios with one film have one element each", %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          film = scenario!(run, work_item, 1, :film)

          evidence = %{
            "scenario" => "scenario-3",
            "title" => "Title of scenario-3",
            "commit" => @commit,
            "media" => %{"type" => "demo-video", "name" => "scenario-1", "version" => film.number},
            "steps" => steps(["Open the cart"])
          }

          push!(run, work_item, "demo-evidence", "scenario-3", [
            {"scenario-3.json", Jason.encode!(evidence)}
          ])
        end)

      view = tab(conn, scope, work_item)

      assert ids(view, "#work-item-tab-scenarios > div") == [
               "work-item-tab-scenarios-scenario-1",
               "work-item-tab-scenarios-scenario-3"
             ]
    end

    test "an earlier take in's names and films stay off the tab", %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film)
          scenario!(run, work_item, 2, :film)
        end)

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [take_in: work_item.take_in + 1]
        )

      work_item = Repo.get!(WorkItem, work_item.id)
      run = verify_run!(work_item, work_item.take_in)
      verification!(run, work_item)
      scenario!(run, work_item, 1, :film)

      view = tab(conn, scope, work_item)

      assert texts(view, "#work-item-tab-scenarios h3") == ["Scenario 1: Title of scenario-1"]
      refute has_element?(view, "#work-item-tab-scenarios-scenario-2")

      assert texts(view, "#work-item-tab-output-demo-evidence-row li > div") == [
               "demo evidence scenario-1 v2"
             ]
    end

    test "each JSON document and the accepting member are read once",
         %{conn: conn, scope: scope} do
      work_item =
        at_verify_gate!(scope, fn run, work_item ->
          verification!(run, work_item)
          scenario!(run, work_item, 1, :film)
        end)

      view = tab(conn, scope, work_item)
      assigns = :sys.get_state(view.pid).socket.assigns

      [evidence] =
        for %{type: "demo-evidence"} = artifact <- assigns.artifacts,
            do: hd(artifact.versions)

      assert %{"title" => "Title of scenario-1"} =
               assigns.stored_reads[{:json, evidence.public_id}]

      [accepted] = for {:accepted, _, _, _} = key <- Map.keys(assigns.stored_reads), do: key

      # What the page keeps is what it shows again, when the frames are read again.
      :sys.replace_state(view.pid, fn state ->
        update_in(state.socket.assigns, fn assigns ->
          %{
            assigns
            | frame_texts: %{},
              stored_reads:
                assigns.stored_reads
                |> Map.update!({:json, evidence.public_id}, &Map.put(&1, "title", "Kept"))
                |> Map.put(accepted, "kept-member")
          }
        end)
      end)

      send(view.pid, {:artifact_pushed, work_item.id, evidence.public_id})

      assert texts(view, "#work-item-tab-scenarios h3") == ["Scenario 1: Kept"]

      assert has_element?(
               view,
               "#work-item-tab-output-verification-parts-accepted",
               "Accepted as it is by kept-member"
             )
    end
  end

  test "the questions have a row frame, in the order of the stage's outputs",
       %{conn: conn, scope: scope} do
    save_process!(scope, ~w(verification questions explainer))

    work_item =
      at_verify_gate!(scope, fn run, work_item ->
        verification!(run, work_item)
        explainer!(run, work_item)

        push!(run, work_item, "questions", "main", [
          {"questions.json", Jason.encode!(%{"questions" => []})}
        ])
      end)

    assert Enum.any?(Artifacts.list(work_item), &(&1.type == "questions"))
    view = tab(conn, scope, work_item)

    assert ids(view, "section.q-xp-frame") == [
             "work-item-tab-output-verification",
             "work-item-tab-output-questions",
             "work-item-tab-output-explainer"
           ]
  end
end
