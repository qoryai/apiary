defmodule Apiary.ModelKeys.CopiesMigrationTest do
  # The migration that keeps which value of each model key a run has, run down and up
  # again inside the test's transaction, which rolls it all back: up fills
  # `secret_values.value_set_at` from `updated_at` and sets its default to the time in
  # UTC, whatever the session's time zone; down takes the column and `model_key_copies`
  # away. It changes `secret_values` under every other test, so this is not async. The
  # rows are read in raw SQL, as the schema has the column the migration takes away.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.Connections
  alias Apiary.Secrets.Value

  @moduletag needs: [:factory, :secrets]

  @migration {20_261_111_190_000, Apiary.Repo.Migrations.KeepTheKeyValueARunWasSealed,
              "keep_the_key_value_a_run_was_sealed"}

  setup_all do
    {version, migration, name} = @migration

    if not Code.ensure_loaded?(migration) do
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
end
