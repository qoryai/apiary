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
    {20_261_019_070_100, Apiary.Repo.Migrations.KeepAProviderSModels, "keep_a_provider_s_models"}
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

  test "down takes the provider's columns and models away, and up puts them back" do
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
    assert "effort" in columns("provider_models")

    assert {:ok, %Connection{provider_kind: "openrouter", models: [_ | _]}} =
             Connections.create_provider(scope, %{
               provider: "openrouter",
               keys: [%{value_id: "main", value: "x"}]
             })
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

    defp model(%Connection{} = provider, attrs) do
      attrs =
        Map.merge(
          %{model_id: "m", title: "M", effort: nil, position: 99, is_default: false},
          attrs
        )

      run(
        """
        INSERT INTO provider_models
          (id, organisation_id, connection_id, model_id, title, effort, position, is_default,
           inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now(), now())
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          Ecto.UUID.dump!(provider.organisation_id),
          Ecto.UUID.dump!(provider.id),
          attrs.model_id,
          attrs.title,
          attrs.effort,
          attrs.position,
          attrs.is_default
        ]
      )
    end

    test "a model, at its bounds", %{provider: provider} do
      id = "a" <> String.duplicate("~", 199)
      assert model(provider, %{model_id: id}) == :ok
      assert model(provider, %{model_id: id <> "~"}) == "provider_models_model_id_format"
      assert model(provider, %{model_id: "a b"}) == "provider_models_model_id_format"
      assert model(provider, %{model_id: "-a"}) == "provider_models_model_id_format"
      assert model(provider, %{model_id: id}) == "provider_models_connection_id_model_id_index"

      assert model(provider, %{model_id: "t1", title: String.duplicate("é", 128)}) == :ok

      assert model(provider, %{model_id: "t2", title: String.duplicate("é", 129)}) ==
               "provider_models_title_length"

      assert model(provider, %{model_id: "t3", title: ""}) == "provider_models_title_length"

      sixteen = Enum.map(1..16, &"e#{&1}")
      assert model(provider, %{model_id: "e1", effort: sixteen}) == :ok

      assert model(provider, %{model_id: "e2", effort: sixteen ++ ["e17"]}) ==
               "provider_models_effort_check"

      assert model(provider, %{model_id: "e3", effort: []}) == "provider_models_effort_check"

      assert model(provider, %{model_id: "e4", effort: ["a", "a"]}) ==
               "provider_models_effort_check"

      assert model(provider, %{model_id: "e5", effort: ["A"]}) == "provider_models_effort_check"

      assert model(provider, %{model_id: "e6", effort: ["a", nil]}) ==
               "provider_models_effort_check"

      assert model(provider, %{model_id: "e7", effort: ["a" <> String.duplicate("b", 31)]}) ==
               :ok

      assert model(provider, %{model_id: "e8", effort: ["a" <> String.duplicate("b", 32)]}) ==
               "provider_models_effort_check"

      assert model(provider, %{model_id: "p1", position: 0}) == :ok
      assert model(provider, %{model_id: "p2", position: -1}) == "provider_models_position_check"

      # The provider has its default model: a second is refused.
      assert model(provider, %{model_id: "d1", is_default: true}) ==
               "provider_models_default_index"
    end
  end
end
