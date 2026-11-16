defmodule ApiaryPro.Deletion.Tables do
  @moduledoc """
  The edition's tables that hold an organisation's rows, in the order the purge deletes
  them (`c:Apiary.Edition.deletion_tables/0`), walked before the core's
  (`Apiary.Deletion.Tables`): the rows of `policy_request_answers` before those of
  `policy_requests`; the organisation's policy, its rules and its row; the organisation's
  variables; the transfers, which name a membership; the feature grants; and the workspace
  access, which names a workspace or a membership, before the core's memberships and
  workspaces it points to; the rows of `operator_invitations` before the core's
  invitations they sit beside; the rows of `operator_harness_assignments`; the
  operators of the organisation's workspaces; and the people locks, then the tenants they
  reference, last. Each is marked `:workspace` when it has `workspace_id`, and
  `:organisation` when it holds the organisation's rows. Nothing writes
  `policy_request_answers`, `policy_requests`, `operator_invitations` and
  `operator_harness_assignments` any more; they stay on the list while they have
  `organisation_id`.

  The rows of other organisations that refer to the one purged go with its row, by their
  keys: rows of `operator_invitations`, by `operator_invitations.operator_id`, and of
  `operator_harness_assignments`, by `operator_harness_assignments.operator_id`. The
  column `tenants.operator_id`, which nothing writes any more, has a key to another
  tenant that takes no action. A row of `workspace_operators` has a key of the same kind to its operator's tenant, so the
  purge of an operator that operates a workspace fails at that key. The
  account suspensions and the instance's branding belong to no organisation, and are not
  listed.
  """

  @tables [
    {"policy_request_answers", :organisation},
    {"policy_requests", :organisation},
    {"organisation_policy_rules", :organisation},
    {"organisation_policies", :organisation},
    {"organisation_variables", :organisation},
    {"transfers", :organisation},
    {"feature_grants", :organisation},
    {"workspace_access", :workspace},
    {"operator_invitations", :organisation},
    {"operator_harness_assignments", :organisation},
    {"workspace_operators", :workspace},
    {"people_locks", :organisation},
    {"tenants", :organisation}
  ]

  @doc "tables/0 is the edition's tables of an organisation's rows, in delete order, marked."
  @spec tables() :: [{String.t(), Apiary.Deletion.Tables.mark()}]
  def tables, do: @tables
end
