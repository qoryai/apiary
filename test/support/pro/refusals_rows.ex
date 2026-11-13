defmodule ApiaryProWeb.RefusalsRows do
  @moduledoc """
  RefusalsRows is the edition's rows of the refusals test (`ApiaryWeb.RefusalsCase`),
  sent after the core's (`ApiaryWeb.RefusalsRows`), in the core's world: every change
  the edition's pages offer, the edition's actions, and what the edition's actors may not
  change on the core's pages. The actors, besides the core's:

      stale_member   a member whose page was opened while they reached the workspace, and
                     who was removed from it before the event
      elsewhere      a member added to another workspace of the organisation only, on that
                     workspace's pages, sending ids of this one
      operator_owner, operator_admin, operator_member
                     an owner, an admin and a member of an operator: on its Clients page,
                     and in its client, which they read and change nothing in
      client_owner   the owner of that client, on the operator's pages, which their
                     membership in the client does not reach
      client_admin, client_member
                     an admin and a member of that client, in it, and on the operator's
                     pages
      client_unplaced
                     a member of that client added to no workspace of it
      instance_admin an owner of the instance organisation: on the Instance settings pages, and
                     reading the organisation, which they reach only as one, read-only
      revoked_instance_admin
                     an instance admin who had an Instance settings page open, and who was made a
                     member of the instance organisation before the event
      io_admin, io_member
                     an admin and a member of the instance organisation, on its instance
                     page

  The world adds to the core's: the instance organisation with an instance admin, an admin
  and a member; an operator made one by that instance admin, with an admin, a member and a
  client, and the client's owner, whom the operator invited, an admin, a member and a
  member added to no workspace of the client's own; with the security policy, a second
  client, and a request of the operator's to both, pending in each.
  """

  @behaviour ApiaryWeb.RefusalsCase

  import Ecto.Query
  import Apiary.AccountsFixtures, only: [user_fixture: 0]
  import Apiary.OrganisationsFixtures

  alias Apiary.{Organisations, Policy, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Membership
  alias ApiaryPro.{Operators, WorkspaceAccess}
  alias ApiaryWeb.RefusalsCase

  @impl true
  def actors do
    [
      :stale_member,
      :elsewhere,
      :operator_owner,
      :operator_admin,
      :operator_member,
      :client_owner,
      :client_admin,
      :client_member,
      :client_unplaced,
      :instance_admin,
      :revoked_instance_admin,
      :io_admin,
      :io_member
    ]
  end

  @impl true
  def rows, do: organisation_rows() ++ key_rows() ++ in_client_rows() ++ instance_rows()

  defp organisation_rows do
    [
      # A member's workspaces are a page of their own, which a member does not open.
      {:"workspace_access.add", :member, "/:org/settings/people/:other_member/workspaces",
       "add_workspace", %{"workspace" => :workspace_b_id}, answer: :refused_at_mount},
      {:"workspace_access.add", :demoted_admin, "/:org/settings/people/:other_member/workspaces",
       "add_workspace", %{"workspace" => :workspace_b_id}},
      # An admin acting on an admin: the member of the open page made one meanwhile.
      {:"workspace_access.add", :admin, "/:org/settings/people/:other_member/workspaces",
       "add_workspace", %{"workspace" => :workspace_b_id},
       meanwhile: {:level, :other_member, :admin}},
      {:"workspace_access.remove", :member, "/:org/settings/people/:other_member/workspaces",
       "remove_workspace", %{"workspace" => :workspace_id}, answer: :refused_at_mount},
      {:"workspace_access.remove", :demoted_admin,
       "/:org/settings/people/:other_member/workspaces", "remove_workspace",
       %{"workspace" => :workspace_id}},

      # An instance admin cannot open a member's suspension, so their `suspend` arrives
      # without it and the page refuses it for their role.
      {:"member.suspend", :instance_admin, "/:org/settings/people", "suspend", %{}},
      {:"member.activate", :instance_admin, "/:org/settings/people", "activate",
       %{"id" => :other_member}},

      # The ownership, a tab of the organisation's settings: an owner offers and
      # withdraws, and only the admin an offer names accepts it. A reader for whom the
      # section is not listed is sent to General as the page opens.
      {:"organisation.transfer", :admin, "/:org/settings/ownership", "offer_to_operator",
       %{"transfer" => %{"operator_slug" => :operator}},
       answer: :refused_at_mount, needs: :managed_organisations},
      {:"organisation.transfer", :demoted_owner, "/:org/settings/ownership", "offer_to_operator",
       %{"transfer" => %{"operator_slug" => :operator}}, needs: :managed_organisations},
      # A client is offered to no other operator: it leaves its own first.
      {:"organisation.transfer", :client_owner, "/:client/settings/ownership",
       "offer_to_operator", %{"transfer" => %{"operator_slug" => :operator}},
       needs: :managed_organisations},
      {:"organisation.transfer", :instance_admin, "/:org/settings/ownership", "offer_to_operator",
       %{"transfer" => %{"operator_slug" => :operator}},
       answer: :refused_at_mount, needs: :managed_organisations},
      # With an offer pending: the organisation's to the operator, and the arbiter's of
      # the client to an admin of it other than the one who tries.
      {:"organisation.withdraw_transfer", :admin, "/:org/settings/ownership", "withdraw_transfer",
       %{},
       setup: :offered_to_operator, answer: :refused_at_mount, needs: :managed_organisations},
      {:"organisation.accept_transfer", :admin, "/:org/settings/ownership", "accept_transfer",
       %{},
       setup: :offered_to_operator, answer: :refused_at_mount, needs: :managed_organisations},
      # The arbiter's offer, made to another admin of the organisation.
      {:"organisation.accept_transfer", :admin, "/:org/settings/ownership", "accept_transfer",
       %{}, setup: :arbitrated_to_another_admin, answer: :refused_at_mount},
      {:"organisation.accept_transfer", :client_admin, "/:client/settings/ownership",
       "accept_transfer", %{}, setup: :client_arbitrated, needs: :managed_organisations},

      # Leaving an operator: the client's owners', neither its admins' and members' nor the
      # operator's people's, the operator's name typed all the same.
      {:"organisation.leave_operator", :client_admin, "/:client/settings/ownership",
       "leave_operator", %{"confirm" => %{"name" => :operator_name}},
       needs: :managed_organisations},
      {:"organisation.leave_operator", :client_member, "/:client/settings/ownership",
       "leave_operator", %{"confirm" => %{"name" => :operator_name}},
       needs: :managed_organisations},
      {:"organisation.leave_operator", :client_admin, "/:client/settings/ownership/leave",
       "leave_operator", %{"confirm" => %{"name" => :operator_name}},
       answer: :refused_at_mount, needs: :managed_organisations},
      {:"organisation.leave_operator", :operator_owner, "/:client/settings/ownership",
       "leave_operator", %{"confirm" => %{"name" => :operator_name}},
       needs: :managed_organisations},

      # A member who no longer reaches the workspace, and one of another workspace
      # carrying the ids of this one.
      {:"security_policy.edit", :stale_member, "/:org/:workspace/policy/rules/new", "rule_save",
       %{}, prelude: [{"rule_validate", %{"rule" => %{"host" => "new.example", "paths" => ""}}}]},
      {:"security_policy.edit", :elsewhere, "/:org/:workspace_b/policy", "remove",
       %{"id" => :rule_open}, answer: :not_found},
      {:"security_policy.edit", :elsewhere, "/:org/:workspace_b/policy", "change_action",
       %{"id" => :rule_open}, answer: :not_found},
      {:"security_policy.edit", :elsewhere, "/:org/:workspace_b/targets/:target_page_b/policy",
       "row_act", %{"id" => :rule_open, "act" => "disable"}, answer: :not_found},
      # A node's page is its path: another workspace's node is a 404 as the page opens.
      {:"node.edit", :elsewhere, "/:org/:workspace_b/machines/:node/settings", "save",
       %{"node" => %{"name" => "renamed"}}, answer: :not_found_at_mount},
      {:"node.set_limit", :elsewhere, "/:org/:workspace_b/machines/:pool/settings", "save",
       %{"node" => %{"instance_limit" => "3"}}, answer: :not_found_at_mount},
      {:"node.delete", :elsewhere, "/:org/:workspace_b/machines/:node/settings/delete", "delete",
       %{}, answer: :not_found_at_mount},
      {:"node.clear_instance", :elsewhere,
       "/:org/:workspace_b/machines/:node/instances/:instance/clear", "clear_instance", %{},
       answer: :not_found_at_mount},

      # An operator's clients.
      {:"client.create", :operator_member, "/:operator/clients", "create",
       %{"organisation" => %{"name" => "Sneaky", "email" => "owner@example.com"}}},
      # The page's path refuses as it opens; the row above is the event's refusal.
      {:"client.create", :operator_member, "/:operator/clients/new", "create",
       %{"organisation" => %{"name" => "Sneaky", "email" => "owner@example.com"}},
       answer: :refused_at_mount},
      # A person of a client, on its operator's page and on the client's own: neither is
      # theirs to open.
      {:"client.create", :client_admin, "/:operator/clients", "create",
       %{"organisation" => %{"name" => "Sneaky", "email" => "owner@example.com"}},
       answer: :not_found_at_mount},
      {:"client.create", :client_admin, "/:client/clients", "create",
       %{"organisation" => %{"name" => "Sneaky", "email" => "owner@example.com"}},
       answer: :not_found_at_mount},

      # A new organisation of a person's own, from the switcher's entry: of a kind whose
      # sign-up setting is closed, the suite's operators, whatever the form says. With both
      # settings closed the entry, the button and the page are not there, and the event is
      # refused too: that needs the node's settings changed, which this test cannot, and
      # is in `test/apiary_pro_web/live/user_live/new_organisation_test.exs`.
      {:"organisation.create", :member, "/users/organisations/new", "create",
       %{"organisation" => %{"name" => "Sneaky", "kind" => "operator"}}},
      {:"organisation.create", :owner, "/users/organisations/new", "create",
       %{"organisation" => %{"name" => "Sneaky", "kind" => "operator"}}},
      {:"organisation.create", :instance_admin, "/users/organisations/new", "create",
       %{"organisation" => %{"name" => "Sneaky", "kind" => "instance_organisation"}}},

      # The first owner of a client: invited by the operator's owners and admins while the
      # client has none; this one has an owner, who invites its people.
      {:"client.invite_owner", :operator_member, "/:operator/clients", "invite_owner",
       %{"client_id" => :client_id, "owner" => %{"email" => "owner@example.com"}}},
      {:"client.invite_owner", :operator_member, "/:operator/clients/:client_id/owner",
       "invite_owner", %{"client_id" => :client_id, "owner" => %{"email" => "owner@example.com"}},
       answer: :refused_at_mount},
      {:"client.invite_owner", :operator_owner, "/:operator/clients/:client_id/owner",
       "invite_owner",
       %{"client_id" => :client_id, "owner" => %{"email" => "owner@example.com"}}},

      # The first admin's invitation, not found while the operator does not own its
      # clients: its page, and each event, as for a client that is not there.
      {:"client.invite_admin", :operator_owner, "/:operator/clients/:client_id/admin",
       "invite_admin", %{"client_id" => :client_id, "owner" => %{"email" => "admin@example.com"}},
       answer: :not_found_at_mount},
      {:"client.invite_admin", :operator_owner, "/:operator/clients", "invite_admin",
       %{"client_id" => :client_id, "owner" => %{"email" => "admin@example.com"}},
       answer: :not_found},
      {:"client.revoke_admin_invitation", :operator_owner, "/:operator/clients",
       "revoke_admin_invitation", %{"client" => :client_id, "id" => :client_id},
       answer: :not_found},
      {:"client.renew_admin_invitation", :operator_owner, "/:operator/clients",
       "renew_admin_invitation", %{"client" => :client_id, "id" => :client_id},
       answer: :not_found},

      # Dropping a client: the operator's owners', neither its admins' nor its members',
      # the client's name typed all the same; the client's owner does not reach the
      # operator.
      {:"client.drop", :operator_admin, "/:operator/clients", "drop_client",
       %{"client_id" => :client_id, "confirm" => %{"name" => :client_name}}},
      {:"client.drop", :operator_member, "/:operator/clients", "drop_client",
       %{"client_id" => :client_id, "confirm" => %{"name" => :client_name}}},
      {:"client.drop", :operator_admin, "/:operator/clients/:client_id/drop", "drop_client",
       %{"client_id" => :client_id, "confirm" => %{"name" => :client_name}},
       answer: :refused_at_mount},
      {:"client.drop", :client_owner, "/:operator/clients", "drop_client",
       %{"client_id" => :client_id, "confirm" => %{"name" => :client_name}},
       answer: :not_found_at_mount},

      # A client's first owner's invitation, revoked while it has no owner: the operator's
      # owners' and admins'; the world's client has an owner, whose invitations are its
      # own.
      {:"client.revoke_owner_invitation", :operator_member, "/:operator/clients",
       "revoke_owner_invitation", %{"client" => :client_id, "id" => :client_id}},
      {:"client.revoke_owner_invitation", :operator_owner, "/:operator/clients",
       "revoke_owner_invitation", %{"client" => :client_id, "id" => :client_id}},

      # A new link for a client's first owner's invitation, while it has no owner: the
      # operator's owners' and admins'; the world's client has an owner, whose invitations
      # are its own.
      {:"client.renew_owner_invitation", :operator_member, "/:operator/clients",
       "renew_owner_invitation", %{"client" => :client_id, "id" => :client_id}},
      {:"client.renew_owner_invitation", :operator_owner, "/:operator/clients",
       "renew_owner_invitation", %{"client" => :client_id, "id" => :client_id}},

      # A client with no owner yet is deleted by the operator's owners, never by its
      # admins or members; the world's client has an owner, so it is dropped, not deleted.
      {:"client.delete", :operator_admin, "/:operator/clients", "delete_client",
       %{"client_id" => :client_id, "confirm" => %{"name" => :client_name}}},
      {:"client.delete", :operator_member, "/:operator/clients", "delete_client",
       %{"client_id" => :client_id, "confirm" => %{"name" => :client_name}}},
      {:"client.delete", :operator_admin, "/:operator/clients/:client_id/delete", "delete_client",
       %{"client_id" => :client_id, "confirm" => %{"name" => :client_name}},
       answer: :refused_at_mount},
      {:"client.delete", :operator_owner, "/:operator/clients", "delete_client",
       %{"client_id" => :client_id, "confirm" => %{"name" => :client_name}}},

      # An organisation offered to the operator, and a client's features: an owner's of it.
      {:"client.accept", :operator_member, "/:operator/clients", "accept_client",
       %{"id" => :organisation_id}},
      {:"client.accept", :operator_member, "/:operator/clients/offers/:organisation_id/accept",
       "accept_client", %{"id" => :organisation_id}, answer: :refused_at_mount},
      # A suspended client is granted nothing, by its operator's owner either.
      {:"client.grant_features", :operator_owner, "/:operator/clients", "save_client_features",
       %{"client_id" => :client_id, "features" => %{"observability" => "true"}},
       setup: :client_suspended},
      {:"client.grant_features", :operator_member, "/:operator/clients", "save_client_features",
       %{"client_id" => :client_id, "features" => %{"observability" => "true"}}},
      {:"client.grant_features", :operator_member, "/:operator/clients/:client_id/features",
       "save_client_features",
       %{"client_id" => :client_id, "features" => %{"observability" => "true"}},
       answer: :refused_at_mount},

      # An operator's policy requests: sent and withdrawn by its owners and admins, never
      # its members; the new request's path refuses as it opens.
      {:"policy_request.send", :operator_member, "/:operator/clients/requests", "send",
       %{"request" => %{"note" => "Sneaky", "mode" => "enforce"}},
       needs: [:managed_organisations, :security]},
      {:"policy_request.send", :operator_member, "/:operator/clients/requests/new", "send",
       %{"request" => %{"note" => "Sneaky", "mode" => "enforce"}},
       answer: :refused_at_mount, needs: [:managed_organisations, :security]},
      {:"policy_request.withdraw", :operator_member, "/:operator/clients/requests", "withdraw",
       %{"id" => :request_id}, needs: [:managed_organisations, :security]},
      # Its withdrawal is asked on the request's row, at a path of its own that refuses as
      # it opens.
      {:"policy_request.withdraw", :operator_member,
       "/:operator/clients/requests/:request_id/withdraw", "withdraw", %{"id" => :request_id},
       answer: :refused_at_mount, needs: [:managed_organisations, :security]},

      # Answered in the client by whoever writes its policy: every level of the client has
      # `security_policy.edit`, so no level of it is refused for want of it. Never by the
      # operator's people, who read the client; never another client's request, which is
      # not found; a locked rule is an owner's at acceptance too; and a workspace of
      # another organisation is refused, whatever the answer.
      {:"policy_request.accept", :operator_owner, "/:client/policy-requests", "accept",
       %{"answer_id" => :client_answer, "workspaces" => [:client_workspace_id]},
       needs: [:managed_organisations, :security]},
      {:"policy_request.accept", :operator_member, "/:client/policy-requests", "accept",
       %{"answer_id" => :client_answer, "workspaces" => [:client_workspace_id]},
       needs: [:managed_organisations, :security]},
      {:"policy_request.accept", :client_admin, "/:client/policy-requests", "accept",
       %{"answer_id" => :client_b_answer, "workspaces" => [:client_workspace_id]},
       answer: :not_found, needs: [:managed_organisations, :security]},
      {:"policy_request.accept", :client_admin, "/:client/policy-requests", "accept",
       %{"answer_id" => :client_answer, "workspaces" => [:client_workspace_id]},
       needs: [:managed_organisations, :security]},
      {:"policy_request.accept", :client_owner, "/:client/policy-requests", "accept",
       %{"answer_id" => :client_answer, "workspaces" => [:workspace_id]},
       needs: [:managed_organisations, :security]},
      {:"policy_request.decline", :operator_admin, "/:client/policy-requests", "decline",
       %{"answer_id" => :client_answer, "decline" => %{"reason" => "Sneaky"}},
       needs: [:managed_organisations, :security]},
      {:"policy_request.decline", :client_admin, "/:client/policy-requests", "decline",
       %{"answer_id" => :client_b_answer, "decline" => %{"reason" => "Sneaky"}},
       answer: :not_found, needs: [:managed_organisations, :security]},
      # A member of the client added to no workspace of it may write the policy nowhere,
      # so answers nothing: an answer is the whole client's.
      {:"policy_request.decline", :client_unplaced, "/:client/policy-requests", "decline",
       %{"answer_id" => :client_answer, "decline" => %{"reason" => "Sneaky"}},
       needs: [:managed_organisations, :security]},
      {:"policy_request.accept", :client_unplaced, "/:client/policy-requests", "accept",
       %{"answer_id" => :client_answer, "workspaces" => [:client_workspace_id]},
       needs: [:managed_organisations, :security]},
      # A decline is asked on the request's row, at a path of its own that refuses as it
      # opens a person who answers nothing.
      {:"policy_request.decline", :operator_owner,
       "/:client/policy-requests/:client_answer/decline", "decline",
       %{"answer_id" => :client_answer, "decline" => %{"reason" => "Sneaky"}},
       answer: :refused_at_mount, needs: [:managed_organisations, :security]},
      {:"policy_request.decline", :client_unplaced,
       "/:client/policy-requests/:client_answer/decline", "decline",
       %{"answer_id" => :client_answer, "decline" => %{"reason" => "Sneaky"}},
       answer: :refused_at_mount, needs: [:managed_organisations, :security]},

      # The organisation's policy: read by its owners, admins and readers, changed by its
      # owners alone. A member does not open the page; an admin, an instance admin and an
      # owner demoted while the page is open are refused each change; the people of a
      # client's operator read it there and change nothing. Those rows need the managed
      # organisations as well as the organisation's policy, and a row names one feature:
      # they name the policy's, which the wall and the record leaves out while it has the
      # managed organisations, and no instance CI makes has without them.
      {:"organisation_policy.edit", :member, "/:org/policy/rules/new", "rule_save", %{},
       answer: :not_found_at_mount},
      # An admin is sent back from New rule as it opens, and a save they make by hand on the
      # list is refused.
      {:"organisation_policy.edit", :admin, "/:org/policy/rules/new", "rule_save", %{},
       answer: :refused_at_mount},
      {:"organisation_policy.edit", :admin, "/:org/policy", "rule_save", %{},
       prelude: [{"rule_validate", %{"rule" => %{"host" => "new.example", "paths" => ""}}}]},
      {:"organisation_policy.edit", :admin, "/:org/policy", "remove", %{"id" => :org_rule}},
      {:"organisation_policy.edit", :admin, "/:org/policy", "change_action",
       %{"id" => :org_rule}},
      {:"organisation_policy.edit", :demoted_owner, "/:org/policy/rules/new", "rule_save", %{},
       prelude: [{"rule_validate", %{"rule" => %{"host" => "new.example", "paths" => ""}}}]},
      {:"organisation_policy.edit", :demoted_owner, "/:org/policy", "remove",
       %{"id" => :org_rule}},
      {:"organisation_policy.edit", :instance_admin, "/:org/policy", "rule_save", %{},
       prelude: [{"rule_validate", %{"rule" => %{"host" => "new.example", "paths" => ""}}}]},
      {:"organisation_policy.edit", :operator_owner, "/:client/policy", "rule_save", %{},
       prelude: [{"rule_validate", %{"rule" => %{"host" => "new.example", "paths" => ""}}}],
       needs: :organisation_policy},
      {:"organisation_policy.set_floor", :admin, "/:org/policy", "mode_open", %{}},
      {:"organisation_policy.set_floor", :admin, "/:org/policy", "mode_set", %{}},
      {:"organisation_policy.set_floor", :demoted_owner, "/:org/policy", "mode_set", %{},
       prelude: [{"mode_open", %{}}, {"mode_pick", %{"mode" => "enforce"}}]},
      {:"organisation_policy.set_floor", :instance_admin, "/:org/policy", "mode_open", %{}},
      {:"organisation_policy.set_floor", :operator_owner, "/:client/policy", "mode_open", %{},
       needs: :organisation_policy},
      {:"organisation_policy.set_switch", :admin, "/:org/policy", "switch_ask", %{}},
      {:"organisation_policy.set_switch", :demoted_owner, "/:org/policy", "setting_confirm", %{},
       prelude: [{"switch_ask", %{}}]},
      {:"organisation_policy.set_switch", :instance_admin, "/:org/policy", "switch_ask", %{}},
      {:"organisation_policy.set_switch", :operator_owner, "/:client/policy", "switch_ask", %{},
       needs: :organisation_policy},

      # The organisation's variables, the Variables tab of its settings' Secrets and
      # variables: read by its owners, admins and readers, changed by its owners and
      # admins. A member does not open the page; an admin demoted while a page or a
      # confirmation is open, and an instance admin, who reads them, are refused each
      # change.
      {:"organisation_variable.edit", :member, "/:org/settings/variables", "create_variable",
       %{"variable" => %{"name" => "SNEAKY", "value" => "x"}}, answer: :not_found_at_mount},
      {:"organisation_variable.edit", :demoted_admin, "/:org/settings/variables/new",
       "create_variable", %{"variable" => %{"name" => "SNEAKY", "value" => "x"}}},
      {:"organisation_variable.edit", :demoted_admin,
       "/:org/settings/variables/:org_variable/change", "change_variable",
       %{"variable" => %{"value" => "changed"}}},
      {:"organisation_variable.edit", :demoted_admin,
       "/:org/settings/variables/:org_variable/lock", "lock_variable", %{}},
      {:"organisation_variable.edit", :demoted_admin,
       "/:org/settings/variables/:org_locked_variable/unlock", "unlock_variable", %{}},
      {:"organisation_variable.edit", :demoted_admin,
       "/:org/settings/variables/:org_variable/delete", "delete_variable", %{}},
      {:"organisation_variable.edit", :instance_admin, "/:org/settings/variables",
       "create_variable", %{"variable" => %{"name" => "SNEAKY", "value" => "x"}}},
      {:"organisation_variable.edit", :instance_admin, "/:org/settings/variables",
       "lock_variable", %{}},
      {:"organisation_variable.edit", :instance_admin,
       "/:org/settings/variables/:org_variable/delete", "delete_variable", %{},
       answer: :refused_at_mount},
      # Another organisation's owner, on their own organisation's page, naming this one's
      # variable: as one that is not there.
      {:"organisation_variable.edit", :other_owner,
       "/:other_org/settings/variables/:org_variable/delete", "delete_variable", %{},
       answer: :refused_at_mount},

      # The organisation's secrets, the Secrets tab of its settings' Secrets and
      # variables: read by its owners, admins and readers, changed by its owners and
      # admins. A member does not open the page; an admin demoted while a page or a
      # confirmation is open, and an instance admin, who reads them, are refused each
      # change.
      {:"organisation_secret.write", :member, "/:org/settings/secrets", "create_secret",
       %{"secret" => %{"name" => "SNEAKY", "value" => "not-to-be-saved"}},
       answer: :not_found_at_mount},
      {:"organisation_secret.write", :demoted_admin, "/:org/settings/secrets/new",
       "create_secret", %{"secret" => %{"name" => "SNEAKY", "value" => "not-to-be-saved"}}},
      {:"organisation_secret.write", :demoted_admin,
       "/:org/settings/secrets/:org_secret/change-value", "set_value",
       %{"secret_value" => %{"value" => "not-to-be-saved"}}},
      {:"organisation_secret.write", :demoted_admin,
       "/:org/settings/secrets/:org_secret/add-value", "add_value",
       %{"secret_value" => %{"first_value_id" => "a", "value_id" => "b", "value" => "c"}}},
      {:"organisation_secret.write", :demoted_admin, "/:org/settings/secrets/:org_secret/edit",
       "update_secret", %{"secret" => %{"name" => "SNEAKY"}}},
      {:"organisation_secret.write", :demoted_admin, "/:org/settings/secrets/:org_secret/delete",
       "delete_secret", %{}},
      {:"organisation_secret.write", :instance_admin, "/:org/settings/secrets", "create_secret",
       %{"secret" => %{"name" => "SNEAKY", "value" => "not-to-be-saved"}}},
      {:"organisation_secret.write", :instance_admin, "/:org/settings/secrets/:org_secret/delete",
       "delete_secret", %{}, answer: :refused_at_mount},
      # Another organisation's owner, on the page of their organisation, naming this one's
      # secret: as one that is not there.
      {:"organisation_secret.write", :other_owner,
       "/:other_org/settings/secrets/:org_secret/delete", "delete_secret", %{},
       answer: :refused_at_mount}
    ]
  end

  # The keys of the model providers added for every workspace, on the Secrets tab, changed
  # under `provider.write`: a member does not open the page, and an admin demoted while it
  # is open is refused each change. (An owner demoted to admin keeps `provider.write`.) In a
  # client, a person of the operator reads the page and is sent back as it opens.
  defp key_rows do
    changes = fn secret ->
      [
        {"#{secret}/values/main/change", "set_value",
         %{"secret_value" => %{"value" => "not-to-be-saved"}}},
        {"#{secret}/add-value", "add_value",
         %{"secret_value" => %{"value_id" => "b", "value" => "not-to-be-saved"}}},
        {"#{secret}/values/main/rename", "rename_value",
         %{"secret_value" => %{"value_id" => "renamed"}}},
        {"#{secret}/values/spare/delete", "delete_value", %{}},
        {"#{secret}/delete", "delete_secret", %{}}
      ]
    end

    for {actor, org, key, opts} <- [
          {:member, "/:org", ":org_key",
           [answer: :not_found_at_mount, needs: [:factory, :secrets]]},
          {:demoted_admin, "/:org", ":org_key", [needs: [:factory, :secrets]]},
          {:instance_admin, "/:org", ":org_key",
           [answer: :refused_at_mount, needs: [:factory, :secrets, :organisation_variables]]},
          {:operator_owner, "/:client", ":client_key",
           [
             answer: :refused_at_mount,
             needs: [:managed_organisations, :factory, :secrets, :organisation_variables]
           ]},
          {:operator_admin, "/:client", ":client_key",
           [
             answer: :refused_at_mount,
             needs: [:managed_organisations, :factory, :secrets, :organisation_variables]
           ]},
          {:operator_member, "/:client", ":client_key",
           [
             answer: :refused_at_mount,
             needs: [:managed_organisations, :factory, :secrets, :organisation_variables]
           ]}
        ],
        {path, event, params} <- changes.("#{org}/settings/secrets/#{key}"),
        do: {:"provider.write", actor, path, event, params, opts}
  end

  # In a client, the operator's people, at every level, read everything and change
  # nothing: each change the client's pages offer, sent by an owner, an admin and a member
  # of the operator.
  defp in_client_rows do
    for actor <- [:operator_owner, :operator_admin, :operator_member],
        row <- [
          {:"organisation.rename", actor, "/:client/settings", "save_organisation",
           %{"organisation" => %{"name" => "Renamed"}}, needs: :managed_organisations},
          {:"workspace.delete", actor, "/:client/settings", "delete_workspace",
           %{"confirm" => %{"slug" => :client_ws}}, needs: :managed_organisations},
          {:"workspace.create", actor, "/:client/workspaces/new?step=name&type=software",
           "create", %{"workspace" => %{"name" => "Sneaky"}},
           answer: :not_found_at_mount, needs: :managed_organisations},
          {:"retention.edit", actor, "/:client/:client_ws/settings", "save_retention",
           %{"retention" => %{"events_retention_days" => "7", "log_retention_days" => "7"}},
           needs: :managed_organisations},
          {:"node.create", actor, "/:client/:client_ws/machines", "create",
           %{"node" => %{"name" => "sneaky"}}, needs: :managed_organisations},
          {:"member.invite", actor, "/:client/settings/people", "invite",
           %{"invitation" => %{"email" => "invitee@example.com"}}, needs: :managed_organisations},
          {:"member.remove", actor, "/:client/settings/people", "remove", %{},
           needs: :managed_organisations},
          {:"member.remove", actor, "/:client/settings/people/:client_member_membership/remove",
           "remove", %{}, answer: :refused_at_mount, needs: :managed_organisations},
          {:"member.change_level", actor, "/:client/settings/people", "set_level",
           %{"membership_id" => :client_member_membership, "level" => "admin"},
           needs: :managed_organisations},
          {:"security_policy.edit", actor, "/:client/:client_ws/policy", "rule_save", %{},
           prelude: [
             {"rule_validate", %{"rule" => %{"host" => "new.example", "paths" => ""}}}
           ],
           needs: [:managed_organisations, :security]},
          {:"security_policy.set_mode", actor, "/:client/:client_ws/policy", "mode_set",
           %{"mode" => "enforce"}, needs: [:managed_organisations, :security]}
        ],
        do: row
  end

  defp instance_rows do
    [
      # The Instance settings pages: not there for the instance organisation's admins and members,
      # nor for an owner of any other organisation, in theirs.
      {:"instance.create_organisation", :io_admin, "/instance/organisations/new", "create",
       %{"organisation" => %{"name" => "Sneaky", "kind" => "organisation"}},
       answer: :not_found_at_mount},
      {:"instance.create_organisation", :io_member, "/instance/organisations/new", "create",
       %{"organisation" => %{"name" => "Sneaky", "kind" => "organisation"}},
       answer: :not_found_at_mount},
      {:"instance.create_organisation", :owner, "/instance/organisations/new", "create",
       %{"organisation" => %{"name" => "Sneaky", "kind" => "organisation"}},
       answer: :not_found_at_mount},
      {:"instance.create_organisation", :revoked_instance_admin, "/instance/organisations/new",
       "create", %{"organisation" => %{"name" => "Sneaky", "kind" => "organisation"}}},
      {:"instance.create_operator", :io_admin, "/instance/organisations/new", "create",
       %{"organisation" => %{"name" => "Sneaky", "kind" => "operator"}},
       answer: :not_found_at_mount},
      {:"instance.create_operator", :revoked_instance_admin, "/instance/organisations/new",
       "create", %{"organisation" => %{"name" => "Sneaky", "kind" => "operator"}}},
      {:"instance.change_kind", :io_admin, "/instance/organisations/:organisation_id/kind",
       "change_kind", %{"kind" => "operator"}, answer: :not_found_at_mount},
      {:"instance.change_kind", :io_member, "/instance/organisations/:organisation_id/kind",
       "change_kind", %{"kind" => "operator"}, answer: :not_found_at_mount},
      {:"instance.change_kind", :owner, "/instance/organisations/:organisation_id/kind",
       "change_kind", %{"kind" => "operator"}, answer: :not_found_at_mount},
      {:"instance.change_kind", :revoked_instance_admin,
       "/instance/organisations/:organisation_id/kind", "change_kind", %{"kind" => "operator"}},
      # An operator with clients stays an operator, and a client becomes none. The
      # instance organisation's kind changes as any other's (`ApiaryPro.OperatorsTest`).
      {:"instance.change_kind", :instance_admin, "/instance/organisations/:operator_id/kind",
       "change_kind", %{"kind" => "organisation"}},
      {:"instance.change_kind", :instance_admin, "/instance/organisations/:client_id/kind",
       "change_kind", %{"kind" => "operator"}},
      {:"instance.purge_organisation", :io_admin,
       "/instance/organisations/:organisation_id/purge", "purge",
       %{"confirm" => %{"slug" => :org}}, answer: :not_found_at_mount},
      {:"instance.purge_organisation", :io_member,
       "/instance/organisations/:organisation_id/purge", "purge",
       %{"confirm" => %{"slug" => :org}}, answer: :not_found_at_mount},
      {:"instance.purge_organisation", :owner, "/instance/organisations/:organisation_id/purge",
       "purge", %{"confirm" => %{"slug" => :org}}, answer: :not_found_at_mount},
      {:"instance.purge_organisation", :revoked_instance_admin,
       "/instance/organisations/:organisation_id/purge", "purge",
       %{"confirm" => %{"slug" => :org}}},
      # The instance organisation is never purged, nor an operator with clients.
      {:"instance.purge_organisation", :instance_admin,
       "/instance/organisations/:instance_org_id/purge", "purge",
       %{"confirm" => %{"slug" => :instance_org}}},
      {:"instance.purge_organisation", :instance_admin,
       "/instance/organisations/:operator_id/purge", "purge",
       %{"confirm" => %{"slug" => :operator}}, needs: :managed_organisations},
      # Suspending and activating an account and an organisation, the arbiter's transfer
      # and the features: the instance organisation's owners', never on the instance
      # organisation.
      {:"instance.suspend_account", :io_admin, "/instance/accounts/:member_user_id/suspend",
       "suspend_account", %{}, answer: :not_found_at_mount},
      {:"instance.suspend_account", :owner, "/instance/accounts/:member_user_id/suspend",
       "suspend_account", %{}, answer: :not_found_at_mount},
      {:"instance.suspend_account", :revoked_instance_admin,
       "/instance/accounts/:member_user_id/suspend", "suspend_account", %{}},
      {:"instance.activate_account", :revoked_instance_admin, "/instance/accounts",
       "activate_account", %{"id" => :member_user_id}},
      {:"instance.suspend_organisation", :io_member,
       "/instance/organisations/:organisation_id/suspend", "suspend_organisation", %{},
       answer: :not_found_at_mount},
      {:"instance.suspend_organisation", :revoked_instance_admin,
       "/instance/organisations/:organisation_id/suspend", "suspend_organisation", %{}},
      {:"instance.suspend_organisation", :instance_admin,
       "/instance/organisations/:instance_org_id/suspend", "suspend_organisation", %{}},
      {:"instance.activate_organisation", :revoked_instance_admin, "/instance/organisations",
       "activate_organisation", %{"id" => :organisation_id}},
      {:"instance.transfer", :revoked_instance_admin,
       "/instance/organisations/:client_id/transfer", "transfer",
       %{
         "transfer" => %{"membership_id" => :client_admin_membership, "reason" => "Gone quiet"}
       }, needs: :managed_organisations},
      {:"instance.grant_features", :revoked_instance_admin,
       "/instance/organisations/:organisation_id/features", "save_features",
       %{"features" => %{"observability" => "true"}}},
      {:"instance.grant_features", :instance_admin, "/instance/organisations/:client_id/features",
       "save_features", %{"features" => %{"observability" => "true"}},
       needs: :managed_organisations},
      # Who may sign up, on Instance settings › Configuration, which is not found for
      # anyone but an instance admin.
      {:"instance.change_sign_up", :io_admin, "/instance/configuration", "save",
       %{"sign_up" => %{"organisations" => "open"}}, answer: :not_found_at_mount},
      {:"instance.change_sign_up", :owner, "/instance/configuration", "save",
       %{"sign_up" => %{"organisations" => "open"}}, answer: :not_found_at_mount},

      # An instance admin reads the organisation and changes nothing in it.
      {:"organisation.rename", :instance_admin, "/:org/settings", "save_organisation",
       %{"organisation" => %{"name" => "Renamed"}}},
      {:"organisation.delete", :instance_admin, "/:org/settings", "delete_organisation",
       %{"confirm" => %{"slug" => :org}}},
      {:"member.change_level", :instance_admin, "/:org/settings/people", "set_level",
       %{"membership_id" => :other_member, "level" => "admin"}},
      {:"member.invite", :instance_admin, "/:org/settings/people", "invite",
       %{"invitation" => %{"email" => "invitee@example.com"}}},
      {:"invitation.revoke", :instance_admin, "/:org/settings/people", "revoke_invitation",
       %{"id" => :invitation}},
      {:"workspace.rename", :instance_admin, "/:org/:workspace/settings", "save_workspace",
       %{"workspace" => %{"name" => "Renamed"}}},
      # The core's page that adds a workspace is no page for anyone but an owner (404). An
      # owner demoted while it is open is sent back to the cards with nothing created and
      # no flash, which no answer of a row names: `ApiaryProWeb.NewWorkspaceTest` has it.
      {:"workspace.create", :instance_admin, "/:org/workspaces/new?step=name&type=software",
       "create", %{"workspace" => %{"name" => "Sneaky"}}, answer: :not_found_at_mount},
      {:"workspace.create", :admin, "/:org/workspaces/new?step=name&type=software", "create",
       %{"workspace" => %{"name" => "Sneaky"}}, answer: :not_found_at_mount},
      {:"workspace.create", :member, "/:org/workspaces/new?step=name&type=software", "create",
       %{"workspace" => %{"name" => "Sneaky"}}, answer: :not_found_at_mount},
      {:"retention.edit", :instance_admin, "/:org/:workspace/settings", "save_retention",
       %{"retention" => %{"events_retention_days" => "7", "log_retention_days" => "7"}}},
      {:"security_policy.set_mode", :instance_admin, "/:org/:workspace/policy", "mode_set",
       %{"mode" => "enforce"}},
      {:"security_policy.edit", :instance_admin, "/:org/:workspace/policy", "rule_save", %{},
       prelude: [{"rule_validate", %{"rule" => %{"host" => "new.example", "paths" => ""}}}]},
      {:"security_policy.lock", :instance_admin, "/:org/:workspace/policy", "lock_toggle",
       %{"id" => :rule_open}},
      # A node's key, from its Access key tab, which the server refuses; the paths of the
      # forms and of the confirmation refuse as they open.
      {:"access_key.add", :instance_admin, "/:org/:workspace/machines/:node/access-key",
       "generate_key", %{"key" => %{"label" => "sneaky", "public_key" => :public_key}}},
      # No instance admin any more when the event comes: sent to `/`, as anyone who no
      # longer reaches the organisation.
      {:"access_key.add", :revoked_instance_admin, "/:org/:workspace/machines/:node/access-key",
       "generate_key", %{"key" => %{"label" => "sneaky", "public_key" => :public_key}}},
      {:"access_key.add", :instance_admin, "/:org/:workspace/machines/:node/access-key/generate",
       "generate_key", %{"key" => %{"label" => "sneaky", "public_key" => :public_key}},
       answer: :refused_at_mount},
      {:"access_key.create_code", :instance_admin,
       "/:org/:workspace/machines/:node/access-key/new-code", "create_code", %{},
       answer: :refused_at_mount},
      {:"access_key.revoke", :instance_admin,
       "/:org/:workspace/machines/:node/access-key/keys/:node_key/revoke", "revoke", %{},
       answer: :refused_at_mount},
      {:"node.create", :instance_admin, "/:org/:workspace/machines", "create",
       %{"node" => %{"name" => "sneaky"}}},
      {:"node.create", :instance_admin, "/:org/:workspace/machines/new", "create",
       %{"node" => %{"name" => "sneaky"}}, answer: :refused_at_mount},
      {:"node.edit", :instance_admin, "/:org/:workspace/machines/:node/settings", "save",
       %{"node" => %{"name" => "renamed"}}},
      {:"node.set_limit", :instance_admin, "/:org/:workspace/machines/:pool/settings", "save",
       %{"node" => %{"instance_limit" => "3"}}},
      {:"node.delete", :instance_admin, "/:org/:workspace/machines/:node/settings", "delete",
       %{}},
      {:"node.delete", :instance_admin, "/:org/:workspace/machines/:node/settings/delete",
       "delete", %{}, answer: :refused_at_mount},
      {:"node.clear_instance", :instance_admin, "/:org/:workspace/machines/:node",
       "clear_instance", %{}},
      {:"node.clear_instance", :instance_admin,
       "/:org/:workspace/machines/:node/instances/:instance/clear", "clear_instance", %{},
       answer: :refused_at_mount}
    ]
  end

  # An operator's Clients page and the Instance's pages are reads, `client.read` and
  # `instance.read`: their refusals are the Access hook's
  # (`test/apiary_pro_web/live/client_live/`, `test/apiary_pro_web/live/instance_live/`).
  # The adoption of the core's organisations is the instance's, after the migrations,
  # never offered by a page (`test/apiary_pro/adoption_test.exs`). The organisation's
  # variables are read on their page, which the Access hook refuses as it mounts
  # (`test/apiary_pro_web/live/settings_live/variables_test.exs`), and so are its secrets
  # (`test/apiary_pro_web/live/settings_live/secrets_test.exs`). No page makes a link to
  # one of its secrets yet: the edition's answer for `:use` is asked directly
  # (`test/apiary_pro/organisation_secrets_test.exs`). No page sets the model providers of
  # a client either: `ApiaryPro.Operators.set_model_chain/3` refuses an operator's member,
  # another operator's owner and a client's people (`test/apiary_pro/model_chain_test.exs`).
  @impl true
  def exempt,
    do: %{
      reads: [
        :"client.read",
        :"instance.read",
        :"organisation_policy.read",
        :"organisation_variable.read",
        :"organisation_secret.read"
      ],
      after_migrate: [:"instance.adopt"],
      no_page: [:"organisation_secret.use", :"client.set_model_chain"]
    }

  @impl true
  def setup(%{owner: owner, member: member, workspace_b: workspace_b, target: target}) do
    # The edition's switch `feature_visibility` is an opt-in feature, on with every
    # feature: the world is made with it off, as the rows read it, in the process that
    # makes it.
    ApiaryPro.Flags.put_feature_visibility(false)

    operators = operators()

    # The core's target, by its system and path, in the other workspace too: the page the
    # member of that workspace names this one's ids from.
    target_b =
      Apiary.Repo.insert!(%Apiary.Runs.Target{
        organisation_id: workspace_b.organisation_id,
        workspace_id: workspace_b.id,
        system: target.system,
        path: target.path,
        first_seen_at: DateTime.utc_now()
      })

    operators
    |> Map.merge(policy_requests(operators))
    |> Map.merge(organisation_policy(owner))
    |> Map.merge(organisation_variable(owner))
    |> Map.merge(organisation_secret(owner))
    |> Map.merge(%{
      org_key: key_secret(owner),
      client_key: operators.client && key_secret(operators.client_owner.scope)
    })
    |> Map.merge(%{
      stale_member: member,
      target_b: target_b,
      elsewhere: member_fixture(workspace_scope(owner.user, workspace_b)),
      revoked_instance_admin: operators.instance_admin
    })
  end

  # With the organisation's policy: a rule of the organisation's, which a row names.
  defp organisation_policy(owner) do
    if :organisation_policy in Apiary.Features.enabled() do
      {:ok, rule} = ApiaryPro.OrganisationPolicy.deny(owner, %{host: "org.example"})
      %{org_rule: rule}
    else
      %{org_rule: nil}
    end
  end

  # With the organisation's variables: a variable of the organisation's, and a locked one,
  # which a row names.
  defp organisation_variable(owner) do
    if :organisation_variables in Apiary.Features.enabled() do
      {:ok, variable} =
        ApiaryPro.OrganisationVariables.create(owner, %{name: "REGISTRY_URL", value: "x"})

      {:ok, locked} =
        ApiaryPro.OrganisationVariables.create(owner, %{
          name: "REGION",
          value: "eu-west-1",
          locked: true
        })

      %{org_variable: variable, org_locked_variable: locked}
    else
      %{org_variable: nil, org_locked_variable: nil}
    end
  end

  # With the organisation's secrets: a secret of the organisation's, of one value, which a
  # row names.
  defp organisation_secret(owner) do
    if :organisation_variables in Apiary.Features.enabled() do
      {:ok, secret} =
        Apiary.Secrets.create_organisation_secret(owner, %{
          "name" => "FORGE_TOKEN",
          "value" => "token-value"
        })

      %{org_secret: secret}
    else
      %{org_secret: nil}
    end
  end

  # With the features `factory` and `secrets`: the secret of the keys of a model provider
  # added in the organisation of `scope` for every workspace, with two keys, which a row names.
  defp key_secret(scope) do
    if :factory in Apiary.Features.enabled() and :secrets in Apiary.Features.enabled() do
      {:ok, provider} =
        Apiary.Connections.create_provider(scope, %{
          provider: "anthropic",
          name: "Claude keys",
          keys: [%{value_id: "main", value: "key-one"}, %{value_id: "spare", value: "key-two"}]
        })

      Repo.get!(Apiary.Secrets.Secret, provider.secret_id)
    end
  end

  # The instance organisation with an instance admin, an admin and a member; an operator
  # made one by that instance admin, with an admin, a member and a client, and the
  # client's owner, whom the operator invited, an admin and a member of the client's own.
  # The people of the instance organisation are inserted as they are, without the locks
  # the product takes on its row and its owners, which every row of this test shares.
  defp operators do
    instance_organisation = ApiaryPro.Organisations.instance_organisation()
    instance_admin = instance_person(instance_organisation, :owner)
    instance_scope = scope_in(instance_admin.user, instance_organisation)

    %{scope: operator_owner, organisation: operator} = sign_up_fixture()

    operator =
      if :managed_organisations in Apiary.Features.enabled() do
        {:ok, operator} = Operators.change_kind(instance_scope, operator.id, :operator)
        operator
      else
        operator
      end

    operator_owner = scope_in(operator_owner.user, operator)

    client =
      if ApiaryPro.Tenants.operator?(operator),
        do: ApiaryPro.OperatorsFixtures.client_fixture(operator_owner, "Client")

    %{
      instance_organisation: instance_organisation,
      instance_admin: instance_admin,
      io_admin: instance_person(instance_organisation, :admin),
      io_member: instance_person(instance_organisation, :member),
      operator: operator,
      operator_member: RefusalsCase.person(operator_owner, :member),
      client: client && client.organisation,
      client_owner: client && client.owner,
      client_admin: client && RefusalsCase.person(client.owner.scope, :admin),
      client_member: client && RefusalsCase.person(client.owner.scope, :member),
      client_unplaced: client && unplaced(client.owner.scope, client.workspace),
      client_workspace: client && client.workspace,
      operator_admin: RefusalsCase.person(operator_owner, :admin),
      operator_owner: %{user: operator_owner.user, scope: operator_owner}
    }
  end

  # With the security policy and an operator: a second client of the operator, a locked
  # rule in the first client's workspace, and a request of the operator's to both, which
  # changes that rule, pending in each.
  defp policy_requests(%{client: nil}),
    do: %{client_b: nil, request: nil, client_answer: nil, client_b_answer: nil}

  defp policy_requests(%{client: client, client_owner: owner, operator_owner: operator}) do
    if :security in Apiary.Features.enabled() do
      client_b = ApiaryPro.OperatorsFixtures.client_fixture(operator.scope, "Client B")
      {:ok, _} = Policy.deny(owner.scope, nil, %{host: "locked.example", locked: true})

      {:ok, request} =
        ApiaryPro.PolicyRequests.send_request(operator.scope, %{
          "changes" => %{
            "rules" => [
              %{"change" => "rule_changed", "action" => "allow", "host" => "locked.example"}
            ]
          },
          "note" => "The harness calls it."
        })

      answer = fn organisation ->
        Repo.get_by!(ApiaryPro.PolicyRequests.Answer,
          request_id: request.id,
          organisation_id: organisation.id
        )
      end

      %{
        client_b: client_b.organisation,
        request: request,
        client_answer: answer.(client),
        client_b_answer: answer.(client_b.organisation)
      }
    else
      policy_requests(%{client: nil})
    end
  end

  # A member of the client removed from its one workspace: in it, and in none of its
  # workspaces.
  defp unplaced(owner, workspace) do
    %{membership: membership} = unplaced = RefusalsCase.person(owner, :member)
    {:ok, _} = WorkspaceAccess.remove(owner, membership.id, workspace.id)
    unplaced
  end

  defp instance_person(instance_organisation, level) do
    user = user_fixture()

    membership =
      Repo.insert!(%Membership{
        organisation_id: instance_organisation.id,
        user_id: user.id,
        level: level
      })

    %{user: user, membership: membership}
  end

  defp scope_in(user, organisation) do
    {:ok, scope} = Organisations.resolve_scope(Scope.for_user(user), organisation.slug)
    scope
  end

  @impl true
  def value(:instance_org, world), do: world.instance_organisation.slug
  def value(:operator, world), do: world.operator.slug
  def value(:client, world), do: world.client.slug
  def value(:client_ws, world), do: world.client_workspace.slug
  def value(:operator_name, world), do: world.operator.name
  def value(:client_name, world), do: world.client.name
  def value(:instance_org_id, world), do: {:id, world.instance_organisation.id}
  def value(:client_id, world), do: {:id, world.client.id}
  def value(:operator_id, world), do: {:id, world.operator.id}
  def value(:member_user_id, world), do: {:id, world.member.user.id}
  def value(:client_admin_membership, world), do: {:id, world.client_admin.membership.id}
  def value(:client_member_membership, world), do: {:id, world.client_member.membership.id}
  def value(:client_workspace_id, world), do: {:id, world.client_workspace.id}
  def value(:request_id, world), do: {:id, world.request.id}
  def value(:client_answer, world), do: {:id, world.client_answer.id}
  def value(:client_b_answer, world), do: {:id, world.client_b_answer.id}
  def value(:org_rule, world), do: {:id, world.org_rule.id}
  def value(:org_variable, world), do: {:id, world.org_variable.id}
  def value(:org_locked_variable, world), do: {:id, world.org_locked_variable.id}
  def value(:org_secret, world), do: {:id, world.org_secret.public_id}
  def value(:org_key, world), do: {:id, world.org_key.public_id}
  def value(:client_key, world), do: {:id, world.client_key.public_id}
  def value(:target_page_b, world), do: world.target_b.public_id
  def value(_name, _world), do: nil

  # The operator and its clients, whose features, offers and people a row may reach.
  @impl true
  def watched(world), do: [world.operator, world.client, world.client_b]

  # The organisation offered to the operator by its owner.
  @impl true
  def before_page(:offered_to_operator, world) do
    if is_nil(ApiaryPro.Transfers.pending(world.owner)),
      do: {:ok, _} = ApiaryPro.Transfers.offer_to_operator(world.owner, world.operator.slug)

    :ok
  end

  # The client's ownership offered by the instance's arbiter to a second admin of it:
  # seeded as the offer's row, since its owner may act.
  def before_page(:client_arbitrated, world) do
    if is_nil(Repo.get_by(ApiaryPro.Transfers.Transfer, organisation_id: world.client.id)) do
      %{user: second} = RefusalsCase.person(world.client_owner.scope, :admin)

      Repo.insert!(%ApiaryPro.Transfers.Transfer{
        organisation_id: world.client.id,
        kind: :to_admin,
        recipient_id: second.id,
        offered_by_id: world.instance_admin.user.id,
        arbitrated: true,
        reason: "Seeded for the refusal table."
      })
    end

    :ok
  end

  # The organisation's ownership offered by the instance's arbiter to an admin of it
  # other than the world's admin: seeded as the offer's row, since the organisation has
  # owners who may act, whom the arbiter would not overrule.
  def before_page(:arbitrated_to_another_admin, world) do
    if is_nil(ApiaryPro.Transfers.pending(world.owner)) do
      %{user: other} = RefusalsCase.person(world.owner, :admin)

      Repo.insert!(%ApiaryPro.Transfers.Transfer{
        organisation_id: world.organisation.id,
        kind: :to_admin,
        recipient_id: other.id,
        offered_by_id: world.instance_admin.user.id,
        arbitrated: true,
        reason: "Seeded for the refusal table."
      })
    end

    :ok
  end

  # The client suspended by an instance admin.
  def before_page(:client_suspended, world) do
    if is_nil(ApiaryPro.Tenants.suspended_at(Repo.reload!(world.client))) do
      admin = scope_in(world.instance_admin.user, world.instance_organisation)
      {:ok, _} = ApiaryPro.Suspensions.suspend_organisation(admin, world.client.id)
    end

    :ok
  end

  def before_page(_step, _world), do: nil

  # The person no longer reaches the workspace.
  @impl true
  def meanwhile(:stale_member, world) do
    Repo.delete_all(
      from a in WorkspaceAccess.Row,
        where: a.workspace_id == ^world.workspace.id and a.user_id == ^world.stale_member.user.id
    )

    :ok
  end

  # No instance admin any more: a member of the instance organisation, as the release
  # command leaves them.
  def meanwhile(:revoked_instance_admin, world) do
    RefusalsCase.put_level(world.revoked_instance_admin, :member)
    :ok
  end

  def meanwhile(_step, _world), do: nil
end
