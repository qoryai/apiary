defmodule ApiaryWeb.BacklogLive.FinishedTest do
  # The Backlog after a work item finishes or its ticket closes at the source
  # (`ApiaryWeb.BacklogLive.Index`), one test for each row of the approved table: where a
  # ticket shows, with which action, and what the work item shows in Work items and on
  # its page.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.SourcesFixtures
  import Apiary.StagesFixtures

  alias Apiary.{Repo, Sources, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Sources.Item
  alias Apiary.WorkItems.{WorkItem, WorkItemEvent}

  @moduletag needs: [:factory, :workflow_model]

  setup :register_and_log_in_user

  setup %{scope: scope} do
    tracker = tracker_fixture(scope)
    {:ok, :accepted} = post_items(tracker, [item("R", title: "Login times out")])
    Map.merge(tracker, %{ticket: ticket(tracker)})
  end

  defp post_items(tracker, items),
    do: Sources.post_items(tracker.key_scope, items_body("TRK", items))

  defp ticket(tracker), do: Repo.get_by!(Item, collection_id: tracker.collection.id)

  defp later(seconds), do: DateTime.add(at(), seconds, :second)

  defp close_ticket(ctx, seconds),
    do:
      {:ok, :accepted} = post_items(ctx, [item("R", state: "closed", updated_at: later(seconds))])

  defp reopen_ticket(ctx, seconds),
    do: {:ok, :accepted} = post_items(ctx, [item("R", updated_at: later(seconds))])

  defp backlog(scope, view),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/backlog?#{[view: view]}"

  defp work_list(scope, view),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work?#{[view: view]}"

  defp work_path(scope, number), do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}"

  defp row(ticket), do: "#ticket-#{ticket.public_id}"

  defp count(view, tab),
    do:
      view
      |> element("#backlog-view-#{tab}")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.replace(~r/\D/, "")
      |> String.to_integer()

  defp words(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp work_row(work_item), do: "#work-item-#{work_item.public_id}"

  # Where the ticket shows: `:open` or `:taken`, or nil for neither, with the two tabs'
  # counts agreeing.
  defp shown_in(conn, scope, ticket) do
    {:ok, open, _html} = live(conn, backlog(scope, "open"))
    {:ok, taken, _html} = live(conn, backlog(scope, "taken"))

    case {has_element?(open, row(ticket)), has_element?(taken, row(ticket))} do
      {true, false} ->
        assert {count(open, :open), count(open, :taken)} == {1, 0}
        {:open, open}

      {false, true} ->
        assert {count(taken, :open), count(taken, :taken)} == {0, 1}
        {:taken, taken}

      {false, false} ->
        assert {count(open, :open), count(open, :taken)} == {0, 0}
        {nil, open}
    end
  end

  defp take_in_button(ticket), do: row(ticket) <> ~s( button[phx-click="take_in"])
  defp again_button(ticket), do: row(ticket) <> ~s( button[phx-click="take_in_again"])
  defp work_link(ticket), do: row(ticket) <> " a.q-bl-wi"

  defp again_title(view, ticket) do
    view
    |> element(again_button(ticket))
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("button")
    |> LazyHTML.attribute("title")
    |> List.first()
  end

  describe "the table" do
    test "open, with no work item: Open, with Take in", ctx do
      assert {:open, view} = shown_in(ctx.conn, ctx.scope, ctx.ticket)
      assert has_element?(view, take_in_button(ctx.ticket))
      refute has_element?(view, again_button(ctx.ticket))
    end

    test "open, at a stage: Taken in, with a link", ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)

      assert {:taken, view} = shown_in(ctx.conn, ctx.scope, ctx.ticket)
      assert words(view, work_link(ctx.ticket)) == "##{work_item.number}"
      refute has_element?(view, again_button(ctx.ticket))
    end

    test "open, finished: Taken in, with a link, and no Take in again, once it is Closed", ctx do
      work_item = finished_fixture(ctx.scope, ctx.ticket)
      assert %WorkItem{state: :closed} = work_item

      assert {:taken, view} = shown_in(ctx.conn, ctx.scope, ctx.ticket)
      assert words(view, work_link(ctx.ticket)) == "##{work_item.number}"
      refute has_element?(view, again_button(ctx.ticket))

      {:ok, list, _html} = live(ctx.conn, work_list(ctx.scope, "closed"))
      assert words(list, work_row(work_item) <> " .q-wl-nx") == "Every stage done"
    end

    test "open, a person closed it: Open, with Take in again", ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      {:ok, _closed} = WorkItems.close(ctx.scope, work_item)

      assert {:open, view} = shown_in(ctx.conn, ctx.scope, ctx.ticket)
      assert has_element?(view, again_button(ctx.ticket))
      assert again_title(view, ctx.ticket) == "Brings back work item ##{work_item.number}"

      {:ok, list, _html} = live(ctx.conn, work_list(ctx.scope, "closed"))
      assert words(list, work_row(work_item) <> " .q-wl-nx") == "Closed by you"
    end

    test "open, closed in another workspace the reader may read: Open, and where it is",
         ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      {:ok, _closed} = WorkItems.close(ctx.scope, work_item)
      other = Apiary.OrganisationsFixtures.workspace_fixture(ctx.scope.organisation, "Second")

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [workspace_id: other.id]
        )

      assert {:open, view} = shown_in(ctx.conn, ctx.scope, ctx.ticket)
      refute has_element?(view, again_button(ctx.ticket))
      assert words(view, "#ticket-#{ctx.ticket.public_id}-elsewhere") == "In Second"
    end

    test "open, at a stage in another workspace: Taken in, with no number and no link", ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      other = Apiary.OrganisationsFixtures.workspace_fixture(ctx.scope.organisation, "Second")

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [workspace_id: other.id]
        )

      assert {:taken, view} = shown_in(ctx.conn, ctx.scope, ctx.ticket)
      refute has_element?(view, work_link(ctx.ticket))
      assert words(view, row(ctx.ticket) <> " span.q-bl-wi") == "Taken in"

      assert view
             |> element(row(ctx.ticket) <> " span.q-bl-wi")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("span.q-bl-wi")
             |> LazyHTML.attribute("title") == ["Taken in as a work item of another workspace"]
    end

    test "open, a person undid its take in: Open, with Take in again", ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      {:ok, _undone} = WorkItems.undo(ctx.scope, work_item)

      assert {:open, view} = shown_in(ctx.conn, ctx.scope, ctx.ticket)
      assert has_element?(view, again_button(ctx.ticket))
    end

    test "closed, with no work item: not in the Backlog", ctx do
      close_ticket(ctx, 60)
      assert {nil, _view} = shown_in(ctx.conn, ctx.scope, ctx.ticket)
    end

    test "closed, at a stage: not in the Backlog, and the work item is Closed with its reason",
         ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      close_ticket(ctx, 60)

      assert {nil, _view} = shown_in(ctx.conn, ctx.scope, ctx.ticket)
      assert %WorkItem{state: :closed, closed_by_id: nil} = Repo.get!(WorkItem, work_item.id)

      {:ok, list, _html} = live(ctx.conn, work_list(ctx.scope, "closed"))
      assert words(list, work_row(work_item) <> " .q-wl-nx") == "Closed when its ticket closed"
    end

    test "closed, finished: not in the Backlog, and the work item keeps its reason", ctx do
      work_item = finished_fixture(ctx.scope, ctx.ticket)
      close_ticket(ctx, 60)

      assert {nil, _view} = shown_in(ctx.conn, ctx.scope, ctx.ticket)

      {:ok, list, _html} = live(ctx.conn, work_list(ctx.scope, "closed"))
      assert words(list, work_row(work_item) <> " .q-wl-nx") == "Every stage done"
    end

    test "closed, a person closed it: not in the Backlog", ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      {:ok, _closed} = WorkItems.close(ctx.scope, work_item)
      close_ticket(ctx, 60)

      assert {nil, _view} = shown_in(ctx.conn, ctx.scope, ctx.ticket)
    end

    test "reopened, finished: Open, with Take in again; the press moves the same work item to Explore at run 1 of 3",
         ctx do
      work_item = finished_fixture(ctx.scope, ctx.ticket)
      close_ticket(ctx, 60)
      reopen_ticket(ctx, 120)

      assert {:open, view} = shown_in(ctx.conn, ctx.scope, ctx.ticket)

      {:ok, list, _html} = live(ctx.conn, work_list(ctx.scope, "closed"))
      assert words(list, work_row(work_item) <> " .q-wl-nx") == "Every stage done"

      view |> element(again_button(ctx.ticket)) |> render_click()
      confirm_take_in(view)
      assert_redirect(view, work_path(ctx.scope, work_item.number))

      assert %WorkItem{state: :exploring, take_in: 2, stage_state: :running} =
               Repo.get!(WorkItem, work_item.id)

      assert %DispatchRun{take_in: 2, attempt: 1, of: 3} = newest_run(work_item)

      {:ok, closed, _html} = live(ctx.conn, work_list(ctx.scope, "closed"))
      refute has_element?(closed, work_row(work_item))
    end
  end

  describe "the mark of a Closed row" do
    defp mark(view, work_item),
      do:
        view
        |> element(work_row(work_item) <> " .q-wi-mk")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.attribute("class")

    test "an amber ring for every stage done, a grey one for any other end", ctx do
      finished = finished_fixture(ctx.scope, ctx.ticket)

      {:ok, :accepted} = post_items(ctx, [item("P"), item("T"), item("U")])

      taken =
        for ref <- ["P", "T", "U"], into: %{} do
          ticket = Repo.get_by!(Item, collection_id: ctx.collection.id, external_ref: ref)
          {:ok, work_item} = WorkItems.take_in(ctx.scope, ticket.public_id)
          {ref, work_item}
        end

      {:ok, _closed} = WorkItems.close(ctx.scope, taken["P"])
      {:ok, _undone} = WorkItems.undo(ctx.scope, taken["U"])
      {:ok, :accepted} = post_items(ctx, [item("T", state: "closed", updated_at: later(60))])

      {:ok, list, _html} = live(ctx.conn, work_list(ctx.scope, "closed"))

      assert mark(list, finished) == ["q-wi-mk q-wi-mk-done"]
      assert mark(list, taken["P"]) == ["q-wi-mk q-wi-mk-stopped"]
      assert mark(list, taken["T"]) == ["q-wi-mk q-wi-mk-stopped"]
      assert mark(list, taken["U"]) == ["q-wi-mk q-wi-mk-stopped"]
    end

    test "keeps the amber ring when its ticket closes and reopens", ctx do
      work_item = finished_fixture(ctx.scope, ctx.ticket)
      close_ticket(ctx, 60)
      reopen_ticket(ctx, 120)

      {:ok, list, _html} = live(ctx.conn, work_list(ctx.scope, "closed"))
      assert mark(list, work_item) == ["q-wi-mk q-wi-mk-done"]
    end
  end

  describe "the views" do
    test "the Closed tab, its count and its line are gone, and its address is Open", ctx do
      close_ticket(ctx, 60)
      {:ok, view, html} = live(ctx.conn, backlog(ctx.scope, "closed"))

      refute has_element?(view, "#backlog-view-closed")
      refute has_element?(view, "#backlog-view-line")
      assert has_element?(view, ~s(#backlog-view-open[aria-current]))
      refute html =~ "closed on"
    end

    test "a Backlog with only closed tickets keeps its tabs", ctx do
      close_ticket(ctx, 60)
      {:ok, view, _html} = live(ctx.conn, backlog(ctx.scope, "open"))

      assert has_element?(view, "#backlog-view-open")
      refute has_element?(view, "#backlog-empty")
    end

    test "a refused Take in again says who has it, and draws the row again", ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      {:ok, _closed} = WorkItems.close(ctx.scope, work_item)
      {:ok, view, _html} = live(ctx.conn, backlog(ctx.scope, "open"))
      view |> element(again_button(ctx.ticket)) |> render_click()

      # The ticket was taken in again while the dialog was open.
      {:ok, _again} = WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id)
      confirm_take_in(view)

      assert render(view) =~
               "Someone took this ticket in already, as work item ##{work_item.number}."
    end
  end

  describe "a press by a person who may not take tickets in" do
    test "is refused, and changes nothing", ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      {:ok, _closed} = WorkItems.close(ctx.scope, work_item)
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.TakesNothingIn)

      {:ok, view, _html} = live(ctx.conn, backlog(ctx.scope, "open"))
      render_click(view, "take_in_again", %{"id" => ctx.ticket.public_id})

      assert has_element?(view, "#flash-error")
      assert %WorkItem{state: :closed, take_in: 1} = Repo.get!(WorkItem, work_item.id)
      assert newest_run(work_item).take_in == 1
    end
  end

  describe "the work item page" do
    defp page(scope, work_item), do: work_path(scope, work_item.number)

    test "a finished one shows its reason, and no Take in again", ctx do
      work_item = finished_fixture(ctx.scope, ctx.ticket)
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, work_item))

      assert words(view, "#work-item-ended-line") =~ "Every stage done"
      refute has_element?(view, "#work-item-ended-again")
      assert words(view, "#work-item-details-ended") =~ "Every stage done"
    end

    test "one whose ticket closed shows its reason, and no Take in again", ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      close_ticket(ctx, 60)
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, work_item))

      assert words(view, "#work-item-ended-line") =~ "Closed when its ticket closed"
      refute has_element?(view, "#work-item-ended-again")

      {:ok, thread, _html} = live(ctx.conn, page(ctx.scope, work_item) <> "/thread")
      assert render(thread) =~ "Closed when its ticket closed"
    end

    test "a finished one offers Take in again once its ticket reopened", ctx do
      work_item = finished_fixture(ctx.scope, ctx.ticket)
      close_ticket(ctx, 60)
      reopen_ticket(ctx, 120)
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, work_item))

      assert words(view, "#work-item-ended-line") == "Every stage done"
      assert has_element?(view, "#work-item-ended-again")
    end

    test "after an undo of its take in again, the end line and the stages agree", ctx do
      work_item = finished_fixture(ctx.scope, ctx.ticket)
      close_ticket(ctx, 60)
      reopen_ticket(ctx, 120)
      {:ok, again} = WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id)
      {:ok, _undone} = WorkItems.undo(ctx.scope, again)

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, work_item))

      assert words(view, "#work-item-ended-line") == "Every stage done"
      assert has_element?(view, "#work-item-head-stages")
      refute has_element?(view, "#work-item-head-stages .q-wi-stage-now")
    end

    test "after an undo of a take in again that moved it, it is at no stage", ctx do
      work_item = finished_fixture(ctx.scope, ctx.ticket)
      close_ticket(ctx, 60)
      reopen_ticket(ctx, 120)
      {:ok, again} = WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id)

      # As if the take in again had moved it: its event has another workspace.
      {1, _rows} =
        Repo.update_all(
          from(e in WorkItemEvent,
            where: e.work_item_id == ^again.id and e.kind == :taken_in,
            where: fragment("?->>'take_in' = '2'", e.data),
            update: [
              set: [
                data:
                  fragment(
                    "jsonb_set(?, '{before,workspace_id}', to_jsonb(?::text))",
                    e.data,
                    ^Ecto.UUID.generate()
                  )
              ]
            ]
          ),
          []
        )

      {:ok, _undone} = WorkItems.undo(ctx.scope, Repo.get!(WorkItem, again.id))
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, work_item))

      assert words(view, "#work-item-ended-line") == "Every stage done"
      refute has_element?(view, ".q-wi-stage-now")
      assert has_element?(view, "#work-item-ended-again")

      {:ok, list, _html} = live(ctx.conn, work_list(ctx.scope, "closed"))
      assert words(list, work_row(work_item)) =~ "Every stage done"
      assert mark(list, work_item) == ["q-wi-mk q-wi-mk-done"]

      assert {:open, backlog} = shown_in(ctx.conn, ctx.scope, ctx.ticket)
      assert has_element?(backlog, again_button(ctx.ticket))
    end

    test "one a person closed keeps Take in again", ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      {:ok, _closed} = WorkItems.close(ctx.scope, work_item)
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, work_item))

      assert has_element?(view, "#work-item-ended-again")
    end

    test "one a person closed, whose ticket closed since, has no Take in again", ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      {:ok, _closed} = WorkItems.close(ctx.scope, work_item)
      close_ticket(ctx, 60)
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, work_item))

      refute has_element?(view, "#work-item-ended-again")
    end
  end
end
