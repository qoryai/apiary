defmodule Apiary.Repo.Migrations.KeepTheSubmitModuleAnAdapterDeclares do
  use Ecto.Migration

  # The harness module that contains the submit program of a forge, as the adapter of the
  # forge declares it in its start-up (the integration contract's `adapter.schema.json`,
  # `submit_module`): on an adapter's node (`Apiary.Nodes.Node`), `submit_module`, a JSON
  # object as the start-up has it, which `Apiary.Adapters.Wire.declaration/1` has checked.
  # NULL until a start stores one, where the latest start declares none, and on every
  # other node (`nodes_submit_module_check`).
  #
  # NULL for every row there already, and adding a column with no default rewrites no row.
  # Apiary stores the module at each adapter's next start-up.
  def up do
    alter table(:nodes) do
      add :submit_module, :jsonb
    end

    execute """
    ALTER TABLE nodes ADD CONSTRAINT nodes_submit_module_check CHECK (
      submit_module IS NULL OR (kind = 'adapter' AND jsonb_typeof(submit_module) = 'object')
    )
    """
  end

  def down do
    execute "ALTER TABLE nodes DROP CONSTRAINT nodes_submit_module_check"

    alter table(:nodes) do
      remove :submit_module
    end
  end
end
