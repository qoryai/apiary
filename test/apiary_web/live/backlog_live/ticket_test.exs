defmodule ApiaryWeb.BacklogLive.TicketTest do
  # The full ticket (`ApiaryWeb.BacklogLive.Ticket`): its page, with Backlog back and Take
  # in with its hint, for whoever may read the workspace's work items, and why in place of
  # Take in to a person who may not take a ticket in; Take in, confirmed in the take in's
  # dialog, leads to the new work item, and a refusal is a flash; an id of no ticket of
  # this Backlog, and a person outside the workspace, find no page.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Repo
  alias Apiary.Adapters.Collection
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  setup :register_and_log_in_user

  setup %{scope: scope} do
    ticket = backlog_ticket_fixture(scope, title: "Login times out")
    %{ticket: ticket}
  end

  defp ticket_path(scope, id), do: ~p"/#{scope.organisation}/#{scope.workspace}/backlog/#{id}"

  defp words(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  test "shows the ticket, Backlog back and Take in", ctx do
    {:ok, view, _html} = live(ctx.conn, ticket_path(ctx.scope, ctx.ticket.public_id))

    assert words(view, "#ticket-title") == "Login times out"

    assert has_element?(
             view,
             ~s(#ticket-back[href="/#{ctx.scope.organisation.slug}/#{ctx.scope.workspace.slug}/backlog"])
           )

    assert words(view, "#ticket-take-in") == "Take in Take in starts exploring this ticket."
    assert words(view, "#ticket-take-in-button") == "Take in"
    assert words(view, "#ticket-take-in-hint") == "Take in starts exploring this ticket."
    refute render(view) =~ "needs a workflow first"
    assert page_title(view) =~ "Login times out"
  end

  test "to a person who may not take a ticket in, why in place of Take in", ctx do
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.TakesNothingIn)
    {:ok, view, _html} = live(ctx.conn, ticket_path(ctx.scope, ctx.ticket.public_id))

    assert words(view, "#ticket-take-in") ==
             ApiaryWeb.BacklogComponents.take_in_who_may(ctx.scope)

    refute has_element?(view, "#ticket-take-in-button")
    refute has_element?(view, "#ticket-take-in-hint")
  end

  test "Take in makes the work item and leads to it", ctx do
    {:ok, view, _html} = live(ctx.conn, ticket_path(ctx.scope, ctx.ticket.public_id))

    view |> element("#ticket-take-in-button") |> render_click()
    confirm_take_in(view)

    %WorkItem{number: number} = Repo.get_by!(WorkItem, item_id: ctx.ticket.id)

    assert_redirect(
      view,
      ~p"/#{ctx.scope.organisation}/#{ctx.scope.workspace}/work/#{number}"
    )
  end

  test "Take in takes in the page's ticket, whatever id the press sends", ctx do
    other = backlog_ticket_fixture(ctx.scope, title: "Export stops at row 500")
    {:ok, view, _html} = live(ctx.conn, ticket_path(ctx.scope, ctx.ticket.public_id))

    render_click(view, "take_in", %{"id" => other.id})
    confirm_take_in(view)

    %WorkItem{number: number} = Repo.get_by!(WorkItem, item_id: ctx.ticket.id)
    refute Repo.get_by(WorkItem, item_id: other.id)

    assert_redirect(
      view,
      ~p"/#{ctx.scope.organisation}/#{ctx.scope.workspace}/work/#{number}"
    )
  end

  test "a refused Take in says why", ctx do
    Repo.get!(Collection, ctx.ticket.collection_id)
    |> Ecto.Changeset.change(target_system: nil, target_path: nil)
    |> Repo.update!()

    {:ok, view, _html} = live(ctx.conn, ticket_path(ctx.scope, ctx.ticket.public_id))
    view |> element("#ticket-take-in-button") |> render_click()
    confirm_take_in(view)

    assert render(view) =~ "sent no repository for this ticket"
    refute Repo.get_by(WorkItem, item_id: ctx.ticket.id)
  end

  test "is not found for an id of no ticket of this Backlog", ctx do
    for id <- ["tk_nothere", "not-an-id"] do
      assert_raise ApiaryWeb.NotFound, fn -> live(ctx.conn, ticket_path(ctx.scope, id)) end
    end
  end

  test "is not found to someone outside the workspace", ctx do
    %{user: outsider} = sign_up_fixture()

    conn =
      build_conn() |> log_in_user(outsider) |> get(ticket_path(ctx.scope, ctx.ticket.public_id))

    assert conn.status == 404
    refute conn.resp_body =~ "Login times out"
  end
end
