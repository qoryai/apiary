defmodule ApiaryWeb.BacklogLive.TakeInDialogTest do
  # The take in's dialog (`ApiaryWeb.BacklogLive.TakeIn`): each Take in, Take in again and
  # Take in here opens it and starts nothing; Cancel, ×, Escape and a click outside start
  # nothing and keep the comment; its Take in takes the ticket in with the comment, or
  # with none; a comment too long stays in the dialog with the error. The panel of a
  # ticket whose work item ended says which work item it is, who ended it and when, and
  # has Take in again, or Take in here for a work item of another workspace, whose row
  # shows where it is; to a reader who may not read that workspace, the row and the
  # panel both offer Take in here, with no workspace, number, link or line on how it
  # ended. A first stage that waits for an input starts no run, and the foot has no line.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Repo, WorkItems}
  alias Apiary.Nodes.Node
  alias Apiary.Sources.Comment
  alias Apiary.WorkItems.{WorkItem, WorkItemEvent}

  @moduletag needs: :factory

  setup :register_and_log_in_user

  setup %{scope: scope} do
    connection = ticket_connection_fixture(scope)

    Repo.update_all(from(n in Node, where: n.id == ^connection.adapter_id),
      set: [comments: true]
    )

    ticket =
      backlog_ticket_fixture(scope,
        connection: connection,
        title: "Credit notes skip a number",
        key: "#501"
      )

    source_comment!(ticket, "Logs from the last run.")
    adapter = Repo.get!(Node, connection.adapter_id)
    %{connection: connection, ticket: ticket, source: adapter.name}
  end

  # A comment the adapter sent on `ticket`.
  defp source_comment!(ticket, body) do
    at = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
    ref = "C-#{System.unique_integer([:positive])}"

    %Comment{organisation_id: ticket.organisation_id, item_id: ticket.id}
    |> Comment.changeset(%{
      external_ref: ref,
      url: "https://tracker.example.com/comments/#{ref}",
      author_name: "Jonas",
      author_kind: :person,
      body: body,
      body_format: "markdown",
      source_created_at: at,
      source_updated_at: at
    })
    |> Repo.insert!()
  end

  defp backlog(scope, query \\ ""),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/backlog" <> query

  defp open(scope, ticket), do: backlog(scope, "?ticket=#{ticket.public_id}")

  defp ticket_page(scope, ticket),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/backlog/#{ticket.public_id}"

  defp work_path(scope, number), do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}"

  defp row(ticket), do: "#ticket-#{ticket.public_id}"

  defp words(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp comment_box(view) do
    [value] =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#take-in-dialog-comment")
      |> Enum.map(&LazyHTML.text/1)

    String.trim(value)
  end

  defp type(view, comment),
    do: view |> form("#take-in-dialog-form", %{comment: comment}) |> render_change()

  defp work_items(ticket),
    do: Repo.all(from w in WorkItem, where: w.external_ref == ^ticket.external_ref)

  defp member_comments(ticket),
    do: Repo.all(from c in Comment, where: c.item_id == ^ticket.id and not is_nil(c.comment_id))

  # The dialog is open over the page, with the ticket and its comment on the left, the
  # action's name on its confirm button, and its focus on the comment box.
  defp assert_dialog(view, action) do
    assert has_element?(view, "dialog#take-in-dialog")
    assert words(view, "#take-in-dialog-title") == "Take in this ticket?"
    assert words(view, "#take-in-dialog-go") == action
    assert has_element?(view, "#take-in-dialog-ticket", "Credit notes skip a number")
    assert has_element?(view, "#take-in-dialog-ticket", "Logs from the last run.")
    assert has_element?(view, ~s(dialog#take-in-dialog[data-focus="take-in-dialog-comment"]))

    assert has_element?(
             view,
             ~s(#take-in-dialog .q-spend-col[role="region"][aria-label="ticket"])
           )
  end

  # The ticket's work item, taken in and undone in the scope's workspace on 5 Nov.; the
  # ticket's record there ended, and a new one in Shop ops, whose scope is `there`.
  defp moved(ctx) do
    main = ctx.scope
    {:ok, work_item} = WorkItems.take_in(main, ctx.ticket.public_id)
    {:ok, _undone} = WorkItems.undo(main, work_item)

    Repo.update_all(
      from(e in WorkItemEvent, where: e.work_item_id == ^work_item.id and e.kind == :undone),
      set: [at: ~U[2026-11-05 10:00:00Z]]
    )

    shop = workspace_fixture(main.organisation, "Shop ops")
    there = workspace_scope(main.user, shop)
    ctx.ticket |> Ecto.Changeset.change(disconnected_at: DateTime.utc_now()) |> Repo.update!()

    record =
      backlog_ticket_fixture(there,
        connection: ctx.connection,
        external_ref: ctx.ticket.external_ref,
        title: "Credit notes skip a number"
      )

    %{main: main, shop: shop, there: there, record: record, work_item: work_item}
  end

  # A comment over the limit, confirmed in the open dialog: the error in it, the text
  # kept, and the work item `work_item` as it was.
  defp assert_too_long(view, ticket, work_item) do
    long = String.duplicate("a", 65_001)
    confirm_take_in(view, long)

    assert has_element?(view, "dialog#take-in-dialog")

    assert words(view, "#take-in-dialog-comment-error") ==
             "Shorten the comment to 65,000 characters. It has 65,001."

    assert comment_box(view) == long
    assert Repo.get!(WorkItem, work_item.id) == work_item
    assert member_comments(ticket) == []
  end

  describe "each Take in opens the dialog and starts nothing" do
    test "a row's Take in", ctx do
      {:ok, view, _html} = live(ctx.conn, backlog(ctx.scope))

      view |> element("#{row(ctx.ticket)} button.q-bl-take") |> render_click()

      assert_dialog(view, "Take in")
      assert has_element?(view, ~s(dialog[data-return="ticket-#{ctx.ticket.public_id}-take-in"]))
      assert work_items(ctx.ticket) == []
    end

    test "the panel's Take in", ctx do
      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))

      view |> element("#backlog-ticket-take-in-button") |> render_click()

      assert_dialog(view, "Take in")
      assert has_element?(view, ~s(dialog[data-return="backlog-ticket-take-in-button"]))
      assert work_items(ctx.ticket) == []
    end

    test "the full ticket's Take in", ctx do
      {:ok, view, _html} = live(ctx.conn, ticket_page(ctx.scope, ctx.ticket))

      view |> element("#ticket-take-in-button") |> render_click()

      assert_dialog(view, "Take in")
      assert work_items(ctx.ticket) == []
    end

    test "a row's Take in again, and the panel's", ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      {:ok, _closed} = WorkItems.close(ctx.scope, work_item)

      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))

      view |> element("#{row(ctx.ticket)} button.q-bl-take") |> render_click()
      assert_dialog(view, "Take in again")
      view |> element("#take-in-dialog-cancel") |> render_click()

      view |> element("#backlog-ticket-take-in-button") |> render_click()
      assert_dialog(view, "Take in again")

      assert %WorkItem{state: :closed, take_in: 1} = Repo.get!(WorkItem, work_item.id)
    end

    test "the footer says what starts, and that the run uses model tokens", ctx do
      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))
      view |> element("#backlog-ticket-take-in-button") |> render_click()

      assert words(view, "#take-in-dialog-line") =~ ~r/^Take in starts a run .*on a machine/
      assert words(view, "#take-in-dialog-line") =~ "The run uses model tokens."
    end

    test "under the box, where the comment goes, in the source's words", ctx do
      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))
      view |> element("#backlog-ticket-take-in-button") |> render_click()

      full_form = Repo.get!(Apiary.Adapters.Collection, ctx.ticket.collection_id).title <> "#501"

      assert words(view, "#take-in-dialog-comment-hint") ==
               "Posted as a comment on #{full_form} in #{ctx.source}, with your name. " <>
                 "On a public collection, anyone can read it."
    end

    test "for a source that takes no comments, the comment stays in Qory Apiary", ctx do
      Repo.update_all(from(n in Node, where: n.id == ^ctx.connection.adapter_id),
        set: [comments: false]
      )

      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))
      view |> element("#backlog-ticket-take-in-button") |> render_click()

      assert words(view, "#take-in-dialog-comment-hint") ==
               "Kept in Qory Apiary only: #{ctx.source} takes no comments."
    end

    test "a person who may not take tickets in is told who may, and no dialog opens", ctx do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.TakesNothingIn)
      {:ok, view, _html} = live(ctx.conn, backlog(ctx.scope))

      view |> element("#{row(ctx.ticket)} button.q-bl-take") |> render_click()

      refute has_element?(view, "#take-in-dialog")
      assert has_element?(view, "#flash-error")
      assert work_items(ctx.ticket) == []
    end
  end

  describe "closing the dialog starts nothing and keeps the comment" do
    setup ctx do
      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))
      view |> element("#backlog-ticket-take-in-button") |> render_click()
      type(view, "Check the export retry first.")
      %{view: view}
    end

    defp assert_kept(view, ticket) do
      refute has_element?(view, "#take-in-dialog")
      assert work_items(ticket) == []

      view |> element("#backlog-ticket-take-in-button") |> render_click()
      assert comment_box(view) == "Check the export retry first."
    end

    test "Cancel", %{view: view} = ctx do
      view |> element("#take-in-dialog-cancel") |> render_click()
      assert_kept(view, ctx.ticket)
    end

    test "×", %{view: view} = ctx do
      view |> element("#take-in-dialog-close") |> render_click()
      assert_kept(view, ctx.ticket)
    end

    test "Escape", %{view: view} = ctx do
      view |> element("dialog#take-in-dialog") |> render_keydown(%{"key" => "Escape"})
      assert_kept(view, ctx.ticket)
    end

    test "a click outside the box", %{view: view} = ctx do
      assert has_element?(view, ~s(#take-in-dialog-form[phx-click-away="take_in_cancel"]))
      render_click(view, "take_in_cancel", %{})
      assert_kept(view, ctx.ticket)
    end
  end

  describe "the dialog's Take in" do
    test "with a comment: the work item, the comment on the ticket, and its page", ctx do
      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))
      view |> element("#backlog-ticket-take-in-button") |> render_click()

      confirm_take_in(view, "  Check the export retry first.\n")

      [%WorkItem{number: number, state: :exploring}] = work_items(ctx.ticket)
      assert_redirect(view, work_path(ctx.scope, number))

      assert [%Comment{body: "Check the export retry first.", post_state: :posting}] =
               member_comments(ctx.ticket)

      {:ok, page, _html} = live(ctx.conn, work_path(ctx.scope, number))

      assert words(page, "#work-item-step-undo-line") =~
               ~r/^You took this in .+\. Until a run starts, you can undo the take in: Qory Apiary removes its label from the ticket, and your comment stays\.$/
    end

    test "with no comment: the work item, and no comment", ctx do
      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))
      view |> element("#backlog-ticket-take-in-button") |> render_click()

      confirm_take_in(view, "   ")

      [%WorkItem{number: number}] = work_items(ctx.ticket)
      assert_redirect(view, work_path(ctx.scope, number))
      assert member_comments(ctx.ticket) == []

      {:ok, page, _html} = live(ctx.conn, work_path(ctx.scope, number))

      assert words(page, "#work-item-step-undo-line") =~
               ~r/^You took this in .+\. Until a run starts, you can undo the take in: Qory Apiary removes its label from the ticket\.$/
    end

    test "a second click reaches a closed dialog and starts nothing", ctx do
      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))
      view |> element("#backlog-ticket-take-in-button") |> render_click()
      view |> element("#take-in-dialog-close") |> render_click()

      render_submit(view, "take_in_confirm", %{"comment" => "Once."})

      refute has_element?(view, "dialog#take-in-dialog")
      assert work_items(ctx.ticket) == []
      assert member_comments(ctx.ticket) == []
    end

    test "a comment too long: the error in the dialog, the text kept, nothing taken in", ctx do
      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))
      view |> element("#backlog-ticket-take-in-button") |> render_click()

      long = String.duplicate("a", 65_001)
      confirm_take_in(view, long)

      assert has_element?(view, "dialog#take-in-dialog")

      assert words(view, "#take-in-dialog-comment-error") ==
               "Shorten the comment to 65,000 characters. It has 65,001."

      assert comment_box(view) == long
      assert work_items(ctx.ticket) == []
      assert member_comments(ctx.ticket) == []
    end

    test "a comment with a character a comment may not have: the error, the text kept",
         ctx do
      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))
      view |> element("#backlog-ticket-take-in-button") |> render_click()

      confirm_take_in(view, "Look \u202E here")

      assert has_element?(view, "dialog#take-in-dialog")
      assert has_element?(view, "#take-in-dialog-comment-error")
      assert comment_box(view) == "Look \u202E here"
      refute has_element?(view, "#flash-error")
      assert work_items(ctx.ticket) == []
      assert member_comments(ctx.ticket) == []
    end

    test "a comment too long through Take in again", ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      {:ok, _closed} = WorkItems.close(ctx.scope, work_item)
      closed = Repo.get!(WorkItem, work_item.id)

      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))
      view |> element("#backlog-ticket-take-in-button") |> render_click()

      assert_too_long(view, ctx.ticket, closed)
    end

    test "a comment too long through Take in here", ctx do
      %{there: there, record: record, work_item: work_item} = moved(ctx)
      undone = Repo.get!(WorkItem, work_item.id)

      {:ok, view, _html} = live(ctx.conn, open(there, record))
      view |> element("#backlog-ticket-take-in-button") |> render_click()
      assert words(view, "#take-in-dialog-go") == "Take in here"

      assert_too_long(view, record, undone)
    end

    @tag needs: [:factory, :workflow_model]
    test "a first stage that waits for an input: no line on a run in the foot", ctx do
      document = %{
        "schema" => "qory.process/v1",
        "machine" => "default",
        "stages" => [
          %{
            "id" => "st_r79kph11eg",
            "name" => "Explore",
            "inputs" => [%{"type" => "acceptance-criteria", "required" => true}],
            "sequence" => [%{"workflow" => "explore-a-ticket"}],
            "outputs" => [%{"type" => "proposal", "required" => true}],
            "gate" => %{"kind" => "person", "approvers" => "members"}
          }
        ]
      }

      {:ok, _version} = Apiary.Processes.save(ctx.scope, ctx.scope.workspace, document)

      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))
      view |> element("#backlog-ticket-take-in-button") |> render_click()

      assert_dialog(view, "Take in")
      refute has_element?(view, "#take-in-dialog-line")
      refute has_element?(view, "dialog#take-in-dialog[aria-describedby]")
      refute render(view) =~ "model tokens"

      confirm_take_in(view, "")
      assert [%WorkItem{stage_state: :waiting_inputs}] = work_items(ctx.ticket)
    end

    test "Take in again: the same work item, with the comment", ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      {:ok, _closed} = WorkItems.close(ctx.scope, work_item)

      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))
      view |> element("#backlog-ticket-take-in-button") |> render_click()
      confirm_take_in(view, "Again, with the logs.")

      assert_redirect(view, work_path(ctx.scope, work_item.number))
      assert %WorkItem{state: :exploring, take_in: 2} = Repo.get!(WorkItem, work_item.id)
      assert [%Comment{body: "Again, with the logs."}] = member_comments(ctx.ticket)
    end

    test "Undo's line: the comment of this take in only, by its taker's name to another reader",
         ctx do
      id = ctx.ticket.public_id
      {:ok, work_item} = WorkItems.take_in(ctx.scope, id, %{comment: "First look."})
      {:ok, _undone} = WorkItems.undo(ctx.scope, work_item)
      {:ok, again} = WorkItems.take_in_again(ctx.scope, id, %{})

      # The first take in's comment, as if both take ins fell in the same second.
      Repo.update_all(from(c in Comment, where: c.item_id == ^ctx.ticket.id),
        set: [source_created_at: DateTime.truncate(again.taken_in_at, :second)]
      )

      {:ok, page, _html} = live(ctx.conn, work_path(ctx.scope, work_item.number))

      assert words(page, "#work-item-step-undo-line") =~
               ~r/^You took this in .+\. Until a run starts, you can undo the take in: Qory Apiary removes its label from the ticket\.$/

      %{user: member} = member_fixture(ctx.scope, :member)
      {:ok, _undone} = WorkItems.undo(ctx.scope, Repo.get!(WorkItem, work_item.id))

      {:ok, _again} =
        WorkItems.take_in_again(workspace_scope(member, ctx.scope.workspace), id, %{
          comment: "Second look."
        })

      {:ok, page, _html} = live(ctx.conn, work_path(ctx.scope, work_item.number))

      assert [_line, name] =
               Regex.run(
                 ~r/^(\S+) took this in .+\. Until a run starts, you can undo the take in: Qory Apiary removes its label from the ticket, and the comment by \1 stays\.$/,
                 words(page, "#work-item-step-undo-line")
               )

      assert name == ApiaryWeb.People.short(member.email)
    end
  end

  describe "a ticket whose work item ended" do
    test "closed: which work item it is, who closed it and when, and Take in again", ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      {:ok, _closed} = WorkItems.close(ctx.scope, work_item)
      lea = user_fixture(%{email: "lea@example.com"})

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [closed_by_id: lea.id, closed_at: ~U[2026-11-05 10:00:00Z]]
      )

      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))

      assert words(view, "#backlog-ticket-take-in-fact") ==
               "This ticket is work item ##{work_item.number}. lea closed it on 5 Nov."

      assert has_element?(
               view,
               ~s(#backlog-ticket-take-in-fact a[href="#{work_path(ctx.scope, work_item.number)}"])
             )

      assert words(view, "#backlog-ticket-take-in-button") == "Take in again"

      assert words(view, "#backlog-ticket-take-in-hint") ==
               "Take in again brings back work item ##{work_item.number} and starts exploring again."
    end

    test "closed by the reader, and closed by no person", ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      {:ok, _closed} = WorkItems.close(ctx.scope, work_item)

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [closed_at: ~U[2026-11-05 10:00:00Z]]
      )

      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))
      assert words(view, "#backlog-ticket-take-in-fact") =~ "You closed it on 5 Nov."

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [closed_by_id: nil]
      )

      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))
      assert words(view, "#backlog-ticket-take-in-fact") =~ "It was closed on 5 Nov."
    end

    test "undone: who undid the take in, and when", ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      {:ok, _undone} = WorkItems.undo(ctx.scope, work_item)
      amara = user_fixture(%{email: "amara@example.com"})

      Repo.update_all(
        from(e in WorkItemEvent, where: e.work_item_id == ^work_item.id and e.kind == :undone),
        set: [actor_id: amara.id, at: ~U[2026-11-05 10:00:00Z]]
      )

      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))

      assert words(view, "#backlog-ticket-take-in-fact") ==
               "This ticket is work item ##{work_item.number}. amara undid the take in on 5 Nov."

      assert words(view, "#backlog-ticket-take-in-button") == "Take in again"
    end

    test "undone by no person: which work item it is, and no line on who", ctx do
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      {:ok, _undone} = WorkItems.undo(ctx.scope, work_item)

      Repo.update_all(
        from(e in WorkItemEvent, where: e.work_item_id == ^work_item.id and e.kind == :undone),
        set: [actor_kind: :instance, actor_id: nil]
      )

      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))

      assert words(view, "#backlog-ticket-take-in-fact") ==
               "This ticket is work item ##{work_item.number}."

      assert words(view, "#backlog-ticket-take-in-button") == "Take in again"
    end

    test "of another workspace the reader may not read: Take in here on the row and the panel, without that workspace",
         ctx do
      %{main: main, shop: shop, there: there, record: record, work_item: work_item} =
        moved(ctx)

      %{user: member} = member_fixture(main, :member)
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.MembersReachNamed)
      Apiary.EditionStubs.MembersReachNamed.put([shop.id])
      conn = log_in_user(build_conn(), member)

      {:ok, view, _html} = live(conn, open(there, record))
      html = render(view)

      refute has_element?(view, "#ticket-#{record.public_id}-elsewhere")
      refute has_element?(view, "#ticket-#{record.public_id}-again")
      assert words(view, "#ticket-#{record.public_id}-here") == "Take in here"

      assert has_element?(
               view,
               ~s(#ticket-#{record.public_id}-here[title="Take in here moves the work item to Shop ops, with a Shop ops number."])
             )

      refute has_element?(view, "#backlog-ticket-take-in-fact")
      refute has_element?(view, "#backlog-ticket-take-in-open")
      assert words(view, "#backlog-ticket-take-in-button") == "Take in here"

      assert words(view, "#backlog-ticket-take-in-hint") ==
               "Take in here moves the work item to Shop ops, with a Shop ops number."

      refute html =~ "In #{main.workspace.name}"
      refute html =~ "work item ##{work_item.number}"
      refute html =~ ~p"/#{main.organisation}/#{main.workspace}/work"

      view |> element("#ticket-#{record.public_id}-here") |> render_click()
      assert words(view, "#take-in-dialog-title") == "Take in this ticket?"
      assert words(view, "#take-in-dialog-go") == "Take in here"
      assert has_element?(view, ~s(dialog[data-return="ticket-#{record.public_id}-here"]))
      view |> element("#take-in-dialog-cancel") |> render_click()
      refute has_element?(view, "dialog#take-in-dialog")

      view |> element("#backlog-ticket-take-in-button") |> render_click()
      assert words(view, "#take-in-dialog-go") == "Take in here"
      confirm_take_in(view, "Moved here.")

      moved = Repo.get!(WorkItem, work_item.id)
      assert {moved.workspace_id, moved.state, moved.take_in} == {shop.id, :exploring, 2}
      assert_redirect(view, work_path(there, moved.number))
    end

    test "of another workspace: In Main on the row, and Take in here moves it", ctx do
      %{main: main, shop: shop, there: there, record: record, work_item: work_item} =
        moved(ctx)

      {:ok, view, _html} = live(ctx.conn, open(there, record))

      assert words(view, "#ticket-#{record.public_id}-elsewhere") == "In #{main.workspace.name}"
      refute has_element?(view, "#{row(record)} button.q-bl-take")

      assert words(view, "#backlog-ticket-take-in-fact") ==
               "This ticket is work item ##{work_item.number} in #{main.workspace.name}. " <>
                 "You undid the take in on 5 Nov. " <>
                 "Open work item ##{work_item.number} in #{main.workspace.name}"

      assert has_element?(
               view,
               ~s(#backlog-ticket-take-in-open[href="#{work_path(main, work_item.number)}"])
             )

      assert words(view, "#backlog-ticket-take-in-button") == "Take in here"

      assert words(view, "#backlog-ticket-take-in-hint") ==
               "Take in here moves work item ##{work_item.number} from #{main.workspace.name} " <>
                 "to Shop ops, with a Shop ops number."

      view |> element("#backlog-ticket-take-in-button") |> render_click()
      assert words(view, "#take-in-dialog-go") == "Take in here"
      assert %WorkItem{workspace_id: workspace_id} = Repo.get!(WorkItem, work_item.id)
      assert workspace_id == main.workspace.id

      confirm_take_in(view, "Moved here.")

      moved = Repo.get!(WorkItem, work_item.id)
      assert {moved.workspace_id, moved.state, moved.take_in} == {shop.id, :exploring, 2}
      assert_redirect(view, work_path(there, moved.number))
      assert [%Comment{body: "Moved here."}] = member_comments(record)
    end
  end
end
