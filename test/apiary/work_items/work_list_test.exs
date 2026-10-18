defmodule Apiary.WorkItems.WorkListTest do
  # The Work items list (`Apiary.WorkItems.list_work_items/3`): its views and their
  # counts, its rows as the page draws them, its search, its filters and its pages, and an
  # empty page to anyone who may not read the workspace's work items.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Edition, EditionStubs, Repo, WorkItems}
  alias Apiary.Sources.Item
  alias Apiary.WorkItems.{WorkItem, WorkList}

  @moduletag needs: :factory

  @empty %{rows: [], counts: %{open: 0, you: 0, declined: 0, closed: 0}, next: nil, prev: nil}

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

      assert open == %{
               id: ctx.open.public_id,
               number: ctx.open.number,
               title: ctx.open.title,
               key: "#12",
               repository: "acme/shop",
               state: :exploring,
               take_in: 1,
               owner_id: ctx.scope.user.id,
               taken_in_at: ctx.open.taken_in_at,
               updated_at: ctx.open.updated_at,
               ended_at: nil,
               ended_by_id: nil
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
    test "by owner, by repository and by the window of the last change", %{scope: scope} do
      %{user: member} = member_fixture(scope)
      mine = item!(scope, collection_title: "acme/basket")
      theirs = item!(scope, owner_id: member.id)
      old = item!(scope) |> set!(updated_at: DateTime.add(DateTime.utc_now(), -3, :day))

      assert ids(list(scope, owner: member.id)) == [theirs.public_id]

      assert Enum.sort(ids(list(scope, owner: [member.id, scope.user.id]))) ==
               Enum.sort([mine.public_id, theirs.public_id, old.public_id])

      # The repository is the title of the collection that holds the ticket now.
      assert length(list(scope, repository: "acme/shop").rows) == 3
      assert list(scope, repository: "acme/basket").rows == []

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
            [repository: [""]],
            [repository: [String.duplicate("a", 1025)]],
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
      assert is_binary(first.next)

      second = list(ctx.scope, after: first.next)
      assert ids(second) == rest
      assert second.next == nil
      assert is_binary(second.prev)

      back = list(ctx.scope, before: second.prev)
      assert ids(back) == first_page
      assert back.prev == nil
      assert back.next == first.next
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
