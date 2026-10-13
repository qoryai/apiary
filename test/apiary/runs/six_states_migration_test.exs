defmodule Apiary.Runs.SixStatesMigrationTest do
  # The migration that allows the six states beside the three old names, run down and up
  # again inside the test's transaction, which rolls it all back, on the schema as it left
  # it: the three migrations after it, which store every run under its new state and
  # narrow the check, are run down first. It changes the `runs` table under every other
  # test, so it is not async.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.Runs.Run

  @version 20_261_009_233_000
  @options [log: false, migration_lock: false]
  @migration Apiary.Repo.Migrations.AllowTheSixStatesOfARun

  # The migrations after it, the latest first.
  @later [
    {20_261_013_120_200, Apiary.Repo.Migrations.ValidateTheSixStatesCheck,
     "validate_the_six_states_check"},
    {20_261_013_120_100, Apiary.Repo.Migrations.AllowOnlyTheSixStatesOfARun,
     "allow_only_the_six_states_of_a_run"},
    {20_261_013_120_000, Apiary.Repo.Migrations.StoreEveryRunUnderItsNewState,
     "store_every_run_under_its_new_state"}
  ]

  setup_all do
    migrations = [{@version, @migration, "allow_the_six_states_of_a_run"} | @later]

    for {version, migration, name} <- migrations, not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  setup do
    for {version, migration, _name} <- @later,
        do: assert(:ok = Ecto.Migrator.down(Repo, version, migration, @options))

    :ok
  end

  # A run row in `state`, with its `reason`, written in SQL: the state check may be the
  # old one.
  defp insert!(scope, state, reason \\ nil) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO runs (id, organisation_id, workspace_id, run_id, state, reason, " <>
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

  # A refused insert, in a savepoint of its own, so the test's transaction goes on.
  defp refused?(scope, state) do
    assert_raise Postgrex.Error, ~r/runs_state_check/, fn ->
      Repo.transaction(fn -> insert!(scope, state) end)
    end
  end

  test "the check takes the six states and the three old names, and refuses any other" do
    %{scope: scope} = sign_up_fixture()

    assert Run.states() == ~w(pending running completed failed cancelled lost)

    for state <- Run.states() ++ ~w(succeeded timed_out ended),
        do: assert(state(insert!(scope, state)) == state)

    for state <- ~w(closed paused Completed), do: refused?(scope, state)
  end

  test "down allows the seven states of before, a completed run succeeded and a cancelled one timed out or ended; up allows both again" do
    %{scope: scope} = sign_up_fixture()

    completed = insert!(scope, "completed")
    timed_out = insert!(scope, "cancelled", "timeout")
    quiet = insert!(scope, "cancelled", "quiet")
    stopped = insert!(scope, "cancelled", "no_longer_needed")
    lost = insert!(scope, "lost", "gateway_lost")
    succeeded = insert!(scope, "succeeded")

    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, @options)

    assert state(completed) == "succeeded"
    assert state(timed_out) == "timed_out"
    assert state(quiet) == "ended"
    assert state(stopped) == "ended"
    assert state(lost) == "lost"
    assert state(succeeded) == "succeeded"

    for state <- ~w(completed cancelled), do: refused?(scope, state)

    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, @options)

    for state <- ~w(completed cancelled succeeded timed_out ended),
        do: assert(state(insert!(scope, state)) == state)
  end
end
