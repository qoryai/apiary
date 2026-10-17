defmodule Apiary.WorkItemsTest do
  # How the work item pages name a work item's ticket (`Apiary.WorkItems.ticket_names/2`):
  # its key and the title of its collection, as the Backlog draws them, from the record of
  # the work item's organisation, adapter and ref in a collection of its workspace, the
  # live one first, else the one that ended last; one query for a list; nothing for
  # another workspace or a person who may not read the workspace's work items; the ref
  # never.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Edition, EditionStubs, Repo, WorkItems}

  @moduletag needs: :factory

  # Opaque, as a source's ref is: never in what the pages are given.
  @ref "123456#42"

  setup do
    %{scope: scope} = sign_up_fixture()
    connection = ticket_connection_fixture(scope)
    collection = source_collection_fixture(scope, connection, %{title: "acme/shop"})
    %{scope: scope, connection: connection, collection: collection}
  end

  # A record of the ticket `ref` in `collection`, with `attrs`.
  defp ticket(ctx, collection, attrs) do
    source_item_fixture(
      ctx.scope,
      Map.merge(%{collection: collection, external_ref: @ref}, attrs)
    )
  end

  defp work_item(ctx, item, ref \\ @ref) do
    work_item_fixture(ctx.scope, %{
      connection_id: ctx.connection.id,
      item_id: item.id,
      external_ref: ref,
      collection_title: "acme/shop as taken in"
    })
  end

  defp end_collection(collection, at) do
    collection
    |> Ecto.Changeset.change(ended_at: at, ended_reason: :disconnected)
    |> Repo.update!()
  end

  defp disconnect(item, at),
    do: item |> Ecto.Changeset.change(disconnected_at: at) |> Repo.update!()

  # How many queries `fun` makes, by this process.
  defp queries(fun) do
    handler = "work-item-names-#{System.unique_integer()}"
    parent = self()

    :telemetry.attach(
      handler,
      [:apiary, :repo, :query],
      fn _event, _measurements, _meta, _config ->
        if self() == parent, do: send(parent, :query)
      end,
      nil
    )

    try do
      result = fun.()
      {result, count_queries(0)}
    after
      :telemetry.detach(handler)
    end
  end

  defp count_queries(n) do
    receive do
      :query -> count_queries(n + 1)
    after
      0 -> n
    end
  end

  describe "ticket_names/2" do
    test "the key and the collection's title, never the ref", ctx do
      item = ticket(ctx, ctx.collection, %{key: "#1204"})
      w = work_item(ctx, item)

      names = WorkItems.ticket_names(ctx.scope, [w])
      assert names == %{w.id => %{key: "#1204", collection_title: "acme/shop"}}
      refute inspect(names) =~ "123456"
    end

    test "no key: none, and never the ref in its place", ctx do
      item = ticket(ctx, ctx.collection, %{key: nil})
      w = work_item(ctx, item)

      assert WorkItems.ticket_names(ctx.scope, [w]) ==
               %{w.id => %{key: nil, collection_title: "acme/shop"}}
    end

    test "the live record of the ref first, else the one that ended last", ctx do
      now = DateTime.utc_now()
      older = source_collection_fixture(ctx.scope, ctx.connection, %{title: "acme/older"})
      earlier = ticket(ctx, older, %{key: "#1"})
      w = work_item(ctx, earlier)
      end_collection(older, DateTime.add(now, -3600))

      later = source_collection_fixture(ctx.scope, ctx.connection, %{title: "acme/later"})
      ticket(ctx, later, %{key: "#2"})
      end_collection(later, DateTime.add(now, -60))

      # No record is live: the one that ended last.
      assert WorkItems.ticket_names(ctx.scope, [w]) ==
               %{w.id => %{key: "#2", collection_title: "acme/later"}}

      # A live record, whenever it was made.
      live = ticket(ctx, ctx.collection, %{key: "#3"})

      assert WorkItems.ticket_names(ctx.scope, [w]) ==
               %{w.id => %{key: "#3", collection_title: "acme/shop"}}

      # A disconnected record has ended too, at the time it was disconnected.
      disconnect(live, DateTime.add(now, -30))

      assert WorkItems.ticket_names(ctx.scope, [w]) ==
               %{w.id => %{key: "#3", collection_title: "acme/shop"}}

      disconnect(live, DateTime.add(now, -7200))

      assert WorkItems.ticket_names(ctx.scope, [w]) ==
               %{w.id => %{key: "#2", collection_title: "acme/later"}}
    end

    test "only a record of the work item's workspace, adapter and ref", ctx do
      item = ticket(ctx, ctx.collection, %{key: "#1204"})
      w = work_item(ctx, item)

      # The same ref in a collection of another workspace, and of another adapter.
      second = workspace_fixture(ctx.scope.organisation, "Second")

      elsewhere =
        source_collection_fixture(ctx.scope, ctx.connection, %{
          title: "acme/elsewhere",
          workspace_id: second.id
        })

      ticket(ctx, elsewhere, %{key: "#9"})
      other_connection = ticket_connection_fixture(ctx.scope)
      ticket(ctx, source_collection_fixture(ctx.scope, other_connection), %{key: "#8"})

      # Another ref, in the work item's collection.
      ticket(ctx, ctx.collection, %{external_ref: "123456#43", key: "#7"})

      assert WorkItems.ticket_names(ctx.scope, [w]) ==
               %{w.id => %{key: "#1204", collection_title: "acme/shop"}}

      # Its only record moves to the other workspace: no key, and the collection's title
      # as it was taken in.
      ctx.collection
      |> Ecto.Changeset.change(workspace_id: second.id)
      |> Repo.update!()

      assert WorkItems.ticket_names(ctx.scope, [w]) ==
               %{w.id => %{key: nil, collection_title: "acme/shop as taken in"}}
    end

    test "one query for a list, whatever its length", ctx do
      work_items =
        for n <- 1..5 do
          ref = "123456##{n}"
          item = ticket(ctx, ctx.collection, %{external_ref: ref, key: "##{n}"})
          work_item(ctx, item, ref)
        end

      {one, one_count} =
        queries(fn -> WorkItems.ticket_names(ctx.scope, Enum.take(work_items, 1)) end)

      {all, all_count} = queries(fn -> WorkItems.ticket_names(ctx.scope, work_items) end)

      assert {one_count, all_count} == {1, 1}
      assert map_size(one) == 1
      assert Enum.map(work_items, &all[&1.id].key) == ["#1", "#2", "#3", "#4", "#5"]
      assert {%{}, 0} == queries(fn -> WorkItems.ticket_names(ctx.scope, []) end)
    end

    test "nothing for another workspace's work item, or for a person who may not read them",
         ctx do
      item = ticket(ctx, ctx.collection, %{key: "#1204"})
      w = work_item(ctx, item)

      second = workspace_fixture(ctx.scope.organisation, "Second")
      there = workspace_scope(ctx.scope.user, second)
      assert WorkItems.ticket_names(there, [w]) == %{}

      %{scope: other} = sign_up_fixture()
      foreign = %{other | organisation: ctx.scope.organisation, workspace: ctx.scope.workspace}

      :ok = Edition.put_test_stub(EditionStubs.HidesNamed)
      :ok = EditionStubs.HidesNamed.put([:factory])
      hidden = Apiary.Access.reload(ctx.scope)

      for scope <- [foreign, hidden, other, %{ctx.scope | workspace: nil}] do
        assert WorkItems.ticket_names(scope, [w]) == %{}
      end
    end
  end
end
