defmodule Apiary.Runs.RunNumberMigrationTest do
  # The migration that gives every run its number, run down and up again inside the test's
  # transaction, which rolls it all back. It changes the `runs` table under every other
  # test, so it is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

  import Apiary.OrganisationsFixtures

  alias Apiary.Runs.Run

  @version 20_261_101_120_000
  @migration Apiary.Repo.Migrations.NumberEveryRun

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_number_every_run.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!, do: assert(:ok = Ecto.Migrator.down(Repo, @version, @migration, @options))
  defp up!, do: assert(:ok = Ecto.Migrator.up(Repo, @version, @migration, @options))

  # A run row written in SQL, with no number: the column may not be there.
  defp insert!(scope, inserted_at, started_at) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO runs (id, organisation_id, workspace_id, node_run_id, state, started_at, " <>
        "inserted_at, updated_at) VALUES ($1, $2, $3, $4, 'pending', $5, $6, $6)",
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(scope.organisation.id),
        Ecto.UUID.dump!(scope.workspace.id),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        started_at,
        inserted_at
      ]
    )

    id
  end

  defp numbers do
    %{rows: rows} = Repo.query!("SELECT id, number FROM runs")
    Map.new(rows, fn [id, number] -> {Ecto.UUID.load!(id), number} end)
  end

  defp column do
    %{rows: rows} =
      Repo.query!(
        "SELECT is_nullable, column_default FROM information_schema.columns " <>
          "WHERE table_name = 'runs' AND column_name = 'number'"
      )

    rows
  end

  defp sequence? do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM pg_class WHERE relname = 'runs_number_seq'")

    count == 1
  end

  defp at(minute), do: DateTime.add(~U[2026-10-01 09:00:00.000000Z], minute, :minute)

  test "up numbers the runs there before it across workspaces, in the order they started" do
    %{scope: first} = sign_up_fixture()
    %{scope: second} = sign_up_fixture()

    down!()
    assert column() == []
    refute sequence?()

    # Inserted in another order than they started; one never started and counts from its
    # insert; two started at the same moment go by their insert.
    c = insert!(first, at(1), at(30))
    a = insert!(second, at(2), at(10))
    b = insert!(first, at(20), nil)
    tie_late = insert!(second, at(41), at(40))
    tie_early = insert!(first, at(35), at(40))

    up!()
    assert column() == [["NO", "nextval('runs_number_seq'::regclass)"]]
    assert sequence?()

    numbers = numbers()

    assert Enum.map([a, b, c, tie_early, tie_late], &Map.fetch!(numbers, &1)) ==
             [1, 2, 3, 4, 5]

    # A run inserted after the migration, with no number, takes the next one.
    later = insert!(first, at(50), nil)
    assert Map.fetch!(numbers(), later) == 6
  end

  test "up on an empty table starts the numbers at 1" do
    %{scope: scope} = sign_up_fixture()

    down!()
    Repo.query!("DELETE FROM runs")
    up!()

    id = insert!(scope, at(1), nil)
    assert Map.fetch!(numbers(), id) == 1
  end

  test "an insert through the schema reads its number back, and no two runs share one" do
    %{scope: scope} = sign_up_fixture()

    insert = fn ->
      Repo.insert!(%Run{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        node_run_id: Ecto.UUID.generate(),
        public_id: Run.new_public_id()
      })
    end

    first = insert.()
    second = insert.()

    assert is_integer(first.number) and first.number >= 1
    assert second.number == first.number + 1

    assert_raise Ecto.ConstraintError, ~r/runs_number_index/, fn ->
      Repo.insert!(%Run{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        node_run_id: Ecto.UUID.generate(),
        public_id: Run.new_public_id(),
        number: first.number
      })
    end
  end

  test "down removes the column and its sequence; up brings both back" do
    down!()
    assert column() == []
    refute sequence?()

    up!()
    assert [["NO", _default]] = column()
    assert sequence?()
  end
end
