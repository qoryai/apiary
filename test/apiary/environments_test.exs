defmodule Apiary.EnvironmentsTest do
  # The environment records (`Apiary.Environments.Record`): the reads, the table's rules
  # (one record per pool and collection, the last good build set together, the image
  # pinned by its digest, the bounds of the refs, a failure's cause and reason), the
  # composite keys that hold a record to its pool's workspace and its collection's
  # organisation, the purges of a workspace and of an organisation, a run held for its
  # pool's build of its target's `environment_ref` and the build its pool's claim queues
  # for it, a build recorded with the target it was built for and the ref it was queued
  # for, whether a prebuild took its ref before the recorded build took its, and a run's
  # image: which record gives it.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures, only: [workspace_gateway!: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{AccessKeys, Deletion, Dispatches, Environments, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Collections}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Environments.Record
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Policy.{Render, RunConfiguration}

  @moduletag needs: :factory

  @image "registry.example.com:5000/acme/shop-env@sha256:" <> String.duplicate("3b9d", 16)

  # Two collections without an `environment_ref`, so that no run made here waits for a
  # build of them, and a connection whose listings the hold's tests post.
  setup do
    %{scope: scope} = sign_up_fixture()
    _gateway = workspace_gateway!(scope)
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

  defp record(ctx, attrs \\ %{}) do
    struct(
      Record,
      Map.merge(
        %{
          organisation_id: ctx.scope.organisation.id,
          workspace_id: ctx.scope.workspace.id,
          pool_id: ctx.pool.id,
          source_collection_id: ctx.app.id
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
      reported_ref: "env-1",
      built_ref: "env-1"
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
            {Map.put(built(), :built_ref, ""), "built_ref"},
            {Map.put(built(), :built_ref, String.duplicate("e", 201)), "built_ref"},
            {Map.delete(built(), :built_ref), "built_ref"},
            {%{built_ref: "env-1"}, "built_ref"},
            {%{lost_ref: ""}, "lost_ref"},
            {%{lost_ref: String.duplicate("e", 201)}, "lost_ref"},
            {%{failure_cause: :released, failed_at: DateTime.utc_now()}, "failure"},
            {%{failure_cause: :lost, failure_reason: "x", failed_at: DateTime.utc_now()},
             "failure"},
            {%{failure_cause: :lost}, "failure"},
            {%{failure_reason: "x", failed_at: DateTime.utc_now()}, "failure"},
            {Map.put(built(), :built_target_system, "code.example.com"), "built_target"},
            {Map.put(built(), :built_target_path, "acme/shop"), "built_target"},
            {%{built_queued_at: DateTime.utc_now()}, "built_queued_at"}
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
            Map.merge(built(), %{
              size: 9_007_199_254_740_991,
              built_ref: String.duplicate("e", 200)
            }),
            %{lost_ref: "env-1"},
            Map.merge(built(), %{
              built_target_system: "code.example.com",
              built_target_path: "acme/shop"
            }),
            Map.put(built(), :built_queued_at, DateTime.utc_now())
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

  describe "a run held for its build" do
    @shop_target %{system: "code.example.com", path: "acme/shop"}

    defp shop_image(n),
      do: "registry.example.com/acme/shop-env@sha256:" <> String.duplicate(n, 64)

    # A waiting run of the queue of a fresh work item in Explore, whose target is SHOP's
    # unless `target` says otherwise.
    defp explore!(ctx, target \\ @shop_target) do
      work_item =
        work_item_fixture(ctx.scope, %{target_system: target.system, target_path: target.path})

      {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
      run
    end

    # Records the build of the prebuild `run`, as stored now, for SHOP's target, with the
    # image `n`, reporting its ref.
    defp land!(run, n) do
      run = Repo.get!(DispatchRun, run.id)

      {:ok, :ok} =
        Repo.transact(fn ->
          {:ok,
           Environments.record_build(
             run,
             %{
               image: shop_image(n),
               size: 1_048_576,
               commit: "4b7d0a3f",
               environment_ref: run.environment_ref
             },
             @shop_target,
             DateTime.utc_now()
           )}
        end)
    end

    # A claim of `pool`: what it took, or `:none`.
    defp claim(ctx, pool) do
      %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
      {:ok, claimed} = Dispatches.claim(key, Dispatches.now())
      claimed
    end

    test "waits while its pool has no image of its collection's ref; the pool's claim queues the build and takes it",
         ctx do
      shop = list(ctx, 1, %{environment_ref: "env-1"})
      assert shop.workspace_id == ctx.scope.workspace.id

      # A listing queues no build.
      assert prebuilds(shop) == []
      assert Environments.for_collection(shop.id) == []

      run = explore!(ctx)

      assert %{run: %DispatchRun{step: "prebuild", environment_ref: "env-1"} = build} =
               claim(ctx, ctx.pool)

      assert build.source_collection_id == shop.id
      assert %DispatchRun{state: :waiting} = Repo.get!(DispatchRun, run.id)
      assert %Record{image: nil, built_ref: nil} = Environments.fetch(ctx.pool.id, shop.id)

      # Held, and its build claimed: the next claim takes nothing and queues nothing.
      assert claim(ctx, ctx.pool) == :none
      assert prebuilds(shop) == [{ctx.pool.id, "env-1"}]

      # The build lands: the run goes, given that image at its claim.
      land!(build, "1")
      assert %{run: taken, registered: registered} = claim(ctx, ctx.pool)
      assert taken.id == run.id
      assert registered.configured_image == shop_image("1")
    end

    test "a key change while it waits: the next claim queues the new ref's build, and ends the old ref's that waits, superseded",
         ctx do
      shop = list(ctx, 1, %{environment_ref: "env-1"})
      [old] = Apiary.DispatchedRunsFixtures.queue_builds!(shop)
      run = explore!(ctx)

      list(ctx, 2, %{environment_ref: "env-2"})
      assert %{run: %DispatchRun{environment_ref: "env-2"} = build} = claim(ctx, ctx.pool)

      assert %DispatchRun{state: :ended, end_cause: :superseded} = Repo.get!(DispatchRun, old.id)
      assert %DispatchRun{state: :waiting} = Repo.get!(DispatchRun, run.id)
      assert prebuilds(shop) == [{ctx.pool.id, "env-1"}, {ctx.pool.id, "env-2"}]

      land!(build, "2")
      assert %{run: taken, registered: %{configured_image: image}} = claim(ctx, ctx.pool)
      assert {taken.id, image} == {run.id, shop_image("2")}
    end

    test "an image of a ref its collection no longer has serves no run", ctx do
      shop = list(ctx, 1, %{environment_ref: "env-1"})
      [first] = Apiary.DispatchedRunsFixtures.queue_builds!(shop)
      assert %{run: %DispatchRun{id: id}} = claim(ctx, ctx.pool)
      assert id == first.id
      land!(first, "1")
      assert Environments.image_for(ctx.pool, @shop_target) == shop_image("1")

      list(ctx, 2, %{environment_ref: "env-2"})
      assert Environments.image_for(ctx.pool, @shop_target) == nil

      assert Environments.claim_image(
               ctx.pool,
               work_item_fixture(ctx.scope, %{
                 target_system: "code.example.com",
                 target_path: "acme/shop"
               })
             ) == :held

      run = explore!(ctx)
      assert %{run: %DispatchRun{environment_ref: "env-2"} = second} = claim(ctx, ctx.pool)
      land!(second, "2")
      assert %{run: taken, registered: %{configured_image: image}} = claim(ctx, ctx.pool)
      assert {taken.id, image} == {run.id, shop_image("2")}
    end

    test "is held for each pool apart: a pool with the image takes it, one without builds",
         ctx do
      shop = list(ctx, 1, %{environment_ref: "env-1"})
      other = pool_fixture(ctx.scope)

      {:ok, built} =
        Repo.transact(fn -> Dispatches.queue_prebuild(shop, ctx.pool, "env-1") end)

      assert %{run: %DispatchRun{id: id}} = claim(ctx, ctx.pool)
      assert id == built.id
      land!(built, "1")

      run = explore!(ctx)
      assert %{run: %DispatchRun{step: "prebuild", pool_id: pool_id}} = claim(ctx, other)
      assert pool_id == other.id
      assert %{run: taken} = claim(ctx, ctx.pool)
      assert taken.id == run.id
    end

    test "no run waits in a workspace whose domain has no prebuilds, nor for a target that names no environment",
         ctx do
      named = explore!(ctx, %{system: "code.example.com", path: "acme/app"})
      assert %{run: taken, registered: %{configured_image: nil}} = claim(ctx, ctx.pool)
      assert taken.id == named.id

      with_domain(ctx.scope, "general")
      shop = list(ctx, 1, %{environment_ref: "env-1"})
      run = explore!(ctx)
      assert %{run: taken, registered: %{configured_image: nil}} = claim(ctx, ctx.pool)
      assert taken.id == run.id
      assert prebuilds(shop) == []
    end

    # A version of the run configuration of the workspace, for `target` (a
    # `Apiary.Runs.Target`) or for none, after the newest one, with `document`.
    defp configuration!(ctx, target, document) do
      target_id = target && target.id

      version =
        Repo.one(
          from c in RunConfiguration,
            where: c.workspace_id == ^ctx.scope.workspace.id,
            select: coalesce(max(c.version), 0)
        )

      Repo.insert!(%RunConfiguration{
        organisation_id: ctx.scope.organisation.id,
        workspace_id: ctx.scope.workspace.id,
        target_id: target_id,
        version: version + 1,
        document: document,
        digest: Render.digest(document),
        rendered_at: DateTime.utc_now()
      })
    end

    @tag needs: [:factory, :security]
    test "a run whose target's run configuration names an image waits for no build and queues none",
         ctx do
      shop = list(ctx, 1, %{environment_ref: "env-1"})
      run = explore!(ctx)

      shop_target = Apiary.Targets.get(ctx.scope, @shop_target.system, @shop_target.path)

      configuration!(
        ctx,
        nil,
        ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"observe","allow":[]},"image":"with-docker"}})
      )

      item = Repo.get!(Apiary.WorkItems.WorkItem, run.work_item_id)
      assert Environments.claim_image(ctx.pool, item) == {:ok, nil}
      assert %{run: taken, registered: %{configured_image: nil}} = claim(ctx, ctx.pool)
      assert taken.id == run.id
      assert prebuilds(shop) == []

      # A version of the target's that names no image is the one in force for it: its next
      # run is held, and the claim queues its build.
      configuration!(
        ctx,
        shop_target,
        ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"observe","allow":[]}}})
      )

      held = explore!(ctx)

      assert %{run: %DispatchRun{step: "prebuild", environment_ref: "env-1"}} =
               claim(ctx, ctx.pool)

      assert %DispatchRun{state: :waiting} = Repo.get!(DispatchRun, held.id)
    end

    test "the claim's builds run only inside the caller's transaction", ctx do
      assert_raise ArgumentError, ~r/caller's transaction/, fn ->
        Environments.hold_builds(ctx.scope.workspace.id, ctx.pool.id, DateTime.utc_now())
      end

      assert_raise ArgumentError, ~r/caller's transaction/, fn ->
        Environments.queue_builds([ctx.app], ctx.pool)
      end
    end
  end

  describe "a build recorded" do
    @target %{system: "code.example.com", path: "acme/app"}
    @build %{
      image: "registry.example.com/acme/app-env@sha256:" <> String.duplicate("7", 64),
      size: 1_048_576,
      commit: "4b7d0a3f",
      environment_ref: "env-2"
    }

    # A prebuild of APP for the pool, queued for `env-1`, as the run of the queue holds it.
    defp prebuild_run(ctx) do
      %DispatchRun{
        organisation_id: ctx.scope.organisation.id,
        workspace_id: ctx.scope.workspace.id,
        pool_id: ctx.pool.id,
        source_collection_id: ctx.app.id,
        step: DispatchRun.prebuild(),
        environment_ref: "env-1",
        queued_at: ~U[2026-10-15 10:00:00.000000Z],
        environment_ref_at: ~U[2026-10-15 11:00:00.000000Z]
      }
    end

    defp record_build!(ctx, target \\ @target, now \\ DateTime.utc_now()) do
      {:ok, :ok} =
        Repo.transact(fn ->
          {:ok, Environments.record_build(prebuild_run(ctx), @build, target, now)}
        end)

      Environments.fetch(ctx.pool.id, ctx.app.id)
    end

    test "keeps the build, its target, the ref it was queued for, the reported ref as it is, and clears the last failure and the lost ref",
         ctx do
      failed_at = DateTime.add(DateTime.utc_now(), -60, :second)

      Repo.insert!(
        record(
          ctx,
          Map.merge(built(), %{
            failure_cause: :released,
            failure_reason: "no space",
            failed_at: failed_at,
            lost_ref: "env-1"
          })
        )
      )

      now = DateTime.utc_now()
      recorded = record_build!(ctx, @target, now)

      assert %Record{
               image: image,
               size: 1_048_576,
               commit: "4b7d0a3f",
               reported_ref: "env-2",
               built_ref: "env-1",
               built_target_system: "code.example.com",
               built_target_path: "acme/app",
               failure_cause: nil,
               failure_reason: nil,
               failed_at: nil,
               lost_ref: nil
             } = recorded

      assert image == @build.image
      assert DateTime.compare(recorded.built_at, now) == :eq
      assert recorded.built_queued_at == ~U[2026-10-15 11:00:00.000000Z]
    end

    test "makes a record that is missing, with the ref its run was queued for and the built target",
         ctx do
      assert Environments.fetch(ctx.pool.id, ctx.app.id) == nil

      assert %Record{
               built_target_path: "acme/app",
               reported_ref: "env-2",
               built_ref: "env-1"
             } = record_build!(ctx)
    end

    test "keeps no built target for a run whose labels named none", ctx do
      assert %Record{built_target_system: nil, built_target_path: nil, image: image} =
               record_build!(ctx, nil)

      assert image == @build.image
    end

    test "runs only inside the caller's transaction", ctx do
      assert_raise ArgumentError, ~r/caller's transaction/, fn ->
        Environments.record_build(prebuild_run(ctx), @build, @target, DateTime.utc_now())
      end
    end
  end

  describe "a build whose ref is older than the image's" do
    # A prebuild queued an hour before it took its ref at `at`, as one that waited again.
    defp run_queued_at(at),
      do: %DispatchRun{
        step: DispatchRun.prebuild(),
        queued_at: DateTime.add(at, -3600, :second),
        environment_ref_at: at
      }

    test "is newer where the record's image was made by a prebuild that took its ref after the run took its, whatever the run's queued_at",
         ctx do
      at = ~U[2026-10-15 11:00:00.000000Z]
      record = record(ctx, Map.put(built(), :built_queued_at, at))

      assert Environments.newer_build?(record, run_queued_at(DateTime.add(at, -1, :microsecond)))
      refute Environments.newer_build?(record, run_queued_at(at))
      refute Environments.newer_build?(record, run_queued_at(DateTime.add(at, 1, :second)))
    end

    test "is never newer with no image, no built_queued_at or no record", ctx do
      run = run_queued_at(~U[2026-10-15 11:00:00.000000Z])

      refute Environments.newer_build?(record(ctx), run)
      refute Environments.newer_build?(record(ctx, built()), run)
      refute Environments.newer_build?(nil, run)
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
            %{
              source_collection_id: collection.id,
              built_target_system: collection.target_system,
              built_target_path: collection.target_path
            },
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

      # Newer, but not counted: a collection without an environment_ref, a record built
      # from another ref than its collection's, a collection ended or assigned to another
      # workspace, another target.
      built!(ctx, shop(ctx, environment_ref: nil), "3", 3)
      built!(ctx, shop(ctx), "4", 4, %{built_ref: "env-0"})
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

      # A collection whose environment_ref changed: its record's image serves no run, and
      # the next newest that its collection's ref built does.
      Repo.update_all(from(c in Collection, where: c.id == ^newest.id),
        set: [environment_ref: "env-2"]
      )

      assert Environments.image_for(ctx.pool, @shop) == image("1")

      # Another pool has no build of the target.
      other = pool_fixture(ctx.scope)
      assert Environments.image_for(other, @shop) == nil
    end

    test "is only an image built for that target, else none, the pool's default",
         ctx do
      shop = shop(ctx)
      built!(ctx, shop, "1", 1)
      assert Environments.image_for(ctx.pool, @shop) == image("1")

      # The collection's target moved, and no prebuild for the new one has landed: the
      # image built for the old target is no run's of either.
      Repo.update_all(from(c in Collection, where: c.id == ^shop.id),
        set: [target_path: "acme/moved"]
      )

      assert Environments.image_for(ctx.pool, @shop) == nil
      assert Environments.image_for(ctx.pool, %{@shop | path: "acme/moved"}) == nil

      # A newer record built for another target than its collection's gives none either,
      # and an older one built for the target still counts.
      older = shop(ctx)
      built!(ctx, older, "2", 2)
      newer = shop(ctx)
      built!(ctx, newer, "3", 3, %{built_target_path: "acme/docs"})
      assert Environments.image_for(ctx.pool, @shop) == image("2")
    end
  end
end
