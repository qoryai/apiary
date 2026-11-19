defmodule Apiary.Runs.ModelKeysMigrationTest do
  # The migration that keeps a run's model keys in place of the value id of its one key,
  # run down and up again inside the test's transaction, which rolls it all back: the
  # list it fills for runs registered before it, the checks it adds, and the providers of
  # a run of the queue. The later migration that drops the run's columns this one fills
  # runs down first, which puts them back filled from the run's key rows, and up last; the
  # columns are read in raw SQL, as the schema reads a run's keys from rows. It changes the
  # tables under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log
  @moduletag needs: [:factory, :secrets]

  import Ecto.Query, only: [from: 2]
  import Apiary.DispatchedRunsFixtures
  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, ModelChoicesFixtures, Repo}
  alias Apiary.Secrets.Value

  @version 20_261_111_100_000
  @migration Apiary.Repo.Migrations.KeepARunSModelKeys
  @name "keep_a_run_s_model_keys"
  # The later migration that drops `model_keys` and the other provider columns of a run,
  # whose keys are then rows of `run_model_keys`.
  @columns_version 20_261_118_162_200
  @columns_migration Apiary.Repo.Migrations.DropARunSOneProviderColumns
  @columns_name "drop_a_run_s_one_provider_columns"
  @options [log: false, migration_lock: false]

  setup_all do
    for {migration, file} <- [
          {@migration, "#{@version}_#{@name}.exs"},
          {@columns_migration, "#{@columns_version}_#{@columns_name}.exs"}
        ],
        not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join(file)
      |> Code.require_file()
    end

    :ok
  end

  defp columns_down!,
    do: assert(:ok = Ecto.Migrator.down(Repo, @columns_version, @columns_migration, @options))

  defp columns_up!,
    do: assert(:ok = Ecto.Migrator.up(Repo, @columns_version, @columns_migration, @options))

  # The run's `model_keys` column.
  defp model_keys(run_id) do
    %{rows: [[keys]]} =
      Repo.query!("SELECT model_keys FROM runs WHERE id = $1", [Ecto.UUID.dump!(run_id)])

    keys
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    %{key: key} = handover_place_fixture(scope, allow_secrets: true)

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [
          %{value_id: "main", value: "sk-ant-migration-main"},
          %{value_id: "spare", value: "sk-ant-migration-spare"}
        ]
      })

    # The default key goes first in a run's keys.
    {:ok, provider} = Connections.put_default_key(scope, provider, "spare")

    {:ok, _choice} =
      ModelChoicesFixtures.put_choice(scope, :workspace, %{provider: provider.public_id})

    %{scope: scope, key: key, provider: provider}
  end

  defp claimed!(ctx, ref) do
    work_item = work_item_fixture(ctx.scope, %{external_ref: ref})
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    {:ok, %{registered: run}} = walked_claim(ctx.key, Dispatches.now())
    run
  end

  defp value(ctx, value_id) do
    Repo.one!(
      from v in Value, where: v.secret_id == ^ctx.provider.secret_id and v.value_id == ^value_id
    )
  end

  defp provider_value_id(run_id) do
    %{rows: [[value_id]]} =
      Repo.query!("SELECT provider_value_id FROM runs WHERE id = $1", [
        Ecto.UUID.dump!(run_id)
      ])

    value_id
  end

  test "a run keeps the key of its value id, under its provider's public id", ctx do
    run = claimed!(ctx, "acme/shop#1")
    gone = claimed!(ctx, "acme/shop#2")
    ended = claimed!(ctx, "acme/shop#4")
    subscription = claimed!(ctx, "acme/shop#5")
    assert [%{name: name} | _] = stored_keys(run)
    assert name == "#{ctx.provider.public_id}-1"

    columns_down!()
    assert [%{"name" => ^name} | _] = model_keys(run.id)
    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, @options)

    # Down: the value id of the run's first key, the provider's default.
    assert provider_value_id(run.id) == "spare"

    # A run whose key was renamed since: up finds no key of that value id.
    %{num_rows: 1} =
      Repo.query!("UPDATE runs SET provider_value_id = 'renamed' WHERE id = $1", [
        Ecto.UUID.dump!(gone.id)
      ])

    # A run whose provider is gone since it ended.
    %{num_rows: 1} =
      Repo.query!(
        "UPDATE runs SET state = 'completed', provider_connection_id = NULL WHERE id = $1",
        [Ecto.UUID.dump!(ended.id)]
      )

    # A run of a subscription, whose API's `auth` has `oauth: true`, through the key with
    # no setting.
    %{num_rows: 1} =
      Repo.query!(
        "UPDATE runs SET provider_value_id = 'main', " <>
          "provider_api = jsonb_set(provider_api, '{auth}', '{\"oauth\": true}') WHERE id = $1",
        [Ecto.UUID.dump!(subscription.id)]
      )

    # The key's setting, written before the upgrade.
    {:ok, _setting} = put_key_setting(ctx.scope, value(ctx, "spare"), %{pause_seconds: 900})

    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, @options)

    # Up: the key with that value id, by its row id, under the name the run's run
    # configuration had for its one key, the provider's public id, with its Pause for,
    # its setting; for a key that is gone, the all-zero row id, which no key has, and the
    # default of an API key, 60 seconds.
    assert model_keys(run.id) == [
             %{
               "id" => value(ctx, "spare").id,
               "name" => ctx.provider.public_id,
               "pause_for_s" => 900
             }
           ]

    assert model_keys(gone.id) == [
             %{
               "id" => Ecto.UUID.cast!(<<0::128>>),
               "name" => ctx.provider.public_id,
               "pause_for_s" => 60
             }
           ]

    # A subscription's default, 1 hour.
    assert [%{"id" => main_id, "pause_for_s" => 3600}] = model_keys(subscription.id)

    assert main_id == value(ctx, "main").id

    assert model_keys(ended.id) == []
    columns_up!()
  end

  test "down keeps the first of several keys, and clears a run whose first key is gone",
       ctx do
    first_main = claimed!(ctx, "acme/shop#6")
    first_gone = claimed!(ctx, "acme/shop#7")
    name = fn n -> "#{ctx.provider.public_id}-#{n}" end

    set_keys = fn run, ids ->
      keys =
        ids
        |> Enum.with_index(1)
        |> Enum.map(fn {id, n} -> %{"id" => id, "name" => name.(n), "pause_for_s" => 60} end)

      %{num_rows: 1} =
        Repo.query!("UPDATE runs SET model_keys = $2 WHERE id = $1", [
          Ecto.UUID.dump!(run.id),
          keys
        ])
    end

    main = value(ctx, "main").id
    spare = value(ctx, "spare").id
    columns_down!()
    set_keys.(first_main, [main, spare])
    set_keys.(first_gone, [Ecto.UUID.generate(), spare])

    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, @options)

    assert provider_value_id(first_main.id) == "main"
    assert provider_value_id(first_gone.id) == nil

    %{rows: [[connection_id, secret_id, chain, api]]} =
      Repo.query!(
        "SELECT provider_connection_id, provider_secret_id, provider_chain, provider_api " <>
          "FROM runs WHERE id = $1",
        [Ecto.UUID.dump!(first_gone.id)]
      )

    assert {connection_id, secret_id, chain, api} == {nil, nil, nil, nil}

    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, @options)
    assert [%{"id" => ^main, "name" => kept_name}] = model_keys(first_main.id)
    assert kept_name == ctx.provider.public_id
    # A run with no provider has no list, as runs_provider_check has it.
    assert model_keys(first_gone.id) == nil
    columns_up!()
  end

  test "down of the column drop fills the columns from the default model provider credential's provider's rows, with times in UTC",
       ctx do
    reset = in_seconds(7_200)
    key_state!(ctx.provider, "main", resets_at: reset)
    run = claimed!(ctx, "acme/shop#8")
    [%{api: api} | _rest] = stored_keys(run)

    # A key row of a second provider, as a later session's key of a shared run.
    {:ok, other} =
      Connections.create_provider(ctx.scope, %{
        provider: "anthropic",
        name: "Checkout keys",
        keys: [%{value_id: "main", value: "sk-ant-migration-other"}]
      })

    other_value =
      Repo.one!(from v in Value, where: v.secret_id == ^other.secret_id and v.value_id == "main")

    {1, _rows} =
      Repo.insert_all(Apiary.Runs.ModelKey, [
        %{
          run_id: run.id,
          position: 3,
          name: "#{other.public_id}-1",
          secret_value_id: other_value.id,
          connection_id: other.id,
          secret_id: other.secret_id,
          chain: "organisation",
          api: api,
          pause_for_s: 60,
          resets_at: reset
        }
      ])

    # A session time zone other than UTC changes no time the columns get.
    Repo.query!("SET LOCAL TIME ZONE 'Pacific/Auckland'")
    columns_down!()

    %{rows: [[connection_id, secret_id, chain]]} =
      Repo.query!(
        "SELECT provider_connection_id, provider_secret_id, provider_chain FROM runs " <>
          "WHERE id = $1",
        [Ecto.UUID.dump!(run.id)]
      )

    assert {Ecto.UUID.cast!(connection_id), Ecto.UUID.cast!(secret_id), chain} ==
             {ctx.provider.id, ctx.provider.secret_id, "organisation"}

    keys = model_keys(run.id)
    p = ctx.provider.public_id
    assert Enum.map(keys, & &1["name"]) == ["#{p}-1", "#{p}-2"]
    assert %{"resets_at" => resets_at} = Enum.find(keys, &(&1["id"] == value(ctx, "main").id))
    assert resets_at == DateTime.to_iso8601(reset)
    columns_up!()
  end

  test "the list is at most 6 keys, each with a row id and a credential name", ctx do
    run = claimed!(ctx, "acme/shop#3")
    columns_down!()

    set = fn keys ->
      try do
        Repo.transaction(fn ->
          Repo.query!("UPDATE runs SET model_keys = $2 WHERE id = $1", [
            Ecto.UUID.dump!(run.id),
            keys
          ])
        end)

        :ok
      rescue
        error in Postgrex.Error -> error.postgres[:constraint]
      end
    end

    key = fn n -> %{"id" => Ecto.UUID.generate(), "name" => "model-#{n}"} end

    assert set.(for n <- 1..6, do: key.(n)) == :ok
    assert set.([]) == :ok
    assert set.(for n <- 1..7, do: key.(n)) == "runs_model_keys_check"
    assert set.([%{"name" => "model-1"}]) == "runs_model_keys_check"
    assert set.([%{"id" => Ecto.UUID.generate()}]) == "runs_model_keys_check"
    assert set.([%{key.(1) | "name" => "Model"}]) == "runs_model_keys_check"
    assert set.([%{key.(1) | "id" => "sk-ant-not-an-id"}]) == "runs_model_keys_check"
    assert set.([%{key.(1) | "name" => 1}]) == "runs_model_keys_check"
    assert set.(["model-1"]) == "runs_model_keys_check"
    assert set.(%{"id" => Ecto.UUID.generate()}) == "runs_model_keys_check"
    columns_up!()
  end
end
