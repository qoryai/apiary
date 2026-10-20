defmodule ApiaryWeb.WorkItemLive.ShowTest do
  # A work item's page (`ApiaryWeb.WorkItemLive.Show`): its tabs and the edit page, not
  # found for a number no work item of the workspace has; what a reader does there (the
  # answers, Confirm as it stands and with changes, Decline, Close, Run Explore again),
  # each refused without words where the page read an earlier state, and the form's
  # errors under its fields; the page read again on a message of its work item, with the
  # scope first, as after a refused action; people by the short name of their account,
  # and a deleted account as a former member; a run's link only where the reader may read
  # the runs of the workspace it ran in, after the work item moved; and a close by the
  # instance.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Edition, EditionStubs, Repo, WorkItems}
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  setup :register_and_log_in_user

  defp page(scope, number, tail \\ ""),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}" <> tail

  # A work item as a take in leaves it: its first run waiting in the queue.
  defp queued(scope) do
    work_item = work_item_fixture(scope)
    explore_run_fixture(work_item, state: :waiting)
    work_item
  end

  defp asked(scope) do
    work_item = work_item_fixture(scope)
    %{run: run} = explore_run_fixture(work_item, result: questions_result())
    {work_item, run}
  end

  defp proposed(scope) do
    work_item = work_item_fixture(scope)
    %{run: run} = explore_run_fixture(work_item, result: understood_result())
    {work_item, run}
  end

  defp state(work_item), do: Repo.get!(WorkItem, work_item.id).state

  describe "the tabs" do
    test "Ticket, Explore and the Thread, with the header, the step card and Details", %{
      conn: conn,
      scope: scope
    } do
      work_item = queued(scope)

      {:ok, view, html} = live(conn, page(scope, work_item.number))
      assert html =~ "The checkout keeps the old price"
      assert has_element?(view, "#work-item-head-title")
      assert has_element?(view, "#work-item-step")
      assert has_element?(view, "#work-item-details")
      assert has_element?(view, "#work-item-ticket-text")
      assert render(view) =~ "The basket shows the price from before the sale."

      view |> element("#work-item-tabs a", "Explore") |> render_click()
      assert_patch(view, page(scope, work_item.number, "/explore"))
      assert has_element?(view, "#work-item-explore")

      view |> element("#work-item-tabs a", "Thread") |> render_click()
      assert_patch(view, page(scope, work_item.number, "/thread"))
      assert has_element?(view, "#work-item-thread-ev-1")
      assert render(view) =~ "You took this in from"
    end

    test "the ticket's title as a page shows it, and none where nothing is left", %{
      conn: conn,
      scope: scope
    } do
      work_item = queued(scope)

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [title: "Totals \u202Eoff\u202C by a cent"]
      )

      {:ok, view, html} = live(conn, page(scope, work_item.number))
      refute html =~ "\u202E"
      assert has_element?(view, "#work-item-head-title bdi", "Totals off by a cent")

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [title: "\u202E\u200B"]
      )

      send(view.pid, {:work_items_changed, [work_item.public_id]})
      refute has_element?(view, "#work-item-head-title bdi")

      assert has_element?(
               view,
               "#work-item-head-title",
               "#" <> Integer.to_string(work_item.number)
             )
    end

    test "a title of only whitespace or invisible characters is no title: the header says its number",
         %{conn: conn, scope: scope} do
      for title <- ["\u00A0", "\u202E\u200B"] do
        work_item = queued(scope)
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id), set: [title: title])

        {:ok, view, _html} = live(conn, page(scope, work_item.number))
        refute has_element?(view, "#work-item-head-title bdi")
        assert has_element?(view, "#work-item-head-title", "##{work_item.number}")
      end
    end

    test "a take in whose first run is not written yet reads as queued, on every tab", %{
      conn: conn,
      scope: scope
    } do
      work_item = work_item_fixture(scope)

      for tail <- ["", "/explore", "/thread"] do
        {:ok, view, _html} = live(conn, page(scope, work_item.number, tail))
        assert has_element?(view, "#work-item-step .q-wi-badge", "Queued")
      end

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))
      assert has_element?(view, "#work-item-explore-run", "Run 1 of 3")
      assert has_element?(view, "#work-item-explore-run", "Queued")
    end

    test "a number no work item of the workspace has is not found", %{conn: conn, scope: scope} do
      for number <- ["99", "0", "x", "1" <> String.duplicate("0", 30)] do
        assert_raise ApiaryWeb.NotFound, fn -> live(conn, page(scope, number)) end
      end

      %{scope: other} = sign_up_fixture()
      theirs = queued(other)

      assert get(conn, ~p"/#{other.organisation}/#{other.workspace}/work/#{theirs.number}").status ==
               404
    end
  end

  describe "the answers" do
    test "the form sends the answers alone, and the next run is queued", %{
      conn: conn,
      scope: scope
    } do
      {work_item, _run} = asked(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))

      view
      |> element("#work-item-explore-questions-form")
      |> render_submit(%{
        "number" => Integer.to_string(work_item.number),
        "answers" => %{"1" => "The one at checkout.", "2" => "The spring sale.", "x" => "y"},
        "_unused_answers[1]" => "",
        "other" => "z"
      })

      assert [%{answer: "The one at checkout."}, %{answer: "The spring sale."}] =
               Repo.all(
                 from a in Apiary.WorkItems.Answer,
                   where: a.work_item_id == ^work_item.id,
                   order_by: a.position
               )

      assert has_element?(view, "#work-item-step .q-wi-badge", "Queued")
    end

    test "an empty answer is marked under its field", %{conn: conn, scope: scope} do
      {work_item, _run} = asked(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))

      html =
        view
        |> element("#work-item-explore-questions-form")
        |> render_submit(%{
          "number" => Integer.to_string(work_item.number),
          "answers" => %{"1" => "The one at checkout.", "2" => "  "}
        })

      assert html =~ "Answer this question. If nobody knows, say so: Qory reads that too."
      assert has_element?(view, "#work-item-explore-questions-answer-2[aria-invalid]")
      assert state(work_item) == :exploring
      assert Repo.aggregate(Apiary.WorkItems.Answer, :count) == 0
    end

    test "an answer that is not text is refused with the form's errors, and nothing is written",
         %{conn: conn, scope: scope} do
      {work_item, _run} = asked(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))

      for forged <- [%{"a" => "b"}, ["x"], 1.5, true, 7, nil] do
        html =
          render_hook(view, "answer", %{
            "number" => Integer.to_string(work_item.number),
            "answers" => %{"1" => forged, "2" => "The spring sale."}
          })

        assert html =~ "Answer this question. If nobody knows, say so: Qory reads that too."
        assert has_element?(view, "#work-item-explore-questions-answer-1[aria-invalid]")
        assert has_element?(view, "#work-item-explore-questions-answer-2", "The spring sale.")
      end

      render_hook(view, "answer", %{
        "number" => Integer.to_string(work_item.number),
        "answers" => "x"
      })

      assert Repo.aggregate(Apiary.WorkItems.Answer, :count) == 0
      assert state(work_item) == :exploring
    end

    test "answers sent after another member answered are refused without words", %{
      conn: conn,
      scope: scope
    } do
      {work_item, _run} = asked(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))

      {:ok, _} = WorkItems.answer(scope, work_item, 1, %{"1" => "First.", "2" => "Second."})

      html =
        render_hook(view, "answer", %{
          "number" => Integer.to_string(work_item.number),
          "answers" => %{"1" => "Late.", "2" => "Late."}
        })

      refute html =~ "Late."
      refute html =~ "Answer this question"
      assert has_element?(view, "#work-item-step .q-wi-badge", "Queued")
      assert Repo.aggregate(Apiary.WorkItems.Answer, :count) == 2
    end
  end

  describe "Confirm" do
    test "as it stands, from the step card", %{conn: conn, scope: scope} do
      {work_item, _run} = proposed(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      view |> element("#work-item-step-confirm") |> render_click()
      assert has_element?(view, "#work-item-step .q-wi-badge", "Ready")
      assert %{changes: changes} = Apiary.WorkItems.Explore.confirmation(work_item.id, 1)
      assert changes == %{}
    end

    test "with changes, from the edit page, back on Explore's tab", %{conn: conn, scope: scope} do
      {work_item, _run} = proposed(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore/edit"))

      assert has_element?(view, "#work-item-edit-form")
      refute has_element?(view, "#work-item-step")

      view
      |> form("#work-item-edit-form", %{"approach" => "Read the price from the catalogue."})
      |> render_submit()

      assert_patch(view, page(scope, work_item.number, "/explore"))

      assert %{changes: %{"approach" => "Read the price from the catalogue."}} =
               Apiary.WorkItems.Explore.confirmation(work_item.id, 1)
    end

    test "a field left empty is marked under it, and nothing is confirmed", %{
      conn: conn,
      scope: scope
    } do
      {work_item, _run} = proposed(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore/edit"))

      view |> form("#work-item-edit-form", %{"approach" => " "}) |> render_submit()

      assert has_element?(view, "#work-item-edit-approach[aria-invalid]")
      refute Apiary.WorkItems.Explore.confirmation(work_item.id, 1)
    end

    test "the edit page is Explore's tab where nothing waits to be confirmed", %{
      conn: conn,
      scope: scope
    } do
      {work_item, _run} = asked(scope)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, page(scope, work_item.number, "/explore/edit"))

      assert to == page(scope, work_item.number, "/explore")
    end
  end

  describe "Decline, Close and Run Explore again" do
    test "Decline asks in place, then declines", %{conn: conn, scope: scope} do
      {work_item, _run} = proposed(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      view |> element("#work-item-step-decline") |> render_click()
      assert has_element?(view, "#work-item-step-decline-question")
      view |> element("#work-item-step-decline-go") |> render_click()

      assert state(work_item) == :declined
      assert has_element?(view, "#work-item-ended")
    end

    test "Close asks under the header, then closes", %{conn: conn, scope: scope} do
      work_item = queued(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      view |> element("#work-item-head-close") |> render_click()
      assert has_element?(view, "#work-item-close")
      view |> element("#work-item-close-go") |> render_click()

      assert state(work_item) == :closed
    end

    test "Run Explore again after a run without a result", %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, run: %{exit_state: "failed", state: "failed"})
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      view |> element("#work-item-step-again") |> render_click()
      assert has_element?(view, "#work-item-step .q-wi-badge", "Queued")
    end

    test "an event for another number does nothing", %{conn: conn, scope: scope} do
      work_item = queued(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      render_hook(view, "close", %{"number" => "#{work_item.number + 1}"})
      render_hook(view, "close", %{"number" => "#{work_item.number}x"})
      assert state(work_item) == :exploring
    end
  end

  describe "a run that ended at its handover, before it started" do
    test "Explore's tab says what to fix and why; neither tab says the run ended with an error",
         %{conn: conn, scope: scope} do
      for {cause, body} <- [
            {:variables_invalid,
             "Fix the variables in the workspace's settings, then run Explore again. One of the run's variables breaks a variable rule."},
            {:ticket_gone,
             "Take the ticket in again from the Backlog, if it is still there. The work item's ticket is no longer in Qory Apiary."},
            {:inputs_invalid,
             "Shorten or correct the ticket, then run Explore again. A value in the ticket or the work item breaks a rule for the agent's input, such as the size limit."}
          ] do
        work_item = work_item_fixture(scope)
        explore_run_fixture(work_item, end_cause: cause)

        {:ok, view, html} = live(conn, page(scope, work_item.number, "/explore"))

        assert has_element?(
                 view,
                 "#work-item-explore-none-h",
                 "The run ended before it started."
               )

        assert has_element?(view, "#work-item-explore-none p", body)
        refute html =~ "ended with an error"
        refute html =~ "Its last result was an error"

        {:ok, _view, html} = live(conn, page(scope, work_item.number, "/thread"))
        refute html =~ "ended with an error"
      end
    end

    test "a run whose last result was an error still says so", %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, result: {:data, %{"is_error" => true, "result" => "No"}})

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))
      assert has_element?(view, "#work-item-explore-none-h", "The run ended with an error.")
    end
  end

  describe "live" do
    test "a change to the work item is drawn; one to another is not read", %{
      conn: conn,
      scope: scope
    } do
      work_item = queued(scope)
      other = queued(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      refute has_element?(view, "#work-item-ended")

      # Closed in the database without a word to the page: only a message that names it
      # makes the page read it again.
      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [state: :closed, closed_at: DateTime.utc_now(), closed_by_id: scope.user.id]
      )

      send(view.pid, {:work_items_changed, [other.public_id]})
      refute has_element?(view, "#work-item-ended")

      send(view.pid, {:work_items_changed, [work_item.public_id]})
      assert has_element?(view, "#work-item-ended")
    end

    test "a work item moved to another workspace is not found here", %{conn: conn, scope: scope} do
      work_item = queued(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      other = workspace_fixture(scope.organisation, "Second")

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [workspace_id: other.id]
      )

      send(view.pid, {:work_items_changed, [work_item.public_id]})

      assert_redirect(view, page(scope, work_item.number))
    end

    test "a member removed behind the page's back is sent away on a message of the work item",
         %{scope: scope} do
      work_item = queued(scope)
      member = member_fixture(scope, :member)

      {:ok, view, _html} =
        live(log_in_user(build_conn(), member.user), page(scope, work_item.number))

      # Removed without a word to the page: the scope is read again before the work item.
      Repo.delete!(member.membership)

      send(view.pid, {:work_items_changed, [work_item.public_id]})
      assert_redirect(view, ~p"/")
    end

    test "a member removed behind the page's back is sent away after a refused action",
         %{scope: scope} do
      work_item = queued(scope)
      member = member_fixture(scope, :member)

      {:ok, view, _html} =
        live(log_in_user(build_conn(), member.user), page(scope, work_item.number))

      Repo.delete!(member.membership)

      render_hook(view, "close", %{"number" => "#{work_item.number}"})
      assert_redirect(view, ~p"/")
      assert state(work_item) == :exploring
    end
  end

  describe "people" do
    defp thread_path(scope, work_item), do: page(scope, work_item.number, "/thread")

    defp author(view, comment) do
      view
      |> element("#work-item-thread-#{comment.public_id}")
      |> render()
    end

    test "a comment's author is their first letter, the address its hint", %{
      conn: conn,
      scope: scope
    } do
      work_item = queued(scope)
      member = member_fixture(scope, :member)
      {:ok, comment} = WorkItems.comment(member.scope, work_item, "Seen on staging")

      {:ok, view, _html} = live(conn, thread_path(scope, work_item))
      letter = String.upcase(String.first(member.user.email))
      dom = "#work-item-thread-#{comment.public_id}"

      assert has_element?(view, ~s{#{dom} > abbr[data-tip="#{member.user.email}"][tabindex="0"]})
      assert has_element?(view, "#{dom} > abbr > span[aria-hidden=true]", letter)
      assert has_element?(view, "#{dom} > abbr > .sr-only", member.user.email)
      refute has_element?(view, "#{dom} .q-wi-box-h b")
    end

    defp owner(view), do: view |> element("#work-item-details-owner") |> render()

    test "a person removed from the organisation is named by their account", %{
      conn: conn,
      scope: scope
    } do
      member = member_fixture(scope, :member)
      work_item = work_item_fixture(scope, owner_id: member.user.id)
      explore_run_fixture(work_item, state: :waiting)
      {:ok, comment} = WorkItems.comment(member.scope, work_item, "Seen on staging")
      Repo.delete!(member.membership)

      {:ok, view, _html} = live(conn, thread_path(scope, work_item))
      short = Apiary.Accounts.User.short_name(member.user.email)
      line = author(view, comment)
      assert line =~ short
      refute line =~ "Former member"
      assert owner(view) =~ short
      refute owner(view) =~ "Former member"
    end

    test "a deleted account is a former member", %{conn: conn, scope: scope} do
      member = member_fixture(scope, :member)
      work_item = work_item_fixture(scope, owner_id: member.user.id)
      explore_run_fixture(work_item, state: :waiting)
      {:ok, comment} = WorkItems.comment(member.scope, work_item, "Seen on staging")
      {:ok, _deleted} = Apiary.Accounts.delete_user(member.user)

      {:ok, view, _html} = live(conn, thread_path(scope, work_item))
      short = Apiary.Accounts.User.short_name(member.user.email)
      line = author(view, comment)
      assert line =~ "Former member"
      refute line =~ short
      assert owner(view) =~ "Former member"
      refute owner(view) =~ short
    end

    test "a person who is not a member of the organisation is named by their account", %{
      conn: conn,
      scope: scope
    } do
      user = Apiary.AccountsFixtures.user_fixture()
      work_item = work_item_fixture(scope, owner_id: user.id)
      explore_run_fixture(work_item, state: :waiting)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert owner(view) =~ Apiary.Accounts.User.short_name(user.email)
      refute owner(view) =~ "Former member"
    end
  end

  describe "a run's link, after the work item moved" do
    setup %{scope: scope} do
      :ok = Edition.put_test_stub(EditionStubs.MembersReachNamed)
      owner = scope
      here = owner.workspace
      there = workspace_fixture(owner.organisation, "There")
      {work_item, run} = asked(owner)
      {:ok, _} = WorkItems.answer(owner, work_item, 1, %{"1" => "At checkout.", "2" => "Spring."})

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [workspace_id: there.id]
      )

      %{user: member} = member_fixture(owner, :member)
      %{here: here, there: there, work_item: work_item, run: run, member: member}
    end

    test "to the run's page where the reader reads the workspace it ran in", ctx do
      EditionStubs.MembersReachNamed.put([ctx.here.id, ctx.there.id])
      conn = log_in_user(ctx.conn, ctx.member)
      org = ctx.scope.organisation

      {:ok, view, html} =
        live(conn, ~p"/#{org}/#{ctx.there}/work/#{ctx.work_item.number}/explore")

      href = ~p"/#{org}/#{ctx.here}/runs/#{ctx.run.public_id}"
      assert has_element?(view, ~s(a[href="#{href}"]))
      assert html =~ "At checkout."
    end

    test "its short id alone where the reader reads only the workspace it is in now", ctx do
      EditionStubs.MembersReachNamed.put([ctx.there.id])
      conn = log_in_user(ctx.conn, ctx.member)
      org = ctx.scope.organisation

      {:ok, view, html} =
        live(conn, ~p"/#{org}/#{ctx.there}/work/#{ctx.work_item.number}/explore")

      short = String.slice(ctx.run.public_id, 0, 11)
      refute has_element?(view, ~s(a[href*="/runs/"]))
      assert has_element?(view, ".q-wi-run-id", short)
      assert html =~ "At checkout."

      {:ok, thread, _html} =
        live(conn, ~p"/#{org}/#{ctx.there}/work/#{ctx.work_item.number}/thread")

      refute has_element?(thread, ~s(a[href*="/runs/"]))
      assert has_element?(thread, ".q-wi-run-id", short)
      assert render(thread) =~ "At checkout."
    end
  end

  describe "a close by the instance" do
    defp instance_close!(work_item, reason) do
      {:ok, _queues} =
        Repo.transact(fn ->
          locked = Repo.one!(from w in WorkItem, where: w.id == ^work_item.id, lock: "FOR UPDATE")
          WorkItems.close_locked([locked], {:instance, reason}, DateTime.utc_now())
        end)
    end

    test "when its integration was removed, every tab says so", %{conn: conn, scope: scope} do
      work_item = queued(scope)
      instance_close!(work_item, "adapter_removed")

      {:ok, view, html} = live(conn, page(scope, work_item.number))
      assert html =~ "when its integration was removed."
      assert has_element?(view, "#work-item-details-ended")

      {:ok, _view, thread} = live(conn, page(scope, work_item.number, "/thread"))
      assert thread =~ "Closed when its integration was removed"
    end

    test "for a reason without words, nothing names who closed it, and nothing fails", %{
      conn: conn,
      scope: scope
    } do
      work_item = queued(scope)
      instance_close!(work_item, "another_reason")

      for tail <- ["", "/explore", "/thread"] do
        {:ok, _view, html} = live(conn, page(scope, work_item.number, tail))
        refute html =~ "integration was removed"
        refute html =~ "another_reason"
      end
    end
  end
end
