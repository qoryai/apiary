defmodule Apiary.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `Apiary.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use in authorization checks,
  or to ensure specific code paths can only be accessed for a given scope.

  Beyond the user, the scope carries the organisation the caller is acting in, the
  caller's membership there and the workspace inside it, once
  `Apiary.Organisations.resolve_scope/4` has loaded the ones a page's path names, or
  `Apiary.Organisations.load_scope/2` the user's. The workspace is the one the path
  names; on an organisation's page, the one the person opened last, or the first they
  reach, or none for one who reaches no workspace yet.

  `reach` says how the person reaches the organisation beyond a membership there, as
  `Apiary.Organisations.resolve_scope/4` found it: nil, or `:membership`, for through
  their membership alone; otherwise the edition's term for the way it gave them in
  (`c:Apiary.Edition.reach/1`), an atom that names it, alone or first in a tuple with what
  the edition read. `edition` is a map the edition owns, empty in the core's: what it
  knows of the person's place beyond the core's fields, such as the workspaces a
  membership reaches, which `Apiary.Access` asks it about. What each allows is
  `Apiary.Access`'s answer.
  At the server contract the scope is an access key's instead (`for_access_key/1`): no
  user, the key's workspace; `key_organisation`, set by `key_in_organisation/2`, is the
  organisation whose audit trail records the key's act, nil for the key's. A job that no person enqueued acts as the instance
  (`for_instance/2`): no user, and `instance: true`, the one mark `Apiary.Access` gives
  the instance's role by; a scope without a person that does not carry it may nothing.
  What a scope may do is `Apiary.Access`'s answer.

  `hidden` is what the person is not shown in the organisation, the features and the parts
  the edition hides from them (`c:Apiary.Edition.hidden/1`, as
  `Apiary.Features.hidden_of/1` keeps it), read when the scope was loaded or read again
  (`Apiary.Access.reload/2`), which `Apiary.Features.visible?/2` answers from; nil, nothing
  hidden, where nothing loaded it, as in an access key's scope and the instance's jobs,
  which then answer as the instance.

  `origin` says from where the caller acts, for the audit trail (`Apiary.Audit`): the
  address and the client of the request, `%{remote_ip:, user_agent:}`, which the web side
  puts on the scope it loads (`put_origin/2`), or the worker of the job,
  `%{worker: "Apiary.Audit.PruneJob"}`. Nil where nobody said.
  """

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.{Preferences, User}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}

  @typedoc "Who is asking, and in which organisation and workspace."
  @type t :: %__MODULE__{}

  @typedoc """
  How a person reaches an organisation beyond a membership there: nil or `:membership`
  for through the membership alone, or the edition's term for the way it gave them in, an
  atom, alone or first in a tuple.
  """
  @type reach :: nil | :membership | atom | tuple

  @typedoc "From where the caller acts: a request's address and client, or a job."
  @type origin ::
          %{optional(:remote_ip) => String.t() | nil, optional(:user_agent) => String.t() | nil}
          | %{worker: String.t()}
          | nil

  defstruct user: nil,
            organisation: nil,
            workspace: nil,
            membership: nil,
            reach: nil,
            access_key: nil,
            instance: false,
            origin: nil,
            hidden: nil,
            edition: %{},
            key_organisation: nil

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  @spec for_user(%User{} | nil) :: t | nil
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc """
  The scope of the gateway at the server contract: the access key it signed with, verified,
  and the key's workspace, or none for the key of a gateway that lives at an organisation
  (`Apiary.Gateways`), whose place is its organisation. The key must carry its workspace
  loaded, as a verified key does (`Apiary.AccessKeys.fetch_for_verification/1`); a caller
  holding one without it preloads it first (`Apiary.Runs.Ingest.ingest/3` and
  `Apiary.Policy.Serving.managed?/1` do).
  """
  @spec for_access_key(AccessKey.t()) :: t
  def for_access_key(%AccessKey{} = access_key) do
    # The key's node says the role it acts in (`Apiary.Access.role/1`): it is loaded here
    # when the key does not carry it, and a key whose node cannot be read acts in none.
    access_key = with_node(access_key)
    of_key(access_key)
  end

  # An adapter's key is the instance's, as its adapter is: no organisation and no
  # workspace, so nothing an edition asks of an organisation is asked of one for it.
  defp of_key(%AccessKey{node: %Node{kind: :adapter}, workspace_id: nil} = access_key) do
    %__MODULE__{access_key: access_key, organisation: nil, workspace: nil}
  end

  # The key of the instance's pool or gateway is the instance's too: no organisation and no
  # workspace. What it may reach is `Apiary.Access`'s answer.
  defp of_key(
         %AccessKey{
           organisation_id: nil,
           workspace_id: nil,
           node: %Node{kind: kind, organisation_id: nil, workspace_id: nil}
         } = access_key
       )
       when kind in [:pool, :gateway] do
    %__MODULE__{access_key: access_key, organisation: nil, workspace: nil}
  end

  defp of_key(%AccessKey{workspace: %Workspace{} = workspace} = access_key) do
    %__MODULE__{access_key: access_key, workspace: workspace}
  end

  defp of_key(%AccessKey{workspace_id: nil} = access_key) do
    %__MODULE__{access_key: access_key, workspace: nil}
  end

  @doc false
  # for_connection/2 is the scope of an adapter's key (`for_access_key/1`) narrowed to the
  # organisation of `connection`, a connection of that adapter, which carries its
  # organisation loaded, and no workspace: what the key asks for that organisation is asked
  # with it (`Apiary.Access`), so the edition answers for the organisation. Nothing else
  # of the scope changes. The caller found the connection the adapter's
  # (`Apiary.Adapters.Connections`).
  @spec for_connection(t, struct()) :: t
  def for_connection(
        %__MODULE__{
          access_key: %AccessKey{
            node_id: adapter_id,
            organisation_id: nil,
            workspace_id: nil,
            node: %Node{kind: :adapter}
          }
        } = scope,
        %Apiary.Adapters.Connection{
          adapter_id: adapter_id,
          organisation: %Organisation{id: organisation_id} = organisation
        }
      )
      when is_binary(adapter_id) and is_binary(organisation_id),
      do: %{scope | organisation: organisation, workspace: nil}

  defp with_node(%AccessKey{node: %Node{}} = access_key), do: access_key

  defp with_node(%AccessKey{node_id: node_id} = access_key) when is_binary(node_id),
    do: %{access_key | node: Apiary.Repo.get(Node, node_id)}

  defp with_node(%AccessKey{} = access_key), do: %{access_key | node: nil}

  @doc """
  key_place/1 is what the place of an access key's scope is asked as, a subject of
  `Apiary.Access`: the key's workspace, or, for a key with none, its organisation, which
  the key carries loaded (`Apiary.AccessKeys.fetch_for_verification/1`), or a struct with
  its id alone; the node of the instance's pool or gateway for its key, which is at the
  instance; nil for any other key with neither, which is at no place of an organisation.
  """
  @spec key_place(t) :: %Workspace{} | %Organisation{} | Node.t() | nil
  def key_place(%__MODULE__{workspace: %Workspace{} = workspace}), do: workspace

  def key_place(%__MODULE__{
        access_key: %AccessKey{
          organisation_id: nil,
          workspace_id: nil,
          node: %Node{kind: kind, organisation_id: nil, workspace_id: nil} = node
        }
      })
      when kind in [:pool, :gateway],
      do: node

  def key_place(%__MODULE__{access_key: %AccessKey{organisation_id: nil}}), do: nil

  def key_place(%__MODULE__{
        access_key: %AccessKey{organisation: %Organisation{} = organisation}
      }),
      do: organisation

  def key_place(%__MODULE__{access_key: %AccessKey{organisation_id: organisation_id}}),
    do: %Organisation{id: organisation_id}

  @doc """
  The scope of the instance acting by itself, in `organisation` and, when given,
  `workspace` of it: the scope of a job that no person enqueued (`Apiary.Job`). No user
  and no membership; `Apiary.Access` answers it by the instance's role.
  """
  @spec for_instance(%Organisation{} | nil, %Workspace{} | nil) :: t
  def for_instance(organisation, workspace \\ nil) do
    %__MODULE__{instance: true, organisation: organisation, workspace: workspace}
  end

  @doc """
  in_organisation/2 is the scope's actor, and its origin, acting in `organisation` with
  nothing else of the scope: for the audit entry of a change the person makes to another
  organisation than the one the scope is in, which is that organisation's.
  """
  @spec in_organisation(t, %Organisation{}) :: t
  def in_organisation(%__MODULE__{} = scope, %Organisation{} = organisation) do
    %{
      scope
      | organisation: organisation,
        workspace: nil,
        membership: nil,
        reach: nil,
        edition: %{},
        # Nothing of the scope's organisation is carried over: an audit entry's scope asks
        # no gate, so nil, nothing hidden, rather than an ask of the edition here.
        hidden: nil
    }
  end

  @doc false
  # key_in_organisation/2 is an access key's scope acting in `organisation`, for the audit
  # entry of an act whose trail is that organisation's rather than the key's: a seal for a
  # run of another organisation (`Apiary.Runs.SecretsRequest`), or an act of the
  # instance's pool on a dispatch of any organisation. The entry is in `organisation`'s
  # trail, by the key; the key's node, when it has no organisation, may be its subject
  # there (`Apiary.Audit`). Nothing else of the scope changes, and no answer of
  # `Apiary.Access` reads it.
  @spec key_in_organisation(t, %Organisation{}) :: t
  def key_in_organisation(
        %__MODULE__{access_key: %AccessKey{}} = scope,
        %Organisation{id: id} = organisation
      )
      when is_binary(id),
      do: %{scope | key_organisation: organisation}

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
