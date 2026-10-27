defmodule ApiaryWeb.BacklogLive.TakeInTest do
  # The ticket over the Backlog's list (`?ticket=`) and Take in
  # (`ApiaryWeb.BacklogLive.Index`): the panel, its help in the workspace's words and its
  # Take in, Close; Take in from the panel and from a row, which leads to the new work
  # item; and each refusal, said in a flash.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Repo, WorkItems}
  alias Apiary.Adapters.Collection
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  setup :register_and_log_in_user

  setup %{scope: scope} do
    connection = ticket_connection_fixture(scope)
    ticket = backlog_ticket_fixture(scope, connection: connection, title: "Login times out")
    %{connection: connection, ticket: ticket}
  end

  defp page(scope, query \\ ""),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/backlog" <> query

  defp open(scope, ticket), do: page(scope, "?ticket=#{ticket.public_id}")

  defp work_path(scope, number), do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}"

  defp words(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  # The flash's words: its title, then its body.
  defp flash(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#flash-error p")
    |> Enum.map_join(" ", &(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

  describe "the ticket over the list" do
    test "a row's title opens the ticket, with the help and Take in", ctx do
      %{scope: scope, ticket: ticket} = ctx
      workspace = scope.workspace.name
      {:ok, view, _html} = live(ctx.conn, page(scope))

      view |> element("#ticket-#{ticket.public_id} a.q-bl-t") |> render_click()
      assert_patch(view, open(scope, ticket))

      assert has_element?(view, ~s(#backlog-ticket[role="dialog"]))
      assert words(view, "#backlog-ticket-title") == "Login times out"
      assert has_element?(view, ~s(#ticket-#{ticket.public_id} a[aria-current="true"]))

      assert words(view, "#backlog-ticket-take-in-help") ==
               "Take in makes a work item from a ticket and starts its explore run. " <>
                 "#{workspace} needs a workflow first, set in Workspace settings › Workflow, " <>
                 "unless the ticket's repository has a harness.yaml or qory.yaml. " <>
                 "Open Backlog. Press a ticket's title. Its panel opens. Press Take in. " <>
                 "In a software workspace, the ticket must be in a repository assigned to " <>
                 "#{workspace}."

      assert has_element?(view, "#backlog-ticket-take-in-help b", "Take in")
      assert has_element?(view, "#backlog-ticket-take-in-help code", "harness.yaml")
      assert words(view, "#backlog-ticket-take-in-button") == "Take in"
      assert has_element?(view, "#backlog-ticket-body", "The basket shows the price")
    end

    test "Close takes the ticket away and keeps the list", ctx do
      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))

      view |> element("#backlog-ticket-close") |> render_click()
      assert_patch(view, page(ctx.scope))
      refute has_element?(view, "#backlog-ticket")
      assert has_element?(view, "#ticket-#{ctx.ticket.public_id}")
    end

    test "the full ticket's link leads to its page", ctx do
      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))

      assert view |> element("#backlog-ticket-full") |> render() =~
               ~s(href="#{page(ctx.scope)}/#{ctx.ticket.public_id}")
    end

    test "an id of no ticket of this Backlog opens nothing", ctx do
      for id <- ["tk_nothere", "not-an-id"] do
        {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?ticket=#{id}"))
        refute has_element?(view, "#backlog-ticket")
        assert has_element?(view, "#ticket-#{ctx.ticket.public_id}")
      end
    end

    test "a ticket taken in has no Take in block", ctx do
      {:ok, _work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))

      assert has_element?(view, "#backlog-ticket")
      refute has_element?(view, "#backlog-ticket-take-in")
    end

    test "in a general workspace, the help leaves out the repository's lines", ctx do
      scope = with_domain(ctx.scope, "general")
      {:ok, view, _html} = live(ctx.conn, open(scope, ctx.ticket))

      assert words(view, "#backlog-ticket-take-in-help") ==
               "Take in makes a work item from a ticket and starts its explore run. " <>
                 "#{scope.workspace.name} needs a workflow first, " <>
                 "set in Workspace settings › Workflow. " <>
                 "Open Backlog. Press a ticket's title. Its panel opens. Press Take in."
    end
  end

  describe "Take in" do
    test "from the panel makes the work item and leads to it", ctx do
      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))

      view |> element("#backlog-ticket-take-in-button") |> render_click()

      %WorkItem{number: number, state: :exploring} =
        Repo.get_by!(WorkItem, item_id: ctx.ticket.id)

      assert_redirect(view, work_path(ctx.scope, number))
    end

    test "from a row makes the work item and leads to it", ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      view |> element("#ticket-#{ctx.ticket.public_id} button.q-bl-take") |> render_click()

      %WorkItem{number: number} = Repo.get_by!(WorkItem, item_id: ctx.ticket.id)
      assert_redirect(view, work_path(ctx.scope, number))
    end

    test "a ticket with no target: why, in the workspace's words", ctx do
      collection = Repo.get!(Collection, ctx.ticket.collection_id)

      collection
      |> Ecto.Changeset.change(target_system: nil, target_path: nil)
      |> Repo.update!()

      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))
      view |> element("#backlog-ticket-take-in-button") |> render_click()

      adapter = Repo.get!(Apiary.Nodes.Node, ctx.ticket.adapter_id)

      assert flash(view) =~
               "#{adapter.name} sent no repository for this ticket, so it was not taken in. " <>
                 "Each work item in #{ctx.scope.workspace.name} needs one."

      refute Repo.get_by(WorkItem, item_id: ctx.ticket.id)
      assert has_element?(view, "#backlog-ticket-take-in-button")
    end

    test "a ticket no longer in the Backlog: says so, and the panel closes", ctx do
      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))

      Repo.get!(Collection, ctx.ticket.collection_id)
      |> Ecto.Changeset.change(workspace_id: nil)
      |> Repo.update!()

      view |> element("#backlog-ticket-take-in-button") |> render_click()

      assert flash(view) =~
               "This ticket is no longer in #{ctx.scope.workspace.name}'s Backlog, so it was " <>
                 "not taken in."

      refute has_element?(view, "#backlog-ticket")
    end

    test "a ticket closed at its source: says so", ctx do
      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))

      ctx.ticket |> Ecto.Changeset.change(state: :closed) |> Repo.update!()
      view |> element("#backlog-ticket-take-in-button") |> render_click()

      adapter = Repo.get!(Apiary.Nodes.Node, ctx.ticket.adapter_id)
      assert flash(view) =~ "This ticket is closed at #{adapter.name}, so it was not taken in."
      refute has_element?(view, "#backlog-ticket-take-in")
    end

    test "a ticket someone took in meanwhile: its work item's number", ctx do
      {:ok, view, _html} = live(ctx.conn, open(ctx.scope, ctx.ticket))

      {:ok, work_item} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      # The page has read the ticket again meanwhile; a press sent before that still says.
      render_click(view, "take_in", %{"id" => ctx.ticket.public_id})

      assert flash(view) =~
               "Someone took this ticket in already, as work item ##{work_item.number}."

      refute has_element?(view, "#backlog-ticket-take-in")
    end
  end
end
