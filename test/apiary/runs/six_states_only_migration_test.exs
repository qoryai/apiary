defmodule Apiary.Runs.SixStatesOnlyMigrationTest do
  # The three migrations that store every run under its new state, allow the six states
  # only and validate that check, run down and up again inside the test's transaction,
  # which rolls it all back. They change the `runs` table under every other test, so this
  # is not async.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.Runs.Run

  @store {20_261_013_120_000, Apiary.Repo.Migrations.StoreEveryRunUnderItsNewState,
          "store_every_run_under_its_new_state"}
  @allow {20_261_013_120_100, Apiary.Repo.Migrations.AllowOnlyTheSixStatesOfARun,
          "allow_only_the_six_states_of_a_run"}
  @validate {20_261_013_120_200, Apiary.Repo.Migrations.ValidateTheSixStatesCheck,
             "validate_the_six_states_check"}

  setup_all do
    for {version, migration, name} <- [@store, @allow, @validate],
        not Code.ensure_loaded?(migration) do
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

  # The schema as 20261009233000 left it: the check allows the three old names too.
  defp before! do
    down!(@validate)
    down!(@allow)
    down!(@store)
  end

  defp after! do
    up!(@store)
    up!(@allow)
    up!(@validate)
  end

  @exited ~U[2026-10-01 10:00:00.000000Z]
  @lost ~U[2026-10-01 09:00:00.000000Z]
  @written ~U[2026-10-01 11:00:00.000000Z]

  # A run row in `state`, with `columns` beside it, written in SQL as a build before
  # 20261009233000 stored it.
  defp insert!(scope, state, columns \\ []) do
    columns =
      [
        id: Ecto.UUID.dump!(Ecto.UUID.generate()),
        organisation_id: Ecto.UUID.dump!(scope.organisation.id),
        workspace_id: Ecto.UUID.dump!(scope.workspace.id),
        run_id: Ecto.UUID.dump!(Ecto.UUID.generate()),
        state: state,
        inserted_at: @written,
        updated_at: @written
      ] ++ columns

    values = Enum.map_join(1..length(columns), ", ", &"$#{&1}")

    Repo.query!(
      "INSERT INTO runs (#{Enum.map_join(columns, ", ", &elem(&1, 0))}) VALUES (#{values})",
      Keyword.values(columns)
    )

    Ecto.UUID.load!(columns[:id])
  end

  defp exited!(scope, state, reason, columns \\ []),
    do: insert!(scope, state, [reason: reason, exited_at: @exited] ++ columns)

  defp outcome(state) do
    [
      outcome_state: state,
      outcome_time: @exited,
      outcome_received_at: @exited,
      outcome_digest: :crypto.hash(:sha256, state)
    ]
  end

  defp run(id), do: Repo.get!(Run, id)

  # A refused insert, in a savepoint, so the test's transaction goes on.
  defp refused?(scope, state) do
    assert_raise Postgrex.Error, ~r/runs_state_check/, fn ->
      Repo.transaction(fn -> insert!(scope, state) end)
    end
  end

  defp validated? do
    %{rows: [[validated]]} =
      Repo.query!(
        "SELECT convalidated FROM pg_constraint " <>
          "WHERE conrelid = 'runs'::regclass AND conname = 'runs_state_check'"
      )

    validated
  end

  test "every old name and old failed exit is stored as the state a rebuild folds" do
    %{scope: scope} = sign_up_fixture()
    before!()

    stored = %{
      exited!(scope, "succeeded", nil) => "completed",
      exited!(scope, "timed_out", "timeout") => "cancelled",
      exited!(scope, "ended", "quiet") => "cancelled",
      exited!(scope, "failed", "session_lost") => "lost",
      exited!(scope, "failed", "timeout") => "cancelled",
      exited!(scope, "failed", "quiet") => "cancelled",
      exited!(scope, "failed", "credential_expired") => "cancelled",
      exited!(scope, "failed", "run_ended_at_issuer") => "cancelled",
      # Left as they are: another reason, an outcome, a refusal, and the six states.
      exited!(scope, "failed", "issuer_unreachable") => "failed",
      exited!(scope, "failed", "stopped") => "failed",
      exited!(scope, "failed", "session_lost", outcome("failed")) => "failed",
      exited!(scope, "failed", "quiet", outcome("failed")) => "failed",
      insert!(scope, "failed", reason: "quiet", refused_at: @exited) => "failed",
      insert!(scope, "failed", reason: "gateway_lost") => "failed",
      insert!(scope, "pending") => "pending",
      insert!(scope, "running") => "running",
      exited!(scope, "completed", nil) => "completed",
      exited!(scope, "cancelled", "stopped") => "cancelled",
      insert!(scope, "lost", lost_at: @lost) => "lost"
    }

    lost = exited!(scope, "failed", "gateway_lost")
    lost_before = exited!(scope, "failed", "gateway_lost", lost_at: @lost)

    after!()

    for {id, state} <- stored do
      assert run(id).state == state
      assert run(id).updated_at == @written
    end

    assert %{state: "lost", lost_at: @exited, updated_at: @written} = run(lost)
    assert %{state: "lost", lost_at: @lost} = run(lost_before)

    for id <- Map.keys(stored), run(id).state != "lost", do: assert(run(id).lost_at == nil)
  end

  test "the rewrite goes through more rows than one batch holds" do
    %{scope: scope} = sign_up_fixture()
    before!()

    Repo.query!(
      "INSERT INTO runs (id, organisation_id, workspace_id, run_id, state, inserted_at, " <>
        "updated_at) SELECT gen_random_uuid(), $1, $2, gen_random_uuid(), 'succeeded', " <>
        "now(), now() FROM generate_series(1, 2001)",
      [Ecto.UUID.dump!(scope.organisation.id), Ecto.UUID.dump!(scope.workspace.id)]
    )

    up!(@store)

    assert %{rows: [[0, 2001]]} =
             Repo.query!(
               "SELECT count(*) FILTER (WHERE state = 'succeeded'), " <>
                 "count(*) FILTER (WHERE state = 'completed') FROM runs WHERE workspace_id = $1",
               [Ecto.UUID.dump!(scope.workspace.id)]
             )
  end

  test "after them the check allows the six states only, validated" do
    %{scope: scope} = sign_up_fixture()
    assert validated?()

    for state <- Run.states(), do: assert(run(insert!(scope, state)).state == state)
    for state <- ~w(succeeded timed_out ended closed Completed), do: refused?(scope, state)
  end

  test "the guard raises while a row holds an old name written after the rewrite" do
    %{scope: scope} = sign_up_fixture()
    before!()
    up!(@store)

    insert!(scope, "succeeded")
    insert!(scope, "ended")

    {version, migration, _name} = @allow

    assert_raise RuntimeError,
                 "runs holds 2 rows in a state an earlier build wrote (succeeded, timed_out " <>
                   "or ended): a build without migration 20261009233000 is still writing to " <>
                   "this database. Stop it, then start this release again.",
                 fn -> Ecto.Migrator.up(Repo, version, migration, @options) end

    # The check is the wide one still: an old name is stored.
    insert!(scope, "timed_out")
    assert validated?()
  end

  test "the validation fails on an old name written after the guard" do
    %{scope: scope} = sign_up_fixture()
    before!()
    up!(@store)
    up!(@allow)
    refute validated?()

    Repo.query!("ALTER TABLE runs DROP CONSTRAINT runs_state_check")
    insert!(scope, "succeeded")

    Repo.query!(
      "ALTER TABLE runs ADD CONSTRAINT runs_state_check CHECK (state IN ('pending', " <>
        "'running', 'completed', 'failed', 'cancelled', 'lost')) NOT VALID"
    )

    {version, migration, _name} = @validate

    error =
      assert_raise Postgrex.Error, fn ->
        Ecto.Migrator.up(Repo, version, migration, @options)
      end

    assert error.postgres.code == :check_violation
    refute validated?()
  end

  test "down allows the three old names again, every row kept; up narrows the check again" do
    %{scope: scope} = sign_up_fixture()
    completed = insert!(scope, "completed")
    cancelled = insert!(scope, "cancelled", reason: "timeout")

    before!()

    assert run(completed).state == "completed"
    assert run(cancelled).state == "cancelled"
    assert validated?()

    for state <- ~w(succeeded timed_out ended),
        do: assert(run(insert!(scope, state)).state == state)

    for state <- ~w(closed Completed), do: refused?(scope, state)

    after!()

    assert validated?()
    for state <- ~w(succeeded timed_out ended), do: refused?(scope, state)
  end
end
