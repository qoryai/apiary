defmodule Apiary.Access do
  import Ecto.Query, warn: false

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Access.Action
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.{Edition, Features}
  alias Apiary.Organisations.{Invitation, Membership, Organisation, Workspace}
  alias Apiary.Repo

  @owners [:owner]
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
    Action.new(:"access_key.create", "create an access key", roles: @members),
    Action.new(:"access_key.rotate", "rotate an access key, and retire its previous secret",
      roles: @members
    ),
    Action.new(:"access_key.revoke", "revoke an access key", roles: @members),
    # The record.
    Action.new(:"run.read", "read the runs, their outcomes and the connections",
      feature: :observability,
      roles: @members,
      audited: {:not, @read}
    ),
    Action.new(:"run.read_log", "read a run's log: its terminal, stdout and stderr",
      feature: :observability,
      roles: @members,
      audited: {:not, @read}
    ),
    Action.new(:"run.close", "close a run that has not ended",
      feature: :observability,
      roles: @members
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
    # The server contract.
    Action.new(:"run.post_events", "post a run's events",
      feature: :observability,
      roles: [:access_key],
      audited: {:not, "the events a runner posts are the record, not the audit trail"}
    ),
    Action.new(:"run_configuration.fetch", "fetch the run configuration",
      feature: :security,
      roles: [:access_key],
      audited: {:not, "a runner's fetch reads the policy and changes nothing"}
    )
  ]

  # The core's roles, with who holds each: a membership's level, a runner's access key, or
  # the instance itself. An edition adds its own (`c:Apiary.Edition.roles/0`).
  @roles [
    member: "a person at member, in the workspaces their level reaches",
    admin: "a person at admin, in every workspace; over members only",
    owner: "a person at owner, in every workspace",
    access_key: "a runner, with a key of the workspace",
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
    :"invitation.revoke"
  ]
  @acts_on %{owner: [:owner, :admin, :member], admin: [:member]}

  # Suspending and activating a membership: an owner over admins and members, an admin
  # over members. An owner is not suspended by another.
  @suspends [:"member.suspend", :"member.activate"]
  @suspends_over %{owner: [:admin, :member], admin: [:member]}

  # The level of the instance organisation's people who are the instance admins.
  @instance_admin_level :owner

  # What nobody takes on their own membership: an owner does not suspend themselves, and
  # nobody activates their own.
  @not_own [:"member.suspend", :"member.activate"]

  # What anyone with a membership may take on their own, at any level: leaving the
  # organisation. The last-owner rule still holds (`Apiary.Organisations`).
  @own [:"member.remove"]

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
    `Apiary.Access.Action` named once, with the feature it belongs to, in the table below;
    an edition adds its own (`c:Apiary.Edition.actions/0`). The registry of both is built
    once, checked, and kept for the node: an action named twice, a role or a feature
    nobody knows, stops it. An action that is in neither raises `ArgumentError`.
  - **`subject`** is the thing acted on: an organisation, a workspace, or a row of one, such
    as a run, a rule, an access key, an invitation or a membership, which carries
    `organisation_id`, and `workspace_id` when it belongs to a workspace. Deleting a
    workspace and cancelling its deletion are asked of the organisation: an owner or an
    admin deletes any workspace of it, from the organisation's settings.

  The answer is read in this order:

  1. **The feature** the action belongs to (`Apiary.Features.on?/2`). An action of a
     feature that is off is `{:error, :not_found}`: a feature that is off is absent, not
     forbidden.
  2. **The edition** (`c:Apiary.Edition.check/3`), asked once: it may answer, for what it
     adds or narrows, or leave the answer to the steps below. The core's own edition
     leaves every answer to them.
  3. **Where the subject is** (`check_place/3`). A subject of another organisation, or of
     another workspace than the scope's, is `{:error, :not_found}`, so the answer does not
     tell that it exists.
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
     `member.remove` of their own membership, whatever their level (`own/0`); the rule
     that an organisation keeps an owner still holds (`Apiary.Organisations`). Nobody
     suspends or activates their own membership.
  7. **The role** of the one asking (`role/1`), in the role table below. An action the
     role does not hold is `{:error, :forbidden}`, and so is every action for a person
     without a membership where the scope is, unless the edition gives them a role there;
     the page decides whether it says forbidden or not found.
  8. **Whom the action is over**, for the actions over people: inviting, changing a
     level, removing, suspending, activating and revoking an invitation. An owner takes
     them over anyone (suspending and activating over admins and members), within the
     rule that an organisation keeps an owner (`Apiary.Organisations`); an admin over
     members only, never over an owner or an admin (`acts_on?/2`). Asked of the
     membership, whose level decides, or of the invitation, which is at member: an
     invitation is an email address, and its person joins as a member; asked of a
     workspace or the organisation, as a page asks whether to show the button at all, the
     role alone answers. A level other than the role allows is `{:error, :forbidden}`. An
     invitation is the organisation's, whichever workspace it grants.

  A context function that changes something asks `authorize/3` before it acts: that is the
  check that counts. It reads the person's membership again from the database, with what
  the edition put on the scope, because what a scope carries may be as old as the
  LiveView that holds it. A page asks `can?/3`, with the same action, for what it shows:
  a button for an action the reader may not take is not rendered. `can?/3` answers from
  the scope as it was loaded, without a read, so a page may ask it on every render. A
  context function that asks several questions in one change reads once with `reload/2`
  and asks each with `check/3`.

  ## Actions

  | Action | What | Feature |
  |---|---|---|
  #{Enum.map_join(@actions, "\n", fn action -> "| `#{action.name}` | #{action.what} | #{if action.feature, do: "`#{action.feature}`", else: "every instance"} |" end)}

  ## Roles

  | Role | Who | Actions |
  |---|---|---|
  #{Enum.map_join(@roles, "\n", fn {role, who} -> "| `#{role}` | #{who} | #{@actions |> Enum.filter(&(role in &1.roles)) |> Enum.map_join(", ", &"`#{&1.name}`")} |" end)}

  Anyone with a membership, at any level, may also remove their own: #{Enum.map_join(@own, ", ", &"`#{&1}`")}.
  Nobody suspends or activates their own membership (#{Enum.map_join(@not_own, ", ", &"`#{&1}`")}).

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

  ## Reach

  A person reaches an organisation through their membership there, at its level: what
  they may change there is its role's. The edition may give a person another way in
  (`c:Apiary.Edition.reach/1`), which the scope's `reach` carries, and a role there
  without a membership (`c:Apiary.Edition.role/1`): such a person reads every workspace of
  the organisation. `reach/1` says which way the scope carries, `level/1` the level they
  act at, which only a membership there gives, and `reader/1` how one without a
  membership reaches it. `Apiary.Organisations.resolve_scope/4` finds the reach a page's
  path opens; `reload/2`, in `authorize/3`, reads the membership again, and the edition
  what it gave, and fails closed.

  ## The instance's admins

  The owners of the instance's organisation (`c:Apiary.Edition.instance_organisation_id/0`)
  run the instance: `instance_admin?/1` says whether a scope's person is one, and is the
  one place that says so. A release command makes an account one or ends it
  (`instance_admin.grant`, `instance_admin.revoke`), which no role takes. Inside the
  organisation they act at their level as anyone there.

  ## Features

  The feature an action belongs to is asked of `Apiary.Features.on?/2` with the scope,
  which carries what its organisation and workspace have (`Apiary.Features.of/2`);
  `reload/2` reads them again after its locks.
  """

  @typedoc "An action, one of `actions/0`."
  @type action :: atom

  @typedoc """
  A role: one of the core's, `:owner`, `:admin`, `:member`, `:access_key` and
  `:instance`, or one the edition adds (`c:Apiary.Edition.roles/0`).
  """
  @type role :: atom

  @typedoc """
  What an action is taken on: an organisation, a workspace, or a row that carries
  `organisation_id`, and `workspace_id` when it belongs to a workspace.
  """
  @type subject :: struct()

  @typedoc "Why the answer is no: a feature that is off or a subject out of reach, or the role."
  @type reason :: :not_found | :forbidden

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
        registry = build_registry()
        :persistent_term.put(__MODULE__, registry)
        registry

      registry ->
        registry
    end
  end

  defp build_registry do
    edition_roles = Edition.roles()
    edition_actions = Edition.actions()

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

    %{
      names: names,
      by_name: Map.new(actions, &{&1.name, &1}),
      roles:
        Map.new(known_roles, fn role ->
          {role, for(action <- actions, role in action.roles, do: action.name)}
        end)
    }
  end

  ## Levels and reach

  @doc """
  reaches_every_workspace?/1 says whether a membership at `level` reaches every workspace
  of its organisation: the levels of `c:Apiary.Edition.every_workspace_levels/0`, in the
  core's edition all three. The edition says which workspaces another level reaches.
  """
  @spec reaches_every_workspace?(Membership.level() | nil) :: boolean
  def reaches_every_workspace?(level), do: level in Edition.every_workspace_levels()

  @doc """
  instance_admin?/1 says whether the scope's person is an instance admin: an owner of the
  instance's organisation (`c:Apiary.Edition.instance_organisation_id/0`), whose membership
  is not suspended and whose account is in use (not deleted, and active as the edition
  says, `c:Apiary.Edition.active_accounts/2`), as the database has it now. False for a
  scope without a person, and for nil. Whoever asks with a person's scope, whatever
  organisation the scope is in, gets the same answer.
  """
  @spec instance_admin?(Scope.t() | nil) :: boolean
  def instance_admin?(%Scope{user: %User{id: user_id}}) do
    case Edition.instance_organisation_id() do
      nil ->
        false

      organisation_id ->
        from(m in Membership,
          join: u in User,
          as: :account,
          on: u.id == m.user_id,
          where: m.organisation_id == ^organisation_id and m.user_id == ^user_id,
          where: m.level == ^@instance_admin_level and is_nil(m.suspended_at),
          where: is_nil(u.deleted_at)
        )
        |> Edition.active_accounts(:account)
        |> Repo.exists?()
    end
  end

  def instance_admin?(_scope), do: false

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
  membership there, as the scope carries it: the edition's name for its reach; nil for
  anyone with a membership there, and for anyone who does not reach it. A reader reads
  and changes nothing a membership would: a page says so, rather than the level a change
  would take.
  """
  @spec reader(Scope.t() | nil) :: atom | nil
  def reader(scope) do
    if own_level(scope), do: nil, else: edition_reach(scope)
  end

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
  membership of any other organisation, and nil. `instance_admin?/1` asks it of a scope.
  """
  @spec instance_admin_membership?(%Membership{} | nil) :: boolean
  def instance_admin_membership?(%Membership{organisation_id: id, level: @instance_admin_level})
      when is_binary(id),
      do: id == Edition.instance_organisation_id()

  def instance_admin_membership?(_membership), do: false

  @doc "own/0 is the actions anyone with a membership may take on their own membership."
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
  action over people, which asks it as the core asks it of its own.
  """
  @spec acts_on?(role | nil, Membership.level()) :: boolean
  def acts_on?(role, level), do: level in Map.get(@acts_on, role, [])

  ## The answer

  @doc """
  Whether `scope` may take `action` on `subject`, from the scope as it was loaded. For what
  a page shows; a context function that acts asks `authorize/3`.
  """
  @spec can?(Scope.t() | nil, action, subject | nil) :: boolean
  def can?(scope, action, subject), do: check(scope, action, subject) == :ok

  @doc """
  Whether `scope` may take `action` on `subject`, with the person's membership, and what
  the edition put on the scope, read again from the database: `:ok`;
  `{:error, :not_found}` where the action's feature is off, the subject is not in the
  scope's organisation and workspace, or the person does not reach its workspace;
  `{:error, :forbidden}` where the role does not allow it, a membership that is gone
  included, or allows it over other people than the subject's.
  `check(reload(scope), action, subject)`.
  """
  @spec authorize(Scope.t() | nil, action, subject | nil) :: :ok | {:error, reason}
  def authorize(scope, action, subject) do
    action(action)
    scope |> reload() |> check(action, subject)
  end

  @doc """
  The answer of `authorize/3`, with its reason, from the scope as it is, without a read.
  For a context function that asks more than one question in one change: it reads once
  with `reload/2` and asks each question of that scope.
  """
  @spec check(Scope.t() | nil, action, subject | nil) :: :ok | {:error, reason}
  def check(scope, action, subject) do
    %Action{feature: feature} = action(action)

    if not is_nil(feature) and not Features.on?(scope, feature) do
      {:error, :not_found}
    else
      case Edition.check(scope, action, subject) do
        :continue -> check_in_place(scope, action, subject)
        answer -> answer
      end
    end
  end

  defp check_in_place(scope, action, subject) do
    role = role(scope)

    with :ok <- check_place(scope, action, subject) do
      cond do
        own?(scope, action, subject) -> :ok
        not_own?(scope, action, subject) -> {:error, :forbidden}
        role not in action(action).roles -> {:error, :forbidden}
        not over?(role, action, subject) -> {:error, :forbidden}
        true -> :ok
      end
    end
  end

  @doc """
  check_place/3 is the place's part of the answer, steps 3 to 5 of the moduledoc: `:ok`
  when `subject` is in the scope's organisation, and in its workspace when it belongs to
  one, the person reaches that workspace, and neither the place nor the subject is marked
  for deletion (but for the actions of `on_marked/0`); `{:error, :not_found}` otherwise.
  For an edition's `check/3` that answers once the place is known, as the core does.
  """
  @spec check_place(Scope.t() | nil, action, subject | nil) :: :ok | {:error, :not_found}
  def check_place(scope, action, subject) do
    place = place(subject)

    cond do
      not in_place?(place(scope), place) -> {:error, :not_found}
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
  def within?(scope, subject), do: in_place?(place(scope), place(subject))

  defp in_place?({organisation_id, _workspace_id}, {organisation_id, nil})
       when is_binary(organisation_id),
       do: true

  defp in_place?({organisation_id, workspace_id}, {organisation_id, workspace_id})
       when is_binary(organisation_id) and is_binary(workspace_id),
       do: true

  defp in_place?(_scope, _subject), do: false

  @doc """
  role/1 is the role the scope acts in, as it carries it: `:access_key` for a runner's
  key, `:instance` for the instance, the level of the person's membership there, else the
  role the edition gives them (`c:Apiary.Edition.role/1`); nil for anyone else.
  """
  @spec role(Scope.t() | nil) :: role | nil
  def role(%Scope{access_key: %AccessKey{}}), do: :access_key
  def role(%Scope{instance: true, user: nil, membership: nil}), do: :instance
  def role(%Scope{} = scope), do: own_level(scope) || Edition.role(scope)
  def role(_scope), do: nil

  ## Reading again

  @doc """
  The scope with the person's membership as the database has it now, its level as it is or
  no membership when it is gone or suspended, or when their account is no longer in use,
  and what the edition put on it read again (`c:Apiary.Edition.reload/2`). An access key's
  scope is returned as it is: the key was verified on the request that carries it; the
  instance's has only its marks to read again. Any other scope, one without a user or an
  organisation, comes back without a membership, so it may nothing a role would allow.

  With the membership it reads the deletion marks of the organisation and the workspace,
  so an organisation or a workspace marked since the scope was loaded answers not found
  (`check/3`). A scope that carries no membership has the person's membership there
  looked for again, in case they hold one now.

  `lock: :share`, for a caller inside a transaction, takes its locks in the lock order of
  docs/access.md: the organisation `FOR SHARE`, with whatever the edition holds beside it
  (`lock_places/1`); the workspace `FOR KEY SHARE`; the membership `FOR SHARE`; what the
  edition reads again, under its own locks; then the account `FOR SHARE`, reading again
  whether it is still in use. A change of the level, a member's suspension, an account
  going out of use or a marking waits until the transaction ends, so what was asked stays
  true while the change is written, and one that came first is seen.
  """
  @spec reload(Scope.t() | nil, keyword) :: Scope.t() | nil
  def reload(scope, opts \\ [])

  def reload(%Scope{access_key: %AccessKey{}} = scope, _opts), do: scope

  def reload(%Scope{user: %User{id: user_id}, organisation: %Organisation{}} = scope, opts) do
    lock? = opts[:lock] == :share

    # The lock order (docs/access.md, The lock order): the organisation rows first, then
    # the membership, then what the edition holds, then the account.
    if lock?, do: lock_places(scope)

    scope = scope |> reload_membership(lock?) |> Edition.reload(opts)

    # The account is read again under its lock: a deletion, or the edition holding it out
    # of use, that came first, and was waited for, leaves the person no reach, as a
    # membership read after it would.
    scope =
      if lock? and not active_account?(user_id),
        do: %{scope | membership: nil, reach: nil},
        else: scope

    %{scope | features: Features.of(scope.organisation, scope.workspace)}
  end

  def reload(%Scope{instance: true, user: nil, access_key: nil} = scope, _opts) do
    %{
      scope
      | organisation: reload_marks(scope.organisation),
        workspace: reload_marks(scope.workspace)
    }
  end

  def reload(%Scope{} = scope, _opts), do: %{scope | membership: nil, reach: nil}

  def reload(nil, _opts), do: nil

  @doc """
  lock_places/1 holds the scope's organisation `FOR SHARE`, reading it as it is now, then
  the other organisations the edition holds with it (`c:Apiary.Edition.places_to_lock/1`),
  for a caller inside a transaction that must stay allowed while it is written: the first
  rows of the lock order (docs/access.md). A change that must not happen under such a
  write locks these rows for update, and waits for the write, or comes first and is
  seen; a row that only names the organisation takes `FOR KEY SHARE`, which does not
  wait. `reload/2` with `lock: :share` takes them first; a write that locks a row of its
  own before it asks, as the security policy's locks its workspace, calls this first.
  `:ok`.
  """
  @spec lock_places(Scope.t()) :: :ok
  def lock_places(%Scope{organisation: %Organisation{id: id}}) do
    case Repo.one(from o in Organisation, where: o.id == ^id, lock: "FOR SHARE") do
      nil ->
        :ok

      %Organisation{} = now ->
        for other <- Edition.places_to_lock(now), other != id do
          Repo.one(from o in Organisation, where: o.id == ^other, select: o.id, lock: "FOR SHARE")
        end

        :ok
    end
  end

  def lock_places(_scope), do: :ok

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
