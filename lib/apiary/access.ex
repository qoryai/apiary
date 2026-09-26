defmodule Apiary.Access do
  import Ecto.Query, warn: false

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Features
  alias Apiary.Organisations.{Membership, Organisation, Workspace}
  alias Apiary.Repo

  # Every action, named once: the feature it belongs to (nil: every instance has it) and
  # what it is, for the table in the moduledoc. `test/apiary/access_test.exs` has rows for
  # each, and fails for an action it has none for.
  @actions [
    # The organisation.
    {:"organisation.rename", nil, "rename the organisation"},
    {:"member.invite", nil, "invite a member, and see the pending invitations"},
    {:"member.change_level", nil, "make a member an owner, or an owner a member"},
    {:"member.remove", nil, "remove a member"},
    {:"invitation.revoke", nil, "revoke a pending invitation"},
    # The workspace.
    {:"workspace.rename", nil, "rename the workspace"},
    {:"access_key.create", nil, "create an access key"},
    {:"access_key.rotate", nil, "rotate an access key, and retire its previous secret"},
    {:"access_key.revoke", nil, "revoke an access key"},
    # The record.
    {:"run.read", :observability, "read the runs, their outcomes and the connections"},
    {:"run.read_log", :observability, "read a run's log: its terminal, stdout and stderr"},
    {:"run.close", :observability, "close a run that has not ended"},
    {:"retention.edit", :observability, "set how long the record is kept"},
    # The security policy.
    {:"security_policy.read", :security, "read the security policy"},
    {:"security_policy.edit", :security, "add, change and remove the rules that are not locked"},
    {:"security_policy.lock", :security,
     "lock and unlock a rule, and change or remove a locked one"},
    {:"security_policy.set_mode", :security, "set the mode, observe or enforce"},
    # The server contract.
    {:"run.post_events", :observability, "post a run's events"},
    {:"run_configuration.fetch", :security, "fetch the run configuration"}
  ]

  @names Enum.map(@actions, &elem(&1, 0))
  @features Map.new(@actions, fn {action, feature, _what} -> {action, feature} end)

  @member [
    :"run.read",
    :"access_key.create",
    :"access_key.rotate",
    :"access_key.revoke",
    :"run.read_log",
    :"run.close",
    :"security_policy.read",
    :"security_policy.edit"
  ]

  # Which role may take which action: the role table. A role is a membership's level, or
  # `:access_key` for a runner at the server contract. An action no role lists is nobody's.
  @roles %{
    member: @member,
    owner:
      @member ++
        [
          :"organisation.rename",
          :"member.invite",
          :"member.change_level",
          :"member.remove",
          :"invitation.revoke",
          :"workspace.rename",
          :"retention.edit",
          :"security_policy.lock",
          :"security_policy.set_mode"
        ],
    access_key: [:"run.post_events", :"run_configuration.fetch"]
  }

  @moduledoc """
  Whether someone may do something, answered in one place (decision 0076): may `scope`
  take `action` on `subject`? `can?/3` answers yes or no, `authorize/3` says why not.

  - **`scope`** is who is asking and from where: an `Apiary.Accounts.Scope` of a person,
    with the organisation, the workspace and the membership its path names, or of an access
    key at the server contract (`Apiary.Accounts.Scope.for_access_key/1`).
  - **`action`** is a verb of the engine, one of `actions/0`, each named once, with the
    feature it belongs to, in the table below.
  - **`subject`** is the thing acted on: an organisation, a workspace, or a row of one, such
    as a run, a rule, an access key or a membership, which carries `organisation_id` and
    `workspace_id`.

  The answer is read in this order:

  1. **The feature** the action belongs to (`Apiary.Features.on?/2`). An action of a
     feature that is off is `{:error, :not_found}`: a feature that is off is absent, not
     forbidden (decision 0070).
  2. **Where the subject is.** A subject of another organisation, or of another workspace
     than the scope's, is `{:error, :not_found}`, so the answer does not tell that it
     exists (decision 0073).
  3. **The role** of the one asking, in the role table below. An action the role does not
     allow is `{:error, :forbidden}`, and so is every action for a person without a
     membership where the scope is; the page decides whether it says forbidden or not
     found.

  A context function that changes something asks `authorize/3` before it acts: that is the
  check that counts. It reads the person's membership again from the database, because the
  one a scope carries may be as old as the LiveView that holds it. A page asks `can?/3`,
  with the same action, for what it shows: a button for an action the reader may not take
  is not rendered. `can?/3` answers from the scope as it was loaded, without a read, so a
  page may ask it on every render. A context function that asks several questions in one
  change reads the membership once with `reload/2` and asks each with `check/3`.

  ## Actions

  | Action | What | Feature |
  |---|---|---|
  #{Enum.map_join(@actions, "\n", fn {action, feature, what} -> "| `#{action}` | #{what} | #{if feature, do: "`#{feature}`", else: "every instance"} |" end)}

  ## Roles

  | Role | Who | Actions |
  |---|---|---|
  #{Enum.map_join([member: "a person with a member membership", owner: "a person with an owner membership", access_key: "a runner, with a key of the workspace"], "\n", fn {role, who} -> "| `#{role}` | #{who} | #{Enum.map_join(Map.fetch!(@roles, role), ", ", &"`#{&1}`")} |" end)}

  The managing relationship, the instance admin and the narrowing of features below the
  instance (decision 0070) are not built yet. When they are, they are read here and
  nowhere else.
  """

  @typedoc "An action, one of `actions/0`."
  @type action :: atom

  @typedoc "A role of `roles/0`."
  @type role :: :owner | :member | :access_key

  @typedoc """
  What an action is taken on: an organisation, a workspace, or a row that carries
  `organisation_id` and `workspace_id`.
  """
  @type subject :: struct()

  @typedoc "Why the answer is no: a feature that is off or a subject out of reach, or the role."
  @type reason :: :not_found | :forbidden

  @doc "Every action, in the order of the table."
  @spec actions() :: [action]
  def actions, do: @names

  @doc "The feature `action` belongs to, nil for an action every instance has."
  @spec feature(action) :: Features.feature() | nil
  def feature(action) when action in @names, do: Map.fetch!(@features, action)

  @doc "The roles, with the actions each allows."
  @spec roles() :: %{role => [action]}
  def roles, do: @roles

  @doc """
  Whether `scope` may take `action` on `subject`, from the scope as it was loaded. For what
  a page shows; a context function that acts asks `authorize/3`.
  """
  @spec can?(Scope.t() | nil, action, subject | nil) :: boolean
  def can?(scope, action, subject) when action in @names, do: check(scope, action, subject) == :ok

  @doc """
  Whether `scope` may take `action` on `subject`, with the person's membership read again
  from the database: `:ok`; `{:error, :not_found}` where the action's feature is off or the
  subject is not in the scope's organisation and workspace; `{:error, :forbidden}` where
  the role does not allow it, a membership that is gone included. `check(reload(scope),
  action, subject)`.
  """
  @spec authorize(Scope.t() | nil, action, subject | nil) :: :ok | {:error, reason}
  def authorize(scope, action, subject) when action in @names,
    do: scope |> reload() |> check(action, subject)

  @doc """
  The answer of `authorize/3`, with its reason, from the scope as it is, without a read.
  For a context function that asks more than one question in one change: it reads the
  membership once with `reload/2` and asks each question of that scope.
  """
  @spec check(Scope.t() | nil, action, subject | nil) :: :ok | {:error, reason}
  def check(scope, action, subject) when action in @names do
    feature = Map.fetch!(@features, action)

    cond do
      not is_nil(feature) and not Features.on?(scope, feature) -> {:error, :not_found}
      not within?(place(scope), place(subject)) -> {:error, :not_found}
      action in Map.get(@roles, role(scope), []) -> :ok
      true -> {:error, :forbidden}
    end
  end

  @doc """
  The scope with the person's membership as the database has it now: its level as it is,
  or no membership when it is gone. One read. An access key's scope is returned as it is:
  the key was verified on the request that carries it. Any other scope, one without a
  user, an organisation, a workspace or a membership, comes back without a membership, so
  it may nothing a role would allow.

  `lock: :share` reads the membership `FOR SHARE`, for a caller inside a transaction: a
  change of the level waits until the transaction ends, so what was asked stays true
  while the change is written.
  """
  @spec reload(Scope.t() | nil, keyword) :: Scope.t() | nil
  def reload(scope, opts \\ [])

  def reload(%Scope{access_key: %AccessKey{}} = scope, _opts), do: scope

  def reload(
        %Scope{
          user: %User{id: user_id},
          organisation: %Organisation{id: organisation_id},
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{id: membership_id} = membership
        } = scope,
        opts
      ) do
    query =
      from m in Membership,
        where:
          m.id == ^membership_id and m.user_id == ^user_id and
            m.organisation_id == ^organisation_id and m.workspace_id == ^workspace_id,
        select: m.level

    query = if opts[:lock] == :share, do: lock(query, "FOR SHARE"), else: query
    level = Repo.one(query)

    %{scope | membership: level && %{membership | level: level}}
  end

  def reload(%Scope{} = scope, _opts), do: %{scope | membership: nil}
  def reload(nil, _opts), do: nil

  # The role as the scope carries it. A membership counts only where it is: in the scope's
  # organisation and workspace.
  defp role(%Scope{access_key: %AccessKey{}}), do: :access_key

  defp role(%Scope{
         organisation: %Organisation{id: organisation_id},
         workspace: %Workspace{id: workspace_id},
         membership: %Membership{
           organisation_id: organisation_id,
           workspace_id: workspace_id,
           level: level
         }
       }),
       do: level

  defp role(_scope), do: nil

  # Where a scope or a subject is: `{organisation_id, workspace_id}`, the workspace nil for
  # what the organisation owns.
  defp place(%Scope{access_key: %AccessKey{} = key}),
    do: {key.organisation_id, key.workspace_id}

  defp place(%Scope{organisation: %Organisation{id: organisation_id}, workspace: workspace}),
    do: {organisation_id, workspace && workspace.id}

  defp place(%Organisation{id: id}), do: {id, nil}
  defp place(%Workspace{id: id, organisation_id: organisation_id}), do: {organisation_id, id}

  defp place(%{organisation_id: organisation_id, workspace_id: workspace_id}),
    do: {organisation_id, workspace_id}

  defp place(%{organisation_id: organisation_id}), do: {organisation_id, nil}
  defp place(_nowhere), do: nil

  # A subject is within the scope in the scope's organisation, and, when it belongs to a
  # workspace, in the scope's workspace.
  defp within?({organisation_id, _workspace_id}, {organisation_id, nil})
       when is_binary(organisation_id),
       do: true

  defp within?({organisation_id, workspace_id}, {organisation_id, workspace_id})
       when is_binary(organisation_id) and is_binary(workspace_id),
       do: true

  defp within?(_scope, _subject), do: false
end
