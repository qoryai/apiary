defmodule Apiary.ModelChoices.MigrationTest do
  # The migrations of the model choice and its fallbacks, run down and up again inside the test's
  # transaction, which rolls it all back, and the checks it adds, each at its bound and
  # one past it. It changes the table under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log
  @moduletag needs: :factory

  import Apiary.ConnectionsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Connections
  alias Apiary.ModelChoices.{Fallback, ModelChoice}

  @migrations [
    {20_261_019_070_200, Apiary.Repo.Migrations.KeepTheModelChoiceAtEachLevel,
     "keep_the_model_choice_at_each_level"},
    {20_261_022_171_500, Apiary.Repo.Migrations.KeyAModelChoiceByWorkflow,
     "key_a_model_choice_by_workflow"},
    {20_261_110_153_000, Apiary.Repo.Migrations.KeepTheFallbacksOfAModelChoice,
     "keep_the_fallbacks_of_a_model_choice"},
    {20_261_118_120_000, Apiary.Repo.Migrations.NameTheModelTierBalanced,
     "name_the_model_tier_balanced"},
    {20_261_118_163_000, Apiary.Repo.Migrations.ChooseAProviderAndARuntimePerFallback,
     "choose_a_provider_and_a_runtime_per_fallback"}
  ]

  @balanced 20_261_118_120_000
  @per_fallback 20_261_118_163_000

  @options [log: false, migration_lock: false]

  setup_all do
    for {version, migration, name} <- @migrations, not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  defp tables do
    %{rows: rows} =
      Repo.query!(
        "SELECT table_name FROM information_schema.tables WHERE table_name = ANY($1)",
        [["model_choices", "model_choice_fallbacks"]]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  # The migration of `version` in `@migrations`.
  defp migration(version) do
    {^version, migration, _name} = List.keyfind(@migrations, version, 0)
    migration
  end

  # The columns of `table`, each with whether it takes NULL.
  defp columns(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name, is_nullable = 'YES' FROM information_schema.columns WHERE table_name = $1",
        [table]
      )

    Map.new(rows, fn [name, nullable] -> {name, nullable} end)
  end

  defp function? do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM pg_proc WHERE proname = 'model_choice_tiers_valid'")

    count == 1
  end

  test "down takes the tables and the tier check away, and up puts them back" do
    assert tables() == ["model_choice_fallbacks", "model_choices"]
    assert function?()

    for {version, migration, _name} <- Enum.reverse(@migrations),
        do: assert(:ok = Ecto.Migrator.down(Repo, version, migration, @options))

    assert tables() == []
    refute function?()

    for {version, migration, _name} <- @migrations,
        do: assert(:ok = Ecto.Migrator.up(Repo, version, migration, @options))

    assert tables() == ["model_choice_fallbacks", "model_choices"]
    assert function?()
  end

  describe "the checks" do
    setup do
      %{scope: scope} = sign_up_fixture()
      workspace = scope.workspace

      {:ok, provider} =
        Connections.create_provider(scope, %{
          provider: "openrouter",
          keys: [%{value_id: "main", value: "x"}]
        })

      %{
        scope: scope,
        organisation_id: scope.organisation.id,
        workspace_id: workspace.id,
        target: target!(scope, "acme/shop"),
        provider: provider
      }
    end

    defp base(ctx),
      do: %{
        organisation_id: ctx.organisation_id,
        workspace_id: ctx.workspace_id,
        connection_id: ctx.provider.id
      }

    # `row` written to `schema`, in a savepoint: :ok, or the name of the check it broke.
    defp write(schema, row) do
      now = DateTime.utc_now()
      row = Map.merge(%{id: Ecto.UUID.generate(), inserted_at: now}, row)

      row =
        if schema in [ModelChoice, Fallback], do: Map.put_new(row, :updated_at, now), else: row

      Repo.transaction(fn -> Repo.insert_all(schema, [row]) end)
      :ok
    rescue
      error in Postgrex.Error -> error.postgres[:constraint] || error.postgres.code
    end

    # A choice of the workspace at the place `attrs` name; `for_workflow/3` sets a
    # workflow, so two rows of a test need not share a place.
    defp choice(ctx, attrs),
      do: write(ModelChoice, Map.merge(base(ctx), Map.new(attrs)))

    defp for_workflow(ctx, workflow, attrs),
      do: choice(ctx, Map.put(Map.new(attrs), :workflow, workflow))

    test "a workflow, at its bounds", ctx do
      assert for_workflow(ctx, "a" <> String.duplicate("-", 63), %{}) == :ok
      assert for_workflow(ctx, "a1-b", %{}) == :ok

      assert for_workflow(ctx, "a" <> String.duplicate("b", 64), %{}) ==
               "model_choices_workflow_format"

      assert for_workflow(ctx, "A", %{}) == "model_choices_workflow_format"
      assert for_workflow(ctx, "-a", %{}) == "model_choices_workflow_format"
      assert for_workflow(ctx, "1a", %{}) == "model_choices_workflow_format"
      assert for_workflow(ctx, "a_b", %{}) == "model_choices_workflow_format"
      assert for_workflow(ctx, "", %{}) == "model_choices_workflow_format"
    end

    test "a chain is the organisation's or the operator's", ctx do
      assert choice(ctx, %{chain: "organisation"}) == :ok
      assert choice(ctx, %{chain: "operator"}) == :ok
      assert choice(ctx, %{chain: "client", workflow: "x"}) == "model_choices_chain_check"
    end

    test "a model id, at its bounds", ctx do
      assert for_workflow(ctx, "a", %{model_id: "a" <> String.duplicate("/", 199)}) == :ok

      assert for_workflow(ctx, "b", %{model_id: "a" <> String.duplicate("/", 200)}) ==
               "model_choices_model_id_format"

      assert for_workflow(ctx, "c", %{model_id: "a b"}) == "model_choices_model_id_format"
      assert for_workflow(ctx, "d", %{model_id: "/a"}) == "model_choices_model_id_format"
      assert for_workflow(ctx, "e", %{model_id: "aé"}) == "model_choices_model_id_format"
      assert for_workflow(ctx, "f", %{model_id: ""}) == "model_choices_model_id_format"
    end

    test "an effort, at its bounds, and only with a model", ctx do
      effort = "a" <> String.duplicate("-", 31)
      assert for_workflow(ctx, "a", %{model_id: "m", effort: effort}) == :ok

      assert for_workflow(ctx, "b", %{model_id: "m", effort: effort <> "-"}) ==
               "model_choices_effort_format"

      assert for_workflow(ctx, "c", %{model_id: "m", effort: "High"}) ==
               "model_choices_effort_format"

      assert for_workflow(ctx, "d", %{model_id: "m", effort: "1a"}) ==
               "model_choices_effort_format"

      assert for_workflow(ctx, "e", %{effort: "high"}) == "model_choices_shape_check"
    end

    test "a tier map, at its bounds", ctx do
      id = "a" <> String.duplicate("b", 199)
      effort = "a" <> String.duplicate("b", 31)

      full = %{
        "light" => id,
        "balanced" => %{"model" => id, "effort" => effort},
        "thinking" => "m"
      }

      assert for_workflow(ctx, "a", %{tiers: full}) == :ok

      for {kind, tiers} <- [
            {"b", %{"light" => id <> "b"}},
            {"c", %{"light" => %{"model" => id <> "b"}}},
            {"d", %{"light" => %{"model" => "m", "effort" => effort <> "b"}}},
            {"e", %{"huge" => "m"}},
            {"e2", %{"fast" => "m"}},
            {"f", %{"light" => %{"effort" => "high"}}},
            {"g", %{"light" => %{"model" => "m", "extra" => "x"}}},
            {"h", %{"light" => 1}},
            {"i", %{"light" => %{"model" => 1}}},
            {"j", %{"light" => %{"model" => "m", "effort" => 1}}},
            {"k", %{"light" => "m n"}},
            {"l", %{}}
          ] do
        assert for_workflow(ctx, kind, %{tiers: tiers}) == "model_choices_tiers_check",
               inspect(tiers)
      end

      # A list or a string is no map: written straight, as the schema's type refuses it.
      for tiers <- [~s(["m"]), ~s("m"), "1", "true"] do
        error =
          assert_raise Postgrex.Error, fn ->
            Repo.transaction(fn ->
              Repo.query!("UPDATE model_choices SET tiers = $1::jsonb", [tiers])
            end)
          end

        assert error.postgres.constraint == "model_choices_tiers_check"
      end
    end

    test "the tier fast is renamed balanced: a choice with fast is deleted", ctx do
      version = @balanced
      migration = migration(version)
      ids = %{fast: Ecto.UUID.generate(), balanced: Ecto.UUID.generate()}
      kept = Ecto.UUID.generate()

      # Rolled back, the check accepts fast and refuses balanced.
      assert :ok = Ecto.Migrator.down(Repo, version, migration, @options)
      assert for_workflow(ctx, "a", %{tiers: %{"balanced" => "m"}}) == "model_choices_tiers_check"

      assert for_workflow(ctx, "b", %{id: ids.fast, tiers: %{"fast" => "m", "light" => "m"}}) ==
               :ok

      assert for_workflow(ctx, "c", %{id: kept, tiers: %{"light" => "m"}}) == :ok

      fallback = %{
        organisation_id: ctx.organisation_id,
        model_choice_id: ids.fast,
        position: 0,
        connection_id: ctx.provider.id,
        runtime: "claude",
        tiers: %{"fast" => "m", "light" => "m"}
      }

      assert write(Fallback, fallback) == :ok

      # Up, the choice with fast goes with its fallback, and the check refuses fast.
      assert :ok = Ecto.Migrator.up(Repo, version, migration, @options)
      assert Repo.get(ModelChoice, ids.fast) == nil
      assert Repo.get(ModelChoice, kept)
      assert Repo.aggregate(Fallback, :count) == 0
      assert for_workflow(ctx, "d", %{tiers: %{"fast" => "m"}}) == "model_choices_tiers_check"
      assert for_workflow(ctx, "e", %{id: ids.balanced, tiers: %{"balanced" => "m"}}) == :ok

      # Down again, the choice with balanced goes.
      assert :ok = Ecto.Migrator.down(Repo, version, migration, @options)
      assert Repo.get(ModelChoice, ids.balanced) == nil
      assert Repo.get(ModelChoice, kept)
      assert :ok = Ecto.Migrator.up(Repo, version, migration, @options)
    end

    test "the shape: what goes with what", ctx do
      no_provider = %{connection_id: nil}
      tiers = %{"light" => "m"}

      # A model needs a provider; a row needs a provider or a tier map.
      assert for_workflow(ctx, "a", Map.merge(no_provider, %{tiers: tiers})) == :ok

      assert for_workflow(ctx, "c", Map.merge(no_provider, %{model_id: "m", tiers: tiers})) ==
               "model_choices_shape_check"

      assert for_workflow(ctx, "d", no_provider) == "model_choices_shape_check"
      assert for_workflow(ctx, "e", %{}) == :ok

      # The organisation's default has no workspace; a lock is for the workspace's rows.
      org = %{workspace_id: nil}
      assert choice(ctx, Map.merge(org, %{chain: "operator"})) == :ok

      assert choice(ctx, Map.merge(org, %{locked: true, chain: "operator", workflow: "x"})) ==
               "model_choices_shape_check"

      assert choice(ctx, %{locked: true, workflow: "f"}) == :ok
      assert choice(ctx, %{locked: true}) == :ok

      assert choice(ctx, %{locked: true, target_id: ctx.target.id, workflow: "g"}) ==
               "model_choices_shape_check"

      assert choice(ctx, %{workspace_id: nil, target_id: ctx.target.id, workflow: "h"}) in [
               "model_choices_shape_check",
               "model_choices_target_id_fkey"
             ]
    end

    test "one choice at a place and chain", ctx do
      target = %{target_id: ctx.target.id}

      assert choice(ctx, %{}) == :ok
      assert choice(ctx, %{}) == "model_choices_place_index"
      assert choice(ctx, %{chain: "operator"}) == :ok
      assert for_workflow(ctx, "explore", %{}) == :ok
      assert for_workflow(ctx, "explore", %{}) == "model_choices_place_index"
      assert choice(ctx, target) == :ok
      assert choice(ctx, target) == "model_choices_place_index"
      assert for_workflow(ctx, "explore", target) == :ok

      org = %{workspace_id: nil}
      assert choice(ctx, org) == :ok
      assert choice(ctx, org) == "model_choices_place_index"
    end

    test "a provider is kept while a choice uses it, and a target takes its choices", ctx do
      assert choice(ctx, %{}) == :ok

      assert_raise Postgrex.Error, ~r/model_choices_connection_id_fkey/, fn ->
        Repo.transaction(fn -> Repo.delete_all(Connections.Connection) end)
      end

      assert choice(ctx, %{target_id: ctx.target.id}) == :ok
      Repo.delete!(ctx.target)
      assert Repo.aggregate(ModelChoice, :count) == 1

      Repo.delete_all(ModelChoice)
      assert {_count, _} = Repo.delete_all(Connections.Connection)
    end

    test "a fallback: its position, runtime and tiers, once per position and provider", ctx do
      id = Ecto.UUID.generate()
      assert choice(ctx, %{id: id}) == :ok

      {:ok, other} =
        Connections.create_provider(ctx.scope, %{
          provider: "deepseek",
          keys: [%{value_id: "main", value: "y"}]
        })

      tiers = %{
        "light" => "m",
        "balanced" => %{"model" => "m", "effort" => "high"},
        "thinking" => "m"
      }

      fallback = %{
        organisation_id: ctx.organisation_id,
        model_choice_id: id,
        position: 0,
        connection_id: other.id,
        runtime: "claude",
        tiers: tiers
      }

      row = fn attrs -> write(Fallback, Map.merge(fallback, attrs)) end
      first = %{position: 1, connection_id: ctx.provider.id}

      assert row.(%{}) == :ok
      assert row.(%{position: 1}) == "model_choice_fallbacks_model_choice_id_connection_id_index"

      assert row.(%{connection_id: ctx.provider.id}) ==
               "model_choice_fallbacks_model_choice_id_position_index"

      assert row.(%{first | position: -1}) == "model_choice_fallbacks_position_check"

      for runtime <- ["a" <> String.duplicate("b", 64), "Claude", "1a", "-a", "a b", ""] do
        assert row.(Map.put(first, :runtime, runtime)) == "model_choice_fallbacks_runtime_format",
               inspect(runtime)
      end

      for bad <- [%{}, %{"fast" => "m"}, %{"light" => "m n"}, %{"light" => %{"effort" => "high"}}] do
        assert row.(Map.put(first, :tiers, bad)) == "model_choice_fallbacks_tiers_check",
               inspect(bad)
      end

      # Both are needed.
      assert row.(Map.put(first, :runtime, nil)) == :not_null_violation
      assert row.(Map.put(first, :tiers, nil)) == :not_null_violation
      assert %{"runtime" => false, "tiers" => false} = columns("model_choice_fallbacks")

      # The runtime at its longest.
      assert row.(Map.put(first, :runtime, "a" <> String.duplicate("_", 63))) == :ok
    end

    test "a fallback reaches a provider and a choice of its organisation alone", ctx do
      id = Ecto.UUID.generate()
      assert choice(ctx, %{id: id}) == :ok

      %{scope: elsewhere} = sign_up_fixture()

      {:ok, foreign} =
        Connections.create_provider(elsewhere, %{
          provider: "deepseek",
          keys: [%{value_id: "main", value: "y"}]
        })

      row = %{
        organisation_id: ctx.organisation_id,
        model_choice_id: id,
        position: 0,
        runtime: "claude",
        tiers: %{"light" => "m"}
      }

      assert write(Fallback, Map.put(row, :connection_id, foreign.id)) ==
               "model_choice_fallbacks_connection_id_fkey"

      assert write(
               Fallback,
               Map.merge(row, %{
                 organisation_id: elsewhere.organisation.id,
                 connection_id: foreign.id
               })
             ) == "model_choice_fallbacks_model_choice_id_fkey"
    end

    test "a provider is kept while a fallback uses it, and a choice takes its fallbacks", ctx do
      id = Ecto.UUID.generate()
      assert choice(ctx, %{id: id, connection_id: nil, tiers: %{"light" => "m"}}) == :ok

      fallback = %{
        organisation_id: ctx.organisation_id,
        model_choice_id: id,
        position: 0,
        connection_id: ctx.provider.id,
        runtime: "claude",
        tiers: %{"light" => "m"}
      }

      assert write(Fallback, fallback) == :ok

      assert_raise Postgrex.Error, ~r/model_choice_fallbacks_connection_id_fkey/, fn ->
        Repo.transaction(fn -> Repo.delete_all(Connections.Connection) end)
      end

      Repo.delete_all(ModelChoice)
      assert Repo.aggregate(Fallback, :count) == 0
      assert {_count, _} = Repo.delete_all(Connections.Connection)
    end

    test "a choice keeps no key, and up deletes the stored fallbacks", ctx do
      migration = migration(@per_fallback)
      id = Ecto.UUID.generate()

      # Rolled back, a choice has a key again, and a fallback a model and an effort.
      assert :ok = Ecto.Migrator.down(Repo, @per_fallback, migration, @options)
      assert Map.has_key?(columns("model_choices"), "value_id")
      refute Map.has_key?(columns("model_choice_fallbacks"), "runtime")

      Repo.query!(
        """
        INSERT INTO model_choices
          (id, organisation_id, workspace_id, connection_id, value_id, chain, locked,
           inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, 'main', 'organisation', false, now(), now())
        """,
        [
          Ecto.UUID.dump!(id),
          Ecto.UUID.dump!(ctx.organisation_id),
          Ecto.UUID.dump!(ctx.workspace_id),
          Ecto.UUID.dump!(ctx.provider.id)
        ]
      )

      {:ok, other} =
        Connections.create_provider(ctx.scope, %{
          provider: "deepseek",
          keys: [%{value_id: "main", value: "y"}]
        })

      Repo.query!(
        """
        INSERT INTO model_choice_fallbacks
          (id, organisation_id, model_choice_id, position, connection_id, model_id, effort,
           inserted_at, updated_at)
        VALUES ($1, $2, $3, 0, $4, 'm', 'high', now(), now())
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          Ecto.UUID.dump!(ctx.organisation_id),
          Ecto.UUID.dump!(id),
          Ecto.UUID.dump!(other.id)
        ]
      )

      # Up, the choice stays without its key, and the fallback, with no runtime and no
      # tiers to keep, is deleted.
      assert :ok = Ecto.Migrator.up(Repo, @per_fallback, migration, @options)
      assert %ModelChoice{connection_id: provider_id} = Repo.get(ModelChoice, id)
      assert provider_id == ctx.provider.id
      assert Repo.aggregate(Fallback, :count) == 0

      refute Map.has_key?(columns("model_choices"), "value_id")
      fallback_columns = columns("model_choice_fallbacks")
      assert %{"runtime" => false, "tiers" => false} = fallback_columns
      refute Map.has_key?(fallback_columns, "model_id")
      refute Map.has_key?(fallback_columns, "effort")

      # A model still needs a provider.
      assert for_workflow(ctx, "a", %{connection_id: nil, model_id: "m", tiers: %{"light" => "m"}}) ==
               "model_choices_shape_check"

      # Down and up again, with a fallback of the new form in place.
      assert write(Fallback, %{
               organisation_id: ctx.organisation_id,
               model_choice_id: id,
               position: 0,
               connection_id: other.id,
               runtime: "claude",
               tiers: %{"light" => "m"}
             }) == :ok

      assert :ok = Ecto.Migrator.down(Repo, @per_fallback, migration, @options)
      assert :ok = Ecto.Migrator.up(Repo, @per_fallback, migration, @options)
      assert Repo.aggregate(Fallback, :count) == 0
      assert Repo.get(ModelChoice, id)
    end

    test "a choice of a target of another workspace is refused", ctx do
      other = workspace_fixture(ctx.scope.organisation, "Other")

      assert choice(ctx, %{workspace_id: other.id, target_id: ctx.target.id}) ==
               "model_choices_target_id_fkey"
    end
  end
end
