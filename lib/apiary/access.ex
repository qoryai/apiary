defmodule Apiary.Access do
  import Ecto.Query, warn: false

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Dispatches.Dispatch
  alias Apiary.Access.Action
  alias Apiary.Adapters.Connection
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.{Edition, Features, Gateways}
  alias Apiary.Mail.Settings
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Invitation, Membership, Organisation, Workspace}
  alias Apiary.Repo
  alias Apiary.Runs.{Run, Sender}
  alias Apiary.Stages.Approvers
  alias Apiary.WorkItems.WorkItem

  @owners [:owner]
  # How many times `lock_organisations/1` takes the organisation rows before it gives up.
  @place_attempts 3
  @admins [:owner, :admin]
  @members [:owner, :admin, :member]
  @read "a read changes nothing"

  # Every action of the core, named once: the feature it belongs to (none: every instance
  # has it), what it is, the roles that hold it, whether it leaves an audit entry, and what
  # it is asked of. An edition adds its own (`c:Apiary.Edition.actions/0`). The access test
  # (`Apiary.AccessCase`) has rows for each, and fails for an action it has none for.
  @actions [
    # The organisation.
    Action.new(
      :"organisation.create",
      "create an organisation, of which the person is the first owner: at sign-up, which asks nothing here; an edition may let a signed-in person create one besides",
      asked_of: :new_organisation
    ),
    Action.new(:"organisation.rename", "rename the organisation",
      roles: @admins,
      asked_of: :organisation
    ),
    Action.new(
      :"organisation.delete",
      "delete the organisation: mark it, and everything in it, for purging after the grace period",
      roles: @owners,
      asked_of: :organisation
    ),
    Action.new(
      :"organisation.restore",
      "cancel the organisation's deletion during the grace period, which brings everything back",
      roles: @owners,
      asked_of: :organisation
    ),
    Action.new(
      :"organisation.purge",
      "purge an organisation marked for deletion once its grace period is over: every row it holds",
      roles: [:instance],
      asked_of: :organisation,
      audited:
        {:not,
         "an organisation's purge deletes its audit trail with it; the instance keeps one line " <>
           "of it in purged_organisations, which names no one"}
    ),
    # Its people.
    Action.new(
      :"member.read",
      "read the organisation's people: their memberships, levels and accounts, and the workspaces each reaches (Apiary.Organisations.list_members/1)",
      roles: @members,
      asked_of: :organisation,
      audited: {:not, @read}
    ),
    Action.new(:"member.invite", "invite a member, and see the pending invitations",
      roles: @admins,
      asked_of: :organisation
    ),
    Action.new(:"member.change_level", "change a person's level: owner, admin or member",
      roles: @owners,
      asked_of: :organisation
    ),
    Action.new(:"member.remove", "remove a member", roles: @admins, asked_of: :organisation),
    Action.new(:"invitation.revoke", "revoke a pending invitation",
      roles: @admins ++ [:instance],
      asked_of: :organisation
    ),
    Action.new(
      :"invitation.renew",
      "make a new link for a pending invitation, whose old link stops working at once",
      roles: @admins,
      asked_of: :organisation
    ),
    Action.new(
      :"invitation.accept",
      "accept an invitation: its token allows it, and no role, so nobody is asked",
      asked_of: :organisation
    ),
    Action.new(
      :"member.suspend",
      "suspend a person's membership: they act in the organisation no more until it is activated",
      roles: @admins,
      asked_of: :organisation
    ),
    Action.new(:"member.activate", "end the suspension of a person's membership",
      roles: @admins,
      asked_of: :organisation
    ),
    # The instance's admins, the owners of its organisation.
    Action.new(
      :"instance_admin.grant",
      "make an account an owner of the instance's organisation, an instance admin: a release command, which no role takes",
      asked_of: :organisation
    ),
    Action.new(
      :"instance_admin.revoke",
      "make an owner of the instance's organisation a member of it: a release command, which no role takes",
      asked_of: :organisation
    ),
    # An account's password, without mail, asked of the account.
    Action.new(
      :"account.password_link",
      "make a one-time link that sets an account's password: an instance admin while the instance sends no mail, or a release command, in the instance's role (Apiary.Accounts.build_password_link/3)",
      roles: @owners ++ [:instance],
      asked_of: :account,
      instance: true
    ),
    # The instance, in Instance settings and the pages only its admins open: the instance
    # organisation's owners, asked of that organisation.
    Action.new(
      :"instance.read",
      "read what only the instance's admins read: Instance settings, the documentation for instance admins, and the machine logs of a run's dispatch",
      roles: @owners,
      asked_of: :organisation,
      audited: {:not, @read},
      instance: true
    ),
    Action.new(
      :"instance.read_machine",
      "read the vendor's type of the machine that a run's dispatch started, on the run's page",
      roles: @owners,
      asked_of: :organisation,
      audited: {:not, @read},
      instance: true
    ),
    Action.new(
      :"instance.review_connections",
      "finish or skip the review of the instance's connections, in Instance settings › Set up (Apiary.Setup.review_connections/1)",
      roles: @owners,
      asked_of: :organisation,
      audited:
        {:not,
         "the review is kept on the instance's set-up, connections_reviewed_at, not in the audit trail"},
      instance: true
    ),
    # The instance's mail, in Instance settings › Mail.
    Action.new(
      :"instance.mail_save",
      "save the mail settings, which sends a test link to the admin who saved them, after a recent sign-in (Apiary.Mail.save_settings/3)",
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    Action.new(
      :"instance.mail_resend",
      "send the test link of the saved mail settings again: the instance admin who saved them, after a recent sign-in, while mail waits for that link (Apiary.Mail.resend_test_link/2)",
      roles: @owners,
      asked_of: :mail_settings,
      instance: true
    ),
    Action.new(
      :"instance.mail_on",
      "turn the saved mail settings on by the test link their save sent: the instance admin who saved them, after a recent sign-in (Apiary.Mail.turn_on/2)",
      roles: @owners,
      asked_of: :mail_settings,
      instance: true
    ),
    # The product's name on the instance, in Instance settings › General.
    Action.new(
      :"instance.rename",
      "set the product's name on the instance (Apiary.ProductName.rename/2)",
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    # The instance's settings, in Instance settings › Configuration.
    Action.new(
      :"instance.configure",
      "change the instance's settings in Instance settings › Configuration and its machine types in Instance settings › Machine types, after a recent sign-in (Apiary.InstanceConfig.save/3, Apiary.MachineTypes)",
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    # The support address, in Instance settings › General.
    Action.new(
      :"instance.support_save",
      "save the support address, where Contact support leads (Apiary.SupportAddress.save/2)",
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    # The instance's features, in Instance settings › Features.
    Action.new(
      :"instance.features_save",
      "turn the instance's features on and off (Apiary.Features.Saved.save/3)",
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    # The audit trail.
    Action.new(:"audit.read", "read the organisation's audit trail, its Activity page",
      roles: @admins,
      asked_of: :organisation,
      audited: {:not, @read}
    ),
    Action.new(:"audit.prune", "delete the audit entries older than the instance keeps them",
      roles: [:instance],
      asked_of: :organisation
    ),
    # The workspace.
    Action.new(
      :"workspace.create",
      "create a workspace of the organisation, which starts empty, while the edition's limit allows another; in the core, the first one, from the kind cards of the organisation's overview",
      roles: @owners,
      asked_of: :organisation
    ),
    Action.new(:"workspace.rename", "rename the workspace", roles: @admins),
    Action.new(
      :"workspace.delete",
      "delete a workspace of the organisation: mark it for purging after the grace period",
      roles: @admins,
      asked_of: :organisation
    ),
    Action.new(
      :"workspace.restore",
      "cancel a workspace's deletion during the grace period, which brings it back with its keys",
      roles: @admins,
      asked_of: :organisation
    ),
    Action.new(
      :"workspace.purge",
      "purge a workspace marked for deletion once its grace period is over: every row it holds",
      roles: [:instance]
    ),
    # The access keys of nodes and node pools: one Ed25519 public key each.
    Action.new(
      :"access_key.create_code",
      "make an enrolment code for a machine, pool or gateway, with the settings of the key it brings",
      part: :nodes,
      roles: @admins
    ),
    Action.new(
      :"access_key.cancel_code",
      "cancel the outstanding enrolment code of a machine, pool or gateway",
      part: :nodes,
      roles: @admins
    ),
    Action.new(
      :"access_key.add",
      "add an access key to a machine, pool or gateway by its public key",
      part: :nodes,
      roles: @admins
    ),
    Action.new(:"access_key.revoke", "revoke an access key of a machine, pool or gateway",
      part: :nodes,
      roles: @admins
    ),
    # The instance's diagnostics keys, which read the diagnostics of every run, in Instance
    # settings › Diagnostics keys (`Apiary.AccessKeys`): instance actions.
    Action.new(
      :"instance.read_observability",
      "read the instance's diagnostics keys and the person who made each one's code",
      feature: :observability,
      roles: @owners,
      asked_of: :organisation,
      audited: {:not, @read},
      instance: true
    ),
    Action.new(
      :"diagnostics_key.create",
      "make an enrolment code for a diagnostics key, after a recent sign-in (Apiary.AccessKeys.create_diagnostics_code/2)",
      feature: :observability,
      roles: @owners,
      asked_of: :organisation,
      audited: {:not, "the code is recorded as access_key.create_code, the entry of every code"},
      instance: true
    ),
    Action.new(
      :"diagnostics_key.revoke",
      "revoke a diagnostics key (Apiary.AccessKeys.revoke_diagnostics_key/2)",
      feature: :observability,
      roles: @owners,
      asked_of: :organisation,
      audited:
        {:not, "the revocation is recorded as access_key.revoke, the entry of every key's"},
      instance: true
    ),
    # The workspace's nodes and node pools, the places its runs run.
    Action.new(:"node.read", "read the workspace's machines and pools, and each one's page",
      part: :nodes,
      roles: @members,
      audited: {:not, @read}
    ),
    Action.new(
      :"node.create",
      "make a machine or a pool, whose kind is fixed from then on",
      part: :nodes,
      roles: @admins
    ),
    Action.new(:"node.edit", "rename a machine or a pool", part: :nodes, roles: @admins),
    Action.new(
      :"node.set_limit",
      "set a pool's machine limit, as it is made or after",
      part: :nodes,
      roles: @admins,
      audited:
        {:not,
         "a pool's limit is set in the node's creation or its edit, whose entry, node.create or " <>
           "node.edit, records it with what else the change made"}
    ),
    Action.new(:"node.delete", "delete a machine or a pool", part: :nodes, roles: @admins),
    Action.new(
      :"node.clear_instance",
      "clear a machine that stopped without reporting that it stopped: its open runs are marked lost, and another machine can start",
      part: :nodes,
      roles: @admins
    ),
    # The record.
    Action.new(:"run.read", "read the runs, their outcomes and the connections",
      feature: :observability,
      roles: @members,
      audited: {:not, @read}
    ),
    Action.new(:"run.read_log", "read a run's log: its terminal, stdout and stderr",
      feature: :observability,
      part: :"observability.terminal",
      roles: @members,
      audited: {:not, @read}
    ),
    Action.new(:"retention.edit", "set how long the record is kept",
      feature: :observability,
      roles: @admins
    ),
    # The security policy.
    Action.new(:"security_policy.read", "read the security policy",
      feature: :security,
      roles: @members,
      audited: {:not, @read}
    ),
    Action.new(
      :"security_policy.edit",
      "add, change and remove the rules that are not locked",
      feature: :security,
      roles: @members
    ),
    Action.new(
      :"security_policy.lock",
      "lock and unlock a rule, and change or remove a locked one",
      feature: :security,
      roles: @owners
    ),
    Action.new(:"security_policy.set_mode", "set the mode, observe or enforce",
      feature: :security,
      roles: @admins
    ),
    # Stored secrets and variables.
    Action.new(
      :"secret.read",
      "read the stored secrets: their names, notes and value IDs, never a value",
      feature: :secrets,
      roles: @members,
      audited: {:not, @read}
    ),
    Action.new(
      :"secret.write",
      "create a stored secret, change its name, note and values, and delete it",
      feature: :secrets,
      roles: @admins
    ),
    Action.new(
      :"secret.use",
      "link a stored secret to what uses it",
      feature: :secrets,
      roles: @admins,
      audited:
        {:not, "a link is part of the change to what uses the secret, which leaves its own entry"}
    ),
    Action.new(:"variable.read", "read the variables of the workspace and its targets",
      feature: :secrets,
      roles: @members,
      audited: {:not, @read}
    ),
    Action.new(
      :"variable.edit",
      "set, change, lock and remove the variables of the workspace and its targets",
      feature: :secrets,
      roles: @admins
    ),
    # What a run is connected to: runtimes, integrations, services and model providers.
    Action.new(
      :"connection.read",
      "read the runtimes, integrations and services of the organisation, where each applies, the releases fetched and the organisation's service definitions",
      feature: :secrets,
      roles: @members,
      asked_of: :organisation,
      audited: {:not, @read}
    ),
    Action.new(
      :"connection.write",
      "add, change and remove an integration or a service, and where and how it applies; fetch an integration's release; write the organisation's service definitions",
      feature: :secrets,
      roles: @admins,
      asked_of: :organisation
    ),
    Action.new(
      :"provider.write",
      "add, change and remove a model provider and its keys, and where and how it applies; set the organisation's default model choice",
      feature: :secrets,
      roles: @admins,
      asked_of: :organisation
    ),
    Action.new(
      :"runtime.write",
      "add, change and remove a runtime, and where and how it applies",
      feature: :secrets,
      roles: @admins,
      asked_of: :organisation
    ),
    # The model a run uses: the choices of the workspace and its targets, which need the
    # features `factory` and `secrets` both (`Apiary.ModelChoices`).
    Action.new(
      :"model_choice.write",
      "set, change, lock and remove the model choices of the workspace and its targets",
      feature: :factory,
      roles: @admins
    ),
    # How long a run of a workflow may take: the limits of the workspace and its targets
    # (`Apiary.TimeLimits`).
    Action.new(
      :"time_limit.edit",
      "set, change and remove the time limits of the workspace and its targets",
      feature: :factory,
      roles: @admins
    ),
    # The server contract.
    Action.new(:"run.post_events", "open a run and post its events",
      feature: :observability,
      roles: [:access_key, :pool_key],
      audited: {:not, "the events the gateway posts are the record, not the audit trail"}
    ),
    Action.new(:"run_configuration.fetch", "fetch the run configuration",
      feature: :security,
      roles: [:access_key, :pool_key],
      audited: {:not, "the gateway's fetch reads the policy and changes nothing"}
    ),
    # A diagnostics key's one action, asked of a run of any organisation
    # (`ApiaryWeb.Contract.DiagnosticsController`, `key_subject/4`).
    Action.new(:"run.read_diagnostics", "read the diagnostics of a run with a diagnostics key",
      feature: :observability,
      roles: [:diagnostics_key],
      audited: {:not, @read}
    ),
    # A diagnostics key's run list, asked of a run with no organisation and no workspace,
    # `%Run{}`, which stands for every run of the instance
    # (`ApiaryWeb.Contract.RunListController`, `key_subject/4`).
    Action.new(
      :"run.list_instance",
      "list the runs of every workspace of the instance with a diagnostics key",
      feature: :observability,
      roles: [:diagnostics_key],
      audited: {:not, @read}
    ),
    # A gateway's secrets request: a run's model key, sealed to the gateway's access key
    # (`Apiary.Runs.SecretsRequest`), which asks this of the run for a request that names
    # the key. The key is held to what its gateway may serve (`key_subject/4`). The run key,
    # the sender and `allow_secrets` are the secrets request's to check: data of the run and
    # of the key it verified under.
    Action.new(:"secret.seal", "seal a run's model key to the gateway's access key",
      feature: :factory,
      roles: [:access_key]
    ),
    # A gateway's secrets request for a run's work entry: a credential the entry's adapter
    # issues for the run, sealed to the gateway's access key (`Apiary.Runs.WorkCredential`),
    # which asks this of the run before the call and again as it records the credential.
    # Each attempt is recorded, issued or refused. The key is held as for `secret.seal`.
    Action.new(
      :"run_credential.issue",
      "issue a run's work credential from its adapter and seal it to the gateway's access key",
      feature: :factory,
      roles: [:access_key]
    ),
    # The instance's adapters: an organisation's people read them and connect them; an
    # instance admin reads every one, with its access keys and codes, and the instance's
    # pool and gateway, makes, renames and deletes them and sets how often they pull, as
    # instance actions (`Apiary.Adapters`). The instance alone installs the adapters its
    # setting lists, and gives them their codes. An instance admin starts an adapter's
    # set-up at the system it reads from, and changes its access keys and codes, as
    # `adapter.setup` (`Apiary.AccessKeys`).
    Action.new(:"adapter.read", "read the instance's adapters",
      feature: :factory,
      roles: @members,
      asked_of: :organisation,
      audited: {:not, @read}
    ),
    Action.new(
      :"instance.read_factory",
      "read the instance's adapters, its pool and its gateway, with their access keys and codes, how often each adapter pulls, and its machine types",
      feature: :factory,
      roles: @owners,
      asked_of: :organisation,
      audited: {:not, @read},
      instance: true
    ),
    Action.new(:"adapter.create", "make an adapter of the instance, after a recent sign-in",
      feature: :factory,
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    Action.new(:"adapter.edit", "rename an adapter",
      feature: :factory,
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    Action.new(:"adapter.set_interval", "set how often an adapter pulls",
      feature: :factory,
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    Action.new(:"adapter.delete", "delete an adapter, which revokes its access keys",
      feature: :factory,
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    Action.new(
      :"adapter.install",
      "make an adapter installed with Qory Apiary, and give it its one-time codes: the instance, by itself (Apiary.Adapters.install/2)",
      feature: :factory,
      roles: [:instance],
      asked_of: :organisation
    ),
    Action.new(
      :"node.install",
      "make the instance's pool or gateway, and give it its one-time codes: the instance, by itself (Apiary.Nodes.Installed.install/2)",
      feature: :factory,
      roles: [:instance],
      asked_of: :organisation
    ),
    Action.new(
      :"adapter.setup",
      "start setting an adapter up at the system it reads from, with a new setup pass, and change its access keys and codes",
      feature: :factory,
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    Action.new(
      :"node.set_instance_limit",
      "set the machine limit of the instance's pool (Apiary.Nodes.Installed.set_instance_limit/3)",
      feature: :factory,
      roles: @owners,
      asked_of: :organisation,
      audited: {:not, "the change is recorded as node.set_limit, the entry of a pool's limit"},
      instance: true
    ),
    Action.new(:"adapter.connect", "connect an adapter to the system it reaches",
      feature: :factory,
      roles: @admins,
      asked_of: :organisation
    ),
    # What an adapter reports, each assigned to a workspace of the organisation.
    Action.new(:"collection.assign", "assign what an adapter reports to a workspace",
      feature: :factory,
      roles: @admins,
      asked_of: :organisation
    ),
    # Whether the items of what an adapter reports come into its workspace's Backlog.
    Action.new(
      :"collection.set_backlog",
      "choose whether the items of a collection come into its workspace's Backlog",
      feature: :factory,
      roles: @admins,
      asked_of: :organisation
    ),
    # A collection whose adapter now lists its ref under another connection: ended as a
    # disconnect ends it, after the listing's part that names it there.
    Action.new(
      :"collection.move",
      "end a collection whose adapter now lists it under another connection: the instance, by itself, after the listing's part (Apiary.Adapters.Collections.post_listing/2)",
      feature: :factory,
      roles: [:instance],
      asked_of: :organisation
    ),
    # A workspace's work items, people's actions. A comment's author may delete it too,
    # while they may still comment (`author?/3`).
    Action.new(:"work_item.read", "read the workspace's work items",
      feature: :factory,
      roles: @members,
      audited: {:not, @read}
    ),
    Action.new(:"work_item.take_in", "take an item in as a work item of the workspace",
      feature: :factory,
      roles: @members
    ),
    Action.new(:"work_item.undo", "undo the taking in of a work item",
      feature: :factory,
      roles: @members
    ),
    Action.new(:"work_item.close", "close a work item", feature: :factory, roles: @members),
    Action.new(:"work_item.answer", "answer Qory's questions on a work item",
      feature: :factory,
      roles: @members
    ),
    Action.new(
      :"work_item.review_comment",
      "write a comment on a stage's outputs or round for a work item, reply to one, and send the open ones to the stage's next run. When the work item's stage lists approvers, only those people take it.",
      feature: :factory,
      roles: @members,
      audited:
        {:not,
         "a comment, a reply and a send each leave the entry of work_item.answer, with the move's details (Apiary.WorkItems.Moves)"}
    ),
    Action.new(:"work_item.confirm", "approve the proposal for a work item",
      feature: :factory,
      roles: @members
    ),
    Action.new(:"work_item.explore_again", "run Explore again on a work item",
      feature: :factory,
      roles: @members
    ),
    Action.new(:"work_item.comment", "comment on a work item",
      feature: :factory,
      roles: @members
    ),
    Action.new(:"work_item.comment_delete", "delete a comment on a work item",
      feature: :factory,
      roles: @admins
    ),
    # A workspace's process, its stages and the artifacts its work items keep
    # (`Apiary.Processes`). An action that no function takes yet says so in `audited`; the
    # function that takes it makes it audited, with its entry.
    Action.new(
      :"process.edit",
      "save a version of the workspace's process, as a trial or as the current one, make a trial current or drop it, assign a work item to a version, export it, update it from its harness, and turn on or off Keep the process at the latest",
      feature: :workflow_model,
      roles: @admins
    ),
    Action.new(
      :"gate.approve",
      "approve a stage's gate on a work item, move a work item past a stage, and act on an escalation. When a stage lists approvers, only those people approve its gate.",
      feature: :workflow_model,
      roles: @members
    ),
    Action.new(:"artifact.write", "store a version of an artifact on a work item",
      feature: :workflow_model,
      roles: @members
    ),
    Action.new(:"artifact_type.edit", "add, change or remove the workspace's artifact types",
      feature: :workflow_model,
      roles: @admins
    ),
    # A workspace type's default process, which new workspaces copy, in Instance settings
    # › Workspace types (`Apiary.Processes.TypeTemplates`).
    Action.new(
      :"workspace_type.edit",
      "save a version of a workspace type's default process, which new workspaces copy (Apiary.Processes.TypeTemplates.save/4)",
      feature: :workflow_model,
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    # › Machine types, a key change (`Apiary.MachineTypes.update/3`).
    Action.new(
      :"machine_type.rekey",
      "rewrite the machine type key in every workspace type and process that uses it, when an instance admin changes the key",
      feature: :workflow_model,
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    # An adapter's key at the server contract, asked of the adapter itself.
    Action.new(
      :"adapter.declare",
      "say where a person is sent to connect the adapter and how often it pulls",
      feature: :factory,
      roles: [:adapter_key],
      asked_of: :organisation
    ),
    Action.new(:"source_item.post", "post the items of a source",
      feature: :factory,
      roles: [:adapter_key],
      asked_of: :organisation,
      audited: {:not, "the items an adapter posts are kept as they are, not in the audit trail"}
    ),
    Action.new(:"work_item.read_changes", "read what changed of the work items",
      feature: :factory,
      roles: [:adapter_key],
      asked_of: :organisation,
      audited: {:not, @read}
    ),
    # The secrets an adapter stores in Qory Apiary (`Apiary.Secrets.Instance`): its upload
    # replaces them, in the trail of the instance's organisation.
    Action.new(:"adapter.app_values_set", "store the secrets the adapter keeps in Qory",
      feature: :factory,
      roles: [:adapter_key],
      asked_of: :organisation
    ),
    # The adapter's read of those secrets, sealed to the key that asks: each read is an
    # entry, in the same trail.
    Action.new(:"adapter.app_values_seal", "read the secrets the adapter keeps in Qory",
      feature: :factory,
      roles: [:adapter_key],
      asked_of: :organisation
    ),
    Action.new(:"adapter.disconnect", "end a connection of the adapter",
      feature: :factory,
      roles: [:adapter_key],
      asked_of: :organisation,
      audited:
        {:not,
         "an adapter's end of a connection is kept on the connection, its end and its reason, not in the audit trail"}
    ),
    # The grants of an organisation's connection (`Apiary.Adapters.Grants`): the adapter's
    # report of one, and its report that the source no longer covers one, each in the
    # trail of the instance's organisation, and its read of them all.
    Action.new(:"adapter.report_grant", "report a grant of a connection of the adapter",
      feature: :factory,
      roles: [:adapter_key],
      asked_of: :organisation
    ),
    Action.new(:"adapter.end_grant", "end a grant of a connection of the adapter",
      feature: :factory,
      roles: [:adapter_key],
      asked_of: :organisation
    ),
    Action.new(:"adapter.read_grants", "read the grants of the adapter's connections",
      feature: :factory,
      roles: [:adapter_key],
      asked_of: :organisation,
      audited: {:not, @read}
    ),
    # The harness a run uses: the harness documents of an organisation's levels
    # (`Apiary.Stacks`), and the instance's assignments of harness sources
    # (`Apiary.Harnesses`), which an instance admin creates and deletes, as instance
    # actions.
    Action.new(
      :"harness.save",
      "save a harness document at a level of the organisation: its default, a workspace or a target, with or without a workflow",
      feature: :factory,
      roles: @admins,
      asked_of: :organisation,
      audited:
        {:not,
         "Workspace settings › Harness saves the workspace's document through Apiary.Stacks.Sources.save/3, which writes no entry, as Apiary.Stacks.put_stack/3 writes none"}
    ),
    Action.new(
      :"harness.assigned",
      "let the runs of one organisation, or of every organisation, use the instance's links for a harness source, after a recent sign-in (Apiary.Harnesses.assign/3)",
      feature: :factory,
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    Action.new(
      :"harness.unassigned",
      "delete an instance assignment of a harness source, after a recent sign-in (Apiary.Harnesses.unassign/2)",
      feature: :factory,
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    # A node pool's key at the server contract, on the runs dispatched to its workspace:
    # one queue per workspace, which any pool of the workspace claims from. Asked of the
    # workspace, its queue, or of a dispatch of it the key's pool claimed (`key_subject/4`).
    Action.new(:"dispatch.claim", "claim a run waiting in the workspace's queue",
      feature: :factory,
      roles: [:pool_key],
      audited:
        {:not,
         "a claim is kept on its dispatch, with the key that claimed it, not in the audit trail"}
    ),
    Action.new(:"dispatch.dispatched", "say that a claimed run's machine was started",
      feature: :factory,
      roles: [:pool_key],
      audited:
        {:not,
         "the start of a claimed run's machine is kept on its dispatch, not in the audit trail"}
    ),
    Action.new(:"dispatch.release", "give a claimed run back before its machine exists",
      feature: :factory,
      roles: [:pool_key]
    ),
    # The further repositories a target's runs also read (`Apiary.Targets`).
    Action.new(
      :"target.set_further_repositories",
      "choose the other targets that runs of a target also read",
      feature: :factory,
      roles: @admins
    ),
    Action.new(:"dispatch.machine_log", "upload the log of a claimed run's machine",
      feature: :factory,
      roles: [:pool_key],
      audited:
        {:not,
         "a machine log is kept as a file with its record, which has its size and when it was uploaded, not in the audit trail"}
    ),
    # The trail keeps three entries of a dispatch at most: its first report, its first
    # `delete_failed` and its `gone` (`Apiary.Dispatches.MachineEnds`).
    Action.new(:"dispatch.machine_end", "report the removal of a claimed run's machine",
      feature: :factory,
      roles: [:pool_key]
    ),
    # A member asks for a build of a target's environment, for each node pool of its
    # workspace (`Apiary.Environments.rebuild/2`).
    Action.new(:"target.rebuild_environment", "rebuild the environment of a target",
      feature: :factory,
      roles: @members
    )
  ]

  # The actions a node pool's key takes on the runs dispatched to its workspace.
  @dispatch_actions [
    :"dispatch.claim",
    :"dispatch.dispatched",
    :"dispatch.release",
    :"dispatch.machine_log",
    :"dispatch.machine_end"
  ]

  # The features whose actions the tables of this documentation leave out: those the
  # documentation does not differ by (`docs: false`), which no doc names.
  @undocumented Features.core_undocumented()

  # The core's roles, with who holds each: a membership's level, the access key of a node,
  # a gateway, a node pool or an adapter, or the instance itself. An edition adds its own
  # (`c:Apiary.Edition.roles/0`).
  @roles [
    member: "a person at member, in the workspaces their level reaches",
    admin: "a person at admin, in every workspace; over members only",
    owner: "a person at owner, in every workspace",
    access_key: "a node or a gateway, with a key of the workspace",
    pool_key: "a node pool, with a key of the workspace",
    diagnostics_key: "a diagnostics key of the instance, on any run of it",
    adapter_key: "an adapter of the instance, with a key enrolled on it, on that adapter",
    instance: "the instance itself, in a job no person enqueued"
  ]

  # The actions over people, and the levels each role may take them on: the level of the
  # membership changed or removed; an invitation, sent or revoked, is at member, the level
  # its person joins at. An owner acts on anyone, an admin on members only.
  @over_people [
    :"member.invite",
    :"member.change_level",
    :"member.remove",
    :"member.suspend",
    :"member.activate",
    :"invitation.revoke",
    :"invitation.renew"
  ]
  @acts_on %{owner: [:owner, :admin, :member], admin: [:member]}

  # Suspending and activating a membership: an owner over admins and members, an admin
  # over members. An owner is not suspended by another.
  @suspends [:"member.suspend", :"member.activate"]
  @suspends_over %{owner: [:admin, :member], admin: [:member]}

  # The level of the instance organisation's people who are the instance admins.
  @instance_admin_level :owner

  # The instance actions asked of an account, which is no organisation's, and of the mail
  # settings, which are the instance's: the others are asked of the instance organisation.
  @instance_on_accounts [:"account.password_link"]
  @instance_on_mail_settings [:"instance.mail_resend", :"instance.mail_on"]

  # The instance actions that only the instance admin who saved the mail settings takes
  # on them (`one_person/3`): sending their test link again, and turning mail on by it.
  @saver_only [:"instance.mail_resend", :"instance.mail_on"]

  # The instance actions that nobody takes on the account they are signed in with: a
  # password link, which would get around the recent sign-in of Account settings.
  @not_own_account [:"account.password_link"]

  # What nobody takes on their own membership: an owner does not suspend themselves, and
  # nobody activates their own.
  @not_own [:"member.suspend", :"member.activate"]

  # What anyone with a membership may take on their own, at any level: leaving the
  # organisation. The last-owner rule still holds (`Apiary.Organisations`).
  @own [:"member.remove"]

  # What anyone may take on what they wrote, by the action they wrote it with, while their
  # role still holds that one (`author?/3`): deleting their comment on a work item.
  @authored %{"work_item.comment_delete": :"work_item.comment"}

  # What only the approvers of the stage a work item is in take on it, where the stage
  # lists them (`check_approver/3`): approving its gate, confirming Explore's proposal,
  # which approves Explore's gate, and the comments on a stage's outputs or round.
  @approver_actions [:"gate.approve", :"work_item.confirm", :"work_item.review_comment"]

  # What a diagnostics key takes, asked of a run of any organisation, or of `%Run{}` for
  # the runs of the instance (`subject_place/3`, `key_subject/4`).
  @diagnostics_actions [:"run.read_diagnostics", :"run.list_instance"]

  # What a gateway's key takes at the server contract. Asked of a run, it is held to what
  # the gateway may serve (`key_subject/4`).
  @gateway_actions [
    :"run.post_events",
    :"run_configuration.fetch",
    :"secret.seal",
    :"run_credential.issue"
  ]

  # What may still be done to an organisation or a workspace marked for deletion: cancel
  # the deletion, and purge it once its grace period is over. Nothing else is.
  @on_marked [
    :"organisation.restore",
    :"workspace.restore",
    :"organisation.purge",
    :"workspace.purge"
  ]

  @moduledoc """
  Whether someone may do something, answered in one place: may `scope` take `action` on
  `subject`? `can?/3` answers yes or no, `authorize/3` says why not.

  - **`scope`** is who is asking and from where: an `Apiary.Accounts.Scope` of a person,
    with the organisation they reach, their membership there, how they reach it beyond
    one when the edition says so (its `reach`) and the workspace the page's path names,
    of an access key at the server contract (`Apiary.Accounts.Scope.for_access_key/1`),
    or of the instance, for a job no person enqueued
    (`Apiary.Accounts.Scope.for_instance/2`). Any other scope without a person may
    nothing.
  - **`action`** is a verb of the engine, one of `actions/0`, each an
    `Apiary.Access.Action` named once, with the feature it belongs to, and the part where
    it belongs to one, a part of its feature or, for an action of no feature, a part of
    none, in the table below; an edition adds further actions
    (`c:Apiary.Edition.actions/0`). The registry of both is built once, checked, and kept
    for the node: an action named twice, a role or a feature nobody knows, or a part that
    is not one of its feature's, or of no feature for an action of none, stops it. An
    action that is in neither raises `ArgumentError`.
  - **`subject`** is the thing acted on: an organisation, a workspace, or a row of one, such
    as a run, a rule, an access key, a node, an invitation or a membership, which carries
    `organisation_id`, and `workspace_id` when it belongs to a workspace. Deleting a
    workspace and cancelling its deletion are asked of the organisation: an owner or an
    admin deletes any workspace of it, from the organisation's settings.

  The answer is read in this order:

  1. **The feature** the action belongs to, or the part (`shown_as/1`,
     `Apiary.Features.visible?/2`). An action of a feature that is off, or of a feature or
     a part hidden from the scope's person, is `{:error, :not_found}`: a feature that is
     off or hidden is absent, not forbidden, and so is a hidden part.
  2. **The edition** (`c:Apiary.Edition.check/3`), asked once: it may answer, for what it
     adds or narrows, or leave the answer to the steps below. The core's edition
     leaves every answer to them.
  3. **Where the subject is** (`check_place/3`). A subject of another organisation, or of
     another workspace than the scope's, is `{:error, :not_found}`, so the answer does not
     tell that it exists. Two keys answer for a run in another way: a gateway's key, on
     what it takes at the server contract, for a run of a workspace it may serve
     (`may_serve?/2`), and a diagnostics key, on `run.read_diagnostics`, for a run of any
     organisation, and on `run.list_instance`, for the runs of the instance, asked of a
     run with no organisation, `%Run{}`.
  4. **Whether the person reaches the workspace.** A membership is the organisation's; the
     levels of `c:Apiary.Edition.every_workspace_levels/0` reach every workspace of it, in
     the core's edition all three, and the edition says which workspaces another level
     reaches (`c:Apiary.Edition.reaches_workspace?/3`), from what the scope carries. A
     subject of a workspace the person does not reach is `{:error, :not_found}` too, as
     a workspace of another organisation would be. What the organisation itself owns, its
     name, its members and its trail, needs no workspace.
  5. **Whether it is marked for deletion** (`Apiary.Deletion`). When the scope's
     organisation or workspace, or a subject that is an organisation or a workspace, is
     marked, every action is `{:error, :not_found}`, as for one that is gone, but those
     of `on_marked/0`: cancelling the deletion, and the purge. The marks are read with
     the membership (`reload/2`), so a page opened before the marking acts on nothing
     after it.
  6. **Whose membership it is.** Anyone with a membership may leave the organisation,
     `member.remove` of their membership, whatever their level (`own/0`); the rule
     that an organisation keeps an owner still holds (`Apiary.Organisations`). Nobody
     suspends or activates their membership.
  7. **The role** of the one asking (`role/1`), in the role table below. An action the
     role does not hold is `{:error, :forbidden}`, and so is every action for a person
     without a membership where the scope is, unless the edition gives them a role there;
     the page decides whether it says forbidden or not found.
  8. **Whom the action is over**, for the actions over people: inviting, changing a
     level, removing, suspending, activating, and revoking an invitation or making a new
     link for it. An owner takes
     them over anyone (suspending and activating over admins and members), within the
     rule that an organisation keeps an owner (`Apiary.Organisations`); an admin over
     members only, never over an owner or an admin (`acts_on?/2`). Asked of the
     membership, whose level decides, or of the invitation, which is at member: an
     invitation is an email address, and its person joins as a member; asked of a
     workspace or the organisation, as a page asks whether to show the button at all, the
     role alone answers. A level other than the role allows is `{:error, :forbidden}`. An
     invitation is the organisation's, whichever workspace it grants.
  9. **The stage's approvers**, for approving a stage's gate, approving Explore's
     proposal and the comments on a stage's outputs or round (`gate.approve`,
     `work_item.confirm`, `work_item.review_comment`), asked of a work item. Where the
     stage the work item is in lists approvers, a person who is not among them is
     `{:error, :not_approver}`.
     Every person the role allows may with the workflow model off, on a work item the
     runner did not place, and at a stage that lists none. An answer to the questions
     (`work_item.answer`) is every member's. Asked of a workspace, as a page asks whether
     to show the gates at all, the role alone answers; asked of any other subject, these
     actions are `{:error, :not_approver}`. The answer reads the work item's process
     version, unless the work item has it loaded.

  A context function that changes something asks `authorize/3` before it acts: that is the
  check that counts. It reads the person's membership again from the database, with what
  the edition put on the scope, because what a scope carries may be as old as the
  LiveView that holds it. A page asks `can?/3`, with the same action, for what it shows:
  a button for an action the reader may not take is not rendered. `can?/3` uses the scope
  as it was loaded, so a page may call it on every render. It reads the database in two
  cases, beyond whatever the edition's check (`c:Apiary.Edition.check/3`) reads: step 9
  reads a work item's process version when the work item does not have it loaded, and an
  instance action reads the instance organisation's id at most once per call, in a scope
  without the id, and not when the action's feature is off. A scope from `reload/2` has no
  such id, so `authorize/3` compares with the id as the database has it now. A
  context function that asks several questions in one change reads once with `reload/2`
  and asks each with `check/3`.

  ## Actions

  | Action | What | Feature |
  |---|---|---|
  #{@actions |> Enum.reject(&(&1.feature in @undocumented)) |> Enum.map_join("\n", fn action -> "| `#{action.name}` | #{action.what} | #{cond do
      action.part && action.feature -> "`#{action.feature}`, its part `#{action.part}`"
      action.part -> "every instance, the part `#{action.part}`"
      action.feature -> "`#{action.feature}`"
      true -> "every instance"
    end} |" end)}

  ## Roles

  The instance actions are left out here: the instance's admins take them, below.

  | Role | Who | Actions |
  |---|---|---|
  #{@roles |> Enum.map(fn {role, who} -> {role, who, Enum.filter(@actions, &(role in &1.roles and not &1.instance and &1.feature not in @undocumented))} end) |> Enum.reject(fn {_role, _who, actions} -> actions == [] end) |> Enum.map_join("\n", fn {role, who, actions} -> "| `#{role}` | #{who} | #{Enum.map_join(actions, ", ", &"`#{&1.name}`")} |" end)}

  Anyone with a membership, at any level, may also remove their membership: #{Enum.map_join(@own, ", ", &"`#{&1}`")}.
  Nobody suspends or activates their membership (#{Enum.map_join(@not_own, ", ", &"`#{&1}`")}).

  An admin may what an owner may inside the organisation but change a person's level,
  lock, unlock, change or remove a locked rule of the security policy, and delete the
  organisation or cancel its deletion, and takes the actions over people over members
  only.

  An action taken on the strength of something other than a role, a sign-up, an
  invitation's token or a release command run on the instance's machine, is in the list
  for the audit trail (`Apiary.Audit`), whose entries name the actions of this list, and
  no role of the core has it: the context function checks the sign-up or the token, and
  asks nothing here; whoever runs a release command controls the instance already. A
  sign-up's `organisation.create` is one: the account does not exist yet.

  ## The levels a person may be given

  Beside the role an action over people needs, the level it gives must be one the edition
  does not refuse there (`level_refusal/4`, `c:Apiary.Edition.level_refusal/4`): the
  core's edition refuses none. An invitation, its acceptance, a change of level and the
  release commands that grant and revoke an instance admin each ask it, and a level it
  refuses is refused, with the edition's reason; a page offers only the levels it refuses
  none of (`grantable_levels/1`).

  ## Reach

  A person reaches an organisation through their membership there, at its level: what
  they may change there is its role's. The edition may give a person another way in
  (`c:Apiary.Edition.reach/1`), which the scope's `reach` carries, and a role there
  without a membership (`c:Apiary.Edition.role/1`): such a person reads every workspace of
  the organisation, and changes there what that role holds. `reach/1` says which way the
  scope carries, `level/1` the level they act at, which only a membership there gives,
  and `reader/1` how one without a membership reaches it while their role there changes
  nothing (`reads_only?/1`). `Apiary.Organisations.resolve_scope/4` finds the reach a page's
  path opens; `reload/2`, in `authorize/3`, reads the membership again, and the edition
  what it gave, and fails closed.

  ## The instance's admins

  The owners of the instance's organisation (`c:Apiary.Edition.instance_organisation_id/0`,
  `instance_organisation/0`) run the instance. Inside the organisation they act at their
  level as anyone there. Beyond it they take the instance actions, those of
  `Apiary.Access.Action` with `instance: true`, below. A release command makes an account
  an instance admin or ends it (`instance_admin.grant`, `instance_admin.revoke`), which no
  role takes.

  An instance action is answered in this order, in place of steps 1 to 9:

  1. **The feature**, asked of the instance (`Apiary.Features.visible?/2` with no scope),
     never what the edition hides from the person: off, `{:error, :not_found}`.
  2. **The instance step.** The instance's scope (`:instance`) passes. Any other scope
     passes only in the instance's organisation, while it is not marked for deletion;
     anywhere else, `{:error, :not_found}`.
  3. **The edition** (`c:Apiary.Edition.check/3`), asked once, as in step 2 above.
  4. **The place.** `account.password_link` is asked of an account in use;
     #{Enum.map_join(@instance_on_mail_settings, " and ", &"`#{&1}`")} of the mail
     settings (`Apiary.Mail.Settings`); every other instance action of the instance's
     organisation, the scope's. Anything else is `{:error, :not_found}`.
  5. **The role** (`role/1`): one the action's roles do not hold is
     `{:error, :forbidden}`.
  6. **One person.** Only the instance admin who saved the mail settings takes
     #{Enum.map_join(@saver_only, " and ", &"`#{&1}`")} on them; anyone else is
     `{:error, :not_saver}`. Nobody takes
     #{Enum.map_join(@not_own_account, ", ", &"`#{&1}`")} on the account they are signed
     in with, `{:error, :own_account}`: they change their password in Account settings.
     The instance's scope has no account, and is not refused.

  A page of the instance admins and a context function ask in the person's scope in the
  instance's organisation, whichever organisation the page's path is in: `in_instance/1`
  for a context function, which then asks `authorize/3`; `instance_scope/1` for a page,
  which asks `can?/3` (`ApiaryWeb.Access`'s `:instance`). `instance_admin?/1` says
  whether a scope's person is one, for what asks no action: a page's wording,
  an edition's harness owner and an edition's commands. Core's release commands
  read the membership, with `instance_admin_membership?/1`.

  A recent sign-in is no part of the answer: where an action needs one, the context
  function asks it after `authorize/3` (`Apiary.Accounts.sudo_mode?/1`).

  | Instance action | Feature | Roles |
  |---|---|---|
  #{@actions |> Enum.filter(& &1.instance) |> Enum.reject(&(&1.feature in @undocumented)) |> Enum.map_join("\n", fn action -> "| `#{action.name}` | #{if action.feature, do: "`#{action.feature}`", else: "every instance"} | #{Enum.map_join(action.roles, ", ", &"`#{&1}`")} |" end)}

  ## Features

  The feature an action belongs to, or the part where it belongs to one (`shown_as/1`), is
  asked of `Apiary.Features.visible?/2` with the scope, which carries what its person is
  not shown in the organisation (`hidden`, `c:Apiary.Edition.hidden/1`); `reload/2` reads
  it again after the edition's reload, under its locks. A part of a feature is hidden where
  it or its feature is; a part of no feature where it is. An access key's scope and the
  instance's answer as the instance.

  `run.read_log` belongs to the part `observability.terminal`, the run's Terminal: an
  edition that hides it from a person hides the run's whole log from them, its terminal,
  stdout and stderr, on the run page, at its address and as a download, and the last lines
  the runs list previews.

  The `node.*` and `access_key.*` actions belong to no feature and to the part `nodes`: an
  edition that hides it from a person hides from them the nodes, the node pools, their
  access keys and the gateways, their pages and every action on them, while the nodes keep
  working. What a node is served asks an access key's scope or the instance's, which is
  never asked what is hidden; an enrolment code's maker approves the key it brings by
  their role and place, whatever is hidden from them (`check_code_maker/2`).
  """

  @typedoc "An action, one of `actions/0`."
  @type action :: atom

  @typedoc """
  A role: one of the core's, `:owner`, `:admin`, `:member`, `:access_key`, `:pool_key`,
  `:adapter_key`, `:diagnostics_key` and `:instance`, or one the edition adds (`c:Apiary.Edition.roles/0`).
  """
  @type role :: atom

  @typedoc """
  What an action is taken on: an organisation, a workspace, or a row that carries
  `organisation_id`, and `workspace_id` when it belongs to a workspace.
  """
  @type subject :: struct()

  @typedoc """
  Why the answer is no: a feature that is off or hidden, or a subject out of reach, the
  role, a person who is not among the approvers of the work item's stage, and, of an
  instance action, an instance admin who did not save the mail settings or who asks of
  the account they are signed in with.
  """
  @type reason :: :not_found | :forbidden | :not_approver | :not_saver | :own_account

  ## The registry

  @doc """
  actions/0 is every action, the core's in the order of the table, then the edition's.
  """
  @spec actions() :: [action]
  def actions, do: registry().names

  @doc """
  action/1 is the `Apiary.Access.Action` named `name`, the core's or the edition's.
  Raises `ArgumentError` for a name that is neither.
  """
  @spec action(action) :: Action.t()
  def action(name) do
    case registry().by_name do
      %{^name => action} -> action
      _unknown -> raise ArgumentError, "#{inspect(name)} is no action of Apiary.Access"
    end
  end

  @doc "The feature `action` belongs to, nil for an action every instance has."
  @spec feature(action) :: Features.feature() | nil
  def feature(action), do: action(action).feature

  @doc """
  shown_as/1 is what `Apiary.Features.visible?/2` is asked of `action`: the part it belongs
  to, else its feature; nil for an action of no feature and no part, which every person is
  shown.
  """
  @spec shown_as(action) :: Features.name() | nil
  def shown_as(action) do
    %Action{feature: feature, part: part} = action(action)
    part || feature
  end

  @doc """
  roles/0 is the roles, the core's and the edition's, with the actions each holds: the
  actions whose `roles` name it, in the order of `actions/0`.
  """
  @spec roles() :: %{role => [action]}
  def roles, do: registry().roles

  # Built on first use and kept for the node: the core's actions and the edition's, the
  # roles, each checked. A mistake in an edition's registry stops whatever asks first,
  # the boot among them.
  defp registry do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        registry = build_registry(Edition.actions(), Edition.roles())
        :persistent_term.put(__MODULE__, registry)
        registry

      registry ->
        registry
    end
  end

  # Public for the access test, which hands it an edition's actions with a mistake.
  @doc false
  def build_registry(edition_actions, edition_roles) do
    for {role, _who} <- edition_roles, Keyword.has_key?(@roles, role) do
      raise ArgumentError, "the edition's role #{inspect(role)} is one of the core's"
    end

    for action <- edition_actions, not is_struct(action, Action) do
      raise ArgumentError, "the edition's action #{inspect(action)} is no Apiary.Access.Action"
    end

    actions = @actions ++ edition_actions
    names = Enum.map(actions, & &1.name)
    known_roles = Keyword.keys(@roles) ++ Map.keys(edition_roles)
    features = Features.all()

    case names -- Enum.uniq(names) do
      [] -> :ok
      twice -> raise ArgumentError, "actions named twice: #{inspect(Enum.uniq(twice))}"
    end

    for action <- actions, role <- action.roles, role not in known_roles do
      raise ArgumentError, "#{action.name} names the role #{inspect(role)}, which nobody defines"
    end

    for %Action{feature: feature} = action <- actions,
        not is_nil(feature) and feature not in features do
      raise ArgumentError, "#{action.name} belongs to #{inspect(feature)}, no feature"
    end

    parts = Features.parts()

    for %Action{feature: feature, part: part} = action <- actions,
        not is_nil(part),
        part not in parts or Features.feature_of(part) != feature do
      raise ArgumentError, part_refused(action.name, part, feature)
    end

    %{
      names: names,
      by_name: Map.new(actions, &{&1.name, &1}),
      roles:
        Map.new(known_roles, fn role ->
          {role, for(action <- actions, role in action.roles, do: action.name)}
        end)
    }
  end

  defp part_refused(name, part, nil),
    do: "#{name} belongs to the part #{inspect(part)}, no part an action of no feature may have"

  defp part_refused(name, part, feature),
    do: "#{name} belongs to the part #{inspect(part)}, no part of #{inspect(feature)}"

  ## Levels and reach

  @doc """
  reaches_every_workspace?/1 says whether a membership at `level` reaches every workspace
  of its organisation: the levels of `c:Apiary.Edition.every_workspace_levels/0`, in the
  core's edition all three. The edition says which workspaces another level reaches.
  """
  @spec reaches_every_workspace?(Membership.level() | nil) :: boolean
  def reaches_every_workspace?(level), do: level in Edition.every_workspace_levels()

  @doc """
  instance_admin?/1 says whether the scope's person is an instance admin, as the database
  has it now: whether they may read the instance (`instance.read`), asked with
  `authorize/3` of the instance organisation in their instance scope (`in_instance/1`).
  That is an owner of the instance's organisation
  (`c:Apiary.Edition.instance_organisation_id/0`), not marked for deletion, whose
  membership is not suspended and whose account is in use (not deleted, and active as the
  edition says, `c:Apiary.Edition.active_accounts/2`). False for a scope without a person,
  and for nil. Whoever asks with a person's scope, whatever organisation the scope is in,
  gets the same answer. For what asks no action: a page's wording,
  an edition's harness owner and an edition's commands; anything that acts asks
  its action.
  """
  @spec instance_admin?(Scope.t() | nil) :: boolean
  def instance_admin?(%Scope{user: %User{}, access_key: nil} = scope) do
    instance = in_instance(scope)
    authorize(instance, :"instance.read", instance.organisation) == :ok
  end

  def instance_admin?(_scope), do: false

  @doc """
  instance_organisation/0 is the instance's organisation
  (`c:Apiary.Edition.instance_organisation_id/0`), whose owners are the instance admins,
  as the database has it now: what an instance action is asked of, but
  `account.password_link`, asked of an account. Nil before the instance's first sign-up.
  """
  @spec instance_organisation() :: %Organisation{} | nil
  def instance_organisation do
    case Edition.instance_organisation_id() do
      nil -> nil
      id -> Repo.get(Organisation, id)
    end
  end

  @doc """
  in_instance/1 is the scope's person in the instance's organisation
  (`instance_organisation/0`), as `Apiary.Organisations.put_reach/2` puts them there, with
  their membership there as the database has it now and no workspace: the scope a context
  function asks an instance action in, whatever organisation the page's scope is in. For a
  person who does not reach that organisation, and before the first sign-up, their scope
  with no place, which may no instance action. Any other scope, the instance's, an access
  key's or nil, as it is.

  The scope it puts in that organisation has the organisation's id in
  `instance_organisation_id`, so `can?/3` reads no row for an instance action, beyond
  whatever the edition's check (`c:Apiary.Edition.check/3`) reads.
  """
  @spec in_instance(Scope.t() | nil) :: Scope.t() | nil
  def in_instance(%Scope{user: %User{}, access_key: nil} = scope) do
    with %Organisation{} = organisation <- instance_organisation(),
         {:ok, instance} <- Apiary.Organisations.put_reach(scope, organisation) do
      %{instance | instance_organisation_id: organisation.id}
    else
      _unreached ->
        %{
          scope
          | organisation: nil,
            workspace: nil,
            membership: nil,
            reach: nil,
            edition: %{},
            instance_organisation_id: nil
        }
    end
  end

  def in_instance(scope), do: scope

  @doc """
  instance_scope/1 is the scope of an instance admin in the instance's organisation, as
  the pages only they open ask in (`ApiaryWeb.Access`'s `:instance`): `{:ok, scope}`, the
  scope of `in_instance/1`, where its person may read the instance (`instance.read`);
  `:error` for anyone else, for a scope without a person, and before the instance's first
  sign-up. A page asks the instance actions with `can?/3` of this scope and the
  instance organisation, its `organisation`.
  """
  @spec instance_scope(Scope.t() | nil) :: {:ok, Scope.t()} | :error
  def instance_scope(%Scope{user: %User{}, access_key: nil} = scope) do
    instance = in_instance(scope)

    if can?(instance, :"instance.read", instance.organisation),
      do: {:ok, instance},
      else: :error
  end

  def instance_scope(_scope), do: :error

  @doc """
  level/1 is the level the scope's person acts at in the scope's organisation: their
  membership's there. Nil for one the edition reaches there without a membership, who
  reads it, and for anyone who does not reach it. As the scope carries it.
  """
  @spec level(Scope.t() | nil) :: Membership.level() | nil
  def level(scope), do: own_level(scope)

  @doc """
  reach/1 says how the scope's person reaches the scope's organisation, as the scope
  carries it: the edition's name for the way it gave them in, when it gave one
  (`c:Apiary.Edition.reach/1`), beside a membership there or not; `:membership`, through
  their membership there alone; nil when they do not.
  """
  @spec reach(Scope.t() | nil) :: :membership | atom | nil
  def reach(scope) do
    cond do
      name = edition_reach(scope) -> name
      own_level(scope) -> :membership
      true -> nil
    end
  end

  @doc """
  reader/1 says how the scope's person reads the scope's organisation when they have no
  membership there and change nothing in it, as the scope carries it: the edition's name
  for its reach, while the role the edition gives them there (`c:Apiary.Edition.role/1`)
  holds no action that changes anything (`reads_only?/1`). Nil for anyone with a
  membership there, for one whose role there changes something, and for anyone who does
  not reach it. A reader reads and changes nothing: a page says so, rather than the level
  a change would take. What the role holds answers, not the name of the reach.
  """
  @spec reader(Scope.t() | nil) :: atom | nil
  def reader(scope) do
    with nil <- own_level(scope),
         name when not is_nil(name) <- edition_reach(scope),
         true <- reads_only?(Map.get(roles(), Edition.role(scope), [])) do
      name
    else
      _membership_or_none_or_writes -> nil
    end
  end

  @doc """
  reads_only?/1 says whether a role that holds `actions`, a list of names of
  `actions/0`, changes nothing: none of them leaves an entry in the audit trail, which
  every change worth one does (`Apiary.Access.Action`'s `audited`). True for none at all.
  `reader/1` asks it of the role the edition gives a person without a membership.
  """
  @spec reads_only?([action]) :: boolean
  def reads_only?(actions) when is_list(actions),
    do: not Enum.any?(actions, &(action(&1).audited == true))

  @doc """
  reaches_every_workspace_in?/1 says whether the scope's person reaches every workspace of
  the scope's organisation: through the edition's reach, to read, or at a level that
  reaches them all (`reaches_every_workspace?/1`). As the scope carries it.
  """
  @spec reaches_every_workspace_in?(Scope.t() | nil) :: boolean
  def reaches_every_workspace_in?(scope) do
    case reach(scope) do
      nil -> false
      :membership -> reaches_every_workspace?(own_level(scope))
      _edition -> true
    end
  end

  # The name of the way the edition gave the scope's person in, as the scope carries it:
  # its `reach`, an atom alone or first in a tuple with what the edition read, while the
  # edition still gives it a role (`c:Apiary.Edition.role/1`).
  defp edition_reach(%Scope{reach: reach} = scope) when reach not in [nil, :membership] do
    if Edition.role(scope), do: reach_name(reach)
  end

  defp edition_reach(_scope), do: nil

  defp reach_name(name) when is_atom(name), do: name
  defp reach_name(reach) when is_tuple(reach) and is_atom(elem(reach, 0)), do: elem(reach, 0)
  defp reach_name(_reach), do: nil

  @doc """
  refused_on?/2 says whether `action` is refused on `subject` whoever asks, for what the
  subject is rather than for the role: the edition's answer to no one in particular
  (`c:Apiary.Edition.check/3` with no scope). For a page that says why a control it would
  otherwise show is not there; the answer to a scope is still `can?/3`'s. The core's
  edition refuses nothing so.
  """
  @spec refused_on?(action, subject | nil) :: boolean
  def refused_on?(action, subject) do
    action(action)
    Edition.check(nil, action, subject) == {:error, :forbidden}
  end

  @doc """
  instance_admin_level/0 is the level at which a person of the instance's organisation is
  an instance admin: owner. Granting one makes a membership of it at this level.
  """
  @spec instance_admin_level() :: Membership.level()
  def instance_admin_level, do: @instance_admin_level

  @doc """
  instance_admin_membership?/1 says whether a membership makes its person an instance
  admin: it is a membership of the instance's organisation
  (`c:Apiary.Edition.instance_organisation_id/0`), at `instance_admin_level/0`. False for a
  membership of any other organisation, and nil. Core's release commands that grant and
  revoke an instance admin read it.
  """
  @spec instance_admin_membership?(%Membership{} | nil) :: boolean
  def instance_admin_membership?(%Membership{organisation_id: id, level: @instance_admin_level})
      when is_binary(id),
      do: id == Edition.instance_organisation_id()

  def instance_admin_membership?(_membership), do: false

  @doc "own/0 is the actions anyone with a membership may take on their membership."
  @spec own() :: [action]
  def own, do: @own

  @doc """
  on_marked/0 is the actions that may still be taken on an organisation or a workspace
  marked for deletion: cancelling the deletion, and the purge.
  """
  @spec on_marked() :: [action]
  def on_marked, do: @on_marked

  @doc """
  acts_on?/2 says whether `role` takes the actions over people on a person at `level`: an
  owner on anyone, an admin on members only, any other role on nobody. For an edition's
  action over people, which asks it as the core asks it of the core's.
  """
  @spec acts_on?(role | nil, Membership.level()) :: boolean
  def acts_on?(role, level), do: level in Map.get(@acts_on, role, [])

  @doc """
  level_refusal/4 is why `level` may not be given in `organisation` by `scope`, or nil
  when it may: the edition's answer (`c:Apiary.Edition.level_refusal/4`), nil always in
  the core's. Every way a level is given asks it, beside whatever role the action needs:
  an invitation, at member, the level its person joins at (`member.invite`); its
  acceptance, at the level the edition gives (`invitation.accept`,
  `c:Apiary.Edition.accepting/3`); a change of level (`member.change_level`); and the
  release commands' `instance_admin.grant` and `instance_admin.revoke`. Each asks it with
  `lock: :share` inside its transaction, at the place in the lock order the callback
  names. A level a membership has already is not given anew, and is not asked.
  """
  @spec level_refusal(Scope.t() | nil, %Organisation{}, Membership.level(), keyword) ::
          nil | atom
  def level_refusal(scope, %Organisation{} = organisation, level, opts \\ []),
    do: Edition.level_refusal(scope, organisation, level, opts)

  @doc """
  grantable_levels/1 is the levels the scope's person may give in the scope's
  organisation, those `level_refusal/4` refuses none of, in the order of
  `Apiary.Organisations.Membership.levels/0`, as the scope carries it: what a page offers.
  Every level in the core's edition; none for a scope without an organisation.
  """
  @spec grantable_levels(Scope.t() | nil) :: [Membership.level()]
  def grantable_levels(%Scope{organisation: %Organisation{} = organisation} = scope),
    do:
      for(
        level <- Membership.levels(),
        is_nil(level_refusal(scope, organisation, level)),
        do: level
      )

  def grantable_levels(_scope), do: []

  ## The answer

  @doc """
  Whether `scope` may take `action` on `subject`, from the scope as it was loaded, as
  `check/3` answers it. For what a page shows; a context function that acts asks
  `authorize/3`.
  """
  @spec can?(Scope.t() | nil, action, subject | nil) :: boolean
  def can?(scope, action, subject), do: check(scope, action, subject) == :ok

  @doc """
  Whether `scope` may take `action` on `subject`, with the person's membership, and what
  the edition put on the scope, read again from the database: `:ok`;
  `{:error, :not_found}` where the action's feature is off or hidden from the person, the
  subject is not in the scope's organisation and workspace, or the person does not reach
  its workspace;
  `{:error, :forbidden}` where the role does not allow it, a membership that is gone
  included, or allows it over other people than the subject's;
  `{:error, :not_approver}` where the role allows it and the work item's stage lists
  approvers the person is not among (step 9 of the moduledoc);
  `{:error, :not_saver}` or `{:error, :own_account}` where the role allows an instance
  action and a one-person rule refuses it (step 6 of "The instance's admins").
  `check(reload(scope), action, subject)`.
  """
  @spec authorize(Scope.t() | nil, action, subject | nil) :: :ok | {:error, reason}
  def authorize(scope, action, subject) do
    action(action)
    scope |> reload() |> check(action, subject)
  end

  @doc """
  The answer of `authorize/3`, with its reason, from the scope as it is, without a read of
  the scope. Step 9 of the moduledoc reads a work item's process version when the work
  item does not have it loaded, and an instance action reads the instance organisation's
  id at most once, in a scope without the id, and not when the action's feature is off;
  the edition's check (`c:Apiary.Edition.check/3`) may read too. For a context function
  that asks more than one question in one change: it reads once with `reload/2` and asks
  each question of that scope.
  """
  @spec check(Scope.t() | nil, action, subject | nil) :: :ok | {:error, reason}
  def check(scope, action, subject) do
    case action(action) do
      %Action{instance: true} -> check_instance(scope, action, subject)
      %Action{} -> check_person(scope, action, subject)
    end
  end

  defp check_person(scope, action, subject) do
    shown_as = shown_as(action)

    # A part of a feature is shown only where its feature is too
    # (`Apiary.Features.visible?/2`).
    if not is_nil(shown_as) and not shown?(scope, shown_as, subject),
      do: {:error, :not_found},
      else: role_and_place(scope, action, subject)
  end

  # An access key checks a run that kept the features it was claimed with, the scope's
  # (`Apiary.Accounts.Scope.for_run/2`) or the subject's until it has ended
  # (`Apiary.Runs.Run.kept_features/1`), for the feature (`Apiary.Features.on?/2`),
  # whatever the instance has now: a run already running finishes with the features it
  # started with. A run that kept none, or has ended, follows the instance.
  defp shown?(%Scope{access_key: %AccessKey{}} = scope, name, subject) do
    case {recorded(scope, subject), Features.feature_of(name)} do
      {nil, _feature} -> Features.visible?(scope, name)
      {_recorded, nil} -> true
      {recorded, feature} -> Features.on?(feature, recorded)
    end
  end

  defp shown?(scope, name, _subject), do: Features.visible?(scope, name)

  defp recorded(%Scope{run_features: recorded}, _subject) when is_list(recorded), do: recorded
  defp recorded(_scope, %Run{} = run), do: Run.kept_features(run)
  defp recorded(_scope, %Dispatch{} = dispatch), do: Sender.dispatch_run_features(dispatch)
  defp recorded(_scope, _subject), do: nil

  # An instance action, in the order of the moduledoc's "The instance's admins": its
  # feature, asked of the instance; the instance step; the edition; the place; the role.
  # The instance organisation's id is the scope's from `in_instance/1`, or else read once
  # here, and passed to each step that needs it.
  defp check_instance(scope, action, subject) do
    shown_as = shown_as(action)

    if not is_nil(shown_as) and not Features.visible?(nil, shown_as) do
      {:error, :not_found}
    else
      instance_id = instance_id_of(scope)

      if at_instance?(scope, instance_id) do
        case Edition.check(scope, action, subject) do
          :continue -> instance_place_and_role(scope, action, subject, instance_id)
          answer -> answer
        end
      else
        {:error, :not_found}
      end
    end
  end

  defp instance_id_of(%Scope{instance_organisation_id: id}) when is_binary(id), do: id
  defp instance_id_of(_scope), do: Edition.instance_organisation_id()

  # The instance step: the instance's scope, or a scope in the instance organisation while
  # it is not marked for deletion, as the scope carries it.
  defp at_instance?(scope, instance_id) do
    case {role(scope), scope} do
      {:instance, _scope} ->
        true

      {_role, %Scope{organisation: %Organisation{id: id} = organisation}} when is_binary(id) ->
        not marked?(organisation) and id == instance_id

      _elsewhere ->
        false
    end
  end

  # The place, then the role, then the one-person rules: an account's action is asked of an
  # account in use, an action of the mail settings of them, any other of the instance
  # organisation, the scope's.
  defp instance_place_and_role(scope, action, subject, instance_id) do
    cond do
      not instance_subject?(scope, action, subject, instance_id) -> {:error, :not_found}
      role(scope) not in action(action).roles -> {:error, :forbidden}
      true -> one_person(scope, action, subject)
    end
  end

  defp instance_subject?(_scope, action, subject, _instance_id)
       when action in @instance_on_accounts,
       do: match?(%User{deleted_at: nil}, subject)

  defp instance_subject?(_scope, action, subject, _instance_id)
       when action in @instance_on_mail_settings,
       do: match?(%Settings{}, subject)

  defp instance_subject?(scope, _action, %Organisation{id: id} = subject, instance_id)
       when is_binary(id),
       do: id == instance_id and within?(scope, subject)

  defp instance_subject?(_scope, _action, _subject, _instance_id), do: false

  # Of the mail settings, the admin who saved them alone; of an account, anyone but its
  # person. The instance's scope has no account.
  defp one_person(scope, action, %Settings{mail_saved_by_id: saved_by})
       when action in @saver_only do
    case scope do
      %Scope{user: %User{id: id}} when is_binary(id) and id == saved_by -> :ok
      _other -> {:error, :not_saver}
    end
  end

  defp one_person(%Scope{user: %User{id: id}}, action, %User{id: id})
       when action in @not_own_account and is_binary(id),
       do: {:error, :own_account}

  defp one_person(_scope, _action, _subject), do: :ok

  @doc """
  check_code_maker/2 is whether the maker of an enrolment code, `scope`, the person who
  made `code`, may still make it, so that the code still approves the key it brings
  (`Apiary.AccessKeys.enrol/2`): the answer of `check/3` for `access_key.create_code` on
  the code, but that step 1 asks only whether its part, `nodes`, is on for the instance
  (`Apiary.Features.visible?/2` with no scope), which a part of no feature always is,
  never what the edition hides from the person; then the edition's answer, the place's
  and the role's, steps 2 to 8. For that one question alone: every other asks `check/3`.
  """
  @spec check_code_maker(Scope.t(), struct()) :: :ok | {:error, reason}
  def check_code_maker(scope, code) do
    action = :"access_key.create_code"
    shown_as = shown_as(action)

    if not is_nil(shown_as) and not Features.visible?(nil, shown_as),
      do: {:error, :not_found},
      else: role_and_place(scope, action, code)
  end

  @doc """
  may_serve?/2 says whether `gateway` may serve `place`, a workspace or a run of one: the
  answer of `check/3` for a key of the gateway, of `run.post_events` on a run there, the
  rule `key_subject/4` holds a gateway's key to. For a caller that holds the gateway's row
  and no key of it: a node's choice, a claim, a registration, an attach. The key and the
  run it asks of are never stored. A gateway in use may serve a workspace at one of the
  workspace's levels (`Apiary.Gateways.levels/1`), and the instance's gateway every
  workspace. `place` nil is a claim of the instance's pool, whose workspace is not known
  yet: only the instance's gateway in use may serve it, asked of its node. It reads the
  ids of the place alone: a place marked for deletion is held to its use apart
  (`Apiary.AccessKeys.place_in_use?/2`). False for nil and for a node that is no gateway.
  """
  @spec may_serve?(Node.t() | nil, %Workspace{} | Run.t() | nil) :: boolean
  def may_serve?(
        %Node{kind: :gateway} = gateway,
        %Workspace{id: id, organisation_id: organisation_id}
      ),
      do: can_serve?(gateway, %Run{organisation_id: organisation_id, workspace_id: id})

  def may_serve?(%Node{kind: :gateway} = gateway, %Run{} = run), do: can_serve?(gateway, run)

  def may_serve?(
        %Node{kind: :gateway, deleted_at: nil, organisation_id: nil, workspace_id: nil} = gateway,
        nil
      ),
      do: can_serve?(gateway, gateway)

  def may_serve?(_gateway, _place), do: false

  defp can_serve?(%Node{} = gateway, subject) do
    key = %AccessKey{
      node_id: gateway.id,
      node: gateway,
      organisation_id: gateway.organisation_id,
      workspace_id: gateway.workspace_id
    }

    can?(%Scope{access_key: key}, :"run.post_events", subject)
  end

  defp role_and_place(scope, action, subject) do
    case Edition.check(scope, action, subject) do
      :continue -> check_in_place(scope, action, subject)
      answer -> answer
    end
  end

  defp check_in_place(scope, action, subject) do
    role = role(scope)

    with :ok <- check_place(scope, action, subject),
         :ok <- key_subject(role, scope, action, subject),
         :ok <- check_role(scope, role, action, subject) do
      check_approver(scope, action, subject)
    end
  end

  defp check_role(scope, role, action, subject) do
    cond do
      own?(scope, action, subject) -> :ok
      author?(scope, action, subject) -> :ok
      not_own?(scope, action, subject) -> {:error, :forbidden}
      role not in action(action).roles -> {:error, :forbidden}
      not over?(role, action, subject) -> {:error, :forbidden}
      true -> :ok
    end
  end

  # Once the role allows it, an action of `@approver_actions` on a work item is the stage's
  # approvers' alone, where the stage lists them (`Apiary.Stages.Approvers.allows?/2`).
  # Asked of a workspace, the role alone answers, as a page asks whether to show the gates
  # at all. Asked of any other subject, it is refused: no subject skips the list.
  defp check_approver(scope, action, %WorkItem{} = work_item)
       when action in @approver_actions do
    if Approvers.allows?(scope, work_item), do: :ok, else: {:error, :not_approver}
  end

  defp check_approver(_scope, action, %Workspace{}) when action in @approver_actions, do: :ok

  defp check_approver(_scope, action, _subject) when action in @approver_actions,
    do: {:error, :not_approver}

  defp check_approver(_scope, _action, _subject), do: :ok

  # An adapter's key acts on that adapter alone, which has no organisation, as the key has
  # none: any other subject, another adapter, an organisation, or anything else, is not
  # found to it. Its scope narrowed to the organisation of a connection of that adapter
  # (`Apiary.Accounts.Scope.for_connection/2`) acts on that organisation too, and on its
  # connections to that adapter, and nothing else of it.
  defp key_subject(
         :adapter_key,
         %Scope{access_key: %AccessKey{node_id: id}} = scope,
         _action,
         subject
       ) do
    organisation_id =
      case scope.organisation do
        %Organisation{id: organisation_id} when is_binary(organisation_id) -> organisation_id
        _none -> nil
      end

    case subject do
      %Node{id: ^id, kind: :adapter, organisation_id: nil, workspace_id: nil}
      when is_binary(id) ->
        :ok

      %Organisation{id: ^organisation_id} when is_binary(organisation_id) ->
        :ok

      %Connection{adapter_id: ^id, organisation_id: ^organisation_id}
      when is_binary(id) and is_binary(organisation_id) ->
        :ok

      _other ->
        {:error, :not_found}
    end
  end

  # A node pool's key acts in its pool's workspace, which its place holds it to
  # (`check_place/3`), and there on its pool: on no other node, and not on the
  # organisation. A dispatch action is asked of the workspace, whose queue every pool of
  # it claims from, or of a dispatch its pool claimed (`dispatch_subject/2`), and of
  # nothing else. The key of the instance's pool is at the instance, on its pool; a
  # dispatch action of it is asked of its pool, the queue of every workspace with no pool
  # in use, or of a dispatch its pool claimed, in any workspace.
  defp key_subject(:pool_key, %Scope{access_key: %AccessKey{} = key}, action, subject)
       when action in @dispatch_actions,
       do: dispatch_subject(key, subject)

  defp key_subject(:pool_key, %Scope{access_key: %AccessKey{node_id: id}}, _action, subject) do
    case subject do
      %Node{id: ^id} when is_binary(id) -> :ok
      %Node{} -> {:error, :not_found}
      %Organisation{} -> {:error, :not_found}
      _other -> :ok
    end
  end

  # A gateway's key acts for a run of what the gateway may serve: at a workspace, that
  # workspace; at an organisation, every workspace of it and of the organisations whose
  # gateways the edition lets serve them; at the instance, every workspace. Any other run
  # is not found to it. Asked of anything but a run, the place alone answers, as for a
  # node's key, and the clause below holds the key of the instance's gateway.
  defp key_subject(
         :access_key,
         %Scope{access_key: %AccessKey{node: %Node{kind: :gateway} = gateway}},
         action,
         %Run{} = run
       )
       when action in @gateway_actions do
    if serves?(gateway, place(run)), do: :ok, else: {:error, :not_found}
  end

  # The key of the instance's gateway is at the instance, where it acts on its gateway
  # alone: on no adapter and not on the instance's pool.
  defp key_subject(
         :access_key,
         %Scope{access_key: %AccessKey{node_id: id, organisation_id: nil, workspace_id: nil}},
         _action,
         subject
       ) do
    case subject do
      %Node{id: ^id} when is_binary(id) -> :ok
      _other -> {:error, :not_found}
    end
  end

  # A diagnostics key reads the diagnostics of a run, wherever it is (`subject_place/3`),
  # and lists the runs of the instance, and takes nothing else, on nothing else.
  defp key_subject(:diagnostics_key, _scope, action, %Run{}) when action in @diagnostics_actions,
    do: :ok

  defp key_subject(:diagnostics_key, _scope, _action, _subject), do: {:error, :not_found}

  defp key_subject(_role, _scope, _action, _subject), do: :ok

  # Whether `gateway`, not deleted, may serve the workspace at this place: one of the
  # workspace's levels (`Apiary.Gateways.levels/1`). It reads no deletion mark: a run's
  # place is held to its use apart, with a separate refusal
  # (`Apiary.AccessKeys.place_in_use?/2`).
  defp serves?(%Node{deleted_at: nil} = gateway, {organisation_id, workspace_id}) do
    case Gateways.level(gateway) do
      {:workspace, id} ->
        id == workspace_id and gateway.organisation_id == organisation_id

      {:organisation, id} ->
        id == organisation_id or id in Gateways.serving_organisations(organisation_id)

      :instance ->
        is_binary(workspace_id) and is_binary(organisation_id)
    end
  end

  defp serves?(%Node{}, _place), do: false

  # What a dispatch action of a node pool's key is asked of: its workspace, the queue, of
  # which a waiting run is claimed; or a dispatch of that workspace that its pool claimed,
  # a row or map that carries `organisation_id` and `workspace_id`, the key's, and
  # `pool_id`, the key's pool. A dispatch another pool claimed, or one that names no pool,
  # is not found to the key, as one of another workspace is. The place was asked already
  # (`check_place/3`); it is asked again here, so this answer does not rest on that one.
  defp dispatch_subject(
         %AccessKey{organisation_id: organisation_id, workspace_id: workspace_id},
         %Workspace{id: workspace_id, organisation_id: organisation_id}
       )
       when is_binary(organisation_id) and is_binary(workspace_id),
       do: :ok

  defp dispatch_subject(
         %AccessKey{
           node_id: pool_id,
           organisation_id: organisation_id,
           workspace_id: workspace_id
         },
         %{organisation_id: organisation_id, workspace_id: workspace_id, pool_id: pool_id}
       )
       when is_binary(pool_id) and is_binary(organisation_id) and is_binary(workspace_id),
       do: :ok

  defp dispatch_subject(
         %AccessKey{node_id: pool_id, organisation_id: nil, workspace_id: nil},
         %Node{id: pool_id, kind: :pool, organisation_id: nil, workspace_id: nil}
       )
       when is_binary(pool_id),
       do: :ok

  defp dispatch_subject(
         %AccessKey{node_id: pool_id, organisation_id: nil, workspace_id: nil},
         %{organisation_id: organisation_id, workspace_id: workspace_id, pool_id: pool_id}
       )
       when is_binary(pool_id) and is_binary(organisation_id) and is_binary(workspace_id),
       do: :ok

  defp dispatch_subject(_key, _subject), do: {:error, :not_found}

  @doc """
  check_place/3 is the place's part of the answer, steps 3 to 5 of the moduledoc: `:ok`
  when `subject` is in the scope's organisation, and in its workspace when it belongs to
  one, the person reaches that workspace, and neither the place nor the subject is marked
  for deletion (but for the actions of `on_marked/0`); `{:error, :not_found}` otherwise.
  For an edition's `check/3` that answers once the place is known, as the core does.
  """
  @spec check_place(Scope.t() | nil, action, subject | nil) :: :ok | {:error, :not_found}
  def check_place(scope, action, subject) do
    place = subject_place(scope, action, subject)

    cond do
      not same_place?(scope, place) -> {:error, :not_found}
      not reaches?(scope, place) -> {:error, :not_found}
      action not in @on_marked and marked?(scope, subject) -> {:error, :not_found}
      true -> :ok
    end
  end

  @doc """
  within?/2 says whether `subject` is where the scope is: in its organisation, and in its
  workspace when the subject belongs to one. An access key's scope is its workspace.
  False for a subject that is nowhere, such as an account, and for a scope without a
  place.
  """
  @spec within?(Scope.t() | nil, subject | nil) :: boolean
  def within?(scope, subject), do: same_place?(scope, place(subject))

  # A dispatch the instance's pool claimed is asked of at the instance, where the pool's
  # key is, whatever workspace the dispatch is in: the pool claims the runs of every
  # workspace with no pool in use. `dispatch_subject/2` holds the key to the dispatches its
  # pool claimed.
  defp subject_place(
         %Scope{
           access_key: %AccessKey{
             node_id: pool_id,
             organisation_id: nil,
             workspace_id: nil,
             node: %Node{kind: :pool, organisation_id: nil, workspace_id: nil}
           }
         },
         action,
         %{organisation_id: organisation_id, workspace_id: workspace_id, pool_id: pool_id}
       )
       when action in @dispatch_actions and is_binary(pool_id) and
              is_binary(organisation_id) and is_binary(workspace_id),
       do: {nil, nil}

  # A run asked of a gateway's key is asked of where the key is, whichever organisation and
  # workspace the run is in: `key_subject/4` holds the key to what its gateway may serve.
  defp subject_place(
         %Scope{access_key: %AccessKey{node: %Node{kind: :gateway}}} = scope,
         action,
         %Run{}
       )
       when action in @gateway_actions,
       do: place(scope)

  # A run asked of a diagnostics key is asked of at the instance, where the key is, whatever
  # organisation and workspace the run is in. `key_subject/4` holds the key to that action.
  defp subject_place(
         %Scope{
           access_key: %AccessKey{
             organisation_id: nil,
             workspace_id: nil,
             node: %Node{kind: :diagnostics, organisation_id: nil, workspace_id: nil}
           }
         },
         action,
         %Run{}
       )
       when action in @diagnostics_actions,
       do: {nil, nil}

  defp subject_place(_scope, _action, subject), do: place(subject)

  # The key of an adapter, of the instance's pool or gateway, or a diagnostics key has no
  # organisation and no workspace: it is where its node is, and where nothing else of an
  # organisation is: the instance, which no other scope is at. It reaches nothing else
  # there: `key_subject/4` holds an adapter's key to its adapter, a pool's key to its pool
  # and the dispatches its pool claimed, and a diagnostics key to the diagnostics of a run.
  defp same_place?(
         %Scope{
           access_key: %AccessKey{
             organisation_id: nil,
             workspace_id: nil,
             node: %Node{kind: kind, organisation_id: nil, workspace_id: nil}
           }
         },
         {nil, nil}
       )
       when kind in [:adapter, :pool, :gateway, :diagnostics],
       do: true

  defp same_place?(scope, place), do: in_place?(place(scope), place)

  defp in_place?({organisation_id, _workspace_id}, {organisation_id, nil})
       when is_binary(organisation_id),
       do: true

  defp in_place?({organisation_id, workspace_id}, {organisation_id, workspace_id})
       when is_binary(organisation_id) and is_binary(workspace_id),
       do: true

  defp in_place?(_scope, _subject), do: false

  @doc """
  role/1 is the role the scope acts in, as it carries it: `:access_key` for the key of a
  node or a gateway, `:pool_key` for a node pool's, `:adapter_key` for an adapter's,
  `:diagnostics_key` for a diagnostics key, `:instance` for the instance, the
  level of the person's membership there, else the role the edition gives them
  (`c:Apiary.Edition.role/1`); nil for anyone else. A key whose node the scope does not
  carry loaded, or whose node is of a kind it does not know, gets no role.
  """
  @spec role(Scope.t() | nil) :: role | nil
  def role(%Scope{access_key: %AccessKey{} = key}), do: key_role(key)
  def role(%Scope{instance: true, user: nil, membership: nil}), do: :instance
  def role(%Scope{} = scope), do: own_level(scope) || Edition.role(scope)
  def role(_scope), do: nil

  # A key's role follows its node's kind, as the key carries it
  # (`Apiary.Accounts.Scope.for_access_key/1` loads it): `adapter_key` for an adapter's,
  # asked before any other kind; `pool_key` for a node pool's, which holds what a node's
  # key holds and the dispatch actions besides; `diagnostics_key` for one of the instance's
  # diagnostics node; `access_key` for a node's or a gateway's; none for a key whose node
  # is not loaded or of a kind not known here, which may nothing.
  defp key_role(%AccessKey{node: %Node{kind: :adapter}}), do: :adapter_key
  defp key_role(%AccessKey{node: %Node{kind: :pool}}), do: :pool_key
  defp key_role(%AccessKey{node: %Node{kind: :diagnostics}}), do: :diagnostics_key

  defp key_role(%AccessKey{node: %Node{kind: kind}}) when kind in [:node, :gateway],
    do: :access_key

  defp key_role(%AccessKey{}), do: nil

  ## Reading again

  @doc """
  The scope with the person's membership as the database has it now, its level as it is or
  no membership when it is gone or suspended, or when their account is no longer in use,
  what the edition put on it read again (`c:Apiary.Edition.reload/2`), and what the person
  is not shown in the organisation (`hidden`, `c:Apiary.Edition.hidden/1`). An access key's
  scope is returned as it is: the key was verified on the request that carries it; the
  instance's has only its marks to read again. Any other scope, one without a user or an
  organisation, comes back without a membership, so it may nothing a role would allow.

  Every scope it returns has `instance_organisation_id` set to nil, so a check of that
  scope reads the instance organisation's id as the database has it now.

  With the membership it reads the deletion marks of the organisation and the workspace,
  so an organisation or a workspace marked since the scope was loaded answers not found
  (`check/3`). A scope that carries no membership has the person's membership there
  looked for again, in case they hold one now.

  `lock: :share`, for a caller inside a transaction, takes its locks in the lock order of
  docs/access.md: the organisation `FOR SHARE`, with whatever the edition holds beside it
  (`lock_places/1`); the workspace `FOR KEY SHARE`; the membership `FOR SHARE`; what the
  edition reads again and what the person is not shown, under the edition's locks; then
  the account `FOR SHARE`, reading again
  whether it is still in use. A change of the level, a member's suspension, an account
  going out of use or a marking waits until the transaction ends, so what was asked stays
  true while the change is written, and one that came first is seen.
  """
  @spec reload(Scope.t() | nil, keyword) :: Scope.t() | nil
  def reload(scope, opts \\ [])

  def reload(%Scope{access_key: %AccessKey{}} = scope, _opts),
    do: %{scope | instance_organisation_id: nil}

  def reload(%Scope{user: %User{id: user_id}, organisation: %Organisation{}} = scope, opts) do
    lock? = opts[:lock] == :share

    # The lock order (docs/access.md, The lock order): the organisation rows, with the
    # edition's own (`lock_places/1`), first, then the membership, then the account.
    if lock?, do: lock_places(scope)

    scope = %{scope | instance_organisation_id: nil}
    scope = scope |> reload_membership(lock?) |> Edition.reload(opts)

    # What the person is not shown, asked once the edition's reach is read again: with
    # `lock: :share` under the edition's locks, which `lock_places/1` took.
    scope = %{scope | hidden: Features.hidden_of(Edition.hidden(scope))}

    # The account is read again under its lock: a deletion, or the edition holding it out
    # of use, that came first, and was waited for, leaves the person no reach, as a
    # membership read after it would.
    if lock? and not active_account?(user_id),
      do: %{scope | membership: nil, reach: nil},
      else: scope
  end

  def reload(%Scope{instance: true, user: nil, access_key: nil} = scope, _opts) do
    %{
      scope
      | organisation: reload_marks(scope.organisation),
        workspace: reload_marks(scope.workspace),
        instance_organisation_id: nil
    }
  end

  def reload(%Scope{} = scope, _opts),
    do: %{scope | membership: nil, reach: nil, instance_organisation_id: nil}

  def reload(nil, _opts), do: nil

  @doc """
  lock_places/1 holds the scope's organisation `FOR SHARE`, with the other organisations
  the edition holds with it (`c:Apiary.Edition.places_to_lock/1`), as
  `lock_organisations/1` holds them, for a caller inside a transaction that must stay
  allowed while it is written: the first rows of the lock order (docs/access.md). A
  change that must not happen under such a write locks these rows for update, and waits
  for the write, or comes first and is seen; a row that only names the organisation
  takes `FOR KEY SHARE`, which does not wait. Then the edition's rows for such a write (`c:Apiary.Edition.lock_rows/1`,
  `{:places, scope}`), before any workspace, membership or account. `reload/2` with
  `lock: :share` takes them first; a write that locks a row itself before it asks, as
  the security policy's locks its workspace, calls this first. `:ok`.
  """
  @spec lock_places(Scope.t()) :: :ok
  def lock_places(%Scope{} = scope) do
    case lock_organisations(scope) do
      :ok -> Edition.lock_rows({:places, scope})
      :gone -> :ok
    end
  end

  def lock_places(_scope), do: :ok

  @doc """
  lock_organisations/1 holds the organisation rows `lock_places/1` holds, and asks the
  edition for none of its rows: for a change whose one point asks the edition itself
  (`Apiary.Organisations.lock_people/1`). The scope's organisation, read as it is now
  without a lock, and those `c:Apiary.Edition.places_to_lock/1` names for it, are taken
  `FOR SHARE` in one statement (`Apiary.Organisations.lock_organisations/2`), under a
  separate savepoint. Then `places_to_lock/1` is asked again of the organisation held:
  should it name one not taken, it lets go of what it took, rolling back to the
  savepoint, and takes the fresh set in one statement again, at most
  #{@place_attempts} times in all; so what it holds at the end was taken in one statement.

  `:ok`; `:gone` for an organisation deleted, holding none of them. It raises, holding
  none of them and the transaction usable, should Postgres refuse the lock twice as a
  deadlock, or should what the edition names change on every attempt.
  """
  @spec lock_organisations(Scope.t()) :: :ok | :gone
  def lock_organisations(%Scope{organisation: %Organisation{id: id}}) do
    case Repo.get(Organisation, id) do
      nil ->
        :gone

      %Organisation{} = seen ->
        Repo.query!("SAVEPOINT apiary_lock_places")
        take_places(id, Edition.places_to_lock(seen), @place_attempts)
    end
  end

  def lock_organisations(_scope), do: :gone

  # One attempt: the organisations `ids`, `FOR SHARE`, in one statement, under the
  # savepoint; then what the edition names for the organisation, asked again of it held.
  # A fresh set means a change of what it names committed between the read and the lock,
  # and each attempt after needs another such change in its own short window, so a few
  # attempts are enough; past them it gives up rather than wait on a change that keeps
  # coming.
  defp take_places(id, ids, attempts) do
    held = hold_places(ids)

    case id in held && Repo.get(Organisation, id) do
      %Organisation{} = now ->
        fresh = Edition.places_to_lock(now)

        cond do
          fresh -- ids == [] ->
            Repo.query!("RELEASE SAVEPOINT apiary_lock_places")
            :ok

          attempts > 1 ->
            Repo.query!("ROLLBACK TO SAVEPOINT apiary_lock_places")
            take_places(id, fresh, attempts - 1)

          true ->
            let_go_of_places()

            raise "what the edition holds with organisation #{id} changed on each of " <>
                    "#{@place_attempts} attempts to lock it"
        end

      _gone ->
        let_go_of_places()
        :gone
    end
  end

  defp let_go_of_places do
    Repo.query!("ROLLBACK TO SAVEPOINT apiary_lock_places")
    Repo.query!("RELEASE SAVEPOINT apiary_lock_places")
  end

  # The organisations `ids`, `FOR SHARE`, in the lock order: those held. A refusal lets go
  # of what the attempts took before it raises.
  defp hold_places(ids) do
    case Apiary.Organisations.lock_organisations(ids, :share) do
      {:ok, held} ->
        held

      {:error, error} ->
        let_go_of_places()
        raise error
    end
  end

  # The person's account `FOR SHARE`, the lock order's last row, and whether it is still
  # in use: not deleted, and active as the edition says. A deletion of the account, or the
  # edition taking it out of use, `FOR NO KEY UPDATE`, waits for the write, or comes first
  # and is seen here. What the edition says is read in a statement of its own, once the
  # lock is held: what holds an account out of use may be a row of the edition's, written
  # under the account's lock without changing the account's row, which a statement that
  # waited for the lock would not see.
  defp active_account?(user_id) do
    Repo.one(from u in User, where: u.id == ^user_id, select: u.id, lock: "FOR SHARE")

    from(u in User,
      as: :account,
      where: u.id == ^user_id and is_nil(u.deleted_at),
      select: u.id
    )
    |> Edition.active_accounts(:account)
    |> Repo.one()
    |> is_binary()
  end

  # With a membership: its level, whether it or its account is out of use, and the marks
  # of its organisation and of the scope's workspace, in one read.
  defp reload_membership(
         %Scope{
           user: %User{id: user_id},
           organisation: %Organisation{id: organisation_id},
           membership: %Membership{id: membership_id} = membership
         } = scope,
         lock?
       ) do
    case scope
         |> membership_query(membership_id, user_id, organisation_id, lock?)
         |> Repo.one() do
      {level, nil, true, organisation_marks, workspace_marks} ->
        %{
          scope
          | membership: %{membership | level: level},
            organisation: marked(scope.organisation, organisation_marks),
            workspace: marked(scope.workspace, workspace_marks)
        }

      # A suspended membership, or an account out of use, is no membership: it reaches
      # nothing and changes nothing.
      {_level, _membership_suspended, _active, organisation_marks, workspace_marks} ->
        %{
          scope
          | membership: nil,
            organisation: marked(scope.organisation, organisation_marks),
            workspace: marked(scope.workspace, workspace_marks)
        }

      nil ->
        %{scope | membership: nil}
    end
  end

  # Without one: the marks of the organisation and of the scope's workspace, and the
  # person's membership there, should they hold one now. Locked, the membership is held
  # `FOR SHARE`, after the organisations, which `reload/2` holds first.
  defp reload_membership(%Scope{user: %User{id: user_id}} = scope, lock?) do
    case scope |> place_query(lock?) |> Repo.one() do
      {organisation_marks, workspace_marks} ->
        %{
          scope
          | membership: own_membership(scope, user_id, lock?),
            organisation: marked(scope.organisation, organisation_marks),
            workspace: marked(scope.workspace, workspace_marks)
        }

      nil ->
        %{scope | membership: nil, reach: nil}
    end
  end

  # The organisation's marks, and the scope's workspace's; locked, the rows are held
  # `FOR KEY SHARE`, which the purge's deletion of them waits for.
  defp place_query(%Scope{organisation: %Organisation{id: organisation_id}} = scope, lock?) do
    query = from o in Organisation, as: :organisation, where: o.id == ^organisation_id

    case scope.workspace do
      %Workspace{id: workspace_id} ->
        query =
          from [organisation: o] in query,
            join: w in Workspace,
            as: :workspace,
            on: w.id == ^workspace_id and w.organisation_id == o.id,
            select: {{o.deletion_marked_at, o.purge_after}, {w.deletion_marked_at, w.purge_after}}

        if lock?,
          do:
            lock(
              query,
              [organisation: o, workspace: w],
              fragment("FOR KEY SHARE OF ?, ?", o, w)
            ),
          else: query

      nil ->
        query =
          from [organisation: o] in query,
            select: {{o.deletion_marked_at, o.purge_after}, nil}

        if lock?,
          do: lock(query, [organisation: o], fragment("FOR KEY SHARE OF ?", o)),
          else: query
    end
  end

  # The person's membership there, while it is not suspended and their account is in use;
  # locked, the membership `FOR SHARE` and the account `FOR KEY SHARE`, which the
  # membership's suspension, or a change that takes the account out of use, waits for.
  defp own_membership(%Scope{organisation: %Organisation{id: organisation_id}}, user_id, lock?) do
    query =
      from m in Membership,
        as: :membership,
        join: u in User,
        as: :user,
        on: u.id == m.user_id,
        where: m.organisation_id == ^organisation_id and m.user_id == ^user_id,
        where: is_nil(m.suspended_at)

    query =
      if lock?,
        do:
          lock(
            query,
            [membership: m, user: u],
            fragment("FOR SHARE OF ? FOR KEY SHARE OF ?", m, u)
          ),
        else: query

    query |> Edition.active_accounts(:user) |> Repo.one()
  end

  # The membership's level, whether it is suspended, whether its account is in use, and
  # the deletion marks of its organisation and of the scope's workspace in it. Locked, the
  # membership is held `FOR SHARE` and the organisation, the account and the workspace
  # `FOR KEY SHARE`, which the purge's deletion of the row waits for (`Apiary.Deletion`):
  # the bindings are named so the lock can name them.
  defp membership_query(scope, membership_id, user_id, organisation_id, lock?) do
    active =
      from(a in User,
        as: :account,
        where: a.id == parent_as(:membership).user_id and is_nil(a.deleted_at),
        select: 1
      )
      |> Edition.active_accounts(:account)

    query =
      from m in Membership,
        as: :membership,
        join: o in Organisation,
        as: :organisation,
        on: o.id == m.organisation_id,
        join: u in User,
        as: :user,
        on: u.id == m.user_id,
        where:
          m.id == ^membership_id and m.user_id == ^user_id and
            m.organisation_id == ^organisation_id

    case scope.workspace do
      %Workspace{id: workspace_id} ->
        query =
          from [membership: m, organisation: o, user: u] in query,
            join: w in Workspace,
            as: :workspace,
            on: w.id == ^workspace_id and w.organisation_id == o.id,
            select:
              {m.level, m.suspended_at, exists(active), {o.deletion_marked_at, o.purge_after},
               {w.deletion_marked_at, w.purge_after}}

        if lock?,
          do:
            lock(
              query,
              [membership: m, organisation: o, user: u, workspace: w],
              fragment("FOR SHARE OF ? FOR KEY SHARE OF ?, ?, ?", m, o, u, w)
            ),
          else: query

      nil ->
        query =
          from [membership: m, organisation: o, user: u] in query,
            select:
              {m.level, m.suspended_at, exists(active), {o.deletion_marked_at, o.purge_after},
               nil}

        if lock?,
          do:
            lock(
              query,
              [membership: m, organisation: o, user: u],
              fragment("FOR SHARE OF ? FOR KEY SHARE OF ?, ?", m, o, u)
            ),
          else: query
    end
  end

  defp marked(nil, _marks), do: nil
  defp marked(row, nil), do: row

  defp marked(row, {marked_at, purge_after}),
    do: %{row | deletion_marked_at: marked_at, purge_after: purge_after}

  # The instance's organisation or workspace with its marks as they are now; as it was,
  # should it be gone, which the purge answers for itself.
  defp reload_marks(%schema{id: id} = row) when schema in [Organisation, Workspace] do
    case Repo.one(
           from r in schema, where: r.id == ^id, select: {r.deletion_marked_at, r.purge_after}
         ) do
      nil -> row
      marks -> marked(row, marks)
    end
  end

  defp reload_marks(row), do: row

  # Whether the scope's organisation or workspace, or a subject that is one, is marked for
  # deletion, as the scope carries them: `reload/2` reads them again.
  defp marked?(%Scope{} = scope, subject),
    do: marked?(scope.organisation) or marked?(scope.workspace) or marked?(subject)

  defp marked?(_scope, subject), do: marked?(subject)

  defp marked?(%Organisation{deletion_marked_at: %DateTime{}}), do: true
  defp marked?(%Workspace{deletion_marked_at: %DateTime{}}), do: true
  defp marked?(_row), do: false

  # The level of the person's membership in the scope's organisation.
  defp own_level(%Scope{
         organisation: %Organisation{id: organisation_id},
         membership: %Membership{organisation_id: organisation_id, level: level}
       }),
       do: level

  defp own_level(_scope), do: nil

  # Whether a person reaches the workspace of a subject: always, for what the organisation
  # owns; for a workspace's, when their level reaches every workspace, or as the edition
  # says from what the scope carries. Without a membership the place answers: a key's is
  # its own workspace, the instance has none, one the edition reaches reads every
  # workspace, and the role refuses anyone else.
  defp reaches?(_scope, {_organisation_id, nil}), do: true

  defp reaches?(scope, {_organisation_id, workspace_id}) do
    case own_level(scope) do
      nil ->
        true

      level ->
        reaches_every_workspace?(level) or Edition.reaches_workspace?(scope, workspace_id, [])
    end
  end

  # Whether the role may take an action over people over the subject's person: the level of
  # the membership, or member for an invitation, which its person joins at. Any other
  # subject, or any other action, the role alone answers.
  defp over?(role, action, %Membership{level: level}) when action in @suspends,
    do: level in Map.get(@suspends_over, role, [])

  defp over?(role, action, %Membership{level: level}) when action in @over_people,
    do: acts_on?(role, level)

  defp over?(role, action, %Invitation{}) when action in @over_people,
    do: acts_on?(role, :member)

  defp over?(_role, _action, _subject), do: true

  # An action of `@own` on the asker's own membership, in their organisation.
  defp own?(
         %Scope{
           organisation: %Organisation{id: organisation_id},
           membership: %Membership{id: id, organisation_id: organisation_id}
         },
         action,
         %Membership{id: id, organisation_id: organisation_id}
       )
       when action in @own,
       do: true

  defp own?(_scope, _action, _subject), do: false

  # An action of `@authored` on what the asker wrote, `author_id` theirs, while their role
  # still holds the action they wrote it with: a comment's author deletes it while they may
  # still comment. The place was asked already (`check_place/3`).
  defp author?(%Scope{user: %User{id: user_id}} = scope, action, %{author_id: user_id})
       when is_map_key(@authored, action) and is_binary(user_id),
       do: role(scope) in action(Map.fetch!(@authored, action)).roles

  defp author?(_scope, _action, _subject), do: false

  # An action of `@not_own` on the asker's own membership: nobody suspends or activates
  # themselves.
  defp not_own?(
         %Scope{user: %User{id: user_id}},
         action,
         %Membership{user_id: user_id}
       )
       when action in @not_own,
       do: true

  defp not_own?(_scope, _action, _subject), do: false

  @doc """
  place/1 is where a scope or a subject is: `{organisation_id, workspace_id}`, the
  workspace nil for what the organisation owns, an invitation among it; nil for what is
  nowhere, such as an account. An access key's scope is its key's workspace.
  """
  @spec place(Scope.t() | subject | nil) :: {Ecto.UUID.t() | nil, Ecto.UUID.t() | nil} | nil
  # The key of an adapter, which has none, is at the organisation its scope was narrowed
  # to, through a connection of that adapter (`Apiary.Accounts.Scope.for_connection/2`).
  def place(%Scope{
        access_key: %AccessKey{
          organisation_id: nil,
          workspace_id: nil,
          node: %Node{kind: :adapter, organisation_id: nil, workspace_id: nil}
        },
        organisation: %Organisation{id: organisation_id}
      })
      when is_binary(organisation_id),
      do: {organisation_id, nil}

  def place(%Scope{access_key: %AccessKey{} = key}),
    do: {key.organisation_id, key.workspace_id}

  def place(%Scope{organisation: %Organisation{id: organisation_id}, workspace: workspace}),
    do: {organisation_id, workspace && workspace.id}

  def place(%Organisation{id: id}), do: {id, nil}
  def place(%User{}), do: nil
  # An invitation grants a workspace, and is the organisation's all the same: only an owner
  # or an admin acts on one, and they reach every workspace, from whichever page.
  def place(%Invitation{organisation_id: organisation_id}), do: {organisation_id, nil}
  def place(%Workspace{id: id, organisation_id: organisation_id}), do: {organisation_id, id}

  def place(%{organisation_id: organisation_id, workspace_id: workspace_id}),
    do: {organisation_id, workspace_id}

  def place(%{organisation_id: organisation_id}), do: {organisation_id, nil}
  def place(_nowhere), do: nil
end
