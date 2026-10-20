defmodule Apiary.Adapters.CollectionsItemsTest do
  # A source that reports no items, and a collection whose listing says it has none: never
  # linked, with no feed entry for an assign, a move, an unassign or an end; the items and
  # comments the adapter sends for it refused as not linked; its tickets out of the
  # Backlog; no switch for its target, which keeps its value. A listing that turns a
  # linked collection's items off writes unlinked, and one that turns them on again
  # writes linked, with no trail entry and the switch as it was. A start whose description
  # turns the source's items off unlinks every linked collection of the adapter, and one
  # that turns them on again links them, with no entry in the organisation's trail.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  import Apiary.SourcesFixtures, only: [items_body: 2, item: 1, comments_body: 2, comment: 1]
  import Apiary.DescriptionFixtures, only: [read_description: 1]

  alias Apiary.{AccessKeys, Adapters, Repo, Sources}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Collections, Connections, Feed}
  alias Apiary.Audit.Entry
  alias Apiary.Nodes.Node
  alias Apiary.Runs.Target
  alias Apiary.Sources.Backlog

  @moduletag needs: :factory

  @shop %{system: "code.example.com", path: "acme/shop"}
  @api %{system: "code.example.com", path: "acme/api"}

  # An organisation with two workspaces, so a collection is assigned to none as it is
  # made.
  setup do
    %{scope: scope, user: user} = sign_up_fixture()
    other_workspace = workspace_fixture(scope.organisation, "Second")
    connectable = connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})
    {connection, _nonce} = connection_fixture(scope, connectable.adapter, :connected)

    %{
      scope: scope,
      user: user,
      workspace: scope.workspace,
      other_workspace: other_workspace,
      adapter: connectable.adapter,
      key_scope: key_scope(connectable.access_key),
      connection: connection
    }
  end

  defp key_scope(key) do
    {:ok, verified} = AccessKeys.fetch_for_verification(key.key_id)
    Scope.for_access_key(verified)
  end

  # A disconnect of `ref` under this test's connection, as the wire reads one.
  defp disconnect(ctx, ref),
    do:
      Collections.disconnect(ctx.key_scope, %{
        connection_id: ctx.connection.public_id,
        collection_ref: ref
      })

  # One part of a listing naming `collections`, `{ref, target, items}` each, where
  # `items` is false, or nil for a collection the part says nothing of. Each listing has
  # a new id and a later `started_at` than the one before, so it updates what it names.
  defp post(ctx, collections, opts \\ []) do
    n = System.unique_integer([:positive, :monotonic])

    Collections.post_listing(ctx.key_scope, %{
      time: DateTime.utc_now(:second),
      connection_id: ctx.connection.public_id,
      collections:
        for {ref, target, items} <- collections do
          %{
            ref: ref,
            url: "https://tracker.acme.example/" <> ref,
            title: ref,
            target: target,
            items: items != false
          }
        end,
      listing: %{
        id: "listing-#{n}",
        part: 1,
        started_at: DateTime.add(~U[2026-10-15 11:00:00Z], n, :second),
        complete: Keyword.get(opts, :complete, false)
      }
    })
  end

  defp collection(ctx, ref) do
    Repo.one!(
      from c in Collection,
        where: c.connection_id == ^ctx.connection.id and c.external_ref == ^ref,
        order_by: [desc_nulls_first: c.ended_at],
        limit: 1
    )
  end

  defp assign(ctx, refs, workspace) do
    ids = for ref <- refs, do: collection(ctx, ref).id
    Collections.assign_collections(ctx.scope, ctx.connection, ids, workspace)
  end

  defp target(workspace, %{system: system, path: path}),
    do: Repo.get_by!(Target, workspace_id: workspace.id, system: system, path: path)

  defp feed(ctx) do
    for %{kind: "collection", data: %{"collection_ref" => ref, "status" => status}} <-
          Feed.entries(ctx.adapter),
        do: {ref, status}
  end

  defp entries(action),
    do: Repo.all(from e in Entry, where: e.action == ^action, order_by: [asc: e.id])

  defp refused?(ctx, ref) do
    Collections.verdict(ctx.key_scope, collection(ctx, ref), :"source_item.post") ==
      {:error, :not_linked}
  end

  defp tickets(ctx), do: Enum.map(Backlog.list_tickets(ctx.scope, %{}).rows, & &1.title)

  defp collections(ctx),
    do:
      ctx.scope |> Backlog.filter_values(:collection, nil) |> Enum.map(& &1.label) |> Enum.sort()

  describe "a source that reports no items" do
    setup ctx, do: %{adapter: describe_source(ctx.adapter, "example-projects.json")}

    test "its collections are never linked: no entry for an assign, a move, an unassign or an end",
         ctx do
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop, nil}, {"API", @api, nil}])
      {:ok, 2} = assign(ctx, ["SHOP", "API"], ctx.workspace)
      {:ok, 1} = assign(ctx, ["SHOP"], ctx.other_workspace)
      {:ok, 1} = assign(ctx, ["SHOP"], nil)
      {:ok, :disconnected} = disconnect(ctx, "API")
      {:ok, 1} = assign(ctx, ["SHOP"], ctx.workspace)
      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)

      assert feed(ctx) == []
    end

    test "made in the only workspace, it is assigned there and not linked", ctx do
      %{scope: scope} = sign_up_fixture()
      {connection, _nonce} = connection_fixture(scope, ctx.adapter, :connected)
      {:ok, :accepted} = post(%{ctx | connection: connection}, [{"SHOP", @shop, nil}])

      assert %Collection{workspace_id: workspace_id, backlog: true, items: true} =
               collection(%{ctx | connection: connection}, "SHOP")

      assert workspace_id == scope.workspace.id
      assert feed(ctx) == []
    end

    test "items and comments sent for its collections are refused as not linked", ctx do
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop, nil}])
      {:ok, 1} = assign(ctx, ["SHOP"], ctx.workspace)

      assert refused?(ctx, "SHOP")

      assert Collections.resolve(ctx.key_scope, "SHOP", :"source_item.post") ==
               {:error, :not_linked}

      assert Sources.post_items(ctx.key_scope, items_body("SHOP", [item("R")])) ==
               {:error, :not_linked}

      assert Sources.post_comments(ctx.key_scope, comments_body("R", [comment("C")])) ==
               {:error, :not_linked}
    end

    test "its target has no switch, and turning it finds none to turn", ctx do
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop, nil}])
      {:ok, 1} = assign(ctx, ["SHOP"], ctx.workspace)
      target = target(ctx.workspace, @shop)

      assert Collections.backlog_switch(ctx.scope, target) == nil
      assert Collections.set_backlog(ctx.scope, target, false) == {:error, :not_found}
      assert collection(ctx, "SHOP").backlog
      assert entries("collection.set_backlog") == []
      assert Backlog.backlog_facts(ctx.scope).linked_collections == 0
    end
  end

  describe "a collection whose listing says it has no items" do
    test "made so: assigned, never linked, no switch, refused, out of the Backlog", ctx do
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop, false}])
      assert collection(ctx, "SHOP").items == false
      {:ok, 1} = assign(ctx, ["SHOP"], ctx.workspace)
      {:ok, 1} = assign(ctx, ["SHOP"], ctx.other_workspace)
      {:ok, 1} = assign(ctx, ["SHOP"], nil)
      {:ok, 1} = assign(ctx, ["SHOP"], ctx.workspace)

      assert feed(ctx) == []
      assert refused?(ctx, "SHOP")
      assert Collections.backlog_switch(ctx.scope, target(ctx.workspace, @shop)) == nil
      assert Backlog.backlog_facts(ctx.scope).linked_collections == 0
    end

    test "linked, it flips to no items: unlinked, no trail entry, the switch kept; back: linked",
         ctx do
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop, nil}, {"API", @api, nil}])
      {:ok, 2} = assign(ctx, ["SHOP", "API"], ctx.workspace)
      {:ok, :accepted} = Sources.post_items(ctx.key_scope, items_body("SHOP", [item("R")]))
      {:ok, :accepted} = Sources.post_items(ctx.key_scope, items_body("API", [item("A")]))
      assert Enum.sort(tickets(ctx)) == ["Title of A", "Title of R"]
      trail = Repo.aggregate(Entry, :count)
      shop_target = target(ctx.workspace, @shop)

      {:ok, :accepted} = post(ctx, [{"SHOP", @shop, false}, {"API", @api, nil}])

      assert feed(ctx) == [{"API", "linked"}, {"SHOP", "linked"}, {"SHOP", "unlinked"}]
      assert %Collection{items: false, backlog: true} = collection(ctx, "SHOP")
      assert Repo.aggregate(Entry, :count) == trail
      assert refused?(ctx, "SHOP")

      assert Sources.post_comments(ctx.key_scope, comments_body("R", [comment("C")])) ==
               {:error, :not_linked}

      assert tickets(ctx) == ["Title of A"]
      assert collections(ctx) == ["API"]
      assert Collections.backlog_switch(ctx.scope, shop_target) == nil
      assert Backlog.backlog_facts(ctx.scope).linked_collections == 1

      # A listing that names it again with no items, or leaves it out, writes nothing.
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop, false}])
      {:ok, :accepted} = post(ctx, [{"API", @api, nil}])
      assert collection(ctx, "SHOP").items == false
      assert length(feed(ctx)) == 3

      # Back: linked, as it is assigned and its switch on.
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop, nil}])

      assert Enum.drop(feed(ctx), 3) == [{"SHOP", "linked"}]
      assert %Collection{items: true, backlog: true} = collection(ctx, "SHOP")
      assert Repo.aggregate(Entry, :count) == trail
      refute refused?(ctx, "SHOP")
      assert Collections.backlog_switch(ctx.scope, shop_target) == %{on: true, item_noun: nil}
      assert Enum.sort(tickets(ctx)) == ["Title of A", "Title of R"]
      assert collections(ctx) == ["API", "SHOP"]
    end

    test "with its switch off, it flips both ways with no entry, and the switch stays off",
         ctx do
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop, nil}])
      {:ok, 1} = assign(ctx, ["SHOP"], ctx.workspace)
      {:ok, 1} = Collections.set_backlog(ctx.scope, target(ctx.workspace, @shop), false)
      told = feed(ctx)

      {:ok, :accepted} = post(ctx, [{"SHOP", @shop, false}])
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop, nil}])

      assert feed(ctx) == told
      refute collection(ctx, "SHOP").backlog

      assert Collections.backlog_switch(ctx.scope, target(ctx.workspace, @shop)) == %{
               on: false,
               item_noun: nil
             }
    end

    test "unassigned, it flips both ways with no entry", ctx do
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop, nil}])
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop, false}])
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop, nil}])

      assert feed(ctx) == []
      assert collection(ctx, "SHOP").items
    end

    test "moved while it has no items, it writes no entry; it links where it then is", ctx do
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop, nil}])
      {:ok, 1} = assign(ctx, ["SHOP"], ctx.workspace)
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop, false}])
      told = feed(ctx)
      assert told == [{"SHOP", "linked"}, {"SHOP", "unlinked"}]

      {:ok, 1} = assign(ctx, ["SHOP"], ctx.other_workspace)
      assert feed(ctx) == told

      {:ok, :accepted} = post(ctx, [{"SHOP", @shop, nil}])
      assert Enum.drop(feed(ctx), 2) == [{"SHOP", "linked"}]
      assert collection(ctx, "SHOP").workspace_id == ctx.other_workspace.id
    end

    test "a complete listing that ends it while it has no items writes no entry", ctx do
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop, nil}])
      {:ok, 1} = assign(ctx, ["SHOP"], ctx.workspace)
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop, false}])
      told = feed(ctx)

      {:ok, :accepted} = post(ctx, [], complete: true)

      assert collection(ctx, "SHOP").ended_reason == :not_listed
      assert feed(ctx) == told
    end

    test "turning its target's switch leaves it as it is, and turns the others", ctx do
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop, false}, {"MIRROR", @shop, nil}])
      {:ok, 2} = assign(ctx, ["SHOP", "MIRROR"], ctx.workspace)
      target = target(ctx.workspace, @shop)
      assert Collections.backlog_switch(ctx.scope, target) == %{on: true, item_noun: nil}

      assert Collections.set_backlog(ctx.scope, target, false) == {:ok, 1}

      assert collection(ctx, "SHOP").backlog
      refute collection(ctx, "MIRROR").backlog
      assert Collections.backlog_switch(ctx.scope, target) == %{on: false, item_noun: nil}
      assert feed(ctx) == [{"MIRROR", "linked"}, {"MIRROR", "unlinked"}]

      assert [%Entry{details: %{"backlog" => false, "count" => 1}}] =
               entries("collection.set_backlog")
    end
  end

  describe "a start whose description changes the source's items" do
    # The adapter starts with the description fixture `name`
    # (`Apiary.Adapters.declare/2`).
    defp start(ctx, name) do
      Adapters.declare(ctx.key_scope, %{
        time: DateTime.utc_now(:second),
        connect_url: "https://tracker-adapter.acme.example/connect",
        default_interval: 900,
        minimum_interval: 300,
        sends_changes: false,
        description: read_description(name)
      })
    end

    defp organisation_trail(ctx),
      do:
        Repo.aggregate(
          from(e in Entry, where: e.organisation_id == ^ctx.scope.organisation.id),
          :count
        )

    test "to none unlinks every linked collection, and back links them; nothing else changes",
         ctx do
      {:ok, :accepted} =
        post(ctx, [
          {"SHOP", @shop, nil},
          {"API", @api, nil},
          {"OFF", @shop, nil},
          {"BARE", @api, false},
          {"LOOSE", @shop, nil}
        ])

      {:ok, 4} = assign(ctx, ["SHOP", "API", "OFF", "BARE"], ctx.workspace)
      {:ok, 1} = assign(ctx, ["OFF"], ctx.other_workspace)
      # A switch is turned in the workspace of its target.
      other_scope = %{ctx.scope | workspace: ctx.other_workspace}
      {:ok, 1} = Collections.set_backlog(other_scope, target(ctx.other_workspace, @shop), false)
      {:ok, :accepted} = Sources.post_items(ctx.key_scope, items_body("SHOP", [item("R")]))
      assert tickets(ctx) == ["Title of R"]
      Phoenix.PubSub.subscribe(Apiary.PubSub, Collections.topic(ctx.scope.organisation.id))
      told = feed(ctx)

      assert told == [
               {"API", "linked"},
               {"OFF", "linked"},
               {"SHOP", "linked"},
               {"OFF", "unlinked"}
             ]

      trail = organisation_trail(ctx)

      assert {:ok, %Node{items: false}} = start(ctx, "example-projects.json")

      assert Enum.drop(feed(ctx), length(told)) == [{"API", "unlinked"}, {"SHOP", "unlinked"}]
      assert organisation_trail(ctx) == trail

      for ref <- ["SHOP", "API", "OFF", "BARE", "LOOSE"] do
        assert refused?(ctx, ref), ref
      end

      # Each collection keeps its workspace, its switch and its items.
      assert %Collection{backlog: true, items: true} = collection(ctx, "SHOP")
      assert %Collection{backlog: false} = collection(ctx, "OFF")
      assert %Collection{items: false} = collection(ctx, "BARE")
      assert collection(ctx, "LOOSE").workspace_id == nil
      assert tickets(ctx) == []

      connection_id = ctx.connection.id
      ids = Enum.sort([collection(ctx, "API").id, collection(ctx, "SHOP").id])

      assert_receive {:collections_changed, %{connection_id: ^connection_id, collection_ids: got}}
      assert Enum.sort(got) == ids

      # A start that says the same changes no link.
      told = feed(ctx)
      assert {:ok, %Node{items: false}} = start(ctx, "example-projects.json")
      assert feed(ctx) == told
      refute_receive {:collections_changed, _}

      # Back: the same two are linked again.
      assert {:ok, %Node{items: true}} = start(ctx, "example-tracker.json")
      assert Enum.drop(feed(ctx), length(told)) == [{"API", "linked"}, {"SHOP", "linked"}]
      assert organisation_trail(ctx) == trail
      refute refused?(ctx, "SHOP")
      assert tickets(ctx) == ["Title of R"]
      assert_receive {:collections_changed, %{connection_id: ^connection_id}}
    end

    test "with no source role, it is the default: items, and so links again", ctx do
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop, nil}])
      {:ok, 1} = assign(ctx, ["SHOP"], ctx.workspace)
      assert {:ok, %Node{items: false}} = start(ctx, "example-projects.json")

      assert {:ok, %Node{items: true, item_noun_one: nil, collection_noun_one: nil}} =
               start(ctx, "acme-tracker.json")

      assert feed(ctx) == [{"SHOP", "linked"}, {"SHOP", "unlinked"}, {"SHOP", "linked"}]
    end

    test "an ended collection, or one of an ended connection, gets no entry", ctx do
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop, nil}, {"API", @api, nil}])
      {:ok, 2} = assign(ctx, ["SHOP", "API"], ctx.workspace)
      {:ok, :disconnected} = disconnect(ctx, "API")
      told = feed(ctx)
      assert told == [{"API", "linked"}, {"SHOP", "linked"}, {"API", "unlinked"}]

      assert {:ok, _} = start(ctx, "example-projects.json")
      assert Enum.drop(feed(ctx), length(told)) == [{"SHOP", "unlinked"}]

      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)
      told = feed(ctx)
      assert {:ok, _} = start(ctx, "example-tracker.json")
      assert feed(ctx) == told
    end
  end
end
