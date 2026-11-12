defmodule ApiaryPro.Deletion.Tables do
  @moduledoc """
  The edition's tables that hold an organisation's rows, in the order the purge
  deletes them (`c:Apiary.Edition.deletion_tables/0`), walked before the core's
  (`Apiary.Deletion.Tables`): a policy request's answers before the request; the
  organisation's policy, its rules and its row; the organisation's variables; the
  transfers, which name a membership; the feature grants; and the workspace access, which
  names a workspace or a membership, before the core's memberships and workspaces it
  points to; an operator's invitations of its clients' first owners before the core's
  invitations they sit beside; an operator's assignments of harness sources to a client;
  and the people locks, then the tenants they reference,
  last. Each is marked `:workspace` when it has `workspace_id`, and `:organisation` when
  it holds the organisation's rows.

  The rows of other organisations that name the one purged go with its row, by their
  keys: an operator's invitations into its former clients, by
  `operator_invitations.operator_id`, and its assignments of harness sources to them, by
  `operator_harness_assignments.operator_id`.
  A client's tenant names its operator's with a key that takes no action, so an operator
  is purged only once it has no clients (`ApiaryPro.Deletion`, `:has_clients`). The
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
    {"people_locks", :organisation},
    {"tenants", :organisation}
  ]

  @doc "tables/0 is the edition's tables of an organisation's rows, in delete order, marked."
  @spec tables() :: [{String.t(), Apiary.Deletion.Tables.mark()}]
  def tables, do: @tables
end
