defmodule Apiary.Features.SavedRacesTest do
  # Two saves of the instance's features from the same read, each on a separate connection
  # outside the SQL sandbox (`Apiary.Races`): the second waits on the row lock the first
  # holds, and once the first commits, finds the version it wrote and saves nothing
  # (`Apiary.Features.Saved.save/3`). Not async: the saved list, the node's copy and the
  # variable's value are the whole node's, and what the test commits is put back on exit.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{Edition, Repo}
  alias Apiary.Audit.Entry
  alias Apiary.Features.Saved
  alias Apiary.Features.Saved.Row
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :feature_sets

  setup_all :clean_up_leftovers
  setup_all :reset_saved_features
  setup :setup_races

  # A run stopped before its `on_exit` leaves the instance's row with a saved list and a
  # raised version, and its trail entries. No other test commits them, so the columns go
  # back to their defaults, no list saved, and the entries are deleted.
  defp reset_saved_features(_context) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    Repo.update_all(from(r in Row, where: r.id == true),
      set: [features: nil, features_seen: [], features_version: 0]
    )

    Repo.delete_all(from e in Entry, where: e.action == "instance.features_save")
    Sandbox.checkin(Repo)
    :ok
  end

  setup do
    for key <- [:features, :features_setting, :installed_adapters, :registry_setting] do
      before = Application.fetch_env(:apiary, key)

      on_exit(fn ->
        case before do
          {:ok, value} -> Application.put_env(:apiary, key, value)
          :error -> Application.delete_env(:apiary, key)
        end
      end)
    end

    Application.put_env(:apiary, :features_setting, nil)
    Application.put_env(:apiary, :installed_adapters, [])
    Application.put_env(:apiary, :registry_setting, nil)

    started = database_now()
    before = Repo.get(Row, true)

    # Registered after the setup of `Apiary.Races`, so it runs before that one, which
    # deletes the instance's row where the test began without one.
    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      if before do
        Repo.update_all(from(r in Row, where: r.id == true),
          set: [
            features: before.features,
            features_seen: before.features_seen,
            features_version: before.features_version
          ]
        )
      end

      Repo.delete_all(
        from e in Entry,
          where: e.organisation_id == ^Edition.instance_organisation_id(),
          where: e.action == "instance.features_save",
          where: e.inserted_at >= ^started
      )

      Sandbox.checkin(Repo)
    end)

    %{admin: Apiary.OrganisationsFixtures.instance_admin_scope(), started: started}
  end

  test "of two saves from the same read, the second waits on the first's lock, then is stale",
       %{admin: admin, started: started} do
    # The instance's row exists before the race, so the second save waits on the row lock
    # and not on the first's insert of the row.
    Repo.insert_all("instance_settings", [%{id: true, updated_at: DateTime.utc_now()}],
      on_conflict: :nothing,
      conflict_target: :id
    )

    %{features: features, version: version} = Saved.current()
    assert :path_rules in features and :workflow_model in features

    {first, first_backend} =
      hold(fn -> Saved.save(admin, features -- [:path_rules], version) end)

    assert {:ok, %{version: written}} = first.result
    assert written == version + 1

    second = start(fn -> Saved.save(admin, features -- [:workflow_model], version) end)
    await_blocked(second.backend, first_backend)
    commit(first)

    assert Task.await(second.task) == {:error, :stale}

    assert %{features: saved, version: ^written} = Saved.current()
    refute :path_rules in saved
    assert :workflow_model in saved

    assert Repo.aggregate(
             from(e in Entry,
               where: e.action == "instance.features_save" and e.inserted_at >= ^started
             ),
             :count
           ) == 1
  end
end
