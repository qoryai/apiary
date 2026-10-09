defmodule Apiary.Runs.NoClosedStateMigrationTest do
  # The migration that drops the state `closed`, run down and up again inside the test's
  # transaction, which rolls it all back. It changes the `runs` table under every other
  # test, so it is not async.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.Runs.Run

  @version 20_261_009_200_000
  @migration Apiary.Repo.Migrations.DropTheClosedStateOfARun

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_drop_the_closed_state_of_a_run.exs")
      |> Code.require_file()
    end

    :ok
  end

  defp columns do
    %{rows: rows} =
      Repo.query!("""
      SELECT column_name FROM information_schema.columns
      WHERE table_name = 'runs' AND column_name IN ('closed_at', 'closed_by_id')
      ORDER BY column_name
      """)

    List.flatten(rows)
  end

  # A run row in `state`, with `columns` beside it, written in SQL: the schema has no
  # column of a close, and the state check may be the old one.
  defp insert!(scope, state, columns \\ []) do
    id = Ecto.UUID.generate()
    names = Enum.map_join(columns, &", #{elem(&1, 0)}")
    values = Enum.map_join(6..(5 + length(columns))//1, &", $#{&1}")

    Repo.query!(
      "INSERT INTO runs (id, organisation_id, workspace_id, run_id, state, inserted_at, " <>
        "updated_at#{names}) VALUES ($1, $2, $3, $4, $5, now(), now()#{values})",
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(scope.organisation.id),
        Ecto.UUID.dump!(scope.workspace.id),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        state | Keyword.values(columns)
      ]
    )

    id
  end

  test "a run has no state closed and no columns of a close" do
    %{scope: scope} = sign_up_fixture()

    refute "closed" in Run.states()
    assert columns() == []

    assert_raise Postgrex.Error, ~r/runs_state_check/, fn ->
      insert!(scope, "closed")
    end
  end

  test "down gives the columns and the state back; up makes a closed run lost" do
    %{scope: scope} = sign_up_fixture()

    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, log: false, migration_lock: false)
    assert columns() == ["closed_at", "closed_by_id"]

    closed_at = ~U[2026-10-01 12:00:00.000000Z]

    closed =
      insert!(scope, "closed", closed_at: closed_at, closed_by_id: Ecto.UUID.dump!(scope.user.id))

    lost_at = ~U[2026-10-02 08:00:00.000000Z]

    already_lost = insert!(scope, "closed", lost_at: lost_at, closed_at: closed_at)

    unclosed = insert!(scope, "closed")
    running = insert!(scope, "running")

    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, log: false, migration_lock: false)
    assert columns() == []

    assert %Run{state: "lost", lost_at: ^closed_at} = Repo.get!(Run, closed)
    assert %Run{state: "lost", lost_at: ^lost_at} = Repo.get!(Run, already_lost)
    assert %Run{state: "lost", lost_at: %DateTime{}} = Repo.get!(Run, unclosed)
    assert %Run{state: "running", lost_at: nil} = Repo.get!(Run, running)
  end
end
