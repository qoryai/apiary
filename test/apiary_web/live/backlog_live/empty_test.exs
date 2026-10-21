defmodule ApiaryWeb.BacklogLive.EmptyTest do
  # The Backlog that holds no ticket (`ApiaryWeb.BacklogComponents.empty_backlog/1`): each
  # state, for an owner or an admin and for a member, with one integration and with
  # several, in the words of a forge-like, a tracker-like and a helpdesk-like source, and
  # of one that names none; the integrations offered as cards; and the line under the
  # title, whose Take in sentence needs a ticket with a target.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Repo
  alias Apiary.Accounts.User
  alias Apiary.Nodes.Node

  @moduletag needs: :factory

  # The words three kinds of source declare: items, then collections.
  @forge {{"issue", "issues"}, {"repository", "repositories"}}
  @tracker {{"task", "tasks"}, {"project", "projects"}}
  @helpdesk {{"incident", "incidents"}, {"queue", "queues"}}
  @none {nil, nil}

  setup :register_and_log_in_user

  defp page(scope), do: ~p"/#{scope.organisation}/#{scope.workspace}/backlog"

  defp settings(scope, adapter),
    do: "/#{scope.organisation.slug}/settings/integrations/#{adapter.public_id}"

  # Records `nouns` on the adapter `id`, as its description's source role declares them.
  defp declare(id, {item, collection}) do
    {item_one, item_other} = item || {nil, nil}
    {one, other} = collection || {nil, nil}

    {1, _} =
      Repo.update_all(from(n in Node, where: n.id == ^id),
        set: [
          item_noun_one: item_one,
          item_noun_other: item_other,
          collection_noun_one: one,
          collection_noun_other: other
        ]
      )

    Repo.get!(Node, id)
  end

  # A name for an adapter that starts with `prefix`, so that a test sets their order.
  defp name(prefix), do: "#{prefix} #{System.unique_integer([:positive])}"

  # An integration the organisation is connected through, its adapter's name starting with
  # `prefix` and declaring `nouns`; listed and its listing complete unless `listed: false`
  # or `complete: false`.
  defp source(scope, prefix, nouns, opts \\ []) do
    connection = ticket_connection_fixture(scope)
    now = DateTime.utc_now()

    {1, _} =
      Repo.update_all(from(n in Node, where: n.id == ^connection.adapter_id),
        set: [name: name(prefix)]
      )

    connection =
      connection
      |> Ecto.Changeset.change(
        listed_at: if(Keyword.get(opts, :listed, true), do: now),
        listing_completed_at:
          if(Keyword.get(opts, :listed, true) and Keyword.get(opts, :complete, true), do: now)
      )
      |> Repo.update!()

    %{connection: connection, adapter: declare(connection.adapter_id, nouns)}
  end

  # An adapter of the instance with items that the organisation is not connected through,
  # its name starting with `prefix`.
  defp offered(prefix, nouns) do
    adapter = Apiary.NodesFixtures.adapter_fixture(%{name: name(prefix)})
    declare(adapter.id, nouns)
  end

  # A live collection of `source`, assigned to the scope's workspace unless `attrs` says.
  defp collection(scope, source, attrs \\ %{}),
    do: source_collection_fixture(scope, source.connection, attrs)

  defp words(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

  defp attribute(view, selector, name) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
  end

  defp heading(view), do: words(view, "#backlog-empty h2")

  defp member(scope) do
    %{user: user} = member_fixture(scope, :member)
    log_in_user(build_conn(), user)
  end

  defp admin(scope), do: member_fixture(scope, :admin)

  defp short(%{user: user}), do: User.short_name(user.email)

  # The letter of a source's tile, which a row's text starts with.
  defp tile(%{adapter: adapter}), do: String.first(adapter.name)

  describe "no integration that sends tickets" do
    test "with none offered, says that an instance admin adds them, to anyone", ctx do
      org = ctx.scope.organisation.name

      for conn <- [ctx.conn, member(ctx.scope)] do
        {:ok, view, _html} = live(conn, page(ctx.scope))

        assert has_element?(view, ~s(#backlog-empty[data-state="none"]))
        assert heading(view) == "#{org} has no integration that sends tickets"

        assert words(view, "#backlog-empty-line") ==
                 "Tickets come into the Backlog from another system, such as an issue " <>
                   "tracker, a support desk or a forge, through an integration that " <>
                   "#{org} installs."

        assert words(view, "#backlog-empty-instance") ==
                 "An instance admin adds integrations in Instance settings › Adapters. " <>
                   "#{org} can then install them in Organisation settings › Integrations."

        refute has_element?(view, "#backlog-empty-offered")
        refute has_element?(view, "#backlog-empty-who")
        refute has_element?(view, "#page-header-description")
        refute has_element?(view, "#backlog")
      end
    end

    test "one card for an owner: the name, what it sends, and Install to its page", ctx do
      adapter = offered("Tracker", @tracker)
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))
      card = "#backlog-empty-offered-#{adapter.public_id}"
      title = "Organisation settings › Integrations › #{adapter.name}"

      assert words(view, "#backlog-empty-offered h3") ==
               "Integrations #{ctx.scope.organisation.name} can install"

      assert words(view, card) ==
               "#{String.first(adapter.name)} #{adapter.name} " <>
                 "Tasks from projects Install"

      for link <- ["#{card}-name", "#{card}-install"] do
        assert attribute(view, link, "href") == [settings(ctx.scope, adapter)]
        assert attribute(view, link, "title") == [title]
      end

      refute has_element?(view, "#backlog-empty-instance")
      refute has_element?(view, "#backlog-empty-who")
      refute has_element?(view, "#backlog-empty-offered-all")
    end

    test "a member reads the cards without Install, who installs, and whom to ask", ctx do
      adapter = offered("Tracker", @tracker)
      admin = admin(ctx.scope)
      {:ok, view, _html} = live(member(ctx.scope), page(ctx.scope))
      card = "#backlog-empty-offered-#{adapter.public_id}"

      assert has_element?(view, "#{card}-name")
      refute has_element?(view, "#{card}-install")

      assert texts(view, "#backlog-empty-who p") == [
               "Owners and admins of #{ctx.scope.organisation.name} install integrations.",
               "Ask #{short(ctx)} or #{short(admin)} to install one."
             ]
    end

    test "several cards by name, each in its adapter's words; Tickets for one with none",
         ctx do
      helpdesk = offered("Helpdesk", @helpdesk)
      forge = offered("Forge", @forge)
      plain = offered("Plain", @none)
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      assert attribute(view, "#backlog-empty-offered li", "id") ==
               Enum.map([forge, helpdesk, plain], &"backlog-empty-offered-#{&1.public_id}")

      assert texts(view, "#backlog-empty-offered li .text-muted") ==
               ["Issues from repositories", "Incidents from queues", "Tickets"]
    end

    test "more than six: the first six by name, then Show all", ctx do
      for n <- 1..7, do: offered("Tracker #{n}", @tracker)
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      assert length(texts(view, "#backlog-empty-offered li")) == 6
      assert words(view, "#backlog-empty-offered-all") == "Show all"

      assert attribute(view, "#backlog-empty-offered-all", "href") ==
               ["/#{ctx.scope.organisation.slug}/settings/integrations"]
    end

    test "offers no adapter without items, nor one the organisation is connected through",
         ctx do
      %{adapter: plain} = source(ctx.scope, "Plain", @none)

      {1, _} = Repo.update_all(from(n in Node, where: n.id == ^plain.id), set: [items: false])
      quiet = offered("Quiet", @none)
      {1, _} = Repo.update_all(from(n in Node, where: n.id == ^quiet.id), set: [items: false])

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))
      assert has_element?(view, ~s(#backlog-empty[data-state="none"]))
      refute has_element?(view, "#backlog-empty-offered")
      assert has_element?(view, "#backlog-empty-instance")
    end
  end

  describe "an integration that has not listed its collections" do
    test "says so in its words, with Open to an owner; the line alone to a member", ctx do
      %{adapter: adapter} = source(ctx.scope, "Tracker", @tracker, listed: false)
      workspace = ctx.scope.workspace.name

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))
      assert has_element?(view, ~s(#backlog-empty[data-state="unlisted"]))
      assert heading(view) == "#{adapter.name} hasn't listed its projects yet"

      assert words(view, "#backlog-empty-line-#{adapter.public_id}") ==
               "#{adapter.name} sends the list after the install. Then the tasks of the " <>
                 "projects assigned to #{workspace} appear here."

      open = "#backlog-empty-open-#{adapter.public_id}"
      assert words(view, open) == "Open #{adapter.name}"
      assert attribute(view, open, "href") == [settings(ctx.scope, adapter)]

      assert words(view, "#{open}-caption") ==
               "Organisation settings › Integrations › #{adapter.name}"

      {:ok, view, _html} = live(member(ctx.scope), page(ctx.scope))
      assert has_element?(view, "#backlog-empty-line-#{adapter.public_id}")
      refute has_element?(view, open)
    end

    test "with several, a box for each", ctx do
      %{adapter: forge} = source(ctx.scope, "Forge", @forge, listed: false)
      %{adapter: helpdesk} = source(ctx.scope, "Helpdesk", @helpdesk, listed: false)
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      assert texts(view, "#backlog-empty h2") == [
               "#{forge.name} hasn't listed its repositories yet",
               "#{helpdesk.name} hasn't listed its queues yet"
             ]
    end
  end

  describe "nothing assigned to the workspace" do
    test "with one integration: how many it lists, and Assign in its words", ctx do
      tracker = source(ctx.scope, "Tracker", @tracker)
      for _ <- 1..12, do: collection(ctx.scope, tracker, %{workspace_id: nil})
      org = ctx.scope.organisation.name
      workspace = ctx.scope.workspace.name

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))
      assert has_element?(view, ~s(#backlog-empty[data-state="unassigned"]))
      assert heading(view) == "No project is assigned to #{workspace}"

      assert words(view, "#backlog-empty-line") ==
               "#{tracker.adapter.name} lists 12 projects for #{org}. Assign the ones " <>
                 "#{workspace} works on, and their tasks appear here."

      assign = "#backlog-empty-assign-#{tracker.adapter.public_id}"
      assert words(view, assign) == "Assign projects"
      assert attribute(view, assign, "href") == [settings(ctx.scope, tracker.adapter)]

      assert words(view, "#{assign}-caption") ==
               "Organisation settings › Integrations › #{tracker.adapter.name}"

      refute has_element?(view, "#backlog-empty-who")
    end

    test "one collection in the singular", ctx do
      helpdesk = source(ctx.scope, "Helpdesk", @helpdesk)
      collection(ctx.scope, helpdesk, %{workspace_id: nil})
      workspace = ctx.scope.workspace.name
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      assert words(view, "#backlog-empty-line") ==
               "#{helpdesk.adapter.name} lists 1 queue for #{ctx.scope.organisation.name}. " <>
                 "Assign it if #{workspace} works on it, and its incidents appear here."
    end

    test "a member reads who assigns, and whom to ask", ctx do
      helpdesk = source(ctx.scope, "Helpdesk", @helpdesk)
      collection(ctx.scope, helpdesk, %{workspace_id: nil})
      {:ok, view, _html} = live(member(ctx.scope), page(ctx.scope))

      refute has_element?(view, "#backlog-empty-assign-#{helpdesk.adapter.public_id}")

      assert texts(view, "#backlog-empty-who p") == [
               "Only owners and admins of #{ctx.scope.organisation.name} assign queues " <>
                 "to workspaces.",
               "Ask #{short(ctx)} to assign the ones #{ctx.scope.workspace.name} works on."
             ]
    end

    test "with several: the nouns joined, a row for each with its count and Assign", ctx do
      forge = source(ctx.scope, "Forge", @forge)
      tracker = source(ctx.scope, "Tracker", @tracker)
      for _ <- 1..3, do: collection(ctx.scope, forge, %{workspace_id: nil})
      collection(ctx.scope, tracker, %{workspace_id: nil})
      workspace = ctx.scope.workspace.name

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))
      assert heading(view) == "No repository or project is assigned to #{workspace}"

      assert words(view, "#backlog-empty-line") ==
               "Assign the repositories and projects #{workspace} works on, and their " <>
                 "tickets appear here."

      assert attribute(view, "#backlog-empty-sources", "aria-label") == ["Integrations"]

      assert texts(view, "#backlog-empty-sources li") == [
               "#{tile(forge)}#{forge.adapter.name} 3 repositories Assign repositories",
               "#{tile(tracker)}#{tracker.adapter.name} 1 project Assign projects"
             ]

      assert attribute(view, "#backlog-empty-assign-#{tracker.adapter.public_id}", "title") ==
               ["Organisation settings › Integrations › #{tracker.adapter.name}"]

      {:ok, view, _html} = live(member(ctx.scope), page(ctx.scope))
      refute has_element?(view, "#backlog-empty-sources a")

      assert texts(view, "#backlog-empty-who p") |> hd() ==
               "Only owners and admins of #{ctx.scope.organisation.name} assign " <>
                 "repositories and projects to workspaces."
    end

    test "a source that names no words reads collection and tickets", ctx do
      plain = source(ctx.scope, "Plain", @none)
      forge = source(ctx.scope, "Forge", @forge)
      collection(ctx.scope, plain, %{workspace_id: nil})
      workspace = ctx.scope.workspace.name
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      assert heading(view) == "No repository or collection is assigned to #{workspace}"

      assert words(view, "#backlog-empty-line") ==
               "Assign the repositories and collections #{workspace} works on, and their " <>
                 "tickets appear here."

      assert words(view, "#backlog-empty-assign-#{plain.adapter.public_id}") ==
               "Assign collections"

      assert words(view, "#backlog-empty-assign-#{forge.adapter.public_id}") ==
               "Assign repositories"
    end
  end

  describe "the Backlog off for every collection assigned" do
    setup ctx do
      forge = source(ctx.scope, "Forge", @forge)

      for title <- ["acme/shop", "acme/web", "acme/api"],
          do: collection(ctx.scope, forge, %{title: title, backlog: false})

      %{forge: forge}
    end

    test "with no card: why, and Turn the Backlog on as the primary action", ctx do
      workspace = ctx.scope.workspace.name
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      assert has_element?(view, ~s(#backlog-empty[data-state="off"]))
      assert heading(view) == "No tickets come into #{workspace}'s Backlog"

      assert words(view, "#backlog-empty-line") ==
               "The Backlog is off for the 3 repositories assigned to #{workspace}."

      on = "#backlog-empty-turn-on"
      assert words(view, on) == "Turn the Backlog on"
      assert has_element?(view, "#{on}.btn-primary")
      assert attribute(view, on, "href") == [settings(ctx.scope, ctx.forge.adapter)]

      assert words(view, "#{on}-caption") ==
               "Organisation settings › Integrations › #{ctx.forge.adapter.name}"

      {:ok, view, _html} = live(member(ctx.scope), page(ctx.scope))
      refute has_element?(view, on)

      assert words(view, "#backlog-empty-who") ==
               "Only owners and admins change the Backlog switches."
    end

    test "with cards: install another system's integration, then Turn the Backlog on", ctx do
      helpdesk = offered("Helpdesk", @helpdesk)
      tracker = offered("Tracker", @tracker)
      workspace = ctx.scope.workspace.name

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      assert words(view, "#backlog-empty-line") ==
               "The Backlog is off for the 3 repositories assigned to #{workspace}. To take " <>
                 "#{workspace}'s tickets from another system, install its integration."

      assert attribute(view, "#backlog-empty-offered li", "id") ==
               Enum.map([helpdesk, tracker], &"backlog-empty-offered-#{&1.public_id}")

      assert has_element?(view, "#backlog-empty-turn-on.btn-ghost")
      refute has_element?(view, "#backlog-empty-who")

      {:ok, view, _html} = live(member(ctx.scope), page(ctx.scope))
      refute has_element?(view, "#backlog-empty-turn-on")
      refute has_element?(view, "#backlog-empty-offered-#{tracker.public_id}-install")

      assert texts(view, "#backlog-empty-who p") == [
               "Owners and admins of #{ctx.scope.organisation.name} install integrations.",
               "Ask #{short(ctx)} to install one."
             ]
    end

    test "one collection in the singular; a collection without items is not counted", ctx do
      Repo.delete_all(from c in Apiary.Adapters.Collection, where: c.title in ["acme/web"])
      [api] = Repo.all(from c in Apiary.Adapters.Collection, where: c.title == "acme/api")
      api |> Ecto.Changeset.change(items: false) |> Repo.update!()
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      assert words(view, "#backlog-empty-line") ==
               "The Backlog is off for the one repository assigned to " <>
                 "#{ctx.scope.workspace.name}."
    end

    test "with several integrations: their nouns joined, Turn on leads to the list", ctx do
      helpdesk = source(ctx.scope, "Helpdesk", @helpdesk)
      collection(ctx.scope, helpdesk, %{title: "Billing", backlog: false})
      workspace = ctx.scope.workspace.name
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      assert words(view, "#backlog-empty-line") ==
               "The Backlog is off for the 4 repositories and queues assigned to #{workspace}."

      assert attribute(view, "#backlog-empty-turn-on", "href") ==
               ["/#{ctx.scope.organisation.slug}/settings/integrations"]

      assert words(view, "#backlog-empty-turn-on-caption") ==
               "Organisation settings › Integrations"
    end
  end

  describe "the collections assigned have no items" do
    test "says so for each integration; the cards, and no Turn the Backlog on", ctx do
      forge = source(ctx.scope, "Forge", @forge)
      collection(ctx.scope, forge, %{items: false})
      tracker = offered("Tracker", @tracker)
      workspace = ctx.scope.workspace.name

      for conn <- [ctx.conn, member(ctx.scope)] do
        {:ok, view, _html} = live(conn, page(ctx.scope))

        assert has_element?(view, ~s(#backlog-empty[data-state="itemless"]))
        assert heading(view) == "No tickets come into #{workspace}'s Backlog"

        assert words(view, "#backlog-empty-line") ==
                 "The repositories assigned to #{workspace} have no issues at " <>
                   "#{forge.adapter.name}. To take #{workspace}'s tickets from another " <>
                   "system, install its integration."

        assert has_element?(view, "#backlog-empty-offered-#{tracker.public_id}")
        refute has_element?(view, "#backlog-empty-turn-on")
      end
    end

    test "with no card, no action and no line for a member", ctx do
      forge = source(ctx.scope, "Forge", @forge)
      collection(ctx.scope, forge, %{items: false})
      {:ok, view, _html} = live(member(ctx.scope), page(ctx.scope))

      assert has_element?(view, ~s(#backlog-empty[data-state="itemless"]))
      refute has_element?(view, "#backlog-empty-who")
      refute has_element?(view, "#backlog-empty-offered")
    end
  end

  describe "linked, and no ticket yet" do
    test "with one integration: its line, the collections, Change", ctx do
      forge = source(ctx.scope, "Forge", @forge)
      shop = collection(ctx.scope, forge, %{title: "acme/shop"})
      collection(ctx.scope, forge, %{title: "acme/off", backlog: false})
      workspace = ctx.scope.workspace.name

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))
      assert has_element?(view, ~s(#backlog-empty[data-state="waiting"]))
      assert heading(view) == "No issues yet"

      assert words(view, "#backlog-empty-line") ==
               "#{forge.adapter.name} lists the open issues of the repositories assigned " <>
                 "to #{workspace}, then sends each new one and each change."

      assert attribute(view, "#backlog-empty-linked", "aria-label") ==
               ["Repositories assigned to #{workspace}"]

      # A collection whose Backlog is off is left out.
      assert texts(view, "#backlog-empty-linked li") == ["#{tile(forge)}acme/shop No open issues"]
      assert has_element?(view, "#backlog-empty-linked-#{shop.public_id}")

      assert words(view, "#backlog-empty-change") == "Change the repositories"

      assert attribute(view, "#backlog-empty-change", "href") ==
               [settings(ctx.scope, forge.adapter)]

      refute has_element?(view, "#backlog-empty-who")
    end

    test "a member reads where each new ticket comes from", ctx do
      tracker = source(ctx.scope, "Tracker", @tracker)
      collection(ctx.scope, tracker, %{title: "Shop web"})
      {:ok, view, _html} = live(member(ctx.scope), page(ctx.scope))

      refute has_element?(view, "#backlog-empty-change")

      assert words(view, "#backlog-empty-who") ==
               "Each new task filed in one of these projects appears here."
    end

    test "with several: tickets, the nouns joined, Not listed yet, Change to the list", ctx do
      forge = source(ctx.scope, "Forge", @forge)
      helpdesk = source(ctx.scope, "Helpdesk", @helpdesk, complete: false)
      collection(ctx.scope, forge, %{title: "acme/shop"})
      collection(ctx.scope, helpdesk, %{title: "Billing"})
      workspace = ctx.scope.workspace.name

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))
      assert heading(view) == "No tickets yet"

      assert words(view, "#backlog-empty-line") ==
               "Each integration lists the open tickets of the repositories and queues " <>
                 "assigned to #{workspace}, then sends each new one and each change."

      assert attribute(view, "#backlog-empty-linked", "aria-label") ==
               ["Repositories and queues assigned to #{workspace}"]

      assert texts(view, "#backlog-empty-linked li") ==
               [
                 "#{tile(forge)}acme/shop No open issues",
                 "#{tile(helpdesk)}Billing Not listed yet"
               ]

      assert words(view, "#backlog-empty-change") == "Change the repositories and queues"

      assert attribute(view, "#backlog-empty-change", "href") ==
               ["/#{ctx.scope.organisation.slug}/settings/integrations"]

      assert words(view, "#backlog-empty-change-caption") ==
               "Organisation settings › Integrations"

      {:ok, view, _html} = live(member(ctx.scope), page(ctx.scope))

      assert words(view, "#backlog-empty-who") ==
               "Each new ticket filed in one of these repositories or queues appears here."
    end

    test "more than five: the first five, then how many more", ctx do
      forge = source(ctx.scope, "Forge", @forge)
      for n <- 1..9, do: collection(ctx.scope, forge, %{title: "acme/repo-#{n}"})
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      assert length(texts(view, "#backlog-empty-linked li[id^='backlog-empty-linked-sc_']")) ==
               5

      assert words(view, "#backlog-empty-linked-more") == "and 4 more"
    end
  end

  describe "the line under the title" do
    setup ctx do
      forge = source(ctx.scope, "Forge", @forge)
      %{forge: forge}
    end

    defp item(collection, attrs \\ %{}) do
      unique = System.unique_integer([:positive])

      source_item_fixture(
        %Apiary.Accounts.Scope{},
        Enum.into(attrs, %{
          collection: collection,
          external_ref: "ref-#{unique}",
          key: "##{unique}"
        })
      )
    end

    test "says Take in while a ticket of Open has a target, its own or its collection's",
         ctx do
      bare = collection(ctx.scope, ctx.forge, %{title: "acme/bare"})
      ticket = item(bare)
      workspace = ctx.scope.workspace.name

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      assert words(view, "#page-header-description") ==
               "Issues from the 1 repository assigned to #{workspace}."

      ticket
      |> Ecto.Changeset.change(target_system: "code.example.com", target_path: "acme/bare")
      |> Repo.update!()

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      assert words(view, "#page-header-description") ==
               "Issues from the 1 repository assigned to #{workspace}. Take one in to make " <>
                 "it a work item."
    end

    test "with several nouns, counts each apart", ctx do
      helpdesk = source(ctx.scope, "Helpdesk", @helpdesk)
      for _ <- 1..2, do: collection(ctx.scope, ctx.forge)

      queue =
        collection(ctx.scope, helpdesk, %{
          target_system: "code.example.com",
          target_path: "acme/queue"
        })

      item(queue)
      workspace = ctx.scope.workspace.name

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      assert words(view, "#page-header-description") ==
               "Tickets from the 2 repositories and 1 queue assigned to #{workspace}. " <>
                 "Take one in to make it a work item."

      assert texts(view, "#backlog-filter-sections .q-fm-label") |> hd() ==
               "Repository or queue"
    end
  end
end
