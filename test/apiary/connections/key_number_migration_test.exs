defmodule Apiary.Connections.KeyNumberMigrationTest do
  # The migration that adds `secrets.last_key_number`, run down and up again inside the
  # test's transaction, which rolls it all back: down drops the column, up adds it again
  # and sets each secret to the highest `key-<n>` its values have, 0 for none. It changes
  # the schema under every other test, so this is not async.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, Secrets}
  alias Apiary.Secrets.Secret

  @moduletag needs: [:factory, :secrets]
  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one.
  @moduletag :capture_log

  @migration {20_261_120_090_000, Apiary.Repo.Migrations.KeepTheLastKeyNumberOfASecret,
              "keep_the_last_key_number_of_a_secret"}
  @options [log: false, migration_lock: false]

  setup_all do
    {version, migration, name} = @migration

    unless Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  defp column do
    %{rows: rows} =
      Repo.query!(
        "SELECT data_type, is_nullable, column_default FROM information_schema.columns " <>
          "WHERE table_name = 'secrets' AND column_name = 'last_key_number'"
      )

    rows
  end

  defp counter(%{secret_id: id}),
    do: Repo.one!(from s in Secret, where: s.id == ^id, select: s.last_key_number)

  test "up sets each secret to its highest key number, down drops the column" do
    %{scope: scope} = sign_up_fixture()

    {:ok, keys} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [
          %{value_id: "key-2", value: "sk-ant-migration-a-0123456789"},
          %{value_id: "key-11", value: "sk-ant-migration-b-0123456789"},
          %{value_id: "main", value: "sk-ant-migration-c-0123456789"}
        ]
      })

    {:ok, other} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: "sk-ant-migration-d-0123456789"}]
      })

    assert column() == [["integer", "NO", "0"]]
    assert counter(keys) == 11
    assert counter(other) == 0

    {version, migration, _name} = @migration
    assert :ok = Ecto.Migrator.down(Repo, version, migration, @options)
    assert column() == []

    assert :ok = Ecto.Migrator.up(Repo, version, migration, @options)
    assert column() == [["integer", "NO", "0"]]
    assert counter(keys) == 11
    assert counter(other) == 0

    assert Secrets.next_key_id(Repo.preload(Repo.get!(Secret, keys.secret_id), :values)) ==
             "key-12"
  end
end
