defmodule Apiary.EnvironmentsTest do
  # The environment records (`Apiary.Environments.Record`): the reads, the table's rules
  # (one record per pool and collection, the last good build set together, the image
  # pinned by its digest, the bounds of the refs, a failure's cause and reason), the
  # composite keys that hold a record to its pool's workspace and its collection's
  # organisation, the purges of a workspace and of an organisation, the trigger that
  # queues a prebuild per node pool from a listing, an assign and a new pool, and a run's
  # image: which record gives it, and the run configuration document that names it.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Deletion, Environments, Nodes, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Collections}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Environments.Record
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Policy.{Effective, Render, Schema}

  @moduletag needs: :factory

  @image "registry.example.com:5000/acme/shop-env@sha256:" <> String.duplicate("3b9d", 16)

  # Two collections without an `environment_ref`, so that no pool made here queues a
  # prebuild for them, and a connection whose listings the trigger's tests post.
  setup do
    %{scope: scope} = sign_up_fixture()
    pool = pool_fixture(scope)
    connectable = connectable_adapter_fixture()
    {connection, _nonce} = connection_fixture(scope, connectable.adapter, :connected)
    {:ok, verified} = AccessKeys.fetch_for_verification(connectable.access_key.key_id)

    %{
      scope: scope,
      pool: pool,
      connection: connection,
      key_scope: Scope.for_access_key(verified),
      app: collection_fixture(scope, external_ref: "APP", environment_ref: nil),
      docs: collection_fixture(scope, external_ref: "DOCS", environment_ref: nil)
    }
  end

  # Posts a part of a listing, started at `minute`, naming SHOP with `item`'s fields.
  defp list(ctx, minute, item) do
    collection =
      Map.merge(
        %{
          ref: "SHOP",
          url: "https://code.example.com/acme/shop",
          title: "shop",
          target: %{system: "code.example.com", path: "acme/shop"}
        },
        item
      )

    {:ok, :accepted} =
      Collections.post_listing(ctx.key_scope, %{
        time: DateTime.utc_now(:second),
        connection_id: ctx.connection.public_id,
        collections: [collection],
        listing: %{
          id: "l-#{minute}",
          part: 1,
          started_at: DateTime.add(~U[2026-10-15 11:00:00Z], minute, :minute),
          complete: false
        }
      })

    Repo.get_by!(Collection, external_ref: "SHOP")
  end

  # The prebuilds queued, `{pool_id, environment_ref}` in the order they were queued.
  defp prebuilds(collection) do
    Repo.all(
      from r in DispatchRun,
        where: r.step == ^DispatchRun.prebuild() and r.source_collection_id == ^collection.id,
        order_by: [asc: r.queued_at, asc: r.pool_id],
        select: {r.pool_id, r.environment_ref}
    )
  end

  defp sorted(pools), do: pools |> Enum.map(& &1.id) |> Enum.sort()

  defp record(ctx, attrs \\ %{}) do
    struct(
      Record,
      Map.merge(
        %{
          organisation_id: ctx.scope.organisation.id,
          workspace_id: ctx.scope.workspace.id,
          pool_id: ctx.pool.id,
          source_collection_id: ctx.app.id,
          queued_ref: "env-1",
          queued_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  defp built(at \\ DateTime.utc_now()),
    do: %{
      image: @image,
      size: 734_003_200,
      commit: "9c1e4a7b",
      built_at: at,
      reported_ref: "env-1"
    }

  describe "the reads" do
    test "fetch/2 by pool and collection, for_collection/1 the oldest first", ctx do
      other_pool = pool_fixture(ctx.scope)
      first = Repo.insert!(record(ctx, built()))
      second = Repo.insert!(record(ctx, %{pool_id: other_pool.id}))
      Repo.insert!(record(ctx, %{source_collection_id: ctx.docs.id}))

      assert %Record{id: id, image: @image} = Environments.fetch(ctx.pool.id, ctx.app.id)
      assert id == first.id
      assert Environments.fetch(other_pool.id, ctx.docs.id) == nil
      assert Enum.map(Environments.for_collection(ctx.app.id), & &1.id) == [first.id, second.id]
      assert Environments.for_collection(Ecto.UUID.generate()) == []
    end
  end

  describe "the table's rules" do
    test "one record per pool and collection", ctx do
      Repo.insert!(record(ctx))

      assert_raise Ecto.ConstraintError,
                   ~r/environments_pool_id_source_collection_id_index/,
                   fn ->
                     Repo.insert!(record(ctx))
                   end
    end

    test "a build set together, its image pinned by its digest, the bounds", ctx do
      assert {:ok, _} = Repo.insert(record(ctx, built()))

      fresh = fn attrs ->
        Repo.insert(record(ctx, Map.put(attrs, :pool_id, pool_fixture(ctx.scope).id)))
      end

      # The contract's refused images, each a reference that could move or is not one.
      for image <- [
            "registry.example.com/acme/shop-env:latest",
            "Registry.example.com/acme/shop-env@sha256:" <> String.duplicate("3b9d", 16),
            "@sha256:" <> String.duplicate("3b9d", 16),
            "acme/shop-env@sha256:" <> String.duplicate("a", 63),
            "acme/shop-env@sha256:" <> String.duplicate("A", 64),
            String.duplicate("a", 256) <> "@sha256:" <> String.duplicate("a", 64)
          ] do
        assert_raise Ecto.ConstraintError, ~r/environments_image_check/, fn ->
          fresh.(Map.put(built(), :image, image))
        end
      end

      # A name of 255 characters, at the bound.
      assert {:ok, _} =
               fresh.(
                 Map.put(
                   built(),
                   :image,
                   String.duplicate("a", 255) <> "@sha256:" <> String.duplicate("0", 64)
                 )
               )

      for {attrs, constraint} <- [
            {Map.delete(built(), :commit), "built"},
            {%{image: @image}, "built"},
            {Map.put(built(), :size, 0), "size"},
            {Map.put(built(), :size, 9_007_199_254_740_992), "size"},
            {Map.put(built(), :commit, String.duplicate("c", 201)), "commit"},
            {Map.put(built(), :reported_ref, ""), "reported_ref"},
            {%{queued_ref: ""}, "queued_ref"},
            {%{queued_ref: String.duplicate("e", 201)}, "queued_ref"},
            {%{failure_cause: :released, failed_at: DateTime.utc_now()}, "failure"},
            {%{failure_cause: :lost, failure_reason: "x", failed_at: DateTime.utc_now()},
             "failure"},
            {%{failure_cause: :lost}, "failure"},
            {%{failure_reason: "x", failed_at: DateTime.utc_now()}, "failure"}
          ] do
        assert_raise Ecto.ConstraintError, ~r/environments_#{constraint}_check/, fn ->
          fresh.(attrs)
        end
      end

      for attrs <- [
            %{
              failure_cause: :released,
              failure_reason: "no space",
              failed_at: DateTime.utc_now()
            },
            %{failure_cause: :timed_out, failed_at: DateTime.utc_now()},
            Map.merge(built(), %{retired_at: DateTime.utc_now(), size: 9_007_199_254_740_991})
          ] do
        assert {:ok, _} = fresh.(attrs)
      end
    end

    test "a record keeps its pool's workspace and its collection's organisation", ctx do
      %{scope: other} = sign_up_fixture()
      theirs = pool_fixture(other)

      assert_raise Ecto.ConstraintError, ~r/environments_pool_id_fkey/, fn ->
        Repo.insert!(record(ctx, %{pool_id: theirs.id}))
      end

      assert_raise Ecto.ConstraintError, ~r/environments_source_collection_id_fkey/, fn ->
        Repo.insert!(
          record(ctx, %{
            organisation_id: other.organisation.id,
            workspace_id: other.workspace.id,
            pool_id: theirs.id
          })
        )
      end
    end
  end

  describe "the purges" do
    test "a workspace's purge deletes the records of its pools", ctx do
      workspace = workspace_fixture(ctx.scope.organisation)
      theirs = pool_fixture(%{ctx.scope | workspace: workspace})
      kept = Repo.insert!(record(ctx))
      Repo.insert!(record(ctx, %{workspace_id: workspace.id, pool_id: theirs.id}))

      {:ok, _} = Deletion.delete_workspace(ctx.scope, workspace.id, workspace.slug)

      Repo.update_all(from(w in Workspace, where: w.id == ^workspace.id),
        set: [purge_after: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      instance = Scope.for_instance(ctx.scope.organisation, Repo.get!(Workspace, workspace.id))
      assert {:ok, :purged} = Deletion.purge_workspace(instance)

      assert Repo.all(from r in Record, select: r.id) == [kept.id]
    end

    test "an organisation's purge deletes its records before its pools and collections", ctx do
      Repo.insert!(record(ctx, built()))

      {:ok, _} = Deletion.delete_organisation(ctx.scope, ctx.scope.organisation.slug)

      Repo.update_all(from(o in Organisation, where: o.id == ^ctx.scope.organisation.id),
        set: [purge_after: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      assert {:ok, :purged} =
               Deletion.purge_organisation(Scope.for_instance(ctx.scope.organisation))

      assert Repo.aggregate(Record, :count) == 0
      assert Repo.aggregate(Collection, :count) == 0
    end
  end

  describe "the trigger" do
    test "a listing queues one prebuild per node pool, held for it, once per environment_ref",
         ctx do
      other = pool_fixture(ctx.scope)
      pools = sorted([ctx.pool, other])

      shop = list(ctx, 1, %{environment_ref: "env-1"})
      assert shop.workspace_id == ctx.scope.workspace.id
      assert prebuilds(shop) == Enum.map(pools, &{&1, "env-1"})

      for record <- Environments.for_collection(shop.id) do
        assert %Record{queued_ref: "env-1", retired_at: nil, image: nil} = record
        assert record.workspace_id == ctx.scope.workspace.id
      end

      assert Enum.sort(Enum.map(Environments.for_collection(shop.id), & &1.pool_id)) == pools

      run = Repo.get_by!(DispatchRun, source_collection_id: shop.id, pool_id: other.id)
      assert %DispatchRun{state: :waiting, work_item_id: nil} = run
      assert run.organisation_id == ctx.scope.organisation.id

      # The same environment_ref named again queues nothing.
      list(ctx, 2, %{environment_ref: "env-1"})
      assert length(prebuilds(shop)) == 2

      # Another queues one more for each pool, the waiting ones left as they are.
      list(ctx, 3, %{environment_ref: "env-2"})
      assert Enum.drop(prebuilds(shop), 2) == Enum.map(pools, &{&1, "env-2"})
      assert Enum.map(Environments.for_collection(shop.id), & &1.queued_ref) == ~w(env-2 env-2)

      # None retires the records and queues nothing.
      list(ctx, 4, %{})
      assert length(prebuilds(shop)) == 4

      for record <- Environments.for_collection(shop.id) do
        assert %Record{queued_ref: "env-2", retired_at: %DateTime{}} = record
      end

      # Named again, even as it was, it queues again, once.
      list(ctx, 5, %{environment_ref: "env-2"})
      list(ctx, 6, %{environment_ref: "env-2"})
      assert Enum.drop(prebuilds(shop), 4) == Enum.map(pools, &{&1, "env-2"})

      # A listing that leaves it out changes nothing.
      list(ctx, 7, %{ref: "OTHER", target: nil, environment_ref: "env-9"})
      assert length(prebuilds(shop)) == 6
    end

    test "an older listing queues nothing", ctx do
      shop = list(ctx, 5, %{environment_ref: "env-2"})
      assert prebuilds(shop) == [{ctx.pool.id, "env-2"}]

      list(ctx, 1, %{environment_ref: "env-1"})
      list(ctx, 2, %{})
      assert prebuilds(shop) == [{ctx.pool.id, "env-2"}]

      assert %Record{queued_ref: "env-2", retired_at: nil} =
               Environments.fetch(ctx.pool.id, shop.id)
    end

    test "a collection without a target, or linked to no workspace, queues nothing", ctx do
      shop = list(ctx, 1, %{target: nil, environment_ref: "env-1"})
      assert shop.workspace_id == ctx.scope.workspace.id
      assert prebuilds(shop) == []
      assert Environments.for_collection(shop.id) == []

      # With a second workspace, a new collection is linked to none.
      empty = workspace_fixture(ctx.scope.organisation)
      list(ctx, 2, %{ref: "NEW", environment_ref: "env-1"})
      new = Repo.get_by!(Collection, external_ref: "NEW")
      assert new.workspace_id == nil
      assert prebuilds(new) == []
      assert Environments.for_collection(new.id) == []

      # Assigned to a workspace, it queues for that workspace's pools; moved to one with
      # none, nothing.
      {:ok, 1} =
        Collections.assign_collections(ctx.scope, ctx.connection, [new.id], ctx.scope.workspace)

      assert prebuilds(new) == [{ctx.pool.id, "env-1"}]
      {:ok, 1} = Collections.assign_collections(ctx.scope, ctx.connection, [new.id], empty)
      {:ok, 1} = Collections.assign_collections(ctx.scope, ctx.connection, [new.id], nil)
      assert prebuilds(new) == [{ctx.pool.id, "env-1"}]
    end

    test "a move to another workspace queues for its pools", ctx do
      workspace = workspace_fixture(ctx.scope.organisation)
      theirs = pool_fixture(%{ctx.scope | workspace: workspace})
      list(ctx, 1, %{environment_ref: "env-1"})
      shop = Repo.get_by!(Collection, external_ref: "SHOP")
      assert shop.workspace_id == nil

      {:ok, 1} =
        Collections.assign_collections(ctx.scope, ctx.connection, [shop.id], ctx.scope.workspace)

      {:ok, 1} = Collections.assign_collections(ctx.scope, ctx.connection, [shop.id], workspace)
      assert prebuilds(shop) == [{ctx.pool.id, "env-1"}, {theirs.id, "env-1"}]

      run = Repo.get_by!(DispatchRun, source_collection_id: shop.id, pool_id: theirs.id)
      assert run.workspace_id == workspace.id
      assert Environments.fetch(theirs.id, shop.id).workspace_id == workspace.id
    end

    test "a new node pool queues for the collections of its workspace, a deleted one is left out",
         ctx do
      shop = list(ctx, 1, %{environment_ref: "env-1"})
      bare = collection_fixture(ctx.scope, target_system: nil, target_path: nil)

      new = pool_fixture(ctx.scope)
      assert prebuilds(shop) == [{ctx.pool.id, "env-1"}, {new.id, "env-1"}]
      assert prebuilds(bare) == []
      assert prebuilds(ctx.app) == []
      assert Environments.for_collection(ctx.app.id) == []

      # A node and a gateway queue nothing.
      node_fixture(ctx.scope)
      gateway_fixture(ctx.scope)
      assert length(prebuilds(shop)) == 2

      {:ok, _deleted} = Nodes.delete_node(ctx.scope, new)
      list(ctx, 2, %{environment_ref: "env-2"})
      assert Enum.drop(prebuilds(shop), 2) == [{ctx.pool.id, "env-2"}]
    end

    test "runs only inside the caller's transaction", ctx do
      assert_raise ArgumentError, ~r/caller's transaction/, fn ->
        Environments.trigger([ctx.app], DateTime.utc_now())
      end

      assert_raise ArgumentError, ~r/caller's transaction/, fn ->
        Environments.trigger_for_pool(ctx.pool, DateTime.utc_now())
      end
    end
  end

  describe "a run's image" do
    @shop %{system: "code.example.com", path: "acme/shop"}

    defp image(n), do: "registry.example.com/acme/shop-env@sha256:" <> String.duplicate(n, 64)

    defp built!(ctx, collection, n, minutes, attrs \\ %{}) do
      at = DateTime.add(~U[2026-10-15 12:00:00.000000Z], minutes, :minute)

      Repo.insert!(
        record(
          ctx,
          Map.merge(
            %{source_collection_id: collection.id},
            Map.merge(built(at), Map.put(attrs, :image, image(n)))
          )
        )
      )
    end

    defp shop(ctx, attrs \\ []),
      do: collection_fixture(ctx.scope, Keyword.merge([target_path: "acme/shop"], attrs))

    test "is the newest build of a live collection of the pool's workspace with that target",
         ctx do
      assert Environments.image_for(ctx.pool, @shop) == nil

      built!(ctx, shop(ctx), "1", 1)
      assert Environments.image_for(ctx.pool, @shop) == image("1")

      newest = shop(ctx)
      built!(ctx, newest, "2", 2)
      assert Environments.image_for(ctx.pool, @shop) == image("2")

      # Newer, but not counted: a collection without an environment_ref, a record retired,
      # a collection ended or linked to another workspace, another target.
      built!(ctx, shop(ctx, environment_ref: nil), "3", 3)
      built!(ctx, shop(ctx), "4", 4, %{retired_at: DateTime.utc_now()})
      ended = shop(ctx)
      built!(ctx, ended, "5", 5)

      Repo.update_all(from(c in Collection, where: c.id == ^ended.id),
        set: [ended_at: DateTime.utc_now(), ended_reason: :disconnected]
      )

      moved = shop(ctx)
      built!(ctx, moved, "6", 6)
      workspace = workspace_fixture(ctx.scope.organisation)

      Repo.update_all(from(c in Collection, where: c.id == ^moved.id),
        set: [workspace_id: workspace.id]
      )

      built!(ctx, shop(ctx, target_path: "acme/docs"), "7", 7)
      assert Environments.image_for(ctx.pool, @shop) == image("2")
      assert Environments.image_for(ctx.pool, %{@shop | path: "acme/docs"}) == image("7")

      # A record queued again keeps its last good build for runs until the next one lands.
      Repo.update_all(from(r in Record, where: r.source_collection_id == ^newest.id),
        set: [queued_ref: "env-2", queued_at: DateTime.utc_now()]
      )

      assert Environments.image_for(ctx.pool, @shop) == image("2")

      # Another pool has no build of the target.
      other = pool_fixture(ctx.scope)
      assert Environments.image_for(other, @shop) == nil
    end

    test "goes inline into the security policy of the run configuration document" do
      effective = %Effective{mode: "enforce", allow: ["api.example.com"], deny: ["bad.example"]}
      document = Render.document(effective)

      assert {:ok, %{document: composed, digest: digest}} =
               Environments.with_image(document, image("a"))

      assert digest == Render.digest(composed)
      assert digest != Render.digest(document)

      assert Environments.with_image(document, image("a")) ==
               {:ok, %{document: composed, digest: digest}}

      assert %{"version" => 1, "security_policy" => policy} = Jason.decode!(composed)
      assert policy["image"] == image("a")

      # The rest keeps its members, its order and its bytes.
      assert Map.delete(policy, "image") == Jason.decode!(document)["security_policy"]

      members =
        composed
        |> Jason.decode!(objects: :ordered_objects)
        |> then(& &1["security_policy"].values)

      assert Enum.map(members, &elem(&1, 0)) == ~w(version egress image)

      assert composed ==
               String.replace_suffix(document, "}}", ~s(,"image":"#{image("a")}"}}))

      # The vendored policy contract names an image by name only, so the document is not
      # one this server serves yet.
      assert :ok = Schema.validate(document)
      assert {:error, _reason} = Schema.validate(composed)

      # A document with no policy has no security policy to put it in.
      assert Environments.with_image(Render.no_policy_document(), image("a")) ==
               {:error, :no_security_policy}
    end
  end
end
