defmodule Apiary.Repo.Migrations.CreateNodes do
  use Ecto.Migration

  # A node of a workspace (`Apiary.Nodes`): a place that runs, either one permanent
  # machine (kind `node`, one instance at a time) or a pool of short-lived instances
  # (kind `pool`, up to its instance limit, or any number when the limit is NULL).
  #
  # The workspace is the node's by the composite key, so no row can name a workspace of
  # another organisation. `public_id` is the node's name in URLs: `nd_` for a node or
  # `np_` for a pool, then sixteen lowercase Crockford base32 characters, unique on the
  # instance, as an access key's key id is. The kind is chosen when the node is made and
  # never changes: the check holds the prefix to it, and the trigger refuses an UPDATE
  # that changes it, whatever wrote it. The limit's check holds a node to 1 and a pool to
  # NULL or 1 to 10000.
  #
  # A node is deleted softly (`deleted_at`, `deleted_by_id`): it leaves every page, its
  # name is free again, by the partial unique index, and the row stays for what names it
  # until its workspace is purged. `instance_limit_refused` and its time count the starts
  # refused at the limit, written by an `update_all` outside any changeset. The people are
  # plain references, indexed.
  @public_id "^(nd|np)_[0-9a-hjkmnp-tv-z]{16}$"

  def change do
    create table(:nodes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :public_id, :string, null: false
      add :name, :string, null: false
      add :kind, :string, null: false
      add :instance_limit, :integer
      add :instance_limit_refused, :integer, null: false, default: 0
      add :instance_limit_refused_at, :utc_datetime_usec
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :deleted_at, :utc_datetime_usec
      add :deleted_by_id, references(:users, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:nodes, [:public_id])

    create unique_index(:nodes, [:organisation_id, :workspace_id, :name],
             where: "deleted_at IS NULL",
             name: :nodes_live_name_index
           )

    create index(:nodes, [:organisation_id, :workspace_id])
    create index(:nodes, [:created_by_id])
    create index(:nodes, [:deleted_by_id])

    create constraint(:nodes, :nodes_kind_check, check: "kind IN ('node', 'pool')")

    create constraint(:nodes, :nodes_public_id_check,
             check:
               "public_id ~ '#{@public_id}' AND " <>
                 "(kind = 'node') = (public_id LIKE 'nd\\_%') AND " <>
                 "(kind = 'pool') = (public_id LIKE 'np\\_%')"
           )

    create constraint(:nodes, :nodes_name_check, check: "char_length(name) BETWEEN 1 AND 80")

    create constraint(:nodes, :nodes_instance_limit_check,
             check:
               "(kind = 'node' AND instance_limit IS NOT DISTINCT FROM 1) OR " <>
                 "(kind = 'pool' AND (instance_limit IS NULL OR " <>
                 "instance_limit BETWEEN 1 AND 10000))"
           )

    create constraint(:nodes, :nodes_instance_limit_refused_check,
             check: "instance_limit_refused >= 0"
           )

    create constraint(:nodes, :nodes_deletion_check,
             check: "deleted_by_id IS NULL OR deleted_at IS NOT NULL"
           )

    execute(
      """
      CREATE FUNCTION nodes_kind_is_fixed() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.kind IS DISTINCT FROM OLD.kind THEN
          RAISE EXCEPTION 'a node''s kind is fixed when it is made'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'nodes_kind_fixed';
        END IF;
        RETURN NEW;
      END
      $$
      """,
      "DROP FUNCTION nodes_kind_is_fixed()"
    )

    execute(
      """
      CREATE TRIGGER nodes_kind_fixed BEFORE UPDATE OF kind ON nodes
      FOR EACH ROW EXECUTE FUNCTION nodes_kind_is_fixed()
      """,
      "DROP TRIGGER nodes_kind_fixed ON nodes"
    )
  end
end
