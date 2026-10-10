defmodule ApiaryWeb.RefusalsRows do
  @moduledoc """
  RefusalsRows is the core's rows of the refusals test (`ApiaryWeb.RefusalsCase`): every
  change the core's pages offer, sent by someone of the core who may not make it. The
  actors, each signed in, opening the row's page in a browser of their own:

      owner           an owner of the organisation
      member          a member of the organisation
      admin           an admin of the organisation
      removed_member  a member whose page was opened, and who was removed from the
                      organisation before the event
      demoted_admin   an admin whose page was opened, a page or a confirmation of an admin's
                      included, and who was made a member before the event, as a demotion
                      leaves them
      demoted_owner   an owner whose page was opened, and who was made an admin before
                      the event
      other_owner     an owner of another organisation: on its own pages, sending ids of
                      this one, and on this one's, which they do not reach

  The world: an organisation with an owner, a second owner, an admin and two members; a
  second workspace, and a third marked for deletion; in the first workspace a rule, a
  locked rule, a stored secret, a variable, a target, an access key, a node with a running
  instance, an active key and an outstanding enrolment code, a run that has not ended, and
  a pending invitation; and another organisation, with its owner.
  """

  @behaviour ApiaryWeb.RefusalsCase

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunListFixtures

  alias Apiary.{Deletion, Policy, Repo, Secrets, Variables}
  alias Apiary.Organisations.Membership
  alias Apiary.Runs.Target
  alias ApiaryWeb.RefusalsCase

  @impl true
  def actors do
    [:owner, :member, :admin, :removed_member, :demoted_admin, :demoted_owner, :other_owner]
  end

  @impl true
  def rows do
    [
      # The members page.
      {:"member.change_level", :member, "/:org/settings/people", "set_level",
       %{"membership_id" => :other_member, "level" => "admin"}},
      {:"member.change_level", :admin, "/:org/settings/people", "set_level",
       %{"membership_id" => :other_member, "level" => "admin"}},
      {:"member.change_level", :demoted_owner, "/:org/settings/people", "set_level",
       %{"membership_id" => :other_member, "level" => "admin"}},
      # An admin acting on an owner.
      {:"member.change_level", :admin, "/:org/settings/people", "set_level",
       %{"membership_id" => :second_owner, "level" => "member"}},
      # A level that is none, from one who may not change levels.
      {:"member.change_level", :admin, "/:org/settings/people", "set_level",
       %{"membership_id" => :other_member, "level" => "superuser"}},
      # Another organisation's owner, on its own members page, naming this one's member.
      {:"member.change_level", :other_owner, "/:other_org/settings/people", "set_level",
       %{"membership_id" => :other_member, "level" => "admin"}, answer: :not_found},
      # Without a member's confirmation open: refused to a member; to an admin, who may
      # remove a member, it is a second click, and the list is shown again.
      {:"member.remove", :member, "/:org/settings/people", "remove", %{}},
      {:"member.remove", :admin, "/:org/settings/people", "remove", %{}, answer: :ignored},
      {:"member.remove", :demoted_admin, "/:org/settings/people/:other_member/remove", "remove",
       %{}},
      # An admin who opened a member's removal, the member made an owner meanwhile.
      {:"member.remove", :admin, "/:org/settings/people/:other_member/remove", "remove", %{},
       meanwhile: {:level, :other_member, :owner}},
      # This organisation's member, in a removal's path of another organisation: no row
      # asks to confirm, and the page says the member is gone, as for one who left.
      {:"member.remove", :other_owner, "/:other_org/settings/people/:other_member/remove",
       "remove", %{}, answer: :refused_at_mount},
      {:"member.invite", :member, "/:org/settings/people", "invite",
       %{"invitation" => %{"email" => "invitee@example.com"}}},
      {:"member.invite", :demoted_admin, "/:org/settings/people/invite", "invite",
       %{"invitation" => %{"email" => "invitee@example.com"}}},
      {:"invitation.revoke", :member, "/:org/settings/people", "revoke_invitation",
       %{"id" => :invitation}},
      {:"invitation.revoke", :other_owner, "/:other_org/settings/people", "revoke_invitation",
       %{"id" => :invitation}, answer: :not_found},
      {:"invitation.renew", :member, "/:org/settings/people", "renew_invitation",
       %{"id" => :invitation}},
      {:"invitation.renew", :other_owner, "/:other_org/settings/people", "renew_invitation",
       %{"id" => :invitation}, answer: :not_found},
      # Suspending and activating a person's membership: an owner acts on admins and
      # members, an admin on members only. A member cannot open a member's suspension, so
      # their `suspend` arrives without it and the page refuses it for their role; the
      # demoted admin's row, whose confirmation was open, reaches the context function.
      {:"member.suspend", :member, "/:org/settings/people", "suspend", %{}},
      {:"member.suspend", :member, "/:org/settings/people/:other_member/suspend", "suspend", %{},
       answer: :refused_at_mount},
      {:"member.suspend", :demoted_admin, "/:org/settings/people/:other_member/suspend",
       "suspend", %{}},
      {:"member.suspend", :admin, "/:org/settings/people/:other_member/suspend", "suspend", %{},
       meanwhile: {:level, :other_member, :owner}},
      {:"member.suspend", :other_owner, "/:other_org/settings/people/:other_member/suspend",
       "suspend", %{}, answer: :refused_at_mount},
      {:"member.activate", :member, "/:org/settings/people", "activate",
       %{"id" => :other_member}},
      {:"member.activate", :admin, "/:org/settings/people", "activate", %{"id" => :second_owner}},
      {:"member.activate", :other_owner, "/:other_org/settings/people", "activate",
       %{"id" => :other_member}, answer: :not_found},
      # An owner does not suspend another owner: the member whose suspension the owner
      # opened is made an owner meanwhile, and the event reaches the server's check.
      {:"member.suspend", :owner, "/:org/settings/people/:other_member/suspend", "suspend", %{},
       meanwhile: {:level, :other_member, :owner}},

      # The settings, and their deletions' confirmations.
      {:"organisation.rename", :member, "/:org/settings", "save_organisation",
       %{"organisation" => %{"name" => "Renamed"}}},
      # An organisation the person does not reach answers 404 before any page opens.
      {:"organisation.rename", :other_owner, "/:org/settings", "save_organisation",
       %{"organisation" => %{"name" => "Renamed"}}, answer: :not_found_at_mount},
      {:"workspace.rename", :member, "/:org/:workspace/settings", "save_workspace",
       %{"workspace" => %{"name" => "Renamed"}}},
      {:"retention.edit", :member, "/:org/:workspace/settings", "save_retention",
       %{"retention" => %{"events_retention_days" => "7", "log_retention_days" => "7"}}},
      {:"organisation.delete", :member, "/:org/settings", "delete_organisation",
       %{"confirm" => %{"slug" => :org}}},
      {:"organisation.delete", :admin, "/:org/settings", "delete_organisation",
       %{"confirm" => %{"slug" => :org}}},
      {:"organisation.delete", :demoted_owner, "/:org/settings/delete", "delete_organisation",
       %{"confirm" => %{"slug" => :org}}},
      {:"organisation.restore", :member, "/users/organisations", "restore",
       %{"id" => :organisation_id}, setup: :organisation_marked},
      {:"organisation.restore", :admin, "/users/organisations", "restore",
       %{"id" => :organisation_id}, setup: :organisation_marked},
      {:"organisation.restore", :other_owner, "/users/organisations", "restore",
       %{"id" => :organisation_id}, setup: :organisation_marked, answer: :not_found},
      # A member's page never holds a workspace to delete, since its confirmation opens
      # only for one who may: the event is answered as for a workspace that is gone, and
      # the context is not asked. The demoted admin's row below is the one that reaches it.
      {:"workspace.delete", :member, "/:org/settings", "delete_workspace",
       %{"confirm" => %{"slug" => :workspace_b}}},
      {:"workspace.delete", :demoted_admin, "/:org/settings/workspaces/:workspace_b_id/delete",
       "delete_workspace", %{"confirm" => %{"slug" => :workspace_b}}},
      # This organisation's workspace, in a deletion's confirmation of another organisation's
      # path: the confirmation does not open, and the page says it cannot be deleted there.
      {:"workspace.delete", :other_owner,
       "/:other_org/settings/workspaces/:workspace_b_id/delete", "delete_workspace",
       %{"confirm" => %{"slug" => :workspace_b}}, answer: :refused_at_mount},
      {:"workspace.restore", :member, "/:org/settings", "restore_workspace",
       %{"id" => :workspace_c_id}},
      # This organisation's workspace marked for deletion, restored from another
      # organisation's settings: whether it exists is not told.
      {:"workspace.restore", :other_owner, "/:other_org/settings", "restore_workspace",
       %{"id" => :workspace_c_id}, answer: :not_found},

      # The security policy.
      {:"security_policy.set_mode", :member, "/:org/:workspace/policy", "mode_open",
       %{"mode" => "enforce"}},
      {:"security_policy.set_mode", :member, "/:org/:workspace/policy", "mode_set",
       %{"mode" => "enforce"}},
      {:"security_policy.set_mode", :demoted_admin, "/:org/:workspace/policy", "mode_set",
       %{"mode" => "enforce"}, prelude: [{"mode_open", %{"mode" => "enforce"}}]},
      {:"security_policy.set_mode", :member, "/:org/:workspace/targets/:target_page/-/policy",
       "mode_open", %{"mode" => "enforce"}},
      {:"security_policy.set_mode", :member, "/:org/:workspace/targets/:target_page/-/policy",
       "mode_set", %{"mode" => "enforce"}},
      {:"security_policy.edit", :removed_member, "/:org/:workspace/policy", "composer_save", %{},
       prelude: [{"composer_change", %{"rule" => %{"host" => "new.example", "paths" => ""}}}]},
      # Another organisation's owner, on its own policy, naming this one's rule.
      {:"security_policy.edit", :other_owner, "/:other_org/:other_ws/policy", "remove",
       %{"id" => :rule_open}, answer: :not_found},
      {:"security_policy.edit", :other_owner, "/:other_org/:other_ws/policy", "change_action",
       %{"id" => :rule_open}, answer: :not_found},
      {:"security_policy.edit", :other_owner,
       "/:other_org/:other_ws/targets/:target_page/-/policy", "remove", %{"id" => :rule_open},
       answer: :not_found},
      {:"security_policy.edit", :other_owner,
       "/:other_org/:other_ws/targets/:target_page/-/policy", "change_action",
       %{"id" => :rule_open}, answer: :not_found},
      {:"security_policy.lock", :member, "/:org/:workspace/policy", "lock_toggle",
       %{"id" => :rule_open}},
      # An admin locking a rule, unlocking one, and changing a locked one.
      {:"security_policy.lock", :admin, "/:org/:workspace/policy", "lock_toggle",
       %{"id" => :rule_open}},
      {:"security_policy.lock", :admin, "/:org/:workspace/policy", "lock_toggle",
       %{"id" => :rule_locked}},
      {:"security_policy.lock", :admin, "/:org/:workspace/policy", "change_action",
       %{"id" => :rule_locked}},
      {:"security_policy.lock", :demoted_owner, "/:org/:workspace/policy", "lock_toggle",
       %{"id" => :rule_open}},
      {:"security_policy.lock", :demoted_owner, "/:org/:workspace/policy", "composer_save", %{},
       prelude: [
         {"composer_change", %{"rule" => %{"host" => "locked.example", "paths" => ""}}}
       ]},
      {:"security_policy.lock", :member, "/:org/:workspace/policy", "remove_confirm", %{},
       prelude: [{"remove", %{"id" => :rule_locked}}]},
      # A member's deny of a rule that the owner locked after the composer read it.
      {:"security_policy.lock", :member, "/:org/:workspace/policy", "composer_save", %{},
       prelude: [
         {"composer_action", %{"action" => "deny"}},
         {"composer_change", %{"rule" => %{"host" => "open.example", "paths" => ""}}}
       ],
       meanwhile: {:locked, :rule_open}},
      # A member's allow for a target under the workspace's locked deny: the composer
      # reads the lock and saves nothing. The workspace's rules have no act on a target's
      # page: an event naming one there is dropped.
      {:"security_policy.lock", :member, "/:org/:workspace/targets/:target_page/-/policy",
       "composer_save", %{},
       prelude: [
         {"composer_change", %{"rule" => %{"host" => "locked.example", "paths" => ""}}}
       ],
       answer: :ignored},
      {:"security_policy.lock", :member, "/:org/:workspace/targets/:target_page/-/policy",
       "change_action", %{"id" => :rule_locked}, answer: :ignored},
      {:"security_policy.lock", :member, "/:org/:workspace/targets/:target_page/-/policy",
       "remove", %{"id" => :rule_locked}, answer: :ignored},

      # The nodes. Without the page or the confirmation open, from a member: refused, as
      # the page offers them no button.
      {:"node.create", :member, "/:org/:workspace/nodes", "create",
       %{"node" => %{"name" => "build-09"}}},
      {:"node.create", :demoted_admin, "/:org/:workspace/nodes/new", "create",
       %{"node" => %{"name" => "build-09"}}},
      {:"node.create", :removed_member, "/:org/:workspace/nodes", "create",
       %{"node" => %{"name" => "build-09"}}},
      {:"node.edit", :member, "/:org/:workspace/nodes/:node/settings", "save",
       %{"node" => %{"name" => "renamed"}}},
      {:"node.edit", :demoted_admin, "/:org/:workspace/nodes/:node/settings", "save",
       %{"node" => %{"name" => "renamed"}}},
      {:"node.edit", :removed_member, "/:org/:workspace/nodes/:node", "save",
       %{"node" => %{"name" => "renamed"}}},
      {:"node.delete", :member, "/:org/:workspace/nodes/:node/settings", "delete", %{}},
      {:"node.delete", :demoted_admin, "/:org/:workspace/nodes/:node/settings/delete", "delete",
       %{}},
      # A node's page is its path: another organisation's node is a 404 as the page opens.
      {:"node.edit", :other_owner, "/:other_org/:other_ws/nodes/:node/settings", "save",
       %{"node" => %{"name" => "renamed"}}, answer: :not_found_at_mount},
      {:"node.delete", :other_owner, "/:other_org/:other_ws/nodes/:node/settings/delete",
       "delete", %{}, answer: :not_found_at_mount},
      {:"node.clear_instance", :member, "/:org/:workspace/nodes/:node", "clear_instance", %{}},
      {:"node.clear_instance", :demoted_admin,
       "/:org/:workspace/nodes/:node/instances/:instance/clear", "clear_instance", %{}},
      {:"node.clear_instance", :removed_member, "/:org/:workspace/nodes/:node", "clear_instance",
       %{}},
      {:"node.clear_instance", :other_owner,
       "/:other_org/:other_ws/nodes/:node/instances/:instance/clear", "clear_instance", %{},
       answer: :not_found_at_mount},

      # A node's access keys and enrolment codes, its Access key tab. Without the page or
      # the confirmation open, from a member: refused, as the page offers them no button;
      # a demoted admin's page or confirmation was open, and the context refuses them. A
      # key made in a browser is sent from the tab here, where the page refuses it before
      # the context: Generate a key's page holds the hook's notices, hidden by a class,
      # which this case reads as alerts shown. The context's refusal of a demoted admin's
      # key is the Access key tab's test "an admin made a member since Generate a key
      # opened is refused by the context".
      {:"access_key.add", :member, "/:org/:workspace/nodes/:node/access-key", "generate_key",
       %{
         "key" => %{"label" => "sneaky", "public_key" => :public_key}
       }},
      {:"access_key.add", :removed_member, "/:org/:workspace/nodes/:node/access-key",
       "generate_key",
       %{
         "key" => %{"label" => "sneaky", "public_key" => :public_key}
       }},
      {:"access_key.add", :demoted_admin, "/:org/:workspace/nodes/:node/access-key",
       "generate_key",
       %{
         "key" => %{"label" => "sneaky", "public_key" => :public_key}
       }},
      # Get the command, on the tab: one click, no form.
      {:"access_key.create_code", :member, "/:org/:workspace/nodes/:node/access-key",
       "create_code", %{}},
      {:"access_key.create_code", :demoted_admin, "/:org/:workspace/nodes/:node/access-key",
       "create_code", %{}},
      # Get the command, in the overview's first-run box, which a member is offered no
      # button of: the page refuses them.
      {:"access_key.create_code", :member, "/:org/:workspace", "get_command", %{}},
      {:"access_key.revoke", :member, "/:org/:workspace/nodes/:node/access-key", "revoke", %{}},
      {:"access_key.revoke", :demoted_admin,
       "/:org/:workspace/nodes/:node/access-key/keys/:node_key/revoke", "revoke", %{}},
      {:"access_key.cancel_code", :member, "/:org/:workspace/nodes/:node/access-key",
       "revoke_code", %{}},
      {:"access_key.cancel_code", :demoted_admin,
       "/:org/:workspace/nodes/:node/access-key/codes/:code/revoke", "revoke_code", %{}},
      # A node's page is its path: another organisation's node is a 404 as the page opens.
      {:"access_key.add", :other_owner, "/:other_org/:other_ws/nodes/:node/access-key/generate",
       "generate_key",
       %{
         "key" => %{"label" => "sneaky", "public_key" => :public_key}
       }, answer: :not_found_at_mount},
      {:"access_key.create_code", :other_owner, "/:other_org/:other_ws/nodes/:node/access-key",
       "create_code", %{}, answer: :not_found_at_mount},
      {:"access_key.cancel_code", :other_owner,
       "/:other_org/:other_ws/nodes/:node/access-key/codes/:code/revoke", "revoke_code", %{},
       answer: :not_found_at_mount},

      # Stored secrets and variables, the workspace's settings' Secrets and variables, whose
      # pages need the `secrets` feature beside their actions' `security`. A member's page
      # has no dialog to open, so the event reaches the context function, or the page
      # refuses it for their role; a demoted admin's dialog was open.
      {:"secret.write", :member, "/:org/:workspace/settings/secrets", "create_secret",
       %{"secret" => %{"name" => "SNEAKY", "value" => "not-to-be-saved"}}, needs: :secrets},
      {:"secret.write", :member, "/:org/:workspace/settings/secrets", "delete_secret", %{},
       needs: :secrets},
      {:"secret.write", :removed_member, "/:org/:workspace/settings/secrets", "create_secret",
       %{"secret" => %{"name" => "SNEAKY", "value" => "not-to-be-saved"}}, needs: :secrets},
      {:"secret.write", :demoted_admin, "/:org/:workspace/settings/secrets/new", "create_secret",
       %{"secret" => %{"name" => "SNEAKY", "value" => "not-to-be-saved"}}, needs: :secrets},
      {:"secret.write", :demoted_admin, "/:org/:workspace/settings/secrets/:secret/change-value",
       "set_value", %{"secret_value" => %{"value" => "not-to-be-saved"}}, needs: :secrets},
      {:"secret.write", :demoted_admin, "/:org/:workspace/settings/secrets/:secret/add-value",
       "add_value",
       %{"secret_value" => %{"first_value_id" => "a", "value_id" => "b", "value" => "c"}},
       needs: :secrets},
      {:"secret.write", :demoted_admin, "/:org/:workspace/settings/secrets/:secret/edit",
       "update_secret", %{"secret" => %{"name" => "SNEAKY"}}, needs: :secrets},
      {:"secret.write", :demoted_admin, "/:org/:workspace/settings/secrets/:secret/delete",
       "delete_secret", %{}, needs: :secrets},
      # This organisation's secret, in a dialog of another organisation's path: the dialog
      # does not open, and the page says the secret is not there.
      {:"secret.write", :other_owner, "/:other_org/:other_ws/settings/secrets/:secret/delete",
       "delete_secret", %{}, answer: :refused_at_mount, needs: :secrets},
      {:"variable.edit", :member, "/:org/:workspace/settings/variables", "create_variable",
       %{"variable" => %{"name" => "SNEAKY", "value" => "x"}}, needs: :secrets},
      {:"variable.edit", :member, "/:org/:workspace/settings/variables", "lock_variable", %{},
       needs: :secrets},
      {:"variable.edit", :removed_member, "/:org/:workspace/settings/variables",
       "create_variable", %{"variable" => %{"name" => "SNEAKY", "value" => "x"}},
       needs: :secrets},
      {:"variable.edit", :demoted_admin, "/:org/:workspace/settings/variables/:variable/change",
       "change_variable", %{"variable" => %{"value" => "changed"}}, needs: :secrets},
      {:"variable.edit", :demoted_admin, "/:org/:workspace/settings/variables/:variable/lock",
       "lock_variable", %{}, needs: :secrets},
      {:"variable.edit", :demoted_admin, "/:org/:workspace/settings/variables/:variable/delete",
       "delete_variable", %{}, needs: :secrets},
      {:"variable.edit", :other_owner,
       "/:other_org/:other_ws/settings/variables/:variable/delete", "delete_variable", %{},
       answer: :refused_at_mount, needs: :secrets}
    ]
  end

  # Reads: a page asks them on mount and for what it shows, and changes nothing; their
  # refusals are the Access hook's (`test/apiary_web/access_test.exs`). The instance's own
  # jobs: no page offers them. The server contract: an access key's, at a signed request,
  # which the contract's tests refuse (`test/apiary_web/contract/`). Taken on the strength
  # of an invitation's token, which no role is: nobody is refused it by their level. The
  # release commands: run on the instance's host by whoever controls it, never offered by
  # a page (`test/apiary/instance_admin_test.exs`). A sign-up's: it creates an
  # organisation for a person who is not signed in, and asks no one's level; no page of
  # the core offers it to a signed-in person. An edition's: creating a workspace, which
  # no page of the core offers, and an edition's page does, with rows of its own. Linking
  # a stored secret to what uses it: no page links one, and the context's tests
  # refuse it. Nor does a page offer the connections (`test/apiary/connections_test.exs`).
  @impl true
  def exempt do
    %{
      reads: [
        :"run.read",
        :"run.read_log",
        :"security_policy.read",
        :"audit.read",
        :"node.read",
        :"secret.read",
        :"variable.read"
      ],
      jobs: [:"organisation.purge", :"workspace.purge", :"audit.prune"],
      contract: [:"run.post_events", :"run_configuration.fetch"],
      token: [:"invitation.accept"],
      release: [:"instance_admin.grant", :"instance_admin.revoke"],
      sign_up: [:"organisation.create"],
      edition: [:"workspace.create"],
      no_page: [
        :"secret.use",
        :"connection.read",
        :"connection.write"
      ]
    }
  end

  @impl true
  def setup(_world) do
    %{scope: owner} = sign_up_fixture()
    workspace_b = workspace_fixture(owner.organisation)
    workspace_c = workspace_fixture(owner.organisation)
    {:ok, _} = Deletion.delete_workspace(owner, workspace_c.id, workspace_c.slug)

    # The rules are the security policy's, which an instance without it does not have.
    {rule_open, rule_locked, secret, variable} =
      if :security in Apiary.Features.enabled() do
        {:ok, open} = Policy.allow(owner, nil, %{host: "open.example"})
        {:ok, locked} = Policy.deny(owner, nil, %{host: "locked.example", locked: true})
        {:ok, secret} = Secrets.create_secret(owner, %{name: "FORGE_TOKEN", value: "x"})

        {:ok, variable} =
          Variables.create_variable(owner, :workspace, %{name: "NODE_ENV", value: "production"})

        {open, locked, secret, variable}
      else
        {nil, nil, nil, nil}
      end

    target =
      Repo.insert!(%Target{
        organisation_id: owner.organisation.id,
        workspace_id: owner.workspace.id,
        system: "github.example",
        path: "acme/site",
        first_seen_at: DateTime.utc_now()
      })

    %{access_key: key} = access_key_fixture(owner)
    node = node_fixture(owner, name: "build-01")
    %{access_key: node_key} = node_key_fixture(owner, node)
    {:ok, code, _code} = Apiary.AccessKeys.create_enrolment_code(owner, node, %{})
    instance = instance_fixture(node, instance_id: "i_1")
    node_run_fixture(node, instance.instance_id)
    run = started_run(owner)
    %{invitation: invitation} = invitation_fixture(owner)
    admin = RefusalsCase.person(owner, :admin)
    member = RefusalsCase.person(owner, :member)
    second_owner = RefusalsCase.person(owner, :owner)
    other = sign_up_fixture()

    # The same path in the other organisation, whose page its owner names this one's ids
    # from.
    Repo.insert!(%Target{
      organisation_id: other.organisation.id,
      workspace_id: other.workspace.id,
      system: target.system,
      path: target.path,
      first_seen_at: DateTime.utc_now()
    })

    %{
      owner: owner,
      organisation: owner.organisation,
      workspace: owner.workspace,
      workspace_b: workspace_b,
      workspace_c: workspace_c,
      second_owner: second_owner,
      admin: admin,
      member: member,
      other_member: RefusalsCase.person(owner, :member),
      removed_member: member,
      demoted_admin: admin,
      demoted_owner: second_owner,
      other_owner: other,
      other_organisation: other.organisation,
      other_workspace: other.workspace,
      rule_open: rule_open,
      rule_locked: rule_locked,
      secret: secret,
      variable: variable,
      target: target,
      key: key,
      node: node,
      node_key: node_key,
      code: code,
      public_key: ed25519_key_pair().encoded,
      instance: instance,
      run: run,
      invitation: invitation
    }
  end

  @impl true
  def value(:org, world), do: world.organisation.slug
  def value(:workspace, world), do: world.workspace.slug
  def value(:workspace_b, world), do: world.workspace_b.slug
  def value(:other_org, world), do: world.other_organisation.slug
  def value(:other_ws, world), do: world.other_workspace.slug
  def value(:other_member, world), do: {:id, world.other_member.membership.id}
  def value(:second_owner, world), do: {:id, world.second_owner.membership.id}
  def value(:invitation, world), do: {:id, world.invitation.id}
  def value(:organisation_id, world), do: {:id, world.organisation.id}
  def value(:workspace_id, world), do: {:id, world.workspace.id}
  def value(:workspace_b_id, world), do: {:id, world.workspace_b.id}
  def value(:workspace_c_id, world), do: {:id, world.workspace_c.id}
  def value(:rule_open, world), do: {:id, world.rule_open.id}
  def value(:rule_locked, world), do: {:id, world.rule_locked.id}
  def value(:secret, world), do: world.secret.public_id
  def value(:variable, world), do: {:id, world.variable.id}
  def value(:target, world), do: {:id, world.target.id}
  # A target's page is its path alone where no other target of its workspace has it.
  def value(:target_page, world), do: world.target.path
  def value(:run, world), do: {:id, world.run.run_id}
  def value(:node, world), do: {:id, world.node.public_id}
  def value(:node_key, world), do: {:id, world.node_key.key_id}
  def value(:code, world), do: {:id, world.code.id}
  def value(:public_key, world), do: world.public_key
  def value(:instance, world), do: world.instance.instance_id
  def value(_name, _world), do: nil

  # The organisation, the other one, whose pages its owner sends this one's ids from, and
  # the member's account.
  @impl true
  def watched(world), do: [world.organisation, world.other_organisation, world.member.user]

  # The organisation marked for deletion by its owner.
  @impl true
  def before_page(:organisation_marked, world) do
    if is_nil(Repo.reload!(world.organisation).deletion_marked_at),
      do: {:ok, _} = Deletion.delete_organisation(world.owner, world.organisation.slug)

    :ok
  end

  def before_page(_step, _world), do: nil

  # The member is no longer of the organisation.
  @impl true
  def meanwhile(:removed_member, world) do
    {1, _} =
      Repo.delete_all(from m in Membership, where: m.id == ^world.removed_member.membership.id)

    :ok
  end

  def meanwhile(:demoted_admin, world), do: change_level(world, world.demoted_admin, :member)
  def meanwhile(:demoted_owner, world), do: change_level(world, world.demoted_owner, :admin)

  def meanwhile({:level, person, level}, world),
    do: change_level(world, Map.fetch!(world, person), level)

  # The rule is locked, as an owner locks it.
  def meanwhile({:locked, rule}, world) do
    %{id: id} = Map.fetch!(world, rule)
    Repo.update_all(from(r in Apiary.Policy.Rule, where: r.id == ^id), set: [locked: true])
    :ok
  end

  def meanwhile(_step, _world), do: nil

  # The level changed in the database, and the edition told, as the owner's change of it
  # tells it (`c:Apiary.Edition.membership_changed/5`): what the edition makes of a
  # demotion, it makes here too.
  defp change_level(world, person, level) do
    changed = RefusalsCase.put_level(person, level)
    :ok = Apiary.Edition.membership_changed(Repo, world.owner, :level, person.membership, changed)
  end
end
