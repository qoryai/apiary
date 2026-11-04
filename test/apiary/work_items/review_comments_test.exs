defmodule Apiary.WorkItems.ReviewCommentsTest do
  # A member's review comments on Explore's proposal, kept in the work item's
  # `review-comments` artifact (`Apiary.Explore.ReviewComments`), with the workflow model
  # on: a review comment written wherever no run runs, also while questions are open, and
  # queuing no run (`Apiary.WorkItems.review_comment/4`); the open review comments sent
  # to the next run with the answers, or at the gate or while questions wait
  # (`send_review_comments/3`); a reply that opens a review comment again (`reply/5`);
  # the run that closes them with its reply; and today's form, a text at the gate,
  # written and sent in one move (`answer/4`).
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.StagesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Processes, Repo, WorkItems}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{DispatchRun, Inputs}
  alias Apiary.Explore.{Questions, ReviewComments}
  alias Apiary.WorkItems.{WorkItem, WorkItemEvent}

  @moduletag needs: [:factory, :workflow_model]

  @comment "Offer a replacement first, then a refund."

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp reload(work_item), do: Repo.get!(WorkItem, work_item.id)

  # The review comments of the newest version, nil for none.
  defp review_comments(work_item) do
    case ReviewComments.newest(reload(work_item)) do
      {_version, document} -> ReviewComments.entries(document)
      nil -> nil
    end
  end

  defp runs(work_item),
    do:
      Repo.all(
        from r in DispatchRun,
          where: r.work_item_id == ^work_item.id,
          order_by: [r.take_in, r.attempt],
          select: {r.attempt, r.of, r.state}
      )

  defp answered_events(work_item),
    do:
      Repo.all(
        from e in WorkItemEvent,
          where: e.work_item_id == ^work_item.id and e.kind == :answered,
          order_by: [asc: e.at, asc: e.id],
          select: e.data
      )

  defp entries(work_item),
    do:
      Repo.all(
        from e in Entry,
          where: e.action == "work_item.answer" and e.subject_id == ^work_item.id,
          order_by: e.inserted_at,
          select: e.details
      )

  # The Explore stage's gate lists the scope's member as its one approver.
  defp approvers_only!(scope) do
    stages =
      Enum.map(Processes.current(scope.workspace).document["stages"], fn
        %{"id" => "st_r79kph11eg"} = stage ->
          put_in(stage, ["gate"], %{
            "kind" => "person",
            "approvers" => %{"members" => [scope.user.id]}
          })

        stage ->
          stage
      end)

    {:ok, _version} =
      Processes.save(scope, scope.workspace, %{
        "schema" => "qory.process/v1",
        "machine" => "default",
        "stages" => stages
      })
  end

  # A proposal at run 1 with the review comment c1 open, sent, and run 2 that asks
  # `question` and leaves c1 open.
  defp asked_after_proposal!(scope, question \\ "Which refund?") do
    work_item = proposed!(scope)
    {:ok, _} = WorkItems.review_comment(scope, work_item, 1, @comment)
    {:ok, _} = WorkItems.send_review_comments(scope, work_item, 1)
    end_run!(work_item, questions_result([question]))
  end

  defp proposed!(scope, message \\ "## What this is\n\nThe basket keeps the price.") do
    scope |> taken_in_fixture() |> end_run!(understood_result(%{"message" => message}))
  end

  # The newest run pushes a proposal, closes each open review comment with its reply, and
  # ends.
  defp revised!(work_item, message \\ "## What this is\n\nAgain.") do
    end_run!(work_item, fn run, registered ->
      push_result!(run, registered, understood_result(%{"message" => message}))
      reply_as_run!(run, registered)
    end)
  end

  # The input of the newest run of `work_item`, as a handover gives it.
  defp input!(work_item) do
    work_item = reload(work_item)
    run = %{domain: "software", target: %{system: "forge", path: "acme/shop"}}
    {:ok, inputs} = Inputs.explore(work_item, newest_run(work_item), run)
    inputs |> Jason.encode!() |> Jason.decode!()
  end

  describe "a review comment" do
    test "is written at the gate, checked, and queues no run", %{scope: scope} do
      work_item = proposed!(scope)

      assert WorkItems.review_comment(scope, work_item, 1, " \r\n ") ==
               {:error, {:invalid, %{comment: :blank}}}

      assert WorkItems.review_comment(scope, work_item, 1, String.duplicate("é", 2001)) ==
               {:error, {:invalid, %{comment: {:too_long, 2000}}}}

      assert WorkItems.review_comment(scope, work_item, 1, "a\u200Bb") ==
               {:error, {:invalid, %{comment: :characters}}}

      assert WorkItems.review_comment(scope, work_item, 1, %{"1" => @comment}) ==
               {:error, {:invalid, :form}}

      assert WorkItems.review_comment(scope, work_item, 2, @comment) == {:error, :stale}
      assert review_comments(work_item) == nil

      assert {:ok, %WorkItem{}} =
               WorkItems.review_comment(scope, work_item, 1, " #{@comment}\r\n")

      name = Inputs.person_name(scope.user.id)

      assert [
               %{
                 "id" => "c1",
                 "on" => %{"artifact" => "proposal", "version" => 1},
                 "text" => @comment,
                 "by" => %{"name" => ^name},
                 "at" => at,
                 "state" => "open"
               }
             ] = review_comments(work_item)

      assert at =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/
      assert runs(work_item) == [{1, 3, :ended}]
      assert WorkItems.explore(scope, reload(work_item)).status == :confirm

      data = %{
        "take_in" => 1,
        "attempt" => 1,
        "count" => 1,
        "comment" => true,
        "review_comment" => "c1"
      }

      assert answered_events(work_item) == [data]
      assert entries(work_item) == [data]

      assert [%{text: @comment, attempt: 1, version: 1, done_version: nil}] =
               WorkItems.explore(scope, reload(work_item)).comments

      # The version a member writes is the member's.
      assert [%{writer: :person}] =
               for(
                 a <- Apiary.Artifacts.list(work_item),
                 a.type == "review-comments",
                 v <- a.versions,
                 do: v
               )
    end

    test "is written while questions are open, and queues no run", %{scope: scope} do
      work_item = proposed!(scope)
      {:ok, _} = WorkItems.answer(scope, work_item, 1, @comment)
      work_item = end_run!(work_item, questions_result(["Which refund?"]))
      assert WorkItems.explore(scope, work_item).status == :questions

      assert {:ok, _} = WorkItems.review_comment(scope, work_item, 2, "Name the refund rule.")

      assert [
               %{"id" => "c1", "state" => "open"},
               %{
                 "id" => "c2",
                 "on" => %{"artifact" => "proposal", "version" => 1},
                 "text" => "Name the refund rule.",
                 "state" => "open"
               }
             ] = review_comments(work_item)

      assert runs(work_item) == [{1, 3, :ended}, {2, 3, :ended}]
      assert WorkItems.explore(scope, reload(work_item)).status == :questions
    end

    test "while a run runs, or before any proposal, is refused", %{scope: scope} do
      work_item = proposed!(scope)
      {:ok, _} = WorkItems.answer(scope, work_item, 1, @comment)
      assert runs(work_item) == [{1, 3, :ended}, {2, 3, :waiting}]

      assert WorkItems.review_comment(scope, work_item, 2, "Also this.") == {:error, :running}

      asked = scope |> taken_in_fixture() |> end_run!(questions_result(["Which basket?"]))
      assert WorkItems.review_comment(scope, asked, 1, "Also this.") == {:error, :not_waiting}
      assert review_comments(asked) == nil
    end

    test "a member not among the approvers the stage lists may not write one", %{scope: scope} do
      member = member_fixture(scope)
      approvers_only!(scope)
      work_item = proposed!(scope)

      assert WorkItems.review_comment(member.scope, work_item, 1, @comment) ==
               {:error, :not_approver}

      assert WorkItems.answer(member.scope, work_item, 1, @comment) == {:error, :not_approver}
      assert review_comments(work_item) == nil
      assert {:ok, _} = WorkItems.review_comment(scope, work_item, 1, @comment)
      [comment] = review_comments(work_item)

      # A push of the files is no way around the member actions: the member who is not an
      # approver cannot close the review comment with a reply in a run's name.
      forged = %{
        "review_comments" => [
          comment
          |> Map.put("state", "closed")
          |> Map.put("replies", [
            %{
              "text" => "Done.",
              "by" => %{"run" => 7},
              "at" => comment["at"],
              "outcome" => "changed"
            }
          ])
        ]
      }

      for push <- [
            &Apiary.Artifacts.push({:person, member.scope}, reload(work_item), &1, &2),
            &Apiary.Stages.add_version(member.scope, reload(work_item), &1, &2)
          ] do
        assert push.("review-comments", [ReviewComments.file(forged)]) ==
                 {:error, {:unknown_type, "review-comments"}}
      end

      assert [^comment] = review_comments(work_item)
    end
  end

  describe "send review comments" do
    test "at the gate queues the next run, which reads the open review comments", %{
      scope: scope
    } do
      work_item = proposed!(scope)
      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, @comment)
      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Name the refund rule.")

      assert {:ok, %WorkItem{}} = WorkItems.send_review_comments(scope, work_item, 1)

      assert runs(work_item) == [{1, 3, :ended}, {2, 3, :waiting}]
      assert WorkItems.explore(scope, reload(work_item)).status == :queued

      assert List.last(answered_events(work_item)) == %{
               "take_in" => 1,
               "attempt" => 1,
               "count" => 2,
               "review_comments" => ["c1", "c2"]
             }

      # The run reads them from the newest review comments it pulls, not from its input.
      assert [%{"state" => "open"}, %{"state" => "open"}] = review_comments(work_item)
      inputs = input!(work_item)
      assert inputs["run"] == %{"attempt" => 2}

      for member <- ~w(answers changes proposal facts solution),
          do: refute(Map.has_key?(inputs, member))

      # The run closes each with its reply, and its proposal is the next version.
      work_item = revised!(work_item)

      assert %{status: :confirm, run: %{attempt: 2, version: 2}} =
               explore = WorkItems.explore(scope, work_item)

      assert explore.run.proposal == %{message: "## What this is\n\nAgain."}

      assert [
               %{
                 "state" => "closed",
                 "replies" => [%{"by" => %{"run" => _}, "outcome" => "changed"}]
               },
               %{"state" => "closed"}
             ] = review_comments(work_item)

      assert [%{version: 1, done_version: 2, done_at: %DateTime{}}, %{done_version: 2}] =
               explore.comments
    end

    test "is refused with no review comment open, and where no proposal waits", %{
      scope: scope
    } do
      work_item = proposed!(scope)
      assert WorkItems.send_review_comments(scope, work_item, 1) == {:error, :not_waiting}

      {:ok, _} = WorkItems.answer(scope, work_item, 1, @comment)
      work_item = revised!(work_item)
      assert [%{"state" => "closed"}] = review_comments(work_item)
      assert WorkItems.send_review_comments(scope, work_item, 2) == {:error, :not_waiting}
      assert WorkItems.send_review_comments(scope, work_item, 1) == {:error, :stale}

      {:ok, _} = WorkItems.review_comment(scope, work_item, 2, "Name the refund rule.")
      work_item_queued = reload(work_item)
      assert {:ok, _} = WorkItems.send_review_comments(scope, work_item_queued, 2)
      assert WorkItems.send_review_comments(scope, work_item_queued, 2) == {:error, :stale}

      asked = scope |> taken_in_fixture() |> end_run!(questions_result(["Which basket?"]))
      assert WorkItems.send_review_comments(scope, asked, 1) == {:error, :not_waiting}
    end

    test "while questions wait queues the next run, and leaves the questions open", %{
      scope: scope
    } do
      work_item = asked_after_proposal!(scope)
      assert WorkItems.explore(scope, work_item).status == :questions
      {_version, questions} = Questions.newest(reload(work_item))
      assert [%{"id" => "q1", "state" => "open"}] = questions["questions"]

      assert {:ok, %WorkItem{}} = WorkItems.send_review_comments(scope, work_item, 2)

      assert runs(work_item) == [{1, 3, :ended}, {2, 3, :ended}, {3, 3, :waiting}]
      assert WorkItems.explore(scope, reload(work_item)).status == :queued

      # The queued run is the latest: a second send or an answer for it is running, and
      # one for the run before it is stale.
      assert WorkItems.send_review_comments(scope, work_item, 3) == {:error, :running}
      assert WorkItems.send_review_comments(scope, work_item, 2) == {:error, :stale}

      assert WorkItems.answer(scope, work_item, 3, %{"1" => "The full one."}) ==
               {:error, :running}

      assert WorkItems.answer(scope, work_item, 2, %{"1" => "The full one."}) == {:error, :stale}
      assert runs(work_item) == [{1, 3, :ended}, {2, 3, :ended}, {3, 3, :waiting}]

      data = %{"take_in" => 1, "attempt" => 2, "count" => 1, "review_comments" => ["c1"]}
      assert List.last(answered_events(work_item)) == data
      assert List.last(entries(work_item)) == data

      # Nothing is written to the questions: the newest version is the run's, unchanged.
      assert {_version, ^questions} = Questions.newest(reload(work_item))

      # The run reads the open review comment from the newest review comments, not from
      # its input, as from the gate.
      assert [%{"id" => "c1", "state" => "open"}] = review_comments(work_item)
      inputs = input!(work_item)
      assert inputs["run"] == %{"attempt" => 3}

      for member <- ~w(answers changes proposal facts solution review_comments),
          do: refute(Map.has_key?(inputs, member))

      # The run gives a proposal and closes c1, but q1 is still open: the questions come
      # first, so Explore stands at the questions.
      work_item = revised!(work_item)
      assert [%{"state" => "closed"}] = review_comments(work_item)

      assert %{status: :questions, comments: [%{version: 1, done_version: 2}]} =
               WorkItems.explore(scope, work_item)
    end

    test "while questions wait is refused with none open, for a non-approver, and stale", %{
      scope: scope
    } do
      member = member_fixture(scope)
      approvers_only!(scope)
      work_item = asked_after_proposal!(scope)

      assert WorkItems.send_review_comments(member.scope, work_item, 2) ==
               {:error, :not_approver}

      assert WorkItems.send_review_comments(scope, work_item, 1) == {:error, :stale}

      # Run 3 asks q2 and closes c1 with a reply that points at q2: no review comment is
      # open.
      {:ok, _} = WorkItems.answer(scope, work_item, 2, %{"1" => "The full one."})

      end_run!(work_item, fn run, registered ->
        push_result!(run, registered, questions_result(["Who decides?"]))
        reply_as_run!(run, registered, "asked", "q2")
      end)

      work_item = reload(work_item)
      assert WorkItems.explore(scope, work_item).status == :questions
      assert [%{"state" => "closed"}] = review_comments(work_item)
      assert WorkItems.send_review_comments(scope, work_item, 3) == {:error, :not_waiting}

      assert runs(work_item) == [{1, 3, :ended}, {2, 3, :ended}, {3, 3, :ended}]
      assert length(answered_events(work_item)) == 3
    end

    test "while questions wait at the take in's last run adds a run, as an answer does", %{
      scope: scope
    } do
      work_item = asked_after_proposal!(scope)
      {:ok, _} = WorkItems.answer(scope, work_item, 2, %{"1" => "The full one."})
      work_item = end_run!(work_item, questions_result(["Who decides?"]))

      assert %{status: :questions, run: %{attempt: 3, of: 3}} =
               WorkItems.explore(scope, work_item)

      assert [%{"id" => "c1", "state" => "open"}] = review_comments(work_item)
      assert {:ok, _} = WorkItems.send_review_comments(scope, work_item, 3)

      assert runs(work_item) ==
               [{1, 3, :ended}, {2, 3, :ended}, {3, 3, :ended}, {4, 4, :waiting}]

      assert input!(work_item)["run"] == %{"attempt" => 4}
    end

    test "while questions wait in a take in again with no proposal is refused", %{
      scope: scope
    } do
      ticket = backlog_ticket_fixture(scope)
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)

      work_item =
        work_item |> reload() |> end_run!(understood_result(%{"message" => "## Take in 1"}))

      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, @comment)
      {:ok, closed} = WorkItems.close(scope, work_item)

      {:ok, _again} =
        WorkItems.take_in_again(scope, ticket.public_id, %{owner_id: scope.user.id})

      work_item = closed |> reload() |> end_run!(questions_result(["Which refund?"]))

      assert %{take_in: 2, status: :questions, comments: []} =
               WorkItems.explore(scope, work_item)

      # Take in 1's review comment is still open, on take in 1's proposal.
      assert [%{"id" => "c1", "state" => "open"}] = review_comments(work_item)
      assert WorkItems.review_comment(scope, work_item, 1, "Also this.") == {:error, :not_waiting}
      assert WorkItems.send_review_comments(scope, work_item, 1) == {:error, :not_waiting}
      assert runs(work_item) == [{1, 3, :ended}, {1, 3, :ended}]
      assert length(answered_events(work_item)) == 1
    end

    test "Send answers carries the open review comments to the next run", %{scope: scope} do
      work_item = proposed!(scope)
      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, @comment)
      {:ok, _} = WorkItems.send_review_comments(scope, work_item, 1)

      # The second run asks, and leaves the review comment open.
      work_item = end_run!(work_item, questions_result(["Which refund?"]))
      {:ok, _} = WorkItems.review_comment(scope, work_item, 2, "Name the refund rule.")
      {:ok, _} = WorkItems.answer(scope, work_item, 2, %{"1" => "The full one."})

      assert runs(work_item) == [{1, 3, :ended}, {2, 3, :ended}, {3, 3, :waiting}]

      assert [%{"id" => "c1", "state" => "open"}, %{"id" => "c2", "state" => "open"}] =
               review_comments(work_item)

      work_item = revised!(work_item)
      assert [%{"state" => "closed"}, %{"state" => "closed"}] = review_comments(work_item)

      assert [%{done_version: 2}, %{done_version: 2}] =
               WorkItems.explore(scope, work_item).comments
    end
  end

  describe "a reply" do
    test "opens the review comment again, and queues no run", %{scope: scope} do
      work_item = proposed!(scope)
      {:ok, _} = WorkItems.answer(scope, work_item, 1, @comment)
      work_item = revised!(work_item)
      assert [%{"state" => "closed"}] = review_comments(work_item)

      assert {:ok, _} = WorkItems.reply(scope, work_item, 2, "c1", "Not yet: name the rule.")
      name = Inputs.person_name(scope.user.id)

      assert [
               %{
                 "state" => "open",
                 "replies" => [
                   %{"by" => %{"run" => _}},
                   %{"text" => "Not yet: name the rule.", "by" => %{"name" => ^name}} = reply
                 ]
               }
             ] = review_comments(work_item)

      refute Map.has_key?(reply, "outcome")
      assert runs(work_item) == [{1, 3, :ended}, {2, 3, :ended}]

      assert %{"review_comment" => "c1", "reply" => 2, "comment" => true} =
               List.last(answered_events(work_item))

      assert {:ok, _} = WorkItems.send_review_comments(scope, work_item, 2)
      assert runs(work_item) == [{1, 3, :ended}, {2, 3, :ended}, {3, 3, :waiting}]
    end

    test "to a review comment the document does not have, or with no text, is refused", %{
      scope: scope
    } do
      work_item = proposed!(scope)
      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, @comment)

      assert WorkItems.reply(scope, work_item, 1, "c9", "Not yet.") == {:error, :not_found}

      assert WorkItems.reply(scope, work_item, 1, "c1", " ") ==
               {:error, {:invalid, %{comment: :blank}}}

      assert [%{"state" => "open"} = comment] = review_comments(work_item)
      refute Map.has_key?(comment, "replies")
    end
  end

  describe "a member's name" do
    # The local part of the member's email address, which the name is, set to 201
    # characters over three lines with tabs and a line separator: as the format takes a
    # member's name, one line of at most 160 characters.
    defp long_name!(scope) do
      local = "  Ann\r\n\tExample\u2028" <> String.duplicate("é", 200)

      {1, _rows} =
        Repo.update_all(from(u in Apiary.Accounts.User, where: u.id == ^scope.user.id),
          set: [email: local <> "@example.com"]
        )

      "Ann Example " <> String.duplicate("é", 148)
    end

    test "is one line of 160 characters in a review comment and a reply", %{scope: scope} do
      work_item = proposed!(scope)
      name = long_name!(scope)
      assert String.length(name) == 160

      assert {:ok, _} = WorkItems.review_comment(scope, work_item, 1, @comment)
      assert [%{"by" => %{"name" => ^name}}] = review_comments(work_item)

      assert {:ok, _} = WorkItems.reply(scope, work_item, 1, "c1", "And name the rule.")
      assert [%{"replies" => [%{"by" => %{"name" => ^name}}]}] = review_comments(work_item)
    end

    test "is one line of 160 characters in an answer", %{scope: scope} do
      work_item = scope |> taken_in_fixture() |> end_run!(questions_result(["Which basket?"]))
      name = long_name!(scope)

      assert {:ok, _} = WorkItems.answer(scope, work_item, 1, %{"1" => "The small one."})

      assert {_version, %{"questions" => [%{"answer" => %{"by" => %{"name" => ^name}}}]}} =
               Apiary.Explore.Questions.newest(reload(work_item))
    end

    test "is unnamed member when nothing of it is left for one line", %{scope: scope} do
      work_item = scope |> taken_in_fixture() |> end_run!(questions_result(["Which basket?"]))

      {1, _rows} =
        Repo.update_all(from(u in Apiary.Accounts.User, where: u.id == ^scope.user.id),
          set: [email: " \t\u2028\u200B @example.com"]
        )

      assert {:ok, _} = WorkItems.answer(scope, work_item, 1, %{"1" => "The small one."})

      assert {_version,
              %{"questions" => [%{"answer" => %{"by" => %{"name" => "unnamed member"}}}]}} =
               Apiary.Explore.Questions.newest(reload(work_item))

      proposed = proposed!(scope)
      assert {:ok, _} = WorkItems.review_comment(scope, proposed, 1, @comment)
      assert [%{"by" => %{"name" => "unnamed member"}}] = review_comments(proposed)
    end
  end

  describe "a newest version that cannot be read" do
    # The stored copy of the version's one file moved away until the test ends, as a store
    # that cannot read it. Each document here has the member's name or a unique number, so
    # no other test stores the same content.
    defp unreadable!(version) do
      [file] = version.files
      {:ok, path} = Apiary.Artifacts.open_file(file)
      File.rename!(path, path <> ".away")
      on_exit(fn -> File.rename(path <> ".away", path) end)
    end

    test "is store_unavailable for a review comment, a reply and a send, which write nothing",
         %{scope: scope} do
      work_item = proposed!(scope)
      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, @comment)
      {version, _document} = ReviewComments.newest(reload(work_item))
      unreadable!(version)

      assert WorkItems.review_comment(scope, work_item, 1, "Refund at once.") ==
               {:error, :store_unavailable}

      assert WorkItems.reply(scope, work_item, 1, "c1", "Not yet.") ==
               {:error, :store_unavailable}

      assert WorkItems.send_review_comments(scope, work_item, 1) == {:error, :store_unavailable}

      assert WorkItems.answer(scope, work_item, 1, "Refund at once.") ==
               {:error, :store_unavailable}

      assert [%{number: 1}] = Apiary.Artifacts.versions(version.artifact)
      assert [_comment] = answered_events(work_item)
      assert runs(work_item) == [{1, 3, :ended}]
    end

    test "is store_unavailable for a send while questions wait, which writes nothing", %{
      scope: scope
    } do
      work_item = asked_after_proposal!(scope)
      {version, _document} = ReviewComments.newest(reload(work_item))
      unreadable!(version)

      assert WorkItems.send_review_comments(scope, work_item, 2) == {:error, :store_unavailable}

      assert length(answered_events(work_item)) == 2
      assert runs(work_item) == [{1, 3, :ended}, {2, 3, :ended}]
    end

    test "is store_unavailable for an answer, which writes nothing", %{scope: scope} do
      work_item =
        scope
        |> taken_in_fixture()
        |> end_run!(questions_result(["Which basket #{System.unique_integer([:positive])}?"]))

      {version, _document} = Apiary.Explore.Questions.newest(reload(work_item))
      unreadable!(version)

      assert WorkItems.answer(scope, work_item, 1, %{"1" => "The small one."}) ==
               {:error, :store_unavailable}

      assert [%{number: 1}] = Apiary.Artifacts.versions(version.artifact)
      assert answered_events(work_item) == []
      assert runs(work_item) == [{1, 3, :ended}]
    end
  end

  describe "the run's version" do
    # Pushes `document` as the review comments of `work_item`, as its newest run.
    defp push_review_comments(work_item, document) do
      run = newest_run(work_item)

      Apiary.Artifacts.push(
        {:run, run},
        reload(work_item),
        "review-comments",
        [ReviewComments.file(document)],
        stage_id: run.stage_id
      )
    end

    defp registered(work_item),
      do: Repo.get_by!(Apiary.Runs.Run, dispatch_run_id: newest_run(work_item).id)

    test "that changes a member's words is refused, and stores nothing", %{scope: scope} do
      work_item = proposed!(scope)
      # Sent at once, so the newest run is the next one, live.
      {:ok, _} = WorkItems.answer(scope, work_item, 1, @comment)
      [comment] = review_comments(work_item)

      assert push_review_comments(work_item, %{
               "review_comments" => [Map.put(comment, "text", "Refund at once.")]
             }) == {:error, {:invalid, {:kept, 0, :comment_changed}}}

      assert [^comment] = review_comments(work_item)
    end

    test "with 1.0 for version 1 and 13.0 for run 13 is taken, stored as 1 and 13", %{
      scope: scope
    } do
      work_item = proposed!(scope)
      {:ok, _} = WorkItems.answer(scope, work_item, 1, @comment)
      [comment] = review_comments(work_item)
      version = comment["on"]["version"]
      assert is_integer(version)

      end_run!(work_item, fn run, registered ->
        push_result!(run, registered, understood_result(%{"message" => "## Again\n\nIt."}))
        at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

        reply = %{
          "text" => "Changed the order.",
          "by" => %{"run" => registered.number * 1.0},
          "at" => at,
          "outcome" => "changed"
        }

        floats =
          comment
          |> put_in(["on", "version"], version * 1.0)
          |> Map.put("replies", [reply])
          |> Map.put("state", "closed")

        file = ReviewComments.file(%{"review_comments" => [floats]})
        assert file.binary =~ "#{version}.0"

        assert {:ok, stored} = push_review_comments(work_item, %{"review_comments" => [floats]})
        [stored_file] = stored.files
        {:ok, path} = Apiary.Artifacts.open_file(stored_file)

        assert %{"review_comments" => [%{"on" => %{"version" => ^version}} = kept]} =
                 path |> File.read!() |> Jason.decode!()

        assert [%{"by" => %{"run" => number}}] = kept["replies"]
        assert number === registered.number
      end)

      # The member's reply finds the review comment the run closed.
      assert {:ok, _} = WorkItems.reply(scope, work_item, 2, "c1", "Not yet: name the rule.")

      assert [
               %{
                 "state" => "open",
                 "on" => %{"version" => ^version},
                 "replies" => [_run, _member]
               }
             ] =
               review_comments(work_item)
    end

    test "an asked reply's question is the id of a question stored before the push", %{
      scope: scope
    } do
      work_item = proposed!(scope)
      {:ok, _} = WorkItems.answer(scope, work_item, 1, @comment)

      end_run!(work_item, fn run, registered ->
        assert {:error, {:invalid, {:kept, 0, :question_unknown}}} =
                 push_review_comments(work_item, reply_doc(work_item, registered, "q1"))

        # Its questions pushed first, the reply is taken.
        push_result!(run, registered, questions_result(["Which refund?"]))

        assert {:ok, _version} =
                 push_review_comments(work_item, reply_doc(work_item, registered, "q1"))
      end)

      assert [%{"state" => "closed", "replies" => [%{"outcome" => "asked", "question" => "q1"}]}] =
               review_comments(work_item)

      assert WorkItems.explore(scope, reload(work_item)).status == :questions
      assert registered(work_item).number > 0
    end

    test "numbers in a run's questions: 1e300 is refused, and the stored file stays within the limit",
         %{scope: scope} do
      work_item = proposed!(scope)
      {:ok, _} = WorkItems.answer(scope, work_item, 1, @comment)
      at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      # `n` open questions asked by run 1000, written `1e3`, each with `context` of
      # `pad` characters, as the raw bytes of a questions file.
      raw = fn n, pad ->
        questions =
          for i <- 1..n do
            %{
              "id" => "q#{i}",
              "question" => "Which basket #{i}?",
              "context" => String.duplicate("a", pad),
              "options" => [],
              "state" => "open",
              "asked" => %{"run" => 1000, "at" => at}
            }
          end

        %{"questions" => questions}
        |> Jason.encode!()
        |> String.replace(~s("run":1000), ~s("run":1e3))
      end

      push = fn run, bytes ->
        Apiary.Artifacts.push(
          {:run, run},
          reload(work_item),
          "questions",
          [%{filename: "questions.json", content_type: "application/json", binary: bytes}],
          stage_id: run.stage_id
        )
      end

      end_run!(work_item, fn run, registered ->
        # A number past every run number, which the format takes as an integer: refused
        # by the check, never written out in 301 digits.
        huge = String.replace(raw.(1, 10), ~s("run":1e3), ~s("run":1e300))

        assert push.(run, huge) == {:error, {:invalid, {:kept, 0, :asked_run}}}
        assert Apiary.Explore.Questions.newest(reload(work_item)) == nil

        {1, _rows} =
          Repo.update_all(from(r in Apiary.Runs.Run, where: r.id == ^registered.id),
            set: [number: 1000]
          )

        # 100 questions whose file is 50 bytes within the limit as it came, and 50 over
        # once each 1e3 is 1000.
        limit = 1_048_576
        target = limit - 50
        pad = div(target - byte_size(raw.(100, 0)), 100)
        bytes = raw.(100, pad)
        extra = String.duplicate("a", target - byte_size(bytes))
        bytes = String.replace(bytes, ~s("context":"), ~s("context":"#{extra}), global: false)
        assert byte_size(bytes) == target

        assert push.(run, bytes) == {:error, {:too_large, limit}}
        assert Apiary.Explore.Questions.newest(reload(work_item)) == nil

        # A small one is stored with 1000.
        assert {:ok, version} = push.(run, raw.(1, 10))
        [file] = version.files
        {:ok, path} = Apiary.Artifacts.open_file(file)
        stored = File.read!(path)
        assert stored =~ ~s("run":1000)
        assert byte_size(stored) == file.size
      end)
    end

    test "a version of the questions that changes a member's answer is refused", %{
      scope: scope
    } do
      work_item = scope |> taken_in_fixture() |> end_run!(questions_result(["Which basket?"]))
      {:ok, _} = WorkItems.answer(scope, work_item, 1, %{"1" => "The small one."})

      {_version, %{"questions" => [answered]}} =
        Apiary.Explore.Questions.newest(reload(work_item))

      changed = put_in(answered, ["answer", "note"], "The large one.")
      run = newest_run(work_item)

      assert Apiary.Artifacts.push(
               {:run, run},
               reload(work_item),
               "questions",
               [Apiary.Explore.Questions.file(%{"questions" => [changed]})],
               stage_id: run.stage_id
             ) == {:error, {:invalid, {:kept, 0, :answer_changed}}}
    end
  end

  # The newest review comments with the run's reply, outcome `asked` and `question`, added
  # to each open review comment, which it closes.
  defp reply_doc(work_item, registered, question) do
    at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    reply = %{
      "text" => "Asked who decides.",
      "by" => %{"run" => registered.number},
      "at" => at,
      "outcome" => "asked",
      "question" => question
    }

    %{
      "review_comments" =>
        for comment <- review_comments(work_item) do
          comment |> Map.put("replies", [reply]) |> Map.put("state", "closed")
        end
    }
  end

  describe "today's form" do
    test "a text at the gate writes a review comment and sends it in one move", %{
      scope: scope
    } do
      work_item = proposed!(scope)

      assert WorkItems.answer(scope, work_item, 1, " \r\n ") ==
               {:error, {:invalid, %{comment: :blank}}}

      assert WorkItems.answer(scope, work_item, 1, %{"1" => @comment}) ==
               {:error, {:invalid, :form}}

      assert {:ok, _} = WorkItems.answer(scope, work_item, 1, @comment)
      assert [%{"id" => "c1", "text" => @comment, "state" => "open"}] = review_comments(work_item)
      assert runs(work_item) == [{1, 3, :ended}, {2, 3, :waiting}]

      assert answered_events(work_item) == [
               %{
                 "take_in" => 1,
                 "attempt" => 1,
                 "count" => 1,
                 "comment" => true,
                 "review_comment" => "c1"
               }
             ]
    end

    test "at the take in's last run, a text adds a run", %{scope: scope} do
      work_item = taken_in_fixture(scope) |> end_run!(questions_result(["Which basket?"]))
      {:ok, _} = WorkItems.answer(scope, work_item, 1, %{"1" => "The small one."})
      work_item = end_run!(work_item, questions_result(["Which sale?"]))
      {:ok, _} = WorkItems.answer(scope, work_item, 2, %{"1" => "The spring one."})
      work_item = end_run!(work_item, understood_result())

      assert %{status: :confirm, run: %{attempt: 3, of: 3}} =
               WorkItems.explore(scope, work_item)

      assert {:ok, _} = WorkItems.answer(scope, work_item, 3, @comment)

      assert runs(work_item) ==
               [{1, 3, :ended}, {2, 3, :ended}, {3, 3, :ended}, {4, 4, :waiting}]

      assert input!(work_item)["run"] == %{"attempt" => 4}
    end
  end
end

defmodule Apiary.WorkItems.ReviewCommentsOffTest do
  # With the workflow model off, no run pushes an artifact: the run API answers 404
  # (`ApiaryWeb.Contract.RunApi.Controller`). A run ends with no result, and no review
  # comment or answer can be given.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import Apiary.StagesFixtures

  alias Apiary.{Stages, WorkItems}

  @moduletag needs: :factory
  @moduletag with_features: Apiary.Features.all() -- [:workflow_model]

  test "a run ends with no result; a review comment and an answer are refused" do
    %{scope: scope} = sign_up_fixture()
    refute Stages.on?()
    work_item = scope |> taken_in_fixture() |> end_run!(nil)

    assert WorkItems.explore(scope, work_item).status == :no_result

    assert WorkItems.review_comment(scope, work_item, 1, "Also this.") ==
             {:error, :not_waiting}

    assert WorkItems.answer(scope, work_item, 1, "Also this.") == {:error, :not_waiting}
    assert WorkItems.send_review_comments(scope, work_item, 1) == {:error, :not_waiting}
    assert Apiary.Artifacts.list(work_item) == []
  end
end
