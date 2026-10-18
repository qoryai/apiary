defmodule Apiary.WorkItemsTest do
  # How the work item pages name a work item's ticket (`Apiary.WorkItems.ticket_names/2`):
  # its key and the title of its collection, as the Backlog draws them, and the public id
  # of its live record, which the Backlog opens it by, from the record of
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

      assert names == %{
               w.id => %{key: "#1204", collection_title: "acme/shop", ticket_id: item.public_id}
             }

      refute inspect(names) =~ "123456"
    end

    test "no key: none, and never the ref in its place", ctx do
      item = ticket(ctx, ctx.collection, %{key: nil})
      w = work_item(ctx, item)

      assert WorkItems.ticket_names(ctx.scope, [w]) ==
               %{w.id => %{key: nil, collection_title: "acme/shop", ticket_id: item.public_id}}
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

      # No record is live: the one that ended last, which the Backlog does not open.
      assert WorkItems.ticket_names(ctx.scope, [w]) ==
               %{w.id => %{key: "#2", collection_title: "acme/later", ticket_id: nil}}

      # A live record, whenever it was made.
      live = ticket(ctx, ctx.collection, %{key: "#3"})

      assert WorkItems.ticket_names(ctx.scope, [w]) ==
               %{w.id => %{key: "#3", collection_title: "acme/shop", ticket_id: live.public_id}}

      # A disconnected record has ended too, at the time it was disconnected.
      disconnect(live, DateTime.add(now, -30))

      assert WorkItems.ticket_names(ctx.scope, [w]) ==
               %{w.id => %{key: "#3", collection_title: "acme/shop", ticket_id: nil}}

      disconnect(live, DateTime.add(now, -7200))

      assert WorkItems.ticket_names(ctx.scope, [w]) ==
               %{w.id => %{key: "#2", collection_title: "acme/later", ticket_id: nil}}
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
               %{
                 w.id => %{
                   key: "#1204",
                   collection_title: "acme/shop",
                   ticket_id: item.public_id
                 }
               }

      # Its only record moves to the other workspace: no key, and the collection's title
      # as it was taken in.
      ctx.collection
      |> Ecto.Changeset.change(workspace_id: second.id)
      |> Repo.update!()

      assert WorkItems.ticket_names(ctx.scope, [w]) ==
               %{w.id => %{key: nil, collection_title: "acme/shop as taken in", ticket_id: nil}}
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

  describe "backlog_off/2" do
    defp put(record, fields), do: record |> Ecto.Changeset.change(fields) |> Repo.update!()

    test "while its ticket's collection is assigned and not linked: its switch off, or no items",
         ctx do
      w = work_item(ctx, ticket(ctx, ctx.collection, %{}))
      assert WorkItems.backlog_off(ctx.scope, [w]) == MapSet.new()

      collection = put(ctx.collection, backlog: false)
      assert WorkItems.backlog_off(ctx.scope, [w]) == MapSet.new([w.id])

      collection = put(collection, backlog: true, items: false)
      assert WorkItems.backlog_off(ctx.scope, [w]) == MapSet.new([w.id])

      put(collection, items: true)
      assert WorkItems.backlog_off(ctx.scope, [w]) == MapSet.new()

      adapter = Repo.get!(Apiary.Nodes.Node, ctx.connection.adapter_id)
      put(adapter, items: false)
      assert WorkItems.backlog_off(ctx.scope, [w]) == MapSet.new([w.id])
    end

    test "not while its ticket has no live record in a collection of the workspace", ctx do
      item = ticket(ctx, ctx.collection, %{})
      w = work_item(ctx, item)
      collection = put(ctx.collection, items: false)

      item = disconnect(item, DateTime.utc_now())
      assert WorkItems.backlog_off(ctx.scope, [w]) == MapSet.new()

      put(item, disconnected_at: nil)
      assert WorkItems.backlog_off(ctx.scope, [w]) == MapSet.new([w.id])

      other = workspace_fixture(ctx.scope.organisation, "Second")
      collection = put(collection, workspace_id: other.id)
      assert WorkItems.backlog_off(ctx.scope, [w]) == MapSet.new()

      collection = put(collection, workspace_id: ctx.scope.workspace.id)
      assert WorkItems.backlog_off(ctx.scope, [w]) == MapSet.new([w.id])
      end_collection(collection, DateTime.utc_now())
      assert WorkItems.backlog_off(ctx.scope, [w]) == MapSet.new()
    end

    test "nothing for another workspace, or a person who may not read its work items", ctx do
      w = work_item(ctx, ticket(ctx, ctx.collection, %{}))
      put(ctx.collection, backlog: false)

      %{scope: stranger} = sign_up_fixture()
      assert WorkItems.backlog_off(stranger, [w]) == MapSet.new()

      other = workspace_fixture(ctx.scope.organisation, "Second")
      assert WorkItems.backlog_off(workspace_scope(ctx.scope.user, other), [w]) == MapSet.new()
      assert WorkItems.backlog_off(ctx.scope, []) == MapSet.new()
    end
  end

  describe "ticket/3" do
    defp comment!(item, n, at, deleted_at \\ nil) do
      Repo.insert!(%Apiary.Sources.Comment{
        organisation_id: item.organisation_id,
        item_id: item.id,
        external_ref: "c#{n}",
        url: "https://forge.example.com/acme/shop/issues/12#c#{n}",
        author_name: "Author #{n}",
        author_kind: :person,
        body: "Comment #{n}",
        body_format: "markdown",
        source_created_at: at,
        source_updated_at: at,
        deleted_at: deleted_at
      })
    end

    test "the record, its latest comments, and the integration's name", ctx do
      item = ticket(ctx, ctx.collection, %{key: "#1204", labels: ["bug", "checkout"]})
      w = work_item(ctx, item)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      comments =
        for n <- 1..5, do: comment!(item, n, DateTime.add(now, n - 10, :minute))

      comment!(item, 6, now, DateTime.utc_now())

      seen = WorkItems.ticket(ctx.scope, w)
      adapter = Repo.get!(Apiary.Nodes.Node, w.adapter_id)

      assert seen.integration == adapter.name
      assert seen.adapter_removed == false
      assert seen.uninstalled == false
      assert seen.uninstalled_at == nil
      assert seen.item_noun == nil

      assert seen.ticket == %{
               filer: %{name: "Avery Example"},
               filed_at: item.source_created_at,
               updated_at: item.source_updated_at,
               labels: ["bug", "checkout"],
               body: item.body,
               format: "markdown",
               comment_count: 5,
               received_at: item.updated_at
             }

      assert Enum.map(seen.comments, & &1.body) == ["Comment 3", "Comment 4", "Comment 5"]
      assert hd(seen.comments).public_id == Enum.at(comments, 2).id

      all = WorkItems.ticket(ctx.scope, w, :all)
      assert Enum.map(all.comments, & &1.author) == Enum.map(1..5, &"Author #{&1}")
      refute inspect(all) =~ "123456"
    end

    test "after the integration's uninstall, and once the adapter is removed", ctx do
      item = ticket(ctx, ctx.collection, %{key: "#1204"})
      w = work_item(ctx, item)
      now = DateTime.utc_now()

      ctx.connection
      |> Ecto.Changeset.change(state: :ended, ended_at: now, ended_reason: :adapter_reported)
      |> Repo.update!()

      assert %{uninstalled: true, uninstalled_at: ^now, ticket: %{}} =
               WorkItems.ticket(ctx.scope, w)

      Apiary.Nodes.Node
      |> Repo.get!(w.adapter_id)
      |> Ecto.Changeset.change(deleted_at: now)
      |> Repo.update!()

      assert %{adapter_removed: true} = WorkItems.ticket(ctx.scope, w)
    end

    test "no record: no ticket and no comments", ctx do
      item = ticket(ctx, ctx.collection, %{key: "#1204"})
      w = work_item(ctx, item)

      Repo.update_all(Ecto.Query.from(w in Apiary.WorkItems.WorkItem, where: w.id == ^w.id),
        set: [external_ref: "other"]
      )

      assert %{ticket: nil, comments: [], uninstalled: false} = WorkItems.ticket(ctx.scope, w)
    end

    test "nothing for another workspace, or for a person who may not read its work items",
         ctx do
      item = ticket(ctx, ctx.collection, %{key: "#1204"})
      w = work_item(ctx, item)

      second = workspace_fixture(ctx.scope.organisation, "Second")
      assert WorkItems.ticket(workspace_scope(ctx.scope.user, second), w) == nil

      %{scope: other} = sign_up_fixture()
      foreign = %{other | organisation: ctx.scope.organisation, workspace: ctx.scope.workspace}

      for scope <- [foreign, other, %{ctx.scope | workspace: nil}] do
        assert WorkItems.ticket(scope, w) == nil
      end
    end
  end
end
