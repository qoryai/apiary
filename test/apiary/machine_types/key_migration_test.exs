defmodule Apiary.MachineTypes.KeyMigrationTest do
  # The migration that gives a machine type a key, a name and an image, run down and up
  # again inside the test's transaction, which rolls it all back: each row's name of
  # before becomes its key, and its name is the key's readable form; an instance with no
  # type of the key `browser` gets one. The later migration that drops the image runs down
  # first and up last, as the image it drops is the earlier one's. The suite's instance
  # admin is committed for every test, so each run is on an instance with users. It
  # changes `machine_types` under every other test, so this is not async.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  @migration {20_261_109_090_000, Apiary.Repo.Migrations.GiveAMachineTypeAKeyANameAndAnImage,
              "give_a_machine_type_a_key_a_name_and_an_image"}

  @size {20_261_111_090_000, Apiary.Repo.Migrations.MakeAMachineTypeASize,
         "make_a_machine_type_a_size"}

  @options [log: false, migration_lock: false]

  setup_all do
    for {version, migration, name} <- [@migration, @size],
        not Code.ensure_loaded?(migration) do
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
        select: {t.key, t.name, t.is_default, t.vcpus}
    )
  end

  # The migration run down, with today's rows in the shape of before: the seeded default
  # and the types of `names` that an instance admin added.
  defp down_with_rows!(names) do
    for {version, migration, _name} <- [@size, @migration],
        do: :ok = Ecto.Migrator.down(Repo, version, migration, @options)

    Repo.query!("DELETE FROM machine_types WHERE name <> 'standard'")

    for {name, vcpus} <- names do
      Repo.query!(
        "INSERT INTO machine_types (id, name, vcpus, memory_mib, disk_gib, arch, virtualization, is_default, inserted_at, updated_at) VALUES (gen_random_uuid(), $1, $2, 4096, 30, 'amd64', false, false, now(), now())",
        [name, vcpus]
      )
    end
  end

  defp up! do
    for {version, migration, _name} <- [@migration, @size],
        do: :ok = Ecto.Migrator.up(Repo, version, migration, @options)
  end

  test "keeps each name as the key and sets the key's readable form as the name" do
    # Two keys that differ by a hyphen alone.
    down_with_rows!([{"browser", 2}, {"large-gpu", 8}, {"largegpu", 2}])
    up!()

    # Each key has a different readable form: keys have no spaces, so no two readable forms
    # are the same, ignoring case. The type of the key browser stays as it was, with the
    # name Browser, and the migration adds no other.
    assert rows() == [
             {"browser", "Browser", false, 2},
             {"large-gpu", "Large gpu", false, 8},
             {"largegpu", "Largegpu", false, 2},
             {"standard", "Standard", true, 2}
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
             {"browser", "Browser tests", false, 2},
             {"large-gpu", "Large gpu", false, 8},
             {"standard", "Standard", true, 2}
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
             {"browser", "Browser tests (browser)", false, 2},
             {"browser-tests", "Browser tests", false, 4},
             {"standard", "Standard", true, 2}
           ]
  end

  defp insert!(key, name),
    do:
      Repo.query!(
        "INSERT INTO machine_types (id, key, name, vcpus, memory_mib, disk_gib, arch, virtualization, is_default, inserted_at, updated_at) VALUES (gen_random_uuid(), $1, $2, 2, 4096, 30, 'amd64', false, false, now(), now())",
        [key, name]
      )
end
