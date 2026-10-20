defmodule Apiary.Adapters.CollectionsBacklogTest do
  # Whether a target's items come into the Backlog (`set_backlog/3`, `backlog_switch/2`):
  # on by default; owners and admins turn it off and on, with the feed's `unlinked` and
  # `linked` entries and one trail entry; an assign, a move and an end with it off; the
  # items and comments an adapter sends for a collection with it off; and who reads it.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  import Apiary.SourcesFixtures, only: [items_body: 2, item: 1, comments_body: 2, comment: 1]

  alias Apiary.{AccessKeys, Repo, Sources}
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry
  alias Apiary.Adapters.{Collection, Collections, Connections, Feed}
  alias Apiary.Runs.Target

  @moduletag needs: :factory

  @started ~U[2026-10-15 11:00:00Z]
  @shop %{system: "code.example.com", path: "acme/shop"}
  @api %{system: "code.example.com", path: "acme/api"}

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

  # One part of a listing naming `collections`, `{ref, target}` each.
  defp post(ctx, collections, opts \\ []) do
    Collections.post_listing(ctx.key_scope, %{
      time: DateTime.utc_now(:second),
      connection_id: ctx.connection.public_id,
      collections:
        for {ref, target} <- collections do
          %{ref: ref, url: "https://tracker.acme.example/" <> ref, title: ref, target: target}
        end,
      listing: %{
        id: Keyword.get(opts, :id, "listing-1"),
        part: 1,
        started_at: Keyword.get(opts, :started_at, @started),
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

  defp scope_in(ctx, workspace), do: workspace_scope(ctx.user, workspace)

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

  # SHOP assigned to the first workspace, with its target there.
  defp shop(ctx) do
    {:ok, :accepted} = post(ctx, [{"SHOP", @shop}])
    {:ok, 1} = assign(ctx, ["SHOP"], ctx.workspace)
    target(ctx.workspace, @shop)
  end

  describe "the switch" do
    test "on by default, for a new collection and for its target", ctx do
      target = shop(ctx)

      assert collection(ctx, "SHOP").backlog
      assert Collections.backlog_switch(ctx.scope, target) == %{on: true, item_noun: nil}
      assert feed(ctx) == [{"SHOP", "linked"}]
    end

    test "off writes only unlinked, on writes linked again, each once; the round trip in order",
         ctx do
      target = shop(ctx)

      assert Collections.set_backlog(ctx.scope, target, false) == {:ok, 1}
      refute collection(ctx, "SHOP").backlog
      assert Collections.backlog_switch(ctx.scope, target) == %{on: false, item_noun: nil}

      # Off again changes nothing, and writes nothing.
      assert Collections.set_backlog(ctx.scope, target, false) == {:ok, 0}

      assert Collections.set_backlog(ctx.scope, target, true) == {:ok, 1}
      assert Collections.set_backlog(ctx.scope, target, true) == {:ok, 0}
      assert collection(ctx, "SHOP").backlog

      assert feed(ctx) == [{"SHOP", "linked"}, {"SHOP", "unlinked"}, {"SHOP", "linked"}]

      # One trail entry a change, about the target, in the workspace's trail.
      assert [off, on] = switch_entries()

      for {entry, backlog} <- [{off, false}, {on, true}] do
        assert entry.details == %{"backlog" => backlog, "count" => 1}
        assert {entry.subject_kind, entry.subject_id} == {"target", target.id}
        assert entry.workspace_id == ctx.workspace.id
        assert entry.organisation_id == ctx.scope.organisation.id
      end
    end

    test "turns every collection of the target in the workspace, and none of another", ctx do
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop}, {"MIRROR", @shop}, {"API", @api}])
      {:ok, 3} = assign(ctx, ["SHOP", "MIRROR", "API"], ctx.workspace)
      target = target(ctx.workspace, @shop)

      assert Collections.set_backlog(ctx.scope, target, false) == {:ok, 2}
      refute collection(ctx, "SHOP").backlog
      refute collection(ctx, "MIRROR").backlog
      assert collection(ctx, "API").backlog

      assert Enum.drop(feed(ctx), 3) == [{"MIRROR", "unlinked"}, {"SHOP", "unlinked"}]
      assert [%Entry{details: %{"count" => 2}}] = switch_entries()

      # On while any one is on.
      Repo.update_all(from(c in Collection, where: c.external_ref == "MIRROR"),
        set: [backlog: true]
      )

      assert Collections.backlog_switch(ctx.scope, target) == %{on: true, item_noun: nil}
      assert Collections.set_backlog(ctx.scope, target, false) == {:ok, 1}
    end

    test "after the change commits, the collections changed are broadcast", ctx do
      target = shop(ctx)
      :ok = Collections.subscribe(ctx.scope)
      id = collection(ctx, "SHOP").id
      connection_id = ctx.connection.id

      {:ok, 1} = Collections.set_backlog(ctx.scope, target, false)

      assert_receive {:collections_changed,
                      %{connection_id: ^connection_id, collection_ids: [^id]}}

      {:ok, 0} = Collections.set_backlog(ctx.scope, target, false)
      refute_receive {:collections_changed, _}, 50
    end
  end

  describe "assigning, moving and ending with it off" do
    test "an assign from none writes no linked, and an unassign no unlinked", ctx do
      target = shop(ctx)
      {:ok, 1} = Collections.set_backlog(ctx.scope, target, false)
      {:ok, 1} = assign(ctx, ["SHOP"], nil)
      {:ok, 1} = assign(ctx, ["SHOP"], ctx.workspace)

      assert feed(ctx) == [{"SHOP", "linked"}, {"SHOP", "unlinked"}]
      refute collection(ctx, "SHOP").backlog

      # On again, assigned: linked.
      {:ok, 1} = Collections.set_backlog(ctx.scope, target, true)
      assert List.last(feed(ctx)) == {"SHOP", "linked"}
    end

    test "a move keeps the switch, and writes no entry, on or off", ctx do
      target = shop(ctx)
      {:ok, 1} = assign(ctx, ["SHOP"], ctx.other_workspace)
      assert feed(ctx) == [{"SHOP", "linked"}]

      moved = target(ctx.other_workspace, @shop)
      other = scope_in(ctx, ctx.other_workspace)
      {:ok, 1} = Collections.set_backlog(other, moved, false)
      {:ok, 1} = assign(ctx, ["SHOP"], ctx.workspace)

      refute collection(ctx, "SHOP").backlog
      assert Collections.backlog_switch(ctx.scope, target) == %{on: false, item_noun: nil}
      assert feed(ctx) == [{"SHOP", "linked"}, {"SHOP", "unlinked"}]
    end

    test "an end writes unlinked only for one with it on", ctx do
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop}, {"API", @api}, {"DOCS", nil}])
      {:ok, 3} = assign(ctx, ["SHOP", "API", "DOCS"], ctx.workspace)
      {:ok, 1} = Collections.set_backlog(ctx.scope, target(ctx.workspace, @shop), false)
      told = length(feed(ctx))

      {:ok, :disconnected} = disconnect(ctx, "SHOP")
      assert Enum.drop(feed(ctx), told) == []

      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)
      assert Enum.drop(feed(ctx), told) == [{"API", "unlinked"}, {"DOCS", "unlinked"}]
    end

    test "a workspace's purge unlinks without an entry for one with it off", ctx do
      {:ok, :accepted} = post(ctx, [{"SHOP", @shop}, {"API", @api}])
      {:ok, 2} = assign(ctx, ["SHOP", "API"], ctx.workspace)
      {:ok, 1} = Collections.set_backlog(ctx.scope, target(ctx.workspace, @shop), false)
      told = length(feed(ctx))

      assert Collections.unlink_workspace(ctx.scope.organisation.id, ctx.workspace.id) == 2
      assert Enum.drop(feed(ctx), told) == [{"API", "unlinked"}]
    end
  end

  describe "what the adapter sends" do
    test "items and comments of a collection with it off are refused as not linked, then taken when on",
         ctx do
      target = shop(ctx)
      body = items_body("SHOP", [item("R")])
      {:ok, :accepted} = Sources.post_items(ctx.key_scope, body)

      {:ok, 1} = Collections.set_backlog(ctx.scope, target, false)

      assert Collections.verdict(ctx.key_scope, collection(ctx, "SHOP"), :"source_item.post") ==
               {:error, :not_linked}

      assert Collections.resolve(ctx.key_scope, "SHOP", :"source_item.post") ==
               {:error, :not_linked}

      later = items_body("SHOP", [item("S")])
      assert Sources.post_items(ctx.key_scope, later) == {:error, :not_linked}

      comments =
        comments_body("R", [comment("C")])

      assert Sources.post_comments(ctx.key_scope, comments) == {:error, :not_linked}

      {:ok, 1} = Collections.set_backlog(ctx.scope, target, true)

      assert {:ok, %Collection{external_ref: "SHOP"}, _scope} =
               Collections.verdict(ctx.key_scope, collection(ctx, "SHOP"), :"source_item.post")

      assert Sources.post_comments(ctx.key_scope, comments) == {:ok, :accepted}
    end
  end

  describe "who" do
    test "an admin turns it; a member reads it and is refused, and nothing changes", ctx do
      target = shop(ctx)
      %{scope: member} = member_fixture(ctx.scope, :member)
      %{scope: admin} = member_fixture(ctx.scope, :admin)

      assert Collections.backlog_switch(member, target) == %{on: true, item_noun: nil}
      assert {:error, _refused} = Collections.set_backlog(member, target, false)
      assert collection(ctx, "SHOP").backlog
      assert switch_entries() == []

      assert Collections.set_backlog(admin, target, false) == {:ok, 1}
      refute collection(ctx, "SHOP").backlog
    end

    test "a target of another workspace, of another organisation, or with no collection is not found",
         ctx do
      target = shop(ctx)
      other = scope_in(ctx, ctx.other_workspace)
      assert Collections.set_backlog(other, target, false) == {:error, :not_found}
      assert Collections.backlog_switch(other, target) == nil

      %{scope: stranger} = sign_up_fixture()
      assert {:error, _refused} = Collections.set_backlog(stranger, target, false)
      assert Collections.backlog_switch(stranger, target) == nil

      # A target with no collection, which a run made, and one whose collection ended.
      lone =
        Repo.insert!(%Target{
          organisation_id: ctx.scope.organisation.id,
          workspace_id: ctx.workspace.id,
          system: "code.example.com",
          path: "acme/lone",
          first_seen_at: DateTime.utc_now()
        })

      assert Collections.set_backlog(ctx.scope, lone, false) == {:error, :not_found}
      assert Collections.backlog_switch(ctx.scope, lone) == nil

      {:ok, :disconnected} = disconnect(ctx, "SHOP")
      assert Collections.set_backlog(ctx.scope, target, false) == {:error, :not_found}
      assert Collections.backlog_switch(ctx.scope, target) == nil
      assert switch_entries() == []
    end
  end
end
