defmodule Apiary.Dispatches.RunSettingsMigrationTest do
  # The migration of what a run keeps of its model choice, run down and up again inside
  # the test's transaction, which rolls it all back, and the checks it adds on a run a
  # handover registered, each at its bound and one past it. It changes the tables under
  # every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log
  @moduletag needs: :factory

  import Ecto.Query, only: [from: 2]
  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Repo}
  alias Apiary.Dispatches.DispatchRun

  @version 20_261_019_070_400
  @migration Apiary.Repo.Migrations.KeepARunSModelSettings
  @name "keep_a_run_s_model_settings"
  @options [log: false, migration_lock: false]
  @columns ~w(provider_api provider_chain provider_connection_id provider_secret_id
              provider_value_id run_settings)
  @api %{
    "format" => "anthropic-messages",
    "endpoint" => "https://api.anthropic.com",
    "auth" => %{"scheme" => "bearer"}
  }

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
    %{key: key} = handover_place_fixture(scope)
    work_item = work_item_fixture(scope)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    %{dispatch: dispatch} = dispatched!(key)

    {:ok, %{run: run}} =
      Dispatches.handover(key, dispatch.public_id, %{
        body: ~s({"version":1,"time":"2026-10-18T12:00:00Z"})
      })

    %{run_id: run.id, queued: queued}
  end

  defp columns do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_name = 'runs' AND column_name = ANY($1)",
        [@columns]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  # `set` written to the run, in a savepoint: :ok, or the name of the check it broke.
  defp set(run_id, set) do
    {assignments, values} =
      set
      |> Enum.with_index(2)
      |> Enum.map(fn {{column, value}, n} -> {"#{column} = $#{n}", value} end)
      |> Enum.unzip()

    Repo.transaction(fn ->
      Repo.query!(
        "UPDATE runs SET #{Enum.join(assignments, ", ")} WHERE id = $1",
        [Ecto.UUID.dump!(run_id) | values]
      )
    end)

    :ok
  rescue
    error in Postgrex.Error -> error.postgres[:constraint] || error.postgres.code
  end

  defp provider(api, more \\ []),
    do:
      Keyword.merge(
        [
          run_settings: %{"runtime" => "claude"},
          provider_value_id: "main",
          provider_chain: "organisation",
          provider_api: api
        ],
        more
      )

  # The bytes a JSON value takes as the database writes it as text.
  defp text_bytes(value) do
    %{rows: [[bytes]]} = Repo.query!("SELECT octet_length($1::jsonb::text)", [value])
    bytes
  end

  test "down takes the columns away, and up puts them back", %{queued: queued} do
    assert columns() == Enum.sort(@columns)
    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, @options)
    assert columns() == []
    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, @options)
    assert columns() == Enum.sort(@columns)

    # Each cause of a run's model choice is taken, with the outcome error.
    for cause <- ~w(provider_gone runtime_unserved key_gone model_gone) do
      {1, _rows} =
        Repo.update_all(from(r in DispatchRun, where: r.id == ^queued.id),
          set: [
            state: :ended,
            end_cause: String.to_existing_atom(cause),
            result_outcome: :error
          ]
        )
    end
  end

  test "down refuses while a run of the queue ended for a cause of its model choice", %{
    queued: queued
  } do
    {1, _rows} =
      Repo.update_all(from(r in DispatchRun, where: r.id == ^queued.id),
        set: [
          state: :ended,
          end_cause: :model_gone,
          result_outcome: :error
        ]
      )

    assert_raise Postgrex.Error, ~r/check_violation|violated/, fn ->
      Ecto.Migrator.down(Repo, @version, @migration, @options)
    end

    assert columns() == Enum.sort(@columns)
  end

  describe "the checks" do
    test "the run settings are an object of at most 64 KiB", %{run_id: run_id} do
      padding = 65_536 - text_bytes(%{"runtime" => ""})
      at_bound = %{"runtime" => String.duplicate("x", padding)}
      assert text_bytes(at_bound) == 65_536
      assert set(run_id, run_settings: at_bound) == :ok

      assert set(run_id, run_settings: %{"runtime" => String.duplicate("x", padding + 1)}) ==
               "runs_run_settings_check"

      assert set(run_id, run_settings: ["claude"]) == "runs_run_settings_check"
    end

    test "the provider's fields are all set, with run settings, or none is", %{run_id: run_id} do
      assert set(run_id, provider(@api)) == :ok

      for {column, _value} <- provider(@api) -- [run_settings: %{"runtime" => "claude"}] do
        assert set(run_id, Keyword.put(provider(@api), column, nil)) == "runs_provider_check",
               inspect(column)
      end

      assert set(run_id, provider(@api, run_settings: nil)) == "runs_provider_check"
      assert set(run_id, provider(@api, provider_chain: "client")) == "runs_provider_check"
      assert set(run_id, provider(@api, provider_value_id: "Main")) == "runs_provider_check"
    end

    test "the API has a format, an endpoint and an auth, at most 8 KiB", %{run_id: run_id} do
      assert set(run_id, provider(Map.put(@api, "key_prefixes", ["sk-"]))) == :ok

      for missing <- ~w(format endpoint auth) do
        assert set(run_id, provider(Map.delete(@api, missing))) == "runs_provider_api_check",
               missing
      end

      for {member, value} <- [
            {"format", 1},
            {"endpoint", %{"setting" => "address"}},
            {"auth", "bearer"},
            {"key", "sk-ant-0123"},
            {"secret_id", Ecto.UUID.generate()}
          ] do
        assert set(run_id, provider(Map.put(@api, member, value))) ==
                 "runs_provider_api_check",
               member
      end

      assert set(run_id, provider(["anthropic-messages"])) == "runs_provider_api_check"

      padding = 8_192 - text_bytes(%{@api | "endpoint" => ""})
      at_bound = %{@api | "endpoint" => String.duplicate("x", padding)}
      assert text_bytes(at_bound) == 8_192
      assert set(run_id, provider(at_bound)) == :ok

      assert set(run_id, provider(%{@api | "endpoint" => String.duplicate("x", padding + 1)})) ==
               "runs_provider_api_check"
    end
  end
end
