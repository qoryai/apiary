defmodule Apiary.Repo.Migrations.GiveATargetItsId do
  use Ecto.Migration

  # `public_id`, the id Qory Apiary gives a target: `tg_`, then sixteen lowercase Crockford
  # base32 characters, 80 random bits, the shape `Apiary.PublicId` makes. A target's page
  # is addressed by it, `/:org/:workspace/targets/tg_…`. The target's `system` and `path`
  # stay what they are, the labels Forager sent, named after the system they come from.
  #
  # `target_public_id()` makes one in SQL, as `workspace_public_id()` does (20261011100000),
  # so that the column's default gives every existing target an id when the column is
  # added, and a row written without one gets one. Its 80 bits are bytes 1 to 6 and 11 to
  # 14 of `gen_random_uuid()`: the bytes that hold the version and the variant are left
  # out, so every bit is random. They are read five at a time, the most significant first,
  # as `Apiary.PublicId.generate/1` reads its bytes. Its `search_path` is `pg_catalog`, where
  # every function it calls is (20261011120000), whatever the `search_path` of the session
  # that calls it. The projector sets the id itself when it creates a target; the default
  # is the same shape. The id is unique on the instance, and the check holds its shape,
  # whatever wrote it.
  @public_id "^tg_[0-9a-hjkmnp-tv-z]{16}$"

  def up do
    execute("""
    CREATE FUNCTION target_public_id() RETURNS text LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog AS $$
    DECLARE
      alphabet constant text := '0123456789abcdefghjkmnpqrstvwxyz';
      raw constant bytea := uuid_send(gen_random_uuid());
      bits constant bit(80) :=
        ('x' || encode(substring(raw FROM 1 FOR 6) || substring(raw FROM 11 FOR 4), 'hex'))::bit(80);
      id text := 'tg_';
    BEGIN
      FOR i IN 0..15 LOOP
        id := id || substr(alphabet, substring(bits FROM i * 5 + 1 FOR 5)::integer + 1, 1);
      END LOOP;
      RETURN id;
    END
    $$
    """)

    alter table(:targets) do
      add :public_id, :text, null: false, default: fragment("target_public_id()")
    end

    create unique_index(:targets, [:public_id])

    create constraint(:targets, :targets_public_id_format, check: "public_id ~ '#{@public_id}'")
  end

  # Rolled back, a target has no id but its row's again.
  def down do
    drop constraint(:targets, :targets_public_id_format)
    drop index(:targets, [:public_id])

    alter table(:targets) do
      remove :public_id
    end

    execute("DROP FUNCTION target_public_id()")
  end
end
