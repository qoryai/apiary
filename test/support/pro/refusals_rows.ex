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
                     an owner, an admin and a member of an operator, in the organisation
                     whose workspace it operates, which they read and change nothing in
      operated_owner, operated_admin
                     the owner and an admin of that organisation, for the rows of
                     `ApiaryProWeb.OperatorAsOwnerRefusalsRows`
      instance_admin an owner of the instance organisation: on the Instance settings pages, and
                     reading the organisation, which they reach only as one, read-only
      revoked_instance_admin
                     an instance admin who had an Instance settings page open, and who was made a
                     member of the instance organisation before the event
      io_admin, io_member
                     an admin and a member of the instance organisation, on its instance
                     page

  The world adds to the core's: the instance organisation with an instance admin, an admin
  and a member; an operator made one by that instance admin, with an admin, a member and an
  organisation whose workspace it operates, and that organisation's owner, an admin and a
  member.
  """

  @behaviour ApiaryWeb.RefusalsCase

  import Ecto.Query
  import Apiary.AccountsFixtures, only: [user_fixture: 0]
  import Apiary.OrganisationsFixtures

  alias Apiary.{Organisations, Repo}
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
      :operated_owner,
      :operated_admin,
      :instance_admin,
      :revoked_instance_admin,
      :io_admin,
      :io_member
    ]
  end

  @impl true
  def rows, do: organisation_rows() ++ key_rows() ++ in_operated_rows() ++ instance_rows()

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

      # The ownership, a tab of the organisation's settings: only the admin an offer is
      # for accepts it. A reader for whom the section is not listed is sent to General as
      # the page opens. The arbiter's offer, made to another admin of the organisation.
      {:"organisation.accept_transfer", :admin, "/:org/settings/ownership", "accept_transfer",
       %{}, setup: :arbitrated_to_another_admin, answer: :refused_at_mount},

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

      # The organisation's policy: read by its owners, admins and readers, changed by its
      # owners alone. A member does not open the page; an admin, an instance admin and an
      # owner demoted while the page is open are refused each change; the people of the
      # operator of its workspace read it there and change nothing. Those rows need the
      # managed organisations as well as the organisation's policy, and a row names one feature:
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
      # The organisation's policy page is not found for the operator's people.
      {:"organisation_policy.edit", :operator_owner, "/:operated/policy", "rule_save", %{},
       answer: :not_found_at_mount, needs: :organisation_policy},
      {:"organisation_policy.set_floor", :admin, "/:org/policy", "mode_open", %{}},
      {:"organisation_policy.set_floor", :admin, "/:org/policy", "mode_set", %{}},
      {:"organisation_policy.set_floor", :demoted_owner, "/:org/policy", "mode_set", %{},
       prelude: [{"mode_open", %{}}, {"mode_pick", %{"mode" => "enforce"}}]},
      {:"organisation_policy.set_floor", :instance_admin, "/:org/policy", "mode_open", %{}},
      {:"organisation_policy.set_floor", :operator_owner, "/:operated/policy", "mode_open", %{},
       answer: :not_found_at_mount, needs: :organisation_policy},
      {:"organisation_policy.set_switch", :admin, "/:org/policy", "switch_ask", %{}},
      {:"organisation_policy.set_switch", :demoted_owner, "/:org/policy", "setting_confirm", %{},
       prelude: [{"switch_ask", %{}}]},
      {:"organisation_policy.set_switch", :instance_admin, "/:org/policy", "switch_ask", %{}},
      {:"organisation_policy.set_switch", :operator_owner, "/:operated/policy", "switch_ask", %{},
       answer: :not_found_at_mount, needs: :organisation_policy},

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
  # organisation, the page is not there for a person of the operator, who reaches the
  # workspace the operator operates and nothing the organisation has as a whole.
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
          {:operator_owner, "/:operated", ":operated_key",
           [
             answer: :not_found_at_mount,
             needs: [:managed_organisations, :factory, :secrets, :organisation_variables]
           ]},
          {:operator_admin, "/:operated", ":operated_key",
           [
             answer: :not_found_at_mount,
             needs: [:managed_organisations, :factory, :secrets, :organisation_variables]
           ]},
          {:operator_member, "/:operated", ":operated_key",
           [
             answer: :not_found_at_mount,
             needs: [:managed_organisations, :factory, :secrets, :organisation_variables]
           ]}
        ],
        {path, event, params} <- changes.("#{org}/settings/secrets/#{key}"),
        do: {:"provider.write", actor, path, event, params, opts}
  end

  # In an operated workspace, the operator's people, at every level, read everything and
  # change nothing: each change the organisation's pages offer, sent by an owner, an admin
  # and a member of the operator.
  defp in_operated_rows do
    for actor <- [:operator_owner, :operator_admin, :operator_member],
        row <- [
          {:"organisation.rename", actor, "/:operated/settings", "save_organisation",
           %{"organisation" => %{"name" => "Renamed"}}, needs: :managed_organisations},
          {:"workspace.delete", actor, "/:operated/settings", "delete_workspace",
           %{"confirm" => %{"slug" => :operated_ws}}, needs: :managed_organisations},
          {:"workspace.create", actor, "/:operated/workspaces/new?step=name&type=software",
           "create", %{"workspace" => %{"name" => "Sneaky"}},
           answer: :not_found_at_mount, needs: :managed_organisations},
          {:"retention.edit", actor, "/:operated/:operated_ws/settings", "save_retention",
           %{"retention" => %{"events_retention_days" => "7", "log_retention_days" => "7"}},
           needs: :managed_organisations},
          {:"node.create", actor, "/:operated/:operated_ws/machines", "create",
           %{"node" => %{"name" => "sneaky"}}, needs: :managed_organisations},
          # The People page is not found for them (`member.read`).
          {:"member.invite", actor, "/:operated/settings/people", "invite",
           %{"invitation" => %{"email" => "invitee@example.com"}},
           answer: :not_found_at_mount, needs: :managed_organisations},
          {:"member.remove", actor, "/:operated/settings/people", "remove", %{},
           answer: :not_found_at_mount, needs: :managed_organisations},
          {:"member.remove", actor,
           "/:operated/settings/people/:operated_member_membership/remove", "remove", %{},
           answer: :not_found_at_mount, needs: :managed_organisations},
          {:"member.change_level", actor, "/:operated/settings/people", "set_level",
           %{"membership_id" => :operated_member_membership, "level" => "admin"},
           answer: :not_found_at_mount, needs: :managed_organisations},
          {:"security_policy.edit", actor, "/:operated/:operated_ws/policy", "rule_save", %{},
           prelude: [
             {"rule_validate", %{"rule" => %{"host" => "new.example", "paths" => ""}}}
           ],
           needs: [:managed_organisations, :security]},
          {:"security_policy.set_mode", actor, "/:operated/:operated_ws/policy", "mode_set",
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
      # An operator that operates a workspace stays an operator, and the organisation of
      # that workspace is not made one. The instance organisation's kind changes as any
      # other's (`ApiaryPro.OperatorsTest`).
      {:"instance.change_kind", :instance_admin, "/instance/organisations/:operator_id/kind",
       "change_kind", %{"kind" => "organisation"}},
      {:"instance.change_kind", :instance_admin, "/instance/organisations/:operated_id/kind",
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
      # The instance organisation is never purged, nor an operator that operates a
      # workspace.
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
       "/instance/organisations/:operated_id/transfer", "transfer",
       %{
         "transfer" => %{"membership_id" => :operated_admin_membership, "reason" => "Gone quiet"}
       }, needs: :managed_organisations},
      {:"instance.grant_features", :revoked_instance_admin,
       "/instance/organisations/:organisation_id/features", "save_features",
       %{"features" => %{"observability" => "true"}}},
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

  # The Instance's pages are reads, `instance.read`: their refusals are the Access hook's
  # (`test/apiary_pro_web/live/instance_live/`).
  # The adoption of the core's organisations is the instance's, after the migrations,
  # never offered by a page (`test/apiary_pro/adoption_test.exs`). The organisation's
  # variables are read on their page, which the Access hook refuses as it mounts
  # (`test/apiary_pro_web/live/settings_live/variables_test.exs`), and so are its secrets
  # (`test/apiary_pro_web/live/settings_live/secrets_test.exs`). No page makes a link to
  # one of its secrets yet: the edition's answer for `:use` is asked directly
  # (`test/apiary_pro/organisation_secrets_test.exs`).
  # No page starts or ends a workspace's operator yet: `ApiaryPro.WorkspaceOperators`
  # refuses a member, an admin who ends one, and the operator's admin
  # (`test/apiary_pro/workspace_operators_test.exs`). No page withdraws an offer of
  # ownership: the arbiter's offer lapses once an owner may act again
  # (`ApiaryPro.Transfers.withdraw_overruled/2`, `test/apiary_pro/suspensions_test.exs`).
  @impl true
  def exempt,
    do: %{
      reads: [
        :"instance.read",
        :"organisation_policy.read",
        :"organisation_variable.read",
        :"organisation_secret.read"
      ],
      after_migrate: [:"instance.adopt"],
      no_page: [
        :"organisation_secret.use",
        :"organisation.withdraw_transfer"
      ]
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
      Apiary.NodesFixtures.target_fixture(%{
        organisation_id: workspace_b.organisation_id,
        workspace_id: workspace_b.id,
        system: target.system,
        path: target.path,
        first_seen_at: DateTime.utc_now()
      })

    operators
    |> Map.merge(organisation_policy(owner))
    |> Map.merge(organisation_variable(owner))
    |> Map.merge(organisation_secret(owner))
    |> Map.merge(%{
      org_key: key_secret(owner),
      operated_key: operators.operated && key_secret(operators.operated_owner.scope)
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
  # made one by that instance admin, with an admin, a member and an organisation whose
  # workspace it operates, and that organisation's owner, an admin and a member.
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

    operated =
      if ApiaryPro.Tenants.operator?(operator),
        do: ApiaryPro.OperatorsFixtures.operated_fixture(operator_owner, "Fabrikam")

    %{
      instance_organisation: instance_organisation,
      instance_admin: instance_admin,
      io_admin: instance_person(instance_organisation, :admin),
      io_member: instance_person(instance_organisation, :member),
      operator: operator,
      operator_member: RefusalsCase.person(operator_owner, :member),
      operated: operated && operated.organisation,
      operated_owner: operated && operated.owner,
      operated_admin: operated && RefusalsCase.person(operated.owner.scope, :admin),
      operated_member: operated && RefusalsCase.person(operated.owner.scope, :member),
      operated_workspace: operated && operated.workspace,
      operator_admin: RefusalsCase.person(operator_owner, :admin),
      operator_owner: %{user: operator_owner.user, scope: operator_owner}
    }
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
  def value(:operated, world), do: world.operated.slug
  def value(:operated_ws, world), do: world.operated_workspace.slug
  def value(:instance_org_id, world), do: {:id, world.instance_organisation.id}
  def value(:operated_id, world), do: {:id, world.operated.id}
  def value(:operator_id, world), do: {:id, world.operator.id}
  def value(:member_user_id, world), do: {:id, world.member.user.id}
  def value(:operated_admin_membership, world), do: {:id, world.operated_admin.membership.id}
  def value(:operated_member_membership, world), do: {:id, world.operated_member.membership.id}
  def value(:org_rule, world), do: {:id, world.org_rule.id}
  def value(:org_variable, world), do: {:id, world.org_variable.id}
  def value(:org_locked_variable, world), do: {:id, world.org_locked_variable.id}
  def value(:org_secret, world), do: {:id, world.org_secret.public_id}
  def value(:org_key, world), do: {:id, world.org_key.public_id}
  def value(:operated_key, world), do: {:id, world.operated_key.public_id}
  def value(:target_page_b, world), do: world.target_b.public_id
  def value(_name, _world), do: nil

  # The operator and the organisation whose workspace it operates, whose features and
  # people a row may reach.
  @impl true
  def watched(world), do: [world.operator, world.operated]

  # The organisation's ownership offered by the instance's arbiter to an admin of it
  # other than the world's admin: seeded as the offer's row, since the organisation has
  # owners who may act, whom the arbiter would not overrule.
  @impl true
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
