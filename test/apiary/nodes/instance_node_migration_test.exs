defmodule Apiary.Nodes.InstanceNodeMigrationTest do
  # The migration that keeps a node pool and a gateway at the instance, with no
  # organisation and no workspace: each check, index, key and trigger it changes refuses a
  # wrong row and accepts an instance row, and its rollback refuses while an instance row
  # is there. The rows are written in SQL, so that no changeset stands between the write
  # and the database. Not async: the rollback test changes `nodes` under every other test.
  use Apiary.DataCase, async: false

  # Running a migration down and up again while later ones are applied makes Ecto warn
  # that an older migration ran after a newer one. The log is kept from the output and
  # shown only when a test fails.
  @moduletag :capture_log

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  @keep {20_261_024_100_000, Apiary.Repo.Migrations.KeepAPoolAndAGatewayAtTheInstance,
         "keep_a_pool_and_a_gateway_at_the_instance"}

  setup_all do
    for {version, migration, name} <- [@keep], not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  # A node written in SQL at `organisation` and `workspace`, either nil: a gateway gets an
  # address. Returns its id.
  defp insert!(kind, organisation, workspace, extra \\ %{}) do
    id = Ecto.UUID.generate()
    prefix = %{"node" => "nd", "pool" => "np", "gateway" => "ng", "adapter" => "na"}[kind]
    url = if kind == "gateway", do: "https://gateway.example"
    limit = if kind == "node", do: 1

    Repo.query!(
      """
      INSERT INTO nodes (id, organisation_id, workspace_id, public_id, name, kind, url,
        instance_limit, installed_as, deleted_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, now(), now())
      """,
      [
        Ecto.UUID.dump!(id),
        dump(organisation),
        dump(workspace),
        Apiary.PublicId.generate(prefix),
        unique_node_name(),
        kind,
        url,
        limit,
        Map.get(extra, :installed_as),
        Map.get(extra, :deleted_at)
      ]
    )

    id
  end

  defp dump(nil), do: nil
  defp dump(%{id: id}), do: Ecto.UUID.dump!(id)

  defp refused(constraint, fun) do
    assert_raise Postgrex.Error, ~r/#{constraint}/, fn -> Repo.transaction(fun) end
  end

  describe "nodes_place_check" do
    test "accepts a pool and a gateway with no organisation and no workspace", %{scope: scope} do
      assert insert!("pool", nil, nil)
      assert insert!("gateway", nil, nil)
      assert insert!("gateway", scope.organisation, nil)
      assert insert!("pool", scope.organisation, scope.workspace)
    end

    test "refuses a pool of an organisation without a workspace, and a node without one",
         %{scope: scope} do
      refused("nodes_place_check", fn -> insert!("pool", scope.organisation, nil) end)
      refused("nodes_place_check", fn -> insert!("node", nil, nil) end)
      refused("nodes_place_check", fn -> insert!("node", scope.organisation, nil) end)
      refused("nodes_place_check", fn -> insert!("adapter", scope.organisation, nil) end)
    end

    test "refuses a workspace without its organisation", %{scope: scope} do
      refused("nodes_place_check", fn -> insert!("pool", nil, scope.workspace) end)
      refused("nodes_place_check", fn -> insert!("gateway", nil, scope.workspace) end)
    end

    test "keeps a node's organisation: an organisation's gateway never becomes the instance's",
         %{scope: scope} do
      id = insert!("gateway", scope.organisation, nil)

      refused("nodes_place_fixed", fn ->
        Repo.query!("UPDATE nodes SET organisation_id = NULL WHERE id = $1", [
          Ecto.UUID.dump!(id)
        ])
      end)
    end
  end

  describe "nodes_instance_kind_index" do
    test "holds one pool and one gateway in use at the instance" do
      insert!("pool", nil, nil)
      insert!("gateway", nil, nil)

      refused("nodes_instance_kind_index", fn -> insert!("pool", nil, nil) end)
      refused("nodes_instance_kind_index", fn -> insert!("gateway", nil, nil) end)

      assert insert!("pool", nil, nil, %{deleted_at: DateTime.utc_now()})
    end
  end

  describe "installed_as" do
    test "is the instance pool's and gateway's folder, and no workspace pool's",
         %{scope: scope} do
      assert insert!("pool", nil, nil, %{installed_as: "pool"})
      assert insert!("gateway", nil, nil, %{installed_as: "gateway"})

      refused("nodes_installed_as_check", fn ->
        insert!("pool", scope.organisation, scope.workspace, %{installed_as: "other"})
      end)

      refused("nodes_installed_as_check", fn ->
        insert!("gateway", scope.organisation, nil, %{installed_as: "other"})
      end)
    end

    test "is in use once among adapters, the pool and the gateway" do
      insert!("pool", nil, nil, %{installed_as: "shared"})

      refused("nodes_installed_as_index", fn ->
        insert!("adapter", nil, nil, %{installed_as: "shared"})
      end)
    end
  end

  describe "pool_place_matches" do
    test "fires on the four tables whose rows name a pool or a node with a workspace" do
      %{rows: rows} =
        Repo.query!(
          "SELECT tgrelid::regclass::text FROM pg_trigger WHERE tgname LIKE '%_pool_place_matches'"
        )

      assert rows |> List.flatten() |> Enum.sort() ==
               ~w(dispatch_runs dispatches environments runs)
    end

    test "accepts a run on the instance's pool in any workspace", %{scope: scope} do
      pool = Repo.get!(Apiary.Nodes.Node, insert!("pool", nil, nil))

      run =
        node_run_fixture(pool, "i_1", %{
          organisation_id: scope.organisation.id,
          workspace_id: scope.workspace.id
        })

      assert run.node_id == pool.id
    end

    test "refuses a run on a node of another workspace, or on the instance's gateway",
         %{scope: scope} do
      %{scope: other} = sign_up_fixture()
      theirs = node_fixture(other)
      gateway = Repo.get!(Apiary.Nodes.Node, insert!("gateway", nil, nil))

      for node <- [theirs, gateway] do
        assert_raise Ecto.ConstraintError, ~r/pool_place_matches/, fn ->
          node_run_fixture(node, "i_1", %{
            organisation_id: scope.organisation.id,
            workspace_id: scope.workspace.id
          })
        end
      end
    end

    test "refuses an update that moves a run's node to another workspace's",
         %{scope: scope} do
      run = node_run_fixture(node_fixture(scope), "i_1")
      %{scope: other} = sign_up_fixture()
      theirs = node_fixture(other)

      refused("pool_place_matches", fn ->
        Repo.query!("UPDATE runs SET node_id = $1 WHERE id = $2", [
          Ecto.UUID.dump!(theirs.id),
          Ecto.UUID.dump!(run.id)
        ])
      end)
    end
  end

  describe "node_instances" do
    test "an instance node's instance has no organisation and no workspace", %{scope: scope} do
      pool = Repo.get!(Apiary.Nodes.Node, insert!("pool", nil, nil))
      instance = instance_fixture(pool)
      assert instance.organisation_id == nil

      refused("node_instances_place_check", fn ->
        Repo.query!(
          """
          INSERT INTO node_instances (id, organisation_id, workspace_id, node_id,
            node_instance_id, first_seen_at, last_seen_at)
          VALUES ($1, NULL, $2, $3, 'i_2', now(), now())
          """,
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            Ecto.UUID.dump!(scope.workspace.id),
            Ecto.UUID.dump!(pool.id)
          ]
        )
      end)
    end
  end

  describe "the rollback" do
    test "refuses while the instance's pool is there, and runs down and up without one" do
      {version, migration, _name} = @keep
      id = insert!("pool", nil, nil)

      assert_raise Postgrex.Error, ~r/the instance's pool or gateway/, fn ->
        Ecto.Migrator.down(Repo, version, migration, @options)
      end

      Repo.query!("DELETE FROM nodes WHERE id = $1", [Ecto.UUID.dump!(id)])

      assert :ok = Ecto.Migrator.down(Repo, version, migration, @options)
      refused("nodes_place_check", fn -> insert!("pool", nil, nil) end)
      assert :ok = Ecto.Migrator.up(Repo, version, migration, @options)
      assert insert!("pool", nil, nil)
    end
  end
end
