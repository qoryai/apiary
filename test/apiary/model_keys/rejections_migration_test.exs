defmodule Apiary.ModelKeys.RejectionsMigrationTest do
  # The migration that creates `model_key_rejections`, run down and up again inside the
  # test's transaction, which rolls it all back: down drops the table with its rows, up
  # creates it again, empty, with its cascade from the key's value and its organisation. It
  # changes the schema under every other test, so this is not async.
  use Apiary.DataCase, async: false

  import Apiary.ModelKeysFixtures, only: [run_key!: 2]
  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, ModelKeys}
  alias Apiary.ModelKeys.Rejection
  alias Apiary.Secrets.Value

  @moduletag needs: [:factory, :secrets]
  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one.
  @moduletag :capture_log

  @migration {20_261_118_160_200, Apiary.Repo.Migrations.CreateModelKeyRejections,
              "create_model_key_rejections"}
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

  defp down!,
    do: assert(:ok = Ecto.Migrator.down(Repo, elem(@migration, 0), elem(@migration, 1), @options))

  defp up!,
    do: assert(:ok = Ecto.Migrator.up(Repo, elem(@migration, 0), elem(@migration, 1), @options))

  defp table do
    %{rows: [[table]]} = Repo.query!("SELECT to_regclass('model_key_rejections')::text")
    table
  end

  defp key! do
    %{scope: scope} = sign_up_fixture()

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: "sk-ant-fixture-main-0123456789"}]
      })

    value = Repo.one!(from v in Value, where: v.secret_id == ^provider.secret_id)

    key = run_key!(scope, value)

    {provider, value, key}
  end

  test "down drops the table with its rows and up creates it again, empty" do
    {provider, _value, key} = key!()

    :ok =
      ModelKeys.reject(
        [key],
        [%{credential: "model-1", at: DateTime.utc_now()}],
        provider,
        DateTime.utc_now()
      )

    assert [%Rejection{}] = Repo.all(Rejection)

    down!()
    assert table() == nil

    up!()
    assert table() == "model_key_rejections"
    assert Repo.all(Rejection) == []
  end

  test "the table has one row per key, goes with the value and refuses another organisation" do
    {provider, value, key} = key!()
    now = DateTime.utc_now()
    :ok = ModelKeys.reject([key], [%{credential: "model-1", at: now}], provider, now)
    assert [%Rejection{secret_value_id: id}] = Repo.all(Rejection)
    assert id == value.id

    # One row per key.
    assert_raise Postgrex.Error, ~r/model_key_rejections_pkey/, fn ->
      Repo.insert_all(Rejection, [
        %{
          secret_value_id: value.id,
          organisation_id: value.organisation_id,
          rejected_at: now,
          updated_at: now
        }
      ])
    end

    # The organisation is the value's.
    %{organisation: other} = sign_up_fixture()
    Repo.delete_all(Rejection)

    assert_raise Postgrex.Error, ~r/model_key_rejections_secret_value_id_fkey/, fn ->
      Repo.insert_all(Rejection, [
        %{
          secret_value_id: value.id,
          organisation_id: other.id,
          rejected_at: now,
          updated_at: now
        }
      ])
    end

    # The row goes with the value.
    :ok = ModelKeys.reject([key], [%{credential: "model-1", at: now}], provider, now)
    Repo.delete_all(from v in Value, where: v.id == ^value.id)
    assert Repo.all(Rejection) == []
  end
end
