defmodule Apiary.Repo.Migrations.IndexTheEscalationOfAMove do
  use Ecto.Migration

  # The index of `gate_decisions.escalation_id` (`20261117090000`), which the deletion of an
  # escalation and the foreign key read. It has the rows that have the column alone: a move
  # that resolves an escalation, a small part of the table.
  #
  # Concurrently, since `gate_decisions` may be large: outside a transaction and without
  # the migration lock, as Postgres requires.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:gate_decisions, [:escalation_id],
             where: "escalation_id IS NOT NULL",
             concurrently: true
           )
  end
end
