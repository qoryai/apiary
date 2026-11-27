defmodule Apiary.Repo.Migrations.KeepHowFarAnAdapterSCredentialReaches do
  use Ecto.Migration

  # How far one credential an adapter answers to a run-credential call reaches, as the
  # source role of its latest start's description says (`credential_scope`, the
  # integration contract's `description.schema.json`): on an adapter's node
  # (`Apiary.Nodes.Node`), `credential_scope`, `resource` (the resources of the call) or
  # `grant` (every resource of the grant). NULL before its first start, and on every
  # other node (`nodes_credential_scope_check`).
  #
  # Adding a column with no default rewrites no row. The check is added NOT VALID, so
  # adding it takes no scan of `nodes` under its lock; the next migration validates it.
  # An adapter's next start stores the value.
  def up do
    alter table(:nodes) do
      add :credential_scope, :text
    end

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_credential_scope_check CHECK (
      credential_scope IS NULL OR (
        kind = 'adapter' AND credential_scope IN ('resource', 'grant')
      )
    ) NOT VALID
    """
  end

  def down do
    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_credential_scope_check"

    alter table(:nodes) do
      remove :credential_scope
    end
  end
end
