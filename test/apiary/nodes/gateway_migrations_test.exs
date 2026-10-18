defmodule Apiary.Nodes.GatewayMigrationsTest do
  # The two migrations that make a gateway a kind of node and let a node choose its
  # gateway, run down and up again inside the test's transaction, which rolls it all back.
  # They change the `nodes` table under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  @kind {20_261_011_130_000, Apiary.Repo.Migrations.MakeAGatewayAKindOfNode,
         "make_a_gateway_a_kind_of_node"}
  @choice {20_261_011_131_000, Apiary.Repo.Migrations.LetANodeChooseItsGateway,
           "let_a_node_choose_its_gateway"}

  setup_all do
    for {version, migration, name} <- [@kind, @choice], not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.down(Repo, version, migration, @options))

  defp up!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.up(Repo, version, migration, @options))

  # Both down, the later first; both up, the earlier first.
  defp down_both! do
    down!(@choice)
    down!(@kind)
  end

  defp up_both! do
    up!(@kind)
    up!(@choice)
  end

  defp columns do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'nodes' " <>
          "AND column_name IN ('url', 'default_gateway', 'gateway_choice', 'gateway_id')"
      )

    rows |> List.flatten() |> Enum.sort()
  end

  # A node or a pool written in SQL, as it was before the migrations.
  defp insert!(scope, kind, prefix, limit) do
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO nodes (id, organisation_id, workspace_id, public_id, name, kind,
        instance_limit, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, now(), now())
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(scope.organisation.id),
        Ecto.UUID.dump!(scope.workspace.id),
        Apiary.PublicId.generate(prefix),
        unique_node_name(),
        kind,
        limit
      ]
    )

    id
  end

  test "every node and pool there before is direct after, naming no gateway" do
    %{scope: scope} = sign_up_fixture()
    node_fixture(scope)

    down_both!()
    assert columns() == []

    before = [insert!(scope, "node", "nd", 1), insert!(scope, "pool", "np", nil)]

    up_both!()
    assert columns() == ~w(default_gateway gateway_choice gateway_id url)

    %{rows: rows} =
      Repo.query!("SELECT id, gateway_choice, gateway_id, url, default_gateway FROM nodes")

    assert length(rows) >= 3

    for [_id, choice, gateway_id, url, default?] <- rows do
      assert {choice, gateway_id, url, default?} == {"direct", nil, nil, false}
    end

    ids = Enum.map(rows, fn [id | _] -> Ecto.UUID.load!(id) end)
    for id <- before, do: assert(id in ids)
  end

  test "down and up again: the columns, the checks and the trigger come back and hold" do
    %{scope: scope} = sign_up_fixture()

    down_both!()
    assert columns() == []

    assert_raise Postgrex.Error, ~r/nodes_(kind|public_id|instance_limit)_check/, fn ->
      Repo.transaction(fn -> insert!(scope, "gateway", "ng", nil) end)
    end

    up_both!()

    gateway = gateway_fixture(scope)
    assert "ng_" <> _ = gateway.public_id
    assert gateway.default_gateway

    node = node_fixture(scope, gateway_choice: "named", gateway_id: gateway.id)
    assert node.gateway_id == gateway.id

    assert_raise Postgrex.Error, ~r/nodes_gateway_is_a_gateway/, fn ->
      Repo.transaction(fn ->
        Repo.query!("UPDATE nodes SET gateway_id = id WHERE id = $1", [Ecto.UUID.dump!(node.id)])
      end)
    end
  end

  test "rolled back, the kind refuses to go while a gateway row is there" do
    %{scope: scope} = sign_up_fixture()
    gateway_fixture(scope)

    down!(@choice)

    assert_raise Postgrex.Error, ~r/nodes holds gateways/, fn ->
      Ecto.Migrator.down(Repo, elem(@kind, 0), elem(@kind, 1), @options)
    end

    assert "url" in columns()
    up!(@choice)
  end
end
