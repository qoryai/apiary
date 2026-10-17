defmodule Apiary.EnvironmentsTest do
  # The environment records (`Apiary.Environments.Record`): the reads, the table's rules
  # (one record per pool and collection, the last good build set together, the image
  # pinned by its digest, the bounds of the refs, a failure's cause and reason), the
  # composite keys that hold a record to its pool's workspace and its collection's
  # organisation, and the purges of a workspace and of an organisation.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Deletion, Environments, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Collections}
  alias Apiary.Environments.Record
  alias Apiary.Organisations.{Organisation, Workspace}

  @moduletag needs: :factory

  @image "registry.example.com:5000/acme/shop-env@sha256:" <> String.duplicate("3b9d", 16)

  setup do
    %{scope: scope} = sign_up_fixture()
    connectable = connectable_adapter_fixture()
    {connection, _nonce} = connection_fixture(scope, connectable.adapter, :connected)
    {:ok, verified} = AccessKeys.fetch_for_verification(connectable.access_key.key_id)
    key_scope = Scope.for_access_key(verified)

    listing = %{
      time: DateTime.utc_now(:second),
      connection_id: connection.public_id,
      collections:
        for ref <- ["APP", "DOCS"] do
          %{
            ref: ref,
            url: "https://code.example.com/acme/" <> ref,
            title: ref,
            target: %{system: "code.example.com", path: "acme/" <> ref},
            environment_ref: "env-1"
          }
        end,
      listing: %{id: "l", part: 1, started_at: ~U[2026-10-15 11:00:00Z], complete: true}
    }

    {:ok, :accepted} = Collections.post_listing(key_scope, listing)
    app = Repo.get_by!(Collection, external_ref: "APP")
    docs = Repo.get_by!(Collection, external_ref: "DOCS")
    %{scope: scope, app: app, docs: docs, pool: pool_fixture(scope)}
  end

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
end
