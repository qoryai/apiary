defmodule Apiary.WorkItems.RecordsMigrationTest do
  # The migration that keeps a take in's answers and confirmation, run down and up again
  # inside the test's transaction, which rolls it all back. It changes
  # `work_item_events` under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.WorkItems.WorkItemEvent

  @records {20_261_018_160_200, Apiary.Repo.Migrations.KeepATakeInSAnswersAndConfirmation,
            "keep_a_take_in_s_answers_and_confirmation"}

  @tables ~w(work_item_answers work_item_confirmations)

  setup_all do
    {version, migration, name} = @records

    unless Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down({version, migration, _name}),
    do: Ecto.Migrator.down(Repo, version, migration, @options)

  defp up!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.up(Repo, version, migration, @options))

  defp tables do
    %{rows: rows} =
      Repo.query!("SELECT table_name FROM information_schema.tables WHERE table_name = ANY($1)", [
        @tables
      ])

    rows |> List.flatten() |> Enum.sort()
  end

  test "down removes the two tables while no event speaks of them; up brings them back" do
    assert tables() == @tables
    assert :ok = down(@records)
    assert tables() == []

    up!(@records)
    assert tables() == @tables
  end

  test "down refuses while an event is answered, confirmed or explore_again, and deletes none" do
    %{scope: scope} = sign_up_fixture()
    work_item = work_item_fixture(scope)

    for kind <- [:answered, :confirmed, :explore_again] do
      event =
        Repo.insert!(%WorkItemEvent{
          organisation_id: work_item.organisation_id,
          workspace_id: work_item.workspace_id,
          work_item_id: work_item.id,
          kind: kind,
          actor_kind: :person,
          actor_id: scope.user.id,
          at: DateTime.utc_now(),
          data: %{}
        })

      # The migration's transaction, a savepoint of the test's, is rolled back.
      assert_raise Postgrex.Error,
                   ~r/this migration rolls back only while no event is of those kinds/,
                   fn -> down(@records) end

      assert tables() == @tables
      assert Repo.get(WorkItemEvent, event.id)
      Repo.delete!(event)
    end
  end
end
