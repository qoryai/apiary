defmodule Apiary.WorkItems.MemberActionsTest do
  # What a member gives Explore (`Apiary.WorkItems.answer/4`, `confirm/4` and
  # `explore_again/3`): each where Explore waits for it, with its records, its event, its
  # next run where it queues one, its entry in the trail, and each refusal; the answers a
  # take in's next run reads (`take_in_answers/2`, through `Apiary.Dispatches.Inputs`);
  # and the stage a decline and a close record, a decline refused once confirmed.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Repo, WorkItems}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{DispatchRun, Inputs}
  alias Apiary.WorkItems.{Answer, Confirmation, WorkItem, WorkItemEvent}

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
  # and the answers and confirmations kept.
  defp written(work_item),
    do: {
      Repo.get!(WorkItem, work_item.id),
      kinds(work_item),
      runs(work_item),
      Repo.aggregate(from(e in Entry, where: e.subject_id == ^work_item.id), :count),
      Repo.aggregate(Answer, :count),
      Repo.aggregate(Confirmation, :count)
    }

  defp asked!(work_item, questions \\ ["Which basket?", "Which sale?"]),
    do: explore_run_fixture(work_item, result: questions_result(questions))

  defp proposed!(work_item), do: explore_run_fixture(work_item, result: understood_result())

  # The domain and the target a handover gives the input of a run of `work_item`.
  defp run(work_item),
    do: %{
      domain: "software",
      target: %{system: work_item.target_system, path: work_item.target_path}
    }

  defp edit_form(attrs) do
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

  describe "answer" do
    test "keeps each answer with its question, and queues the take in's next run", ctx do
      asked!(ctx.work_item)
      answers = %{"1" => "The one on the checkout page.", "2" => " The spring sale. "}

      assert {:ok, %WorkItem{} = answered} =
               WorkItems.answer(ctx.scope, ctx.work_item, 1, answers)

      assert DateTime.compare(answered.updated_at, ctx.work_item.updated_at) == :gt

      assert [
               %Answer{
                 position: 1,
                 question: "Which basket?",
                 answer: "The one on the checkout page."
               } =
                 first,
               %Answer{position: 2, question: "Which sale?", answer: "The spring sale."}
             ] = Repo.all(from a in Answer, order_by: a.position)

      assert first.take_in == 1 and first.attempt == 1
      assert first.answered_by_id == ctx.scope.user.id

      assert runs(ctx.work_item) == [{1, 1, :ended}, {1, 2, :waiting}]

      assert [{:taken_in, _}, {:answered, %{"take_in" => 1, "attempt" => 1, "count" => 2}}] =
               kinds(ctx.work_item)

      assert entry("work_item.answer", ctx.work_item).details ==
               %{"take_in" => 1, "attempt" => 1, "count" => 2}

      explore = WorkItems.explore(ctx.scope, answered)
      assert explore.status == :queued
      assert explore.answers_by_ids == [ctx.scope.user.id]
      assert [%{questions: questions, answered_by_id: answered_by}] = explore.earlier_runs
      assert answered_by == ctx.scope.user.id

      assert questions == [
               %{public_id: "1", text: "Which basket?", answer: "The one on the checkout page."},
               %{public_id: "2", text: "Which sale?", answer: "The spring sale."}
             ]
    end

    test "the next run's input carries the answers, oldest first, as the contract has them",
         ctx do
      asked!(ctx.work_item, ["Which basket?"])
      {:ok, _} = WorkItems.answer(ctx.scope, ctx.work_item, 1, %{"1" => "The small one."})
      %{dispatch_run: second} = Repo.one!(from r in DispatchRun, where: r.attempt == 2) |> wrap()

      # The second run asks again, and is answered; the third reads both.
      {1, _} =
        Repo.update_all(from(r in DispatchRun, where: r.id == ^second.id),
          set: [state: :ended, end_cause: :run_ended]
        )

      run =
        Repo.insert!(%Apiary.Runs.Run{
          organisation_id: ctx.work_item.organisation_id,
          workspace_id: ctx.work_item.workspace_id,
          node_run_id: second.run_id,
          dispatch_run_id: second.id,
          state: "completed",
          exit_state: "completed"
        })

      result_event!(run, 3, %{
        "is_error" => false,
        "result" => Jason.encode!(questions_result(["Which shop?"]))
      })

      {:ok, _} = WorkItems.answer(ctx.scope, ctx.work_item, 2, %{"1" => "The one in town."})
      third = Repo.one!(from r in DispatchRun, where: r.attempt == 3)

      [first_answer, second_answer] = WorkItems.take_in_answers(ctx.work_item, 1)
      name = Inputs.person_name(ctx.scope.user.id)

      assert Jason.decode!(Jason.encode!(first_answer)) == %{
               "question" => "Which basket?",
               "answer" => "The small one.",
               "by" => %{"name" => name},
               "at" => Jason.decode!(Jason.encode!(first_answer))["at"]
             }

      assert Enum.map(first_answer.values, &elem(&1, 0)) == ["question", "answer", "by", "at"]
      assert Jason.decode!(Jason.encode!(second_answer))["question"] == "Which shop?"

      assert Jason.decode!(Jason.encode!(first_answer))["at"] =~
               ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/

      work_item = Repo.get!(WorkItem, ctx.work_item.id)
      {:ok, inputs} = Inputs.explore(work_item, third, run(work_item))
      inputs = inputs |> Jason.encode!() |> Jason.decode!()

      assert Enum.map(inputs["answers"], & &1["answer"]) == ["The small one.", "The one in town."]
      assert inputs["run"] == %{"attempt" => 3, "of" => 3}

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

    test "an answer whose member's account is gone is a former member's", ctx do
      asked!(ctx.work_item, ["Which basket?"])
      {:ok, _} = WorkItems.answer(ctx.scope, ctx.work_item, 1, %{"1" => "The small one."})
      Repo.update_all(Answer, set: [answered_by_id: nil])

      assert [answer] = WorkItems.take_in_answers(ctx.work_item, 1)
      assert Jason.decode!(Jason.encode!(answer))["by"] == %{"name" => "former member"}
    end

    test "an answer by a member whose name the contract refuses: the next run has no input",
         ctx do
      # The account's email rules now refuse a bidirectional control in the local part,
      # but an account whose address took one before still holds it; the explore input's
      # name refuses it.
      email = "ann\u202Ex#{System.unique_integer([:positive])}@example.com"

      refute Apiary.Accounts.User.email_changeset(%Apiary.Accounts.User{}, %{email: email},
               validate_unique: false
             ).valid?

      %{user: user} = member_fixture(ctx.scope)

      {1, _} =
        Repo.update_all(from(u in Apiary.Accounts.User, where: u.id == ^user.id),
          set: [email: email]
        )

      member = workspace_scope(Repo.get!(Apiary.Accounts.User, user.id), ctx.scope.workspace)

      asked!(ctx.work_item, ["Which basket?"])
      {:ok, answered} = WorkItems.answer(member, ctx.work_item, 1, %{"1" => "The small one."})

      next =
        Repo.one!(from r in DispatchRun, where: r.work_item_id == ^answered.id and r.attempt == 2)

      assert Inputs.explore(answered, next, run(answered)) == {:error, :inputs_invalid}
    end

    test "answers belong to their take in: another take in reads none of them", ctx do
      asked!(ctx.work_item, ["Which basket?"])
      {:ok, _} = WorkItems.answer(ctx.scope, ctx.work_item, 1, %{"1" => "The small one."})

      assert WorkItems.take_in_answers(ctx.work_item, 2) == []
      assert length(WorkItems.take_in_answers(ctx.work_item, 1)) == 1
    end

    test "answers that do not hold, refused with their errors, nothing written", ctx do
      asked!(ctx.work_item)

      assert WorkItems.answer(ctx.scope, ctx.work_item, 1, %{"1" => " ", "2" => "a\u200Bb"}) ==
               {:error, {:invalid, %{"1" => :blank, "2" => :characters}}}

      assert WorkItems.answer(ctx.scope, ctx.work_item, 1, %{"1" => "Yes"}) ==
               {:error, {:invalid, :form}}

      assert Repo.aggregate(Answer, :count) == 0
      assert runs(ctx.work_item) == [{1, 1, :ended}]
      assert entry("work_item.answer", ctx.work_item) == nil
    end

    test "where the latest run asked nothing, or another run is latest, refused", ctx do
      answers = %{"1" => "Yes"}
      proposed!(ctx.work_item)
      assert WorkItems.answer(ctx.scope, ctx.work_item, 1, answers) == {:error, :not_waiting}
      assert WorkItems.answer(ctx.scope, ctx.work_item, 2, answers) == {:error, :stale}

      running = work_item_fixture(ctx.scope, external_ref: "acme/shop#13")
      explore_run_fixture(running, state: :handed_over)
      assert WorkItems.answer(ctx.scope, running, 1, answers) == {:error, :running}

      none = work_item_fixture(ctx.scope, external_ref: "acme/shop#14")
      assert WorkItems.answer(ctx.scope, none, 1, answers) == {:error, :stale}
    end

    test "at the run limit, refused: the work item stays live", ctx do
      explore_run_fixture(ctx.work_item, end_cause: :lost)
      explore_run_fixture(ctx.work_item, end_cause: :lost)
      asked!(ctx.work_item, ["Which basket?"])

      assert WorkItems.answer(ctx.scope, ctx.work_item, 3, %{"1" => "Yes"}) == {:error, :used_up}
      assert %WorkItem{state: :exploring} = Repo.get!(WorkItem, ctx.work_item.id)
      assert WorkItems.explore(ctx.scope, ctx.work_item).status == :used_up
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

  describe "confirm" do
    test "as it stands: the result kept, no changes, ready for Shape", ctx do
      proposed!(ctx.work_item)

      assert {:ok, %WorkItem{state: :exploring}} = WorkItems.confirm(ctx.scope, ctx.work_item, 1)

      assert [
               %Confirmation{take_in: 1, attempt: 1, changes: changes, result: result} =
                 confirmation
             ] =
               Repo.all(Confirmation)

      assert changes == %{}
      assert result == understood_result()
      assert confirmation.confirmed_by_id == ctx.scope.user.id

      assert [{:taken_in, _}, {:confirmed, %{"take_in" => 1, "attempt" => 1, "changed" => []}}] =
               kinds(ctx.work_item)

      assert entry("work_item.confirm", ctx.work_item).details ==
               %{"take_in" => 1, "attempt" => 1, "changed" => []}

      explore = WorkItems.explore(ctx.scope, ctx.work_item)
      assert explore.status == :shape
      assert explore.confirmed_by_id == ctx.scope.user.id
      assert explore.changes == %{}

      assert WorkItems.confirm(ctx.scope, ctx.work_item, 1) == {:error, :not_waiting}
      assert Repo.aggregate(Confirmation, :count) == 1
    end

    test "with the edit page's changes: only those that differ kept, by who confirmed", ctx do
      proposed!(ctx.work_item)

      form =
        edit_form(%{
          "complexity" => %{"level" => "complex", "reason" => "Two screens read the price."},
          "scope_out" => "The invoice\r\nThe receipt"
        })

      assert {:ok, _} = WorkItems.confirm(ctx.scope, ctx.work_item, 1, form)

      assert [%Confirmation{changes: changes}] = Repo.all(Confirmation)

      assert changes == %{
               "complexity" => %{"level" => "complex", "reason" => "Two screens read the price."},
               "scope_out" => ["The invoice", "The receipt"]
             }

      assert entry("work_item.confirm", ctx.work_item).details["changed"] ==
               ["complexity", "scope_out"]

      user_id = ctx.scope.user.id

      assert %{
               complexity: %{value: %{level: :complex}, by_id: ^user_id},
               scope_out: %{value: ["The invoice", "The receipt"], by_id: ^user_id}
             } = WorkItems.explore(ctx.scope, ctx.work_item).changes
    end

    test "changes that do not hold, refused with their errors, nothing written", ctx do
      proposed!(ctx.work_item)

      assert WorkItems.confirm(ctx.scope, ctx.work_item, 1, edit_form(%{"approach" => ""})) ==
               {:error, {:invalid, %{approach: :blank}}}

      assert WorkItems.confirm(ctx.scope, ctx.work_item, 1, %{"approach" => "x"}) ==
               {:error, {:invalid, :form}}

      assert Repo.aggregate(Confirmation, :count) == 0
      assert entry("work_item.confirm", ctx.work_item) == nil
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

      for id <- @malformed, params <- [nil, edit_form(%{"scope_out" => "The receipt"})] do
        malformed = %{ctx.work_item | id: id}
        assert WorkItems.confirm(ctx.scope, malformed, 1, params) == {:error, :not_found}
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

      # Ended by its outcome a moment ago, its result may still come.
      settling = work_item_fixture(ctx.scope, external_ref: "acme/shop#15")

      explore_run_fixture(settling,
        run: %{exit_state: nil, outcome_received_at: DateTime.utc_now()}
      )

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

  describe "the stage a decline and a close record" do
    test "a decline at Explore, and at Confirm", ctx do
      explore_run_fixture(ctx.work_item, end_cause: :lost)
      {:ok, _} = WorkItems.decline(ctx.scope, ctx.work_item)
      assert {:declined, %{"stage" => "explore"}} = List.last(kinds(ctx.work_item))

      proposed = work_item_fixture(ctx.scope, external_ref: "acme/shop#13")
      proposed!(proposed)
      {:ok, declined} = WorkItems.decline(ctx.scope, proposed)
      assert {:declined, %{"stage" => "confirm"}} = List.last(kinds(proposed))

      assert WorkItems.explore(ctx.scope, declined) |> Map.take([:status, :stage]) ==
               %{status: :declined, stage: :confirm}
    end

    test "once confirmed, a decline is refused, and a close records Shape", ctx do
      proposed!(ctx.work_item)
      {:ok, _} = WorkItems.confirm(ctx.scope, ctx.work_item, 1)

      assert WorkItems.decline(ctx.scope, ctx.work_item) == {:error, :confirmed}
      assert %WorkItem{state: :exploring} = Repo.get!(WorkItem, ctx.work_item.id)

      {:ok, closed} = WorkItems.close(ctx.scope, ctx.work_item)
      assert {:closed, %{"stage" => "shape"}} = List.last(kinds(ctx.work_item))

      assert WorkItems.explore(ctx.scope, closed) |> Map.take([:status, :stage]) ==
               %{status: :closed, stage: :shape}
    end
  end

  defp wrap(dispatch_run), do: %{dispatch_run: dispatch_run}
end
