defmodule Apiary.AuditChanges do
  @moduledoc """
  AuditChanges is the core's module of changes of the audit test (`Apiary.AuditCase`):
  each audited action of the core made the way the product makes it, what it needs
  first, then the trail as it is (`before`), then the change; and the same change
  refused, `{the trail before the attempt, the attempt's answer}`.
  """

  import Apiary.AccessKeysFixtures
  import Apiary.AccountsFixtures, only: [unique_user_email: 0, valid_user_attributes: 1]
  import Apiary.AuditCase, only: [entries: 0, old!: 1, refuse_as_member: 4]

  import Apiary.DispatchedRunsFixtures, only: [handover_place_fixture: 1]

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures, only: [work_item_fixture: 1]
  import Ecto.Query

  alias Apiary.{
    Access,
    AccessKeys,
    Accounts,
    Adapters,
    Audit,
    Deletion,
    Nodes,
    Organisations,
    Policy,
    Repo,
    Retention,
    Secrets,
    Targets,
    Variables
  }

  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Collections}
  alias Apiary.Organisations.{Membership, Organisation, Workspace}

  @mail_attrs %{
    "smtp_relay" => "smtp.example.com",
    "smtp_port" => "587",
    "smtp_tls" => "always",
    "smtp_username" => "qory",
    "smtp_password" => "a relay password",
    "mail_from" => ""
  }

  # People's comments on a work item's Thread, each made by its function of
  # `Apiary.WorkItems`: about the work item.
  @work_item_comments [
    :"work_item.comment",
    :"work_item.comment_delete"
  ]

  # The audited actions of a person on the work items, each made by its function of
  # `Apiary.WorkItems`.
  @work_item_moves [
    :"work_item.take_in",
    :"work_item.undo",
    :"work_item.decline",
    :"work_item.close",
    :"work_item.answer",
    :"work_item.confirm",
    :"work_item.explore_again"
  ]

  @doc "actions/0 is the core's audited actions, each made and refused below."
  @spec actions() :: [Access.action()]
  def actions do
    [
      :"organisation.create",
      :"organisation.rename",
      :"organisation.delete",
      :"organisation.restore",
      :"member.invite",
      :"member.change_level",
      :"member.remove",
      :"invitation.revoke",
      :"invitation.renew",
      :"invitation.accept",
      :"member.suspend",
      :"member.activate",
      :"instance_admin.grant",
      :"instance_admin.revoke",
      :"account.password_link",
      :"instance.mail_save",
      :"instance.mail_on",
      :"instance.rename",
      :"instance.configure",
      :"audit.prune",
      :"workspace.create",
      :"workspace.rename",
      :"workspace.delete",
      :"workspace.restore",
      :"workspace.purge",
      :"access_key.create_code",
      :"access_key.cancel_code",
      :"access_key.add",
      :"access_key.revoke",
      :"node.create",
      :"node.edit",
      :"node.delete",
      :"node.clear_instance",
      :"retention.edit",
      :"security_policy.edit",
      :"security_policy.lock",
      :"security_policy.set_mode",
      :"secret.write",
      :"variable.edit",
      :"connection.write",
      :"provider.write",
      :"runtime.write",
      :"model_choice.write",
      :"time_limit.edit",
      :"adapter.create",
      :"adapter.edit",
      :"adapter.set_interval",
      :"adapter.delete",
      :"adapter.install",
      :"adapter.setup",
      :"adapter.connect",
      :"adapter.declare",
      :"collection.assign",
      :"collection.set_backlog",
      :"collection.move",
      :"dispatch.release",
      :"target.set_further_repositories",
      :"target.rebuild_environment",
      :"secret.seal"
    ] ++ @work_item_moves ++ @work_item_comments
  end

  @doc """
  make/2 makes `action` the way the product makes it, in the context `Apiary.AuditCase`
  gives: what it needs first, then the trail as it is, then the change.
  """
  @spec make(Access.action(), map) :: map
  def make(:"organisation.create", _ctx) do
    before = entries()

    # A later sign-up, whether or not the edition opens one.
    {:ok, %{user: user, organisation: organisation} = signed_up} =
      Organisations.sign_up_user(valid_user_attributes(%{}), nil, open: true)

    scope = %Scope{user: user, organisation: organisation, workspace: signed_up.workspace}
    %{scope: scope, subject: {"organisation", organisation.id}, before: before}
  end

  def make(:"organisation.rename", %{scope: scope}) do
    before = entries()
    {:ok, _} = Organisations.update_organisation(scope, %{name: "Renamed"})
    %{scope: scope, subject: {"organisation", scope.organisation.id}, before: before}
  end

  def make(:"member.invite", %{scope: scope}) do
    before = entries()
    %{invitation: invitation} = invitation_fixture(scope)
    %{scope: scope, subject: {"invitation", invitation.id}, before: before}
  end

  def make(:"member.change_level", %{scope: scope}) do
    %{membership: membership} = member_fixture(scope)
    before = entries()
    {:ok, _} = Organisations.set_member_level(scope, membership.id, :owner)
    %{scope: scope, subject: {"membership", membership.id}, before: before}
  end

  def make(:"member.remove", %{scope: scope}) do
    %{membership: membership} = member_fixture(scope)
    before = entries()
    {:ok, _} = Organisations.remove_member(scope, membership.id)
    %{scope: scope, subject: {"membership", membership.id}, before: before}
  end

  def make(:"invitation.revoke", %{scope: scope}) do
    %{invitation: invitation} = invitation_fixture(scope)
    before = entries()
    {:ok, _} = Organisations.revoke_invitation(scope, invitation.id)
    %{scope: scope, subject: {"invitation", invitation.id}, before: before}
  end

  def make(:"invitation.renew", %{scope: scope}) do
    %{invitation: invitation} = invitation_fixture(scope)
    before = entries()

    {:ok, _renewed} =
      Organisations.renew_invitation(scope, invitation.id, &"http://localhost/invitations/#{&1}")

    %{scope: scope, subject: {"invitation", invitation.id}, before: before}
  end

  def make(:"invitation.accept", %{scope: scope}) do
    %{invitation: invitation, token: token} = invitation_fixture(scope)
    %{user: user} = sign_up_fixture()
    before = entries()
    {:ok, _membership} = Organisations.accept_invitation(Scope.for_user(user), token)
    accepted = %Scope{user: user, organisation: scope.organisation}
    %{scope: accepted, subject: {"invitation", invitation.id}, before: before}
  end

  def make(:"member.suspend", %{scope: scope}) do
    %{membership: membership} = member_fixture(scope)
    before = entries()
    {:ok, _} = Organisations.suspend_member(scope, membership.id)
    %{scope: scope, subject: {"membership", membership.id}, before: before}
  end

  def make(:"member.activate", %{scope: scope}) do
    %{membership: membership} = member_fixture(scope)
    {:ok, _} = Organisations.suspend_member(scope, membership.id)
    before = entries()
    {:ok, _} = Organisations.activate_member(scope, membership.id)
    %{scope: scope, subject: {"membership", membership.id}, before: before}
  end

  # A release command, by the instance, in the trail of the instance's organisation.
  def make(:"instance_admin.grant", _ctx) do
    %{user: user} = sign_up_fixture()
    before = entries()
    {:ok, %{membership: membership}} = Organisations.grant_instance_admin(user)
    instance = Scope.for_instance(instance_organisation())
    %{scope: instance, actor: :instance, subject: {"membership", membership.id}, before: before}
  end

  # An instance admin's, while no mail is set, in the trail of the instance's organisation:
  # for an account with no membership there, about the organisation. The link is the
  # secret the entry must not keep.
  def make(:"account.password_link", _ctx) do
    # Signed in just now: a link needs a recent sign-in.
    admin = password_link_admin() |> mail_signed_in(0)
    user = Apiary.AccountsFixtures.user_fixture()
    Apiary.Mail.put_test_source(:none)
    before = entries()

    {:ok, url, _expires_at} =
      Accounts.build_password_link(admin, user, &"http://localhost/users/password/#{&1}")

    [_, token] = Regex.run(~r{/users/password/(.+)$}, url)
    instance = instance_organisation()

    %{
      scope: Scope.in_organisation(admin, instance),
      subject: {"organisation", instance.id},
      before: before,
      secret: token
    }
  end

  # An instance admin's, after a recent sign-in, in the trail of the instance's
  # organisation, about the organisation. The relay's password is the secret the entry must
  # not keep.
  def make(:"instance.mail_save", _ctx) do
    admin = mail_admin()
    before = entries()

    {:ok, _settings, :sent} =
      Apiary.Mail.save_settings(
        admin,
        @mail_attrs,
        &"http://localhost/instance/mail/confirm/#{&1}"
      )

    instance = instance_organisation()

    %{
      scope: Scope.in_organisation(admin, instance),
      subject: {"organisation", instance.id},
      before: before,
      secret: @mail_attrs["smtp_password"]
    }
  end

  # An instance admin's, in the trail of the instance's organisation, about the
  # organisation.
  def make(:"instance.rename", _ctx) do
    admin = password_link_admin()
    before = entries()
    {:ok, "Acme Agents"} = Apiary.ProductName.rename(admin, %{"product_name" => "Acme Agents"})
    instance = instance_organisation()

    %{
      scope: Scope.in_organisation(admin, instance),
      subject: {"organisation", instance.id},
      before: before
    }
  end

  # An instance admin's, after a recent sign-in, in the trail of the instance's
  # organisation, about the organisation.
  def make(:"instance.configure", _ctx) do
    admin = password_link_admin() |> mail_signed_in(0)
    before = entries()

    {:ok, %{invitations_per_day: 50}} =
      Apiary.InstanceConfig.save(admin, :invitations, %{"invitations_per_day" => "50"})

    instance = instance_organisation()

    %{
      scope: Scope.in_organisation(admin, instance),
      subject: {"organisation", instance.id},
      before: before
    }
  end

  # The admin who saved, by the test link the save sent them. The link is the secret.
  def make(:"instance.mail_on", _ctx) do
    {admin, token} = mail_saved()
    before = entries()
    {:ok, _settings} = Apiary.Mail.turn_on(admin, token)
    instance = instance_organisation()

    %{
      scope: Scope.in_organisation(admin, instance),
      subject: {"organisation", instance.id},
      before: before,
      secret: token
    }
  end

  # What an edition records beside the revocation, in actions of its own, is not the one
  # looked for: the edition's test pins it.
  def make(:"instance_admin.revoke", _ctx) do
    %{user: user} = sign_up_fixture()
    {:ok, %{membership: membership}} = Organisations.grant_instance_admin(user)
    before = entries()
    {:ok, _member} = Organisations.revoke_instance_admin(user)

    %{
      scope: Scope.for_instance(instance_organisation()),
      actor: :instance,
      subject: {"membership", membership.id},
      before: before ++ of_the_edition(entries() -- before)
    }
  end

  def make(:"audit.prune", %{owner: %{organisation: organisation}}) do
    old!(organisation)
    before = entries()
    instance = Scope.for_instance(organisation)
    {:ok, 1} = Audit.prune(instance)
    # The pruned entry is gone from the trail: it is not the one looked for.
    %{
      scope: instance,
      actor: :instance,
      subject: {"organisation", organisation.id},
      before: Enum.filter(before, &(&1 in entries()))
    }
  end

  # The core's edition allows one workspace in use: the organisation's first is marked
  # for deletion, as a fixture marks it, before the owner creates another.
  def make(:"workspace.create", %{scope: scope}) do
    scope = mark_only_workspace(scope)
    before = entries()

    {:ok, workspace} =
      Organisations.create_workspace(scope, %{"name" => "Data", "domain" => "software"})

    %{scope: scope, subject: {"workspace", workspace.id}, before: before}
  end

  def make(:"workspace.rename", %{scope: scope}) do
    before = entries()
    {:ok, _} = Organisations.update_workspace(scope, %{name: "Renamed"})
    %{scope: scope, subject: {"workspace", scope.workspace.id}, before: before}
  end

  def make(:"access_key.create_code", %{scope: scope}) do
    node = node_fixture(scope)
    before = entries()
    {:ok, _row, code} = AccessKeys.create_enrolment_code(scope, node, %{allow_secrets: true})
    %{scope: scope, subject: {"node", node.id}, secret: code, before: before}
  end

  def make(:"access_key.cancel_code", %{scope: scope}) do
    node = node_fixture(scope)
    {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node, %{})
    before = entries()
    {:ok, _} = AccessKeys.cancel_code(scope, row)
    %{scope: scope, subject: {"node", node.id}, before: before}
  end

  def make(:"access_key.add", %{scope: scope}) do
    node = node_fixture(scope)
    before = entries()
    %{access_key: key} = node_key_fixture(scope, node)
    %{scope: scope, subject: {"access_key", key.id}, before: before}
  end

  def make(:"access_key.revoke", %{scope: scope}) do
    %{access_key: key} = node_key_fixture(scope, node_fixture(scope))
    before = entries()
    {:ok, _} = AccessKeys.revoke_access_key(scope, key)
    %{scope: scope, subject: {"access_key", key.id}, before: before}
  end

  def make(:"node.create", %{scope: scope}) do
    before = entries()
    {:ok, node} = Nodes.create_node(scope, %{kind: "pool", name: "spot-runners"})
    %{scope: scope, subject: {"node", node.id}, before: before}
  end

  def make(:"node.edit", %{scope: scope}) do
    node = pool_fixture(scope)
    before = entries()
    {:ok, _} = Nodes.update_node(scope, node, %{name: "spot-runners", instance_limit: 10})
    %{scope: scope, subject: {"node", node.id}, before: before}
  end

  def make(:"node.delete", %{scope: scope}) do
    node = node_fixture(scope)
    before = entries()
    {:ok, _} = Nodes.delete_node(scope, node)
    %{scope: scope, subject: {"node", node.id}, before: before}
  end

  # An adapter is the instance's: an instance admin, signed in just now, makes, renames and
  # deletes one, in the trail of the instance's organisation.
  def make(:"adapter.create", _ctx) do
    admin = instance_admin_scope()
    before = entries()
    {:ok, adapter} = Adapters.create_adapter(admin, %{name: "Acme tracker"})
    %{scope: in_instance(admin), subject: {"node", adapter.id}, before: before}
  end

  # The instance, by itself, installs an adapter its setting lists.
  def make(:"adapter.install", _ctx) do
    instance = Scope.for_instance(instance_organisation())
    before = entries()
    {:ok, adapter} = Adapters.install(instance, "tracker")

    %{scope: instance, actor: :instance, subject: {"node", adapter.id}, before: before}
  end

  # An instance admin starts the set-up of an adapter that declares where, in the trail
  # of the instance's organisation, about the adapter, never with the pass.
  def make(:"adapter.setup", _ctx) do
    %{adapter: adapter} = settable_adapter_fixture()
    admin = instance_admin_scope()
    before = entries()
    {:ok, url} = Adapters.setup(admin, adapter)
    %{"state" => pass} = URI.decode_query(URI.parse(url).query)

    %{
      scope: in_instance(admin),
      subject: {"node", adapter.id},
      secret: pass,
      before: before
    }
  end

  def make(:"adapter.edit", _ctx) do
    adapter = adapter_fixture()
    admin = instance_admin_scope()
    before = entries()
    {:ok, _} = Adapters.rename_adapter(admin, adapter, %{name: "Acme tracker"})
    %{scope: in_instance(admin), subject: {"node", adapter.id}, before: before}
  end

  # An instance admin sets how often a declared adapter pulls.
  def make(:"adapter.set_interval", _ctx) do
    adapter = declared_adapter()
    admin = instance_admin_scope()
    before = entries()
    {:ok, _} = Adapters.update_sync_interval(admin, adapter, %{sync_interval: 3600})
    %{scope: in_instance(admin), subject: {"node", adapter.id}, before: before}
  end

  def make(:"adapter.delete", _ctx) do
    adapter = adapter_fixture()
    admin = instance_admin_scope()
    before = entries()
    {:ok, _} = Adapters.delete_adapter(admin, adapter)
    %{scope: in_instance(admin), subject: {"node", adapter.id}, before: before}
  end

  # An owner connects the instance's adapter to their organisation, whose trail holds the
  # entry, about the organisation.
  def make(:"adapter.connect", %{scope: scope}) do
    %{adapter: adapter} = connectable_adapter_fixture()
    before = entries()
    {:ok, url, _session} = Adapters.connect(scope, adapter)
    %{"state" => pass} = URI.decode_query(URI.parse(url).query)

    %{
      scope: scope,
      subject: {"organisation", scope.organisation.id},
      secret: pass,
      before: before
    }
  end

  # An owner assigns a collection of their organisation's connection to a workspace, in
  # the organisation's trail, about the workspace.
  def make(:"collection.assign", ctx) do
    {connection, collection, workspace} = prepare(:"collection.assign", ctx)
    before = entries()
    {:ok, 1} = Collections.assign_collections(ctx.scope, connection, [collection.id], workspace)
    %{scope: ctx.scope, subject: {"workspace", workspace.id}, before: before}
  end

  # An owner turns off the Backlog of a target of the workspace, whose collection is
  # assigned there, in the workspace's trail, about the target.
  def make(:"collection.set_backlog", ctx) do
    target = prepare(:"collection.set_backlog", ctx)
    before = entries()
    {:ok, 1} = Collections.set_backlog(ctx.scope, target, false)
    %{scope: ctx.scope, subject: {"target", target.id}, before: before}
  end

  # The adapter lists a ref live under the organisation's connection under another
  # organisation's connection: the instance ends the organisation's collection, in the
  # trail of the organisation, about the collection.
  def make(:"collection.move", %{scope: scope}) do
    %{mine: mine, theirs: theirs, key_scope: key_scope} = moving(scope)
    {:ok, :accepted} = Collections.post_listing(key_scope, listed(mine, "first"))
    collection = Repo.get_by!(Collection, connection_id: mine.id)
    before = entries()
    {:ok, :accepted} = Collections.post_listing(key_scope, listed(theirs, "second"))

    %{
      scope: Scope.for_instance(scope.organisation),
      actor: :instance,
      subject: {"collection", collection.id},
      before: before
    }
  end

  # An owner chooses what the runs of a target of the workspace also read, in the
  # workspace's trail, about the target.
  def make(:"target.set_further_repositories", ctx) do
    target = prepare(:"target.set_further_repositories", ctx)
    before = entries()
    {:ok, _saved} = Targets.set_further_repositories(ctx.scope, target, "acme/docs")
    %{scope: ctx.scope, subject: {"target", target.id}, before: before}
  end

  # A member asks for a build of the environment of a target of the workspace, whose
  # collection names one, for the workspace's node pool, in the workspace's trail, about
  # the target.
  def make(:"target.rebuild_environment", ctx) do
    target = prepare(:"target.rebuild_environment", ctx)
    before = entries()
    {:ok, 1} = Apiary.Environments.rebuild(ctx.scope, target)
    %{scope: ctx.scope, subject: {"target", target.id}, before: before}
  end

  # An adapter's key declares, in the trail of the instance's organisation, and the
  # entry's actor is the key.
  def make(:"adapter.declare", _ctx) do
    %{adapter: adapter, access_key: key} = connectable_adapter_fixture()
    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)
    key_scope = Scope.for_access_key(key)
    before = entries()
    {:ok, _declared} = Adapters.declare(key_scope, declaration())

    %{
      scope: key_scope,
      subject: {"node", adapter.id},
      before: before,
      actor: {:access_key, key.id}
    }
  end

  # A gateway's secrets request seals a run's model key to its access key, in the trail of
  # the gateway's organisation, about the run; the entry's actor is the gateway's key, and
  # the entry keeps nothing of the key's value.
  def make(:"secret.seal", %{scope: scope}) do
    {ctx, key, now} = sealed_run(scope)
    # The credential names of the run's run configuration, in its order: the model key's
    # and, with the `registry` feature, the registry credential's after it.
    document = Jason.decode!(ctx.attached.settings)
    credentials = for %{"name" => name} <- document["credentials"], do: name
    body = secrets_request(ctx.run, ctx.attached.digest, credentials, now)
    before = entries()

    {:ok, _answer} =
      Apiary.Runs.SecretsRequest.answer(key, body, Apiary.ContractFixtures.instance_id(), now)

    %{
      scope: Scope.for_access_key(key),
      subject: {"run", ctx.run.id},
      before: before,
      actor: {:access_key, key.id},
      secret: Apiary.SealedRunsFixtures.model_key()
    }
  end

  # A node pool's starter gives back the run of a dispatch its pool claimed, before its
  # handover, in the trail of the workspace's organisation, about the pool; the entry's
  # actor is the pool's key.
  def make(:"dispatch.release", %{scope: scope}) do
    %{key: key} = handover_place_fixture(scope)
    {:ok, _run} = Repo.transact(fn -> Apiary.Dispatches.queue(work_item_fixture(scope), 1) end)
    {:ok, %{dispatch: dispatch}} = Apiary.Dispatches.claim(key, Apiary.Dispatches.now())
    before = entries()

    :ok =
      Apiary.Dispatches.release(key, dispatch.public_id, %{
        reason: "The job could not start."
      })

    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)

    %{
      scope: Scope.for_access_key(key),
      subject: {"node", key.node_id},
      before: before,
      actor: {:access_key, key.id}
    }
  end

  # A member takes a ticket of the workspace's Backlog in, in the workspace's trail,
  # about the new work item.
  def make(:"work_item.take_in", %{scope: scope} = ctx) do
    ticket = prepare(:"work_item.take_in", ctx)
    before = entries()
    {:ok, work_item} = Apiary.WorkItems.take_in(scope, ticket.public_id)
    %{scope: scope, subject: subject_of(work_item), before: before}
  end

  # A member undoes, declines or closes a work item of the workspace, answers the questions
  # of its run, confirms its run's proposal or asks for another run, about it.
  def make(action, %{scope: scope} = ctx) when action in @work_item_moves do
    work_item = prepare(action, ctx)
    before = entries()
    {:ok, _work_item} = attempt(action, scope, work_item)
    %{scope: scope, subject: subject_of(work_item), before: before}
  end

  # A member comments on a work item of the workspace, or deletes a comment there.
  def make(action, %{scope: scope} = ctx) when action in @work_item_comments do
    subject = prepare(action, ctx)
    before = entries()
    {:ok, _comment} = attempt(action, scope, subject)
    %{scope: scope, subject: subject_of(subject), before: before}
  end

  def make(:"node.clear_instance", %{scope: scope}) do
    node = node_fixture(scope)
    instance = instance_fixture(node, name: "build-01.example.com")
    node_run_fixture(node, instance.node_instance_id)
    before = entries()
    {:ok, _} = Nodes.clear_instance(scope, node, instance.node_instance_id)
    %{scope: scope, subject: {"node", node.id}, before: before}
  end

  def make(:"retention.edit", %{scope: scope}) do
    before = entries()
    {:ok, _} = Retention.update_retention(scope, %{events_retention_days: 30})
    %{scope: scope, subject: {"workspace", scope.workspace.id}, before: before}
  end

  def make(:"security_policy.edit", %{scope: scope}) do
    before = entries()
    {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
    %{scope: scope, subject: {"workspace", scope.workspace.id}, before: before}
  end

  def make(:"security_policy.lock", %{scope: scope}) do
    {:ok, rule} = Policy.allow(scope, nil, %{host: "api.example"})
    before = entries()
    {:ok, _} = Policy.lock(scope, rule)
    %{scope: scope, subject: {"workspace", scope.workspace.id}, before: before}
  end

  def make(:"security_policy.set_mode", %{scope: scope}) do
    before = entries()
    {:ok, _} = Policy.set_mode(scope, "enforce")
    %{scope: scope, subject: {"workspace", scope.workspace.id}, before: before}
  end

  def make(:"secret.write", %{scope: scope}) do
    before = entries()
    value = "s3cr3t-audit-value"
    {:ok, secret} = Secrets.create_secret(scope, %{name: "API_TOKEN", value: value})
    %{scope: scope, subject: {"secret", secret.id}, before: before, secret: value}
  end

  def make(:"variable.edit", %{scope: scope}) do
    before = entries()
    value = "plain-audit-value"

    {:ok, variable} =
      Variables.create_variable(scope, :workspace, %{name: "NODE_ENV", value: value})

    %{scope: scope, subject: {"variable", variable.id}, before: before, secret: value}
  end

  def make(:"connection.write", %{scope: scope}) do
    before = entries()
    {:ok, connection} = Apiary.Connections.create_service(scope, %{service: "sentry"})
    %{scope: scope, subject: {"connection", connection.id}, before: before}
  end

  # A model provider is added: the key's value is the secret no entry may hold.
  def make(:"provider.write", %{scope: scope}) do
    value = "sk-audit-provider-key"
    before = entries()

    {:ok, provider} =
      Apiary.Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: value}]
      })

    %{scope: scope, subject: {"connection", provider.id}, before: before, secret: value}
  end

  def make(:"runtime.write", %{scope: scope}) do
    before = entries()
    {:ok, connection} = Apiary.Connections.create_runtime(scope, %{runtime: "claude"})
    %{scope: scope, subject: {"connection", connection.id}, before: before}
  end

  # A model provider is added, then the workspace's choice names it, in the workspace's
  # trail, about the choice. The key's value is the secret no entry may hold.
  def make(:"model_choice.write", %{scope: scope}) do
    value = "sk-audit-model-key"

    {:ok, provider} =
      Apiary.Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: value}]
      })

    before = entries()

    {:ok, choice} =
      Apiary.ModelChoices.put_choice(scope, :workspace, %{provider: provider.public_id})

    %{scope: scope, subject: {"model_choice", choice.id}, before: before, secret: value}
  end

  # The workspace's time limit for the runs of a workflow, in the workspace's trail, about
  # the limit.
  def make(:"time_limit.edit", %{scope: scope}) do
    before = entries()
    {:ok, limit} = Apiary.TimeLimits.put_limit(scope, :workspace, "hello", 90)
    %{scope: scope, subject: {"time_limit", limit.id}, before: before}
  end

  def make(:"organisation.delete", %{scope: scope}) do
    before = entries()
    {:ok, _} = Deletion.delete_organisation(scope, scope.organisation.slug)
    %{scope: scope, subject: {"organisation", scope.organisation.id}, before: before}
  end

  def make(:"organisation.restore", %{scope: scope}) do
    {:ok, _} = Deletion.delete_organisation(scope, scope.organisation.slug)
    before = entries()
    {:ok, _} = Deletion.restore_organisation(scope, scope.organisation.id)
    %{scope: scope, subject: {"organisation", scope.organisation.id}, before: before}
  end

  def make(:"workspace.delete", %{scope: scope}) do
    workspace = workspace_fixture(scope.organisation)
    before = entries()
    {:ok, _} = Deletion.delete_workspace(scope, workspace.id, workspace.slug)
    %{scope: scope, subject: {"workspace", workspace.id}, before: before}
  end

  def make(:"workspace.restore", %{scope: scope}) do
    workspace = workspace_fixture(scope.organisation)
    {:ok, _} = Deletion.delete_workspace(scope, workspace.id, workspace.slug)
    before = entries()
    {:ok, _} = Deletion.restore_workspace(scope, workspace.id)
    %{scope: scope, subject: {"workspace", workspace.id}, before: before}
  end

  def make(:"workspace.purge", %{scope: scope}) do
    workspace = due_workspace(scope)
    before = entries()
    instance = Scope.for_instance(scope.organisation, workspace)
    {:ok, :purged} = Deletion.purge_workspace(instance)
    # The workspace's own entries are purged with it: not the one looked for.
    %{
      scope: instance,
      actor: :instance,
      subject: {"workspace", workspace.id},
      before: Enum.filter(before, &(&1 in entries()))
    }
  end

  @doc """
  refuse/2 makes `action` refused or rolled back, in the context `Apiary.AuditCase` gives:
  `{the trail before the attempt, the attempt's answer}`.
  """
  @spec refuse(Access.action(), map) :: {list, term}
  def refuse(:"organisation.create", _ctx) do
    before = entries()

    {before,
     Organisations.sign_up_user(%{email: "not an address", organisation_name: "Acme"}, nil,
       open: true
     )}
  end

  def refuse(:"invitation.accept", %{scope: scope}) do
    %{token: token} = invitation_fixture(scope)
    # Accepted once already: the second finds no pending invitation.
    %{user: first} = sign_up_fixture()
    {:ok, _} = Organisations.accept_invitation(first, token)
    %{user: user} = sign_up_fixture()
    before = entries()
    {before, Organisations.accept_invitation(Scope.for_user(user), token)}
  end

  # An account deleted is made nobody's admin.
  def refuse(:"instance_admin.grant", _ctx) do
    user = Apiary.AccountsFixtures.user_fixture()
    {:ok, _} = Accounts.delete_user(%Scope{user: user})
    before = entries()
    {before, Organisations.grant_instance_admin(user)}
  end

  # An instance admin, once mail is set: the person asks for a log-in link instead.
  def refuse(:"account.password_link", _ctx) do
    admin = password_link_admin()
    user = Apiary.AccountsFixtures.user_fixture()
    before = entries()
    {before, Accounts.build_password_link(admin, user, &"http://localhost/users/password/#{&1}")}
  end

  # Anyone but an instance admin: the owner of an organisation that is not the instance's.
  def refuse(:"instance.rename", %{scope: scope}) do
    before = entries()
    {before, Apiary.ProductName.rename(scope, %{"product_name" => "Acme Agents"})}
  end

  # An instance admin whose sign-in is no longer recent signs in again first, for the
  # instance's settings as for its mail.
  def refuse(:"instance.configure", _ctx) do
    admin = password_link_admin() |> mail_signed_in(-21)
    before = entries()

    {before, Apiary.InstanceConfig.save(admin, :invitations, %{"invitations_per_day" => "50"})}
  end

  def refuse(:"instance.mail_save", _ctx) do
    admin = mail_admin() |> mail_signed_in(-21)
    before = entries()

    {before,
     Apiary.Mail.save_settings(
       admin,
       @mail_attrs,
       &"http://localhost/instance/mail/confirm/#{&1}"
     )}
  end

  def refuse(:"instance.mail_on", _ctx) do
    {admin, token} = mail_saved()
    before = entries()
    {before, Apiary.Mail.turn_on(mail_signed_in(admin, -21), token)}
  end

  # The instance's last admin, the suite's first user, stays one.
  def refuse(:"instance_admin.revoke", _ctx) do
    [admin] =
      Repo.all(
        from m in Membership,
          where:
            m.organisation_id == ^Apiary.Edition.instance_organisation_id() and
              m.level == ^Access.instance_admin_level(),
          preload: :user
      )

    before = entries()
    {before, Organisations.revoke_instance_admin(admin.user)}
  end

  def refuse(:"audit.prune", %{scope: scope, owner: %{organisation: organisation}}) do
    old!(organisation)
    before = entries()
    {before, Audit.prune(scope)}
  end

  # Anyone but the instance, here an owner, may not purge.
  def refuse(:"workspace.purge", %{scope: scope}) do
    workspace = due_workspace(scope)
    before = entries()
    {before, Deletion.purge_workspace(%{scope | workspace: workspace})}
  end

  # Anyone but the instance, here an owner, installs no adapter.
  def refuse(:"adapter.install", %{scope: scope}) do
    before = entries()
    {before, Adapters.install(scope, "tracker")}
  end

  # A listing's part of an ended connection names the ref live under the organisation's
  # connection: it is refused, and moves nothing.
  def refuse(:"collection.move", %{scope: scope}) do
    %{mine: mine, theirs: theirs, key_scope: key_scope} = moving(scope)
    {:ok, :accepted} = Collections.post_listing(key_scope, listed(mine, "first"))
    {:ok, _ended} = Adapters.Connections.end_connection(key_scope, theirs.public_id)
    before = entries()
    {before, Collections.post_listing(key_scope, listed(theirs, "second"))}
  end

  # A node's key declares no adapter.
  def refuse(:"adapter.declare", %{scope: scope}) do
    connectable_adapter_fixture()
    %{access_key: key} = node_key_fixture(scope, node_fixture(scope))
    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)
    before = entries()
    {before, Adapters.declare(Scope.for_access_key(key), declaration())}
  end

  # A request with a credential the run does not have seals nothing.
  def refuse(:"secret.seal", %{scope: scope}) do
    {ctx, key, now} = sealed_run(scope)
    body = secrets_request(ctx.run, ctx.attached.digest, ["forge"], now)
    before = entries()

    {before,
     Apiary.Runs.SecretsRequest.answer(key, body, Apiary.ContractFixtures.instance_id(), now)}
  end

  # A dispatch another pool of the workspace claimed is not the key's to give back.
  def refuse(:"dispatch.release", %{scope: scope}) do
    %{key: claimer} = handover_place_fixture(scope)
    %{access_key: other} = enrolled_key_fixture(scope, pool_fixture(scope))
    {:ok, _run} = Repo.transact(fn -> Apiary.Dispatches.queue(work_item_fixture(scope), 1) end)
    {:ok, %{dispatch: dispatch}} = Apiary.Dispatches.claim(claimer, Apiary.Dispatches.now())
    before = entries()

    {before,
     Apiary.Dispatches.release(other, dispatch.public_id, %{
       reason: "The job could not start."
     })}
  end

  # A member where the change is an owner's or an admin's; where every member may make it,
  # a person who was a member when the scope was loaded and is no longer.
  def refuse(action, ctx),
    do: refuse_as_member(action, ctx, &prepare(action, &1), &attempt(action, &1, &2))

  # An adapter connected to the scope's organisation (`mine`) and to another
  # organisation (`theirs`), and its key's scope.
  defp moving(scope) do
    %{adapter: adapter, access_key: key} = connectable_adapter_fixture()
    {mine, _nonce} = connection_fixture(scope, adapter, :connected)
    %{scope: other} = sign_up_fixture()
    {theirs, _nonce} = connection_fixture(other, adapter, :connected)
    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)
    %{mine: mine, theirs: theirs, key_scope: Scope.for_access_key(key)}
  end

  # A complete listing of `connection` naming the ref `TRK`.
  defp listed(connection, id) do
    %{
      time: DateTime.utc_now(:second),
      connection_id: connection.public_id,
      collections: [
        %{ref: "TRK", url: "https://tracker.acme.example/TRK", title: "Tracker", target: nil}
      ],
      listing: %{id: id, part: 1, started_at: DateTime.utc_now(:second), complete: true}
    }
  end

  # What an adapter declares as it starts (`Apiary.Adapters.Wire.declaration/1`).
  defp declaration do
    %{
      time: DateTime.utc_now(:second),
      connect_url: "https://tracker-adapter.acme.example/connect",
      default_interval: 900,
      minimum_interval: 300,
      sends_changes: false,
      description: Apiary.DescriptionFixtures.read_description()
    }
  end

  # An adapter that has declared how it pulls.
  defp declared_adapter do
    %{access_key: key} = connectable_adapter_fixture()
    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)
    {:ok, declared} = Adapters.declare(Scope.for_access_key(key), declaration())
    declared
  end

  defp prepare(:"member.change_level", %{scope: scope}), do: member_fixture(scope).membership
  defp prepare(:"member.remove", %{scope: scope}), do: member_fixture(scope).membership
  defp prepare(:"invitation.revoke", %{scope: scope}), do: invitation_fixture(scope).invitation
  defp prepare(:"invitation.renew", %{scope: scope}), do: invitation_fixture(scope).invitation
  defp prepare(:"member.suspend", %{scope: scope}), do: member_fixture(scope).membership

  defp prepare(:"member.activate", %{scope: scope}) do
    %{membership: membership} = member_fixture(scope)
    {:ok, suspended} = Organisations.suspend_member(scope, membership.id)
    suspended
  end

  defp prepare(:"access_key.create_code", %{scope: scope}), do: node_fixture(scope)

  defp prepare(:"access_key.cancel_code", %{scope: scope}) do
    {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node_fixture(scope), %{})
    row
  end

  defp prepare(:"access_key.add", %{scope: scope}), do: node_fixture(scope)

  defp prepare(:"access_key.revoke", %{scope: scope}),
    do: node_key_fixture(scope, node_fixture(scope)).access_key

  defp prepare(:"adapter.edit", _ctx), do: adapter_fixture()
  defp prepare(:"adapter.set_interval", _ctx), do: declared_adapter()
  defp prepare(:"adapter.delete", _ctx), do: adapter_fixture()
  defp prepare(:"adapter.connect", _ctx), do: adapter_fixture()

  defp prepare(:"adapter.setup", _ctx),
    do: settable_adapter_fixture() |> Map.fetch!(:adapter)

  # A collection the adapter listed for the organisation's connection, and a workspace
  # made after it, so assigning it there changes its link.
  defp prepare(:"collection.assign", %{scope: scope}) do
    %{adapter: adapter, access_key: key} = connectable_adapter_fixture()
    {connection, _nonce} = connection_fixture(scope, adapter, :listed)
    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)

    {:ok, :accepted} =
      Collections.post_listing(Scope.for_access_key(key), %{
        time: DateTime.utc_now(:second),
        connection_id: connection.public_id,
        collections: [
          %{ref: "TRK", url: "https://tracker.acme.example/TRK", title: "Tracker", target: nil}
        ],
        listing: %{id: "first", part: 1, started_at: DateTime.utc_now(:second), complete: true}
      })

    collection = Repo.get_by!(Collection, connection_id: connection.id)
    {connection, collection, workspace_fixture(scope.organisation)}
  end

  # A target of the scope's workspace, as a run's labels make it.
  defp prepare(:"target.set_further_repositories", %{scope: scope}) do
    :ok =
      Apiary.Runs.Target.insert_new(scope.organisation.id, scope.workspace.id, [
        %{system: "code.example.com", path: "acme/shop"}
      ])

    Targets.get(scope, "code.example.com", "acme/shop")
  end

  # A target of the scope's workspace, a node pool there, then a collection assigned there
  # with the target and an `environment_ref`, made after the pool, so nothing is queued
  # for it yet.
  defp prepare(:"target.rebuild_environment", %{scope: scope}) do
    pool_fixture(scope)

    collection_fixture(scope,
      external_ref: "SHOP",
      target_system: "code.example.com",
      target_path: "acme/shop",
      environment_ref: "env-1"
    )

    :ok =
      Apiary.Runs.Target.insert_new(scope.organisation.id, scope.workspace.id, [
        %{system: "code.example.com", path: "acme/shop"}
      ])

    Targets.get(scope, "code.example.com", "acme/shop")
  end

  # A collection with a target, listed for the organisation's connection and assigned to
  # the scope's workspace, which makes the target there.
  defp prepare(:"collection.set_backlog", %{scope: scope}) do
    %{adapter: adapter, access_key: key} = connectable_adapter_fixture()
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)

    {:ok, :accepted} =
      Collections.post_listing(Scope.for_access_key(key), %{
        time: DateTime.utc_now(:second),
        connection_id: connection.public_id,
        collections: [
          %{
            ref: "SHOP",
            url: "https://tracker.acme.example/SHOP",
            title: "acme/shop",
            target: %{system: "code.example.com", path: "acme/shop"}
          }
        ],
        listing: %{id: "first", part: 1, started_at: DateTime.utc_now(:second), complete: true}
      })

    collection = Repo.get_by!(Collection, connection_id: connection.id)

    {:ok, _changed} =
      Collections.assign_collections(scope, connection, [collection.id], scope.workspace)

    Repo.get_by!(Apiary.Runs.Target,
      workspace_id: scope.workspace.id,
      system: "code.example.com",
      path: "acme/shop"
    )
  end

  defp prepare(:"work_item.take_in", %{scope: scope}),
    do: Apiary.WorkItemsFixtures.backlog_ticket_fixture(scope)

  # A work item whose run asked, or proposed, or gave no result, as the action needs.
  defp prepare(:"work_item.answer", %{scope: scope}) do
    work_item = Apiary.WorkItemsFixtures.work_item_fixture(scope)
    result = Apiary.WorkItemsFixtures.questions_result(["Which basket?"])
    Apiary.WorkItemsFixtures.explore_run_fixture(work_item, result: result)
    work_item
  end

  defp prepare(:"work_item.confirm", %{scope: scope}) do
    work_item = Apiary.WorkItemsFixtures.work_item_fixture(scope)
    result = Apiary.WorkItemsFixtures.understood_result()
    Apiary.WorkItemsFixtures.explore_run_fixture(work_item, result: result)
    work_item
  end

  defp prepare(:"work_item.explore_again", %{scope: scope}) do
    work_item = Apiary.WorkItemsFixtures.work_item_fixture(scope)
    Apiary.WorkItemsFixtures.explore_run_fixture(work_item)
    work_item
  end

  # A comment by the owner, which a member may not delete.
  defp prepare(:"work_item.comment_delete", %{scope: scope}) do
    work_item = Apiary.WorkItemsFixtures.work_item_fixture(scope)
    {:ok, comment} = Apiary.WorkItems.comment(scope, work_item, "Seen on staging")
    comment
  end

  defp prepare(action, %{scope: scope})
       when action in @work_item_moves or action in @work_item_comments,
       do: Apiary.WorkItemsFixtures.work_item_fixture(scope)

  defp prepare(:"node.edit", %{scope: scope}), do: node_fixture(scope)
  defp prepare(:"node.delete", %{scope: scope}), do: node_fixture(scope)

  defp prepare(:"node.clear_instance", %{scope: scope}) do
    node = node_fixture(scope)
    {node, instance_fixture(node).node_instance_id}
  end

  defp prepare(:"organisation.restore", %{scope: scope}) do
    {:ok, organisation} = Deletion.delete_organisation(scope, scope.organisation.slug)
    organisation
  end

  defp prepare(:"workspace.delete", %{scope: scope}), do: workspace_fixture(scope.organisation)

  defp prepare(:"workspace.restore", %{scope: scope}) do
    workspace = workspace_fixture(scope.organisation)
    {:ok, workspace} = Deletion.delete_workspace(scope, workspace.id, workspace.slug)
    workspace
  end

  defp prepare(:"security_policy.lock", %{scope: scope}) do
    {:ok, rule} = Policy.allow(scope, nil, %{host: "api.example"})
    rule
  end

  defp prepare(_action, _ctx), do: nil

  defp attempt(:"organisation.rename", scope, _),
    do: Organisations.update_organisation(scope, %{name: "Renamed"})

  defp attempt(:"organisation.delete", scope, _),
    do: Deletion.delete_organisation(scope, scope.organisation.slug)

  defp attempt(:"organisation.restore", scope, organisation),
    do: Deletion.restore_organisation(scope, organisation.id)

  defp attempt(:"workspace.create", scope, _),
    do: Organisations.create_workspace(scope, %{"name" => "Data", "domain" => "software"})

  defp attempt(:"workspace.delete", scope, workspace),
    do: Deletion.delete_workspace(scope, workspace.id, workspace.slug)

  defp attempt(:"workspace.restore", scope, workspace),
    do: Deletion.restore_workspace(scope, workspace.id)

  defp attempt(:"member.invite", scope, _) do
    Organisations.invite_member(
      scope,
      %{"email" => unique_user_email()},
      &"http://localhost/invitations/#{&1}"
    )
  end

  defp attempt(:"member.change_level", scope, membership),
    do: Organisations.set_member_level(scope, membership.id, :owner)

  defp attempt(:"member.remove", scope, membership),
    do: Organisations.remove_member(scope, membership.id)

  defp attempt(:"invitation.revoke", scope, invitation),
    do: Organisations.revoke_invitation(scope, invitation.id)

  defp attempt(:"invitation.renew", scope, invitation),
    do:
      Organisations.renew_invitation(
        scope,
        invitation.id,
        &"http://localhost/invitations/#{&1}"
      )

  defp attempt(:"member.suspend", scope, membership),
    do: Organisations.suspend_member(scope, membership.id)

  defp attempt(:"member.activate", scope, membership),
    do: Organisations.activate_member(scope, membership.id)

  defp attempt(:"workspace.rename", scope, _),
    do: Organisations.update_workspace(scope, %{name: "Renamed"})

  defp attempt(:"access_key.revoke", scope, key), do: AccessKeys.revoke_access_key(scope, key)

  defp attempt(:"access_key.create_code", scope, node),
    do: AccessKeys.create_enrolment_code(scope, node, %{})

  defp attempt(:"access_key.cancel_code", scope, code), do: AccessKeys.cancel_code(scope, code)

  defp attempt(:"access_key.add", scope, node),
    do:
      AccessKeys.add_access_key(scope, node, %{
        label: "build-01",
        public_key: ed25519_key_pair().encoded
      })

  defp attempt(:"node.create", scope, _),
    do: Nodes.create_node(scope, %{kind: "node", name: "build-01"})

  defp attempt(:"adapter.create", scope, _),
    do: Adapters.create_adapter(scope, %{name: "Acme tracker"})

  defp attempt(:"adapter.edit", scope, adapter),
    do: Adapters.rename_adapter(scope, adapter, %{name: "Acme tracker"})

  defp attempt(:"adapter.set_interval", scope, adapter),
    do: Adapters.update_sync_interval(scope, adapter, %{sync_interval: 3600})

  defp attempt(:"adapter.delete", scope, adapter), do: Adapters.delete_adapter(scope, adapter)

  defp attempt(:"adapter.connect", scope, adapter),
    do: Adapters.connect(scope, adapter)

  defp attempt(:"adapter.setup", scope, adapter), do: Adapters.setup(scope, adapter)

  defp attempt(:"collection.assign", scope, {connection, collection, workspace}),
    do: Collections.assign_collections(scope, connection, [collection.id], workspace)

  defp attempt(:"collection.set_backlog", scope, target),
    do: Collections.set_backlog(scope, target, false)

  defp attempt(:"target.set_further_repositories", scope, target),
    do: Targets.set_further_repositories(scope, target, "acme/docs")

  defp attempt(:"target.rebuild_environment", scope, target),
    do: Apiary.Environments.rebuild(scope, target)

  defp attempt(:"work_item.take_in", scope, ticket),
    do: Apiary.WorkItems.take_in(scope, ticket.public_id)

  defp attempt(:"work_item.undo", scope, work_item), do: Apiary.WorkItems.undo(scope, work_item)

  defp attempt(:"work_item.decline", scope, work_item),
    do: Apiary.WorkItems.decline(scope, work_item)

  defp attempt(:"work_item.close", scope, work_item), do: Apiary.WorkItems.close(scope, work_item)

  defp attempt(:"work_item.answer", scope, work_item),
    do: Apiary.WorkItems.answer(scope, work_item, 1, %{"1" => "The one at checkout."})

  defp attempt(:"work_item.confirm", scope, work_item),
    do: Apiary.WorkItems.confirm(scope, work_item, 1)

  defp attempt(:"work_item.explore_again", scope, work_item),
    do: Apiary.WorkItems.explore_again(scope, work_item, 1)

  defp attempt(:"work_item.comment", scope, work_item),
    do: Apiary.WorkItems.comment(scope, work_item, "Seen on staging")

  defp attempt(:"work_item.comment_delete", scope, comment),
    do: Apiary.WorkItems.delete_comment(scope, comment.public_id)

  defp attempt(:"node.edit", scope, node), do: Nodes.update_node(scope, node, %{name: "build-02"})
  defp attempt(:"node.delete", scope, node), do: Nodes.delete_node(scope, node)

  defp attempt(:"node.clear_instance", scope, {node, instance_id}),
    do: Nodes.clear_instance(scope, node, instance_id)

  defp attempt(:"secret.write", scope, _),
    do: Secrets.create_secret(scope, %{name: "API_TOKEN", value: "s3cr3t-audit-value"})

  defp attempt(:"variable.edit", scope, _),
    do: Variables.create_variable(scope, :workspace, %{name: "NODE_ENV", value: "test"})

  defp attempt(:"connection.write", scope, _),
    do: Apiary.Connections.create_service(scope, %{service: "sentry"})

  defp attempt(:"provider.write", scope, _),
    do:
      Apiary.Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: "sk-audit-provider-key"}]
      })

  defp attempt(:"runtime.write", scope, _),
    do: Apiary.Connections.create_runtime(scope, %{runtime: "claude"})

  defp attempt(:"model_choice.write", scope, _),
    do: Apiary.ModelChoices.put_choice(scope, :workspace, %{tiers: %{"light" => "model-1"}})

  defp attempt(:"time_limit.edit", scope, _),
    do: Apiary.TimeLimits.put_limit(scope, :workspace, "hello", 90)

  defp attempt(:"retention.edit", scope, _),
    do: Retention.update_retention(scope, %{events_retention_days: 30})

  defp attempt(:"security_policy.edit", scope, _),
    do: Policy.allow(scope, nil, %{host: "api.example"})

  defp attempt(:"security_policy.lock", scope, rule), do: Policy.lock(scope, rule)
  defp attempt(:"security_policy.set_mode", scope, _), do: Policy.set_mode(scope, "enforce")

  # The scope's workspace, the organisation's only one, marked for deletion directly, and
  # the scope loaded again, with no workspace in use: the product does not delete an
  # organisation's last workspace, and the core's edition lets another be created only in
  # its place.
  defp mark_only_workspace(%Scope{workspace: %Workspace{} = workspace} = scope) do
    now = DateTime.utc_now()

    workspace
    |> Ecto.Changeset.change(
      deletion_marked_at: now,
      purge_after: DateTime.add(now, 30, :day),
      purge_trigger: "grace_period"
    )
    |> Repo.update!()

    Organisations.load_scope(Scope.for_user(scope.user), scope.organisation.id)
  end

  # The instance's own organisation (`c:Apiary.Edition.instance_organisation_id/0`).
  defp instance_organisation,
    do: Repo.get!(Organisation, Apiary.Edition.instance_organisation_id())

  # `scope`'s person in the instance's organisation, whose trail holds what they change of
  # the instance.
  defp in_instance(scope), do: Scope.in_organisation(scope, instance_organisation())

  # A fresh instance admin, by a release command: their scope.
  defp password_link_admin do
    %{user: admin} = sign_up_fixture()
    {:ok, _} = Organisations.grant_instance_admin(admin)
    Scope.for_user(admin)
  end

  # A fresh instance admin, signed in just now, on an instance whose mail comes from no
  # environment: their scope.
  defp mail_admin do
    admin = password_link_admin() |> mail_signed_in(0)
    Apiary.Mail.put_test_source(:none)
    admin
  end

  defp mail_signed_in(%Scope{} = scope, minutes),
    do: put_in(scope.user.authenticated_at, DateTime.add(DateTime.utc_now(), minutes, :minute))

  # Mail settings saved by a fresh instance admin: their scope, and the test link's token.
  defp mail_saved do
    admin = mail_admin()

    {:ok, _settings, :sent} =
      Apiary.Mail.save_settings(
        admin,
        @mail_attrs,
        &"http://localhost/instance/mail/confirm/#{&1}"
      )

    receive do
      {:email, %Swoosh.Email{subject: "Turn on mail for Qory Apiary", text_body: body}} ->
        [_, token] = Regex.run(~r{/instance/mail/confirm/([A-Za-z0-9_-]+)}, body)
        {admin, token}
    after
      0 -> raise "no test link was sent"
    end
  end

  # The entries of `entries` of the edition's own actions (`Apiary.Edition.actions/0`).
  defp of_the_edition(entries) do
    names = Enum.map(Apiary.Edition.actions(), &Atom.to_string(&1.name))
    Enum.filter(entries, &(&1.action in names))
  end

  # A second workspace of the scope's organisation, deleted and past its grace period.
  defp due_workspace(scope) do
    workspace = workspace_fixture(scope.organisation)
    {:ok, _} = Deletion.delete_workspace(scope, workspace.id, workspace.slug)

    Repo.update_all(from(w in Workspace, where: w.id == ^workspace.id),
      set: [purge_after: DateTime.add(DateTime.utc_now(), -60, :second)]
    )

    workspace
  end

  defp subject_of(%Apiary.WorkItems.WorkItem{id: id}), do: {"work_item", id}
  defp subject_of(%Apiary.WorkItems.Comment{work_item_id: id}), do: {"work_item", id}

  defp sealed_run(scope) do
    ctx = Apiary.SealedRunsFixtures.sealed_run_fixture(scope)
    {key, _seed} = ctx.secrets_key
    {ctx, key, ApiaryWeb.Contract.SignedRequest.now()}
  end

  defp secrets_request(run, digest, credentials, now),
    do: Apiary.SealedRunsFixtures.secrets_request(run, digest, credentials, now)
end
