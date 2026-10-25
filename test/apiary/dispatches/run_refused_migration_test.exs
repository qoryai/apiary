defmodule Apiary.Dispatches.RunRefusedMigrationTest do
  # The migration that ends a run its gateway refused, run down and up again inside the
  # test's transaction, which rolls it all back: up lets a run of the queue and its
  # dispatch end `run_refused` and keeps the refusal's code as `end_detail` for that cause
  # alone; down takes the column away and refuses while a row has the cause. It changes
  # `dispatch_runs` and `dispatches` under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration down and up again while later ones are applied makes Ecto warn.
  @moduletag :capture_log

  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures, only: [gateway_for!: 2]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Dispatches
  alias Apiary.Dispatches.{Dispatch, DispatchRun}

  @moduletag needs: :factory

  @migration {20_261_020_090_000, Apiary.Repo.Migrations.EndARunTheGatewayRefused,
              "end_a_run_the_gateway_refused"}

  setup_all do
    {version, migration, name} = @migration

    if not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.down(Repo, version, migration, @options))

  defp up!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.up(Repo, version, migration, @options))

  defp column? do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_name = 'dispatch_runs' AND column_name = 'end_detail'"
      )

    rows != []
  end

  # The causes the check `name` lists, sorted, as the database stores them.
  defp causes(name) do
    %{rows: [[definition]]} =
      Repo.query!("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1", [
        name
      ])

    ~r/'([a-z_]+)'::text/
    |> Regex.scan(definition, capture: :all_but_first)
    |> List.flatten()
    |> Enum.sort()
  end

  defp refused(constraint, fun), do: assert_raise(Postgrex.Error, ~r/#{constraint}/, fun)

  defp update!(table, id, assignments, params \\ []) do
    Repo.query!("UPDATE #{table} SET #{assignments} WHERE id = $1", [
      Ecto.UUID.dump!(id) | params
    ])
  end

  # A run of the queue, claimed under a key through a gateway, with its dispatch.
  setup do
    %{scope: scope} = sign_up_fixture()
    pool = pool_fixture(scope)
    _gateway = gateway_for!(scope, pool)
    %{access_key: key} = access_key_fixture(scope, node: pool)
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(scope), 1) end)
    {:ok, %{dispatch: dispatch}} = Dispatches.claim(key, Dispatches.now())
    %{run: run, dispatch: dispatch}
  end

  test "up takes run_refused for a run and its dispatch, and a code for that cause alone",
       %{run: run, dispatch: dispatch} do
    assert %{num_rows: 1} =
             update!("dispatches", dispatch.id, "ended_at = now(), end_cause = 'run_refused'")

    assert %{num_rows: 1} =
             update!(
               "dispatch_runs",
               run.id,
               "state = 'ended', end_cause = 'run_refused', end_detail = $2",
               ["model_key_missing"]
             )

    assert %DispatchRun{end_cause: :run_refused, end_detail: "model_key_missing"} =
             Repo.get!(DispatchRun, run.id)

    assert %Dispatch{end_cause: :run_refused} = Repo.get!(Dispatch, dispatch.id)

    # 64 characters is the longest code, and its first is a letter.
    longest = "a" <> String.duplicate("_", 63)
    assert %{num_rows: 1} = update!("dispatch_runs", run.id, "end_detail = $2", [longest])

    for bad <- ["", "1code", "Code", "a-b", longest <> "a"] do
      refused("dispatch_runs_end_detail_check", fn ->
        update!("dispatch_runs", run.id, "end_detail = $2", [bad])
      end)
    end

    refused("dispatch_runs_end_detail_check", fn ->
      update!("dispatch_runs", run.id, "end_cause = 'released'")
    end)

    refused("dispatch_runs_end_cause_check", fn ->
      update!("dispatch_runs", run.id, "end_cause = 'refused'")
    end)
  end

  test "down refuses while a run or a dispatch has the cause, then takes column and cause away",
       %{run: run, dispatch: dispatch} do
    update!("dispatches", dispatch.id, "ended_at = now(), end_cause = 'run_refused'")

    update!(
      "dispatch_runs",
      run.id,
      "state = 'ended', end_cause = 'run_refused', end_detail = 'image_user_root'"
    )

    # The run's detail goes with its cause; the dispatch still has the cause.
    update!("dispatch_runs", run.id, "end_detail = NULL, end_cause = 'released'")
    assert_raise Postgrex.Error, ~r/dispatches_end_cause_check/, fn -> down!(@migration) end
    assert column?()

    update!("dispatches", dispatch.id, "end_cause = 'released'")
    down!(@migration)
    refute column?()

    refused("dispatch_runs_end_cause_check", fn ->
      update!("dispatch_runs", run.id, "end_cause = 'run_refused'")
    end)

    refused("dispatches_end_cause_check", fn ->
      update!("dispatches", dispatch.id, "end_cause = 'run_refused'")
    end)

    # Every cause before the migration stays, `secrets_not_allowed` among them;
    # `build_failed`, `harness_unresolved` and `target_access_gone` came after it.
    before =
      DispatchRun.end_causes() --
        [:run_refused, :build_failed, :harness_unresolved, :target_access_gone]

    for table <- ~w(dispatch_runs dispatches) do
      assert causes("#{table}_end_cause_check") == Enum.sort(Enum.map(before, &to_string/1))
    end

    up!(@migration)
    assert column?()

    assert %{num_rows: 1} =
             update!("dispatch_runs", run.id, "end_cause = 'run_refused', end_detail = 'x'")
  end

  test "down refuses while a run of the queue has the cause", %{run: run} do
    update!("dispatch_runs", run.id, "state = 'ended', end_cause = 'run_refused'")
    assert_raise Postgrex.Error, ~r/dispatch_runs_end_cause_check/, fn -> down!(@migration) end
    assert column?()
  end
end
