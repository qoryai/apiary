defmodule Apiary.Connections.ProviderMigrationTest do
  # The migrations of a model provider, run down and up again inside the test's
  # transaction, which rolls it all back, and the checks they add, each at its bound and
  # one past it. They change the tables under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log
  @moduletag needs: :factory

  import Apiary.OrganisationsFixtures

  alias Apiary.Connections
  alias Apiary.Connections.Connection

  @migrations [
    {20_261_019_070_000, Apiary.Repo.Migrations.KeepAProviderAsAnIntegrationConnection,
     "keep_a_provider_as_an_integration_connection"},
    {20_261_019_070_100, Apiary.Repo.Migrations.KeepAProviderSModels, "keep_a_provider_s_models"},
    {20_261_026_140_000, Apiary.Repo.Migrations.KeepNoModelListForAProvider,
     "keep_no_model_list_for_a_provider"}
  ]

  @options [log: false, migration_lock: false]

  setup_all do
    for {version, migration, name} <- @migrations, not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  defp down!,
    do:
      for(
        {version, migration, _name} <- Enum.reverse(@migrations),
        do: assert(:ok = Ecto.Migrator.down(Repo, version, migration, @options))
      )

  defp up!,
    do:
      for(
        {version, migration, _name} <- @migrations,
        do: assert(:ok = Ecto.Migrator.up(Repo, version, migration, @options))
      )

  defp columns(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = $1",
        [table]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  @provider_columns ~w(chain default_value_id description_ref provider_kind secret_id)

  test "down takes the provider's columns away, and up puts them back, with no model list" do
    %{scope: scope} = sign_up_fixture()
    {:ok, _runtime} = Connections.create_runtime(scope, %{runtime: "claude"})

    # A connection written since is coded under version 3: down refuses it.
    [{version, migration, _name} | _models] = @migrations

    error =
      assert_raise Postgrex.Error, fn ->
        Ecto.Migrator.down(Repo, version, migration, @options)
      end

    assert error.postgres.message =~ "One is."
    assert "chain" in columns("organisation_connections")

    Repo.delete_all(Connection)
    down!()
    assert columns("provider_models") == []
    assert Enum.all?(@provider_columns, &(&1 not in columns("organisation_connections")))

    up!()
    assert Enum.all?(@provider_columns, &(&1 in columns("organisation_connections")))
    assert columns("provider_models") == []

    assert {:ok, %Connection{provider_kind: "openrouter"} = provider} =
             Connections.create_provider(scope, %{
               provider: "openrouter",
               keys: [%{value_id: "main", value: "x"}]
             })

    assert [_ | _] = Connections.provider_models(provider)
  end

  test "the model list goes, and down puts it back empty" do
    {version, migration, _name} = List.last(@migrations)

    assert :ok = Ecto.Migrator.down(Repo, version, migration, @options)
    assert "effort" in columns("provider_models")
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM provider_models")

    assert :ok = Ecto.Migrator.up(Repo, version, migration, @options)
    assert columns("provider_models") == []

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM pg_proc WHERE proname = 'provider_effort_valid'")
  end

  describe "the checks" do
    setup do
      %{scope: scope} = sign_up_fixture()

      {:ok, provider} =
        Connections.create_provider(scope, %{
          provider: "openrouter",
          keys: [%{value_id: "main", value: "x"}]
        })

      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
      %{provider: provider, runtime: runtime}
    end

    # `sql` run in a savepoint: :ok, or the name of the check it broke.
    defp run(sql, params) do
      Repo.transaction(fn -> Repo.query!(sql, params) end)
      :ok
    rescue
      error in Postgrex.Error -> error.postgres[:constraint] || error.postgres.code
    end

    defp set(%Connection{id: id}, column, value),
      do:
        run(
          "UPDATE organisation_connections SET #{column} = $1 WHERE id = $2",
          [value, Ecto.UUID.dump!(id)]
        )

    test "a provider's columns, at their bounds", %{provider: provider, runtime: runtime} do
      kind = "a" <> String.duplicate("b", 63)
      assert set(provider, "provider_kind", kind) == :ok

      assert set(provider, "provider_kind", kind <> "c") ==
               "organisation_connections_provider_kind_format"

      assert set(provider, "provider_kind", "1a") ==
               "organisation_connections_provider_kind_format"

      assert set(provider, "description_ref", String.duplicate("f", 40)) == :ok

      assert set(provider, "description_ref", String.duplicate("f", 41)) ==
               "organisation_connections_description_ref_format"

      assert set(provider, "description_ref", String.duplicate("F", 40)) ==
               "organisation_connections_description_ref_format"

      value_id = "a" <> String.duplicate("b", 63)
      assert set(provider, "default_value_id", value_id) == :ok

      assert set(provider, "default_value_id", value_id <> "c") ==
               "organisation_connections_default_value_id_format"

      assert set(provider, "chain", "operator") == :ok
      assert set(provider, "chain", "client") == "organisation_connections_chain_check"

      # The provider's columns only on a provider, a default key only with its secret.
      assert set(runtime, "chain", "operator") == "organisation_connections_provider_check"

      assert set(runtime, "description_ref", String.duplicate("f", 40)) ==
               "organisation_connections_provider_check"

      assert set(runtime, "provider_kind", "openrouter") ==
               "organisation_connections_shape_check"

      assert set(provider, "secret_id", nil) == "organisation_connections_provider_check"
      assert set(provider, "release_id", Ecto.UUID.dump!(Ecto.UUID.generate())) != :ok
      assert set(provider, "argument", "x") == "organisation_connections_shape_check"
      assert set(provider, "description_ref", nil) == "organisation_connections_shape_check"
    end

    test "the provider's keys are not deleted while it links them", %{provider: provider} do
      assert run("DELETE FROM secrets WHERE id = $1", [Ecto.UUID.dump!(provider.secret_id)]) ==
               "organisation_connections_secret_id_fkey"
    end
  end
end
