defmodule Apiary.EnvironmentsTest do
  # The environment records (`Apiary.Environments.Record`): the reads, the table's rules
  # (one record per pool and collection, the last good build set together, the image
  # pinned by its digest, the bounds of the refs, a failure's cause and reason), the
  # composite keys that hold a record to its pool's workspace and its collection's
  # organisation, the purges of a workspace and of an organisation, the trigger that
  # queues a prebuild per node pool from a listing, an assign and a new pool, keyed on the
  # target and the `environment_ref`, one waiting per collection and pool, a build
  # recorded with the target it was built for and when its run took its ref, whether a
  # prebuild took its ref before the recorded build took its, and a run's image: which
  # record gives it.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{AccessKeys, Deletion, Dispatches, Environments, Nodes, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Collections}
  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.Environments.Record
  alias Apiary.Organisations.{Organisation, Workspace}

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

  # The prebuilds that wait, `{pool_id, environment_ref}` by pool.
  defp waiting(collection) do
    Repo.all(
      from r in DispatchRun,
        where: r.step == ^DispatchRun.prebuild() and r.source_collection_id == ^collection.id,
        where: r.state == :waiting,
        order_by: r.pool_id,
        select: {r.pool_id, r.environment_ref}
    )
  end

  # Claims the oldest run `pool` may take: the run and its dispatch.
  defp claim!(ctx, pool) do
    %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
    {:ok, %{run: run, dispatch: dispatch}} = Dispatches.claim(key, Dispatches.now())
    %{run: run, dispatch: dispatch}
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
            {%{failure_reason: "x", failed_at: DateTime.utc_now()}, "failure"},
            {%{queued_target_system: "code.example.com"}, "queued_target"},
            {%{queued_target_path: "acme/shop"}, "queued_target"},
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
            Map.merge(built(), %{retired_at: DateTime.utc_now(), size: 9_007_199_254_740_991}),
            %{queued_target_system: "code.example.com", queued_target_path: "acme/shop"},
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

      # Another, while they wait, is set on the waiting ones: one waits per pool.
      list(ctx, 3, %{environment_ref: "env-2"})
      assert prebuilds(shop) == Enum.map(pools, &{&1, "env-2"})
      assert waiting(shop) == Enum.map(pools, &{&1, "env-2"})
      assert Enum.map(Environments.for_collection(shop.id), & &1.queued_ref) == ~w(env-2 env-2)

      # Claimed, then none: the records are retired and nothing is queued.
      claim!(ctx, ctx.pool)
      claim!(ctx, other)
      list(ctx, 4, %{})
      assert length(prebuilds(shop)) == 2
      assert waiting(shop) == []

      for record <- Environments.for_collection(shop.id) do
        assert %Record{queued_ref: "env-2", retired_at: %DateTime{}} = record
      end

      # Named again, even as it was, it queues again, once.
      list(ctx, 5, %{environment_ref: "env-2"})
      list(ctx, 6, %{environment_ref: "env-2"})
      assert Enum.drop(prebuilds(shop), 2) == Enum.map(pools, &{&1, "env-2"})
      assert waiting(shop) == Enum.map(pools, &{&1, "env-2"})

      # A listing that leaves it out changes nothing.
      list(ctx, 7, %{ref: "OTHER", target: nil, environment_ref: "env-9"})
      assert length(prebuilds(shop)) == 4
    end

    test "thirty changes leave one prebuild waiting, for the last environment_ref", ctx do
      for minute <- 1..30, do: list(ctx, minute, %{environment_ref: "env-#{rem(minute, 2)}"})
      shop = Repo.get_by!(Collection, external_ref: "SHOP")

      assert prebuilds(shop) == [{ctx.pool.id, "env-0"}]
      assert waiting(shop) == [{ctx.pool.id, "env-0"}]
      assert %Record{queued_ref: "env-0"} = Environments.fetch(ctx.pool.id, shop.id)
    end

    test "changes across two node pools leave one prebuild waiting for each", ctx do
      pools = sorted([ctx.pool, pool_fixture(ctx.scope)])
      for minute <- 1..6, do: list(ctx, minute, %{environment_ref: "env-#{minute}"})
      shop = Repo.get_by!(Collection, external_ref: "SHOP")

      assert prebuilds(shop) == Enum.map(pools, &{&1, "env-6"})
      assert waiting(shop) == Enum.map(pools, &{&1, "env-6"})

      for record <- Environments.for_collection(shop.id),
          do: assert(record.queued_ref == "env-6")
    end

    test "a change while one is claimed queues exactly one that waits; the claimed one, lapsed, gives way",
         ctx do
      shop = list(ctx, 1, %{environment_ref: "env-1"})

      # Lapsed with none waiting, it waits again, as any run does.
      %{run: first, dispatch: lapsed} = claim!(ctx, ctx.pool)
      Dispatches.sweep(lapsed.lease_until)
      assert waiting(shop) == [{ctx.pool.id, "env-1"}]

      %{run: claimed, dispatch: dispatch} = claim!(ctx, ctx.pool)
      assert claimed.id == first.id

      list(ctx, 2, %{environment_ref: "env-2"})
      list(ctx, 3, %{environment_ref: "env-3"})
      list(ctx, 4, %{environment_ref: "env-2"})

      assert waiting(shop) == [{ctx.pool.id, "env-2"}]
      assert prebuilds(shop) == [{ctx.pool.id, "env-1"}, {ctx.pool.id, "env-2"}]

      assert %DispatchRun{state: :claimed, environment_ref: "env-1"} =
               Repo.get!(DispatchRun, claimed.id)

      assert %Record{queued_ref: "env-2"} = Environments.fetch(ctx.pool.id, shop.id)

      # Its lease lapsed, the claimed one ends, superseded by the one that waits, and its
      # dispatch with it.
      Dispatches.sweep(dispatch.lease_until)

      assert %DispatchRun{state: :ended, end_cause: :superseded} =
               Repo.get!(DispatchRun, claimed.id)

      assert %Dispatch{stale_at: %DateTime{}, slot_freed_at: %DateTime{}, end_cause: :run_ended} =
               Repo.get!(Dispatch, dispatch.id)

      assert waiting(shop) == [{ctx.pool.id, "env-2"}]
    end

    test "two claimed prebuilds of one collection and pool lapsing together leave one waiting, for the record's queued_ref",
         ctx do
      %{access_key: key} = enrolled_key_fixture(ctx.scope, ctx.pool)
      back = DateTime.add(Dispatches.now(), -700, :second)

      shop = list(ctx, 1, %{environment_ref: "env-1"})
      {:ok, %{run: older, dispatch: older_dispatch}} = Dispatches.claim(key, back)
      list(ctx, 2, %{environment_ref: "env-2"})
      {:ok, %{run: newer, dispatch: newer_dispatch}} = Dispatches.claim(key, back)
      assert {older.environment_ref, newer.environment_ref} == {"env-1", "env-2"}

      # Another organisation's explore run, claimed, lapses in the same sweep.
      %{scope: other} = sign_up_fixture()
      other_pool = pool_fixture(other)
      %{access_key: other_key} = enrolled_key_fixture(other, other_pool)
      {:ok, _run} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(other), 1) end)
      {:ok, %{run: explore, dispatch: explore_dispatch}} = Dispatches.claim(other_key, back)

      Dispatches.sweep(Dispatches.now())

      assert %DispatchRun{state: :ended, end_cause: :superseded} =
               Repo.get!(DispatchRun, older.id)

      assert %Dispatch{end_cause: :run_ended} = Repo.get!(Dispatch, older_dispatch.id)

      assert %DispatchRun{state: :waiting, environment_ref: "env-2"} =
               Repo.get!(DispatchRun, newer.id)

      assert %Dispatch{stale_at: %DateTime{}, ended_at: nil} =
               Repo.get!(Dispatch, newer_dispatch.id)

      assert waiting(shop) == [{ctx.pool.id, "env-2"}]
      assert %DispatchRun{state: :waiting} = Repo.get!(DispatchRun, explore.id)
      assert %Dispatch{stale_at: %DateTime{}} = Repo.get!(Dispatch, explore_dispatch.id)

      # The next sweep and claims go on as before.
      Dispatches.sweep(Dispatches.now())
      assert {:ok, %{run: %{id: id}}} = Dispatches.claim(key, Dispatches.now())
      assert id == newer.id
      assert {:ok, %{run: %{id: id}}} = Dispatches.claim(other_key, Dispatches.now())
      assert id == explore.id
    end

    test "of claimed prebuilds lapsing together, none queued for the record's queued_ref, the one queued last waits, with it",
         ctx do
      %{access_key: key} = enrolled_key_fixture(ctx.scope, ctx.pool)
      back = DateTime.add(Dispatches.now(), -700, :second)

      shop = list(ctx, 1, %{environment_ref: "env-1"})
      {:ok, %{run: older}} = Dispatches.claim(key, back)
      list(ctx, 2, %{environment_ref: "env-2"})
      {:ok, %{run: newer}} = Dispatches.claim(key, back)

      {1, _rows} =
        Repo.update_all(from(r in Record, where: r.source_collection_id == ^shop.id),
          set: [queued_ref: "env-3"]
        )

      Dispatches.sweep(Dispatches.now())

      assert %DispatchRun{state: :ended, end_cause: :superseded} =
               Repo.get!(DispatchRun, older.id)

      assert %DispatchRun{state: :waiting, environment_ref: "env-3"} =
               Repo.get!(DispatchRun, newer.id)
    end

    test "the older claimed prebuild, lapsed first, waits with the record's queued_ref, and the newer, lapsed later, gives way",
         ctx do
      %{access_key: key} = enrolled_key_fixture(ctx.scope, ctx.pool)

      shop = list(ctx, 1, %{environment_ref: "env-1"})
      {:ok, %{run: older, dispatch: older_dispatch}} = Dispatches.claim(key, Dispatches.now())
      list(ctx, 2, %{environment_ref: "env-2"})
      {:ok, %{run: newer, dispatch: newer_dispatch}} = Dispatches.claim(key, Dispatches.now())

      later = DateTime.add(older_dispatch.lease_until, 3600, :second)

      {1, _rows} =
        Repo.update_all(from(d in Dispatch, where: d.id == ^newer_dispatch.id),
          set: [lease_until: later]
        )

      Dispatches.sweep(older_dispatch.lease_until)

      assert %DispatchRun{state: :waiting, environment_ref: "env-2"} =
               Repo.get!(DispatchRun, older.id)

      Dispatches.sweep(later)

      assert %DispatchRun{state: :ended, end_cause: :superseded} =
               Repo.get!(DispatchRun, newer.id)

      assert waiting(shop) == [{ctx.pool.id, "env-2"}]

      # Named again, env-2 queues nothing more: the one that waits is for it.
      list(ctx, 3, %{environment_ref: "env-2"})
      assert waiting(shop) == [{ctx.pool.id, "env-2"}]
      assert length(prebuilds(shop)) == 2
    end

    test "an environment_ref removed ends the prebuild that waits, collection_ended, and leaves a claimed one",
         ctx do
      %{access_key: key} = enrolled_key_fixture(ctx.scope, ctx.pool)
      shop = list(ctx, 1, %{environment_ref: "env-1"})
      {:ok, %{run: claimed}} = Dispatches.claim(key, Dispatches.now())
      list(ctx, 2, %{environment_ref: "env-2"})

      [%DispatchRun{} = queued] =
        Repo.all(
          from r in DispatchRun, where: r.source_collection_id == ^shop.id and r.state == :waiting
        )

      list(ctx, 3, %{})

      assert %DispatchRun{state: :ended, end_cause: :collection_ended} =
               Repo.get!(DispatchRun, queued.id)

      assert %DispatchRun{state: :claimed} = Repo.get!(DispatchRun, claimed.id)
      assert waiting(shop) == []
      assert %Record{retired_at: %DateTime{}} = Environments.fetch(ctx.pool.id, shop.id)
      assert Dispatches.claim(key, Dispatches.now()) == {:ok, :none}
    end

    test "an environment_ref removed and named again queues each time it comes back", ctx do
      shop = list(ctx, 1, %{environment_ref: "env-1"})
      claim!(ctx, ctx.pool)

      list(ctx, 2, %{})
      list(ctx, 3, %{environment_ref: "env-1"})
      assert waiting(shop) == [{ctx.pool.id, "env-1"}]
      claim!(ctx, ctx.pool)

      # Removed a second time, the record is retired again, after it was queued again.
      list(ctx, 4, %{})
      record = Environments.fetch(ctx.pool.id, shop.id)
      assert DateTime.compare(record.retired_at, record.queued_at) == :gt

      list(ctx, 5, %{environment_ref: "env-1"})
      assert waiting(shop) == [{ctx.pool.id, "env-1"}]
      assert length(prebuilds(shop)) == 3
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

    test "a collection without a target, or assigned to no workspace, queues nothing", ctx do
      shop = list(ctx, 1, %{target: nil, environment_ref: "env-1"})
      assert shop.workspace_id == ctx.scope.workspace.id
      assert prebuilds(shop) == []
      assert Environments.for_collection(shop.id) == []

      # With a second workspace, a new collection is assigned to none.
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

    test "a workspace whose domain has no prebuilds queues none: by a listing, an assign or a new pool",
         ctx do
      with_domain(ctx.scope, "general")
      shop = list(ctx, 1, %{environment_ref: "env-1"})
      assert shop.workspace_id == ctx.scope.workspace.id
      assert prebuilds(shop) == []
      assert Environments.for_collection(shop.id) == []

      _new = pool_fixture(ctx.scope)
      assert prebuilds(shop) == []

      software = workspace_fixture(ctx.scope.organisation)
      theirs = pool_fixture(%{ctx.scope | workspace: software})
      {:ok, 1} = Collections.assign_collections(ctx.scope, ctx.connection, [shop.id], software)
      assert prebuilds(shop) == [{theirs.id, "env-1"}]

      general = Repo.get!(Workspace, ctx.scope.workspace.id)
      {:ok, 1} = Collections.assign_collections(ctx.scope, ctx.connection, [shop.id], general)
      list(ctx, 2, %{environment_ref: "env-2"})
      assert prebuilds(shop) == [{theirs.id, "env-1"}]
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
      assert Enum.sort(waiting(shop)) == Enum.sort([{ctx.pool.id, "env-2"}, {new.id, "env-1"}])
      assert Environments.fetch(new.id, shop.id).queued_ref == "env-1"
    end

    test "keeps the target each prebuild was queued for", ctx do
      shop = list(ctx, 1, %{environment_ref: "env-1"})

      assert %Record{
               queued_ref: "env-1",
               queued_target_system: "code.example.com",
               queued_target_path: "acme/shop",
               built_target_system: nil,
               built_target_path: nil
             } = Environments.fetch(ctx.pool.id, shop.id)
    end

    test "a target that changes with the same environment_ref queues a prebuild, as a changed environment_ref does",
         ctx do
      moved = %{system: "code.example.com", path: "acme/shop-next"}
      shop = list(ctx, 1, %{environment_ref: "env-1"})
      claim!(ctx, ctx.pool)

      list(ctx, 2, %{environment_ref: "env-1", target: moved})
      assert prebuilds(shop) == [{ctx.pool.id, "env-1"}, {ctx.pool.id, "env-1"}]
      assert waiting(shop) == [{ctx.pool.id, "env-1"}]

      assert %Record{
               queued_ref: "env-1",
               queued_target_system: "code.example.com",
               queued_target_path: "acme/shop-next"
             } = Environments.fetch(ctx.pool.id, shop.id)

      # The same target and environment_ref named again queue nothing.
      list(ctx, 3, %{environment_ref: "env-1", target: moved})
      assert length(prebuilds(shop)) == 2

      # Back to the first target while one waits: still one waits, and the record has the
      # target it is queued for now.
      list(ctx, 4, %{environment_ref: "env-1"})
      assert length(prebuilds(shop)) == 2
      assert waiting(shop) == [{ctx.pool.id, "env-1"}]

      assert %Record{queued_target_path: "acme/shop"} =
               Environments.fetch(ctx.pool.id, shop.id)

      # A system that changes, with the same path, is another target too.
      claim!(ctx, ctx.pool)

      list(ctx, 5, %{
        environment_ref: "env-1",
        target: %{system: "git.example.com", path: "acme/shop"}
      })

      assert waiting(shop) == [{ctx.pool.id, "env-1"}]
      assert length(prebuilds(shop)) == 3

      assert %Record{queued_target_system: "git.example.com", queued_target_path: "acme/shop"} =
               Environments.fetch(ctx.pool.id, shop.id)
    end

    test "a record of no queued target, as one kept before the target was, is queued for the collection's target",
         ctx do
      shop = list(ctx, 1, %{environment_ref: "env-1"})
      claim!(ctx, ctx.pool)

      Repo.update_all(from(r in Record, where: r.source_collection_id == ^shop.id),
        set: [queued_target_system: nil, queued_target_path: nil]
      )

      list(ctx, 2, %{environment_ref: "env-1"})
      assert waiting(shop) == [{ctx.pool.id, "env-1"}]

      assert %Record{queued_target_system: "code.example.com", queued_target_path: "acme/shop"} =
               Environments.fetch(ctx.pool.id, shop.id)
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

    test "keeps the build and its target, the reported ref as it is, and clears the last failure",
         ctx do
      failed_at = DateTime.add(DateTime.utc_now(), -60, :second)
      queued_at = DateTime.add(DateTime.utc_now(), -120, :second)

      Repo.insert!(
        record(
          ctx,
          Map.merge(built(), %{
            queued_at: queued_at,
            queued_target_system: "code.example.com",
            queued_target_path: "acme/app",
            failure_cause: :released,
            failure_reason: "no space",
            failed_at: failed_at
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
               built_target_system: "code.example.com",
               built_target_path: "acme/app",
               failure_cause: nil,
               failure_reason: nil,
               failed_at: nil,
               retired_at: nil,
               queued_ref: "env-1",
               queued_target_system: "code.example.com",
               queued_target_path: "acme/app"
             } = recorded

      assert image == @build.image
      assert DateTime.compare(recorded.built_at, now) == :eq
      assert DateTime.compare(recorded.queued_at, queued_at) == :eq
      assert recorded.built_queued_at == ~U[2026-10-15 11:00:00.000000Z]
    end

    test "keeps a record retired by a build whose run took its ref before, and queues nothing",
         ctx do
      retired_at = DateTime.add(DateTime.utc_now(), -30, :second)
      Repo.insert!(record(ctx, %{retired_at: retired_at}))

      recorded = record_build!(ctx)
      assert recorded.image == @build.image
      assert DateTime.compare(recorded.retired_at, retired_at) == :eq
      assert prebuilds(ctx.app) == []
    end

    test "makes a record that is missing, queued for the run's environment_ref and the built target",
         ctx do
      assert Environments.fetch(ctx.pool.id, ctx.app.id) == nil

      assert %Record{
               queued_ref: "env-1",
               queued_at: ~U[2026-10-15 10:00:00.000000Z],
               queued_target_system: "code.example.com",
               queued_target_path: "acme/app",
               built_target_path: "acme/app",
               reported_ref: "env-2"
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

  describe "a retired record" do
    @shop_target %{system: "code.example.com", path: "acme/shop"}

    defp shop_image(n),
      do: "registry.example.com/acme/shop-env@sha256:" <> String.duplicate(n, 64)

    # Records the build of `run` (as stored now), which reported `ref`, with the image `n`.
    defp land!(run, n, ref) do
      run = Repo.get!(DispatchRun, run.id)

      {:ok, :ok} =
        Repo.transact(fn ->
          {:ok,
           Environments.record_build(
             run,
             %{image: shop_image(n), size: 1_048_576, commit: "4b7d0a3f", environment_ref: ref},
             @shop_target,
             DateTime.utc_now()
           )}
        end)
    end

    test "is served again by a build of a ref that came back, never by one claimed before it was retired",
         ctx do
      shop = list(ctx, 1, %{environment_ref: "env-1"})
      %{run: old} = claim!(ctx, ctx.pool)

      # Absent: retired. Present again, a new ref, its prebuild claimed.
      list(ctx, 2, %{})
      assert %Record{retired_at: %DateTime{}} = Environments.fetch(ctx.pool.id, shop.id)
      list(ctx, 3, %{environment_ref: "env-2"})
      %{run: new} = claim!(ctx, ctx.pool)
      assert new.environment_ref == "env-2"

      # The old build lands late: stored, the record still retired, the pool's default.
      land!(old, "1", "env-1")
      assert %Record{retired_at: %DateTime{}} = record = Environments.fetch(ctx.pool.id, shop.id)
      assert record.image == shop_image("1")
      assert Environments.image_for(ctx.pool, @shop_target) == nil

      # The new ref's build lands: served.
      land!(new, "2", "env-2")
      assert %Record{retired_at: nil} = Environments.fetch(ctx.pool.id, shop.id)
      assert Environments.image_for(ctx.pool, @shop_target) == shop_image("2")
    end

    test "stays retired when a build claimed before it was retired lands", ctx do
      shop = list(ctx, 1, %{environment_ref: "env-1"})
      %{run: old} = claim!(ctx, ctx.pool)
      list(ctx, 2, %{})
      %Record{retired_at: retired_at} = Environments.fetch(ctx.pool.id, shop.id)

      land!(old, "1", "env-1")
      record = Environments.fetch(ctx.pool.id, shop.id)
      assert record.image == shop_image("1")
      assert DateTime.compare(record.retired_at, retired_at) == :eq
      assert Environments.image_for(ctx.pool, @shop_target) == nil
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

      # Newer, but not counted: a collection without an environment_ref, a record retired,
      # a collection ended or assigned to another workspace, another target.
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

      # A record queued again, never retired, keeps its last good build for runs until the
      # next one lands.
      Repo.update_all(from(r in Record, where: r.source_collection_id == ^newest.id),
        set: [queued_ref: "env-2", queued_at: DateTime.utc_now()]
      )

      assert Environments.image_for(ctx.pool, @shop) == image("2")

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
