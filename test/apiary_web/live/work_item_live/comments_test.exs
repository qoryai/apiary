defmodule ApiaryWeb.WorkItemLive.CommentsTest do
  # People's comments on the work item page's Thread (`ApiaryWeb.WorkItemLive.Comments`,
  # drawn by `ApiaryWeb.WorkItemLive.Show`): the composer, a comment written and the
  # composer drawn again empty, a draft the server refuses kept with its words, a blank
  # text with none, More where the reader may delete, the delete question only there and
  # Cancel, the deleted line, the count beside the Thread's tab, and another reader's page
  # drawn again live.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Repo
  alias Apiary.WorkItems
  alias Apiary.WorkItems.Comment

  @moduletag needs: :factory

  setup :register_and_log_in_user

  setup %{scope: scope} do
    %{work_item: work_item_fixture(scope)}
  end

  defp thread(scope, work_item),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{work_item.number}/thread"

  defp ticket(scope, work_item),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{work_item.number}"

  defp comment_id(public_id), do: "#work-item-thread-#{public_id}"

  defp only_comment(work_item),
    do: Repo.get_by!(Comment, work_item_id: work_item.id)

  test "a comment is written, shown in the Thread, counted, and the composer is empty again",
       %{conn: conn, scope: scope, work_item: work_item} do
    {:ok, view, _html} = live(conn, thread(scope, work_item))

    assert has_element?(view, "#work-item-composer-0 textarea[name=body][maxlength='4000']")

    view
    |> form("#work-item-composer-0", %{"body" => "Two items at €12.45\nare enough."})
    |> render_submit()

    comment = only_comment(work_item)
    assert comment.body == "Two items at €12.45\nare enough."
    html = render(view)
    assert has_element?(view, comment_id(comment.public_id), "are enough.")
    assert has_element?(view, "#work-item-composer-1 textarea")
    refute has_element?(view, "#work-item-composer-0")
    assert html =~ "Two items at €12.45"

    {:ok, _ticket, ticket_html} = live(conn, ticket(scope, work_item))
    assert ticket_html =~ ~r/Thread\s*<span[^>]*>\s*1\s*</
  end

  test "a draft refused for its characters is kept, with words; a blank one has none",
       %{conn: conn, scope: scope, work_item: work_item} do
    {:ok, view, _html} = live(conn, thread(scope, work_item))

    view
    |> form("#work-item-composer-0", %{"body" => "Two\u202Eitems"})
    |> render_submit()

    assert has_element?(
             view,
             "#work-item-composer-0-error",
             "Remove the control or invisible characters."
           )

    assert has_element?(view, "#work-item-composer-0 textarea", "Two")

    view
    |> form("#work-item-composer-0", %{"body" => "   "})
    |> render_submit()

    refute has_element?(view, "#work-item-composer-0-error")
    assert Repo.all(Comment) == []
  end

  test "a draft too long for a comment is kept, with words",
       %{conn: conn, scope: scope, work_item: work_item} do
    {:ok, view, _html} = live(conn, thread(scope, work_item))

    render_submit(view, "comment", %{"body" => String.duplicate("a", 4001)})

    assert has_element?(
             view,
             "#work-item-composer-0-error",
             "Write at most 4,000 characters."
           )

    assert Repo.all(Comment) == []
  end

  test "More where the reader may delete: their comment, not another member's",
       %{conn: conn, scope: scope, work_item: work_item} do
    member = member_fixture(scope)
    {:ok, theirs} = WorkItems.comment(member.scope, work_item, "Sam's note")
    {:ok, mine} = WorkItems.comment(member.scope, work_item, "Another note")
    {:ok, _deleted} = WorkItems.delete_comment(scope, mine.public_id)

    member_conn = log_in_user(build_conn(), member.user)
    {:ok, view, _html} = live(member_conn, thread(scope, work_item))

    assert has_element?(
             view,
             comment_id(theirs.public_id) <> " [aria-label='More for your comment']"
           )

    {:ok, own_comment} = WorkItems.comment(scope, work_item, "The owner's note")
    {:ok, member_view, _html} = live(member_conn, thread(scope, work_item))
    refute has_element?(member_view, comment_id(own_comment.public_id) <> "-more")

    # The owner may delete any.
    {:ok, owner_view, _html} = live(conn, thread(scope, work_item))
    assert has_element?(owner_view, comment_id(theirs.public_id) <> "-more")
  end

  test "the delete question, Cancel, then Delete comment leaves the deleted line; another page sees it live",
       %{conn: conn, scope: scope, work_item: work_item} do
    member = member_fixture(scope)
    {:ok, comment} = WorkItems.comment(member.scope, work_item, "Wrong work item, sorry")

    {:ok, view, _html} = live(conn, thread(scope, work_item))
    {:ok, other, _html} = live(log_in_user(build_conn(), member.user), thread(scope, work_item))

    view |> element(comment_id(comment.public_id) <> "-delete") |> render_click()
    assert has_element?(view, comment_id(comment.public_id) <> "-confirm", "comment?")

    render_click(view, "cancel_question", %{})
    refute has_element?(view, comment_id(comment.public_id) <> "-confirm")

    view |> element(comment_id(comment.public_id) <> "-delete") |> render_click()
    view |> element(comment_id(comment.public_id) <> "-confirm-go") |> render_click()

    assert has_element?(view, comment_id(comment.public_id), "Comment deleted by you")
    assert render(other) =~ "Comment deleted by"
    refute render(other) =~ "Wrong work item, sorry"
    assert %Comment{body: nil} = Repo.reload!(comment)
  end

  test "the delete question opens only on a comment the reader may delete",
       %{scope: scope, work_item: work_item} do
    member = member_fixture(scope)
    {:ok, owners} = WorkItems.comment(scope, work_item, "The owner's note")
    {:ok, gone} = WorkItems.comment(member.scope, work_item, "Sam's old note")
    {:ok, _deleted} = WorkItems.delete_comment(member.scope, gone.public_id)

    {:ok, view, _html} = live(log_in_user(build_conn(), member.user), thread(scope, work_item))

    for comment <- [owners, gone] do
      html = render_click(view, "ask_delete_comment", %{"comment" => comment.public_id})
      refute has_element?(view, comment_id(comment.public_id) <> "-confirm")
      refute html =~ "comment?"
    end
  end

  test "an event naming a comment of another workspace changes nothing",
       %{conn: conn, scope: scope, work_item: work_item} do
    there = workspace_scope(scope.user, workspace_fixture(scope.organisation))
    elsewhere = work_item_fixture(there, external_ref: "acme/shop#77")
    {:ok, comment} = WorkItems.comment(there, elsewhere, "Over there")

    {:ok, view, _html} = live(conn, thread(scope, work_item))
    render_click(view, "delete_comment", %{"comment" => comment.public_id})
    render_click(view, "ask_delete_comment", %{"comment" => "not-a-comment"})

    assert %Comment{deleted_at: nil} = Repo.reload!(comment)
  end
end
