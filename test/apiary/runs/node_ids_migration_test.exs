defmodule Apiary.Runs.NodeIdsMigrationTest do
  # The migration that names each id a node gives as the node's, run down and up again
  # inside the test's transaction, which rolls it all back. It changes `runs`, `events`,
  # `deliveries` and `node_instances` under every other test, so it is not async.
  use Apiary.DataCase, async: false

  @version 20_261_017_140_000
  @migration Apiary.Repo.Migrations.NameANodeSIdsAsTheNodeS

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_name_a_node_s_ids_as_the_node_s.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!, do: assert(:ok = Ecto.Migrator.down(Repo, @version, @migration, @options))
  defp up!, do: assert(:ok = Ecto.Migrator.up(Repo, @version, @migration, @options))

  @tables ~w(runs events deliveries node_instances)

  @columns_before %{
    "runs" => ~w(attach_instance_id instance_id run_id),
    "events" => ~w(event_id instance_id run_id),
    "deliveries" => ~w(delivery_id instance_id run_id),
    "node_instances" => ~w(instance_id)
  }

  @columns_after %{
    "runs" => ~w(gateway_instance_id node_instance_id node_run_id),
    "events" => ~w(node_event_id node_instance_id run_id),
    "deliveries" => ~w(node_delivery_id node_instance_id node_run_id),
    "node_instances" => ~w(node_instance_id)
  }

  @indexes_before ~w(
    deliveries_access_key_id_delivery_id_index
    deliveries_workspace_id_run_id_index
    events_workspace_id_event_id_index
    node_instances_node_id_instance_id_index
    runs_gateway_id_run_id_index
    runs_node_id_instance_id_alive_index
    runs_workspace_id_run_id_index
  )

  @indexes_after ~w(
    deliveries_access_key_id_node_delivery_id_index
    deliveries_workspace_id_node_run_id_index
    events_workspace_id_node_event_id_index
    node_instances_node_id_node_instance_id_index
    runs_gateway_id_node_run_id_index
    runs_node_id_node_instance_id_alive_index
    runs_public_id_pattern_index
    runs_workspace_id_node_run_id_index
  )

  @constraints_before ~w(
    deliveries_delivery_id_not_null
    deliveries_instance_id_check
    deliveries_run_id_not_null
    events_event_id_not_null
    events_instance_id_check
    node_instances_instance_id_check
    node_instances_instance_id_not_null
    runs_attach_instance_id_check
    runs_instance_id_check
    runs_run_id_not_null
  )

  @constraints_after ~w(
    deliveries_node_instance_id_check
    deliveries_node_run_id_not_null
    events_node_event_id_not_null
    events_node_instance_id_check
    node_instances_node_instance_id_check
    node_instances_node_instance_id_not_null
    runs_gateway_instance_id_check
    runs_node_instance_id_check
    runs_node_run_id_not_null
  )

  # The columns of each table that name an id a node gives, by the names either side of
  # the migration use.
  defp columns do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT table_name, column_name FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = ANY($1)
          AND column_name ~ '(run_id|instance_id|event_id|delivery_id)$'
        ORDER BY table_name, column_name
        """,
        [@tables]
      )

    Enum.group_by(rows, &hd/1, &List.last/1)
  end

  defp indexes(names) do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname = ANY($1)",
        [names]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  # Only the constraints Postgres names: a NOT NULL constraint has a name from Postgres 18
  # on.
  defp named_constraints(names) do
    %{rows: rows} =
      Repo.query!(
        "SELECT conname FROM pg_constraint WHERE conname = ANY($1) AND contype IN ('c', 'n')",
        [names]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  defp not_nulls_named? do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM pg_constraint WHERE contype = 'n'")
    count > 0
  end

  defp expected(names) do
    if not_nulls_named?(),
      do: names,
      else: Enum.reject(names, &String.ends_with?(&1, "_not_null"))
  end

  defp nullable?(table, column) do
    %{rows: [[nullable]]} =
      Repo.query!(
        "SELECT is_nullable FROM information_schema.columns " <>
          "WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2",
        [table, column]
      )

    nullable == "YES"
  end

  # A delivery row written in SQL, the migration up, with the given delivery id, which may
  # be null.
  defp insert_delivery!(delivery_id) do
    %{scope: scope} = Apiary.OrganisationsFixtures.sign_up_fixture()
    key = Apiary.AccessKeysFixtures.access_key_fixture(scope).access_key
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO deliveries (id, organisation_id, workspace_id, access_key_id, " <>
        "node_delivery_id, node_run_id, received_at, status) " <>
        "VALUES ($1, $2, $3, $4, $5, $6, now(), 202)",
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(scope.organisation.id),
        Ecto.UUID.dump!(scope.workspace.id),
        Ecto.UUID.dump!(key.id),
        delivery_id && Ecto.UUID.dump!(delivery_id),
        Ecto.UUID.dump!(Ecto.UUID.generate())
      ]
    )

    id
  end

  defp delivery_id_of(column, id) do
    %{rows: [[value]]} =
      Repo.query!("SELECT #{column}::text FROM deliveries WHERE id = $1", [Ecto.UUID.dump!(id)])

    value
  end

  defp pattern_index do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexdef FROM pg_indexes WHERE indexname = 'runs_public_id_pattern_index'"
      )

    List.flatten(rows)
  end

  test "down gives every column, index and constraint its old name; up the node's again" do
    assert columns() == @columns_after

    down!()
    assert columns() == @columns_before
    assert indexes(@indexes_before) == @indexes_before
    assert indexes(@indexes_after) == []
    assert named_constraints(@constraints_before) == expected(@constraints_before)
    assert named_constraints(@constraints_after) == []
    assert pattern_index() == []

    up!()
    assert columns() == @columns_after
    assert indexes(@indexes_after) == @indexes_after
    assert indexes(@indexes_before) == []
    assert named_constraints(@constraints_after) == expected(@constraints_after)
    assert named_constraints(@constraints_before) == []
  end

  test "up lets a delivery have no delivery id; down requires one again and fills those without" do
    assert nullable?("deliveries", "node_delivery_id")
    refute nullable?("deliveries", "node_run_id")
    without = insert_delivery!(nil)
    given = Ecto.UUID.generate()
    with_id = insert_delivery!(given)

    down!()
    refute nullable?("deliveries", "delivery_id")
    assert {:ok, _filled} = Ecto.UUID.cast(delivery_id_of("delivery_id", without))
    assert delivery_id_of("delivery_id", with_id) == given

    if not_nulls_named?(),
      do: assert(named_constraints(["deliveries_delivery_id_not_null"]) != [])

    up!()
    assert nullable?("deliveries", "node_delivery_id")
    assert named_constraints(["deliveries_node_delivery_id_not_null"]) == []
    assert named_constraints(["deliveries_delivery_id_not_null"]) == []
    assert delivery_id_of("node_delivery_id", with_id) == given
  end

  test "up keeps the unique index on a run's public id and adds one a prefix search can use" do
    down!()
    up!()

    assert indexes(["runs_public_id_index"]) == ["runs_public_id_index"]

    assert [definition] = pattern_index()
    assert definition =~ "ON public.runs USING btree (public_id text_pattern_ops)"
    refute definition =~ "UNIQUE"
  end

  test "a rename rewrites no row: a run and its event keep their values" do
    %{scope: scope} = Apiary.OrganisationsFixtures.sign_up_fixture()
    run = Apiary.RunEventsFixtures.run_fixture(scope, %{node_instance_id: "i_1"})
    event = Apiary.RunEventsFixtures.event_fixture(run, 2, "run.heartbeat", %{})

    down!()

    %{rows: [[run_id, instance_id]]} =
      Repo.query!("SELECT run_id::text, instance_id FROM runs WHERE id = $1", [
        Ecto.UUID.dump!(run.id)
      ])

    assert {run_id, instance_id} == {run.node_run_id, "i_1"}

    %{rows: [[event_id]]} =
      Repo.query!("SELECT event_id::text FROM events WHERE id = $1", [Ecto.UUID.dump!(event.id)])

    assert event_id == event.node_event_id

    up!()

    assert Repo.get!(Apiary.Runs.Run, run.id).node_run_id == run.node_run_id
    assert Repo.get!(Apiary.Runs.Event, event.id).node_event_id == event.node_event_id
  end
end
