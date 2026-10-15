defmodule Apiary.Secrets.OrganisationLevelMigrationTest do
  # The two migrations that let a stored secret belong to an organisation and validate
  # their checks (`20261016085000`, `20261016085100`), run down and up again inside the
  # test's transaction, which rolls it all back. They change the schema of the secrets'
  # tables under every other test, so this is not async.
  use Apiary.DataCase, async: false

  @moduletag needs: :secrets

  import Apiary.OrganisationsFixtures

  alias Apiary.{Edition, EditionStubs, Secrets}

  @level {20_261_016_085_000, Apiary.Repo.Migrations.LetAStoredSecretBelongToAnOrganisation,
          "let_a_stored_secret_belong_to_an_organisation"}
  @validate {20_261_016_085_100, Apiary.Repo.Migrations.ValidateAStoredSecretSLevelChecks,
             "validate_a_stored_secret_s_level_checks"}

  @options [log: false, migration_lock: false]

  @tables ~w(secret_values secrets workspace_data_keys organisation_data_keys)

  setup_all do
    for {version, migration, name} <- [@level, @validate], not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  defp down!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.down(Repo, version, migration, @options))

  defp up!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.up(Repo, version, migration, @options))

  defp down_all! do
    down!(@validate)
    down!(@level)
  end

  defp up_all! do
    up!(@level)
    up!(@validate)
  end

  # What the tables are: their columns, indexes, constraints and triggers, by name.
  defp shape do
    %{rows: columns} =
      Repo.query!(
        """
        SELECT table_name::text, column_name::text, data_type::text, is_nullable::text
        FROM information_schema.columns WHERE table_schema = 'public' AND table_name = ANY($1)
        ORDER BY 1, 2
        """,
        [@tables]
      )

    %{rows: indexes} =
      Repo.query!(
        """
        SELECT tablename::text, indexname::text, indexdef FROM pg_indexes
        WHERE schemaname = 'public' AND tablename = ANY($1) ORDER BY 1, 2
        """,
        [@tables]
      )

    %{rows: constraints} =
      Repo.query!(
        """
        SELECT conrelid::regclass::text, conname::text, pg_get_constraintdef(oid), convalidated
        FROM pg_constraint WHERE conrelid::regclass::text = ANY($1) ORDER BY 1, 2
        """,
        [@tables]
      )

    %{rows: triggers} =
      Repo.query!(
        """
        SELECT tgrelid::regclass::text, tgname::text, pg_get_triggerdef(oid) FROM pg_trigger
        WHERE NOT tgisinternal AND tgrelid::regclass::text = ANY($1) ORDER BY 1, 2
        """,
        [@tables]
      )

    %{columns: columns, indexes: indexes, constraints: constraints, triggers: triggers}
  end

  defp constraint(shape, name) do
    Enum.find_value(shape.constraints, fn
      [_table, ^name, definition, _valid] -> definition
      _other -> nil
    end)
  end

  defp nullable?(shape, table, column),
    do: [table, column] in for([t, c, _type, "YES"] <- shape.columns, do: [t, c])

  # A secret's value and its data key, as the database holds them, read in SQL that both
  # shapes of the tables answer.
  defp stored(secret) do
    %{rows: [row]} =
      Repo.query!(
        """
        SELECT v.id, v.workspace_id, v.nonce, v.ciphertext, k.id, k.wrapped_key, k.wrapping_key_id
        FROM secret_values v JOIN workspace_data_keys k ON k.id = v.data_key_id
        WHERE v.secret_id = $1
        """,
        [Ecto.UUID.dump!(secret.id)]
      )

    row
  end

  test "down puts the tables back as they were, and up adds the organisation's level again" do
    now = shape()
    assert Enum.all?(now.constraints, fn [_, _, _, valid] -> valid end)

    down_all!()
    before = shape()

    refute nullable?(before, "secrets", "workspace_id")
    refute nullable?(before, "secret_values", "workspace_id")
    refute nullable?(before, "secret_values", "data_key_id")
    refute Enum.any?(before.columns, &match?(["organisation_data_keys" | _], &1))
    refute Enum.any?(before.columns, &match?([_, "organisation_data_key_id" | _], &1))
    assert before.triggers == []

    assert constraint(before, "secrets_workspace_id_fkey") ==
             "FOREIGN KEY (workspace_id, organisation_id) REFERENCES workspaces(id, organisation_id) MATCH FULL ON DELETE CASCADE"

    assert constraint(before, "secret_values_secret_id_fkey") ==
             "FOREIGN KEY (secret_id, workspace_id) REFERENCES secrets(id, workspace_id) MATCH FULL ON DELETE CASCADE"

    assert constraint(before, "secret_values_workspace_id_fkey") ==
             "FOREIGN KEY (workspace_id, organisation_id) REFERENCES workspaces(id, organisation_id) MATCH FULL ON DELETE CASCADE"

    up_all!()
    assert shape() == now

    assert nullable?(now, "secrets", "workspace_id")
    assert nullable?(now, "secret_values", "workspace_id")
    assert nullable?(now, "secret_values", "data_key_id")

    assert constraint(now, "secret_values_secret_organisation_fkey") ==
             "FOREIGN KEY (secret_id, organisation_id) REFERENCES secrets(id, organisation_id) MATCH FULL ON DELETE CASCADE"

    assert constraint(now, "secret_values_data_key_id_fkey") ==
             "FOREIGN KEY (data_key_id, workspace_id) REFERENCES workspace_data_keys(id, workspace_id) MATCH FULL"

    definitions = Map.new(now.indexes, fn [_table, name, definition] -> {name, definition} end)
    assert definitions["secrets_name_index"] =~ "(organisation_id, workspace_id, lower(name))"
    assert definitions["secrets_organisation_name_index"] =~ "UNIQUE INDEX"

    assert definitions["secrets_organisation_name_index"] =~
             "(organisation_id, lower(name)) WHERE (workspace_id IS NULL)"

    assert definitions["organisation_data_keys_organisation_id_index"] =~ "UNIQUE INDEX"
  end

  test "up leaves a workspace's secrets as they were, byte for byte, and still decrypting" do
    %{scope: scope} = sign_up_fixture()
    {:ok, secret} = Secrets.create_secret(scope, %{name: "API_KEY", value: "a value"})
    as_stored = stored(secret)

    down_all!()
    assert stored(secret) == as_stored
    up_all!()

    assert stored(secret) == as_stored

    assert Secrets.reveal_for_sealing(scope.workspace, secret.public_id, nil) ==
             {:ok, "a value"}

    assert {:ok, _} = Secrets.set_value(scope, secret, nil, "another value")

    assert Secrets.reveal_for_sealing(scope.workspace, secret.public_id, nil) ==
             {:ok, "another value"}
  end

  test "down refuses while an organisation's secret is there, and changes nothing" do
    Edition.put_test_stub(EditionStubs.GrantsOrganisationSecrets)
    %{scope: scope, organisation: organisation} = sign_up_fixture()

    {:ok, secret} =
      Secrets.create_organisation_secret(scope, %{name: "API_KEY", value: "a value"})

    now = shape()
    down!(@validate)

    error = assert_raise Postgrex.Error, fn -> down!(@level) end
    assert error.postgres.message =~ "secrets holds secrets of organisations"

    up!(@validate)
    assert shape() == now
    assert Secrets.reveal_for_sealing(organisation, secret.public_id, nil) == {:ok, "a value"}
  end

  test "down refuses while an organisation's data key is there, its secrets gone" do
    Edition.put_test_stub(EditionStubs.GrantsOrganisationSecrets)
    %{scope: scope} = sign_up_fixture()

    {:ok, secret} =
      Secrets.create_organisation_secret(scope, %{name: "API_KEY", value: "a value"})

    {:ok, _} = Secrets.delete_secret(scope, secret)
    down!(@validate)

    error = assert_raise Postgrex.Error, fn -> down!(@level) end
    assert error.postgres.message =~ "organisation_data_keys"

    up!(@validate)
  end
end
