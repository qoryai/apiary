defmodule Apiary.Runs.OldStateNamesMigrationTest do
  # The migration that rewrites the three old names of a run's state and refuses them, run
  # down and up again inside the test's transaction, which rolls it all back. It changes the
  # `runs` table under every other test, so it is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

  import Apiary.OrganisationsFixtures

  alias Apiary.Runs.Run

  @version 20_261_019_004_000
  @migration Apiary.Repo.Migrations.RefuseTheOldNamesOfARunSState

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_refuse_the_old_names_of_a_run_s_state.exs")
      |> Code.require_file()
    end

    :ok
  end

  # A run row in `state`, with its `reason`, written in SQL: the state check may be the
  # old one.
  defp insert!(scope, state, reason \\ nil) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO runs (id, organisation_id, workspace_id, node_run_id, state, reason, " <>
        "inserted_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, now(), now())",
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(scope.organisation.id),
        Ecto.UUID.dump!(scope.workspace.id),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        state,
        reason
      ]
    )

    id
  end

  defp state(id), do: Repo.get!(Run, id).state

  # A refused insert, in a savepoint, so the test's transaction goes on.
  defp refused?(scope, state) do
    assert_raise Postgrex.Error, ~r/runs_state_check/, fn ->
      Repo.transaction(fn -> insert!(scope, state) end)
    end
  end

  test "the check takes the six states and refuses the old names" do
    %{scope: scope} = sign_up_fixture()

    assert Run.states() == ~w(pending running completed failed cancelled lost)

    for state <- Run.states(), do: assert(state(insert!(scope, state)) == state)

    for state <- ~w(succeeded timed_out ended closed paused Completed),
        do: refused?(scope, state)
  end

  test "down allows the old names again; up rewrites each to its state and refuses them" do
    %{scope: scope} = sign_up_fixture()

    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, log: false, migration_lock: false)

    succeeded = insert!(scope, "succeeded")
    timed_out = insert!(scope, "timed_out", "timeout")
    ended = insert!(scope, "ended", "no_longer_needed")
    completed = insert!(scope, "completed")
    lost = insert!(scope, "lost", "gateway_lost")

    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, log: false, migration_lock: false)

    assert state(succeeded) == "completed"
    assert state(timed_out) == "cancelled"
    assert state(ended) == "cancelled"
    assert state(completed) == "completed"
    assert state(lost) == "lost"

    for state <- ~w(succeeded timed_out ended), do: refused?(scope, state)
  end
end
