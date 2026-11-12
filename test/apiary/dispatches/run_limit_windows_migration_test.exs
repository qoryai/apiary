defmodule Apiary.Dispatches.RunLimitWindowsMigrationTest do
  # The migration that lets a run keep its model provider's limit windows in
  # `runs.provider_api` as `use_up_to_windows`, run down and up again inside the test's
  # transaction, which rolls it all back, and the check it replaces, at its bounds and one
  # past them. It changes the tables under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log
  @moduletag needs: :factory

  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Repo}

  @version 20_261_112_110_000
  @migration Apiary.Repo.Migrations.KeepARunSLimitWindows
  @file_name "#{@version}_keep_a_run_s_limit_windows.exs"
  @options [log: false, migration_lock: false]
  @api %{
    "format" => "anthropic-messages",
    "endpoint" => "https://api.anthropic.com",
    "auth" => %{"scheme" => "bearer", "oauth" => true}
  }
  @windows ~w(five_hour seven_day)

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

    %{run_id: run.id}
  end

  # `api` written to the run as its `provider_api`, with the other provider columns, in a
  # savepoint: :ok, or the name of the check it broke.
  defp set(run_id, api) do
    Repo.transaction(fn ->
      Repo.query!(
        "UPDATE runs SET run_settings = $2, model_keys = $3, provider_chain = $4, " <>
          "provider_api = $5 WHERE id = $1",
        [
          Ecto.UUID.dump!(run_id),
          %{"runtime" => "claude"},
          [%{"id" => Ecto.UUID.generate(), "name" => "model-1", "use_up_to_percent" => 90}],
          "organisation",
          api
        ]
      )
    end)

    :ok
  rescue
    error in Postgrex.Error -> error.postgres[:constraint] || error.postgres.code
  end

  defp api_of(run_id) do
    %{rows: [[api]]} =
      Repo.query!("SELECT provider_api FROM runs WHERE id = $1", [Ecto.UUID.dump!(run_id)])

    api
  end

  # The bytes a JSON value takes as the database writes it as text.
  defp text_bytes(value) do
    %{rows: [[bytes]]} = Repo.query!("SELECT octet_length($1::jsonb::text)", [value])
    bytes
  end

  test "down removes a run's windows and refuses them; up takes them again", %{run_id: run_id} do
    with_windows = Map.put(@api, "use_up_to_windows", @windows)
    assert set(run_id, with_windows) == :ok

    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, @options)
    assert api_of(run_id) == @api
    assert set(run_id, with_windows) == "runs_provider_api_check"

    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, @options)
    assert set(run_id, with_windows) == :ok
    assert api_of(run_id) == with_windows
  end

  test "the windows are 1 to 11 names of the contract's limit windows", %{run_id: run_id} do
    assert set(run_id, @api) == :ok

    for windows <- [
          ["w1"],
          for(i <- 1..11, do: "w#{i}"),
          ["a" <> String.duplicate("_9", 31) <> "z"]
        ] do
      assert set(run_id, Map.put(@api, "use_up_to_windows", windows)) == :ok, inspect(windows)
    end

    for windows <- [
          [],
          for(i <- 1..12, do: "w#{i}"),
          "five_hour",
          ["five_hour", 5],
          [nil],
          [""],
          ["Five_hour"],
          ["5_hour"],
          ["five-hour"],
          ["five_hour\n"],
          ["a" <> String.duplicate("b", 64)]
        ] do
      assert set(run_id, Map.put(@api, "use_up_to_windows", windows)) ==
               "runs_provider_api_check",
             inspect(windows)
    end

    assert set(run_id, Map.put(@api, "limit_windows", @windows)) == "runs_provider_api_check"
  end

  # The largest API the catalogue's schema and the endpoint rule allow, but a basic
  # scheme's username, which the schema does not bound: the longest format, an endpoint
  # of 2,048 characters, a header of 64, and 4 key prefixes of 32 characters that each
  # take two octets as JSON text. With 11 windows of 64 characters, it stays within the
  # 8 KiB of the check, which stays as it was.
  test "the largest API with 11 windows of 64 characters fits 8 KiB", %{run_id: run_id} do
    endpoint = "https://" <> String.duplicate("a", 63) <> ".example.com/"
    endpoint = endpoint <> String.duplicate("p", 2048 - String.length(endpoint))
    assert String.length(endpoint) == 2048
    assert Apiary.Kinds.Endpoint.check(endpoint) == :ok

    api = %{
      "format" => "anthropic-messages",
      "endpoint" => endpoint,
      "auth" => %{"scheme" => "header", "header" => String.duplicate("x", 64)},
      "key_prefixes" => for(c <- ["\"", "\\", "'", "!"], do: String.duplicate(c, 32)),
      "use_up_to_windows" => for(n <- 1..11, do: String.pad_trailing("w#{n}_", 64, "x"))
    }

    bytes = text_bytes(api)
    assert bytes <= 8192
    assert set(run_id, api) == :ok

    padding = 8192 - bytes
    over = %{api | "endpoint" => api["endpoint"] <> String.duplicate("p", padding + 1)}
    assert text_bytes(over) == 8193
    assert set(run_id, over) == "runs_provider_api_check"
  end
end
