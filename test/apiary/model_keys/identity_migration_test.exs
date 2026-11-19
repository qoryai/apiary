defmodule Apiary.ModelKeys.IdentityMigrationTest do
  # The migrations that add `secret_values.hint` and `model_key_logins.email`, run down and
  # up again inside the test's transaction, which rolls it all back: down drops the column
  # with what it holds, up adds it again, empty and nullable, and the rows stay. They change
  # the schema under every other test, so this is not async.
  use Apiary.DataCase, async: false

  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Connections

  @moduletag needs: [:factory, :secrets]
  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one.
  @moduletag :capture_log

  @hint {20_261_119_090_000, Apiary.Repo.Migrations.AddAHintToSecretValues,
         "add_a_hint_to_secret_values"}
  @email {20_261_119_090_100, Apiary.Repo.Migrations.AddAnEmailToModelKeyLogins,
          "add_an_email_to_model_key_logins"}
  @options [log: false, migration_lock: false]

  setup_all do
    for {version, migration, name} <- [@hint, @email] do
      unless Code.ensure_loaded?(migration) do
        Application.app_dir(:apiary, "priv/repo/migrations")
        |> Path.join("#{version}_#{name}.exs")
        |> Code.require_file()
      end
    end

    :ok
  end

  defp down!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.down(Repo, version, migration, @options))

  defp up!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.up(Repo, version, migration, @options))

  defp column(table, column) do
    %{rows: rows} =
      Repo.query!(
        "SELECT data_type, is_nullable FROM information_schema.columns " <>
          "WHERE table_name = $1 AND column_name = $2",
        [table, column]
      )

    rows
  end

  defp keys! do
    %{scope: scope} = sign_up_fixture()

    {:ok, api} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value: "sk-ant-fixture-key-0123456789-9c2e"}]
      })

    {:ok, login} =
      Connections.create_provider(scope, %{
        provider: "openai-subscription",
        keys: [%{value: device_login()}]
      })

    {api, login}
  end

  test "the hint column is nullable text, and down drops it with its hints" do
    assert column("secret_values", "hint") == [["character varying", "YES"]]
    {api, _login} = keys!()
    assert key_value!(api, "key-1").hint == "9c2e"

    down!(@hint)
    assert column("secret_values", "hint") == []
    assert Repo.aggregate(Apiary.Secrets.Value, :count) == 2

    up!(@hint)
    assert column("secret_values", "hint") == [["character varying", "YES"]]

    assert Repo.one!(
             from v in "secret_values",
               where: v.value_id == "key-1" and not is_nil(v.hint),
               select: count()
           ) == 0
  end

  test "the email column is nullable text, and down drops it with its emails" do
    assert column("model_key_logins", "email") == [["character varying", "YES"]]
    {_api, login} = keys!()
    assert [%{email: "dana@example.com"}] = Map.values(Apiary.ModelKeys.Login.by_key(login))

    down!(@email)
    assert column("model_key_logins", "email") == []
    assert Repo.aggregate("model_key_logins", :count) == 1

    up!(@email)
    assert column("model_key_logins", "email") == [["character varying", "YES"]]
    assert [%{email: nil}] = Map.values(Apiary.ModelKeys.Login.by_key(login))
  end
end
