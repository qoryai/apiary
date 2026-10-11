defmodule Apiary.Edition do
  @moduledoc """
  The edition: what this build of Qory Apiary is beyond its core, named once in the
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
    `workspace_created/3`, `instance_organisation_id/0`, `first_sign_up_line/0`,
    `audit_retention_max_days/0`, `attribution?/0`.
  - **Policy** (`Apiary.Policy`): `above_workspace/1`, what holds above a workspace's
    security policy.
  - **Access** (`Apiary.Access`): `actions/0`, `roles/0`, `check/3`, `reach/1`, `role/1`,
    `reload/2`, `places_to_lock/1`, `lock_rows/1`, `every_workspace_levels/0`,
    `reaches_workspace?/3`, `reached_workspaces/2`.
  - **In use**, refinements of the queries that must leave out what the edition holds out
    of use: `active_accounts/2`, `active_organisations/2`, `account_refusal/1`.
  - **Places**: `places/1`, the organisations a person reaches.
  - **Invitations**: `accepting/3`, `accepted/4`.
  - **Members**: `membership_changed/5`, `level_refusal/4`.
  - **Deletion**: `deletion_refusal/2`, `deletion_changed/4`.
  - **Audit trail** (`Apiary.Audit`): `audit_details/3`, what the edition adds to an
    entry's details as it is written.
  - **Registries**: `deletion_tables/0` (`Apiary.Deletion.Tables`), `features/0` and
    `features_of/3` (`Apiary.Features`), `subject_kinds/0` (`Apiary.Audit`).
  - **Runtime**: `boot!/0`, `children/0`, `crontab/0`, `migrations_paths/0`,
    `after_migrate/0`.

  **The test seam.** A test may have a stub answer some callbacks in its own processes
  (`put_test_stub/1`), as an edition that narrows the core would, while the configured
  edition answers every other call.
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

  @typedoc """
  What a change asks the edition to lock its rows for (`c:lock_rows/1`): `{:places, scope}`,
  a write that must stay allowed for the scope's person; `{:people, scope, organisation}`, a
  change of the organisation's people, `scope` nil for a sign-up;
  `{:account, user_id, organisation_ids}`, the deletion of an account, with the
  organisations the core holds for it.
  """
  @type lock_about ::
          {:places, Scope.t()}
          | {:people, Scope.t() | nil, %Organisation{}}
          | {:account, Ecto.UUID.t(), [Ecto.UUID.t()]}

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

  @doc """
  The set-up page's line on what the instance's first sign-up creates
  (`ApiaryWeb.SetupLive`), translated when it is asked.
  """
  @callback first_sign_up_line() :: String.t()

  @doc """
  What holds above `workspace`'s security policy, from the level the edition keeps above
  its workspaces (`Apiary.Policy.Above`: host rules, a required mode, whether the
  workspace may allow hosts of its own, and variables), or nil: the core has none. Asked
  by the reads and writes of `Apiary.Policy` and `Apiary.Variables` that need it, never
  once per holder or row, and resolved, rendered and shown by the core, which says the
  level's `name` and nothing of its own about it. A level with variables and no
  policy is answered with `policy: false`, which the security policy takes as nil and
  `Apiary.Variables` still reads.
  """
  @callback above_workspace(%Workspace{}) :: Apiary.Policy.Above.t() | nil

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
  with `lock: :share` its own rows are held already (`c:lock_rows/1`, `{:places, scope}`),
  and it locks nothing.
  """
  @callback reload(Scope.t(), keyword) :: Scope.t()

  @doc """
  The organisations a write that must stay allowed holds `FOR SHARE`, in the lock order:
  the organisation's own id first. Given the organisation as the database has it now:
  `Apiary.Access.lock_places/1` asks it first without a lock, takes what it names in one
  statement, then asks it again of the organisation held `FOR SHARE` and takes after
  what it names that is not held yet. Several organisations are locked in the order of
  `Apiary.Organisations.lock_order/1`, which asks this callback, without a lock: those
  it names another organisation for first, then the rest, each in the order of their
  ids.

  The organisations it names besides the organisation's own hold none of their own: for
  each of them, this callback names that organisation alone. This is what makes
  `Apiary.Organisations.lock_order/1` one order that every change agrees on. It may read,
  but it locks nothing: the edition's locks belong to `c:lock_rows/1`.
  """
  @callback places_to_lock(%Organisation{}) :: [Ecto.UUID.t()]

  @doc """
  Locks the edition's own rows for a change, inside its transaction: an edition takes all
  its own rows for a change here, at one point before the change's first write, in its
  own fixed order and in the strongest mode the change needs, and none later in that
  change; otherwise two changes can wait on each other. The rule is the change's, not a
  callback's: what the edition reads or writes of its own later in the change
  (`c:reload/2`, `c:level_refusal/4`, `c:membership_changed/5`, `c:accepted/4`) it holds
  from here. The core's answer is `:ok`, and it locks nothing.

  The lock order, by class of row (docs/access.md):

  1. the organisation rows, then this callback's rows; where the edition locks rows of
     more than one organisation, in any mode, it takes them through
     `Apiary.Organisations.lock_organisations/2`, in the order of
     `Apiary.Organisations.lock_order/1`;
  2. then the workspaces, the owners' memberships and the other memberships;
  3. then the account and the invitation.

  The edition never locks a membership or any other row of the core's here. Each change
  has one point, where it is asked once:

  - `{:places, scope}` at the end of `Apiary.Access.lock_places/1`, in a write that must
    stay allowed, once the scope's organisation rows are held and before the membership
    `Apiary.Access.reload/2` holds. The rows it takes for a scope must not depend on the
    scope's workspace: a write may ask it more than once in one change, with the same
    organisation, as the security policy's writes do, before and after their workspaces'
    rows and writes and once for each workspace of a request;
  - `{:people, scope, organisation}` in every change of the organisation's people, once
    its organisation rows are held and before the owners' memberships
    (`Apiary.Organisations.lock_people/1`, which asks no `{:places, scope}` before it): a
    change of level, a removal or leaving, a suspension, an activation, and the release
    commands that grant and revoke an instance admin; and once an invitation's
    organisation is held, in its acceptance and in a sign-up with one, `scope` nil for the
    sign-up. Here the edition takes, all at once in its fixed order, every row it would
    take at `{:places, scope}` for that scope, in at least the same mode, and its rows of
    the organisation's people;
  - `{:account, user_id, organisation_ids}` in an account's deletion, once every
    organisation the account is a member of is held, those it owns `FOR SHARE` and the
    rest `FOR KEY SHARE`, and before their owners and the person's memberships:
    `organisation_ids` are the organisations the core holds, in the order it took them,
    and the edition takes rows of those organisations only, at this one point. An
    organisation the account joins after they were read is not among them, and the
    edition takes none of its rows.

  A repeat of `{:places, scope}` later in the same change, after its point, must take no
  new row and no stronger mode: the edition answers it with rows it holds already, in the
  mode it holds them.
  """
  @callback lock_rows(lock_about) :: :ok

  @doc "The levels that reach every workspace of their organisation."
  @callback every_workspace_levels() :: [level]

  @doc """
  Whether the scope's membership, at a level that does not reach every workspace
  (`every_workspace_levels/0`), reaches the workspace `workspace_id`, as the scope carries
  it: from what `reach/1`, `reached_workspaces/2` and `reload/2` put on it, without a
  read. `opts` is ignored.
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
  The edition's rows are held already (`c:lock_rows/1`), and it locks nothing here.
  """
  @callback membership_changed(
              Ecto.Repo.t(),
              Scope.t(),
              event :: :level | :activated,
              old :: %Membership{},
              new :: %Membership{}
            ) :: :ok | {:error, term}

  @doc """
  Why `level` may not be given in `organisation` by `scope`, or nil when it may: the
  edition's reason, an atom, which the pages say in the edition's words
  (`c:ApiaryWeb.Edition.level_refusal_sentence/2`). `scope` is who gives it: the person
  who changes a level or invites, the person who accepts an invitation, nil for a sign-up
  with one, whose account is not made yet, and the instance for a release command. Every
  way the core gives a level asks it (`Apiary.Access.level_refusal/4`), and a page offers
  no level it refuses (`Apiary.Access.grantable_levels/1`). The core's answer is nil.

  With `lock: :share` it is asked inside the transaction of the change, before the
  membership is written: in a change of level, an invitation's acceptance, a sign-up with
  one and the release commands, once the edition's rows are held already
  (`c:lock_rows/1`). It reads, and locks nothing here. An invitation, which writes no
  membership, asks it once the allowance's row is held, with none of the edition's rows
  held. Without `lock:` a page asks what to offer, and nothing is held.
  """
  @callback level_refusal(Scope.t() | nil, %Organisation{}, level, keyword) :: nil | atom

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

  # Audit trail

  @doc """
  An entry's `details` as the edition leaves them, asked once for every entry of the audit
  trail as `Apiary.Audit.record/6` writes it: such as how the actor reached the
  organisation, which the entry keeps after the way is gone. `scope` is the actor's, a
  person's, an access key's or the instance's; `organisation_id` is the entry's
  organisation, which an access key's scope does not load; `details` is the entry's, as
  JSON has them (string keys), an empty map for an entry without any. The core's answer is
  `details`, unchanged.

  The edition adds keys of its own and changes or removes none of the core's: a key the
  entry has, and `allowance_id`, which the core counts entries by whatever their action,
  raise `ArgumentError`. A key that ends in `_id` and holds an organisation's id is named by
  `Apiary.Audit.names/2`, as the other side of a change is. What it adds is a JSON map
  with no secret and no person's name or email address, as the rest of the entry.

  It is asked inside the change's transaction, before the entry is inserted, so it must be
  cheap: an answer from the scope (its `reach` and `edition`) needs no read, and a read it
  must make takes no lock, neither `FOR UPDATE` nor `FOR SHARE`, beyond those the change
  holds already. Anything it raises, or an answer that can't be stored as JSON, rolls the
  change back.
  """
  @callback audit_details(Scope.t(), organisation_id :: Ecto.UUID.t(), details :: map) :: map

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
    first_sign_up_line: 0,
    above_workspace: 1,
    audit_retention_max_days: 0,
    attribution?: 0,
    actions: 0,
    roles: 0,
    check: 3,
    reach: 1,
    role: 1,
    reload: 2,
    places_to_lock: 1,
    lock_rows: 1,
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
    level_refusal: 4,
    deletion_refusal: 2,
    deletion_changed: 4,
    audit_details: 3,
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

  # One function per callback, which asks the configured module, or a test's stub that
  # answers it (`put_test_stub/1`).
  for {name, arity} <- @callbacks do
    args = Macro.generate_arguments(arity, __MODULE__)
    @doc false
    def unquote(name)(unquote_splicing(args)),
      do: answering(unquote(name), unquote(arity)).unquote(name)(unquote_splicing(args))
  end

  ## The test seam

  @test_stub {__MODULE__, :test_stub}
  @stubbed {__MODULE__, :stubbed}

  @doc """
  put_test_stub/1 has `stub` answer, for a test, each callback it exports, of this
  behaviour and of `ApiaryWeb.Edition`, in the calling
  process and the processes that have it among their `$callers` (a `Task`, a LiveView
  under test), and in no other; the configured edition (`module/0`) answers the rest,
  and a stub that narrows the edition's answer asks it there. Tests that set different
  stubs run at once (`async: true`). Until a test sets one, no call looks for a stub.
  `:ok`.
  """
  @spec put_test_stub(module) :: :ok
  def put_test_stub(stub) when is_atom(stub) do
    Code.ensure_loaded!(stub)
    unless :persistent_term.get(@stubbed, false), do: :persistent_term.put(@stubbed, true)
    Process.put(@test_stub, stub)
    :ok
  end

  defp answering(name, arity), do: answering(name, arity, @module)

  @doc false
  # The module that answers `name/arity`: the test's stub that exports it, else `module`.
  # `ApiaryWeb.Edition` asks it too, so one stub answers callbacks of both.
  @spec answering(atom, arity, module) :: module
  def answering(name, arity, module) do
    with true <- :persistent_term.get(@stubbed, false),
         stub when is_atom(stub) and not is_nil(stub) <- test_stub(),
         true <- function_exported?(stub, name, arity) do
      stub
    else
      _no_stub -> module
    end
  end

  # The stub a test set in this process, or in the nearest of its callers that set one.
  defp test_stub do
    Enum.find_value([self() | Process.get(:"$callers", [])], fn
      pid when pid == self() -> Process.get(@test_stub)
      pid -> caller_stub(pid)
    end)
  end

  defp caller_stub(pid) when is_pid(pid) do
    case Process.info(pid, {:dictionary, @test_stub}) do
      {{:dictionary, @test_stub}, stub} when is_atom(stub) and stub != :undefined -> stub
      _unset_or_gone -> nil
    end
  end

  defp caller_stub(_name), do: nil
end
