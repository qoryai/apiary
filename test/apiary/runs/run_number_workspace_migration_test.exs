defmodule Apiary.Runs.RunNumberWorkspaceMigrationTest do
  # The migration that numbers runs per workspace, run down and up again on real rows
  # inside the test's transaction, which rolls it all back. It changes the `runs` table
  # under every other test, so it is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Runs.Number
  alias Apiary.WorkItems.WorkItem

  @version 20_261_105_090_000
  @migration Apiary.Repo.Migrations.NumberRunsPerWorkspace

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_number_runs_per_workspace.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!, do: assert(:ok = Ecto.Migrator.down(Repo, @version, @migration, @options))
  defp up!, do: assert(:ok = Ecto.Migrator.up(Repo, @version, @migration, @options))

  # A run row written in SQL as the code before the migration wrote it, its number from
  # the sequence.
  defp insert!(scope, inserted_at) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO runs (id, organisation_id, workspace_id, node_run_id, state, public_id, " <>
        "inserted_at, updated_at) VALUES ($1, $2, $3, $4, 'pending', run_public_id(), $5, $5)",
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(scope.organisation.id),
        Ecto.UUID.dump!(scope.workspace.id),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        inserted_at
      ]
    )

    id
  end

  defp numbers do
    %{rows: rows} = Repo.query!("SELECT id, number FROM runs")
    Map.new(rows, fn [id, number] -> {Ecto.UUID.load!(id), number} end)
  end

  defp counters do
    %{rows: rows} = Repo.query!("SELECT workspace_id, last_number FROM run_counters")
    Map.new(rows, fn [id, last] -> {Ecto.UUID.load!(id), last} end)
  end

  defp column do
    %{rows: rows} =
      Repo.query!(
        "SELECT is_nullable, column_default FROM information_schema.columns " <>
          "WHERE table_name = 'runs' AND column_name = 'number'"
      )

    rows
  end

  defp relation?(name) do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM pg_class WHERE relname = $1", [name])
    count == 1
  end

  defp at(minute), do: DateTime.add(~U[2026-10-01 09:00:00.000000Z], minute, :minute)

  test "up numbers each workspace's runs from 1, in creation order, and fills the counters" do
    %{scope: first} = sign_up_fixture()
    %{scope: second} = sign_up_fixture()
    %{scope: no_runs} = sign_up_fixture()

    down!()
    assert [["NO", "nextval('runs_number_seq'::regclass)"]] = column()
    assert relation?("runs_number_seq")
    refute relation?("run_counters")

    # Inserted out of creation order; the rows of the two workspaces take turns.
    late = insert!(first, at(30))
    a = insert!(second, at(1))
    early = insert!(first, at(10))
    b = insert!(second, at(2))
    # Two rows with one `inserted_at` go by the number they had.
    tie_one = insert!(first, at(40))
    tie_two = insert!(first, at(40))

    assert Map.fetch!(numbers(), late) == Enum.min(Map.values(numbers()))
    assert Map.fetch!(numbers(), tie_one) < Map.fetch!(numbers(), tie_two)

    up!()
    assert column() == [["NO", nil]]
    refute relation?("runs_number_seq")
    refute relation?("runs_number_index")
    assert relation?("runs_workspace_id_number_index")
    assert relation?("run_counters")

    numbers = numbers()

    assert Enum.map([early, late, tie_one, tie_two], &Map.fetch!(numbers, &1)) == [1, 2, 3, 4]
    assert Enum.map([a, b], &Map.fetch!(numbers, &1)) == [1, 2]

    counters = counters()
    assert Map.fetch!(counters, first.workspace.id) == 4
    assert Map.fetch!(counters, second.workspace.id) == 2
    refute Map.has_key?(counters, no_runs.workspace.id)

    # The next run of each workspace takes the number after the highest; a workspace with
    # no runs starts at 1.
    take = fn scope ->
      {:ok, number} = Repo.transact(fn -> {:ok, Number.next(scope.workspace)} end)
      number
    end

    assert take.(first) == 5
    assert take.(second) == 3
    assert take.(no_runs) == 1
  end

  test "up raises a workspace's counter for a work item moved there, and keeps old numbers" do
    %{scope: first} = sign_up_fixture()
    there = workspace_scope(first.user, workspace_fixture(first.organisation))
    fresh = workspace_scope(first.user, workspace_fixture(first.organisation))
    moved = work_item_fixture(first)

    # Four runs where the work item was, and one where it moved to, as before a raise.
    old =
      for take_in <- 11..14,
          do: explore_run_fixture(moved, take_in: take_in, settle: false).run.id

    {1, _rows} =
      Repo.update_all(from(w in WorkItem, where: w.id == ^moved.id),
        set: [workspace_id: there.workspace.id]
      )

    new = explore_run_fixture(Repo.get!(WorkItem, moved.id), settle: false).run.id

    # The other work item in the fresh workspace raises nothing there: it has no runs.
    work_item_fixture(fresh)

    down!()
    up!()

    numbers = numbers()
    counters = counters()

    assert Enum.map(old, &Map.fetch!(numbers, &1)) == [1, 2, 3, 4]
    # The run in the new workspace is Run 1, as the work item's first run is: not changed.
    assert Map.fetch!(numbers, new) == 1
    assert Map.fetch!(counters, first.workspace.id) == 4
    assert Map.fetch!(counters, there.workspace.id) == 4
    refute Map.has_key?(counters, fresh.workspace.id)

    take = fn scope ->
      {:ok, number} = Repo.transact(fn -> {:ok, Number.next(scope.workspace)} end)
      number
    end

    assert take.(there) == 5
    assert take.(first) == 5
    assert take.(fresh) == 1
  end

  test "up keeps a workspace's counter that is past the numbers of a work item moved there" do
    %{scope: first} = sign_up_fixture()
    there = workspace_scope(first.user, workspace_fixture(first.organisation))
    moved = work_item_fixture(first)

    for take_in <- 11..12, do: explore_run_fixture(moved, take_in: take_in, settle: false)

    {1, _rows} =
      Repo.update_all(from(w in WorkItem, where: w.id == ^moved.id),
        set: [workspace_id: there.workspace.id]
      )

    down!()
    for minute <- 1..7, do: insert!(there, at(minute))
    up!()

    counters = counters()
    assert Map.fetch!(counters, first.workspace.id) == 2
    assert Map.fetch!(counters, there.workspace.id) == 7
  end

  # The previous release sets no number on an insert, and runs on this schema.
  test "an insert with no number makes the counter's row and takes 1, and next/1 takes 2" do
    %{scope: scope} = sign_up_fixture()
    assert Map.get(counters(), scope.workspace.id) == nil

    %{rows: [[number]]} =
      Repo.query!(
        "INSERT INTO runs (id, organisation_id, workspace_id, node_run_id, state, public_id, " <>
          "inserted_at, updated_at) VALUES ($1, $2, $3, $4, 'pending', run_public_id(), now(), " <>
          "now()) RETURNING number",
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          Ecto.UUID.dump!(scope.organisation.id),
          Ecto.UUID.dump!(scope.workspace.id),
          Ecto.UUID.dump!(Ecto.UUID.generate())
        ]
      )

    assert number == 1
    assert Map.fetch!(counters(), scope.workspace.id) == 1
    assert {:ok, 2} = Repo.transact(fn -> {:ok, Number.next(scope.workspace)} end)
  end

  test "up on an empty table makes no counter" do
    %{scope: scope} = sign_up_fixture()

    down!()
    Repo.query!("DELETE FROM runs")
    up!()

    assert counters() == %{}
    assert {:ok, 1} = Repo.transact(fn -> {:ok, Number.next(scope.workspace)} end)
  end

  test "down goes back to one count on the server, and the sequence goes on from it" do
    %{scope: first} = sign_up_fixture()
    %{scope: second} = sign_up_fixture()

    down!()
    a = insert!(first, at(1))
    b = insert!(second, at(2))
    tie_one = insert!(first, at(3))
    tie_two = insert!(second, at(3))
    up!()

    assert Map.fetch!(numbers(), a) == 1
    assert Map.fetch!(numbers(), b) == 1

    down!()
    assert [["NO", "nextval('runs_number_seq'::regclass)"]] = column()
    assert relation?("runs_number_seq")
    assert relation?("runs_number_index")
    refute relation?("runs_workspace_id_number_index")
    refute relation?("run_counters")

    %{rows: [[triggers]]} =
      Repo.query!("SELECT count(*) FROM pg_trigger WHERE tgname = 'runs_number_from_counter'")

    assert triggers == 0

    numbers = numbers()
    assert Map.fetch!(numbers, a) == 1
    assert Map.fetch!(numbers, b) == 2
    assert [3, 4] == Enum.sort([Map.fetch!(numbers, tie_one), Map.fetch!(numbers, tie_two)])

    later = insert!(first, at(4))
    assert Map.fetch!(numbers(), later) == 5

    # And up again, from those numbers.
    up!()
    numbers = numbers()
    assert Map.fetch!(numbers, later) == 3
    assert Map.fetch!(counters(), first.workspace.id) == 3
    assert Map.fetch!(counters(), second.workspace.id) == 2
  end
end
