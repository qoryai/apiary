defmodule ApiaryWeb.BacklogLive.IndexTest do
  # A workspace's Backlog (`ApiaryWeb.BacklogLive.Index`): read by its members and not
  # found to anyone else; its views with their counts; Search; the Filter menu's
  # collections, Filed by, Label and Updated, their tokens, Clear and the match count;
  # Sort; the pager both ways; a forged cursor, filter, view, order or search, which
  # matches nothing or is the default and breaks nothing; the words of the source for its
  # items; and the list read again on a message of its workspace's Backlog, and not on
  # another's.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Repo
  alias Apiary.Adapters.Collection
  alias Apiary.Nodes.Node
  alias Apiary.Sources.{Item, Topic}

  @moduletag needs: :factory

  setup :register_and_log_in_user

  # acme/shop has a target, so a ticket of it can be taken in; acme/api has none.
  setup %{scope: scope} do
    connection = ticket_connection_fixture(scope)

    shop =
      source_collection_fixture(scope, connection, %{
        title: "acme/shop",
        target_system: "code.example.com",
        target_path: "acme/shop"
      })

    api = source_collection_fixture(scope, connection, %{title: "acme/api"})
    %{connection: connection, shop: shop, api: api}
  end

  defp page(scope, query \\ ""),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/backlog" <> query

  # A ticket of `collection`, with a ref and a key no other has, changed at the source
  # `minutes` before now (`:minutes`), and any other field `attrs` names.
  defp ticket(collection, attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    attrs = Map.new(attrs)
    {minutes, attrs} = Map.pop(attrs, :minutes, 0)
    at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-minutes, :minute)

    source_item_fixture(
      %Apiary.Accounts.Scope{},
      Enum.into(attrs, %{
        collection: collection,
        external_ref: "ref-#{unique}",
        key: "##{unique}",
        title: "Ticket #{unique}",
        source_created_at: at,
        source_updated_at: at
      })
    )
  end

  # The work item of `item` in the scope's workspace, in `state`.
  defp work_item(scope, %Item{} = item, state) do
    connection_id =
      Repo.one!(from c in Collection, where: c.id == ^item.collection_id, select: c.connection_id)

    work_item =
      work_item_fixture(scope, %{
        connection_id: connection_id,
        item_id: item.id,
        external_ref: item.external_ref
      })

    case state do
      :exploring ->
        work_item

      :declined ->
        work_item
        |> Ecto.Changeset.change(
          state: :declined,
          declined_at: DateTime.utc_now(),
          declined_by_id: scope.user.id
        )
        |> Repo.update!()
    end
  end

  defp row(item), do: "#ticket-#{item.public_id}"

  # The DOM ids of the rows, in their order.
  defp rows(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#backlog-rows > li")
    |> LazyHTML.attribute("id")
  end

  defp ids(items), do: Enum.map(items, &"ticket-#{&1.public_id}")

  defp words(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  # The texts of the elements `selector` names, each with its spaces made one.
  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

  # The params of the address the page patched to.
  defp patched(view),
    do: view |> assert_patch() |> URI.parse() |> Map.get(:query) |> URI.decode_query()

  defp member_conn(scope, level) do
    %{user: user} = member_fixture(scope, level)
    log_in_user(build_conn(), user)
  end

  describe "who reads it" do
    test "a member of the workspace reads it, as its owner does", %{scope: scope, shop: shop} do
      item = ticket(shop)

      for conn <- [member_conn(scope, :member), member_conn(scope, :admin)] do
        {:ok, view, _html} = live(conn, page(scope))
        assert has_element?(view, row(item))
        assert has_element?(view, "h1", "Backlog")
      end
    end

    test "is not found to someone outside the workspace, and shows them nothing",
         %{scope: scope, shop: shop} do
      ticket(shop, title: "Discount codes are case-sensitive")
      %{user: outsider} = sign_up_fixture()
      conn = build_conn() |> log_in_user(outsider) |> get(page(scope))

      assert conn.status == 404
      refute conn.resp_body =~ "Discount codes"
    end

    # In the core's edition every level of member reaches every workspace in use, so the
    # workspace a member does not reach is one deleted, marked for deletion.
    test "is not found to a member of the organisation who does not reach the workspace",
         %{scope: scope, connection: connection} do
      platform = workspace_fixture(scope.organisation, "Platform")

      collection =
        source_collection_fixture(scope, connection, %{
          title: "acme/platform",
          workspace_id: platform.id
        })

      ticket(collection, title: "Discount codes are case-sensitive")
      %{user: member} = member_fixture(scope, :member)

      {:ok, platform} = Apiary.Deletion.delete_workspace(scope, platform.id, platform.slug)

      assert workspace_scope(member, scope.workspace)
      assert workspace_scope(member, platform) == nil

      conn = build_conn() |> log_in_user(member) |> get(page(%{scope | workspace: platform}))

      assert conn.status == 404
      refute conn.resp_body =~ "Discount codes"
    end

    test "a Backlog with no ticket says why in place of the list", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, page(scope))
      assert has_element?(view, "h1", "Backlog")
      refute has_element?(view, "#backlog")
      # Its integration has not listed (`empty_test.exs` has each state).
      assert has_element?(view, ~s(#backlog-empty[data-state="unlisted"]))
      # An empty Backlog has no line under the title.
      refute has_element?(view, "#page-header-description")
    end
  end

  describe "the line under the title" do
    setup %{connection: connection} do
      %{adapter: Repo.get!(Node, connection.adapter_id)}
    end

    test "says where the tickets come from; the count links to the integration's page", ctx do
      ticket(ctx.shop)
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))
      workspace = ctx.scope.workspace.name

      assert words(view, "#page-header-description") ==
               "Tickets from the 2 collections assigned to #{workspace}. " <>
                 "Take one in to make it a work item."

      link = "#page-header-description a#backlog-integration"
      assert words(view, link) == "2 collections assigned to #{workspace}"

      assert has_element?(
               view,
               ~s(#{link}[href="/#{ctx.scope.organisation.slug}/settings/integrations/#{ctx.adapter.public_id}"])
             )

      assert view
             |> element(link)
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.attribute("title") ==
               ["Organisation settings › Integrations › #{ctx.adapter.name}"]
    end

    test "one collection in the singular", ctx do
      ticket(ctx.shop)

      ctx.api
      |> Ecto.Changeset.change(ended_at: DateTime.utc_now(), ended_reason: :disconnected)
      |> Repo.update!()

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      assert words(view, "#backlog-integration") ==
               "1 collection assigned to #{ctx.scope.workspace.name}"
    end

    test "counts a collection with its Backlog off; not another workspace's", ctx do
      ticket(ctx.shop)
      ctx.api |> Ecto.Changeset.change(backlog: false) |> Repo.update!()
      platform = workspace_fixture(ctx.scope.organisation, "Platform")
      there = workspace_scope(ctx.scope.user, platform)
      source_collection_fixture(there, ctx.connection, %{title: "acme/web"})
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      assert words(view, "#page-header-description") ==
               "Tickets from the 2 collections assigned to #{ctx.scope.workspace.name}. " <>
                 "Take one in to make it a work item."
    end

    test "in the source's words for its items and its collections", ctx do
      {1, _} =
        Repo.update_all(from(n in Node, where: n.id == ^ctx.adapter.id),
          set: [
            item_noun_one: "bug",
            item_noun_other: "bugs",
            collection_noun_one: "project",
            collection_noun_other: "projects"
          ]
        )

      ticket(ctx.shop)
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      assert words(view, "#page-header-description") ==
               "Bugs from the 2 projects assigned to #{ctx.scope.workspace.name}. " <>
                 "Take one in to make it a work item."
    end

    test "with two integrations, the words link to neither", ctx do
      other = ticket_connection_fixture(ctx.scope)
      ticket(source_collection_fixture(ctx.scope, other, %{title: "acme/web"}))
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      assert words(view, "#page-header-description") ==
               "Tickets from the 3 collections assigned to #{ctx.scope.workspace.name}."

      refute has_element?(view, "#page-header-description a")
    end

    test "beside an integration without items, link to the one with items", ctx do
      plain = ticket_connection_fixture(ctx.scope)

      {1, _} =
        Repo.update_all(from(n in Node, where: n.id == ^plain.adapter_id), set: [items: false])

      ticket(ctx.shop)
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      assert has_element?(
               view,
               ~s(#page-header-description a#backlog-integration[href="/#{ctx.scope.organisation.slug}/settings/integrations/#{ctx.adapter.public_id}"])
             )
    end
  end

  describe "the views" do
    setup %{scope: scope, shop: shop} do
      open = ticket(shop, minutes: 1)
      taken = ticket(shop, minutes: 2)
      declined = ticket(shop, minutes: 3)
      closed = ticket(shop, minutes: 4, state: :closed, state_reason: "Not planned")
      work_item(scope, taken, :exploring)
      work_item(scope, declined, :declined)
      %{open: open, taken: taken, declined: declined, closed: closed}
    end

    test "each view holds its tickets and says its count, Open first", ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      # Open leaves out the tickets Taken in and Declined hold.
      assert words(view, "#backlog-views") == "Open 1 Taken in 1 Declined 1 Closed 1"
      assert has_element?(view, ~s(#backlog-view-open[aria-current="page"]))
      assert rows(view) == ids([ctx.open])

      for {key, items} <- [taken: [ctx.taken], declined: [ctx.declined], closed: [ctx.closed]] do
        view |> element("#backlog-view-#{key}") |> render_click()
        assert_patch(view, page(ctx.scope, "?view=#{key}"))
        assert rows(view) == ids(items)
        assert has_element?(view, ~s(#backlog-view-#{key}[aria-current="page"]))
        refute has_element?(view, ~s(#backlog-view-open[aria-current="page"]))
      end

      # The counts stay those of every view.
      assert words(view, "#backlog-views") == "Open 1 Taken in 1 Declined 1 Closed 1"
    end

    test "a row is drawn by its ticket's record id, with its work item and its state word",
         ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?view=closed"))
      assert has_element?(view, row(ctx.closed), "Not planned")
      refute has_element?(view, "#ticket-#{ctx.closed.key}")

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?view=declined"))
      assert has_element?(view, "#{row(ctx.declined)} .q-bl-wi-declined")

      # Who declined it, the reader here, by their first letter, with their address as its
      # tooltip.
      email = ctx.scope.user.email
      letter = email |> String.first() |> String.upcase()
      in_row = &"#{row(ctx.declined)} .q-bl-w #{&1}"
      assert has_element?(view, in_row.(""), "Declined by")
      assert has_element?(view, in_row.(~s|abbr[data-tip="#{email} (you)"]|))
      only_letter = ~r/\A#{Regex.escape(letter)}\z/
      assert has_element?(view, in_row.("abbr [aria-hidden]"), only_letter)

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?view=taken"))
      assert has_element?(view, "#{row(ctx.taken)} a.q-bl-wi")

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))
      assert has_element?(view, "#{row(ctx.open)} .q-bl-take", "Take in")

      # The title opens the ticket by its record's id, never by the source's.
      assert view |> element("#{row(ctx.open)} a.q-bl-t") |> render() =~
               "ticket=#{ctx.open.public_id}"
    end

    test "a row has the tile of the integration its ticket came through", ctx do
      adapter = Repo.get!(Node, ctx.connection.adapter_id)
      other = ticket_connection_fixture(ctx.scope)

      {1, _} =
        Repo.update_all(from(n in Node, where: n.id == ^other.adapter_id),
          set: [name: "Tracker"]
        )

      elsewhere = ticket(source_collection_fixture(ctx.scope, other), minutes: 0)
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      tile = ~s(#{row(ctx.open)} .q-bl-tile[role="img"][aria-label="#{adapter.name}"])
      assert has_element?(view, tile)
      assert words(view, tile) == String.first(adapter.name)

      assert has_element?(view, ~s(#{row(elsewhere)} .q-bl-tile[aria-label="Tracker"]), "T")
    end
  end

  describe "Search" do
    setup %{shop: shop} do
      %{
        discount: ticket(shop, title: "Discount codes are case-sensitive", key: "#1231"),
        basket: ticket(shop, title: "The basket badge keeps the old count", key: "#902")
      }
    end

    test "searches the title, the number and the key, and says how many match", ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      assert has_element?(view, ~s(#backlog-search-input[placeholder="Search tickets"]))
      assert has_element?(view, "#backlog-search .sr-only", "Search the backlog")
      refute has_element?(view, "#backlog-match")

      for {text, expected} <- [
            {"discount", ctx.discount},
            {"1231", ctx.discount},
            {"#902", ctx.basket},
            {"BADGE", ctx.basket}
          ] do
        view |> form("#backlog-search", %{q: text}) |> render_change()
        assert_patch(view, page(ctx.scope, "?" <> URI.encode_query(q: text)))
        assert rows(view) == ids([expected])
        assert words(view, "#backlog-match") == "1 ticket matches"
      end

      view |> form("#backlog-search", %{q: "nothing like it"}) |> render_change()
      assert rows(view) == []
      assert words(view, "#backlog-match") == "0 tickets match"
      assert has_element?(view, "#backlog-views")
    end

    test "a search in the address is shown in the field, and a view keeps it", ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?q=basket"))
      assert has_element?(view, ~s(#backlog-search-input[value="basket"]))
      assert rows(view) == ids([ctx.basket])

      view |> element("#backlog-view-closed") |> render_click()
      assert patched(view) == %{"view" => "closed", "q" => "basket"}
    end
  end

  describe "the Filter menu" do
    setup %{shop: shop, api: api} do
      lea_shop = ticket(shop, minutes: 1, filed_by_name: "Lea", labels: ["bug", "checkout"])
      lea_api = ticket(api, minutes: 2, filed_by_name: "Lea", labels: ["bug"])

      bot_api =
        ticket(api,
          minutes: 3 * 24 * 60,
          filed_by_name: "deps-bot",
          filed_by_kind: :automation,
          labels: ["dependencies"]
        )

      %{lea_shop: lea_shop, lea_api: lea_api, bot_api: bot_api}
    end

    test "offers each section's values with their tickets, most first; Filed by by name",
         ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      assert texts(view, "#backlog-filter-sections .q-fm-label") ==
               ["Collection", "Filed by", "Label", "Updated"]

      # The bot's tile, a letter a screen reader skips, stands right before its name.
      assert words(view, "#backlog-filter-filed_by-form") == "Lea 2 ddeps-bot 1"
      assert words(view, "#backlog-filter-collection-form") == "acme/api 2 acme/shop 1"
      assert words(view, "#backlog-filter-label-form") == "bug 2 checkout 1 dependencies 1"

      assert texts(view, "#backlog-filter-updated-form .q-filter-option") ==
               ["Last hour", "Last 24 hours", "Last 7 days", "Last 14 days", "Last 30 days"]

      # A bot has a neutral tile with its first letter before its name; a person none.
      assert texts(view, "#backlog-filter-filed_by-form .q-bl-bot-av") == ["d"]

      assert has_element?(
               view,
               ~s|#backlog-filter-filed_by-form label:has(input[value="deps-bot"]) .q-bl-bot-av[aria-hidden="true"]|
             )

      refute has_element?(
               view,
               ~s|#backlog-filter-filed_by-form label:has(input[value="Lea"]) .q-bl-bot-av|
             )

      # The other sections have no tile.
      refute has_element?(view, "#backlog-filter-collection-form .q-bl-bot-av")
      refute has_element?(view, "#backlog-filter-label-form .q-bl-bot-av")
    end

    test "an address with repository in place of collection filters nothing", ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))
      all = rows(view)

      query = "?" <> Plug.Conn.Query.encode(repository: [ctx.api.id])
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, query))
      assert rows(view) == all
      refute has_element?(view, "#backlog-token-collection")
    end

    test "the collections' section and token are named in the source's word for one",
         ctx do
      query = "?" <> Plug.Conn.Query.encode(collection: [ctx.api.id])
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, query))

      # "Collection" where the source names none, in every kind of workspace.
      assert texts(view, "#backlog-filter-sections .q-fm-label") |> hd() == "Collection"
      assert words(view, "#backlog-token-collection") == "Collection acme/api"

      assert has_element?(
               view,
               ~s(#backlog-token-collection a[aria-label="Remove the collection filter"])
             )

      {1, _} =
        Repo.update_all(from(n in Node, where: n.id == ^ctx.connection.adapter_id),
          set: [collection_noun_one: "project", collection_noun_other: "projects"]
        )

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, query))
      assert texts(view, "#backlog-filter-sections .q-fm-label") |> hd() == "Project"
      assert words(view, "#backlog-token-collection") == "Project acme/api"
      assert words(view, "#backlog-filter-open-collection") == "Project acme/api"

      assert has_element?(
               view,
               ~s(#backlog-token-collection a[aria-label="Remove the project filter"])
             )

      refute has_element?(view, ~s(a[aria-label="Remove the collection filter"]))
    end

    test "Filed by keeps a filer's tickets, its token says so and takes it away", ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      view
      |> form("#backlog-filter-filed_by-form", %{"_filter" => "filed_by", "filed_by" => ["Lea"]})
      |> render_change()

      assert_patch(view, page(ctx.scope, "?" <> Plug.Conn.Query.encode(filed_by: ["Lea"])))
      assert rows(view) == ids([ctx.lea_shop, ctx.lea_api])
      assert words(view, "#backlog-token-filed_by") == "Filed by Lea"
      assert words(view, "#backlog-match") == "2 tickets match"
      assert has_element?(view, "#backlog-filter-button .q-listmenu-n", "1")

      view
      |> element(~s(#backlog-token-filed_by a[aria-label="Remove the filed-by filter"]))
      |> render_click()

      assert_patch(view, page(ctx.scope))
      assert length(rows(view)) == 3
      refute has_element?(view, "#backlog-tokens")
    end

    test "the collections' section keeps a collection's tickets by its id, named by its title",
         ctx do
      query = "?" <> Plug.Conn.Query.encode(collection: [ctx.shop.id])
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, query))

      assert rows(view) == ids([ctx.lea_shop])
      assert words(view, "#backlog-token-collection") == "Collection acme/shop"
      assert words(view, "#backlog-match") == "1 ticket matches"

      assert has_element?(
               view,
               ~s(#backlog-filter-collection-form input[value="#{ctx.shop.id}"][checked])
             )

      view
      |> element(~s(#backlog-token-collection a[aria-label="Remove the collection filter"]))
      |> render_click()

      assert length(rows(view)) == 3
    end

    test "Label keeps the tickets that carry a label, Updated those changed in a window", ctx do
      {:ok, view, _html} =
        live(ctx.conn, page(ctx.scope, "?" <> Plug.Conn.Query.encode(label: ["checkout"])))

      assert rows(view) == ids([ctx.lea_shop])
      assert words(view, "#backlog-token-label") == "Label checkout"

      view
      |> form("#backlog-filter-updated-form", %{"_filter" => "updated", "updated" => "24h"})
      |> render_change()

      assert patched(view) == %{"label[]" => "checkout", "updated" => "24h"}
      assert rows(view) == ids([ctx.lea_shop])

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?updated=24h"))
      assert rows(view) == ids([ctx.lea_shop, ctx.lea_api])
      assert words(view, "#backlog-token-updated") == "Updated Last 24 hours"
      assert words(view, "#backlog-filter-open-updated") == "Updated Last 24 hours"
    end

    test "the Label and Updated tokens each have a × that takes that filter away", ctx do
      query = "?" <> Plug.Conn.Query.encode(label: ["checkout"], updated: "24h", q: "Ticket")
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, query))
      assert rows(view) == ids([ctx.lea_shop])

      view
      |> element(~s(#backlog-token-label a[aria-label="Remove the label filter"]))
      |> render_click()

      assert patched(view) == %{"q" => "Ticket", "updated" => "24h"}
      assert rows(view) == ids([ctx.lea_shop, ctx.lea_api])
      refute has_element?(view, "#backlog-token-label")

      view
      |> element(~s(#backlog-token-updated a[aria-label="Remove the updated filter"]))
      |> render_click()

      assert patched(view) == %{"q" => "Ticket"}
      assert rows(view) == ids([ctx.lea_shop, ctx.lea_api, ctx.bot_api])
      refute has_element?(view, "#backlog-tokens")
    end

    test "Clear takes every filter away and keeps the view and the search", ctx do
      query =
        "?" <>
          Plug.Conn.Query.encode(
            view: "open",
            q: "Ticket",
            collection: [ctx.api.id],
            filed_by: ["Lea"],
            label: ["bug"],
            updated: "24h"
          )

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, query))
      assert rows(view) == ids([ctx.lea_api])
      assert has_element?(view, "#backlog-filter-button .q-listmenu-n", "4")

      view |> element("#backlog-tokens-clear") |> render_click()
      assert_patch(view, page(ctx.scope, "?q=Ticket"))
      assert rows(view) == ids([ctx.lea_shop, ctx.lea_api, ctx.bot_api])
      refute has_element?(view, "#backlog-tokens")
    end

    test "Filed by always has Find a name; the other sections only above eight values",
         ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      # Two filers, Lea and deps-bot.
      assert length(texts(view, "#backlog-filter-filed_by-form .q-filter-option")) == 2
      assert has_element?(view, ~s(#backlog-filter-filed_by-search[placeholder="Find a name"]))

      for key <- ["collection", "label", "updated"] do
        refute has_element?(view, "#backlog-filter-#{key}-search"), key
      end
    end

    test "Find a name narrows Filed by's values on the server", ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      for n <- 1..8, do: ticket(ctx.shop, filed_by_name: "Filer #{n}")
      send(view.pid, {:tickets_changed, []})

      assert has_element?(
               view,
               ~s(#backlog-filter-filed_by-search[placeholder="Find a name"][aria-label="Find a name"])
             )

      view
      |> form("#backlog-filter-filed_by-narrow", %{"_filter" => "filed_by", "q" => "bot"})
      |> render_change()

      assert words(view, "#backlog-filter-filed_by-form") == "ddeps-bot 1"
      assert texts(view, "#backlog-filter-filed_by-form .q-bl-bot-av") == ["d"]
    end
  end

  describe "Sort" do
    test "by the latest change, the newest ticket or the most comments", %{
      conn: conn,
      scope: scope,
      shop: shop
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      old =
        ticket(shop,
          source_created_at: DateTime.add(now, -3, :day),
          source_updated_at: DateTime.add(now, -1, :minute),
          comment_count: 1
        )

      new =
        ticket(shop,
          source_created_at: DateTime.add(now, -1, :day),
          source_updated_at: DateTime.add(now, -2, :hour),
          comment_count: 7
        )

      middle =
        ticket(shop,
          source_created_at: DateTime.add(now, -2, :day),
          source_updated_at: DateTime.add(now, -1, :hour),
          comment_count: 0
        )

      {:ok, view, _html} = live(conn, page(scope))
      assert rows(view) == ids([old, middle, new])
      assert has_element?(view, ~s(#backlog-sort-button[aria-label="Sort: Recently updated"]))
      assert words(view, "#backlog-sort ul") == "Sort by Recently updated Newest Most comments"

      view |> element("#backlog-sort-created") |> render_click()
      assert_patch(view, page(scope, "?sort=created"))
      assert rows(view) == ids([new, middle, old])
      assert has_element?(view, ~s(#backlog-sort-created[aria-checked="true"]))

      view |> element("#backlog-sort-comments") |> render_click()
      assert_patch(view, page(scope, "?sort=comments"))
      assert rows(view) == ids([new, old, middle])
    end
  end

  describe "the pager" do
    test "Older to the last page and Newer back to the first", %{
      conn: conn,
      scope: scope,
      shop: shop
    } do
      tickets = for minutes <- 1..52, do: ticket(shop, minutes: minutes)

      {:ok, view, _html} = live(conn, page(scope))
      assert rows(view) == ids(Enum.take(tickets, 50))
      assert words(view, "#backlog-pager-footer") == "1–50 of 52"
      assert has_element?(view, "#backlog-pager-previous[disabled]")

      view |> element("#backlog-pager-next") |> render_click()
      assert rows(view) == ids(Enum.drop(tickets, 50))
      assert words(view, "#backlog-pager-footer") == "51–52 of 52"
      assert has_element?(view, "#backlog-pager-next[disabled]")

      view |> element("#backlog-pager-previous") |> render_click()
      assert rows(view) == ids(Enum.take(tickets, 50))
      assert words(view, "#backlog-pager-footer") == "1–50 of 52"
    end

    test "has no pager while the view fits one page", %{conn: conn, scope: scope, shop: shop} do
      ticket(shop)
      {:ok, view, _html} = live(conn, page(scope))
      refute has_element?(view, "#backlog-pager")
    end
  end

  describe "a forged address" do
    setup %{shop: shop}, do: %{item: ticket(shop, filed_by_name: "Lea")}

    test "a cursor, a filter value or a search that is not one matches nothing and breaks nothing",
         ctx do
      for query <- [
            "?after=ud.1.tk_nothing",
            "?before=garbage",
            "?after[x]=1",
            "?collection=not-an-id",
            "?collection[]=#{Ecto.UUID.generate()}",
            "?filed_by[x]=Lea",
            "?label=" <> String.duplicate("x", 101),
            "?updated=99y",
            "?updated[]=1h",
            "?q[]=Lea"
          ] do
        {:ok, view, _html} = live(ctx.conn, page(ctx.scope, query))
        assert rows(view) == [], query
        assert has_element?(view, "#backlog-views"), query
      end
    end

    test "a filter is read to its first 100 values, so a longer list is not drawn in full",
         ctx do
      labels = for n <- 1..150, do: "label-#{String.pad_leading("#{n}", 3, "0")}"

      {:ok, view, _html} =
        live(ctx.conn, page(ctx.scope, "?" <> Plug.Conn.Query.encode(label: labels)))

      html = view |> render() |> LazyHTML.from_fragment()

      checked = LazyHTML.query(html, "#backlog-filter-label-form input[checked]")
      assert Enum.count(checked) == 100

      drawn =
        html
        |> LazyHTML.query("#backlog-token-label .q-tok-v")
        |> LazyHTML.text()
        |> String.trim()

      assert String.split(drawn, ", ") == Enum.take(labels, 100)
    end

    test "a view or an order it does not know is the default", ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?view=elsewhere&sort=random"))
      assert rows(view) == ids([ctx.item])
      assert has_element?(view, ~s(#backlog-view-open[aria-current="page"]))
      assert has_element?(view, ~s(#backlog-sort-updated[aria-checked="true"]))
    end

    test "a filter value is shown as text", ctx do
      {:ok, view, _html} =
        live(ctx.conn, page(ctx.scope, "?" <> URI.encode_query(label: "<b>x</b>")))

      assert words(view, "#backlog-token-label") == "Label <b>x</b>"
      refute has_element?(view, "#backlog-token-label b b")
    end
  end

  describe "the Closed view's line" do
    setup %{connection: connection} do
      %{adapter: Repo.get!(Node, connection.adapter_id)}
    end

    test "says which tickets Closed holds and where they are closed, on Closed alone", ctx do
      ticket(ctx.shop, state: :closed)
      ticket(ctx.shop)

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))
      refute has_element?(view, "#backlog-view-line")

      view |> element("#backlog-view-closed") |> render_click()

      assert words(view, "#backlog-view-line") ==
               "Tickets that are closed on #{ctx.adapter.name}."

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?view=taken"))
      refute has_element?(view, "#backlog-view-line")
    end

    test "in the source's words for its items", %{connection: connection} = ctx do
      {1, _} =
        Repo.update_all(from(n in Node, where: n.id == ^connection.adapter_id),
          set: [item_noun_one: "bug", item_noun_other: "bugs"]
        )

      ticket(ctx.shop, state: :closed)
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?view=closed"))

      assert words(view, "#backlog-view-line") ==
               "Bugs that are closed on #{ctx.adapter.name}."
    end

    test "is left out where several integrations connect the organisation, none named", ctx do
      ticket(ctx.shop, state: :closed)
      other = ticket_connection_fixture(ctx.scope)
      ticket(source_collection_fixture(ctx.scope, other, %{title: "acme/web"}))

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?view=closed"))
      assert rows(view) |> length() == 1
      refute has_element?(view, "#backlog-view-line")
    end
  end

  describe "the Declined view's line" do
    setup %{connection: connection} do
      %{adapter: Repo.get!(Node, connection.adapter_id)}
    end

    test "says which tickets Declined holds and where they stay open, on Declined alone",
         ctx do
      work_item(ctx.scope, ticket(ctx.shop), :declined)

      for view <- ["open", "taken", "closed"] do
        {:ok, view_page, _html} = live(ctx.conn, page(ctx.scope, "?view=#{view}"))
        refute has_element?(view_page, "#backlog-view-line", "declined"), view
      end

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))
      view |> element("#backlog-view-declined") |> render_click()

      assert words(view, "#backlog-view-line") ==
               "Tickets whose work item a member declined after Explore. They stay open on " <>
                 "#{ctx.adapter.name}, and Open leaves them out. Take in again brings back " <>
                 "the same work item."
    end

    test "in the source's words for its items", %{connection: connection} = ctx do
      {1, _} =
        Repo.update_all(from(n in Node, where: n.id == ^connection.adapter_id),
          set: [item_noun_one: "bug", item_noun_other: "bugs"]
        )

      work_item(ctx.scope, ticket(ctx.shop), :declined)
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?view=declined"))

      assert words(view, "#backlog-view-line") =~
               ~r/^Bugs whose work item a member declined after Explore\. They stay open on /
    end

    test "is left out where several integrations connect the organisation, none named", ctx do
      work_item(ctx.scope, ticket(ctx.shop), :declined)
      other = ticket_connection_fixture(ctx.scope)
      ticket(source_collection_fixture(ctx.scope, other, %{title: "acme/web"}))

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?view=declined"))
      assert rows(view) |> length() == 1
      refute has_element?(view, "#backlog-view-line")
    end

    test "is said beside an integration without items, naming the one with items", ctx do
      work_item(ctx.scope, ticket(ctx.shop), :declined)
      plain = ticket_connection_fixture(ctx.scope)

      {1, _} =
        Repo.update_all(from(n in Node, where: n.id == ^plain.adapter_id), set: [items: false])

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))
      view |> element("#backlog-view-declined") |> render_click()

      assert words(view, "#backlog-view-line") ==
               "Tickets whose work item a member declined after Explore. They stay open on " <>
                 "#{ctx.adapter.name}, and Open leaves them out. Take in again brings back " <>
                 "the same work item."
    end
  end

  describe "the source's words" do
    test "a source that names its items is read in its words", %{
      conn: conn,
      scope: scope,
      connection: connection,
      shop: shop
    } do
      {1, _} =
        Repo.update_all(from(n in Node, where: n.id == ^connection.adapter_id),
          set: [item_noun_one: "bug", item_noun_other: "bugs"]
        )

      ticket(shop, title: "Discount codes")
      {:ok, view, _html} = live(conn, page(scope, "?q=discount"))

      assert has_element?(view, ~s(#backlog-search-input[placeholder="Search bugs"]))
      assert words(view, "#backlog-match") == "1 bug matches"
    end
  end

  describe "live" do
    test "a message of the workspace's Backlog reads the list again", %{
      conn: conn,
      scope: scope,
      shop: shop
    } do
      first = ticket(shop, minutes: 5)
      {:ok, view, _html} = live(conn, page(scope))
      assert rows(view) == ids([first])

      added = ticket(shop, minutes: 1)

      Phoenix.PubSub.broadcast(
        Apiary.PubSub,
        Topic.topic(scope.workspace.id),
        {:tickets_changed, []}
      )

      assert rows(view) == ids([added, first])
      assert words(view, "#backlog-views") == "Open 2 Taken in 0 Declined 0 Closed 0"
    end

    test "a message of another workspace's Backlog changes nothing", %{
      conn: conn,
      scope: scope,
      shop: shop
    } do
      first = ticket(shop, minutes: 5)
      {:ok, view, _html} = live(conn, page(scope))

      ticket(shop, minutes: 1)
      other = workspace_fixture(scope.organisation, "Platform")

      Phoenix.PubSub.broadcast(
        Apiary.PubSub,
        Topic.topic(other.id),
        {:tickets_changed, []}
      )

      assert rows(view) == ids([first])
      assert words(view, "#backlog-views") == "Open 1 Taken in 0 Declined 0 Closed 0"
    end
  end

  describe "what the integration sent, as a page shows an external system's text" do
    # A bidirectional override, a zero-width space and a control character, and what is
    # left of them on the page (`Apiary.ExternalText.line/1`).
    defp sent(text), do: "\u202E" <> text <> "\u200B\a"
    defp shown(text), do: text <> "\uFFFD"

    test "a row in <bdi>, and the Filter menu's values and a token: cleaned", ctx do
      web = source_collection_fixture(ctx.scope, ctx.connection, %{title: sent("acme/web")})

      item =
        ticket(web,
          title: sent("Fix the login"),
          filed_by_name: sent("Lea"),
          labels: [sent("bug")]
        )

      query = "?" <> Plug.Conn.Query.encode(collection: [web.id])
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, query))

      assert has_element?(view, "#{row(item)} a.q-bl-t > bdi", shown("Fix the login"))
      assert has_element?(view, "#{row(item)} .q-bl-rp > bdi", shown("acme/web"))
      assert has_element?(view, ~s(#{row(item)} .q-bl-rp[title="#{shown("acme/web")}"]))
      assert has_element?(view, "#{row(item)} .q-bl-filer bdi", shown("Lea"))

      for {section, value} <- [collection: "acme/web", filed_by: "Lea", label: "bug"] do
        assert has_element?(
                 view,
                 ~s(#backlog-filter-#{section}-form span[title="#{shown(value)}"]),
                 shown(value)
               )
      end

      assert words(view, "#backlog-token-collection") == "Collection " <> shown("acme/web")
    end

    test "a value with nothing left to show, offered or only chosen: marked", ctx do
      web = source_collection_fixture(ctx.scope, ctx.connection, %{title: "acme/web"})
      ticket(web, title: "Fix the login", labels: ["\u200B"])
      # The first a ticket carries, so it is offered; the second only chosen.
      query = "?" <> Plug.Conn.Query.encode(label: ["\u200B", "\u2060"])
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, query))

      form = view |> element("#backlog-filter-label-form") |> render() |> LazyHTML.from_fragment()

      shown =
        form |> LazyHTML.query(".q-filter-option > span > bdi") |> Enum.map(&LazyHTML.text/1)

      assert Enum.count(shown, &(&1 == "\uFFFD")) == 2

      token = view |> element("#backlog-token-label") |> render() |> LazyHTML.from_fragment()
      values = token |> LazyHTML.query(".q-tok-v bdi") |> Enum.map(&LazyHTML.text/1)
      assert values == ["\uFFFD", "\uFFFD"]
    end

    test "a token's values: each isolated in a <bdi>, all of them in its title", ctx do
      web = source_collection_fixture(ctx.scope, ctx.connection, %{title: "acme/web"})
      ticket(web, title: "Fix the login", labels: ["\u05D1\u05D0\u05D2", "checkout"])
      query = "?" <> Plug.Conn.Query.encode(label: ["\u05D1\u05D0\u05D2", "checkout"])
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, query))

      token = view |> element("#backlog-token-label") |> render() |> LazyHTML.from_fragment()
      values = token |> LazyHTML.query(".q-tok-v bdi") |> Enum.map(&LazyHTML.text/1)
      assert Enum.sort(values) == Enum.sort(["\u05D1\u05D0\u05D2", "checkout"])
      [title] = token |> LazyHTML.query(".q-tok-v") |> LazyHTML.attribute("title")
      assert title == Enum.join(values, ", ")
      assert words(view, "#backlog-token-label") == "Label " <> Enum.join(values, ", ")
    end
  end
end
