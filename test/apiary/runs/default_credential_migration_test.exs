defmodule Apiary.Runs.DefaultCredentialMigrationTest do
  # The migration that renames a key row's `start` to `default_credential`, run down and
  # up again inside the test's transaction, which rolls it all back: the column and the
  # index that keeps one default credential per run, under each name, with a run's rows
  # kept. It changes the table under every other test, so this is not async.
  use Apiary.DataCase, async: false

  @moduletag :capture_log
  @moduletag needs: [:factory, :secrets]

  import Apiary.DispatchedRunsFixtures
  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, Repo}

  @version 20_261_119_161_000
  @migration Apiary.Repo.Migrations.RenameARunModelKeySStartToDefaultCredential
  @name "rename_a_run_model_key_s_start_to_default_credential"
  @options [log: false, migration_lock: false]

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_#{@name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  # The boolean columns of `run_model_keys`, and its partial indexes on `run_id` alone,
  # each with its definition.
  defp columns do
    %{rows: rows} =
      Repo.query!("""
      SELECT column_name FROM information_schema.columns
      WHERE table_name = 'run_model_keys' AND data_type = 'boolean'
      """)

    List.flatten(rows)
  end

  defp indexes do
    %{rows: rows} =
      Repo.query!("""
      SELECT indexname, indexdef FROM pg_indexes
      WHERE tablename = 'run_model_keys' AND indexdef LIKE '%WHERE%' AND indexdef LIKE '%(run_id)%'
      """)

    Map.new(rows, &List.to_tuple/1)
  end

  # The run's key rows by name, each with its flag, read in raw SQL under `column`.
  defp flags(run_id, column) do
    %{rows: rows} =
      Repo.query!(
        "SELECT name, #{column} FROM run_model_keys WHERE run_id = $1 ORDER BY position",
        [Ecto.UUID.dump!(run_id)]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  test "renames start to default_credential with its index, and back" do
    %{scope: scope} = sign_up_fixture()
    pool = Apiary.NodesFixtures.pool_fixture(scope)
    %{access_key: key} = Apiary.AccessKeysFixtures.enrolled_key_fixture(scope, pool)
    %{run: run} = handed_over_fixture(scope, key, %{run_settings: %{}})

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [
          %{value_id: "main", value: "sk-ant-rename-main-0123456789"},
          %{value_id: "spare", value: "sk-ant-rename-spare-0123456789"}
        ]
      })

    run_keys!(run, [
      %{provider: provider, secret_value_id: key_value!(provider, "main").id},
      %{provider: provider, secret_value_id: key_value!(provider, "spare").id}
    ])

    pid = provider.public_id
    named = [{"#{pid}-1", true}, {"#{pid}-2", false}]

    assert columns() == ["default_credential"]
    assert flags(run.id, "default_credential") == named

    assert %{"run_model_keys_default_credential_index" => definition} = indexes()
    assert definition =~ "WHERE default_credential"

    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, @options)
    assert columns() == ["start"]
    assert flags(run.id, "start") == named
    assert %{"run_model_keys_start_index" => definition} = indexes()
    assert definition =~ "WHERE start"

    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, @options)
    assert columns() == ["default_credential"]
    assert flags(run.id, "default_credential") == named
    assert Map.keys(indexes()) == ["run_model_keys_default_credential_index"]
  end
end
