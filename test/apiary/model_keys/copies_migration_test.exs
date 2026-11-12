defmodule Apiary.ModelKeys.CopiesMigrationTest do
  # The migrations that keep which value of each model key a run has, run down and up
  # again inside the test's transaction, which rolls it all back. The first fills
  # `secret_values.value_set_at` from `updated_at` and sets its default to the time in
  # UTC, whatever the session's time zone; down takes the column and `model_key_copies`
  # away. The second writes a copy for each key of a live run that has none. They change
  # `secret_values` and `model_key_copies` under every other test, so this is not async.
  # The rows are read in raw SQL, as the schema has the column the migration takes away.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, ModelKeys}
  alias Apiary.ModelKeys.{Copy, State}
  alias Apiary.Runs.Run
  alias Apiary.Secrets.Value

  @moduletag needs: [:factory, :secrets]

  @migration {20_261_111_190_000, Apiary.Repo.Migrations.KeepTheKeyValueARunWasSealed,
              "keep_the_key_value_a_run_was_sealed"}

  @live_copies {20_261_111_220_000, Apiary.Repo.Migrations.KeepTheKeyValuesOfLiveRuns,
                "keep_the_key_values_of_live_runs"}

  setup_all do
    for {version, migration, name} <- [@migration, @live_copies],
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

  defp column_default do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_default FROM information_schema.columns " <>
          "WHERE table_name = 'secret_values' AND column_name = 'value_set_at'"
      )

    rows
  end

  defp copies_table do
    %{rows: [[table]]} = Repo.query!("SELECT to_regclass('model_key_copies')::text")
    table
  end

  test "up fills value_set_at from updated_at with a UTC default; down takes both away" do
    %{scope: scope} = sign_up_fixture()

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: "sk-ant-fixture-main-0123456789"}]
      })

    updated_at = ~U[2026-11-01 08:00:00.000000Z]

    {1, _rows} =
      Repo.update_all(from(v in Value, where: v.secret_id == ^provider.secret_id),
        set: [updated_at: updated_at, value_set_at: ~U[2026-11-10 08:00:00.000000Z]]
      )

    down!(@migration)
    assert column_default() == []
    assert copies_table() == nil

    up!(@migration)
    assert copies_table() == "model_key_copies"

    %{rows: [[value_set_at]]} =
      Repo.query!("SELECT value_set_at FROM secret_values WHERE secret_id = $1", [
        Ecto.UUID.dump!(provider.secret_id)
      ])

    assert value_set_at == DateTime.to_naive(updated_at)

    # The column has no time zone, so a default is cast to it as an insert casts it: the
    # session's local time would be hours off in a session outside UTC.
    Repo.query!("SET LOCAL TIME ZONE 'America/New_York'")
    assert [[default]] = column_default()
    %{rows: [[now]]} = Repo.query!("SELECT (#{default})::timestamp without time zone")
    assert abs(NaiveDateTime.diff(now, NaiveDateTime.utc_now())) < 60
  end

  # A run of the scope's queue, handed over to a gateway, in `state`, with the key `value`
  # of `provider` and no copy of it.
  defp keys_run(scope, provider, %Value{id: id}, state) do
    pool = Apiary.NodesFixtures.pool_fixture(scope)
    %{access_key: key} = Apiary.AccessKeysFixtures.enrolled_key_fixture(scope, pool)

    %{run: run} =
      Apiary.DispatchedRunsFixtures.handed_over_fixture(scope, key, %{
        provider_connection_id: provider.id,
        provider_secret_id: provider.secret_id,
        provider_chain: "organisation",
        provider_api: %{
          "format" => "anthropic-messages",
          "endpoint" => "https://api.model.example/anthropic",
          "auth" => %{"scheme" => "x-api-key"}
        },
        model_keys: [%{"id" => id, "name" => "model-1", "pause_for_s" => 60}],
        run_settings: %{}
      })

    {1, _rows} = Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [state: state])
    %{run | state: state}
  end

  # Records a report of the run's key, and returns the states of `value`.
  defp report(run, %Value{id: id}) do
    item = %{
      credential: "model-1",
      window: "five_hour",
      status: "allowed",
      resets_at: nil,
      utilization: nil,
      cooldown_until: nil,
      source: "provider",
      observed_at: ~U[2026-11-10 12:00:00.000000Z]
    }

    :ok = ModelKeys.record(ModelKeys.run_keys(run), [item], DateTime.utc_now())
    Repo.all(from s in State, where: s.secret_value_id == ^id, select: s.status)
  end

  test "a live run written before its key's value_set_at gets a copy and keeps its reports" do
    %{scope: scope} = sign_up_fixture()

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [
          %{value_id: "main", value: "sk-ant-fixture-main-0123456789"},
          %{value_id: "spare", value: "sk-ant-fixture-spare-0123456789"}
        ]
      })

    values = Repo.all(from v in Value, where: v.secret_id == ^provider.secret_id)
    %{"main" => main, "spare" => spare} = Map.new(values, &{&1.value_id, &1})

    running = keys_run(scope, provider, main, "running")
    pending = keys_run(scope, provider, main, "pending")
    ended = keys_run(scope, provider, main, "completed")
    sealed = keys_run(scope, provider, spare, "pending")
    # A key that has no value row, such as a deleted key, gets no copy.
    gone =
      keys_run(scope, provider, %Value{id: "00000000-0000-0000-0000-000000000000"}, "running")

    # The upgrade's fill from `updated_at`, which a rename after the runs were written
    # moved: each key reads as set since the runs.
    later = DateTime.add(DateTime.utc_now(), 3_600, :second)

    {2, _rows} =
      Repo.update_all(from(v in Value, where: v.secret_id == ^provider.secret_id),
        set: [value_set_at: later]
      )

    # A copy a secrets request kept stays as it is.
    sealed_at = ~U[2026-11-01 08:00:00.000000Z]
    :ok = ModelKeys.keep_copies(sealed.id, [{spare.id, sealed_at}])

    assert report(running, main) == []

    down!(@live_copies)
    up!(@live_copies)
    assert report(running, main) == ["allowed"]

    copies =
      Repo.all(
        from c in Copy,
          where: c.secret_value_id in ^[main.id, spare.id],
          select: {c.run_id, c.secret_value_id, c.value_set_at}
      )

    assert Enum.sort(copies) ==
             Enum.sort([
               {running.id, main.id, later},
               {pending.id, main.id, later},
               {sealed.id, spare.id, sealed_at}
             ])

    refute Enum.any?(copies, fn {run_id, _id, _at} -> run_id == ended.id end)
    assert Repo.aggregate(from(c in Copy, where: c.run_id == ^gone.id), :count) == 0

    # Run again, it writes no second row.
    down!(@live_copies)
    up!(@live_copies)
    assert Repo.aggregate(from(c in Copy, where: c.run_id == ^running.id), :count) == 1
  end
end
