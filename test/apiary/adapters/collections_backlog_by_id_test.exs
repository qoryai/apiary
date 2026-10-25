defmodule Apiary.Adapters.CollectionsBacklogByIdTest do
  # The Backlog switch of one collection, by the id Qory Apiary gives it
  # (`set_collection_backlog/4`), with or without a target: owners and admins turn it off
  # and on, with the feed's `unlinked` and `linked` entries, one trail entry about the
  # collection, which records its title and its connection, and a broadcast; a press that
  # changes nothing writes nothing; the refusals; the switch kept across a move; and the
  # switch each row of `list_collections/3` shows.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  import Apiary.SourcesFixtures, only: [items_body: 2, item: 1]

  alias Apiary.{AccessKeys, Repo, Sources}
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry
  alias Apiary.Adapters.{Collection, Collections, Connections, Feed}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Workspace
  alias Apiary.Runs.Target
  alias Apiary.Sources.Backlog

  @moduletag needs: :factory

  @started ~U[2026-10-15 11:00:00Z]
  @shop %{system: "code.example.com", path: "acme/shop"}

  # An organisation with two workspaces, so a collection is linked to none as it is made.
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

  # One part of a listing naming `collections`, `{ref, target}` or `{ref, target,
  # items}` each, its title "Title of" and its ref.
  defp post(ctx, collections, opts \\ []) do
    Collections.post_listing(ctx.key_scope, %{
      time: DateTime.utc_now(:second),
      connection_id: ctx.connection.public_id,
      collections:
        for collection <- collections do
          {ref, target, items} =
            case collection do
              {ref, target} -> {ref, target, true}
              {ref, target, items} -> {ref, target, items}
            end

          %{
            ref: ref,
            url: "https://tracker.acme.example/" <> ref,
            title: "Title of " <> ref,
            grant_ref: listing_grant(ctx.connection),
            target: target,
            items: items
          }
        end,
      listing: %{
        id: Keyword.get(opts, :id, "listing-1"),
        part: 1,
        started_at: Keyword.get(opts, :started_at, @started),
        complete: false
      }
    })
  end

  defp collection(ctx, ref),
    do: Repo.get_by!(Collection, connection_id: ctx.connection.id, external_ref: ref)

  defp assign(ctx, refs, workspace) do
    ids = for ref <- refs, do: collection(ctx, ref).id
    Collections.assign_collections(ctx.scope, ctx.connection, ids, workspace)
  end

  defp switch(ctx, ref, on, scope \\ nil),
    do:
      Collections.set_collection_backlog(
        scope || ctx.scope,
        ctx.connection,
        collection(ctx, ref).id,
        on
      )

  defp feed(ctx) do
    for %{kind: "collection", data: %{"collection_ref" => ref, "status" => status}} <-
          Feed.entries(ctx.adapter),
        do: {ref, status}
  end

  defp switch_entries do
    Repo.all(
      from e in Entry,
        where: e.action == "collection.set_backlog",
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  defp row(ctx, ref) do
    id = collection(ctx, ref).id
    Enum.find(Collections.list_collections(ctx.scope, ctx.connection), &(&1.id == id))
  end

  # DOCS, with no target, assigned to the first workspace.
  defp docs(ctx) do
    {:ok, :accepted} = post(ctx, [{"DOCS", nil}])
    {:ok, 1} = assign(ctx, ["DOCS"], ctx.workspace)
    collection(ctx, "DOCS")
  end

  describe "the switch of a collection with no target" do
    test "off writes unlinked and one entry about the collection, on writes linked and another",
         ctx do
      docs = docs(ctx)
      assert feed(ctx) == [{"DOCS", "linked"}]

      assert switch(ctx, "DOCS", false) == {:ok, 1}
      refute collection(ctx, "DOCS").backlog
      assert switch(ctx, "DOCS", true) == {:ok, 1}
      assert collection(ctx, "DOCS").backlog

      assert feed(ctx) == [{"DOCS", "linked"}, {"DOCS", "unlinked"}, {"DOCS", "linked"}]

      # One entry a press, about the collection, in its workspace's trail, with its
      # title and its connection's public id as they were then.
      assert [off, on] = switch_entries()

      for {entry, backlog} <- [{off, false}, {on, true}] do
        assert entry.details == %{
                 "backlog" => backlog,
                 "count" => 1,
                 "name" => "Title of DOCS",
                 "connection_id" => ctx.connection.public_id
               }

        assert {entry.subject_kind, entry.subject_id} == {"collection", docs.id}
        assert entry.workspace_id == ctx.workspace.id
        assert entry.organisation_id == ctx.scope.organisation.id
        assert {entry.actor_kind, entry.actor_id} == {:person, ctx.user.id}
      end

      # No target is made.
      assert Repo.all(from t in Target, where: t.workspace_id == ^ctx.workspace.id) == []
    end

    test "a press that changes nothing answers 0, and writes no entry, no feed entry and no broadcast",
         ctx do
      docs(ctx)
      :ok = Collections.subscribe(ctx.scope)

      assert switch(ctx, "DOCS", true) == {:ok, 0}
      assert switch_entries() == []
      assert feed(ctx) == [{"DOCS", "linked"}]
      refute_receive {:collections_changed, _}, 50

      {:ok, 1} = switch(ctx, "DOCS", false)
      assert_receive {:collections_changed, _}
      assert switch(ctx, "DOCS", false) == {:ok, 0}
      assert length(switch_entries()) == 1
      assert feed(ctx) == [{"DOCS", "linked"}, {"DOCS", "unlinked"}]
      refute_receive {:collections_changed, _}, 50
    end

    test "after the change commits, the collection is broadcast on the organisation's topic",
         ctx do
      %Collection{id: id} = docs(ctx)
      :ok = Collections.subscribe(ctx.scope, ctx.connection)
      connection_id = ctx.connection.id

      {:ok, 1} = switch(ctx, "DOCS", false)

      assert_receive {:collections_changed,
                      %{connection_id: ^connection_id, collection_ids: [^id]}}
    end

    test "off, its tickets leave the Backlog and its items are refused; on, they come back",
         ctx do
      docs(ctx)
      {:ok, :accepted} = Sources.post_items(ctx.key_scope, items_body("DOCS", [item("R")]))
      assert [_ticket] = Backlog.list_tickets(ctx.scope, %{}).rows

      {:ok, 1} = switch(ctx, "DOCS", false)
      assert Backlog.list_tickets(ctx.scope, %{}).rows == []

      assert Collections.verdict(ctx.key_scope, collection(ctx, "DOCS"), :"source_item.post") ==
               {:error, :not_linked}

      assert Sources.post_items(ctx.key_scope, items_body("DOCS", [item("S")])) ==
               {:error, :not_linked}

      {:ok, 1} = switch(ctx, "DOCS", true)
      assert [_ticket] = Backlog.list_tickets(ctx.scope, %{}).rows

      assert {:ok, %Collection{external_ref: "DOCS"}, _scope} =
               Collections.verdict(ctx.key_scope, collection(ctx, "DOCS"), :"source_item.post")
    end

    test "the switch stays with the collection when it moves, and the move writes no entry",
         ctx do
      docs(ctx)
      {:ok, 1} = switch(ctx, "DOCS", false)
      {:ok, 1} = assign(ctx, ["DOCS"], ctx.other_workspace)

      refute collection(ctx, "DOCS").backlog
      assert row(ctx, "DOCS").backlog == %{on: false}
      assert feed(ctx) == [{"DOCS", "linked"}, {"DOCS", "unlinked"}]

      # Turned on in the new workspace: linked there, and the entry in its trail.
      {:ok, 1} = switch(ctx, "DOCS", true)
      assert List.last(feed(ctx)) == {"DOCS", "linked"}
      assert List.last(switch_entries()).workspace_id == ctx.other_workspace.id
    end
  end

  describe "the switch of a collection with a target" do
    test "turned by id, the entry is about the collection, and the target's switch follows",
         ctx do
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop}])
      {:ok, 1} = assign(ctx, ["SHOP"], ctx.workspace)
      shop = collection(ctx, "SHOP")

      target =
        Repo.get_by!(Target,
          workspace_id: ctx.workspace.id,
          system: @shop.system,
          path: @shop.path
        )

      assert switch(ctx, "SHOP", false) == {:ok, 1}
      assert Collections.backlog_switch(ctx.scope, target) == %{on: false, item_noun: nil}
      assert [%Entry{subject_kind: "collection", subject_id: subject_id}] = switch_entries()
      assert subject_id == shop.id

      # The target's switch, pressed after, is the same switch: on again, one entry
      # about the target.
      assert Collections.set_backlog(ctx.scope, target, true) == {:ok, 1}
      assert switch(ctx, "SHOP", true) == {:ok, 0}

      assert [_by_id, %Entry{subject_kind: "target", details: %{"count" => 1}}] =
               switch_entries()

      assert feed(ctx) == [{"SHOP", "linked"}, {"SHOP", "unlinked"}, {"SHOP", "linked"}]
    end
  end

  describe "refused" do
    test "a member who is no admin is refused, and an admin turns it", ctx do
      docs(ctx)
      %{scope: member} = member_fixture(ctx.scope, :member)
      %{scope: admin} = member_fixture(ctx.scope, :admin)

      assert switch(ctx, "DOCS", false, member) == {:error, :forbidden}
      assert collection(ctx, "DOCS").backlog
      assert switch_entries() == []

      assert switch(ctx, "DOCS", false, admin) == {:ok, 1}
    end

    test "another organisation's scope, another connection's collection and an id that is none are not found",
         ctx do
      docs = docs(ctx)

      %{scope: stranger} = sign_up_fixture()

      assert Collections.set_collection_backlog(stranger, ctx.connection, docs.id, false) ==
               {:error, :not_found}

      another = connectable_adapter_fixture(%{name: unique_adapter_name("Acme board")})
      {other, _nonce} = connection_fixture(ctx.scope, another.adapter, :connected)

      for {connection, id} <- [
            {other, docs.id},
            {ctx.connection, Ecto.UUID.generate()},
            {ctx.connection, "not an id"},
            {ctx.connection, docs.public_id}
          ] do
        assert Collections.set_collection_backlog(ctx.scope, connection, id, false) ==
                 {:error, :not_found}
      end

      assert collection(ctx, "DOCS").backlog
      assert switch_entries() == []
    end

    test "a collection assigned to no workspace, or ended, is not found", ctx do
      {:ok, :accepted} = post(ctx, [{"DOCS", nil}, {"LOOSE", nil}])
      {:ok, 1} = assign(ctx, ["DOCS"], ctx.workspace)

      assert switch(ctx, "LOOSE", false) == {:error, :not_found}

      {:ok, :disconnected} = disconnect(ctx, "DOCS")
      assert switch(ctx, "DOCS", false) == {:error, :not_found}

      assert switch_entries() == []
      assert collection(ctx, "LOOSE").backlog
    end

    test "an ended connection is refused ended", ctx do
      %Collection{id: id} = docs(ctx)
      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)

      assert Collections.set_collection_backlog(ctx.scope, ctx.connection, id, false) ==
               {:error, :ended}
    end

    test "a collection in a workspace marked for deletion is not found", ctx do
      docs(ctx)

      {:ok, %Workspace{}} =
        Apiary.Deletion.delete_workspace(ctx.scope, ctx.workspace.id, ctx.workspace.slug)

      assert switch(ctx, "DOCS", false) == {:error, :not_found}
      assert collection(ctx, "DOCS").backlog
      assert switch_entries() == []
    end

    test "a collection with no items, or of an adapter with none, has no switch", ctx do
      {:ok, :accepted} = post(ctx, [{"DOCS", nil, false}])
      {:ok, 1} = assign(ctx, ["DOCS"], ctx.workspace)

      assert switch(ctx, "DOCS", false) == {:error, :not_found}

      {:ok, :accepted} = post(ctx, [{"DOCS", nil, true}], id: "listing-2")
      assert switch(ctx, "DOCS", false) == {:ok, 1}
      {:ok, 1} = switch(ctx, "DOCS", true)

      Repo.update_all(from(n in Node, where: n.id == ^ctx.adapter.id), set: [items: false])
      assert switch(ctx, "DOCS", false) == {:error, :not_found}
      assert collection(ctx, "DOCS").backlog
      assert length(switch_entries()) == 2
    end
  end

  describe "the row's switch" do
    test "on or off where assigned, with items; none unassigned or with no items; an ended one not listed",
         ctx do
      {:ok, :accepted} = post(ctx, [{"DOCS", nil}, {"LOOSE", nil}, {"BARE", nil, false}])
      {:ok, 2} = assign(ctx, ["DOCS", "BARE"], ctx.workspace)

      assert row(ctx, "DOCS").backlog == %{on: true}
      assert row(ctx, "LOOSE").backlog == nil
      assert row(ctx, "BARE").backlog == nil

      {:ok, 1} = switch(ctx, "DOCS", false)
      assert row(ctx, "DOCS").backlog == %{on: false}

      # Its adapter with no items: no switch, and its value kept, unread.
      Repo.update_all(from(n in Node, where: n.id == ^ctx.adapter.id), set: [items: false])
      assert row(ctx, "DOCS").backlog == nil
      Repo.update_all(from(n in Node, where: n.id == ^ctx.adapter.id), set: [items: true])
      assert row(ctx, "DOCS").backlog == %{on: false}

      {:ok, :disconnected} = disconnect(ctx, "DOCS")
      assert row(ctx, "DOCS") == nil
    end
  end
end
