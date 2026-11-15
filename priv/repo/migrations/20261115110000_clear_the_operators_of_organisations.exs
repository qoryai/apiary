defmodule Apiary.Repo.Migrations.ClearTheOperatorsOfOrganisations do
  use Ecto.Migration

  # Clears the data of the earlier model, in which an operator managed whole
  # organisations. An operator relates to workspaces alone (`workspace_operators`),
  # and no code reads these rows:
  #
  # - Every organisation's operator: `tenants.operator_id` and `tenants.operator_since`
  #   become NULL, and `tenants.model_chain` becomes `organisation`, which its check
  #   requires of a row without an operator. While `operator_id` is set, the foreign key
  #   `tenants_operator_fkey` stops the purge of that operator and its change of kind.
  # - The pending invitations sent by an operator (a row in `operator_invitations`):
  #   accepted after this upgrade, one makes a member, not the organisation's owner. The
  #   invitations go, and their `operator_invitations` rows with them.
  #
  # The columns and tables stay. Rolling back changes nothing: the cleared data cannot
  # come back.
  def up do
    execute("""
    UPDATE tenants
    SET operator_id = NULL, operator_since = NULL, model_chain = 'organisation'
    WHERE operator_id IS NOT NULL
    """)

    execute("""
    DELETE FROM invitations
    WHERE accepted_at IS NULL
      AND id IN (SELECT invitation_id FROM operator_invitations)
    """)
  end

  def down, do: :ok
end
