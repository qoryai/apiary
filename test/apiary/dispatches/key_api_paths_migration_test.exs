defmodule Apiary.Dispatches.KeyApiPathsMigrationTest do
  # The migration that lets a run's model key keep the paths it is set on in
  # `run_model_keys.api` as `paths`, run down and up again inside the test's transaction,
  # which rolls it all back, and the check it replaces, at its bounds and one past them. It
  # changes the tables under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log
  @moduletag needs: [:factory, :secrets]

  import Apiary.DispatchedRunsFixtures
  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, Repo}

  @version 20_261_119_100_000
  @migration Apiary.Repo.Migrations.KeepAKeySApiPaths
  @file_name "#{@version}_keep_a_key_s_api_paths.exs"
  @options [log: false, migration_lock: false]
  @api %{
    "format" => "openai-responses",
    "endpoint" => "https://chatgpt.com/backend-api/codex",
    "auth" => %{
      "scheme" => "bearer",
      "oauth" => true,
      "account_header" => "chatgpt-account-id",
      "account_claim" => "/https:~1~1api.openai.com~1auth/chatgpt_account_id"
    }
  }
  @paths ["/backend-api/codex/*"]

  setup_all do
    if not Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join(@file_name)
      |> Code.require_file()
    end

    :ok
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    %{key: key} = handover_place_fixture(scope)
    work_item = work_item_fixture(scope)
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    %{registered: run} = dispatched!(key)

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: "sk-ant-paths-0123456789"}]
      })

    [_row] =
      run_keys!(run, [%{provider: provider, secret_value_id: Ecto.UUID.generate()}], api: @api)

    %{run_id: run.id}
  end

  # `api` written to the run's key row, in a savepoint: :ok, or the name of the check it
  # broke.
  defp set(run_id, api) do
    Repo.transaction(fn ->
      Repo.query!("UPDATE run_model_keys SET api = $2 WHERE run_id = $1", [
        Ecto.UUID.dump!(run_id),
        api
      ])
    end)

    :ok
  rescue
    error in Postgrex.Error -> error.postgres[:constraint] || error.postgres.code
  end

  defp api_of(run_id) do
    %{rows: [[api]]} =
      Repo.query!("SELECT api FROM run_model_keys WHERE run_id = $1", [Ecto.UUID.dump!(run_id)])

    api
  end

  test "down removes a key's paths and refuses them; up takes them again", %{run_id: run_id} do
    with_paths = Map.put(@api, "paths", @paths)
    assert set(run_id, with_paths) == :ok

    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, @options)
    assert api_of(run_id) == @api
    assert set(run_id, with_paths) == "run_model_keys_api_check"
    assert set(run_id, @api) == :ok

    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, @options)
    assert set(run_id, with_paths) == :ok
    assert api_of(run_id) == with_paths
  end

  test "the paths are 1 to 32 strings that start with a slash", %{run_id: run_id} do
    assert set(run_id, @api) == :ok

    fits = [@paths, ["/"], for(n <- 1..32, do: "/p#{n}"), ["/a/{}/b", "/repos/{}/pulls/{}"]]

    for paths <- fits do
      assert set(run_id, Map.put(@api, "paths", paths)) == :ok, inspect(paths)
    end

    for paths <- [
          [],
          for(n <- 1..33, do: "/p#{n}"),
          "/backend-api/*",
          ["backend-api"],
          [""],
          [5],
          [nil]
        ] do
      assert set(run_id, Map.put(@api, "paths", paths)) == "run_model_keys_api_check",
             inspect(paths)
    end

    assert set(run_id, Map.put(@api, "other_paths", @paths)) == "run_model_keys_api_check"
  end

  test "the key's API keeps its bound of 8192 octets with the paths in it", %{run_id: run_id} do
    api = Map.put(@api, "paths", for(n <- 1..32, do: "/" <> String.duplicate("p", 200) <> "#{n}"))
    assert set(run_id, api) == :ok

    over =
      Map.put(@api, "paths", for(n <- 1..32, do: "/" <> String.duplicate("p", 254) <> "#{n}"))

    assert set(run_id, over) == "run_model_keys_api_check"
  end
end
