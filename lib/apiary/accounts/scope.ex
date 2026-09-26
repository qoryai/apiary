defmodule Apiary.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `Apiary.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use in authorization checks,
  or to ensure specific code paths can only be accessed for a given scope.

  Beyond the user, the scope carries the organisation the caller is acting in,
  the workspace inside it and the caller's membership there, once
  `Apiary.Organisations.resolve_scope/3` has loaded the ones a page's path names,
  or `Apiary.Organisations.load_scope/2` the user's own. At the server contract the scope
  is an access key's instead (`for_access_key/1`): no user, the key's workspace. A job
  that no person enqueued acts as the instance (`for_instance/2`): no user, and
  `instance: true`, the one mark `Apiary.Access` gives the instance's role by; a scope
  without a person that does not carry it may nothing. What a scope may do is
  `Apiary.Access`'s answer.

  `origin` says from where the caller acts, for the audit trail (`Apiary.Audit`): the
  address and the client of the request, `%{remote_ip:, user_agent:}`, which the web side
  puts on the scope it loads (`put_origin/2`), or the worker of the job,
  `%{worker: "Apiary.Audit.PruneJob"}`. Nil where nobody said.
  """

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.{Preferences, User}
  alias Apiary.Organisations.{Organisation, Workspace}

  @typedoc "Who is asking, and in which organisation and workspace."
  @type t :: %__MODULE__{}

  @typedoc "From where the caller acts: a request's address and client, or a job."
  @type origin ::
          %{optional(:remote_ip) => String.t() | nil, optional(:user_agent) => String.t() | nil}
          | %{worker: String.t()}
          | nil

  defstruct user: nil,
            organisation: nil,
            workspace: nil,
            membership: nil,
            access_key: nil,
            instance: false,
            origin: nil

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc """
  The scope of a runner at the server contract: the access key it signed with, verified,
  and the key's workspace. The key must carry its workspace loaded, as a verified key does
  (`Apiary.AccessKeys.fetch_for_verification/1`); a caller holding one without it preloads
  it first (`Apiary.Runs.Ingest.ingest/3` and `Apiary.Policy.Serving.managed?/1` do). The
  key's secrets stay out of it.
  """
  @spec for_access_key(AccessKey.t()) :: t
  def for_access_key(%AccessKey{workspace: %Workspace{} = workspace} = access_key) do
    %__MODULE__{access_key: AccessKey.without_secrets(access_key), workspace: workspace}
  end

  @doc """
  The scope of the instance acting on its own, in `organisation` and, when given,
  `workspace` of it: the scope of a job that no person enqueued (`Apiary.Job`). No user
  and no membership; `Apiary.Access` answers it by the instance's role.
  """
  @spec for_instance(%Organisation{} | nil, %Workspace{} | nil) :: t
  def for_instance(organisation, workspace \\ nil) do
    %__MODULE__{instance: true, organisation: organisation, workspace: workspace}
  end

  @doc """
  The scope with `origin`, from where its caller acts; nil stays nil.
  """
  @spec put_origin(t | nil, origin) :: t | nil
  def put_origin(nil, _origin), do: nil
  def put_origin(%__MODULE__{} = scope, origin), do: %{scope | origin: origin}

  @doc """
  The time zone the scope's times are shown in: its user's preference, an IANA name
  (`Apiary.Accounts.Preferences`), or UTC without a user. A stored zone the zone database
  no longer knows (a later release of it dropped the name) reads UTC too, so it always
  converts. Every time is stored in UTC.

      iex> Apiary.Accounts.Scope.time_zone(nil)
      "Etc/UTC"
  """
  @spec time_zone(t | nil) :: String.t()
  def time_zone(%__MODULE__{user: %User{time_zone: zone}}) do
    if Preferences.time_zone?(zone), do: zone, else: Preferences.default_time_zone()
  end

  def time_zone(_scope), do: Preferences.default_time_zone()

  @doc """
  The language the scope's pages are written in: its user's preference, or English
  without a user, as stored. `ApiaryWeb.Lingo.locale_for/1` puts it together with the
  workspace's domain, and reads English for a language that has no catalogue.

      iex> Apiary.Accounts.Scope.language(nil)
      "en"
  """
  @spec language(t | nil) :: String.t()
  def language(%__MODULE__{user: %User{language: language}}) when is_binary(language),
    do: language

  def language(_scope), do: Preferences.default_language()
end
