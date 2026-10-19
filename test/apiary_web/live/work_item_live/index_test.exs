defmodule ApiaryWeb.WorkItemLive.IndexTest do
  # A workspace's Work items list (`ApiaryWeb.WorkItemLive.Index`): read by its members
  # and not found to anyone else, to a person not shown the feature, or to a member who
  # does not reach the workspace; the stages strip, the Open view's bands and a stage
  # alone; the views with their counts and each row's status; Waiting on you, and the
  # sidebar's count beside Work items; Search; the Filter menu, its tokens and the match
  # count, the collections' section in their sources' words; Sort; the pager; a forged
  # view, stage, sort or cursor; the texts of an external system; a row the instance
  # closed; the people the list names, by their accounts; the empty list; the list read
  # again on a message of its workspace's work items, with the scope first; and an event
  # it does not know.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Edition, EditionStubs, Repo, WorkItems}
  alias Apiary.Accounts.User
  alias Apiary.Dispatches.Settle
  alias Apiary.WorkItems.{Confirmation, WorkItem, WorkList}

  @moduletag needs: :factory

  setup :register_and_log_in_user

  defp page(scope, query \\ ""), do: ~p"/#{scope.organisation}/#{scope.workspace}/work" <> query

  defp item!(scope, attrs \\ %{}), do: work_item_fixture(scope, attrs)

  defp set!(work_item, fields) do
    {1, _} = Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id), set: fields)
    Repo.get!(WorkItem, work_item.id)
  end

  # A live work item of the scope's workspace at `status`, its runs written as their
  # writers write them, each ended run settled.
  defp at!(scope, status, attrs \\ %{}) do
    work_item = item!(scope, attrs)
    run!(work_item, status)
    Repo.get!(WorkItem, work_item.id)
  end

  defp run!(work_item, status) do
    runs =
      case status do
        :queued -> []
        :running -> [[state: :handed_over]]
        :confirm -> [[result: understood_result()]]
        :questions -> [[result: questions_result()]]
        :used_up -> List.duplicate([result: questions_result()], 3)
        :shape -> [[result: understood_result()]]
      end

    for opts <- runs do
      %{dispatch_run: dispatch_run} = explore_run_fixture(work_item, opts)
      Settle.settle(dispatch_run.id)
    end

    if status == :shape do
      Repo.insert!(%Confirmation{
        organisation_id: work_item.organisation_id,
        workspace_id: work_item.workspace_id,
        work_item_id: work_item.id,
        take_in: work_item.take_in,
        attempt: 1,
        result: understood_result(),
        confirmed_at: DateTime.utc_now()
      })
    end
  end

  defp row(work_item), do: "#work-item-#{work_item.public_id}"

  # The DOM ids of the rows, in their order.
  defp rows(view, selector \\ "#work-items") do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#{selector} li[id^='work-item-']")
    |> LazyHTML.attribute("id")
  end

  defp ids(items), do: Enum.map(items, &"work-item-#{&1.public_id}")

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

  defp name(%User{email: email}), do: User.short_name(email)

  describe "who reads it" do
    test "a member of the workspace reads it, as its owner and an admin do", %{
      conn: conn,
      scope: scope
    } do
      work_item = item!(scope)

      {:ok, view, _html} = live(conn, page(scope))
      assert has_element?(view, row(work_item))

      for level <- [:member, :admin] do
        %{user: user} = member_fixture(scope, level)
        {:ok, view, _html} = live(log_in_user(build_conn(), user), page(scope))
        assert has_element?(view, row(work_item))
        assert has_element?(view, "h1", "Work items")
      end
    end

    test "is not found to someone outside the workspace, and shows them nothing",
         %{scope: scope} do
      item!(scope, title: "Discount codes are case-sensitive")
      %{user: outsider} = sign_up_fixture()
      conn = build_conn() |> log_in_user(outsider) |> get(page(scope))

      assert conn.status == 404
      refute conn.resp_body =~ "Discount codes"
    end

    test "is not found to a person who is not shown the feature", %{conn: conn, scope: scope} do
      item!(scope, title: "Discount codes are case-sensitive")
      :ok = Edition.put_test_stub(EditionStubs.HidesNamed)
      :ok = EditionStubs.HidesNamed.put([:factory])

      {404, _headers, body} = assert_error_sent(404, fn -> get(conn, page(scope)) end)
      refute body =~ "Discount codes"
    end

    test "a member who does not reach a workspace finds it not found, and sees nothing of it",
         %{conn: conn, scope: scope} do
      :ok = Edition.put_test_stub(EditionStubs.MembersReachNamed)
      platform = workspace_fixture(scope.organisation, "Platform")
      ours = item!(scope, title: "The basket loses an item")
      theirs = item!(%{scope | workspace: platform}, title: "Discount codes are case-sensitive")
      %{user: member} = member_fixture(scope, :member)
      EditionStubs.MembersReachNamed.put([scope.workspace.id])
      member_conn = log_in_user(build_conn(), member)

      other = get(member_conn, page(%{scope | workspace: platform}))
      assert other.status == 404
      refute other.resp_body =~ "Discount codes"

      {:ok, view, html} = live(member_conn, page(scope))
      assert rows(view) == ids([ours])
      refute html =~ "Discount codes"

      # The owner reaches both.
      {:ok, view, _html} = live(conn, page(%{scope | workspace: platform}))
      assert rows(view) == ids([theirs])
    end
  end

  describe "the Open view" do
    setup %{scope: scope} do
      %{user: member} = member_fixture(scope, :member)

      %{
        member: member,
        queued: at!(scope, :queued),
        running: at!(scope, :running),
        questions: at!(scope, :questions),
        used_up: at!(scope, :used_up),
        mine: at!(scope, :confirm),
        theirs: at!(scope, :confirm, owner_id: member.id),
        shape: at!(scope, :shape)
      }
    end

    test "shows the stages as a strip and as bands, each row with its status", ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      for {stage, count, attention} <- [
            {:explore, "4", ["1 exploring", "1 waits for answers"]},
            {:confirm, "2", ["1 waits for you"]},
            {:shape, "1", ["1 ready"]}
          ] do
        assert words(view, "#work-items-stages-#{stage} .q-wl-st-n") == count
        assert texts(view, "#work-items-stages-#{stage} .q-wl-attn") == attention
      end

      assert words(view, "#work-items-views") ==
               "Open 7 Waiting on you 1 Declined 0 Closed 0"

      assert Enum.sort(rows(view, "#work-items-explore")) ==
               Enum.sort(ids([ctx.queued, ctx.running, ctx.questions, ctx.used_up]))

      # The reader's first.
      assert rows(view, "#work-items-confirm") == ids([ctx.mine, ctx.theirs])
      assert rows(view, "#work-items-shape") == ids([ctx.shape])

      for {work_item, status} <- [
            {ctx.queued, "Explore is queued"},
            {ctx.running, "Qory is exploring"},
            {ctx.questions, "Waits for answers"},
            {ctx.used_up, "Explore used its 3 runs"},
            {ctx.mine, "Waits for you to confirm"},
            {ctx.theirs, "Waits for #{name(ctx.member)} to confirm"},
            {ctx.shape, "Ready for Shape"}
          ] do
        assert words(view, row(work_item) <> " .q-wl-nx") == status
      end

      assert has_element?(view, row(ctx.mine) <> " .q-wl-row-hot")
      refute has_element?(view, row(ctx.theirs) <> " .q-wl-row-hot")

      assert has_element?(
               view,
               ~s(#{row(ctx.mine)} a[href="#{page(ctx.scope, "/#{ctx.mine.number}")}"])
             )
    end

    test "a stage alone is a band of its rows, from its strip's link", ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      view |> element("#work-items-stages-confirm") |> render_click()
      assert patched(view) == %{"stage" => "confirm"}

      assert Enum.sort(rows(view, "#work-items-confirm")) ==
               Enum.sort(ids([ctx.mine, ctx.theirs]))

      refute has_element?(view, "#work-items-explore")
    end

    test "a stage it does not know shows nothing", ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?stage=nonsense"))
      assert rows(view) == []
      assert words(view, "#work-items-views") =~ "Open 7"
    end

    test "Show all leads to a stage that holds more than its band", %{conn: conn, scope: scope} do
      for _n <- 1..WorkList.band_size(), do: item!(scope)
      {:ok, view, _html} = live(conn, page(scope))

      assert length(rows(view, "#work-items-explore")) == WorkList.band_size()

      assert has_element?(
               view,
               ~s(#work-items-explore-all[href="#{page(scope, "?stage=explore")}"]),
               "Show all #{WorkList.band_size() + 4} in Explore"
             )
    end
  end

  describe "Waiting on you" do
    setup %{scope: scope} do
      %{user: member} = member_fixture(scope, :member)
      base = DateTime.utc_now()

      older = at!(scope, :confirm) |> set!(updated_at: DateTime.add(base, -60, :second))
      newer = at!(scope, :confirm) |> set!(updated_at: DateTime.add(base, -30, :second))
      theirs = at!(scope, :confirm, owner_id: member.id)
      questions = at!(scope, :questions)
      shape = at!(scope, :shape)

      %{older: older, newer: newer, theirs: theirs, questions: questions, shape: shape}
    end

    test "holds the reader's work items that wait at Confirm, oldest first, with its note",
         ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))
      view |> element("#work-items-views-you") |> render_click()
      assert patched(view) == %{"view" => "you"}

      assert rows(view) == ids([ctx.older, ctx.newer])

      assert words(view, "#work-items-note") ==
               "Work items that wait for you to confirm what Qory proposes. Oldest first."

      for other <- [ctx.theirs, ctx.questions, ctx.shape],
          do: refute(has_element?(view, row(other)))
    end

    test "the sidebar counts the same beside Work items", ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      assert words(view, "#nav-work_items .q-nav-count") == "2"

      assert has_element?(
               view,
               ~s(#nav-work_items .q-nav-count[title="Work items: 2 wait for you"])
             )

      assert ApiaryWeb.UserAuth.nav_counts(ctx.scope).waiting_on == 2
    end
  end

  describe "the ended views" do
    test "Declined and Closed say who ended each one", %{conn: conn, scope: scope} do
      %{user: member} = member_fixture(scope, :member)
      now = DateTime.utc_now()

      declined =
        at!(scope, :confirm)
        |> set!(state: :declined, declined_at: now, declined_by_id: scope.user.id)

      closed = item!(scope) |> set!(state: :closed, closed_at: now, closed_by_id: member.id)
      undone = item!(scope)
      {:ok, _undone} = WorkItems.undo(scope, undone)

      {:ok, view, _html} = live(conn, page(scope, "?view=declined"))
      assert rows(view) == ids([declined])
      assert words(view, row(declined) <> " .q-wl-nx") == "Declined by you"
      assert has_element?(view, "#work-items-note")

      {:ok, view, _html} = live(conn, page(scope, "?view=closed"))
      assert Enum.sort(rows(view)) == Enum.sort(ids([closed, undone]))
      assert words(view, row(closed) <> " .q-wl-nx") == "Closed by #{name(member)}"
      assert words(view, row(undone) <> " .q-wl-nx") == "Undone by you"
      refute has_element?(view, "#work-items-note")
    end

    test "a row the instance closed when its integration was removed says so",
         %{conn: conn, scope: scope} do
      work_item = item!(scope)

      {:ok, _queues} =
        Repo.transact(fn ->
          locked = Repo.one!(from w in WorkItem, where: w.id == ^work_item.id, lock: "FOR UPDATE")
          WorkItems.close_locked([locked], {:instance, "adapter_removed"}, DateTime.utc_now())
        end)

      {:ok, view, _html} = live(conn, page(scope, "?view=closed"))
      assert rows(view) == ids([work_item])

      assert words(view, row(work_item) <> " .q-wl-nx") ==
               "Closed when its integration was removed"
    end

    test "a forged view is Open", %{conn: conn, scope: scope} do
      work_item = item!(scope)
      {:ok, view, _html} = live(conn, page(scope, "?view=nonsense"))
      assert rows(view) == ids([work_item])
    end
  end

  describe "people" do
    # What the list says of `user`, who owns a work item at Confirm and closed another,
    # once `change` ran: the row's owner, Confirm's line on the strip filtered to them,
    # the Filter menu's owners, and the Closed view's line.
    defp said_of(conn, scope, user, change) do
      owned = at!(scope, :confirm, owner_id: user.id)

      closed =
        item!(scope) |> set!(state: :closed, closed_at: DateTime.utc_now(), closed_by_id: user.id)

      change.()

      {:ok, view, _html} = live(conn, page(scope, "?owner[]=#{user.id}"))

      owner =
        view
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query(row(owned) <> " .q-wl-own")
        |> LazyHTML.attribute("aria-label")

      said = %{
        owner: owner,
        waiting: texts(view, "#work-items-stages-confirm .q-wl-attn"),
        options: texts(view, "#work-items-filter-owner-form .q-filter-option")
      }

      {:ok, view, _html} = live(conn, page(scope, "?view=closed"))
      Map.put(said, :closed, words(view, row(closed) <> " .q-wl-nx"))
    end

    # The row's owner and the Owner filter name a person by the address; the other words
    # by its local part.
    defp assert_named(said, address) do
      name = User.short_name(address)
      assert said.owner == ["Owner: #{address}"]
      assert said.waiting == ["1 waits for #{name}"]
      assert Enum.any?(said.options, &String.contains?(&1, address)), inspect(said.options)
      assert said.closed == "Closed by #{name}"
    end

    test "a person removed from the organisation is named by their account",
         %{conn: conn, scope: scope} do
      member = member_fixture(scope, :member)
      said = said_of(conn, scope, member.user, fn -> Repo.delete!(member.membership) end)
      assert_named(said, member.user.email)
    end

    test "a deleted account is a former member", %{conn: conn, scope: scope} do
      member = member_fixture(scope, :member)

      said =
        said_of(conn, scope, member.user, fn ->
          {:ok, _deleted} = Apiary.Accounts.delete_user(member.user)
        end)

      assert_named(said, "Former member")
    end

    test "a person who is not a member of the organisation is named by their account",
         %{conn: conn, scope: scope} do
      user = Apiary.AccountsFixtures.user_fixture()
      said = said_of(conn, scope, user, fn -> :ok end)
      assert_named(said, user.email)
    end

    test "an owner of 16 characters that is no id lists nothing, and breaks nothing",
         %{conn: conn, scope: scope} do
      item!(scope)
      {:ok, view, _html} = live(conn, page(scope, "?owner[]=0123456789abcdef"))
      assert rows(view) == []
      assert texts(view, "#work-items-stages-confirm .q-wl-attn") == []
    end

    test "an owner's id in capitals names that owner on Confirm's line",
         %{conn: conn, scope: scope} do
      %{user: member} = member_fixture(scope, :member)
      at!(scope, :confirm, owner_id: member.id)

      {:ok, view, _html} = live(conn, page(scope, "?owner[]=#{String.upcase(member.id)}"))

      assert texts(view, "#work-items-stages-confirm .q-wl-attn") == [
               "1 waits for #{name(member)}"
             ]
    end

    test "many owners in the address read no account of theirs", %{conn: conn, scope: scope} do
      item!(scope)
      forged = for _ <- 1..150, do: Ecto.UUID.generate()
      test = self()
      handler = "work-items-users-#{System.unique_integer()}"

      # How many of the forged ids each query of the users table carries, from any
      # process: the page's runs in its own.
      :telemetry.attach(
        handler,
        [:apiary, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          params = List.flatten([metadata[:params] || [], metadata[:cast_params] || []])
          read = Enum.count(forged, &(&1 in params or Ecto.UUID.dump!(&1) in params))
          if metadata[:source] == "users" and read > 0, do: send(test, {:users_read, read})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      query = Enum.map_join(forged, "&", &"owner[]=#{&1}")
      {:ok, view, _html} = live(conn, page(scope, "?" <> query))
      assert rows(view) == []
      refute_received {:users_read, _count}

      # One owner alone is read, for Confirm's line.
      {:ok, _view, _html} = live(conn, page(scope, "?owner[]=#{hd(forged)}"))
      assert_received {:users_read, 1}
    end
  end

  describe "Search and the Filter menu" do
    setup %{scope: scope} do
      %{user: member} = member_fixture(scope, :member)
      basket = item!(scope, title: "The basket loses an item")
      price = item!(scope, title: "The price shows 100% off", owner_id: member.id)
      %{member: member, basket: basket, price: price}
    end

    test "Search narrows the list as the reader types", ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      view |> form("#work-items-search", %{q: "basket"}) |> render_change()
      assert patched(view) == %{"q" => "basket"}
      assert rows(view) == ids([ctx.basket])

      view |> form("#work-items-search", %{q: "nothing like it"}) |> render_change()
      assert rows(view) == []
      assert has_element?(view, "#work-items-stages")
    end

    test "Owner keeps one owner's work items, with its token, Clear and the match count", ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))

      assert has_element?(
               view,
               "#work-items-filter-owner-form .q-filter-option",
               ctx.member.email
             )

      # A choice in a list of people: the letter beside the address, hidden from a screen
      # reader.
      assert has_element?(
               view,
               "#work-items-filter-owner-form .q-filter-option .avatar[aria-hidden=true]"
             )

      view
      |> form("#work-items-filter-owner-form", %{
        "_filter" => "owner",
        "owner" => [ctx.member.id]
      })
      |> render_change()

      assert patched(view) == %{"owner[]" => ctx.member.id}
      assert rows(view) == ids([ctx.price])

      assert words(view, "#work-items-tokens-owner .q-tok-v") == ctx.member.email
      assert words(view, "#work-items-tokens-match") == "1 work item matches"
      assert has_element?(view, ~s(#work-items-tokens-clear[href="#{page(ctx.scope)}"]))
    end

    test "an address with repository in place of collection filters nothing", ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))
      all = rows(view)

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?repository[]=acme/shop"))
      assert rows(view) == all
      refute has_element?(view, "#work-items-tokens-collection")
    end

    test "Collection and Updated keep theirs; a forged value matches nothing", ctx do
      ctx.basket |> set!(updated_at: DateTime.add(DateTime.utc_now(), -3, :day))
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?collection[]=acme/shop"))
      assert length(rows(view)) == 2
      assert words(view, "#work-items-tokens-collection .q-tok-v") == "acme/shop"

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?updated=24h"))
      assert rows(view) == ids([ctx.price])

      for forged <- ["?updated=1y", "?owner[]=not-an-id", "?collection[]=acme/none"] do
        {:ok, view, _html} = live(ctx.conn, page(ctx.scope, forged))
        assert rows(view) == [], forged
      end
    end

    test "the collections' section and its token in their sources' words", ctx do
      section = "#work-items-filter .q-fm-label"
      token = "#work-items-tokens-collection"
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?collection[]=acme/shop"))

      # Sources that name no words read Collection.
      assert texts(view, section) == ["Owner", "Collection", "Updated"]
      assert words(view, "#{token} .q-tok-k") == "Collection"

      for {work_item, name, {one, other}} <- [
            {ctx.basket, "Beta", {"queue", "queues"}},
            {ctx.price, "Alpha", {"repository", "repositories"}}
          ] do
        {1, _} =
          Repo.update_all(from(n in Apiary.Nodes.Node, where: n.id == ^work_item.adapter_id),
            set: [name: name, collection_noun_one: one, collection_noun_other: other]
          )
      end

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?collection[]=acme/shop"))

      # Each source's word once, by the adapter's name, joined with or.
      assert texts(view, section) == ["Owner", "Repository or queue", "Updated"]
      assert words(view, "#{token} .q-tok-k") == "Repository or queue"

      assert view |> element("#{token} .q-tok-x") |> render() =~
               ~s(aria-label="Remove Repository or queue: acme/shop")
    end
  end

  # A work item created `created` seconds before `base` and last changed `changed`
  # seconds before it.
  defp timed!(work_item, base, created, changed, fields \\ []) do
    set!(
      work_item,
      [
        inserted_at: DateTime.add(base, -created, :second),
        updated_at: DateTime.add(base, -changed, :second)
      ] ++ fields
    )
  end

  describe "Sort" do
    setup %{scope: scope} do
      base = DateTime.utc_now()
      # Created in one order, last changed in the other.
      older = scope |> item!() |> timed!(base, 60, 10)
      newer = scope |> item!() |> timed!(base, 30, 20)
      %{base: base, older: older, newer: newer}
    end

    test "offers Recently updated and Newest on Open, Declined, Closed and a stage alone",
         ctx do
      for query <- ["", "?view=declined", "?view=closed", "?stage=explore"] do
        {:ok, view, _html} = live(ctx.conn, page(ctx.scope, query))

        assert has_element?(
                 view,
                 ~s(#work-items-sort-button[aria-label="Sort: Recently updated"])
               ),
               query

        assert words(view, "#work-items-sort ul") == "Sort by Recently updated Newest", query
        assert has_element?(view, ~s(#work-items-sort-updated[aria-checked="true"])), query
        assert has_element?(view, ~s(#work-items-sort-created[aria-checked="false"])), query
      end
    end

    test "Newest lists the latest created first; Recently updated leaves sort out", ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?stage=explore"))
      assert rows(view) == ids([ctx.older, ctx.newer])

      view |> element("#work-items-sort-created") |> render_click()
      assert patched(view) == %{"stage" => "explore", "sort" => "created"}
      assert rows(view) == ids([ctx.newer, ctx.older])
      assert has_element?(view, ~s(#work-items-sort-created[aria-checked="true"]))
      assert has_element?(view, ~s(#work-items-sort-button[aria-label="Sort: Newest"]))

      view |> element("#work-items-sort-updated") |> render_click()
      assert patched(view) == %{"stage" => "explore"}
      assert rows(view) == ids([ctx.older, ctx.newer])
    end

    test "orders the Open view's bands", ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?sort=created"))
      assert rows(view, "#work-items-explore") == ids([ctx.newer, ctx.older])

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope))
      assert rows(view, "#work-items-explore") == ids([ctx.older, ctx.newer])
    end

    test "keeps the other params and leaves out the page's cursor", ctx do
      query = "?view=closed&q=checkout&owner[]=#{ctx.scope.user.id}&updated=24h&after=u.1.wi_0"
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, query))

      view |> element("#work-items-sort-created") |> render_click()

      assert patched(view) == %{
               "view" => "closed",
               "q" => "checkout",
               "owner[]" => ctx.scope.user.id,
               "updated" => "24h",
               "sort" => "created"
             }
    end

    test "is kept as the view, the stage and the search change", ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?sort=created"))

      view |> element("#work-items-views-closed") |> render_click()
      assert patched(view) == %{"view" => "closed", "sort" => "created"}

      view |> element("#work-items-views-open") |> render_click()
      assert patched(view) == %{"sort" => "created"}

      view |> element("#work-items-stages-explore") |> render_click()
      assert patched(view) == %{"stage" => "explore", "sort" => "created"}

      view |> form("#work-items-search", %{q: "checkout"}) |> render_change()
      assert patched(view) == %{"stage" => "explore", "q" => "checkout", "sort" => "created"}
      assert rows(view) == ids([ctx.newer, ctx.older])
    end

    test "a sort it does not know is Recently updated", ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?stage=explore&sort=comments"))
      assert rows(view) == ids([ctx.older, ctx.newer])
      assert has_element?(view, ~s(#work-items-sort-updated[aria-checked="true"]))
    end

    test "Waiting on you shows no Sort and stays oldest first", ctx do
      # Oldest first by the last change, unlike either order by creation.
      a = ctx.scope |> at!(:confirm) |> timed!(ctx.base, 90, 50)
      b = ctx.scope |> at!(:confirm) |> timed!(ctx.base, 30, 45)
      c = ctx.scope |> at!(:confirm) |> timed!(ctx.base, 60, 40)

      {:ok, view, _html} = live(ctx.conn, page(ctx.scope, "?view=you&sort=created"))
      assert rows(view) == ids([a, b, c])
      refute has_element?(view, "#work-items-sort")
    end
  end

  describe "the pager" do
    test "pages Newest, both ways, keeping the sort", %{conn: conn, scope: scope} do
      base = DateTime.utc_now()
      size = WorkList.page_size()
      closed = [state: :closed, closed_at: base, closed_by_id: scope.user.id]

      # The latest created is the earliest changed.
      items = for n <- 1..(size + 2), do: scope |> item!() |> timed!(base, n, -n, closed)

      {:ok, view, _html} = live(conn, page(scope, "?view=closed&sort=created"))
      assert rows(view) == ids(Enum.take(items, size))

      view |> element("#work-items-pager-next") |> render_click()
      assert %{"view" => "closed", "sort" => "created", "after" => "c." <> _} = patched(view)
      assert rows(view) == ids(Enum.drop(items, size))
      assert words(view, "#work-items-pager") =~ "#{size + 1}–#{size + 2} of #{size + 2}"

      view |> element("#work-items-pager-previous") |> render_click()
      assert %{"view" => "closed", "sort" => "created", "before" => "c." <> _} = patched(view)
      assert rows(view) == ids(Enum.take(items, size))
    end

    test "pages a view of more than a page, both ways", %{conn: conn, scope: scope} do
      base = DateTime.utc_now()
      size = WorkList.page_size()

      items =
        for n <- 1..(size + 2) do
          item!(scope)
          |> set!(
            state: :closed,
            closed_at: base,
            closed_by_id: scope.user.id,
            updated_at: DateTime.add(base, -n, :second)
          )
        end

      {:ok, view, _html} = live(conn, page(scope, "?view=closed"))
      assert rows(view) == ids(Enum.take(items, size))
      assert words(view, "#work-items-pager") =~ "1–#{size} of #{size + 2}"

      view |> element("#work-items-pager-next") |> render_click()
      assert %{"view" => "closed", "after" => _cursor} = patched(view)
      assert rows(view) == ids(Enum.drop(items, size))
      assert words(view, "#work-items-pager") =~ "#{size + 1}–#{size + 2} of #{size + 2}"

      view |> element("#work-items-pager-previous") |> render_click()
      assert rows(view) == ids(Enum.take(items, size))
    end

    test "a forged cursor shows nothing and breaks nothing", %{conn: conn, scope: scope} do
      closed =
        item!(scope)
        |> set!(state: :closed, closed_at: DateTime.utc_now(), closed_by_id: scope.user.id)

      {:ok, view, _html} = live(conn, page(scope, "?view=closed"))
      assert rows(view) == ids([closed])

      {:ok, view, _html} = live(conn, page(scope, "?view=closed&after=nonsense"))
      assert rows(view) == []
    end
  end

  describe "texts of an external system" do
    test "a ticket's title is shown without its invisible characters", %{
      conn: conn,
      scope: scope
    } do
      work_item = item!(scope) |> set!(title: "Basket \u202Eflow")
      {:ok, view, html} = live(conn, page(scope))

      refute html =~ "\u202E"
      assert words(view, row(work_item) <> " .q-wl-ttl b") == "Basket flow"
    end

    test "a title with nothing left to show is no title: the row says its number", %{
      conn: conn,
      scope: scope
    } do
      work_item = item!(scope) |> set!(title: "\u200B\u202E\u2066")
      {:ok, view, _html} = live(conn, page(scope))

      assert words(view, row(work_item) <> " .q-wl-ttl b") == "##{work_item.number}"
    end

    test "a title of only whitespace or invisible characters is no title either", %{
      conn: conn,
      scope: scope
    } do
      for title <- ["\u00A0", "\u202E\u200B"] do
        work_item = item!(scope) |> set!(title: title)
        {:ok, view, _html} = live(conn, page(scope))

        assert words(view, row(work_item) <> " .q-wl-ttl b") == "##{work_item.number}"
      end
    end
  end

  describe "the empty list" do
    test "says how a work item starts, with the Backlog", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, page(scope))

      assert has_element?(view, "h1", "Work items")
      assert has_element?(view, "h2", "No work items yet")

      assert has_element?(
               view,
               ~s(#work-items-open-backlog[href="/#{scope.organisation.slug}/#{scope.workspace.slug}/backlog"])
             )

      refute has_element?(view, "#work-items-stages")
    end

    test "a search that matches nothing is not the empty list", %{conn: conn, scope: scope} do
      item!(scope)
      {:ok, view, _html} = live(conn, page(scope, "?q=nothing+like+it"))
      refute has_element?(view, "h2", "No work items yet")
      assert has_element?(view, "#work-items-stages")
    end
  end

  describe "live" do
    test "a message of the workspace's work items reads the list and the sidebar's count again",
         %{conn: conn, scope: scope} do
      work_item = at!(scope, :running)
      {:ok, view, _html} = live(conn, page(scope))

      assert words(view, row(work_item) <> " .q-wl-nx") == "Qory is exploring"
      refute has_element?(view, "#nav-work_items .q-nav-count")

      Repo.delete_all(
        from d in Apiary.Dispatches.DispatchRun, where: d.work_item_id == ^work_item.id
      )

      run!(work_item, :confirm)

      Phoenix.PubSub.broadcast(
        Apiary.PubSub,
        WorkItems.topic(scope.workspace.id),
        {:work_items_changed, [work_item.public_id]}
      )

      assert words(view, row(work_item) <> " .q-wl-nx") == "Waits for you to confirm"
      assert words(view, "#nav-work_items .q-nav-count") == "1"
      assert words(view, "#work-items-views") == "Open 1 Waiting on you 1 Declined 0 Closed 0"
    end

    test "a message of another workspace's work items changes nothing", %{
      conn: conn,
      scope: scope
    } do
      first = item!(scope)
      {:ok, view, _html} = live(conn, page(scope))

      item!(scope)
      other = workspace_fixture(scope.organisation, "Platform")

      Phoenix.PubSub.broadcast(
        Apiary.PubSub,
        WorkItems.topic(other.id),
        {:work_items_changed, []}
      )

      assert rows(view) == ids([first])
    end

    test "a member removed behind the page's back is sent away on a message of its work items",
         %{scope: scope} do
      work_item = item!(scope)
      member = member_fixture(scope, :member)
      {:ok, view, _html} = live(log_in_user(build_conn(), member.user), page(scope))

      # Removed without a word to the page: the scope is read again before the list.
      Repo.delete!(member.membership)

      send(view.pid, {:work_items_changed, [work_item.public_id]})
      assert_redirect(view, ~p"/")
    end

    test "an event it does not know changes nothing", %{conn: conn, scope: scope} do
      work_item = item!(scope)
      {:ok, view, _html} = live(conn, page(scope))

      render_hook(view, "nonsense", %{"q" => "x"})
      render_hook(view, "answer", %{})
      assert rows(view) == ids([work_item])
    end
  end
end
