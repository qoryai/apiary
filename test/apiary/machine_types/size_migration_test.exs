defmodule Apiary.MachineTypes.SizeMigrationTest do
  # The migration that makes a machine type a size, run down and up again inside the
  # test's transaction, which rolls it all back: up drops each type's image and the two
  # columns that kept a run's type image, with their checks and index; every type keeps
  # its key, name and spec, and a run given a type's image keeps `configured_image`. Down
  # adds them back with no data. It changes `machine_types` and `runs` under every other
  # test, so this is not async.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2, type: 2]
  import Apiary.OrganisationsFixtures, only: [sign_up_fixture: 0]
  import Apiary.RunEventsFixtures, only: [run_fixture: 2]

  @migration {20_261_111_090_000, Apiary.Repo.Migrations.MakeAMachineTypeASize,
              "make_a_machine_type_a_size"}

  @options [log: false, migration_lock: false]

  @image "ghcr.io/northwind/agent@sha256:" <> String.duplicate("a", 64)

  setup_all do
    {version, migration, name} = @migration

    if not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  defp down! do
    {version, migration, _name} = @migration
    :ok = Ecto.Migrator.down(Repo, version, migration, @options)
  end

  defp up! do
    {version, migration, _name} = @migration
    :ok = Ecto.Migrator.up(Repo, version, migration, @options)
  end

  defp columns(table) do
    Repo.all(
      from c in "columns",
        prefix: "information_schema",
        where: c.table_schema == "public" and c.table_name == ^table,
        select: {c.column_name, c.is_nullable, c.column_default}
    )
  end

  defp column(table, name), do: Enum.find(columns(table), &(elem(&1, 0) == name))

  defp constraint?(name) do
    Repo.exists?(
      from c in "table_constraints",
        prefix: "information_schema",
        where: c.constraint_schema == "public" and c.constraint_name == ^name
    )
  end

  defp index?(name) do
    Repo.exists?(from i in "pg_indexes", where: i.indexname == ^name)
  end

  defp types do
    Repo.all(
      from t in "machine_types",
        order_by: t.key,
        select: {t.key, t.name, t.vcpus, t.memory_mib, t.disk_gib, t.arch, t.is_default}
    )
  end

  test "up drops each type's image and a run's type image, and keeps every type" do
    %{scope: scope} = sign_up_fixture()
    run = run_fixture(scope, %{configured_image: @image})
    kept = types()
    down!()

    # A type of before with an image, which the up loses, and a run given that image.
    Repo.query!("UPDATE machine_types SET image = $1 WHERE key = 'browser'", [@image])

    Repo.query!(
      """
      UPDATE runs SET configured_image_from_type = true,
        configured_image_machine_type_id = (SELECT id FROM machine_types WHERE key = 'browser')
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(run.id)]
    )

    up!()

    assert types() == kept

    assert Repo.one(
             from r in "runs",
               where: r.id == type(^run.id, :binary_id),
               select: r.configured_image
           ) ==
             @image

    assert column("machine_types", "image") == nil
    assert column("runs", "configured_image_from_type") == nil
    assert column("runs", "configured_image_machine_type_id") == nil
    assert column("runs", "configured_image") != nil
    refute constraint?("machine_types_image_check")
    refute constraint?("runs_configured_image_from_type_check")
    refute constraint?("runs_configured_image_machine_type_id_fkey")
    refute index?("runs_configured_image_machine_type_id_index")
  end

  test "down adds the columns, checks and index back, with no image and no type" do
    down!()

    assert column("machine_types", "image") == {"image", "YES", nil}

    assert {"configured_image_from_type", "NO", "false"} =
             column("runs", "configured_image_from_type")

    assert {_name, "YES", nil} = column("runs", "configured_image_machine_type_id")
    assert constraint?("machine_types_image_check")
    assert constraint?("runs_configured_image_from_type_check")
    assert constraint?("runs_configured_image_machine_type_id_fkey")
    assert index?("runs_configured_image_machine_type_id_index")

    assert Repo.all(from t in "machine_types", where: not is_nil(t.image), select: t.key) == []

    assert Repo.all(from r in "runs", where: r.configured_image_from_type, select: r.id) == []

    # The image check is back: a reference not pinned by digest is refused.
    assert_raise Postgrex.Error, ~r/machine_types_image_check/, fn ->
      Repo.transaction(fn ->
        Repo.query!("UPDATE machine_types SET image = 'northwind/agent:latest'")
      end)
    end
  end
end
