defmodule Apiary.Edition do
  @moduledoc """
  The edition: what this build of the apiary is beyond its core, named once in the
  configuration and asked at the few places where an edition may add to the core or narrow
  it.

      config :apiary, :edition,
        module: MyEdition,            # this behaviour
        web: MyEditionWeb,            # ApiaryWeb.Edition
        router: MyEditionWeb.Router,  # mounts the core's routes (ApiaryWeb.Routes)
        static_app: :my_edition       # served before :apiary

  The core is an edition of its own, `Apiary.Edition.Core`, and the default: one
  organisation with one workspace, the instance's features switched at launch, no action,
  table, feature, job or migration beyond the core's. A module that `use`s this one gets
  the core's answer to every callback and overrides the ones it changes; the core's answer
  stays callable as `Apiary.Edition.Core.fun/n`.

  The configuration is read at compile time and every call is made at runtime on the module
  it names, so the core compiles without the edition and never names one of its modules.
  What an edition registers (actions, roles, features, tables, subject kinds) is read once
  at boot by the registry that owns it, which checks it and refuses to boot on a mistake.

  The callbacks, by where they are asked:

  - **Limits and sign-up**: `limits/0`, `sign_up_open?/0`, `organisation_created/2`,
    `workspace_created/3`, `instance_organisation_id/0`, `audit_retention_max_days/0`,
    `attribution?/0`.
  - **Access** (`Apiary.Access`): `actions/0`, `roles/0`, `check/3`, `reach/1`, `role/1`,
    `reload/2`, `places_to_lock/1`, `every_workspace_levels/0`, `reaches_workspace?/3`,
    `reached_workspaces/2`.
  - **In use**, refinements of the queries that must leave out what the edition holds out
    of use: `active_accounts/2`, `active_organisations/2`, `account_refusal/1`.
  - **Places**: `places/1`, the organisations a person reaches.
  - **Invitations**: `accepting/3`, `accepted/4`.
  - **Members**: `membership_changed/5`.
  - **Deletion**: `deletion_refusal/2`, `deletion_changed/4`.
  - **Registries**: `deletion_tables/0` (`Apiary.Deletion.Tables`), `features/0` and
    `features_of/3` (`Apiary.Features`), `subject_kinds/0` (`Apiary.Audit`).
  - **Runtime**: `boot!/0`, `children/0`, `crontab/0`, `migrations_paths/0`,
    `after_migrate/0`.
  """

  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.{Invitation, Membership, Organisation, Workspace}

  @typedoc "A limit on how many of a thing are in use on the instance."
  @type limit :: non_neg_integer | :unlimited

  @typedoc "The level of a membership."
  @type level :: :owner | :admin | :member

  @typedoc "A place a person reaches: an organisation, with what the edition says of it."
  @type place :: map

  @typedoc "What a deletion or purge is about."
  @type deletion_subject :: %Organisation{} | %Workspace{}

  # Limits and sign-up

  @doc "How many organisations and workspaces may be in use on the instance."
  @callback limits() :: %{organisations: limit, workspaces: limit}

  @doc "Whether a sign-up without an invitation may create an organisation, after the first."
  @callback sign_up_open?() :: boolean

  @doc """
  Adds the edition's steps to the transaction that creates an organisation
  (`Apiary.Organisations.build_organisation/2`), after the organisation
  (`:organisation`), its workspace Main (`:workspace`) and its first owner's membership
  (`:membership`, nil for one whose first owner joins later), and before the entry that
  begins its trail. `how` says how it is created: `:first_sign_up`, the instance's first
  sign-up, which creates the instance's own organisation; `{:sign_up, extra}`, a later
  sign-up, with what its form sent beyond the core's fields, string-keyed; or the
  edition's own term, from its own ways of creating one. A step may refuse with
  `{field, message}`, which a sign-up says on that field of its form, and may leave
  `:organisation_entry`, a map of `before`, `after` and `details` the entry carries.
  """
  @callback organisation_created(Ecto.Multi.t(), how :: term) :: Ecto.Multi.t()

  @doc """
  Told, inside the transaction, that `workspace` was created in its organisation
  (`Apiary.Organisations.create_workspace/2`), once its entry is written; `scope` is
  whoever created it. The workspace starts empty, as the core makes it: an edition writes
  here what it keeps of a workspace from the start. An error rolls the creation back.
  """
  @callback workspace_created(Ecto.Repo.t(), %Workspace{}, Scope.t()) :: :ok | {:error, term}

  @doc "The organisation whose owners run the instance, or nil before the first sign-up."
  @callback instance_organisation_id() :: Ecto.UUID.t() | nil

  @doc "The most days `AUDIT_RETENTION_DAYS` may say."
  @callback audit_retention_max_days() :: pos_integer

  @doc ~s(Whether the product's pages and emails carry "Powered by Qory Apiary".)
  @callback attribution?() :: boolean

  # Access

  @doc "The edition's actions, beside the core's (`Apiary.Access.Action`)."
  @callback actions() :: [Apiary.Access.Action.t()]

  @doc "The edition's roles, beside the core's, with what each is."
  @callback roles() :: %{atom => String.t()}

  @doc """
  Asked by `Apiary.Access.check/3` once the action's feature is on and before the place is
  checked: `:continue` leaves the answer to the core, anything else is the answer. An
  answer that must come after the place's, as the core's would, asks
  `Apiary.Access.check_place/3` first. `scope` is nil when no one in particular asks, as
  `Apiary.Access.refused_on?/2` does: `{:error, :forbidden}` then says the subject refuses
  the action whoever asks.
  """
  @callback check(Scope.t(), action :: atom, subject :: term) ::
              :continue | :ok | {:error, :not_found | :forbidden}

  @doc """
  How the scope's person reaches the organisation just put into the scope
  (`Apiary.Organisations.put_reach/2`), with their membership there when they have one in
  use, and no workspace yet: `{:ok, scope}`, with its `reach` and what else the edition
  says of the place, or `:error`, not reached. The core's answer is `{:ok, scope}` with a
  membership and `:error` without one; an edition may reach a person without one, and put
  what it knows of the organisation on the organisation's `edition`
  (`Apiary.Organisations.Organisation`).
  """
  @callback reach(Scope.t()) :: {:ok, Scope.t()} | :error

  @doc """
  The role the edition gives the scope's person through the reach the scope carries, or
  nil: the role of one without a membership there, and whether a reach the scope carries
  still stands (`Apiary.Access.reach/1`).
  """
  @callback role(Scope.t()) :: atom | nil

  @doc """
  Reads again what the edition put on the scope, after `Apiary.Access.reload/2` has read
  the membership and the marks and taken their locks, and before it holds the account;
  with `lock: :share` it holds what it reads `FOR SHARE`.
  """
  @callback reload(Scope.t(), keyword) :: Scope.t()

  @doc """
  The organisations a write that must stay allowed holds `FOR SHARE`, in the lock order:
  the organisation's own id first. Given the organisation as the database has it now,
  held `FOR SHARE` already (`Apiary.Access.lock_places/1`).
  """
  @callback places_to_lock(%Organisation{}) :: [Ecto.UUID.t()]

  @doc "The levels that reach every workspace of their organisation."
  @callback every_workspace_levels() :: [level]

  @doc """
  Whether the scope's membership, at a level that does not reach every workspace
  (`every_workspace_levels/0`), reaches the workspace `workspace_id`, as the scope carries
  it: from what `reach/1`, `reached_workspaces/2` and `reload/2` put on it, without a
  read. `opts` is for later use.
  """
  @callback reaches_workspace?(Scope.t(), workspace_id :: Ecto.UUID.t(), keyword) :: boolean

  @doc """
  Narrows a query over the workspaces (binding `:workspace`), each asked for a membership
  (binding `:membership`) at a level that does not reach every workspace, to those the
  membership reaches. The query selects a map with the workspace under `:workspace`; what
  the edition merges into it beside is what it says of the membership there, which the
  core puts on the scope's `edition` when the membership opens that workspace, and in the
  membership's `edition` under the same key, a list, when it lists memberships. `scope`
  is the scope that opens it, whose reach may read every workspace; nil for a listing.
  """
  @callback reached_workspaces(Ecto.Queryable.t(), Scope.t() | nil) :: Ecto.Query.t()

  # In use

  @doc "Narrows a query to the accounts in use, the account at binding `binding`."
  @callback active_accounts(Ecto.Queryable.t(), binding :: atom) :: Ecto.Query.t()

  @doc "Narrows a query to the organisations in use, the organisation at binding `binding`."
  @callback active_organisations(Ecto.Queryable.t(), binding :: atom) :: Ecto.Query.t()

  @doc "Why an account whose password or log-in link was right may not sign in, or nil."
  @callback account_refusal(%User{}) :: nil | atom

  # Places

  @doc "The organisations a person reaches, for the switcher and their organisations page."
  @callback places(%User{}) :: [place]

  # Invitations

  @doc """
  Asked inside an invitation's acceptance, first, before the core holds its organisation
  `FOR SHARE`, so the edition may hold it more strongly: the level the person joins at, or
  why they may not. `user` is nil for a sign-up with the invitation, whose account is not
  made yet.
  """
  @callback accepting(Ecto.Repo.t(), %Invitation{}, %User{} | nil) ::
              {:ok, level} | {:error, term}

  @doc """
  Asked inside an invitation's acceptance, once the membership is made and before the
  invitation is deleted; `scope` is the person who accepts, in the invitation's
  organisation, whose origin the entries the edition writes carry.
  """
  @callback accepted(Ecto.Repo.t(), Scope.t(), %Invitation{}, %Membership{}) ::
              :ok | {:error, term}

  # Members

  @doc """
  Told, inside the transaction, that a membership changed from `old` to `new`, once its
  entry is written: `:level`, its level changed (`member.change_level`, or a release
  command's `instance_admin.revoke`); `:activated`, its suspension ended
  (`member.activate`). `scope` is whoever changed it. An error rolls the change back.
  """
  @callback membership_changed(
              Ecto.Repo.t(),
              Scope.t(),
              event :: :level | :activated,
              old :: %Membership{},
              new :: %Membership{}
            ) :: :ok | {:error, term}

  # Deletion

  @doc """
  Why a workspace or an organisation may not be deleted (`:delete`) or purged, or nil;
  asked on the row locked for the change, after the core's own refusals.
  """
  @callback deletion_refusal(:delete | :purge, deletion_subject) :: nil | atom

  @doc """
  Told, inside the transaction, that a workspace or an organisation was marked for
  deletion (`:marked`), restored (`:restored`) or purged (`:purged`, in the transaction
  that deletes its row, before it goes). `{:ok, memberships}` names people beyond the
  organisation's own members to tell once the transaction commits
  (`Apiary.Organisations.broadcast_membership_changes/1`); an error rolls the change back.
  An erasure request's marking is told with the purge that follows it.
  """
  @callback deletion_changed(
              Ecto.Repo.t(),
              :marked | :restored | :purged,
              deletion_subject,
              Scope.t()
            ) :: :ok | {:ok, [%Membership{}]} | {:error, term}

  # Registries

  @doc """
  The edition's tables that hold an organisation's rows, in delete order, each with
  whether it holds a workspace's (`Apiary.Deletion.Tables`); they are purged before the
  core's.
  """
  @callback deletion_tables() :: [{String.t(), :organisation | :workspace}]

  @doc "The edition's features, with the features each needs and whether it is built."
  @callback features() :: [{atom, keyword}]

  @doc """
  The features an organisation, or a workspace of it, has, given the features the instance
  has on (`enabled`).
  """
  @callback features_of(%Organisation{}, %Workspace{} | nil, enabled :: [atom]) :: [atom]

  @doc "The edition's schemas an audit entry may be about, with the kind it records."
  @callback subject_kinds() :: %{module => String.t()}

  # Runtime

  @doc "Reads and checks the edition's settings at boot; raises on a wrong one."
  @callback boot!() :: :ok

  @doc "The edition's processes, started after the core's and before the endpoint."
  @callback children() :: [Supervisor.child_spec() | {module, term} | module]

  @doc "The edition's scheduled jobs, beside the core's."
  @callback crontab() :: [{String.t(), module}]

  @doc "Every folder of migrations, the core's first."
  @callback migrations_paths() :: [Path.t()]

  @doc "Runs once the migrations have, at boot and from the migrate command."
  @callback after_migrate() :: :ok

  @callbacks [
    limits: 0,
    sign_up_open?: 0,
    organisation_created: 2,
    workspace_created: 3,
    instance_organisation_id: 0,
    audit_retention_max_days: 0,
    attribution?: 0,
    actions: 0,
    roles: 0,
    check: 3,
    reach: 1,
    role: 1,
    reload: 2,
    places_to_lock: 1,
    every_workspace_levels: 0,
    reaches_workspace?: 3,
    reached_workspaces: 2,
    active_accounts: 2,
    active_organisations: 2,
    account_refusal: 1,
    places: 1,
    accepting: 3,
    accepted: 4,
    membership_changed: 5,
    deletion_refusal: 2,
    deletion_changed: 4,
    deletion_tables: 0,
    features: 0,
    features_of: 3,
    subject_kinds: 0,
    boot!: 0,
    children: 0,
    crontab: 0,
    migrations_paths: 0,
    after_migrate: 0
  ]

  defmacro __using__(_opts) do
    defaults =
      for {name, arity} <- @callbacks do
        args = Macro.generate_arguments(arity, __MODULE__)

        quote do
          @impl Apiary.Edition
          def unquote(name)(unquote_splicing(args)),
            do: Apiary.Edition.Core.unquote(name)(unquote_splicing(args))
        end
      end

    quote do
      @behaviour Apiary.Edition
      unquote_splicing(defaults)
      defoverridable Apiary.Edition
    end
  end

  @config Application.compile_env(:apiary, :edition, [])
  @module Keyword.get(@config, :module, Apiary.Edition.Core)

  # An edition that is an application of its own compiles after the core, which depends
  # on nothing of it: its module is not there to check a call against yet.
  @compile {:no_warn_undefined, @module}

  @doc "The module that answers for the edition."
  @spec module() :: module
  def module, do: @module

  # One function per callback, which asks the configured module.
  for {name, arity} <- @callbacks do
    args = Macro.generate_arguments(arity, __MODULE__)
    @doc false
    def unquote(name)(unquote_splicing(args)), do: @module.unquote(name)(unquote_splicing(args))
  end
end
