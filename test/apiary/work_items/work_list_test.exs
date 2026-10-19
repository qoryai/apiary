defmodule Apiary.WorkItems.WorkListTest do
  # The Work items list (`Apiary.WorkItems.list_work_items/3`): its views and their
  # counts, its rows as the page draws them, its search, its filters, its sort and its
  # pages, and an empty page to anyone who may not read the workspace's work items.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Edition, EditionStubs, Repo, WorkItems}
  alias Apiary.Dispatches.Settle
  alias Apiary.Nodes.Node
  alias Apiary.Sources.Item
  alias Apiary.WorkItems.{Confirmation, WorkItem, WorkList}

  @moduletag needs: :factory

  @no_stages %{
    explore: 0,
    confirm: 0,
    shape: 0,
    exploring: 0,
    answers: 0,
    no_result: 0,
    waiting: 0,
    waiting_you: 0,
    ready: 0
  }
  @empty %{
    rows: [],
    counts: %{open: 0, you: 0, declined: 0, closed: 0},
    stages: @no_stages,
    first: 1,
    next: nil,
    prev: nil
  }

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp item!(scope, attrs \\ %{}), do: work_item_fixture(scope, attrs)

  defp set!(work_item, fields) do
    {1, _} = Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id), set: fields)
    Repo.get!(WorkItem, work_item.id)
  end

  defp ids(page), do: Enum.map(page.rows, & &1.id)

  defp list(scope, params \\ %{}), do: WorkItems.list_work_items(scope, params)

  describe "the views" do
    setup %{scope: scope} do
      now = DateTime.utc_now()
      open = item!(scope)

      declined =
        item!(scope) |> set!(state: :declined, declined_at: now, declined_by_id: scope.user.id)

      closed = item!(scope) |> set!(state: :closed, closed_at: now, closed_by_id: nil)
      undone = item!(scope)
      {:ok, _undone} = WorkItems.undo(scope, undone)
      %{open: open, declined: declined, closed: closed, undone: Repo.get!(WorkItem, undone.id)}
    end

    test "hold the live, the declined, and the closed and undone work items, with every count",
         ctx do
      counts = %{open: 1, you: 0, declined: 1, closed: 2}

      assert %{rows: [%{id: open}], counts: ^counts} = list(ctx.scope)
      assert open == ctx.open.public_id
      assert ids(list(ctx.scope, view: :declined)) == [ctx.declined.public_id]
      assert ids(list(ctx.scope, %{"view" => "declined"})) == [ctx.declined.public_id]

      assert Enum.sort(ids(list(ctx.scope, view: :closed))) ==
               Enum.sort([ctx.closed.public_id, ctx.undone.public_id])

      assert %{rows: [], counts: ^counts} = list(ctx.scope, view: :you)
      assert ids(list(ctx.scope, view: "nonsense")) == [ctx.open.public_id]
    end

    test "draw each row with when and by whom it ended", ctx do
      rows =
        Map.new(
          list(ctx.scope, view: :closed).rows ++ list(ctx.scope, view: :declined).rows,
          &{&1.id, &1}
        )

      declined = rows[ctx.declined.public_id]
      assert declined.state == :declined
      assert declined.ended_at == ctx.declined.declined_at
      assert declined.ended_by_id == ctx.scope.user.id

      closed = rows[ctx.closed.public_id]
      assert closed.state == :closed
      assert closed.ended_at == ctx.closed.closed_at
      assert closed.ended_by_id == nil

      undone = rows[ctx.undone.public_id]
      assert undone.state == :undone
      assert %DateTime{} = undone.ended_at
      assert undone.ended_by_id == ctx.scope.user.id

      [open] = list(ctx.scope).rows
      adapter = Repo.get!(Node, ctx.open.adapter_id)

      assert open == %{
               id: ctx.open.public_id,
               number: ctx.open.number,
               title: ctx.open.title,
               key: "#12",
               repository: "acme/shop",
               integration: adapter.name,
               state: :exploring,
               take_in: 1,
               status: :queued,
               attempt: nil,
               of: nil,
               owner_id: ctx.scope.user.id,
               taken_in_at: ctx.open.taken_in_at,
               inserted_at: ctx.open.inserted_at,
               updated_at: ctx.open.updated_at,
               ended_at: nil,
               ended_by_id: nil,
               ended_reason: nil
             }
    end
  end

  describe "the search" do
    setup %{scope: scope} do
      basket = item!(scope, title: "The basket loses an item") |> key!("KEY-A")
      price = item!(scope, title: "The price shows 100% off") |> key!("KEY-B")
      %{basket: basket, price: price}
    end

    # The ticket's key at the source, with no digit a number search would find.
    defp key!(work_item, key) do
      {1, _} =
        Repo.update_all(from(i in Item, where: i.id == ^work_item.item_id), set: [key: key])

      work_item
    end

    test "finds by the title, any case, the key, or the number", ctx do
      assert ids(list(ctx.scope, search: "BASKET")) == [ctx.basket.public_id]
      assert ids(list(ctx.scope, search: "  basket ")) == [ctx.basket.public_id]
      assert ids(list(ctx.scope, search: "#{ctx.price.number}")) == [ctx.price.public_id]
      assert ids(list(ctx.scope, search: "##{ctx.price.number}")) == [ctx.price.public_id]
      assert ids(list(ctx.scope, search: "key-b")) == [ctx.price.public_id]
      assert length(list(ctx.scope, search: "KEY-").rows) == 2
    end

    test "takes %, _ and \\ as they are", ctx do
      assert ids(list(ctx.scope, search: "100%")) == [ctx.price.public_id]
      assert ids(list(ctx.scope, search: "%")) == [ctx.price.public_id]
      assert list(ctx.scope, search: "_").rows == []
      assert list(ctx.scope, search: "\\").rows == []
    end

    test "matches nothing for a search too long, not UTF-8 or with a NUL", ctx do
      for search <- [String.duplicate("a", 1025), <<0xFF>>, "bas\0ket", 42] do
        assert list(ctx.scope, search: search).rows == [], inspect(search)
      end

      assert length(list(ctx.scope, search: "").rows) == 2
    end
  end

  describe "the filters" do
    test "by owner, by collection and by the window of the last change", %{scope: scope} do
      %{user: member} = member_fixture(scope)
      mine = item!(scope, collection_title: "acme/basket")
      theirs = item!(scope, owner_id: member.id)
      old = item!(scope) |> set!(updated_at: DateTime.add(DateTime.utc_now(), -3, :day))

      assert ids(list(scope, owner: member.id)) == [theirs.public_id]

      assert Enum.sort(ids(list(scope, owner: [member.id, scope.user.id]))) ==
               Enum.sort([mine.public_id, theirs.public_id, old.public_id])

      # The collection is named by its title: of the collection that holds the ticket now.
      assert length(list(scope, collection: "acme/shop").rows) == 3
      assert list(scope, collection: "acme/basket").rows == []

      assert Enum.sort(ids(list(scope, updated: "24h"))) ==
               Enum.sort([mine.public_id, theirs.public_id])

      assert length(list(scope, updated: "7d").rows) == 3
      assert list(scope, %{"owner" => ""}).rows |> length() == 3
    end

    test "match nothing for a value that is not one, or too many", %{scope: scope} do
      item!(scope)

      for params <- [
            [owner: "not an id"],
            [owner: List.duplicate(Ecto.UUID.generate(), 101)],
            [collection: [""]],
            [collection: [String.duplicate("a", 1025)]],
            [updated: "1y"],
            [updated: 7]
          ] do
        assert list(scope, params).rows == [], inspect(params)
      end
    end

    test "count each view under the search and the filters", %{scope: scope} do
      item!(scope, title: "The basket loses an item")
      item!(scope) |> set!(state: :closed, closed_at: DateTime.utc_now())

      assert list(scope, search: "basket").counts == %{open: 1, you: 0, declined: 0, closed: 0}
      assert list(scope).counts == %{open: 1, you: 0, declined: 0, closed: 1}
    end
  end

  describe "the pages" do
    setup %{scope: scope} do
      base = DateTime.utc_now()
      count = WorkList.page_size() + 2

      items =
        for n <- 1..count do
          item!(scope) |> set!(updated_at: DateTime.add(base, -n, :second))
        end

      %{items: Enum.map(items, & &1.public_id)}
    end

    test "go from the latest changed, a page at a time, and back", ctx do
      size = WorkList.page_size()
      {first_page, rest} = Enum.split(ctx.items, size)

      first = list(ctx.scope)
      assert ids(first) == first_page
      assert first.prev == nil
      assert first.first == 1
      assert is_binary(first.next)

      second = list(ctx.scope, after: first.next)
      assert ids(second) == rest
      assert second.next == nil
      assert second.first == size + 1
      assert is_binary(second.prev)

      back = list(ctx.scope, before: second.prev)
      assert ids(back) == first_page
      assert back.prev == nil
      assert back.first == 1
      assert back.next == first.next
    end

    test "of Waiting on you go from the earliest changed, and back", ctx do
      waiting =
        ctx.items
        |> Enum.map(&Repo.get_by!(WorkItem, public_id: &1))
        |> Enum.map(fn work_item ->
          %{dispatch_run: dispatch_run} =
            explore_run_fixture(work_item, result: understood_result())

          Settle.settle(dispatch_run.id)
          work_item.public_id
        end)

      # Settling wrote no work item, so the order of their last change holds.
      oldest_first = Enum.reverse(waiting)
      {first_page, rest} = Enum.split(oldest_first, WorkList.page_size())

      first = list(ctx.scope, view: :you)
      assert ids(first) == first_page
      assert first.counts.you == length(waiting)

      second = list(ctx.scope, view: :you, after: first.next)
      assert ids(second) == rest
      assert second.first == WorkList.page_size() + 1
      assert second.next == nil

      back = list(ctx.scope, view: :you, before: second.prev)
      assert ids(back) == first_page
      assert back.prev == nil
    end

    test "a cursor not in the shape given matches nothing", ctx do
      first = list(ctx.scope)

      for params <- [
            [after: "nonsense"],
            [after: "u.12.wi_0"],
            [after: "u.99999999999999999999.wi_0000000000000000"],
            [after: String.duplicate("u", 100)],
            [after: first.next, before: first.next]
          ] do
        assert list(ctx.scope, params).rows == [], inspect(params)
      end
    end
  end

  # A work item created `created` seconds before `base` and last changed `changed`
  # seconds before it.
  defp timed!(work_item, base, created, changed),
    do:
      set!(work_item,
        inserted_at: DateTime.add(base, -created, :second),
        updated_at: DateTime.add(base, -changed, :second)
      )

  describe "the sort" do
    setup %{scope: scope} do
      base = DateTime.utc_now()
      # Created in one order, last changed in the other.
      older = scope |> item!() |> timed!(base, 60, 10)
      newer = scope |> item!() |> timed!(base, 30, 20)
      %{base: base, older: older, newer: newer}
    end

    test "goes from the latest changed by default, or from the latest created", ctx do
      by_change = [ctx.older.public_id, ctx.newer.public_id]
      by_creation = [ctx.newer.public_id, ctx.older.public_id]

      assert ids(list(ctx.scope)) == by_change
      assert ids(list(ctx.scope, sort: :updated)) == by_change
      assert ids(list(ctx.scope, %{"sort" => "updated"})) == by_change
      assert ids(list(ctx.scope, sort: :created)) == by_creation
      assert ids(list(ctx.scope, %{"sort" => "created"})) == by_creation
      assert ids(list(ctx.scope, view: :open, stage: :explore, sort: :created)) == by_creation

      for sort <- ["nonsense", "", "comments", :comments, 1, nil] do
        assert ids(list(ctx.scope, sort: sort)) == by_change, inspect(sort)
      end
    end

    test "leaves Waiting on you oldest first", ctx do
      # Oldest first by the last change, unlike either order by creation.
      a = ctx.scope |> at!(:confirm) |> timed!(ctx.base, 90, 50)
      b = ctx.scope |> at!(:confirm) |> timed!(ctx.base, 30, 45)
      c = ctx.scope |> at!(:confirm) |> timed!(ctx.base, 60, 40)
      oldest_first = [a.public_id, b.public_id, c.public_id]

      assert ids(list(ctx.scope, view: :you)) == oldest_first
      assert ids(list(ctx.scope, view: :you, sort: :created)) == oldest_first
      assert ids(list(ctx.scope, view: :you, sort: "created")) == oldest_first
    end

    test "orders each band by the sort after the work items that wait for the reader", ctx do
      %{user: member} = member_fixture(ctx.scope)
      mine = ctx.scope |> at!(:confirm) |> timed!(ctx.base, 120, 120)
      theirs_older = ctx.scope |> at!(:confirm, owner_id: member.id) |> timed!(ctx.base, 60, 10)
      theirs_newer = ctx.scope |> at!(:confirm, owner_id: member.id) |> timed!(ctx.base, 30, 20)

      by_change = WorkItems.list_bands(ctx.scope).bands
      by_creation = WorkItems.list_bands(ctx.scope, sort: :created).bands

      assert ids(%{rows: by_change.confirm}) ==
               [mine.public_id, theirs_older.public_id, theirs_newer.public_id]

      assert ids(%{rows: by_creation.confirm}) ==
               [mine.public_id, theirs_newer.public_id, theirs_older.public_id]

      assert ids(%{rows: by_change.explore}) == [ctx.older.public_id, ctx.newer.public_id]
      assert ids(%{rows: by_creation.explore}) == [ctx.newer.public_id, ctx.older.public_id]

      assert ids(%{rows: WorkItems.list_bands(ctx.scope, sort: "nonsense").bands.explore}) ==
               [ctx.older.public_id, ctx.newer.public_id]
    end
  end

  describe "the pages of Newest" do
    setup %{scope: scope} do
      base = DateTime.utc_now()

      # The latest created is the earliest changed, so the two sorts page apart.
      items =
        for n <- 1..(WorkList.page_size() + 2) do
          scope |> item!() |> timed!(base, n, -n)
        end

      %{items: Enum.map(items, & &1.public_id)}
    end

    test "go from the latest created, a page at a time, and back", ctx do
      size = WorkList.page_size()
      {first_page, rest} = Enum.split(ctx.items, size)

      first = list(ctx.scope, sort: :created)
      assert ids(first) == first_page
      assert first.prev == nil
      assert first.first == 1
      assert "c." <> _cursor = first.next

      second = list(ctx.scope, sort: :created, after: first.next)
      assert ids(second) == rest
      assert second.next == nil
      assert second.first == size + 1
      assert "c." <> _cursor = second.prev

      back = list(ctx.scope, sort: :created, before: second.prev)
      assert ids(back) == first_page
      assert back.prev == nil
      assert back.first == 1
      assert back.next == first.next

      assert ids(list(ctx.scope)) == ctx.items |> Enum.reverse() |> Enum.take(size)
    end

    test "a cursor of the other sort matches nothing", ctx do
      created = list(ctx.scope, sort: :created)
      updated = list(ctx.scope)
      assert "u." <> _cursor = updated.next

      for params <- [
            [after: created.next],
            [sort: :updated, before: created.next],
            [sort: :created, after: updated.next],
            [sort: :created, before: updated.next]
          ] do
        assert list(ctx.scope, params).rows == [], inspect(params)
      end
    end
  end

  # A live work item of the scope's workspace at `status`, its runs written as their
  # writers write them, each ended run settled (`Apiary.Dispatches.Settle`).
  defp at!(scope, status, attrs \\ %{}) do
    work_item = item!(scope, attrs)

    runs =
      case status do
        :queued -> []
        :running -> [[state: :handed_over]]
        :confirm -> [[result: understood_result()]]
        :questions -> [[result: questions_result()]]
        :no_result -> [[]]
        :lost -> [[end_cause: :lost]]
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

    Repo.get!(WorkItem, work_item.id)
  end

  defp statuses(page), do: Map.new(page.rows, &{&1.id, &1.status})

  describe "the status" do
    test "each row says where Explore stands, with its latest run", %{scope: scope} do
      items =
        for status <- [:queued, :running, :confirm, :questions, :used_up, :shape],
            into: %{},
            do: {status, at!(scope, status)}

      page = list(scope)
      expected = Map.new(items, fn {status, item} -> {item.public_id, status} end)
      assert statuses(page) == expected

      rows = Map.new(page.rows, &{&1.id, &1})
      assert %{attempt: 3, of: 3} = rows[items.used_up.public_id]
      assert %{attempt: 1, of: 3} = rows[items.confirm.public_id]
      assert %{attempt: nil, of: nil} = rows[items.queued.public_id]
    end

    test "an ended row keeps the status of its last take in, and an instance's close its reason",
         %{scope: scope} do
      declined =
        at!(scope, :confirm)
        |> set!(state: :declined, declined_at: DateTime.utc_now(), declined_by_id: scope.user.id)

      removed = at!(scope, :questions)

      {:ok, _workspaces} =
        Repo.transact(fn ->
          WorkItems.close_locked([removed], {:instance, "adapter_removed"}, DateTime.utc_now())
        end)

      assert [%{status: :confirm, ended_reason: nil}] = list(scope, view: :declined).rows
      [closed] = list(scope, view: :closed).rows
      assert closed.id == removed.public_id
      assert closed.status == :questions
      assert closed.ended_by_id == nil
      assert closed.ended_reason == "adapter_removed"
      assert declined.state == :declined
    end
  end

  describe "Waiting on you" do
    setup %{scope: scope} do
      %{user: member, membership: membership} = member_fixture(scope)
      base = DateTime.utc_now()

      older = at!(scope, :confirm) |> set!(updated_at: DateTime.add(base, -60, :second))

      newer =
        at!(scope, :confirm, title: "The basket loses an item")
        |> set!(updated_at: DateTime.add(base, -30, :second))

      theirs = at!(scope, :confirm, owner_id: member.id)

      for status <- [:queued, :running, :questions, :used_up, :no_result, :shape],
          do: at!(scope, status)

      _declined =
        at!(scope, :confirm)
        |> set!(state: :declined, declined_at: base, declined_by_id: scope.user.id)

      %{member: member, membership: membership, older: older, newer: newer, theirs: theirs}
    end

    test "holds the reader's live work items whose proposal waits at Confirm, oldest first",
         ctx do
      page = list(ctx.scope, view: :you)

      assert ids(page) == [ctx.older.public_id, ctx.newer.public_id]
      assert page.counts.you == 2
      assert page.stages.waiting == 3
      assert page.stages.waiting_you == 2
      assert WorkItems.count_waiting_on(ctx.scope) == 2
      assert WorkList.waiting_on(ctx.scope) == 2
    end

    test "holds the other member's work items for that member", ctx do
      member_scope = workspace_scope(ctx.member, ctx.scope.workspace)

      assert ids(list(member_scope, view: :you)) == [ctx.theirs.public_id]
      assert WorkItems.count_waiting_on(member_scope) == 1
    end

    test "counts under the search and the filters, and nothing to anyone else", ctx do
      assert list(ctx.scope, view: :you, owner: ctx.member.id).counts.you == 0
      searched = list(ctx.scope, view: :you, search: "basket")
      assert ids(searched) == [ctx.newer.public_id]
      assert searched.counts.you == 1

      # The member whose count is 1 above, once no longer a member, is counted nothing,
      # with the scope read again.
      member_scope = workspace_scope(ctx.member, ctx.scope.workspace)
      assert WorkItems.count_waiting_on(member_scope) == 1
      Repo.delete!(ctx.membership)
      assert WorkItems.count_waiting_on(Apiary.Access.reload(member_scope)) == 0
    end
  end

  describe "the stages" do
    setup %{scope: scope} do
      %{user: member} = member_fixture(scope)

      items =
        for {status, owner} <- [
              queued: nil,
              running: nil,
              running: nil,
              questions: nil,
              no_result: nil,
              lost: nil,
              used_up: nil,
              confirm: nil,
              confirm: member.id,
              shape: nil
            ] do
          {status, at!(scope, status, if(owner, do: %{owner_id: owner}, else: %{}))}
        end

      %{items: items, member: member}
    end

    test "count each stage and what in it needs a look", %{scope: scope} do
      assert list(scope).stages == %{
               explore: 7,
               confirm: 2,
               shape: 1,
               exploring: 2,
               answers: 1,
               no_result: 2,
               waiting: 2,
               waiting_you: 1,
               ready: 1
             }
    end

    test "narrow the Open view to one stage", %{scope: scope, items: items} do
      of = fn statuses ->
        for {status, item} <- items, status in statuses, do: item.public_id
      end

      assert Enum.sort(ids(list(scope, stage: :confirm))) == Enum.sort(of.([:confirm]))
      assert ids(list(scope, %{"stage" => "shape"})) == of.([:shape])

      assert Enum.sort(ids(list(scope, stage: "explore"))) ==
               Enum.sort(of.([:queued, :running, :questions, :no_result, :lost, :used_up]))

      assert list(scope, stage: "nonsense").rows == []

      closed =
        at!(scope, :confirm)
        |> set!(state: :closed, closed_at: DateTime.utc_now(), closed_by_id: scope.user.id)

      assert ids(list(scope, view: :closed)) == [closed.public_id]
      assert list(scope, view: :closed, stage: :confirm).rows == []
      assert length(list(scope, stage: "").rows) == 10
    end

    test "bands: each stage's first rows, the reader's first", %{scope: scope, items: items} do
      %{bands: bands, counts: counts, stages: stages} = WorkItems.list_bands(scope)

      mine = for {:confirm, item} <- items, item.owner_id == scope.user.id, do: item.public_id
      [first | _] = bands.confirm
      assert [first.id] == mine
      assert length(bands.confirm) == 2
      assert length(bands.explore) == 7
      assert ids(%{rows: bands.shape}) == for({:shape, item} <- items, do: item.public_id)
      assert counts.open == 10
      assert stages.explore == 7
    end
  end

  describe "the bands" do
    test "hold at most a band's rows, the latest changed first", %{scope: scope} do
      base = DateTime.utc_now()

      items =
        for n <- 1..(WorkList.band_size() + 2) do
          item!(scope) |> set!(updated_at: DateTime.add(base, -n, :second))
        end

      %{bands: bands, stages: stages} = WorkItems.list_bands(scope, search: "checkout")

      assert ids(%{rows: bands.explore}) ==
               items |> Enum.take(WorkList.band_size()) |> Enum.map(& &1.public_id)

      assert stages.explore == WorkList.band_size() + 2
      assert WorkItems.list_bands(scope, search: "nothing like it").bands.explore == []
    end

    test "are empty to anyone who may not read the work items", %{scope: scope} do
      item!(scope)
      %{scope: stranger} = sign_up_fixture()
      foreign = %{stranger | organisation: scope.organisation, workspace: scope.workspace}

      assert WorkItems.list_bands(foreign) == %{
               bands: %{explore: [], confirm: [], shape: []},
               counts: %{open: 0, you: 0, declined: 0, closed: 0},
               stages: @no_stages
             }
    end
  end

  describe "the Filter menu's values" do
    test "the owners and the repositories, most work items first", %{scope: scope} do
      %{user: member} = member_fixture(scope)
      item!(scope)
      item!(scope)
      item!(scope, owner_id: member.id, collection_title: "acme/api")

      assert WorkItems.list_filter_values(scope, :owner) == [
               %{key: scope.user.id, count: 2},
               %{key: member.id, count: 1}
             ]

      # The collection is named by its title: of the collection that holds the ticket now.
      assert WorkItems.list_filter_values(scope, :collection) == [
               %{key: "acme/shop", count: 3}
             ]

      assert WorkItems.list_filter_values(scope, :collection, "SHOP") == [
               %{key: "acme/shop", count: 3}
             ]

      assert WorkItems.list_filter_values(scope, :collection, "api") == []
      assert WorkItems.list_filter_values(scope, :collection, <<0xFF>>) == []

      %{scope: stranger} = sign_up_fixture()
      foreign = %{stranger | organisation: scope.organisation, workspace: scope.workspace}
      assert WorkItems.list_filter_values(foreign, :owner) == []
    end
  end

  describe "an empty page" do
    setup %{scope: scope} do
      item!(scope)
      assert [_row] = list(scope).rows
      :ok
    end

    test "to a person with no membership in the organisation of the workspace", %{scope: scope} do
      %{scope: stranger} = sign_up_fixture()
      foreign = %{stranger | organisation: scope.organisation, workspace: scope.workspace}

      assert list(foreign) == @empty
    end

    test "to a person who is not shown the feature", %{scope: scope} do
      :ok = Edition.put_test_stub(EditionStubs.HidesNamed)
      :ok = EditionStubs.HidesNamed.put([:factory])

      assert list(Apiary.Access.reload(scope)) == @empty
    end

    test "for a workspace of another organisation, or none", %{scope: scope} do
      %{scope: stranger} = sign_up_fixture()

      assert list(%{scope | organisation: stranger.organisation}) == @empty
      assert list(%{scope | workspace: nil}) == @empty
    end
  end
end
