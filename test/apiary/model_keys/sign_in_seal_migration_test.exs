defmodule Apiary.ModelKeys.SignInSealMigrationTest do
  # The migration that adds `model_key_copies.login_at`, run down and up again inside the
  # test's transaction, which rolls it all back: down takes the column away, up adds it
  # again, nullable, with no row changed. It changes the schema under every other test, so
  # this is not async.
  use Apiary.DataCase, async: false

  @moduletag needs: [:factory, :secrets]
  @moduletag :capture_log

  @migration {20_261_119_090_000, Apiary.Repo.Migrations.KeepTheSignInARunSealed,
              "keep_the_sign_in_a_run_sealed"}
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
        "SELECT data_type, is_nullable FROM information_schema.columns " <>
          "WHERE table_name = 'model_key_copies' AND column_name = 'login_at'"
      )

    rows
  end

  test "up adds a nullable login_at, and down takes it away" do
    assert column() == [["timestamp without time zone", "YES"]]

    assert :ok = Ecto.Migrator.down(Repo, elem(@migration, 0), elem(@migration, 1), @options)
    assert column() == []

    assert :ok = Ecto.Migrator.up(Repo, elem(@migration, 0), elem(@migration, 1), @options)
    assert column() == [["timestamp without time zone", "YES"]]
  end
end
