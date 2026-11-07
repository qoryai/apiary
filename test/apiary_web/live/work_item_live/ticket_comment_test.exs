defmodule ApiaryWeb.WorkItemLive.TicketCommentTest do
  # A member's comment from a take in, on the work item's Ticket tab
  # (`ApiaryWeb.WorkItemLive.Show`) and on the ticket over the Backlog
  # (`ApiaryWeb.BacklogLive.Index`): how far its post at the source is, in the source's
  # name (Posting to, Posted to with a link, Kept in Qory Apiary only), and, where it was
  # not posted, why, in one reason for each failure, with Post again for whoever may take
  # tickets in.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.WorkItemsFixtures

  alias Apiary.{Repo, Sources, WorkItems}
  alias Apiary.Nodes.Node
  alias Apiary.Sources.Comment

  @moduletag needs: :factory

  @url "https://tracker.example.com/acme/billing/501#comment-7"

  setup :register_and_log_in_user

  setup %{scope: scope} do
    connection = ticket_connection_fixture(scope)

    Repo.update_all(from(n in Node, where: n.id == ^connection.adapter_id),
      set: [comments: true]
    )

    ticket = backlog_ticket_fixture(scope, connection: connection, title: "Credit notes skip")

    {:ok, work_item} =
      WorkItems.take_in(scope, ticket.public_id, %{comment: "Check the export retry first."})

    comment = Repo.get_by!(Comment, item_id: ticket.id)
    adapter = Repo.get!(Node, connection.adapter_id)
    %{ticket: ticket, work_item: work_item, comment: comment, source: adapter.name}
  end

  defp set(comment, state, failure \\ nil) do
    {ref, url} = if state == :posted, do: {"C-7", @url}, else: {nil, nil}

    Repo.update_all(from(c in Comment, where: c.id == ^comment.id),
      set: [post_state: state, post_failure: failure, external_ref: ref, url: url]
    )
  end

  defp ticket_tab(ctx),
    do: ~p"/#{ctx.scope.organisation}/#{ctx.scope.workspace}/work/#{ctx.work_item.number}/ticket"

  defp panel(ctx),
    do:
      ~p"/#{ctx.scope.organisation}/#{ctx.scope.workspace}/backlog?view=taken&ticket=#{ctx.ticket.public_id}"

  defp words(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp tab_comment(ctx), do: "#work-item-ticket-comment-#{ctx.comment.id}"
  defp panel_comment(ctx), do: "#backlog-ticket-comment-#{ctx.comment.id}"

  describe "the Ticket tab" do
    test "posting: under the comments on the ticket, Posting to the source", ctx do
      {:ok, view, _html} = live(ctx.conn, ticket_tab(ctx))

      assert words(view, "#work-item-ticket-comments-h") == "1 comment on the ticket"
      assert words(view, tab_comment(ctx) <> "-post") == "· Posting to #{ctx.source}"
      assert has_element?(view, tab_comment(ctx), "Check the export retry first.")
      refute has_element?(view, tab_comment(ctx) <> "-failed")
    end

    test "posted: Posted to the source, a link to the comment there", ctx do
      set(ctx.comment, :posted)
      {:ok, view, _html} = live(ctx.conn, ticket_tab(ctx))

      assert words(view, tab_comment(ctx) <> "-post") =~ "· Posted to #{ctx.source}"
      assert has_element?(view, tab_comment(ctx) <> ~s(-post a[href="#{@url}"]))
    end

    test "kept: in Qory Apiary only, as the source takes no comments", ctx do
      set(ctx.comment, :kept)
      {:ok, view, _html} = live(ctx.conn, ticket_tab(ctx))

      assert words(view, tab_comment(ctx) <> "-post") ==
               "· Kept in Qory Apiary only: #{ctx.source} takes no comments."
    end

    test "not posted: one reason for each failure, in the source's name, with Post again", ctx do
      for {failure, reason} <- [
            item_gone: "the ticket is no longer at #{ctx.source}.",
            not_permitted: "the integration has no access to this ticket.",
            too_long: "the comment is longer than #{ctx.source} takes.",
            unreachable: "#{ctx.source} could not be reached.",
            deleted_at_source: "the comment was deleted at #{ctx.source}."
          ] do
        set(ctx.comment, :not_posted, failure)
        {:ok, view, _html} = live(ctx.conn, ticket_tab(ctx))

        assert words(view, tab_comment(ctx) <> "-failed-why") ==
                 "Not posted to #{ctx.source}: #{reason}",
               "#{failure}"

        assert words(view, tab_comment(ctx) <> "-failed-again") == "Post again"
        refute has_element?(view, tab_comment(ctx) <> "-post")
      end
    end

    test "Post again: the comment is posting again", ctx do
      set(ctx.comment, :not_posted, :unreachable)
      {:ok, view, _html} = live(ctx.conn, ticket_tab(ctx))

      view |> element(tab_comment(ctx) <> "-failed-again") |> render_click()

      assert Repo.get!(Comment, ctx.comment.id).post_state == :posting
      refute has_element?(view, tab_comment(ctx) <> "-failed")
      assert words(view, tab_comment(ctx) <> "-post") == "· Posting to #{ctx.source}"
      refute has_element?(view, "#flash-error")
    end

    test "a post again elsewhere shows on the open page", ctx do
      set(ctx.comment, :not_posted, :unreachable)
      {:ok, view, _html} = live(ctx.conn, ticket_tab(ctx))
      assert has_element?(view, tab_comment(ctx) <> "-failed")

      {:ok, _comment} = Sources.post_again(ctx.scope, ctx.comment.comment_id)

      refute has_element?(view, tab_comment(ctx) <> "-failed")
      assert words(view, tab_comment(ctx) <> "-post") == "· Posting to #{ctx.source}"
    end

    test "a person who may not take tickets in: no Post again, and a press is refused", ctx do
      set(ctx.comment, :not_posted, :unreachable)
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.TakesNothingIn)
      {:ok, view, _html} = live(ctx.conn, ticket_tab(ctx))

      assert has_element?(view, tab_comment(ctx) <> "-failed-why")
      refute has_element?(view, tab_comment(ctx) <> "-failed-again")

      render_click(view, "post_again", %{"comment" => ctx.comment.comment_id})

      assert has_element?(view, "#flash-error")
      assert Repo.get!(Comment, ctx.comment.id).post_state == :not_posted
    end

    test "a comment deleted since the page drew it: the page draws it no more", ctx do
      set(ctx.comment, :not_posted, :unreachable)
      {:ok, view, _html} = live(ctx.conn, ticket_tab(ctx))
      Repo.delete!(Repo.get!(Comment, ctx.comment.id))
      assert {:error, :not_found} = Sources.post_again(ctx.scope, ctx.comment.comment_id)

      render_click(view, "post_again", %{"comment" => ctx.comment.comment_id})

      refute has_element?(view, "#flash-error")
      refute has_element?(view, tab_comment(ctx))
    end

    test "a comment posted since the page drew it: the page shows it posted", ctx do
      set(ctx.comment, :not_posted, :unreachable)
      {:ok, view, _html} = live(ctx.conn, ticket_tab(ctx))
      set(ctx.comment, :posted)

      view |> element(tab_comment(ctx) <> "-failed-again") |> render_click()

      refute has_element?(view, "#flash-error")
      refute has_element?(view, tab_comment(ctx) <> "-failed")
      assert words(view, tab_comment(ctx) <> "-post") =~ "· Posted to #{ctx.source}"
      assert Repo.get!(Comment, ctx.comment.id).post_state == :posted
    end
  end

  describe "the ticket over the Backlog" do
    test "the comment is last among the ticket's comments, Posted to the source", ctx do
      set(ctx.comment, :posted)
      {:ok, view, _html} = live(ctx.conn, panel(ctx))

      assert words(view, panel_comment(ctx) <> "-post") =~ "· Posted to #{ctx.source}"
      assert has_element?(view, panel_comment(ctx) <> ~s(-post a[href="#{@url}"]))

      assert has_element?(
               view,
               "#backlog-ticket-comments .q-bl-cmt:last-child#{panel_comment(ctx)}"
             )
    end

    test "not posted: why, and no Post again", ctx do
      set(ctx.comment, :not_posted, :not_permitted)
      {:ok, view, _html} = live(ctx.conn, panel(ctx))

      assert words(view, panel_comment(ctx) <> "-failed-why") ==
               "Not posted to #{ctx.source}: the integration has no access to this ticket."

      refute has_element?(view, panel_comment(ctx) <> "-failed-again")
    end
  end
end
