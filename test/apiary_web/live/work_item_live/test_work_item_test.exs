defmodule ApiaryWeb.WorkItemLive.TestWorkItemTest do
  # A test work item (`Apiary.WorkItems.take_in_test/2`) on the pages: the Work items list
  # shows it with its number and the mark Test, and its page opens on Explore's tab with
  # its run, as for any work item, with no ticket, no integration and no Take in again;
  # a work item taken in from a ticket stays as it was.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.WorkItemsFixtures

  alias Apiary.{Repo, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  @line "Hello! Where are you running?"

  setup :register_and_log_in_user

  defp list(scope), do: ~p"/#{scope.organisation}/#{scope.workspace}/work"

  defp page(scope, number, tail \\ ""),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}" <> tail

  defp test_item!(scope) do
    {:ok, work_item} = WorkItems.take_in_test(scope, @line)
    work_item
  end

  # The test work item with its queued run replaced by one written as `opts` say.
  defp ran!(scope, opts) do
    work_item = test_item!(scope)
    Repo.delete_all(from r in DispatchRun, where: r.work_item_id == ^work_item.id)
    %{run: run} = explore_run_fixture(work_item, opts)
    {work_item, run}
  end

  defp state(work_item), do: Repo.get!(WorkItem, work_item.id).state

  # No part of the page names a ticket, its label or Take in again in its words.
  defp no_ticket!(view) do
    for part <- ~w(#work-item-head #work-item-step #work-item-details #work-item-explore),
        words <- [~r/ticket/i, ~r/label/i, ~r/Take in again/] do
      refute has_element?(view, part, words)
    end
  end

  describe "the Work items list" do
    test "shows a test work item with its number, its line and the mark Test", %{
      conn: conn,
      scope: scope
    } do
      test_item = test_item!(scope)
      listed = work_item_fixture(scope)

      {:ok, view, _html} = live(conn, list(scope))

      row = "#work-item-#{test_item.public_id}"
      assert has_element?(view, "#{row} .q-wl-no", "##{test_item.number}")
      assert has_element?(view, "#{row} .q-wl-ttl b", @line)
      assert has_element?(view, "#{row} .q-wl-ttl .badge", "Test")
      refute has_element?(view, "#{row} .q-bl-tile")

      assert has_element?(
               view,
               "#{row} a[href='#{page(scope, test_item.number)}']"
             )

      # A work item taken in from a ticket keeps its integration's mark and no Test.
      other = "#work-item-#{listed.public_id}"
      assert has_element?(view, "#{other} .q-bl-tile")
      refute has_element?(view, "#{other} .badge")
    end
  end

  describe "its page" do
    test "opens on Explore's tab, with the mark Test and no Ticket tab", %{
      conn: conn,
      scope: scope
    } do
      test_item = test_item!(scope)

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, page(scope, test_item.number))
      assert to == page(scope, test_item.number, "/explore")

      {:ok, view, _html} = live(conn, page(scope, test_item.number, "/explore"))

      assert has_element?(view, "#work-item-head-title", @line)
      assert has_element?(view, "#work-item-head-title .badge", "Test")
      refute has_element?(view, "#work-item-head .q-wi-ref")
      refute has_element?(view, "#work-item-tabs a", "Ticket")
      assert has_element?(view, "#work-item-tabs a", "Explore")
      assert has_element?(view, "#work-item-tabs a", "Thread")

      # Its first run waits, and the person who started it may undo it until it starts.
      assert has_element?(view, "#work-item-step .q-wi-badge", "Queued")

      assert has_element?(
               view,
               "#work-item-step-undo-line",
               "Until a run starts, you can undo this."
             )

      assert has_element?(view, "#work-item-step", "Qory answers the line when the run starts.")
      assert has_element?(view, "#work-item-explore-wait", "It answers the line.")
      refute has_element?(view, "#work-item-explore", "the code")
      no_ticket!(view)

      # Details: no ticket and no collection; the line is its first instruction.
      refute has_element?(view, "#work-item-details-ticket")
      refute has_element?(view, "#work-item-details-repository")
      assert has_element?(view, "#work-item-details-instruction", @line)
    end

    test "shows its run, with a link to the run's page, and its result", %{
      conn: conn,
      scope: scope
    } do
      {test_item, run} = ran!(scope, run: %{exit_state: "failed", state: "failed"})

      {:ok, view, _html} = live(conn, page(scope, test_item.number, "/explore"))

      run_path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.public_id}"
      assert has_element?(view, "#work-item-details-runs a[href='#{run_path}']")
      assert has_element?(view, "#work-item-step .q-wi-badge", "No result")
      assert has_element?(view, "#work-item-step-again")
      refute has_element?(view, "#work-item-ended-again")
      no_ticket!(view)

      view |> element("#work-item-step-again") |> render_click()
      assert has_element?(view, "#work-item-step .q-wi-badge", "Queued")
    end

    test "its Thread says who started the test run, with no ticket", %{
      conn: conn,
      scope: scope
    } do
      test_item = test_item!(scope)

      {:ok, view, _html} = live(conn, page(scope, test_item.number, "/thread"))

      assert has_element?(view, "#work-item-thread", "You started a test run")
      refute has_element?(view, "#work-item-thread .q-bl-tile")
      assert has_element?(view, "#work-item-thread", "First instruction: #{@line}")
    end

    test "Close asks with no ticket in its words, then closes, with no Take in again", %{
      conn: conn,
      scope: scope
    } do
      test_item = test_item!(scope)
      {:ok, view, _html} = live(conn, page(scope, test_item.number, "/explore"))

      view |> element("#work-item-head-close") |> render_click()
      assert has_element?(view, "#work-item-close", "Closing ends the work on it in Qory Apiary.")
      refute has_element?(view, "#work-item-close", "label")

      view |> element("#work-item-close-go") |> render_click()

      assert state(test_item) == :closed
      assert has_element?(view, "#work-item-ended", "You closed this work item")
      refute has_element?(view, "#work-item-ended-again")
    end

    test "Decline asks with no ticket in its words, then declines", %{
      conn: conn,
      scope: scope
    } do
      {test_item, _run} = ran!(scope, result: questions_result())
      {:ok, view, _html} = live(conn, page(scope, test_item.number, "/explore"))

      assert has_element?(
               view,
               "#work-item-explore-questions",
               "Qory runs Explore again from the start, with the line and the answers of this take in."
             )

      refute has_element?(view, "#work-item-explore-questions", "its comments")

      view |> element("#work-item-step-decline") |> render_click()

      assert has_element?(
               view,
               "#work-item-step-decline",
               "The work item stays in Qory Apiary, declined."
             )

      refute has_element?(view, "#work-item-step-decline", "label")

      view |> element("#work-item-step-decline-go") |> render_click()

      assert state(test_item) == :declined
      refute has_element?(view, "#work-item-ended-again")
    end
  end

  describe "a work item taken in from a ticket" do
    test "keeps its Ticket tab, its ticket in the header and Details, and no mark Test", %{
      conn: conn,
      scope: scope
    } do
      work_item = work_item_fixture(scope)
      explore_run_fixture(work_item, state: :waiting)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-tabs a", "Ticket")
      assert has_element?(view, "#work-item-head .q-wi-ref")
      refute has_element?(view, "#work-item-head-title .badge")
      assert has_element?(view, "#work-item-details-ticket")
      assert has_element?(view, "#work-item-details-repository")
    end
  end
end
