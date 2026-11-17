defmodule Apiary.Repo.Migrations.KeepTheDecisionThatAskedForAVersion do
  use Ecto.Migration

  # A person's change to an approved output (vault 0261, 624 (a)): a run stores a new
  # version of it with the id of the person's note that asked for it.
  #
  # `gate_decisions.public_id` (`gd_…`) and `escalations.public_id` (`es_…`) are the ids of
  # the people's notes that the run API lists (`Apiary.Stages.notes/1`): sixteen lowercase
  # Crockford base32 characters after the prefix, 80 random bits, the shape
  # `Apiary.PublicId` makes. `gate_decision_public_id()` and `escalation_public_id()` make
  # one in SQL, as `run_public_id()` does (20261017100000), so that the column's default
  # sets an id on every existing row when the column is added. Their `search_path` is
  # `pg_catalog`, where every function they call is. The stage runner sets the id itself
  # when it writes a row; the default has the same shape. Each id is unique on the
  # instance, and a check keeps its shape.
  #
  # A volatile default rewrites `gate_decisions` and `escalations` under a lock that
  # blocks reads and writes. The unique index and the check are separate statements, and
  # each scans the table again under that lock, which the migration keeps until it
  # commits. `artifact_versions.decision_id` is the id of the note, `gd_…` or `es_…`, nil
  # for none: a nullable column rewrites no row, and its check is added NOT VALID, so it
  # takes no scan under the lock; `20261117140100` validates it. Every stored version has
  # none.
  @tables [gate_decisions: "gd", escalations: "es"]
  @id "[0-9a-hjkmnp-tv-z]{16}"

  def up do
    for {table, prefix} <- @tables do
      execute(function(table, prefix))

      alter table(table) do
        add :public_id, :text, null: false, default: fragment("#{function_name(table)}()")
      end

      create unique_index(table, [:public_id])

      create constraint(table, :"#{table}_public_id_check",
               check: "public_id ~ '^#{prefix}_#{@id}$'"
             )
    end

    alter table(:artifact_versions) do
      add :decision_id, :text
    end

    create constraint(:artifact_versions, :artifact_versions_decision_id_check,
             check: "decision_id IS NULL OR decision_id ~ '^(gd|es)_#{@id}$'",
             validate: false
           )
  end

  # Rolled back, a version loses the decision that asked for it, and a note its id.
  def down do
    drop constraint(:artifact_versions, :artifact_versions_decision_id_check)

    alter table(:artifact_versions) do
      remove :decision_id
    end

    for {table, _prefix} <- @tables do
      drop constraint(table, :"#{table}_public_id_check")
      drop index(table, [:public_id])

      alter table(table) do
        remove :public_id
      end

      execute("DROP FUNCTION #{function_name(table)}()")
    end
  end

  defp function_name(:gate_decisions), do: "gate_decision_public_id"
  defp function_name(:escalations), do: "escalation_public_id"

  defp function(table, prefix) do
    """
    CREATE FUNCTION #{function_name(table)}() RETURNS text LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog AS $$
    DECLARE
      alphabet constant text := '0123456789abcdefghjkmnpqrstvwxyz';
      raw constant bytea := uuid_send(gen_random_uuid());
      bits constant bit(80) :=
        ('x' || encode(substring(raw FROM 1 FOR 6) || substring(raw FROM 11 FOR 4), 'hex'))::bit(80);
      id text := '#{prefix}_';
    BEGIN
      FOR i IN 0..15 LOOP
        id := id || substr(alphabet, substring(bits FROM i * 5 + 1 FOR 5)::integer + 1, 1);
      END LOOP;
      RETURN id;
    END
    $$
    """
  end
end
