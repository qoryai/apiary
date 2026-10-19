defmodule Apiary.ModelChoices.MigrationTest do
  # The migration of the model choice, run down and up again inside the test's
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
  alias Apiary.ModelChoices.ModelChoice

  @migrations [
    {20_261_019_070_200, Apiary.Repo.Migrations.KeepTheModelChoiceAtEachLevel,
     "keep_the_model_choice_at_each_level"}
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

  defp tables do
    %{rows: rows} =
      Repo.query!(
        "SELECT table_name FROM information_schema.tables WHERE table_name = ANY($1)",
        [["model_choices"]]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  defp function? do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM pg_proc WHERE proname = 'model_choice_tiers_valid'")

    count == 1
  end

  test "down takes the table and the tier check away, and up puts them back" do
    assert tables() == ["model_choices"]
    assert function?()

    for {version, migration, _name} <- Enum.reverse(@migrations),
        do: assert(:ok = Ecto.Migrator.down(Repo, version, migration, @options))

    assert tables() == []
    refute function?()

    for {version, migration, _name} <- @migrations,
        do: assert(:ok = Ecto.Migrator.up(Repo, version, migration, @options))

    assert tables() == ["model_choices"]
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
        if schema == ModelChoice, do: Map.put_new(row, :updated_at, now), else: row

      Repo.transaction(fn -> Repo.insert_all(schema, [row]) end)
      :ok
    rescue
      error in Postgrex.Error -> error.postgres[:constraint] || error.postgres.code
    end

    # A choice of the workspace at the place `attrs` name; `kinded/3` sets a run kind, so
    # two rows of a test need not share a place.
    defp choice(ctx, attrs),
      do: write(ModelChoice, Map.merge(base(ctx), Map.new(attrs)))

    defp kinded(ctx, kind, attrs), do: choice(ctx, Map.put(Map.new(attrs), :run_kind, kind))

    test "a run kind, at its bounds", ctx do
      assert kinded(ctx, "a" <> String.duplicate("_", 39), %{}) == :ok
      assert kinded(ctx, "a" <> String.duplicate("_", 40), %{}) == "model_choices_run_kind_format"
      assert kinded(ctx, "A", %{}) == "model_choices_run_kind_format"
      assert kinded(ctx, "_a", %{}) == "model_choices_run_kind_format"
      assert kinded(ctx, "a1", %{}) == "model_choices_run_kind_format"
      assert kinded(ctx, "", %{}) == "model_choices_run_kind_format"
    end

    test "a chain is the organisation's or the operator's", ctx do
      assert choice(ctx, %{chain: "organisation"}) == :ok
      assert choice(ctx, %{chain: "operator"}) == :ok
      assert choice(ctx, %{chain: "client", run_kind: "x"}) == "model_choices_chain_check"
    end

    test "a value id, at its bounds", ctx do
      assert kinded(ctx, "a", %{value_id: "a" <> String.duplicate("b", 63)}) == :ok

      assert kinded(ctx, "b", %{value_id: "a" <> String.duplicate("b", 64)}) ==
               "model_choices_value_id_format"

      assert kinded(ctx, "c", %{value_id: "Main"}) == "model_choices_value_id_format"
      assert kinded(ctx, "d", %{value_id: "-a"}) == "model_choices_value_id_format"
      assert kinded(ctx, "e", %{value_id: ""}) == "model_choices_value_id_format"
    end

    test "a model id, at its bounds", ctx do
      assert kinded(ctx, "a", %{model_id: "a" <> String.duplicate("/", 199)}) == :ok

      assert kinded(ctx, "b", %{model_id: "a" <> String.duplicate("/", 200)}) ==
               "model_choices_model_id_format"

      assert kinded(ctx, "c", %{model_id: "a b"}) == "model_choices_model_id_format"
      assert kinded(ctx, "d", %{model_id: "/a"}) == "model_choices_model_id_format"
      assert kinded(ctx, "e", %{model_id: "aé"}) == "model_choices_model_id_format"
      assert kinded(ctx, "f", %{model_id: ""}) == "model_choices_model_id_format"
    end

    test "an effort, at its bounds, and only with a model", ctx do
      effort = "a" <> String.duplicate("-", 31)
      assert kinded(ctx, "a", %{model_id: "m", effort: effort}) == :ok

      assert kinded(ctx, "b", %{model_id: "m", effort: effort <> "-"}) ==
               "model_choices_effort_format"

      assert kinded(ctx, "c", %{model_id: "m", effort: "High"}) == "model_choices_effort_format"
      assert kinded(ctx, "d", %{model_id: "m", effort: "1a"}) == "model_choices_effort_format"
      assert kinded(ctx, "e", %{effort: "high"}) == "model_choices_shape_check"
    end

    test "a tier map, at its bounds", ctx do
      id = "a" <> String.duplicate("b", 199)
      effort = "a" <> String.duplicate("b", 31)

      full = %{"light" => id, "fast" => %{"model" => id, "effort" => effort}, "thinking" => "m"}
      assert kinded(ctx, "a", %{tiers: full}) == :ok

      for {kind, tiers} <- [
            {"b", %{"light" => id <> "b"}},
            {"c", %{"light" => %{"model" => id <> "b"}}},
            {"d", %{"light" => %{"model" => "m", "effort" => effort <> "b"}}},
            {"e", %{"huge" => "m"}},
            {"f", %{"light" => %{"effort" => "high"}}},
            {"g", %{"light" => %{"model" => "m", "extra" => "x"}}},
            {"h", %{"light" => 1}},
            {"i", %{"light" => %{"model" => 1}}},
            {"j", %{"light" => %{"model" => "m", "effort" => 1}}},
            {"k", %{"light" => "m n"}},
            {"l", %{}}
          ] do
        assert kinded(ctx, kind, %{tiers: tiers}) == "model_choices_tiers_check", inspect(tiers)
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

    test "the shape: what goes with what", ctx do
      no_provider = %{connection_id: nil}
      tiers = %{"light" => "m"}

      # A key or a model needs a provider; a row needs a provider or a tier map.
      assert kinded(ctx, "a", Map.merge(no_provider, %{tiers: tiers})) == :ok

      assert kinded(ctx, "b", Map.merge(no_provider, %{value_id: "k", tiers: tiers})) ==
               "model_choices_shape_check"

      assert kinded(ctx, "c", Map.merge(no_provider, %{model_id: "m", tiers: tiers})) ==
               "model_choices_shape_check"

      assert kinded(ctx, "d", no_provider) == "model_choices_shape_check"
      assert kinded(ctx, "e", %{}) == :ok

      # The organisation's default has no workspace; a lock is for the workspace's rows.
      org = %{workspace_id: nil}
      assert choice(ctx, Map.merge(org, %{chain: "operator"})) == :ok

      assert choice(ctx, Map.merge(org, %{locked: true, chain: "operator", run_kind: "x"})) ==
               "model_choices_shape_check"

      assert choice(ctx, %{locked: true, run_kind: "f"}) == :ok
      assert choice(ctx, %{locked: true}) == :ok

      assert choice(ctx, %{locked: true, target_id: ctx.target.id, run_kind: "g"}) ==
               "model_choices_shape_check"

      assert choice(ctx, %{workspace_id: nil, target_id: ctx.target.id, run_kind: "h"}) in [
               "model_choices_shape_check",
               "model_choices_target_id_fkey"
             ]
    end

    test "one choice at a place and chain", ctx do
      target = %{target_id: ctx.target.id}

      assert choice(ctx, %{}) == :ok
      assert choice(ctx, %{}) == "model_choices_place_index"
      assert choice(ctx, %{chain: "operator"}) == :ok
      assert kinded(ctx, "explore", %{}) == :ok
      assert kinded(ctx, "explore", %{}) == "model_choices_place_index"
      assert choice(ctx, target) == :ok
      assert choice(ctx, target) == "model_choices_place_index"
      assert kinded(ctx, "explore", target) == :ok

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

    test "a choice of a target of another workspace is refused", ctx do
      other = workspace_fixture(ctx.scope.organisation, "Other")

      assert choice(ctx, %{workspace_id: other.id, target_id: ctx.target.id}) ==
               "model_choices_target_id_fkey"
    end
  end
end
