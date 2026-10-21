defmodule Apiary.Repo.Migrations.GiveARunItsId do
  use Ecto.Migration

  # `public_id`, the id Qory Apiary gives a run: `rn_`, then sixteen lowercase Crockford
  # base32 characters, 80 random bits, the shape `Apiary.PublicId` makes. The console names
  # and addresses a run by it, `/:org/:workspace/runs/rn_…`. `run_id`, the run's id as the
  # node gave it, stays the run's subject in the server contract.
  #
  # `run_public_id()` makes one in SQL, as `workspace_public_id()` does for a workspace
  # (20261011100000), so that the column's default gives every existing run an id when the
  # column is added, and a row written without one gets one. Its 80 bits are bytes 1 to 6
  # and 11 to 14 of `gen_random_uuid()`, built into Postgres: the bytes that hold the
  # version and the variant are left out, so every bit is random. They are read five at a
  # time, the most significant first, as `Apiary.PublicId.generate/1` reads its bytes. Its
  # `search_path` is `pg_catalog`, where every function it calls is, whatever the
  # `search_path` of the session that calls it (20261011120000). `Apiary.Runs.Ingest` and
  # `Apiary.Runs.Registration` set the id themselves when they create a run; the default is
  # the same shape. The id is unique on the instance, and the check holds its shape,
  # whatever wrote it.
  @public_id "^rn_[0-9a-hjkmnp-tv-z]{16}$"

  def up do
    execute("""
    CREATE FUNCTION run_public_id() RETURNS text LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog AS $$
    DECLARE
      alphabet constant text := '0123456789abcdefghjkmnpqrstvwxyz';
      raw constant bytea := uuid_send(gen_random_uuid());
      bits constant bit(80) :=
        ('x' || encode(substring(raw FROM 1 FOR 6) || substring(raw FROM 11 FOR 4), 'hex'))::bit(80);
      id text := 'rn_';
    BEGIN
      FOR i IN 0..15 LOOP
        id := id || substr(alphabet, substring(bits FROM i * 5 + 1 FOR 5)::integer + 1, 1);
      END LOOP;
      RETURN id;
    END
    $$
    """)

    alter table(:runs) do
      add :public_id, :text, null: false, default: fragment("run_public_id()")
    end

    create unique_index(:runs, [:public_id])

    create constraint(:runs, :runs_public_id_format, check: "public_id ~ '#{@public_id}'")
  end

  # Rolled back, a run is named by its subject alone again.
  def down do
    drop constraint(:runs, :runs_public_id_format)
    drop index(:runs, [:public_id])

    alter table(:runs) do
      remove :public_id
    end

    execute("DROP FUNCTION run_public_id()")
  end
end
