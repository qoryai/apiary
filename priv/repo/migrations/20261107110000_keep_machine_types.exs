defmodule Apiary.Repo.Migrations.KeepMachineTypes do
  use Ecto.Migration

  # `machine_types`: the instance's machine types, which an instance admin keeps in
  # Instance settings › Machine types (`Apiary.MachineTypes`). Each has a name, 1 to 64
  # lower-case letters, digits and hyphens that start with a letter, other than
  # `default`, which means the instance's default type; and a spec, as the provisioner
  # contract's `$defs/machine_spec` bounds it: `vcpus` 1 to 1024, `memory_mib` 512 to
  # 8388608, `disk_gib` 1 to 65536, `arch` `amd64` or `arm64`, and `virtualization`. At
  # most one type is the default, by a unique index on `is_default` where it is true.
  #
  # The instance starts with one type, `standard`, 2 vCPUs, 4 GiB of memory, a 30 GiB
  # disk, amd64 and no virtualization, the default: the machine a pool starts when its
  # claim answer has no machine type.
  def up do
    create table(:machine_types, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :vcpus, :integer, null: false
      add :memory_mib, :integer, null: false
      add :disk_gib, :integer, null: false
      add :arch, :text, null: false
      add :virtualization, :boolean, null: false
      add :is_default, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:machine_types, [:name])

    create unique_index(:machine_types, [:is_default],
             where: "is_default",
             name: :machine_types_one_default_index
           )

    create constraint(:machine_types, :machine_types_name_check,
             check: "name ~ '^[a-z][a-z0-9-]{0,63}$' AND name <> 'default'"
           )

    create constraint(:machine_types, :machine_types_spec_check,
             check:
               "vcpus BETWEEN 1 AND 1024 AND memory_mib BETWEEN 512 AND 8388608 AND " <>
                 "disk_gib BETWEEN 1 AND 65536 AND arch IN ('amd64', 'arm64')"
           )

    execute """
    INSERT INTO machine_types
      (id, name, vcpus, memory_mib, disk_gib, arch, virtualization, is_default,
       inserted_at, updated_at)
    VALUES
      (gen_random_uuid(), 'standard', 2, 4096, 30, 'amd64', false, true, now(), now())
    """
  end

  def down do
    drop table(:machine_types)
  end
end
