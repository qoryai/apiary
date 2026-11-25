defmodule Apiary.FindingsTest do
  # The findings of a work item (`Apiary.Findings`): a run's batch of events, the bases,
  # the numbers, a person's events and the rows that are only added.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.StagesFixtures

  alias Apiary.{Findings, Repo}
  alias Apiary.Findings.{Base, Event, Finding}
  alias Apiary.Runs.Target
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: [:factory, :workflow_model]

  @explore "st_r79kph11eg"
  @build "st_6ns22c4pav"
  @verify "st_m1mqbeywdg"
  @base String.duplicate("a", 40)

  setup do
    %{scope: scope} = sign_up_fixture()
    work_item = taken_in_fixture(scope)
    queued = newest_run(work_item)

    # The row of the work item's target, which the assign of its collection makes.
    :ok =
      Target.insert_new(work_item.organisation_id, work_item.workspace_id, [
        WorkItem.target(work_item)
      ])

    target_id = Target.dispatched_id(work_item.workspace_id, queued.id)
    assert is_binary(target_id)

    %{
      scope: scope,
      work_item: work_item,
      target_id: target_id,
      run: %{run_id: Ecto.UUID.generate(), dispatch_run_id: queued.id}
    }
  end

  defp raise_event(ctx, ref, attrs \\ %{}) do
    Map.merge(
      %{
        kind: "raise",
        by: "code-reviewer",
        ref: ref,
        target_id: ctx.target_id,
        stage_id: @build,
        source_kind: "reviewer",
        source_name: "code-reviewer",
        severity: "blocking",
        place: %{"quote" => "total = price + tax - discount"},
        point: "The discount is applied after the tax",
        problem: "The tax is charged on the full price.",
        fix: "Subtract the discount first.",
        proof: "An order of 100.00 totals 110.00.",
        version: nil,
        reason: nil
      },
      attrs
    )
  end

  defp event(ctx, kind, number, attrs \\ %{}),
    do:
      Map.merge(
        %{kind: kind, by: "suite", number: number, target_id: ctx.target_id, reason: "Why."},
        attrs
      )

  defp post(ctx, events, bases \\ []),
    do: Findings.post(ctx.work_item, ctx.run, %{bases: bases, events: events})

  defp finding(ctx, number),
    do:
      Repo.one!(
        from f in Finding, where: f.work_item_id == ^ctx.work_item.id and f.number == ^number
      )

  defp kinds(ctx, number) do
    %Finding{id: id} = finding(ctx, number)
    Repo.all(from e in Event, where: e.finding_id == ^id, order_by: e.position, select: e.kind)
  end

  describe "post/3" do
    test "a raise gets the next number of the work item, and the answer counts per stage", ctx do
      assert {:ok, %{created: [{"r1", "f1"}, {"r2", "f2"}], open_blocking: counts}} =
               post(ctx, [
                 raise_event(ctx, "r1"),
                 raise_event(ctx, "r2", %{stage_id: @verify, severity: "non-blocking"})
               ])

      assert Enum.sort(counts) == [{@build, 1}, {@verify, 0}]

      assert {:ok, %{created: [{"r1", "f3"}]}} =
               post(ctx, [raise_event(ctx, "r1", %{stage_id: @verify})])

      assert %Finding{state: "open", take_in: 1, stage_id: @build, severity: "blocking"} =
               finding(ctx, 1)

      assert [
               %Event{
                 kind: "raised",
                 round: round,
                 actor_kind: "qory",
                 actor_name: "code-reviewer"
               }
             ] =
               Repo.all(from e in Event, where: e.finding_id == ^finding(ctx, 1).id)

      assert round == (ctx.work_item.stage_round || 1)
    end

    test "numbers count the work item's findings across its targets", ctx do
      :ok =
        Target.insert_new(ctx.work_item.organisation_id, ctx.work_item.workspace_id, [
          %{
            adapter_id: ctx.work_item.adapter_id,
            collection_external_ref: "other-collection",
            system: "forge.example.com",
            path: "acme/other"
          }
        ])

      other =
        Repo.one!(
          from t in Target,
            where: t.workspace_id == ^ctx.work_item.workspace_id,
            where: t.collection_external_ref == "other-collection",
            select: t.id
        )

      assert {:ok, %{created: [{"r1", "f1"}]}} = post(ctx, [raise_event(ctx, "r1")])

      assert {:ok, %{created: [{"r1", "f2"}]}} =
               post(ctx, [raise_event(ctx, "r1", %{target_id: other})])

      assert [%Finding{number: 1}] = Findings.list(ctx.work_item, ctx.target_id)
      assert [%Finding{number: 2}] = Findings.list(ctx.work_item, other)
    end

    test "a repeat of an open finding adds repeated; a run's close and a repeat reopen it", ctx do
      {:ok, _} = post(ctx, [raise_event(ctx, "r1")])

      {:ok, _} =
        post(ctx, [
          event(ctx, "repeat", 1),
          event(ctx, "reply_disputed", 1),
          event(ctx, "close_fixed", 1)
        ])

      assert %Finding{state: "fixed", disputed: true} = finding(ctx, 1)

      {:ok, %{open_blocking: [{@build, 1}]}} = post(ctx, [event(ctx, "repeat", 1)])
      assert %Finding{state: "open"} = finding(ctx, 1)

      assert kinds(ctx, 1) == ~w(raised repeated replied_disputed closed_fixed reopened)

      {:ok, _} = post(ctx, [event(ctx, "reply_fixed", 1), event(ctx, "close_dismissed", 1)])
      assert %Finding{state: "dismissed", disputed: false} = finding(ctx, 1)
    end

    test "a repeat or a close for a run's stage is refused for another stage's finding",
         ctx do
      {:ok, _} = post(ctx, [raise_event(ctx, "r1", %{stage_id: @verify})])

      # Read under the lock, with the events in order: the raise before it is not kept.
      for kind <- ~w(repeat close_fixed close_dismissed) do
        assert post(ctx, [
                 raise_event(ctx, "r2"),
                 event(ctx, kind, 1, %{run_stage_id: @build})
               ]) == {:error, {:other_stage, 1}}
      end

      assert %Finding{state: "open"} = finding(ctx, 1)
      assert kinds(ctx, 1) == ~w(raised)

      assert Repo.aggregate(
               from(f in Finding, where: f.work_item_id == ^ctx.work_item.id),
               :count
             ) == 1

      assert {:ok, _} = post(ctx, [event(ctx, "close_fixed", 1, %{run_stage_id: @verify})])
      assert %Finding{state: "fixed"} = finding(ctx, 1)
    end

    test "a repeat of a finding a person closed adds an event and leaves it closed", ctx do
      {:ok, _} = post(ctx, [raise_event(ctx, "r1")])
      work_item = Repo.get!(WorkItem, ctx.work_item.id)

      :ok = Findings.accept_open(work_item, @build, ctx.scope.user.id)

      assert {:ok, %{open_blocking: [{@build, 0}]}} =
               post(ctx, [event(ctx, "repeat", 1), event(ctx, "close_fixed", 1)])

      assert %Finding{state: "accepted", closed_by_person: true} = finding(ctx, 1)
      assert kinds(ctx, 1) == ~w(raised accepted repeated_after_person_close closed_fixed)
    end

    test "a finding the work item's current take in does not have is not found", ctx do
      {:ok, _} = post(ctx, [raise_event(ctx, "r1")])

      assert post(ctx, [event(ctx, "repeat", 1), event(ctx, "repeat", 7)]) ==
               {:error, {:not_found, 1}}

      # The error writes nothing: the first event of the batch is not kept.
      assert kinds(ctx, 1) == ["raised"]

      {1, _} =
        Repo.update_all(
          from(f in Finding, where: f.number == 1 and f.work_item_id == ^ctx.work_item.id),
          set: [take_in: 0]
        )

      assert post(ctx, [event(ctx, "repeat", 1)]) == {:error, {:not_found, 0}}
    end

    test "a base is written once per take in and target; another base is refused", ctx do
      assert {:ok, _} =
               post(ctx, [raise_event(ctx, "r1")], [%{target_id: ctx.target_id, base: @base}])

      assert {:ok, _} =
               post(ctx, [event(ctx, "repeat", 1)], [%{target_id: ctx.target_id, base: @base}])

      assert post(ctx, [event(ctx, "repeat", 1)], [
               %{target_id: ctx.target_id, base: String.duplicate("b", 40)}
             ]) == {:error, :base_changed}

      assert [%Base{base: @base}] = Findings.bases(ctx.work_item, ctx.target_id)
      # The refused batch wrote no event.
      assert kinds(ctx, 1) == ~w(raised repeated)
    end

    test "the database keeps one base per work item, take in and target", ctx do
      row = %Base{
        organisation_id: ctx.work_item.organisation_id,
        work_item_id: ctx.work_item.id,
        take_in: 1,
        target_id: ctx.target_id,
        base: @base,
        inserted_at: DateTime.utc_now()
      }

      Repo.insert!(row)

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%{row | id: nil, base: String.duplicate("c", 40)})
      end
    end

    test "a run of the queue that ended writes nothing", ctx do
      {1, _} =
        Repo.update_all(
          from(d in Apiary.Dispatches.DispatchRun, where: d.id == ^ctx.run.dispatch_run_id),
          set: [state: :ended, end_cause: :run_ended]
        )

      assert post(ctx, [raise_event(ctx, "r1")]) == {:error, :not_found}
      assert Repo.aggregate(Finding, :count) == 0
    end
  end

  describe "the events of a finding" do
    test "cannot be changed or deleted, but go with their work item", ctx do
      {:ok, _} = post(ctx, [raise_event(ctx, "r1")])
      %Finding{id: id} = finding(ctx, 1)

      assert_raise Postgrex.Error, ~r/finding events are only added: UPDATE refused/, fn ->
        Repo.update_all(from(e in Event, where: e.finding_id == ^id), set: [reason: "Changed."])
      end

      assert_raise Postgrex.Error, ~r/finding events are only added: DELETE refused/, fn ->
        Repo.delete_all(from e in Event, where: e.finding_id == ^id)
      end

      Repo.delete_all(from w in WorkItem, where: w.id == ^ctx.work_item.id)
      assert Repo.aggregate(from(e in Event, where: e.finding_id == ^id), :count) == 0
    end
  end

  describe "list/2" do
    test "has the first 500 findings, each with its newest 100 events, oldest first", ctx do
      for refs <- Enum.chunk_every(1..501, 100) do
        {:ok, _} = post(ctx, for(n <- refs, do: raise_event(ctx, "r#{n}")))
      end

      # 1 raised, then 101 repeated: positions 1 to 102.
      {:ok, _} = post(ctx, for(_ <- 1..101, do: event(ctx, "repeat", 1)))

      findings = Findings.list(ctx.work_item, ctx.target_id)
      assert Enum.map(findings, & &1.number) == Enum.to_list(1..500)

      [first, second | _rest] = findings
      assert Enum.map(first.events, & &1.position) == Enum.to_list(3..102)
      assert Enum.all?(first.events, &(&1.kind == "repeated"))
      assert [%Event{kind: "raised", position: 1}] = second.events
    end
  end

  describe "the gate and Accept as it is" do
    setup ctx do
      {:ok, _} =
        post(ctx, [raise_event(ctx, "r1"), raise_event(ctx, "r2", %{severity: "non-blocking"})])

      %{work_item: Repo.get!(WorkItem, ctx.work_item.id)}
    end

    test "accept_open/3 accepts every open finding of the stage, blocking or not", ctx do
      {:ok, _} = post(ctx, [raise_event(ctx, "r3", %{stage_id: @verify})])
      assert Findings.open_blocking(ctx.work_item, @build) == [1]

      user_id = ctx.scope.user.id
      assert Findings.accept_open(ctx.work_item, @build, user_id) == :ok
      assert Findings.open(ctx.work_item, @build) == []

      for number <- [1, 2] do
        assert kinds(ctx, number) == ~w(raised accepted)

        assert [%Event{actor_kind: "person", user_id: ^user_id, actor_name: nil}] =
                 Repo.all(
                   from e in Event,
                     where: e.finding_id == ^finding(ctx, number).id and e.kind == "accepted"
                 )
      end

      assert %Finding{state: "accepted"} = finding(ctx, 2)
      # Verify's finding is left as it is.
      assert Findings.open_blocking(ctx.work_item, @verify) == [3]
    end

    test "refusal_lines/3 has the action, then the rule" do
      for {action, button} <- [
            request_changes: "Request changes",
            another_round: "Run another round"
          ] do
        rule = "Build passes only when none is open."

        assert Findings.refusal_lines(1, "Build", action) ==
                 ["Click #{button}. 1 blocking finding is open.", rule]

        assert Findings.refusal_lines(2, "Build", action) ==
                 ["Click #{button}. 2 blocking findings are open.", rule]
      end
    end

    test "gate/2 refuses a stage with an open blocking finding, and only that stage", ctx do
      stage = %{"id" => @build, "name" => "Build"}

      assert Findings.gate(ctx.work_item, stage) ==
               {:error,
                {:open_blocking_findings,
                 %{stage_id: @build, stage: "Build", findings: ["f1"], count: 1}}}

      assert Findings.gate(ctx.work_item, %{"id" => @verify, "name" => "Verify"}) == :ok
      assert Findings.gate(ctx.work_item, %{"id" => @explore, "name" => "Explore"}) == :ok
    end
  end

  test "stage_names/1 writes each stage's name as the run contract has it" do
    document = %{
      "stages" => [
        %{"id" => "st_r79kph11eg", "name" => "Code review"},
        %{"id" => "st_p9w5cvh311", "name" => "Build"},
        %{"id" => "st_6ns22c4pav", "name" => "build"},
        %{"id" => "st_m1mqbeywdg", "name" => "  Prüfung & Abnahme!  "},
        %{"id" => "st_k9kpv17xmy", "name" => "???"}
      ]
    }

    assert Findings.stage_names(document) == %{
             "st_r79kph11eg" => "code-review",
             "st_p9w5cvh311" => "p9w5cvh311",
             "st_6ns22c4pav" => "6ns22c4pav",
             "st_m1mqbeywdg" => "pr-fung-abnahme",
             "st_k9kpv17xmy" => "k9kpv17xmy"
           }
  end

  test "a stage whose name is another stage's id after st_ gets its id after st_ (stage_names/1)" do
    document = %{
      "stages" => [
        %{"id" => "st_r79kph11eg", "name" => "k9kpv17xmy"},
        %{"id" => "st_k9kpv17xmy", "name" => "???"},
        %{"id" => "st_build", "name" => "Build"}
      ]
    }

    names = Findings.stage_names(document)

    assert names == %{
             "st_r79kph11eg" => "r79kph11eg",
             "st_k9kpv17xmy" => "k9kpv17xmy",
             "st_build" => "build"
           }

    # Each name leads back to one stage.
    assert names |> Map.values() |> Enum.uniq() |> length() == 3
  end

  test "verdict_message/3 writes the run contract's two lines, singular for one finding" do
    assert Findings.verdict_message("build", 2, ["f1", "f2"]) ==
             "Send changes-requested in place of passed: build has 2 open blocking findings.\n" <>
               "  The open blocking findings are f1, f2."

    assert Findings.verdict_message("build", 1, ["f1"]) ==
             "Send changes-requested in place of passed: build has 1 open blocking finding.\n" <>
               "  The open blocking finding is f1."
  end
end
