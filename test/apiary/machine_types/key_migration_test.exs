defmodule Apiary.MachineTypes.KeyMigrationTest do
  # The migration that gives a machine type a key, a name and an image, run down and up
  # again inside the test's transaction, which rolls it all back: each row's name of
  # before becomes its key, its name is the key's readable form, and it has no image; an
  # instance with no type of the key `browser` gets one. The suite's instance admin is
  # committed for every test, so each run is on an instance with users. It changes
  # `machine_types` under every other test, so this is not async.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  @migration {20_261_109_090_000, Apiary.Repo.Migrations.GiveAMachineTypeAKeyANameAndAnImage,
              "give_a_machine_type_a_key_a_name_and_an_image"}

  @options [log: false, migration_lock: false]

  setup_all do
    {version, migration, name} = @migration

    if not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  defp rows do
    Repo.all(
      from t in "machine_types",
        order_by: t.key,
        select: {t.key, t.name, t.image, t.is_default, t.vcpus}
    )
  end

  # The migration run down, with today's rows in the shape of before: the seeded default
  # and the types of `names` that an instance admin added.
  defp down_with_rows!(names) do
    {version, migration, _name} = @migration
    :ok = Ecto.Migrator.down(Repo, version, migration, @options)
    Repo.query!("DELETE FROM machine_types WHERE name <> 'standard'")

    for {name, vcpus} <- names do
      Repo.query!(
        "INSERT INTO machine_types (id, name, vcpus, memory_mib, disk_gib, arch, virtualization, is_default, inserted_at, updated_at) VALUES (gen_random_uuid(), $1, $2, 4096, 30, 'amd64', false, false, now(), now())",
        [name, vcpus]
      )
    end
  end

  defp up! do
    {version, migration, _name} = @migration
    :ok = Ecto.Migrator.up(Repo, version, migration, @options)
  end

  test "keeps each name as the key, sets the key's readable form as the name, and no image" do
    # Two keys that differ by a hyphen alone.
    down_with_rows!([{"browser", 2}, {"large-gpu", 8}, {"largegpu", 2}])
    up!()

    # Each key has a different readable form: keys have no spaces, so no two readable forms
    # are the same, ignoring case. The type of the key browser stays as it was, with the
    # name Browser, and the migration adds no other.
    assert rows() == [
             {"browser", "Browser", nil, false, 2},
             {"large-gpu", "Large gpu", nil, false, 8},
             {"largegpu", "Largegpu", nil, false, 2},
             {"standard", "Standard", nil, true, 2}
           ]

    # The key keeps the name's index and check.
    assert_raise Postgrex.Error, ~r/machine_types_key_index/, fn ->
      Repo.transaction(fn -> insert!("largegpu", "Other") end)
    end

    # Names are unique, ignoring case.
    assert_raise Postgrex.Error, ~r/machine_types_name_lower_index/, fn ->
      Repo.transaction(fn -> insert!("other", "LARGE GPU") end)
    end
  end

  test "adds Browser tests to an instance with users, with the spec of standard" do
    down_with_rows!([{"large-gpu", 8}])
    assert Repo.one(from u in "users", select: count()) > 0
    up!()

    assert rows() == [
             {"browser", "Browser tests", nil, false, 2},
             {"large-gpu", "Large gpu", nil, false, 8},
             {"standard", "Standard", nil, true, 2}
           ]

    assert Repo.one(
             from t in "machine_types",
               where: t.key == "browser",
               select: {t.memory_mib, t.disk_gib, t.arch, t.virtualization}
           ) == {4096, 30, "amd64", false}
  end

  test "adds browser as Browser tests (browser) where browser-tests has the name Browser tests" do
    down_with_rows!([{"browser-tests", 4}])
    up!()

    assert rows() == [
             {"browser", "Browser tests (browser)", nil, false, 2},
             {"browser-tests", "Browser tests", nil, false, 4},
             {"standard", "Standard", nil, true, 2}
           ]
  end

  defp insert!(key, name),
    do:
      Repo.query!(
        "INSERT INTO machine_types (id, key, name, vcpus, memory_mib, disk_gib, arch, virtualization, is_default, inserted_at, updated_at) VALUES (gen_random_uuid(), $1, $2, 2, 4096, 30, 'amd64', false, false, now(), now())",
        [key, name]
      )
end
