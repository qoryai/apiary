defmodule Apiary.Secrets.OrganisationScopeMigrationTest do
  # The migration that makes the stored secrets the organisation's
  # (`20261016090100_keep_stored_secrets_at_the_organisation`), run down and up again
  # inside the test's transaction, which rolls it all back. It changes the schema of three
  # tables under every other test, so this is not async.
  use Apiary.DataCase, async: false

  @moduletag needs: :secrets

  import Apiary.OrganisationsFixtures

  alias Apiary.Secrets

  @scope_change {20_261_016_090_100, Apiary.Repo.Migrations.KeepStoredSecretsAtTheOrganisation,
                 "keep_stored_secrets_at_the_organisation"}

  @options [log: false, migration_lock: false]

  setup_all do
    {version, migration, name} = @scope_change

    unless Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  defp down, do: run(:down)
  defp up, do: run(:up)

  defp run(direction) do
    {version, migration, _name} = @scope_change
    apply(Ecto.Migrator, direction, [Repo, version, migration, @options])
  end

  defp empty! do
    for table <- ~w(secret_values secrets organisation_data_keys),
        do: Repo.query!("DELETE FROM #{table}")
  end

  # What the three tables are: their columns, indexes and constraints, by name.
  defp shape(tables) do
    %{rows: columns} =
      Repo.query!(
        """
        SELECT table_name::text, column_name::text, data_type::text, is_nullable::text
        FROM information_schema.columns WHERE table_schema = 'public' AND table_name = ANY($1)
        ORDER BY 1, 2
        """,
        [tables]
      )

    %{rows: indexes} =
      Repo.query!(
        """
        SELECT tablename::text, indexname::text, indexdef FROM pg_indexes
        WHERE schemaname = 'public' AND tablename = ANY($1) ORDER BY 1, 2
        """,
        [tables]
      )

    %{rows: constraints} =
      Repo.query!(
        """
        SELECT conrelid::regclass::text, conname::text, pg_get_constraintdef(oid)
        FROM pg_constraint WHERE conrelid::regclass::text = ANY($1) ORDER BY 1, 2
        """,
        [tables]
      )

    %{columns: columns, indexes: indexes, constraints: constraints}
  end

  @now ~w(secret_values secrets organisation_data_keys)
  @before ~w(secret_values secrets workspace_data_keys)

  test "down puts the workspace back, and up takes it away again" do
    empty!()
    now = shape(@now)

    assert :ok = down()
    before = shape(@before)

    for table <- @before do
      assert [_workspace_id] =
               for([^table, "workspace_id", "uuid", "NO"] <- before.columns, do: table)
    end

    assert ["secrets", "secrets_name_index", definition] =
             Enum.find(before.indexes, &match?([_, "secrets_name_index", _], &1))

    assert definition =~ "(organisation_id, workspace_id, lower(name))"

    assert :ok = up()
    assert shape(@now) == now

    assert now.constraints
           |> Enum.map(&Enum.at(&1, 1))
           |> Enum.all?(&(&1 =~ ~r/\A(organisation_data_keys|secrets|secret_values)_/))

    # And the context works on it.
    %{scope: scope} = sign_up_fixture()
    assert {:ok, secret} = Secrets.create_secret(scope, %{name: "API_KEY", value: "a value"})

    assert Secrets.reveal_for_sealing(scope.organisation, secret.public_id, nil) ==
             {:ok, "a value"}
  end

  test "down refuses while a row is there, and changes nothing" do
    empty!()
    %{scope: scope} = sign_up_fixture()
    {:ok, _secret} = Secrets.create_secret(scope, %{name: "API_KEY", value: "a value"})
    now = shape(@now)

    error = assert_raise RuntimeError, fn -> down() end
    assert error.message =~ "secret_values"
    assert error.message =~ "organisation_data_keys"

    assert error.message ==
             "secret_values, secrets, organisation_data_keys hold rows: " <>
               "delete them before rolling this back"

    assert shape(@now) == now
  end

  test "the organisation's names and keys are unique, and a value's secret and key are of its organisation" do
    shape = shape(@now)

    definitions = Map.new(shape.indexes, fn [_table, name, definition] -> {name, definition} end)
    assert definitions["secrets_name_index"] =~ "UNIQUE INDEX"
    assert definitions["secrets_name_index"] =~ "(organisation_id, lower(name))"
    assert definitions["organisation_data_keys_organisation_id_index"] =~ "UNIQUE INDEX"
    assert definitions["organisation_data_keys_organisation_id_index"] =~ "(organisation_id)"
    assert definitions["secret_values_organisation_id_index"] =~ "(organisation_id)"

    constraints =
      Map.new(shape.constraints, fn [_table, name, definition] -> {name, definition} end)

    assert constraints["secret_values_secret_id_fkey"] ==
             "FOREIGN KEY (secret_id, organisation_id) REFERENCES secrets(id, organisation_id) MATCH FULL ON DELETE CASCADE"

    assert constraints["secret_values_data_key_id_fkey"] ==
             "FOREIGN KEY (data_key_id, organisation_id) REFERENCES organisation_data_keys(id, organisation_id) MATCH FULL"

    refute Enum.any?(shape.columns, &match?([_, "workspace_id", _, _], &1))
  end
end
