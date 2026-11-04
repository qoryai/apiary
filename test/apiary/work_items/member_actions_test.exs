defmodule Apiary.WorkItems.MemberActionsTest do
  # What a member gives Explore (`Apiary.WorkItems.answer/4`, `confirm/3` and
  # `explore_again/3`): each where Explore waits for it, with what it writes (the answers
  # in a new version of the questions, `Apiary.Explore.Questions`), its event, its next
  # run where it queues one, its entry in the trail, and each refusal; and the stage a
  # close records. Review comments on a proposal: `Apiary.WorkItems.ReviewCommentsTest`.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Repo, WorkItems}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{DispatchRun, Inputs}
  alias Apiary.Explore.Questions
  alias Apiary.WorkItems.{Confirmation, WorkItem, WorkItemEvent}

  @moduletag needs: :factory

  @base "https://qory.dev/contracts/"

  # The explore contract's schemas from `priv/contract`, and the integration contract's
  # it refers to from the vendored fixtures. Nothing is fetched.
  defmodule Resolver do
    @moduledoc false
    @behaviour JSV.Resolver

    @base "https://qory.dev/contracts/"

    @impl JSV.Resolver
    def resolve(@base <> path, roots) do
      Enum.find_value(roots, {:error, {:not_vendored, path}}, fn root ->
        file = Path.expand(path, root)

        with true <- String.starts_with?(file, root <> "/"),
             {:ok, body} <- File.read(file),
             {:ok, schema} <- Jason.decode(body) do
          {:ok, schema}
        else
          _ -> nil
        end
      end)
    end

    def resolve(url, _roots), do: {:error, {:not_vendored, url}}
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, work_item: work_item_fixture(scope)}
  end

  defp kinds(work_item),
    do:
      Repo.all(
        from e in WorkItemEvent,
          where: e.work_item_id == ^work_item.id,
          order_by: [asc: e.at, asc: e.id],
          select: {e.kind, e.data}
      )

  defp runs(work_item),
    do:
      Repo.all(
        from r in DispatchRun,
          where: r.work_item_id == ^work_item.id,
          order_by: [r.take_in, r.attempt],
          select: {r.take_in, r.attempt, r.state}
      )

  defp entry(action, work_item),
    do: Repo.one(from e in Entry, where: e.action == ^action and e.subject_id == ^work_item.id)

  defp other_workspace_scope(scope),
    do: workspace_scope(scope.user, workspace_fixture(scope.organisation))

  # Ids that are no UUID: a work item carrying one is not found.
  @malformed ["not-a-uuid", nil, %{}, 1]

  # What stands for `work_item`: its row, its events, its runs, its entries in the trail,
  # its questions and the confirmations kept.
  defp written(work_item),
    do: {
      Repo.get!(WorkItem, work_item.id),
      kinds(work_item),
      runs(work_item),
      Repo.aggregate(from(e in Entry, where: e.subject_id == ^work_item.id), :count),
      questions(work_item),
      Repo.aggregate(Confirmation, :count)
    }

  # The questions of the newest version of the work item's questions, nil for none.
  defp questions(work_item) do
    case Questions.newest(Repo.get!(WorkItem, work_item.id)) do
      {_version, document} -> document["questions"]
      nil -> nil
    end
  end

  defp asked!(work_item, questions \\ ["Which basket?", "Which sale?"]),
    do: explore_run_fixture(work_item, result: questions_result(questions))

  defp proposed!(work_item), do: explore_run_fixture(work_item, result: understood_result())

  # The domain and the target a handover gives the input of a run of `work_item`.
  defp run(work_item),
    do: %{
      domain: "software",
      target: %{system: work_item.target_system, path: work_item.target_path}
    }

  describe "answer" do
    test "writes the answers into a new version of the questions, and queues the next run",
         ctx do
      asked!(ctx.work_item)
      answers = %{"1" => "The one on the checkout page.", "2" => " The spring sale. "}

      assert {:ok, %WorkItem{} = answered} =
               WorkItems.answer(ctx.scope, ctx.work_item, 1, answers)

      assert DateTime.compare(answered.updated_at, ctx.work_item.updated_at) == :gt
      name = Inputs.person_name(ctx.scope.user.id)

      assert [
               %{
                 "id" => "q1",
                 "state" => "answered",
                 "answer" => %{
                   "option" => nil,
                   "note" => "The one on the checkout page.",
                   "by" => %{"name" => ^name},
                   "at" => at
                 }
               },
               %{"id" => "q2", "state" => "answered", "answer" => %{"note" => "The spring sale."}}
             ] = questions(ctx.work_item)

      assert at =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/
      assert runs(ctx.work_item) == [{1, 1, :ended}, {1, 2, :waiting}]
      data = %{"take_in" => 1, "attempt" => 1, "count" => 2, "questions" => ["q1", "q2"]}
      assert [{:taken_in, _}, {:answered, ^data}] = kinds(ctx.work_item)
      assert entry("work_item.answer", ctx.work_item).details == data

      explore = WorkItems.explore(ctx.scope, answered)
      assert explore.status == :queued
      assert explore.answers_by_ids == [ctx.scope.user.id]
      assert [%{questions: questions, answered_by_id: answered_by}] = explore.earlier_runs
      assert answered_by == ctx.scope.user.id

      assert questions == [
               %{
                 public_id: "1",
                 text: "Which basket?",
                 options: [],
                 answer: "The one on the checkout page.",
                 custom: true
               },
               %{
                 public_id: "2",
                 text: "Which sale?",
                 options: [],
                 answer: "The spring sale.",
                 custom: true
               }
             ]
    end

    test "an option's title is the answer's option, the member's text its note", ctx do
      asked!(ctx.work_item, [
        %{
          "question" => "Which basket?",
          "options" => [
            %{"title" => "The small one", "explanation" => "The checkout page shows it."},
            %{"title" => "The large one", "explanation" => "The shop page shows it."}
          ]
        },
        "Which sale?"
      ])

      answers = %{"1" => %{"option" => "The large one"}, "2" => %{"custom" => "The spring one."}}
      assert {:ok, _} = WorkItems.answer(ctx.scope, ctx.work_item, 1, answers)

      assert [%{"answer" => first}, %{"answer" => second}] = questions(ctx.work_item)
      assert %{"option" => "The large one"} = first
      refute Map.has_key?(first, "note")
      assert %{"option" => nil, "note" => "The spring one."} = second

      assert [%{questions: [%{options: [_, _], custom: false}, %{options: [], custom: true}]}] =
               WorkItems.explore(ctx.scope, ctx.work_item).earlier_runs
    end

    @tag :tmp_dir
    test "a member's own answer writes option null, a version the questions schema takes",
         ctx do
      asked!(ctx.work_item, [
        %{
          "question" => "Which basket?",
          "options" => [%{"title" => "The small one", "explanation" => "The checkout."}]
        }
      ])

      # The form gives an empty option beside the member's text, as "Give your own option"
      # sends it.
      answers = %{"1" => %{"option" => "", "custom" => "Neither: the saved one."}}
      assert {:ok, _} = WorkItems.answer(ctx.scope, ctx.work_item, 1, answers)

      {version, _document} = Questions.newest(Repo.get!(WorkItem, ctx.work_item.id))
      [file] = version.files

      bytes =
        case Apiary.Artifacts.open_file(file) do
          {:ok, path} when is_binary(path) -> File.read!(path)
          {:ok, stream} -> stream |> Enum.to_list() |> IO.iodata_to_binary()
        end

      assert [%{"answer" => %{"option" => nil, "note" => "Neither: the saved one."} = answer}] =
               Jason.decode!(bytes)["questions"]

      assert Map.has_key?(answer, "option")

      # The copied schema (`priv/schemas/artifacts/questions.schema.json`) and the checks
      # after it take the version as stored.
      path = Path.join(ctx.tmp_dir, "questions.json")
      File.write!(path, bytes)
      questions_type = Enum.find(Apiary.Artifacts.Type.standard(), &(&1.name == "questions"))

      assert {:ok, _content_type} =
               Apiary.Artifacts.Format.check(questions_type, "questions.json", path)
    end

    test "an option title the question does not have is refused, nothing written", ctx do
      asked!(ctx.work_item, [
        %{
          "question" => "Which basket?",
          "options" => [%{"title" => "The small one", "explanation" => "The checkout."}]
        }
      ])

      before = questions(ctx.work_item)

      assert WorkItems.answer(ctx.scope, ctx.work_item, 1, %{"1" => %{"option" => "Another"}}) ==
               {:error, {:invalid, :form}}

      assert questions(ctx.work_item) == before
      assert runs(ctx.work_item) == [{1, 1, :ended}]
    end

    test "some of the open questions: the rest stay open, and the next run is queued", ctx do
      asked!(ctx.work_item, ["Which basket?", "Which sale?", "Which shop?"])

      assert {:ok, _} = WorkItems.answer(ctx.scope, ctx.work_item, 1, %{"2" => "The spring one."})

      assert [
               %{"id" => "q1", "state" => "open"},
               %{"id" => "q2", "state" => "answered"},
               %{"id" => "q3", "state" => "open"}
             ] = questions(ctx.work_item)

      assert runs(ctx.work_item) == [{1, 1, :ended}, {1, 2, :waiting}]
      assert [{:taken_in, _}, {:answered, %{"questions" => ["q2"]}}] = kinds(ctx.work_item)
    end

    test "at any count of runs, an answer queues the next run, past the run limit", ctx do
      explore_run_fixture(ctx.work_item, end_cause: :lost)
      explore_run_fixture(ctx.work_item, end_cause: :lost)
      asked!(ctx.work_item, ["Which basket?", "Which sale?"])
      assert WorkItems.explore(ctx.scope, ctx.work_item).status == :questions

      assert {:ok, _} = WorkItems.answer(ctx.scope, ctx.work_item, 3, %{"1" => "The small one."})

      assert runs(ctx.work_item) ==
               [{1, 1, :ended}, {1, 2, :ended}, {1, 3, :ended}, {1, 4, :waiting}]

      assert %DispatchRun{of: 4} = Repo.one!(from r in DispatchRun, where: r.attempt == 4)
      assert %WorkItem{state: :exploring} = Repo.get!(WorkItem, ctx.work_item.id)
    end

    test "the next run reads the answers from the questions, not from its input", ctx do
      asked!(ctx.work_item, ["Which basket?"])
      {:ok, _} = WorkItems.answer(ctx.scope, ctx.work_item, 1, %{"1" => "The small one."})
      second = Repo.one!(from r in DispatchRun, where: r.attempt == 2)

      work_item = Repo.get!(WorkItem, ctx.work_item.id)
      {:ok, inputs} = Inputs.explore(work_item, second, run(work_item))
      inputs = inputs |> Jason.encode!() |> Jason.decode!()

      assert inputs["run"] == %{"attempt" => 2}

      for member <- ~w(answers changes proposal facts solution),
          do: refute(Map.has_key?(inputs, member))

      validator =
        JSV.build!(%{"$ref" => @base <> "explore/v1/inputs.schema.json"},
          resolver:
            {Resolver,
             [
               Path.expand("../../fixtures/contract", __DIR__),
               Application.app_dir(:apiary, "priv/contract")
             ]},
          formats: true
        )

      assert {:ok, _} = JSV.validate(inputs, validator)
    end

    test "answers that do not hold, refused with their errors, nothing written", ctx do
      asked!(ctx.work_item)
      before = questions(ctx.work_item)

      assert WorkItems.answer(ctx.scope, ctx.work_item, 1, %{"1" => " ", "2" => "a\u200Bb"}) ==
               {:error, {:invalid, %{"2" => :characters}}}

      assert WorkItems.answer(ctx.scope, ctx.work_item, 1, %{"1" => " ", "2" => "\r\n"}) ==
               {:error, {:invalid, %{"1" => :blank, "2" => :blank}}}

      assert WorkItems.answer(ctx.scope, ctx.work_item, 1, %{"3" => "Yes"}) ==
               {:error, {:invalid, :form}}

      assert WorkItems.answer(ctx.scope, ctx.work_item, 1, "Yes") == {:error, {:invalid, :form}}

      assert questions(ctx.work_item) == before
      assert runs(ctx.work_item) == [{1, 1, :ended}]
      assert entry("work_item.answer", ctx.work_item) == nil
    end

    test "where the latest run asked nothing, or another run is latest, refused", ctx do
      answers = %{"1" => "Yes"}
      explore_run_fixture(ctx.work_item, end_cause: :lost)
      assert WorkItems.answer(ctx.scope, ctx.work_item, 1, answers) == {:error, :not_waiting}
      assert WorkItems.answer(ctx.scope, ctx.work_item, 2, answers) == {:error, :stale}

      # Where a proposal waits, a member gives a review comment, a text: answers are no form.
      proposed = work_item_fixture(ctx.scope, external_ref: "acme/shop#12")
      proposed!(proposed)
      assert WorkItems.answer(ctx.scope, proposed, 1, answers) == {:error, {:invalid, :form}}

      running = work_item_fixture(ctx.scope, external_ref: "acme/shop#13")
      explore_run_fixture(running, state: :handed_over)
      assert WorkItems.answer(ctx.scope, running, 1, answers) == {:error, :running}

      none = work_item_fixture(ctx.scope, external_ref: "acme/shop#14")
      assert WorkItems.answer(ctx.scope, none, 1, answers) == {:error, :stale}
    end

    test "of another take in than the page read, not live, or not in the workspace, refused",
         ctx do
      asked!(ctx.work_item, ["Which basket?"])
      answers = %{"1" => "Yes"}

      assert WorkItems.answer(ctx.scope, %{ctx.work_item | take_in: 2}, 1, answers) ==
               {:error, :stale}

      assert WorkItems.answer(other_workspace_scope(ctx.scope), ctx.work_item, 1, answers) ==
               {:error, :not_found}

      {:ok, closed} = WorkItems.close(ctx.scope, ctx.work_item)
      assert WorkItems.answer(ctx.scope, closed, 1, answers) == {:error, :not_live}
    end

    test "of a work item whose id is no UUID, not found, nothing written", ctx do
      asked!(ctx.work_item, ["Which basket?"])
      before = written(ctx.work_item)

      for id <- @malformed do
        malformed = %{ctx.work_item | id: id}

        assert WorkItems.answer(ctx.scope, malformed, 1, %{"1" => "Yes"}) ==
                 {:error, :not_found}
      end

      assert written(ctx.work_item) == before
    end
  end

  describe "answer by question id" do
    defp asked_with_options!(work_item),
      do:
        asked!(work_item, [
          %{
            "question" => "Which basket?",
            "options" => [
              %{"title" => "The small one", "explanation" => "The checkout page shows it."},
              %{"title" => "The large one", "explanation" => "The shop page shows it."}
            ]
          },
          "Which sale?",
          "Which shop?"
        ])

    test "an option and a note together, a note alone, and the rest left open", ctx do
      asked_with_options!(ctx.work_item)

      answers = [
        %{"id" => "q1", "option" => " The large one ", "note" => "With the gift card field."},
        %{"id" => "q3", "option" => nil, "note" => " The spring sale. \r\n"}
      ]

      assert {:ok, %WorkItem{}} = WorkItems.answer(ctx.scope, ctx.work_item, 1, answers)

      assert [
               %{"id" => "q1", "state" => "answered", "answer" => first},
               %{"id" => "q2", "state" => "open"} = second,
               %{"id" => "q3", "state" => "answered", "answer" => third}
             ] = questions(ctx.work_item)

      assert %{"option" => "The large one", "note" => "With the gift card field."} = first
      assert %{"option" => nil, "note" => "The spring sale."} = third
      refute Map.has_key?(second, "answer")

      data = %{"take_in" => 1, "attempt" => 1, "count" => 2, "questions" => ["q1", "q3"]}
      assert [{:taken_in, _}, {:answered, ^data}] = kinds(ctx.work_item)
      assert entry("work_item.answer", ctx.work_item).details == data
      assert runs(ctx.work_item) == [{1, 1, :ended}, {1, 2, :waiting}]
    end

    test "an option with an empty note, or none, has no note", ctx do
      asked_with_options!(ctx.work_item)

      answers = [
        %{"id" => "q1", "option" => "The small one", "note" => " "},
        %{"id" => "q2", "note" => "The spring one."}
      ]

      assert {:ok, _} = WorkItems.answer(ctx.scope, ctx.work_item, 1, answers)
      assert [%{"answer" => first}, %{"answer" => second}, _open] = questions(ctx.work_item)
      assert first["option"] == "The small one"
      refute Map.has_key?(first, "note")
      assert %{"option" => nil, "note" => "The spring one."} = second
    end

    test "each answer that does not hold, refused by its id, nothing written", ctx do
      asked_with_options!(ctx.work_item)
      before = written(ctx.work_item)

      answers = [
        %{"id" => "q9", "note" => "Yes."},
        %{"id" => "q1", "option" => "Another one"},
        %{"id" => "q2", "option" => nil, "note" => " \n "},
        %{"id" => "q3", "note" => String.duplicate("a", 2001)}
      ]

      assert WorkItems.answer(ctx.scope, ctx.work_item, 1, answers) ==
               {:error,
                {:invalid,
                 %{
                   "q9" => :unknown_id,
                   "q1" => :unknown_option,
                   "q2" => :note_required,
                   "q3" => {:too_long, 2000}
                 }}}

      assert WorkItems.answer(ctx.scope, ctx.work_item, 1, [
               %{"id" => "q1", "option" => "The small one", "note" => "a\u200Bb"}
             ]) == {:error, {:invalid, %{"q1" => :characters}}}

      # 2,000 code points is the note's most.
      assert {:error, {:invalid, %{"q9" => :unknown_id}}} =
               WorkItems.answer(ctx.scope, ctx.work_item, 1, [
                 %{"id" => "q3", "note" => String.duplicate("é", 2000)},
                 %{"id" => "q9", "note" => "Yes."}
               ])

      assert written(ctx.work_item) == before
    end

    test "a question that is no longer open is refused by its id", ctx do
      asked_with_options!(ctx.work_item)
      {_version, document} = Questions.newest(Repo.get!(WorkItem, ctx.work_item.id))

      {:ok, document} =
        Questions.answer(document, [{"q2", nil, "Earlier."}], "Someone", DateTime.utc_now())

      {:ok, _version} =
        Apiary.Artifacts.push({:person, ctx.scope}, ctx.work_item, "questions", [
          Questions.file(document)
        ])

      assert WorkItems.answer(ctx.scope, ctx.work_item, 1, [
               %{"id" => "q2", "note" => "Again."},
               %{"id" => "q3", "note" => "The shop page."}
             ]) == {:error, {:invalid, %{"q2" => :not_open}}}

      assert [_q1, %{"answer" => %{"note" => "Earlier."}}, %{"state" => "open"}] =
               questions(ctx.work_item)
    end

    test "a list of another shape is no form", ctx do
      asked_with_options!(ctx.work_item)
      before = written(ctx.work_item)

      for answers <- [
            [],
            ["q1"],
            [%{"id" => 1, "note" => "Yes."}],
            [%{"note" => "Yes."}],
            [%{"id" => "q1", "custom" => "Yes."}],
            [%{"id" => "q1", "option" => 1}],
            [%{"id" => "q1", "note" => %{}}],
            [%{"id" => "q2", "note" => "Yes."}, %{"id" => "q2", "note" => "No."}]
          ] do
        assert WorkItems.answer(ctx.scope, ctx.work_item, 1, answers) ==
                 {:error, {:invalid, :form}},
               inspect(answers)
      end

      assert written(ctx.work_item) == before
    end

    test "where a proposal waits, a list is no review comment", ctx do
      proposed!(ctx.work_item)

      assert WorkItems.answer(ctx.scope, ctx.work_item, 1, [%{"id" => "q1", "note" => "Yes."}]) ==
               {:error, {:invalid, :form}}
    end
  end

  describe "confirm" do
    test "the proposal's version kept, ready for Shape", ctx do
      proposed!(ctx.work_item)

      assert {:ok, %WorkItem{state: :exploring}} = WorkItems.confirm(ctx.scope, ctx.work_item, 1)

      assert [%Confirmation{take_in: 1, attempt: 1, result: result} = confirmation] =
               Repo.all(Confirmation)

      assert result == %{"proposal_version" => 1}
      assert confirmation.confirmed_by_id == ctx.scope.user.id

      assert [{:taken_in, _}, {:confirmed, %{"take_in" => 1, "attempt" => 1}}] =
               kinds(ctx.work_item)

      assert entry("work_item.confirm", ctx.work_item).details ==
               %{"take_in" => 1, "attempt" => 1}

      explore = WorkItems.explore(ctx.scope, ctx.work_item)
      assert explore.status == :shape
      assert explore.confirmed_by_id == ctx.scope.user.id
      assert explore.review_comments == []

      assert WorkItems.confirm(ctx.scope, ctx.work_item, 1) == {:error, :not_waiting}
      assert Repo.aggregate(Confirmation, :count) == 1
    end

    test "where no proposal waits, or another run is latest, refused", ctx do
      asked!(ctx.work_item)
      assert WorkItems.confirm(ctx.scope, ctx.work_item, 1) == {:error, :not_waiting}
      assert WorkItems.confirm(ctx.scope, ctx.work_item, 2) == {:error, :stale}

      running = work_item_fixture(ctx.scope, external_ref: "acme/shop#13")
      explore_run_fixture(running, state: :waiting)
      assert WorkItems.confirm(ctx.scope, running, 1) == {:error, :running}
    end

    test "of a work item whose id is no UUID, not found, nothing written", ctx do
      proposed!(ctx.work_item)
      before = written(ctx.work_item)

      for id <- @malformed do
        malformed = %{ctx.work_item | id: id}
        assert WorkItems.confirm(ctx.scope, malformed, 1) == {:error, :not_found}
      end

      assert written(ctx.work_item) == before
    end

    test "on the last run, a proposal still waits for Confirm", ctx do
      explore_run_fixture(ctx.work_item, end_cause: :lost)
      explore_run_fixture(ctx.work_item, end_cause: :lost)
      proposed!(ctx.work_item)

      assert WorkItems.explore(ctx.scope, ctx.work_item).status == :confirm
      assert {:ok, _} = WorkItems.confirm(ctx.scope, ctx.work_item, 3)
    end
  end

  describe "explore again" do
    for {name, opts} <- [
          {"gave no result", [end_cause: :run_ended]},
          {"was lost", [end_cause: :lost]},
          {"was cancelled", [end_cause: :released]},
          {"could not be handed over", [end_cause: :ticket_gone]}
        ] do
      test "after a run that #{name}: the take in's next run queued", ctx do
        explore_run_fixture(ctx.work_item, unquote(opts))

        assert {:ok, again} = WorkItems.explore_again(ctx.scope, ctx.work_item, 1)
        assert runs(ctx.work_item) == [{1, 1, :ended}, {1, 2, :waiting}]

        assert [{:taken_in, _}, {:explore_again, %{"take_in" => 1, "attempt" => 2}}] =
                 kinds(ctx.work_item)

        assert entry("work_item.explore_again", ctx.work_item).details ==
                 %{"take_in" => 1, "attempt" => 2}

        assert WorkItems.explore(ctx.scope, again).status == :queued
      end
    end

    test "where the run asked, proposed or runs, refused", ctx do
      asked!(ctx.work_item)
      assert WorkItems.explore_again(ctx.scope, ctx.work_item, 1) == {:error, :not_waiting}

      proposed = work_item_fixture(ctx.scope, external_ref: "acme/shop#13")
      proposed!(proposed)
      assert WorkItems.explore_again(ctx.scope, proposed, 1) == {:error, :not_waiting}

      running = work_item_fixture(ctx.scope, external_ref: "acme/shop#14")
      explore_run_fixture(running, state: :handed_over)
      assert WorkItems.explore_again(ctx.scope, running, 1) == {:error, :running}

      # Ended, what it gave not yet stored: it reads as running.
      settling = work_item_fixture(ctx.scope, external_ref: "acme/shop#15")
      explore_run_fixture(settling, settle: false)
      assert WorkItems.explore_again(ctx.scope, settling, 1) == {:error, :running}
    end

    test "at the run limit, refused; twice for one run, the second is stale", ctx do
      explore_run_fixture(ctx.work_item, end_cause: :lost)
      assert {:ok, _} = WorkItems.explore_again(ctx.scope, ctx.work_item, 1)
      assert WorkItems.explore_again(ctx.scope, ctx.work_item, 1) == {:error, :stale}

      used = work_item_fixture(ctx.scope, external_ref: "acme/shop#13")
      for _ <- 1..3, do: explore_run_fixture(used, end_cause: :lost)
      assert WorkItems.explore_again(ctx.scope, used, 3) == {:error, :used_up}
      assert runs(used) |> length() == 3
    end

    test "of a work item whose id is no UUID, not found, nothing written", ctx do
      explore_run_fixture(ctx.work_item, end_cause: :lost)
      before = written(ctx.work_item)

      for id <- @malformed do
        malformed = %{ctx.work_item | id: id}
        assert WorkItems.explore_again(ctx.scope, malformed, 1) == {:error, :not_found}
      end

      assert written(ctx.work_item) == before
    end
  end

  describe "the stage a close records" do
    test "a close at Explore, and at Confirm", ctx do
      explore_run_fixture(ctx.work_item, end_cause: :lost)
      {:ok, _} = WorkItems.close(ctx.scope, ctx.work_item)
      assert {:closed, %{"stage" => "explore"}} = List.last(kinds(ctx.work_item))

      proposed = work_item_fixture(ctx.scope, external_ref: "acme/shop#13")
      proposed!(proposed)
      {:ok, closed} = WorkItems.close(ctx.scope, proposed)
      assert {:closed, %{"stage" => "confirm"}} = List.last(kinds(proposed))

      assert WorkItems.explore(ctx.scope, closed) |> Map.take([:status, :stage]) ==
               %{status: :closed, stage: :confirm}
    end

    test "once confirmed, a close records Shape", ctx do
      proposed!(ctx.work_item)
      {:ok, _} = WorkItems.confirm(ctx.scope, ctx.work_item, 1)

      {:ok, closed} = WorkItems.close(ctx.scope, ctx.work_item)
      assert {:closed, %{"stage" => "shape"}} = List.last(kinds(ctx.work_item))

      assert WorkItems.explore(ctx.scope, closed) |> Map.take([:status, :stage]) ==
               %{status: :closed, stage: :shape}
    end
  end
end
