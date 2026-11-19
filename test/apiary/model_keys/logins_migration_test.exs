defmodule Apiary.ModelKeys.LoginsMigrationTest do
  # The migration that creates `model_key_logins`, run down and up again inside the test's
  # transaction, which rolls it all back: down drops the table and its rows, up creates
  # it again with its checks and its cascade from the key's value. It changes the schema
  # under every other test, so this is not async.
  use Apiary.DataCase, async: false

  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, ModelKeys}
  alias Apiary.ModelKeys.Login
  alias Apiary.Secrets.Value

  @moduletag needs: [:factory, :secrets]

  @migration {20_261_118_140_000, Apiary.Repo.Migrations.CreateModelKeyLogins,
              "create_model_key_logins"}

  setup_all do
    {version, migration, name} = @migration

    unless Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!,
    do: assert(:ok = Ecto.Migrator.down(Repo, elem(@migration, 0), elem(@migration, 1), @options))

  defp up!,
    do: assert(:ok = Ecto.Migrator.up(Repo, elem(@migration, 0), elem(@migration, 1), @options))

  defp table do
    %{rows: [[table]]} = Repo.query!("SELECT to_regclass('model_key_logins')::text")
    table
  end

  defp constraints do
    %{rows: rows} =
      Repo.query!(
        "SELECT conname FROM pg_constraint WHERE conrelid = 'model_key_logins'::regclass " <>
          "AND contype = 'c' ORDER BY conname"
      )

    List.flatten(rows)
  end

  test "down drops the table with its rows and up creates it again, empty" do
    %{scope: scope} = sign_up_fixture()

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "openai-subscription",
        keys: [%{value_id: "main", value: device_login()}]
      })

    value = key_value!(provider, "main")
    assert %Login{} = ModelKeys.Login.by_key(provider)[value.id]

    down!()
    assert table() == nil

    up!()
    assert table() == "model_key_logins"
    assert Repo.all(Login) == []

    assert constraints() == [
             "model_key_logins_account_id_check",
             "model_key_logins_failures_check",
             "model_key_logins_generation_check",
             "model_key_logins_lease_check",
             "model_key_logins_state_check"
           ]
  end

  test "the table holds one row per key and refuses a state without its cause" do
    %{scope: scope} = sign_up_fixture()

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "openai-subscription",
        keys: [%{value_id: "main", value: device_login()}]
      })

    %Value{id: id} = key_value!(provider, "main")

    for set <- [
          [state: "sign_in_needed"],
          [state: "signed_in", sign_in_cause: "refresh_unauthorized"],
          [state: "sign_in_needed", sign_in_cause: "unauthorized"],
          [state: "sign_in_needed", sign_in_cause: "Refresh_Token_Expired"],
          [state: "sign_in_needed", sign_in_cause: ""],
          [state: "sleeping"],
          [failures: -1],
          [generation: 0],
          [account_id: ""],
          [lease_id: Ecto.UUID.generate()]
        ] do
      refused =
        try do
          Repo.transaction(fn ->
            Repo.update_all(from(l in Login, where: l.secret_value_id == ^id), set: set)
          end)

          false
        rescue
          error in Postgrex.Error ->
            error.postgres.constraint =~ ~r/\Amodel_key_logins_\w+_check\z/
        end

      assert refused, "the table took #{inspect(set)}"
    end
  end

  test "the check accepts each cause the module lists, and no other" do
    %{scope: scope} = sign_up_fixture()

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "openai-subscription",
        keys: [%{value_id: "main", value: device_login()}]
      })

    %Value{id: id} = key_value!(provider, "main")

    assert Login.causes() ==
             ~w(refresh_token_expired refresh_token_reused refresh_token_invalidated
                invalid_grant refresh_unauthorized token_not_stored)

    for cause <- Login.causes() do
      assert {1, _} =
               Repo.update_all(from(l in Login, where: l.secret_value_id == ^id),
                 set: [state: "sign_in_needed", sign_in_cause: cause]
               )
    end
  end

  test "a row goes with the key's value" do
    %{scope: scope} = sign_up_fixture()

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "openai-subscription",
        keys: [
          %{value_id: "main", value: device_login()},
          %{value_id: "spare", value: device_login(tag: "b")}
        ]
      })

    assert map_size(Login.by_key(provider)) == 2

    {:ok, _provider} = Connections.delete_provider_key(scope, provider, "spare")

    assert [%Login{}] = Repo.all(Login)
  end
end
