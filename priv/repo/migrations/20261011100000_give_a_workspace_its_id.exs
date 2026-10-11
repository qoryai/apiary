defmodule Apiary.Repo.Migrations.GiveAWorkspaceItsId do
  use Ecto.Migration

  # `public_id`, a workspace's id in the server contract: `ws_`, then sixteen lowercase
  # Crockford base32 characters, 80 random bits, the shape `Apiary.PublicId` makes. Discovery
  # lists it as the workspace an access key may name. It is for the contract alone: the
  # URLs name a workspace by its slug, and everything inside Qory Apiary by its id.
  #
  # `workspace_public_id()` makes one in SQL, so that the column's default gives every
  # existing workspace its own id when the column is added, and a row written without one
  # gets one. Its 80 bits are bytes 1 to 6 and 11 to 14 of `gen_random_uuid()`, built into
  # Postgres: the bytes that hold the version and the variant are left out, so every bit
  # is random. They are read five at a time, the most significant first, as
  # `Apiary.PublicId.generate/1` reads its bytes. `Apiary.Organisations.Workspace` sets the
  # id itself on creation; the default is the same shape. The id is unique on the instance,
  # and the check holds its shape, whatever wrote it.
  @public_id "^ws_[0-9a-hjkmnp-tv-z]{16}$"

  def up do
    execute("""
    CREATE FUNCTION workspace_public_id() RETURNS text LANGUAGE plpgsql VOLATILE AS $$
    DECLARE
      alphabet constant text := '0123456789abcdefghjkmnpqrstvwxyz';
      raw constant bytea := uuid_send(gen_random_uuid());
      bits constant bit(80) :=
        ('x' || encode(substring(raw FROM 1 FOR 6) || substring(raw FROM 11 FOR 4), 'hex'))::bit(80);
      id text := 'ws_';
    BEGIN
      FOR i IN 0..15 LOOP
        id := id || substr(alphabet, substring(bits FROM i * 5 + 1 FOR 5)::integer + 1, 1);
      END LOOP;
      RETURN id;
    END
    $$
    """)

    alter table(:workspaces) do
      add :public_id, :string, null: false, default: fragment("workspace_public_id()")
    end

    create unique_index(:workspaces, [:public_id])

    create constraint(:workspaces, :workspaces_public_id_format,
             check: "public_id ~ '#{@public_id}'"
           )
  end

  # Rolled back, the workspaces have no id of their own in the contract again.
  def down do
    drop constraint(:workspaces, :workspaces_public_id_format)
    drop index(:workspaces, [:public_id])

    alter table(:workspaces) do
      remove :public_id
    end

    execute("DROP FUNCTION workspace_public_id()")
  end
end
