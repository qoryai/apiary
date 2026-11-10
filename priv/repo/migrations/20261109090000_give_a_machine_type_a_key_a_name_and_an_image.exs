defmodule Apiary.Repo.Migrations.GiveAMachineTypeAKeyANameAndAnImage do
  use Ecto.Migration

  # `machine_types.name` becomes `key`, with its index and its check: process documents,
  # stages and runs use the key, as they used the name. `name` is then what people see,
  # 1 to 100 characters with no control character (U+0001 to U+001F and U+007F; text has
  # no U+0000) and no line or paragraph separator (U+2028, U+2029): a name the diagnostics
  # contract takes, on one line. Each existing type gets the readable form of its key: the
  # hyphens as spaces and the first letter in upper case, so `standard` is Standard and
  # `large-gpu` is Large gpu. `image` is the image a run on the type starts in, a
  # reference pinned by digest, or null for none; the database checks its length and its
  # digest, and `Apiary.MachineTypes.MachineType` the whole reference.
  #
  # Names are unique ignoring case (`machine_types_name_lower_index`). The readable forms
  # cannot collide: keys are unique, lower case and have no spaces, so the lower case of
  # a readable form, the key with spaces for its hyphens, differs for each key.
  #
  # Every instance gets the type `browser`, with the spec of `standard` and no image,
  # unless a type has the key `browser` already. Its name is Browser tests, else, where
  # another type has that name ignoring case (the type `browser-tests`), Browser tests
  # (browser), which no name derived from a key can be: keys have no parentheses. Where
  # both names were taken, the insert would add no row rather than fail on the index.
  #
  # The table has a few rows, so the update and the new checks scan little.
  def up do
    rename table(:machine_types), :name, to: :key

    execute "ALTER INDEX machine_types_name_index RENAME TO machine_types_key_index"
    drop constraint(:machine_types, :machine_types_name_check)

    create constraint(:machine_types, :machine_types_key_check,
             check: "key ~ '^[a-z][a-z0-9-]{0,63}$' AND key <> 'default'"
           )

    alter table(:machine_types) do
      add :name, :text
      add :image, :text
    end

    execute """
    UPDATE machine_types
    SET name = upper(left(key, 1)) || replace(substr(key, 2), '-', ' ')
    """

    execute "ALTER TABLE machine_types ALTER COLUMN name SET NOT NULL"

    create constraint(:machine_types, :machine_types_name_check,
             check:
               "char_length(name) BETWEEN 1 AND 100 AND name !~ '[\\x01-\\x1f\\x7f\\u2028\\u2029]'"
           )

    create constraint(:machine_types, :machine_types_image_check,
             check:
               "image IS NULL OR (char_length(image) <= 327 AND image ~ '@sha256:[0-9a-f]{64}$')"
           )

    create unique_index(:machine_types, ["lower(name)"], name: :machine_types_name_lower_index)

    execute """
    INSERT INTO machine_types
      (id, key, name, vcpus, memory_mib, disk_gib, arch, virtualization, is_default,
       inserted_at, updated_at)
    SELECT gen_random_uuid(), 'browser', candidate.name, 2, 4096, 30, 'amd64', false, false,
           now(), now()
    FROM (VALUES (1, 'Browser tests'), (2, 'Browser tests (browser)')) AS candidate(rank, name)
    WHERE NOT EXISTS (SELECT 1 FROM machine_types WHERE key = 'browser')
      AND NOT EXISTS (SELECT 1 FROM machine_types WHERE lower(name) = lower(candidate.name))
    ORDER BY candidate.rank
    LIMIT 1
    """
  end

  def down do
    drop index(:machine_types, ["lower(name)"], name: :machine_types_name_lower_index)
    drop constraint(:machine_types, :machine_types_image_check)
    drop constraint(:machine_types, :machine_types_name_check)

    alter table(:machine_types) do
      remove :image
      remove :name
    end

    drop constraint(:machine_types, :machine_types_key_check)
    execute "ALTER INDEX machine_types_key_index RENAME TO machine_types_name_index"
    rename table(:machine_types), :key, to: :name

    create constraint(:machine_types, :machine_types_name_check,
             check: "name ~ '^[a-z][a-z0-9-]{0,63}$' AND name <> 'default'"
           )
  end
end
