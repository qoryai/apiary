defmodule Apiary.Runs.ModelKeysMigrationTest do
  # The migration that keeps a run's model keys in place of the value id of its one key,
  # run down and up again inside the test's transaction, which rolls it all back: the
  # list it fills for runs registered before it, the checks it adds, and the providers of
  # a run of the queue. It changes the tables under every other test, so this is not
  # async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log
  @moduletag needs: [:factory, :secrets]

  import Ecto.Query, only: [from: 2]
  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, ModelChoices, ModelKeys, Repo}
  alias Apiary.Runs.{ProviderCredential, Run}
  alias Apiary.Secrets.Value

  @version 20_261_111_090_000
  @migration Apiary.Repo.Migrations.KeepARunSModelKeys
  @name "keep_a_run_s_model_keys"
  @options [log: false, migration_lock: false]

  setup_all do
    if not Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_#{@name}.exs")
      |> Code.require_file()
    end

    :ok
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

    {:ok, _choice} =
      ModelChoices.put_choice(scope, :workspace, %{provider: provider.public_id, key: "spare"})

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
    assert [%{"name" => name} | _] = Repo.get!(Run, run.id).model_keys
    assert name == "#{ctx.provider.public_id}-1"

    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, @options)

    # Down: the value id of the run's first key, the one its choice names.
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
    {:ok, _setting} = ModelKeys.put_setting(value(ctx, "spare"), %{pause_seconds: 900})

    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, @options)

    # Up: the key with that value id, by its row id, under the name the run's run
    # configuration had for its one key, the provider's public id, with its Pause for,
    # its setting; for a key that is gone, the all-zero row id, which no key has, and the
    # default of an API key, 60 seconds.
    assert Repo.get!(Run, run.id).model_keys == [
             %{
               "id" => value(ctx, "spare").id,
               "name" => ctx.provider.public_id,
               "pause_for_s" => 900
             }
           ]

    assert Repo.get!(Run, gone.id).model_keys == [
             %{
               "id" => Ecto.UUID.cast!(<<0::128>>),
               "name" => ctx.provider.public_id,
               "pause_for_s" => 60
             }
           ]

    # A subscription's default, 1 hour.
    assert [%{"id" => main_id, "pause_for_s" => 3600}] =
             Repo.get!(Run, subscription.id).model_keys

    assert main_id == value(ctx, "main").id

    # The run configuration has the Pause for, and a later change of the setting leaves it.
    {:ok, _setting} = ModelKeys.put_setting(value(ctx, "spare"), %{pause_seconds: 120})
    {:ok, %{keys: [%{entry: entry}]}} = ProviderCredential.for_run(Repo.get!(Run, run.id))
    assert entry["pause_for_s"] == 900

    assert Repo.get!(Run, ended.id).model_keys == []
  end

  test "the list is at most 6 keys, each with a row id and a credential name", ctx do
    run = claimed!(ctx, "acme/shop#3")

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
  end
end
