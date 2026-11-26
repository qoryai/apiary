defmodule Apiary.Connections do
  @moduledoc """
  Connections holds what an organisation sets up: the runtimes, integrations and
  services the contract calls connections, and the pages call integrations
  (`Apiary.Connections.Connection`), the workspaces each applies to, and the
  organisation's service definitions (`Apiary.Connections.ServiceDefinition`).

  ## The kinds

    * A **runtime** connection names a runtime of the catalogue
      (`Apiary.Kinds.Runtimes`), such as `claude`.
    * An **integration** connection is added from a release the organisation found
      (`Apiary.Integrations`), ready and intact, whose source the instance's settings
      still accept, else `integration_source_refused`: it takes the description's name
      and the release's source, its forge's kind, its version and its description digest.
      Its plain `settings` are checked against the description
      (`Apiary.Integrations.Description.check_settings/2`): a secret, or a secret's
      `<name>_file`, is never a setting. Its `argument` must match its credential role's
      pattern. Moving it to another release keeps its source and its name, else
      `integration_source_mismatch`.
    * A **service** connection names its definition, a built-in one by key
      (`Apiary.Kinds.Services`) or one of the organisation's, and nothing else: the definition is
      the one source of its hosts, paths, auth and declared secrets.
    * A **model provider** is an integration added from a description of the catalogue
      (`Apiary.Kinds.Providers`), with no release. It links one secret, whose values are
      its keys (`Apiary.Secrets.create_provider_keys/3`), one of them its default key: a
      secret of the organisation, or, for a provider added for one workspace alone
      (`create_provider/3` with `:workspace`), a secret of that workspace. It keeps no list of models: its models are its description's
      (`provider_models/1`), the first its default model (`default_model/1`). The
      functions under "Model providers" below read and change it; `list_connections/1`,
      `get_connection/2` and `list_for_rendering/1` leave providers out.

  No connection holds a secret, and the audit trail never carries a value.

  ## Model providers

  A provider and everything of it need the features `factory` and `secrets`, shown to the
  scope (`Apiary.Features.visible?/2`): with either off, every function of a provider
  answers `{:error, :not_found}`. The address a person enters for an endpoint from a
  setting, an address setting (`Apiary.Kinds.Provider.address_settings/1`), passes
  `Apiary.Kinds.Endpoint.check/1` at every save, or the save is refused with that rule's
  sentence on `settings`. Providers are left out of the overlap check: a choice of model
  decides which provider a run uses, never the host. Every provider created here is of the
  organisation's chain (`chain` `organisation`). Every function refuses a change to a
  provider of any other chain, `{:error, :forbidden}`, and `list_providers/2` and
  `get_provider/3` given any other chain are `{:error, :not_found}`.

  A provider's keys are entered and changed only through the functions here
  (`add_provider_key/3` to `delete_provider_key/3`): `Apiary.Secrets` leaves them out of
  the organisation's secrets and of the workspace's.

  A change to a provider takes the organisation's integrations lock, then the provider's
  row `FOR UPDATE`, then, to change its keys, for the organisation's secret the
  organisation's lock for its secrets, and its keys' secret row `FOR UPDATE`, or that row
  `FOR SHARE` to choose a default key. Deleting it deletes its keys' secret with it
  (`Apiary.Secrets.delete_provider_keys/3`). Adding a provider for one workspace takes
  that workspace's row `FOR NO KEY UPDATE` after the integrations lock, before it writes
  the workspace's secret (docs/access.md).

  A provider whose keys are a workspace's secret reaches that workspace alone: a change of
  its `applies_to` (`update_provider/3`) and another workspace added to its list
  (`put_workspace/3`) are refused on `applies_to`, with the sentence that says to add it
  again. The workspace's purge deletes it, with the model choices that name it
  (`purge_workspace_providers/2`).

  ## Where a connection applies

  `applies_to` is `all`, every workspace of the organisation, those made later included,
  or `selected`, the workspaces it lists (`Apiary.Connections.ConnectionWorkspace`), each
  of the organisation; a workspace's purge takes it from every list, so a `selected`
  connection may list none. The reach is set when the connection is added, and a form
  that adds one sets it by `reach_at_add/3`. It is never changed after:
  `update_connection/3` and `update_provider/3` refuse a change of `applies_to`, and
  `put_workspace/3` and `remove_workspace/3` a change of the list, `{:error, :reach_fixed}`.
  Only the workspace's purge changes a list. A save that would make two connections collide in a
  workspace where both apply, the same runtime, the same integration, or a host in
  common, is refused, `{:error, {:overlap, public_ids}}` (`Apiary.Connections.Overlap`).

  ## The security policy

  The hosts that an integration other than a model provider requires (`egress_hosts/1`)
  are allowed in the policy of every workspace it reaches (`Apiary.Policy`). A write to
  such an integration locks every workspace of the organisation before it writes
  (docs/access.md, The lock order), then renders again the policy of each workspace it
  reached before the write or reaches after it, in the write's transaction
  (`Apiary.Policy.rerender_in/3`). A render that fails rolls the write back, with
  `{:error, %Apiary.Policy.Error{}}`.

  ## Integrity

  Every connection, release and custom definition carries an integrity code
  (`Apiary.Kinds.Coded`). A listing marks each connection `intact`;
  `list_for_rendering/1` refuses the connections that apply to a workspace when one of
  them, its release or its definition fails its code, with an error in the log.

  ## Who, and the trail

  Reading is `connection.read`, every member. A change is asked under the action for what
  it writes (`write_action/1`), owners and admins in each case, all asked of the
  organisation: `provider.write` for a model provider and its keys,
  `runtime.write` for a runtime, and `connection.write` for an integration, a service, a
  release of an integration and a service definition. A change leaves one entry in the
  organisation's audit trail, in its transaction, of the action it was asked under,
  `details.change` saying what. A write locks the scope's organisation `FOR SHARE` and
  reads the membership again under its locks (`Apiary.Access.lock_places/1`,
  `Apiary.Access.reload/2`, docs/access.md), then takes the organisation's integrations
  lock, a transaction-level advisory lock on `apiary:integrations:` and the organisation's
  id: two writes to one organisation take turns, so the overlap check sees every write
  before it.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Changeset
  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{
    Access,
    Audit,
    Edition,
    Features,
    Integrations,
    LogMetadata,
    ModelChoices,
    ModelKeys,
    PublicId,
    Repo,
    Secrets
  }

  alias Apiary.Accounts.Scope
  alias Apiary.ModelKeys.{Group, Identity, Login}

  alias Apiary.Connections.{
    Connection,
    ConnectionWorkspace,
    Overlap,
    ServiceDefinition,
    SettingsFit
  }

  alias Apiary.Integrations.{Description, Release}
  alias Apiary.Kinds.{CanonicalJSON, Coded, Endpoint, Provider, Providers, Runtimes, Services}
  alias Apiary.Secrets.{Secret, Value}
  alias Apiary.Kinds.ServiceDefinition, as: Definition
  alias Apiary.Policy
  alias Apiary.Policy.Grammar
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.Run

  @typedoc """
  Why a change is refused: the reasons of `Apiary.Access`, a changeset, or a code with
  what it is about: `{:overlap, public_ids}`, `{:in_use, public_ids}`, `:runtime_unknown`,
  `:service_unknown`, `:release_not_ready`, `:integration_source_refused`,
  `:workspace_not_found`, `:reach_fixed` for a change of the workspaces a connection
  reaches after its add, `{:integration_source_mismatch, why}`, and the description's
  `{:integration_settings_not_allowed, names}`, `{:integration_settings_invalid, details}`,
  `{:integration_settings_too_large, max}` and `{:integration_argument_not_allowed, roles}`;
  for a definition, `{:definition_invalid, problems}`; for a provider,
  `:provider_unknown`, `:provider_changed`, `{:model_in_use, places}`,
  `{:provider_in_use, %{places: places, runs: run_public_ids}}` and `Apiary.Secrets`'
  refusals of its keys; for an integration, an `Apiary.Policy.Error` when a render of
  the security policy fails.
  """
  @type refusal ::
          Access.reason() | Ecto.Changeset.t() | Apiary.Policy.Error.t() | atom | {atom, term}

  ## Reading

  @doc """
  list_connections/1 is the scope's organisation's connections but its model providers,
  by kind and name, each with its workspaces, its release and its definition, and `intact`
  set: `{:ok, connections}` for a reader who may `connection.read`.
  """
  @spec list_connections(Scope.t()) :: {:ok, [Connection.t()]} | {:error, Access.reason()}
  def list_connections(%Scope{} = scope) do
    with {:ok, organisation} <- may_read(scope) do
      {:ok, organisation.id |> load_all() |> Enum.map(&%{&1 | intact: intact?(&1)})}
    end
  end

  @doc """
  get_connection/2 is the scope's organisation's connection with the public id
  `public_id`, loaded as `list_connections/1` loads it: `{:ok, connection}`, or
  `{:error, reason}`, `:not_found` for one the organisation does not have, or a provider.
  """
  @spec get_connection(Scope.t(), term) :: {:ok, Connection.t()} | {:error, Access.reason()}
  def get_connection(%Scope{} = scope, public_id) do
    with {:ok, organisation} <- may_read(scope),
         true <- PublicId.valid?("con", public_id),
         %Connection{} = connection <-
           Repo.one(
             from c in connections(organisation.id),
               where: c.public_id == ^public_id and is_nil(c.provider_kind)
           ) do
      connection = Repo.preload(connection, preloads())
      {:ok, %{connection | intact: intact?(connection)}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  list_service_definitions/1 is the service definitions of the scope's organisation, by key:
  `{:ok, definitions}` for a reader who may `connection.read`.
  """
  @spec list_service_definitions(Scope.t()) ::
          {:ok, [ServiceDefinition.t()]} | {:error, Access.reason()}
  def list_service_definitions(%Scope{} = scope) do
    with {:ok, organisation} <- may_read(scope) do
      {:ok, Repo.all(from d in definitions(organisation.id), order_by: [asc: d.key])}
    end
  end

  @doc """
  get_service_definition/2 is the service definition of the scope's organisation with the
  public id `public_id`: `{:ok, definition}`, or `{:error, reason}`.
  """
  @spec get_service_definition(Scope.t(), term) ::
          {:ok, ServiceDefinition.t()} | {:error, Access.reason()}
  def get_service_definition(%Scope{} = scope, public_id) do
    with {:ok, organisation} <- may_read(scope),
         true <- PublicId.valid?("svc", public_id),
         %ServiceDefinition{} = definition <-
           Repo.one(from d in definitions(organisation.id), where: d.public_id == ^public_id) do
      {:ok, definition}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  definition/1 is the service definition a service connection names, decoded:
  `{:ok, definition}`, or `:error` for a built-in key the release no longer ships.
  """
  @spec definition(Connection.t()) :: {:ok, map} | :error
  def definition(%Connection{kind: "service", service_builtin: key}) when is_binary(key),
    do: Services.fetch(key)

  def definition(%Connection{kind: "service", service_definition: %ServiceDefinition{} = d}),
    do: {:ok, ServiceDefinition.decoded(d)}

  def definition(%Connection{kind: "service"} = connection),
    do: connection |> Repo.preload(:service_definition) |> definition()

  @doc """
  description/1 is the description an integration connection was added from, read:
  `{:ok, description}`, or `{:error, :not_ready}`.
  """
  @spec description(Connection.t()) :: {:ok, Description.t()} | {:error, :not_ready}
  def description(%Connection{kind: "integration", provider_kind: kind} = connection)
      when is_binary(kind) do
    case provider(connection) do
      {:ok, provider} -> {:ok, provider.description}
      {:error, _reason} -> {:error, :not_ready}
    end
  end

  def description(%Connection{kind: "integration", release: %Release{} = release}),
    do: Integrations.description(release)

  def description(%Connection{kind: "integration", release: %Ecto.Association.NotLoaded{}} = c),
    do: c |> Repo.preload(:release) |> description()

  def description(%Connection{kind: "integration"}), do: {:error, :not_ready}

  defp may_read(%Scope{organisation: %Organisation{} = organisation} = scope) do
    with :ok <- Access.authorize(scope, :"connection.read", organisation),
         do: {:ok, organisation}
  end

  defp may_read(_scope), do: {:error, :not_found}

  defp connections(organisation_id),
    do: from(c in Connection, where: c.organisation_id == ^organisation_id)

  defp definitions(organisation_id),
    do: from(d in ServiceDefinition, where: d.organisation_id == ^organisation_id)

  defp preloads,
    do: [
      :release,
      :service_definition,
      workspaces: from(w in ConnectionWorkspace, order_by: w.workspace_id)
    ]

  # A provider's: its workspaces, and its keys' secret with its values, never their
  # ciphertext.
  defp preloads(%Connection{provider_kind: kind}) when is_binary(kind),
    do: [
      workspaces: from(w in ConnectionWorkspace, order_by: w.workspace_id),
      secret: [
        values: from(v in Value, select: struct(v, ^Value.public_fields()), order_by: v.value_id)
      ]
    ]

  defp preloads(%Connection{}), do: preloads()

  # The organisation's connections but its providers.
  defp load_all(organisation_id) do
    Repo.all(
      from c in connections(organisation_id),
        where: is_nil(c.provider_kind),
        order_by: [asc: c.kind, asc: fragment("lower(?)", c.name), asc: c.id],
        preload: ^preloads()
    )
  end

  ## Integrity

  @doc """
  intact?/1 says whether `connection`, loaded with its release and definition, is as it
  was written: its code verifies, an integration's release is intact and has the digest
  it copied, and a custom service's definition verifies.
  """
  @spec intact?(Connection.t()) :: boolean
  def intact?(%Connection{} = connection) do
    Coded.verify(connection) == :ok and Connection.coded_columns?(connection) and
      part_intact?(connection)
  end

  # A provider's description is the catalogue's, which the release compiles in.
  defp part_intact?(%Connection{kind: "integration", provider_kind: kind}) when is_binary(kind),
    do: true

  defp part_intact?(%Connection{kind: "integration", release: %Release{} = release} = c),
    do: Release.intact?(release) and release.description_sha256 == c.description_sha256

  defp part_intact?(%Connection{kind: "service", service_definition_id: nil}), do: true

  defp part_intact?(%Connection{kind: "service", service_definition: %ServiceDefinition{} = d}),
    do: Coded.verify(d) == :ok

  defp part_intact?(%Connection{kind: "runtime"}), do: true
  defp part_intact?(_connection), do: false

  @doc """
  list_for_rendering/1 is the connections of `workspace`'s organisation that apply to it,
  every workspace's and those that list it, loaded as `list_connections/1` loads them,
  every one checked:
  `{:ok, connections}`, or `{:error, {:integrity, public_ids}}` when a connection, its
  release or its definition is not as it was written, with an error in the log. It leaves
  out the model providers, whose hosts a run reaches only by its choice of model. It asks
  nothing of `Apiary.Access`: it is the server's path, with no person's scope to ask
  about.
  """
  @spec list_for_rendering(%Workspace{}) ::
          {:ok, [Connection.t()]} | {:error, {:integrity, [String.t()]}}
  def list_for_rendering(%Workspace{} = workspace) do
    connections =
      for connection <- load_all(workspace.organisation_id),
          connection.applies_to == "all" or workspace.id in workspace_ids_of(connection),
          do: connection

    case for(connection <- connections, not intact?(connection), do: connection.public_id) do
      [] ->
        {:ok, Enum.map(connections, &%{&1 | intact: true})}

      failed ->
        Logger.error(
          "connections fail their integrity code, and are not rendered: #{Enum.join(failed, ", ")}",
          LogMetadata.metadata(workspace.organisation_id, workspace.id)
        )

        {:error, {:integrity, failed}}
    end
  end

  @doc """
  egress_hosts/1 is the hosts that the integrations reaching `workspace` require, each
  with its connection: the `egress_hosts` of every integration connection of the
  organisation that applies to every workspace or lists `workspace`, read for its
  settings (`Apiary.Integrations.Description.egress_hosts/2`). Each host is exact
  (`Apiary.Policy.Grammar.exact_host?/1`). `Apiary.Policy` renders them into the
  workspace's policy (`Apiary.Policy.Resolution`).

  Model providers are left out: a run whose claim set a model provider gets the
  provider's hosts in the document composed for the run
  (`Apiary.Policy.ComposedConfiguration`), and `provider_hosts/1` has the hosts of their
  API endpoints. A connection that fails its integrity code, or
  whose release does, is left out, with an error in the log, and so is one whose
  description fails to parse. A setting whose address fails the endpoint rule, or whose
  host is not exact, adds no host, with a line in the log that contains the setting's
  name and not its value. `[]` where the `secrets` feature is off, since the
  organisation's integrations are absent there. It asks nothing of `Apiary.Access`.
  """
  @spec egress_hosts(%Workspace{}) :: [Apiary.Policy.Resolution.integration_host()]
  def egress_hosts(%Workspace{id: workspace_id, organisation_id: organisation_id}),
    do: reaching_hosts(organisation_id, &reaching_workspace(&1, workspace_id))

  @doc """
  organisation_egress_hosts/1 is `egress_hosts/1` for every workspace of the
  organisation at once: the hosts of each integration connection that applies to every
  workspace or lists at least one workspace, each with its connection.
  """
  @spec organisation_egress_hosts(%Organisation{} | Ecto.UUID.t()) ::
          [Apiary.Policy.Resolution.integration_host()]
  def organisation_egress_hosts(%Organisation{id: id}), do: organisation_egress_hosts(id)

  def organisation_egress_hosts(organisation_id) when is_binary(organisation_id),
    do: reaching_hosts(organisation_id, &reaching_any/1)

  @doc """
  provider_hosts/1 is the hosts of the API endpoints of the model providers reaching
  `workspace`, each with its connection: every provider connection of the organisation
  that applies to every workspace or lists `workspace`, the reach the model choice
  checks. An endpoint that is a setting is the provider's value of that setting. Each
  host is exact and passes the rule of `Apiary.Kinds.Endpoint`; any other is left out,
  and so is a provider that fails its integrity code, whose kind the catalogue no longer
  has, or whose settings no longer fit the catalogue's entry (`provider/1`).
  A save of a policy returns an error for a deny rule of such a host (`Apiary.Policy`);
  the hosts are in no workspace's policy, only in the document composed for a run
  (`Apiary.Policy.ComposedConfiguration`). `[]` unless the features `factory` and
  `secrets` are both on. It makes no call to `Apiary.Access`.
  """
  @spec provider_hosts(%Workspace{}) :: [Apiary.Policy.Resolution.integration_host()]
  def provider_hosts(%Workspace{id: workspace_id, organisation_id: organisation_id}),
    do: reaching_provider_hosts(organisation_id, &reaching_workspace(&1, workspace_id))

  @doc """
  organisation_provider_hosts/1 is `provider_hosts/1` for every workspace of the
  organisation at once: the hosts of each provider connection that applies to every
  workspace or lists at least one workspace, each with its connection.
  """
  @spec organisation_provider_hosts(%Organisation{} | Ecto.UUID.t()) ::
          [Apiary.Policy.Resolution.integration_host()]
  def organisation_provider_hosts(%Organisation{id: id}), do: organisation_provider_hosts(id)

  def organisation_provider_hosts(organisation_id) when is_binary(organisation_id),
    do: reaching_provider_hosts(organisation_id, &reaching_any/1)

  defp reaching_workspace(query, workspace_id) do
    from [c] in query,
      left_join: w in ConnectionWorkspace,
      on: w.connection_id == c.id and w.workspace_id == ^workspace_id,
      where: c.applies_to == "all" or not is_nil(w.workspace_id)
  end

  defp reaching_any(query) do
    from [c] in query,
      where:
        c.applies_to == "all" or
          exists(from w in ConnectionWorkspace, where: w.connection_id == parent_as(:c).id)
  end

  defp reaching_hosts(organisation_id, reach) do
    if Features.on?(:secrets) do
      from(c in connections(organisation_id),
        as: :c,
        where: c.kind == "integration" and is_nil(c.provider_kind),
        order_by: [asc: c.id],
        preload: [:release]
      )
      |> reach.()
      |> Repo.all()
      |> with_hosts(&connection_egress_hosts/1)
    else
      []
    end
  end

  defp reaching_provider_hosts(organisation_id, reach) do
    if Features.on?(:factory) and Features.on?(:secrets) do
      from(c in connections(organisation_id),
        as: :c,
        where: c.kind == "integration" and not is_nil(c.provider_kind),
        order_by: [asc: c.id]
      )
      |> reach.()
      |> Repo.all()
      |> with_hosts(&api_hosts/1)
    else
      []
    end
  end

  defp with_hosts(connections, hosts) do
    for connection <- connections,
        host <- hosts.(connection),
        do: %{
          host: host,
          connection: %{
            id: connection.id,
            public_id: connection.public_id,
            name: connection.name
          }
        }
  end

  # The exact hosts of the provider's API endpoints, each once, as the document composed
  # for a run checks them (`Apiary.Runs.ProviderCredential`). A provider that fails its
  # integrity code, or for which `provider/1` returns an error, has none here: a run of
  # it has no run configuration.
  defp api_hosts(%Connection{} = provider) do
    with true <- intact?(provider),
         {:ok, %Provider{apis: apis}} <- provider(provider) do
      settings = Connection.settings_map(provider)

      apis
      |> Enum.flat_map(fn
        %{"endpoint" => address} when is_binary(address) -> [address]
        %{"endpoint" => %{"setting" => name}} -> [settings[name]]
        _api -> []
      end)
      |> Enum.flat_map(fn address ->
        case Endpoint.host(address) do
          {:ok, host} -> [host]
          :error -> []
        end
      end)
      |> Enum.filter(&Grammar.exact_host?/1)
      |> Enum.uniq()
    else
      _not_read -> []
    end
  end

  defp connection_egress_hosts(%Connection{} = connection) do
    with true <- intact?(connection) || :not_intact,
         {:ok, description} <- description(connection) do
      {hosts, refused} =
        Description.egress_hosts(description, Connection.settings_map(connection))

      for name <- refused do
        Logger.warning(
          "the setting #{name} of the integration connection #{connection.public_id} is " <>
            "not an address with an exact host: its host is not added to the security policy",
          LogMetadata.metadata(connection.organisation_id, nil)
        )
      end

      Enum.filter(hosts, &Grammar.exact_host?/1)
    else
      :not_intact ->
        Logger.error(
          "an integration connection fails its integrity code, and its hosts are not rendered: #{connection.public_id}",
          LogMetadata.metadata(connection.organisation_id, nil)
        )

        []

      {:error, _not_ready} ->
        []
    end
  end

  ## Connections

  @doc """
  create_runtime/2 sets up a runtime of the catalogue (`runtime.write`): `attrs` has
  `runtime`, its name, `applies_to` (`all` by default) and `workspace_ids`, the workspaces
  of a `selected` one, each of the organisation, else `:workspace_not_found`. `{:ok, connection}`, or `{:error, refusal}`: `:runtime_unknown`.
  """
  @spec create_runtime(Scope.t(), map) :: {:ok, Connection.t()} | {:error, refusal}
  def create_runtime(%Scope{} = scope, attrs) do
    attrs = stringify(attrs)

    with {:ok, runtime} <- fetch_runtime(attrs["runtime"]) do
      create(scope, :"runtime.write", attrs, fn connection ->
        %{connection | kind: "runtime", name: runtime.name}
      end)
    end
  end

  defp fetch_runtime(name) do
    case Runtimes.fetch(name) do
      {:ok, runtime} -> {:ok, runtime}
      :error -> {:error, :runtime_unknown}
    end
  end

  @doc """
  create_integration/3 adds an integration from the scope's organisation's release
  `release_id`, ready and intact (`connection.write`): `attrs` has `settings`, the plain
  settings (`%{}` by default), `argument`, `applies_to` and `workspace_ids`.
  `{:ok, connection}`, or `{:error, refusal}`: `:release_not_ready`,
  `:integration_source_refused` for a release whose source the instance's settings no
  longer accept (`Apiary.Integrations.accepted_source/1`), and the description's refusals
  of the settings and the argument.
  """
  @spec create_integration(Scope.t(), term, map) :: {:ok, Connection.t()} | {:error, refusal}
  def create_integration(%Scope{} = scope, release_id, attrs) do
    attrs = stringify(attrs)

    create(scope, :"connection.write", attrs, fn connection, organisation_id ->
      with {:ok, release, description} <- ready_release(organisation_id, release_id),
           {:ok, settings} <- settings(description, Map.get(attrs, "settings", %{})),
           :ok <- argument(description, blank_to_nil(attrs["argument"])) do
        {:ok,
         %{
           connection
           | kind: "integration",
             name: description.name,
             release_id: release.id,
             release: release,
             source: release.source,
             forge_kind: release.forge_kind,
             version: release.version,
             description_sha256: release.description_sha256,
             settings: settings
         }}
      end
    end)
  end

  @doc """
  create_service/2 sets up a service (`connection.write`): `attrs` has `service`, the key
  of a built-in definition, or `definition_id`, the public id of one of the organisation's
  definitions, and `name` (the definition's title by default), `applies_to` and
  `workspace_ids`.
  `{:ok, connection}`, or `{:error, refusal}`: `:service_unknown`.
  """
  @spec create_service(Scope.t(), map) :: {:ok, Connection.t()} | {:error, refusal}
  def create_service(%Scope{} = scope, attrs) do
    attrs = stringify(attrs)

    create(scope, :"connection.write", attrs, fn connection, organisation_id ->
      with {:ok, title, fields} <- service(organisation_id, attrs) do
        # A name given is left to `attrs_changeset/3`, which casts it, so it is checked.
        name = if blank_to_nil(attrs["name"]), do: nil, else: title
        {:ok, struct(%{connection | kind: "service", name: name}, fields)}
      end
    end)
  end

  defp service(_organisation_id, %{"service" => key}) when is_binary(key) do
    case Services.fetch(key) do
      {:ok, definition} -> {:ok, definition["title"], service_builtin: key}
      :error -> {:error, :service_unknown}
    end
  end

  defp service(organisation_id, %{"definition_id" => public_id}) when is_binary(public_id) do
    with true <- PublicId.valid?("svc", public_id),
         %ServiceDefinition{} = definition <-
           Repo.one(from d in definitions(organisation_id), where: d.public_id == ^public_id) do
      {:ok, definition.title,
       service_definition_id: definition.id, service_definition: definition}
    else
      _ -> {:error, :service_unknown}
    end
  end

  defp service(_organisation_id, _attrs), do: {:error, :service_unknown}

  # A new connection, asked under `action`, the one for its kind (`write_action/1`):
  # `build` fills in its kind from the attributes, with the organisation when it needs to
  # read from it; then the name, where it applies, the overlap check, the row, its
  # workspaces and the entry, in one write.
  defp create(scope, action, attrs, build) do
    write(scope, fn scope, organisation ->
      new = %Connection{
        id: Ecto.UUID.generate(),
        public_id: PublicId.generate("con"),
        organisation_id: organisation.id,
        created_by_id: scope.user && scope.user.id,
        updated_by_id: scope.user && scope.user.id
      }

      with :ok <- Access.check(scope, action, organisation),
           {:ok, connection} <- built(build, new, organisation.id),
           workspaces = lock_rendered(connection, organisation.id),
           changeset = connection |> change() |> attrs_changeset(connection, attrs),
           :ok <- valid(changeset),
           {:ok, workspace_ids} <-
             workspace_ids(organisation.id, connection_reach_ids(changeset, attrs)),
           :ok <- no_overlap(organisation.id, apply_changes(changeset), workspace_ids),
           {:ok, inserted} <- insert_sealed(changeset),
           :ok <- insert_workspaces(inserted, workspace_ids),
           {:ok, _entry} <-
             Audit.record(Repo, scope, action, inserted, %{
               after: audited(inserted),
               details: %{
                 change: "created",
                 connection_id: inserted.public_id,
                 kind: inserted.kind,
                 name: inserted.name
               }
             }) do
        rendered(scope, workspaces, nil, inserted)
      end
    end)
    |> reload()
  end

  defp built(build, new, _organisation_id) when is_function(build, 1), do: {:ok, build.(new)}
  defp built(build, new, organisation_id), do: build.(new, organisation_id)

  # The row is coded with its public id (`Apiary.Kinds.Coded`), so a fresh id after a
  # collision (`Apiary.PublicId.Insert`) is coded again.
  defp insert_sealed(changeset) do
    PublicId.Insert.insert(changeset, &(&1 |> Coded.seal() |> Repo.insert()))
  end

  defp attrs_changeset(changeset, %Connection{kind: kind} = connection, attrs) do
    provider? = Connection.provider?(connection)
    fields = if kind == "service" or provider?, do: [:name, :applies_to], else: [:applies_to]
    fields = if kind == "integration" and not provider?, do: [:argument | fields], else: fields

    changeset
    |> cast(attrs, fields, empty_values: [nil])
    |> update_change(:name, &String.trim/1)
    |> update_change(:argument, &blank_to_nil/1)
    |> validate_required([:name, :applies_to])
    |> validate_inclusion(:applies_to, Connection.applies())
    |> validate_length(:name, min: 1, max: 128, count: :codepoints)
    |> Apiary.Names.validate_characters(:name)
    |> validate_length(:argument, min: 1, max: 4096, count: :bytes)
  end

  defp connection_reach_ids(changeset, attrs) do
    if get_field(changeset, :applies_to) == "selected",
      do: List.wrap(attrs["workspace_ids"]),
      else: []
  end

  @doc """
  reach_at_add/3 is the reach that a form gives what it adds, as the attributes
  `applies_to` and `workspace_ids` that `create_runtime/2`, `create_integration/3`,
  `create_service/2` and `create_provider/3` take: every workspace of the organisation
  (`all`) where the edition shows the setting `Available to every workspace in
  %{organisation}` (`c:Apiary.Edition.scope_setting?/1`) and `everywhere` is true, the
  setting on; else `workspace` alone (`selected`), the workspace the form is in. A form
  adds a thing in a workspace only: with no workspace, there is no reach to give, and no
  clause matches.
  """
  @spec reach_at_add(Scope.t(), %Workspace{}, boolean) :: %{
          String.t() => String.t() | [Ecto.UUID.t()]
        }
  def reach_at_add(%Scope{} = scope, %Workspace{} = workspace, everywhere)
      when is_boolean(everywhere) do
    if everywhere and Edition.scope_setting?(scope),
      do: %{"applies_to" => "all", "workspace_ids" => []},
      else: %{"applies_to" => "selected", "workspace_ids" => [workspace.id]}
  end

  @doc """
  update_connection/3 changes a connection (`write_action/1`): a service's `name`; an
  integration's `settings` and `argument`, checked against its description; a provider
  as `update_provider/3` does. `{:ok, connection}`, or `{:error, refusal}`:
  `:reach_fixed` for a change of `applies_to`, which is set at the add. A change that
  changes nothing leaves no entry.
  """
  @spec update_connection(Scope.t(), Connection.t(), map) ::
          {:ok, Connection.t()} | {:error, refusal}
  def update_connection(%Scope{} = scope, %Connection{provider_kind: kind} = connection, attrs)
      when is_binary(kind),
      do: update_provider(scope, connection, attrs)

  def update_connection(%Scope{} = scope, %Connection{} = connection, attrs) do
    attrs = stringify(attrs)

    write_connection(scope, connection, fn scope, organisation, current ->
      changeset =
        current
        |> change(updated_by_id: scope.user && scope.user.id)
        |> attrs_changeset(current, attrs)

      with :ok <- reach_kept(changeset, organisation, current),
           :ok <- valid(changeset),
           {:ok, changeset} <- settings_change(changeset, current, attrs),
           :ok <- argument_change(changeset, current),
           :ok <-
             no_overlap(organisation.id, apply_changes(changeset), workspace_ids_of(current)) do
        save(scope, current, changeset, "updated")
      end
    end)
    |> reload()
  end

  defp settings_change(changeset, %Connection{kind: "integration"} = current, %{"settings" => s}) do
    with {:ok, description} <- current_description(current),
         {:ok, encoded} <- settings(description, s) do
      {:ok, put_change(changeset, :settings, encoded)}
    end
  end

  defp settings_change(changeset, _current, _attrs), do: {:ok, changeset}

  defp argument_change(changeset, %Connection{kind: "integration"} = current) do
    case fetch_change(changeset, :argument) do
      {:ok, argument} ->
        with {:ok, description} <- current_description(current),
             do: argument(description, argument)

      :error ->
        :ok
    end
  end

  defp argument_change(_changeset, _current), do: :ok

  @doc """
  change_release/3 moves an integration connection to another ready, intact release of
  the scope's organisation (`connection.write`), of the same source and the same
  integration, its settings and argument checked again against the new description.
  `{:ok, connection}`, or `{:error, refusal}`: `{:integration_source_mismatch, why}` for a
  release of another source or another integration, and the refusals of
  `create_integration/3` of the release.
  """
  @spec change_release(Scope.t(), Connection.t(), term) ::
          {:ok, Connection.t()} | {:error, refusal}
  def change_release(
        %Scope{} = scope,
        %Connection{kind: "integration", provider_kind: nil} = connection,
        release_id
      ) do
    write_connection(scope, connection, fn scope, organisation, current ->
      with {:ok, release, description} <- ready_release(organisation.id, release_id),
           :ok <- same_source(current, release, description),
           {:ok, _settings} <- settings(description, Connection.settings_map(current)),
           :ok <- argument(description, current.argument) do
        changeset =
          change(current,
            release_id: release.id,
            version: release.version,
            description_sha256: release.description_sha256,
            updated_by_id: scope.user && scope.user.id
          )

        with :ok <-
               no_overlap(
                 organisation.id,
                 %{apply_changes(changeset) | release: release},
                 workspace_ids_of(current)
               ),
             do: save(scope, current, changeset, "release_changed")
      end
    end)
    |> reload()
  end

  def change_release(%Scope{}, %Connection{}, _release_id), do: {:error, :not_found}

  defp same_source(current, release, description) do
    cond do
      release.source != current.source or release.forge_kind != current.forge_kind ->
        {:error, {:integration_source_mismatch, :source}}

      description.name != current.name ->
        {:error, {:integration_source_mismatch, :name}}

      true ->
        :ok
    end
  end

  @doc """
  put_workspace/3 is the answer to adding the workspace `workspace_id` of the scope's
  organisation, not marked for deletion, to a connection's list (`write_action/1`): the
  list is set at the add, so `{:ok, connection}` for a workspace it lists already, with
  no entry, and else `{:error, refusal}`: `:workspace_not_found`; a changeset whose error
  is on `applies_to` for a model provider whose keys are a workspace's secret, as
  `update_provider/3` refuses it; `:reach_fixed` for any other.
  """
  @spec put_workspace(Scope.t(), Connection.t(), term) ::
          {:ok, Connection.t()} | {:error, refusal}
  def put_workspace(%Scope{} = scope, %Connection{} = connection, workspace_id) do
    write_connection(scope, connection, fn _scope, organisation, current ->
      listed = workspace_ids_of(current)

      with {:ok, [workspace_id]} <- workspace_ids(organisation.id, [workspace_id]) do
        if workspace_id in listed,
          do: {:ok, current},
          else: reach_refused(change(current), organisation, current)
      end
    end)
    |> reload()
  end

  @doc """
  remove_workspace/3 is the answer to taking the workspace `workspace_id` from a
  connection's list (`write_action/1`): the list is set at the add, and only the
  workspace's purge takes a workspace from it, so `{:error, refusal}`: `:reach_fixed` for
  a workspace it lists, `:workspace_not_found` for one it does not list. It changes
  nothing.
  """
  @spec remove_workspace(Scope.t(), Connection.t(), term) ::
          {:ok, Connection.t()} | {:error, refusal}
  def remove_workspace(%Scope{} = scope, %Connection{} = connection, workspace_id) do
    write_connection(scope, connection, fn _scope, _organisation, current ->
      with {:ok, uuid} <- cast_uuid(workspace_id) do
        if uuid in workspace_ids_of(current),
          do: {:error, :reach_fixed},
          else: {:error, :workspace_not_found}
      end
    end)
  end

  @doc """
  delete_connection/2 removes a connection with its list of workspaces (`write_action/1`):
  `{:ok, connection}`, the connection as it was, or `{:error, refusal}`. A provider goes as
  `delete_provider/2` deletes it.
  """
  @spec delete_connection(Scope.t(), Connection.t()) :: {:ok, Connection.t()} | {:error, refusal}
  def delete_connection(%Scope{} = scope, %Connection{provider_kind: kind} = connection)
      when is_binary(kind),
      do: delete_provider(scope, connection)

  def delete_connection(%Scope{} = scope, %Connection{} = connection) do
    write_connection(scope, connection, fn scope, _organisation, current ->
      with {:ok, deleted} <- Repo.delete(current),
           {:ok, _entry} <-
             Audit.record(Repo, scope, write_action(current), deleted, %{
               before: audited(current),
               details: %{
                 change: "deleted",
                 connection_id: deleted.public_id,
                 kind: deleted.kind,
                 name: deleted.name
               }
             }) do
        {:ok, deleted}
      end
    end)
  end

  defp save(scope, current, changeset, change) do
    case Audit.changed(current, apply_changes(changeset), audited_fields()) do
      nil ->
        {:ok, current}

      changed ->
        with {:ok, updated} <- changeset |> Coded.seal() |> Repo.update(),
             {:ok, _entry} <-
               Audit.record(
                 Repo,
                 scope,
                 write_action(current),
                 updated,
                 Map.put(changed, :details, %{
                   change: change,
                   connection_id: updated.public_id,
                   name: updated.name
                 })
               ) do
          {:ok, updated}
        end
    end
  end

  defp audited_fields, do: [:name, :applies_to, :settings, :argument, :release_id, :version]

  defp audited(%Connection{} = connection), do: Map.take(connection, [:kind | audited_fields()])

  ## The kinds' checks

  defp ready_release(organisation_id, release_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(release_id),
         %Release{state: "ready"} = release <-
           Repo.one(
             from r in Release, where: r.id == ^uuid and r.organisation_id == ^organisation_id
           ),
         true <- Integrations.intact(release),
         {:ok, description} <- Integrations.description(release) do
      # Found before the instance admin's settings changed, it is still not one to add now.
      case Integrations.accepted_source(release) do
        {:ok, _source} -> {:ok, release, description}
        {:error, _reason} -> {:error, :integration_source_refused}
      end
    else
      _ -> {:error, :release_not_ready}
    end
  end

  defp current_description(%Connection{} = connection) do
    case connection |> Repo.preload(:release) |> description() do
      {:ok, description} -> {:ok, description}
      {:error, _} -> {:error, :release_not_ready}
    end
  end

  defp settings(description, settings) do
    with :ok <- Description.check_settings(description, settings),
         do: {:ok, CanonicalJSON.encode!(settings)}
  end

  defp argument(description, argument), do: Description.check_argument(description, argument)

  ## Overlap

  # Whether `candidate`, applying to every workspace or to `workspace_ids`, collides with
  # another connection of the organisation in a workspace where both apply. The caller
  # holds the organisation's integrations lock, so every write before it is seen. A model
  # provider collides with none, and none with it.
  defp no_overlap(_organisation_id, %Connection{provider_kind: kind}, _workspace_ids)
       when is_binary(kind),
       do: :ok

  defp no_overlap(organisation_id, %Connection{} = candidate, workspace_ids) do
    others = load_all(organisation_id)
    entry = overlap_entry(candidate, workspace_ids)

    case Overlap.conflicts(entry, Enum.map(others, &overlap_entry(&1, workspace_ids_of(&1)))) do
      [] ->
        :ok

      ids ->
        {:error, {:overlap, for(c <- others, c.id in ids, do: c.public_id)}}
    end
  end

  defp overlap_entry(%Connection{} = connection, workspace_ids) do
    reach = if connection.applies_to == "all", do: :all, else: MapSet.new(workspace_ids)
    %{id: connection.id, identity: identity(connection), hosts: hosts(connection), reach: reach}
  end

  defp identity(%Connection{kind: "service"}), do: nil
  defp identity(%Connection{kind: kind, name: name}), do: {kind, name}

  defp hosts(%Connection{kind: "runtime", name: name}) do
    case Runtimes.fetch(name) do
      {:ok, runtime} -> Runtimes.hosts(runtime)
      :error -> []
    end
  end

  defp hosts(%Connection{kind: "integration"} = connection) do
    case description(Repo.preload(connection, :release)) do
      {:ok, description} -> Description.hosts(description)
      {:error, _} -> []
    end
  end

  defp hosts(%Connection{kind: "service"} = connection) do
    case definition(connection) do
      {:ok, definition} -> definition["hosts"]
      :error -> []
    end
  end

  @doc """
  workspace_ids_of/1 is the ids of the workspaces `connection` lists, those it applies to
  when it is `selected`.
  """
  @spec workspace_ids_of(Connection.t()) :: [Ecto.UUID.t()]
  def workspace_ids_of(%Connection{workspaces: workspaces}) when is_list(workspaces),
    do: Enum.map(workspaces, & &1.workspace_id)

  def workspace_ids_of(%Connection{id: id}),
    do:
      Repo.all(
        from w in ConnectionWorkspace,
          where: w.connection_id == ^id,
          order_by: w.workspace_id,
          select: w.workspace_id
      )

  ## Workspaces

  @doc """
  purge_workspace_providers/2 deletes, for the purge of the workspace `workspace_id`
  (`Apiary.Deletion.purge_workspace/1`), the model providers of the organisation
  `organisation_id` whose keys are a secret of that workspace, with the model choices
  that name them, at any level, and the fallbacks of other choices that name them, in
  one transaction, before the purge deletes the
  workspace's secrets: no provider is left linking a secret that is gone. Their
  workspaces' rows go with them (`ON DELETE CASCADE`), and the runs that name them keep
  no link to them (`ON DELETE SET NULL`). It asks nothing of `Apiary.Access` and
  leaves no entry: the purge's `workspace.purge` entry counts the rows. Returns the
  rows deleted by table.
  """
  @spec purge_workspace_providers(Ecto.UUID.t(), Ecto.UUID.t()) :: %{
          String.t() => non_neg_integer
        }
  def purge_workspace_providers(organisation_id, workspace_id)
      when is_binary(organisation_id) and is_binary(workspace_id) do
    {:ok, deleted} =
      Repo.transact(fn ->
        ids =
          Repo.all(
            from c in Connection,
              join: s in Secret,
              on: s.id == c.secret_id and s.organisation_id == c.organisation_id,
              where:
                c.organisation_id == ^organisation_id and s.workspace_id == ^workspace_id and
                  not is_nil(c.provider_kind),
              select: c.id
          )

        {fallbacks, _} =
          Repo.delete_all(
            from f in Apiary.ModelChoices.Fallback,
              where: f.organisation_id == ^organisation_id and f.connection_id in ^ids
          )

        {choices, _} =
          Repo.delete_all(
            from m in Apiary.ModelChoices.ModelChoice,
              where: m.organisation_id == ^organisation_id and m.connection_id in ^ids
          )

        {providers, _} = Repo.delete_all(from c in Connection, where: c.id in ^ids)

        {:ok,
         %{
           "model_choice_fallbacks" => fallbacks,
           "model_choices" => choices,
           "organisation_connections" => providers
         }}
      end)

    :ok = Apiary.Dispatches.refresh_model_providers({:organisation, organisation_id})
    deleted
  end

  # The ids of `ids`, each a workspace of the organisation not marked for deletion, else
  # `:workspace_not_found`.
  defp workspace_ids(_organisation_id, []), do: {:ok, []}

  defp workspace_ids(organisation_id, ids) do
    with {:ok, uuids} <- cast_uuids(ids) do
      uuids = Enum.uniq(uuids)

      found =
        Repo.all(
          from w in Workspace,
            where:
              w.organisation_id == ^organisation_id and w.id in ^uuids and
                is_nil(w.deletion_marked_at),
            select: w.id
        )

      if length(found) == length(uuids), do: {:ok, uuids}, else: {:error, :workspace_not_found}
    end
  end

  defp cast_uuids(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case cast_uuid(id) do
        {:ok, uuid} -> {:cont, {:ok, [uuid | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, uuids} -> {:ok, Enum.reverse(uuids)}
      error -> error
    end
  end

  defp cast_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :workspace_not_found}
    end
  end

  defp insert_workspaces(_connection, []), do: :ok

  defp insert_workspaces(%Connection{} = connection, workspace_ids) do
    now = DateTime.utc_now()

    rows =
      for workspace_id <- workspace_ids do
        %{
          organisation_id: connection.organisation_id,
          connection_id: connection.id,
          workspace_id: workspace_id,
          inserted_at: now,
          updated_at: now
        }
      end

    {_count, _} = Repo.insert_all(ConnectionWorkspace, rows)
    :ok
  end

  ## Model providers

  @doc """
  list_providers/1 is the scope's organisation's model providers, by name, each with its
  workspaces, its keys' secret with the value ids of its values, never a value, and
  `intact` set: `{:ok, providers}` for a reader who may `connection.read`, where the
  features `factory` and `secrets` are shown to the scope; else `{:error, reason}`,
  `:not_found` with either off.

  `chain` is the chain whose providers are listed, `"organisation"` by default; any other
  chain is `{:error, :not_found}`.
  """
  @spec list_providers(Scope.t(), String.t()) ::
          {:ok, [Connection.t()]} | {:error, Access.reason()}
  def list_providers(%Scope{} = scope, chain \\ "organisation") do
    with :ok <- providers_shown(scope),
         :ok <- chain_readable(chain),
         {:ok, organisation} <- may_read(scope) do
      {:ok,
       Repo.all(
         from c in connections(organisation.id),
           where: not is_nil(c.provider_kind) and c.chain == ^chain,
           order_by: [asc: fragment("lower(?)", c.name), asc: c.id],
           preload: ^preloads(%Connection{provider_kind: ""})
       )
       |> Enum.map(&%{&1 | intact: intact?(&1)})}
    end
  end

  @doc """
  get_provider/2 is the scope's organisation's model provider with the public id
  `public_id`, loaded as `list_providers/1` loads it: `{:ok, provider}`, or
  `{:error, reason}`, `:not_found` for one the organisation does not have in `chain`,
  `"organisation"` by default, or for any other chain (`list_providers/2`).
  """
  @spec get_provider(Scope.t(), term, String.t()) ::
          {:ok, Connection.t()} | {:error, Access.reason()}
  def get_provider(%Scope{} = scope, public_id, chain \\ "organisation") do
    with :ok <- providers_shown(scope),
         :ok <- chain_readable(chain),
         {:ok, organisation} <- may_read(scope),
         true <- PublicId.valid?("con", public_id),
         %Connection{} = provider <-
           Repo.one(
             from c in connections(organisation.id),
               where:
                 c.public_id == ^public_id and not is_nil(c.provider_kind) and c.chain == ^chain
           ) do
      provider = Repo.preload(provider, preloads(provider))
      {:ok, %{provider | intact: intact?(provider)}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  provider/1 is the description of a provider connection's kind in the catalogue of the
  running release (`Apiary.Kinds.Providers`), whatever entry the connection was added
  from: `{:ok, provider}` while the connection's settings fit that entry, checked as
  `create_provider/3` checks them; `{:error, :provider_changed}` once they no longer
  fit; `{:error, :provider_unchecked}` when the check ran out of time or crashed, a stop
  that depends on the node and not on the settings, so a later read checks them again;
  or `{:error, :provider_unknown}` once the catalogue no longer has the kind. The check
  returns the same result for the same settings and entry, so a table on each node keeps
  the results fit and no longer fit by the SHA-256 of the settings and of the entry, at
  most 4,096 of them, until a restart. Inside one claim of the queue, `provider/1`
  returns `{:error, :provider_unchecked}` again, without a check, for a connection whose
  check stopped, until the claim ends. The connection's `description_sha256`, the digest
  of the entry it was added from, is kept as it was recorded and not compared.
  """
  @spec provider(Connection.t()) ::
          {:ok, Provider.t()}
          | {:error, :provider_changed | :provider_unchecked | :provider_unknown}
  def provider(%Connection{id: id, provider_kind: kind, settings: settings}) do
    with false <- stopped_in_claim?(id),
         {:ok, %Provider{} = provider} <- Providers.fetch(kind) do
      case SettingsFit.fit(provider, settings, &settings_fit/2) do
        :fit -> {:ok, provider}
        :unfit -> {:error, :provider_changed}
        :unchecked -> stopped_in_claim(id)
      end
    else
      true -> {:error, :provider_unchecked}
      :error -> {:error, :provider_unknown}
    end
  end

  # The connection ids whose settings check stopped during the claim that runs in this
  # process (`within_claim/1`); not set outside a claim.
  @claim_stopped {__MODULE__, :claim_stopped}

  @doc false
  # within_claim/1 runs `fun`, one claim of the queue (`Apiary.Dispatches.claim/4`),
  # with a memory of the providers whose settings check ran out of time or crashed in
  # it: `provider/1` returns `{:error, :provider_unchecked}` for each of them again
  # without a check, so a claim checks a stopping provider once, however many of its
  # runs need it. The memory is in this process and goes when `fun` returns or raises;
  # no claim reads the memory of another.
  @spec within_claim((-> result)) :: result when result: term
  def within_claim(fun) when is_function(fun, 0) do
    if Process.get(@claim_stopped) do
      fun.()
    else
      Process.put(@claim_stopped, MapSet.new())

      try do
        fun.()
      after
        Process.delete(@claim_stopped)
      end
    end
  end

  @doc false
  # stopped_in_claim/0 is the connection ids whose settings check stopped in the claim
  # that runs in this process (`within_claim/1`), `[]` outside a claim.
  @spec stopped_in_claim() :: [Ecto.UUID.t()]
  def stopped_in_claim do
    case Process.get(@claim_stopped) do
      %MapSet{} = stopped -> MapSet.to_list(stopped)
      nil -> []
    end
  end

  defp stopped_in_claim?(id) do
    case Process.get(@claim_stopped) do
      %MapSet{} = stopped -> MapSet.member?(stopped, id)
      nil -> false
    end
  end

  defp stopped_in_claim(id) do
    case Process.get(@claim_stopped) do
      %MapSet{} = stopped -> Process.put(@claim_stopped, MapSet.put(stopped, id))
      nil -> nil
    end

    {:error, :provider_unchecked}
  end

  # Whether a provider's saved settings pass the checks of an add or an edit against
  # `provider`, the entry of the running release (`provider_settings/3`): the entry's
  # settings schema, then the endpoint rule on each address setting, or the entry's
  # default address where the provider has none. `:unchecked` when the schema's check ran
  # out of time or crashed (`Apiary.Integrations.Description.recheck_settings/2`).
  defp settings_fit(%Provider{} = provider, settings) do
    case Description.recheck_settings(provider.description, settings) do
      :ok -> if address_refused(provider, settings) == nil, do: :fit, else: :unfit
      {:error, :unchecked} -> :unchecked
      {:error, _refusal} -> :unfit
    end
  end

  @doc """
  provider_models/1 is the models of a model provider: those of its description, in the
  description's order, each a map of `id`, `title` and, when the description lists them,
  `effort`, the effort values the model accepts. Given a provider connection, those of
  the catalogue's entry of its kind (`provider/1`), and `[]` once its settings no longer
  fit that entry or the catalogue no longer has the kind. A model choice may name any
  other model id too.
  """
  @spec provider_models(Connection.t() | Provider.t()) :: [map]
  def provider_models(%Provider{models: models}), do: models

  def provider_models(%Connection{} = provider) do
    case provider(provider) do
      {:ok, description} -> provider_models(description)
      {:error, _changed} -> []
    end
  end

  @doc """
  default_model/1 is the id of a model provider's default model, the first of
  `provider_models/1`: nil for a provider whose description lists no model.
  """
  @spec default_model(Connection.t() | Provider.t()) :: String.t() | nil
  def default_model(provider) do
    case provider_models(provider) do
      [%{"id" => id} | _rest] -> id
      [] -> nil
    end
  end

  @doc """
  create_provider/3 adds a model provider of the catalogue to the scope's organisation
  (`provider.write`), in one transaction with its keys, at `place`:

    * `:organisation`, the default: its keys are a secret of the organisation, and it
      reaches the workspaces `applies_to` and `workspace_ids` give;
    * `:workspace`: its keys are a secret of the scope's workspace
      (`Apiary.Secrets.create_provider_keys/3`), and it reaches that workspace alone,
      `applies_to` `selected` with that one workspace, whatever `attrs` gives. A reach
      that never widens (`update_provider/3`, `put_workspace/3`) keeps every other
      workspace from the key. `:workspace_not_found` for a scope without a workspace of
      the organisation, or one marked for deletion.

  `attrs` has:

    * `provider`, the name of a provider of the catalogue, else `:provider_unknown`;
    * `name`, the description's title by default; `applies_to` (`all` by default) and
      `workspace_ids`, as `create_runtime/2` takes them, for `:organisation`;
    * `settings`, its plain settings (`%{}` by default), checked against the description,
      each address setting by `Apiary.Kinds.Endpoint.check/1`;
    * `keys`, its keys: a list of maps of `value_id` and `value`, or a map of them by
      index, as `Apiary.Secrets.create_provider_keys/2` takes them, each `value` without
      the whitespace at its ends (`String.trim/1`); for a provider whose keys are logins
      (`Apiary.ModelKeys.Login`) the `value` is the sign-in of a device sign-in
      (`t:Apiary.ModelKeys.Login.parsed/0`), and any text is refused with "is invalid".
      A key with no `value_id` gets the next `key-<n>`; a given `value_id` of that form is
      refused with "Choose another name: Qory Apiary gives names like key-3 to new keys.";
    * `default_key`, the value id of its default key, the first key's by default;
    * `chain`, `"organisation"` by default; any other chain is refused with
      `:forbidden`.

  The keys are stored as a secret that the provider links. The provider keeps no models:
  `provider_models/1` reads them from its description.
  A provider whose description lists no models, such as LiteLLM, is refused on
  `provider_kind` unless the feature `model_proxies` is on (`Providers.offered?/1`), as
  the pages leave it out of their lists; `update_provider/3` does not check it.

  `{:ok, provider}`, loaded as `get_provider/2` loads it, or `{:error, refusal}`: a
  changeset of the provider whose errors are on `name`, `applies_to`, `provider_kind`,
  `settings` or `default_value_id`, a changeset of the keys' secret whose errors are on
  `values`, a value changeset whose error is on `value_id` for a given `key-<n>`, or a
  refusal of the settings.
  """
  @spec create_provider(Scope.t(), map, :organisation | :workspace) ::
          {:ok, Connection.t()} | {:error, refusal}
  def create_provider(%Scope{} = scope, attrs, place \\ :organisation)
      when place in [:organisation, :workspace] do
    scope
    |> insert_provider(attrs, place, :given)
    |> refreshed()
    |> reload()
    |> without_keys()
  end

  # The write of `create_provider/3`, in a new transaction or in the caller's
  # (`add_key/2`), which refreshes the waiting runs once its transaction commits. `names`
  # is `:given` for keys' value ids from the caller, where a `key-<n>` is refused, or
  # `:numbered` for the one `add_key/2` sets (`next_key_name/2`). `keys_opts` goes to
  # `Apiary.Secrets.create_provider_keys/4`: `copy:` for a key that moves (`move_key/4`).
  defp insert_provider(scope, attrs, place, names, keys_opts \\ []) do
    attrs = scope |> placed(stringify(attrs), place)

    write(scope, fn scope, organisation ->
      with :ok <- providers_shown(scope),
           :ok <- Access.check(scope, :"provider.write", organisation),
           :ok <- new_chain(attrs["chain"]),
           {:ok, provider} <- fetch_provider(attrs["provider"]),
           new = new_provider(scope, organisation, provider),
           changeset = new |> change() |> attrs_changeset(new, attrs),
           :ok <- offered(changeset, provider),
           {:ok, changeset} <- provider_settings(changeset, provider, attrs),
           :ok <- valid(changeset),
           {:ok, workspace_ids} <-
             workspace_ids(organisation.id, connection_reach_ids(changeset, attrs)),
           :ok <- placed_reach(place, workspace_ids),
           ordered = in_order(attrs["keys"]),
           :ok <- given_names(ordered, names),
           {:ok, keys, logins} <-
             login_keys(provider, ordered |> trim_keys() |> name_keys()),
           {:ok, secret} <-
             Secrets.create_provider_keys(
               scope,
               %{name: keys_name(new), values: keys},
               place,
               [hint: not Login.provider?(provider.name)] ++ keys_opts
             ),
           :ok <- put_logins(secret.id, logins),
           {:ok, changeset} <-
             default_key(changeset, provider, secret, attrs["default_key"] || first_key(keys)),
           {:ok, inserted} <- insert_sealed(changeset),
           :ok <- insert_workspaces(inserted, workspace_ids),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"provider.write", inserted, %{
               after: provider_audited(inserted),
               details: %{
                 change: "provider_created",
                 connection_id: inserted.public_id,
                 kind: inserted.kind,
                 name: inserted.name,
                 provider: inserted.provider_kind,
                 secret_id: secret.public_id
               }
             }) do
        {:ok, inserted}
      end
    end)
  end

  # A provider added for the scope's workspace alone reaches that workspace, `selected`,
  # whatever `attrs` gives; a scope without a workspace gives an id that is none.
  defp placed(scope, attrs, :workspace) do
    workspace_id =
      case scope do
        %Scope{workspace: %Workspace{id: id}} -> id
        _none -> ""
      end

    Map.merge(attrs, %{"applies_to" => "selected", "workspace_ids" => [workspace_id]})
  end

  defp placed(_scope, attrs, :organisation), do: attrs

  defp placed_reach(:workspace, [_one]), do: :ok
  defp placed_reach(:workspace, _ids), do: {:error, :workspace_not_found}
  defp placed_reach(:organisation, _ids), do: :ok

  # A provider whose description lists no models, such as LiteLLM, is added only with the
  # feature `model_proxies` on (`Providers.offered?/1`), as the pages offer it; else the
  # refusal on `provider_kind`. A provider of that kind already added stays, and its
  # edits are not checked.
  defp offered(changeset, %Provider{} = provider) do
    if Providers.offered?(provider),
      do: :ok,
      else:
        {:error,
         add_error(
           changeset,
           :provider_kind,
           dgettext_noop(
             "errors",
             "Turn on the feature Model proxies to add %{provider}: it lists no models."
           ),
           provider: provider.title
         )}
  end

  defp fetch_provider(name) do
    case Providers.fetch(name) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, :provider_unknown}
    end
  end

  # A provider is created in the organisation's chain alone.
  defp new_chain(chain) when chain in [nil, "organisation"], do: :ok
  defp new_chain(_other), do: {:error, :forbidden}

  # Only the organisation's chain is read.
  defp chain_readable("organisation"), do: :ok
  defp chain_readable(_other), do: {:error, :not_found}

  defp new_provider(scope, organisation, %Provider{} = provider) do
    %Connection{
      id: Ecto.UUID.generate(),
      public_id: PublicId.generate("con"),
      organisation_id: organisation.id,
      kind: "integration",
      name: provider.title,
      provider_kind: provider.name,
      description_ref: Providers.ref(),
      description_sha256: provider.sha256,
      chain: "organisation",
      created_by_id: scope.user && scope.user.id,
      updated_by_id: scope.user && scope.user.id
    }
  end

  # The secret of a provider's keys is named after the public id the provider was made
  # with, which is unique, so the name is free among the organisation's secrets. Should
  # that id collide at the insert, the provider is inserted with a fresh id
  # (`Apiary.PublicId.Insert`) and the secret keeps the name it has.
  defp keys_name(%Connection{public_id: "con_" <> id}), do: "MODEL_PROVIDER_" <> String.upcase(id)

  # The keys as they came: a list as it is, a form's map in the order of its index.
  defp in_order(keys) when is_list(keys), do: keys

  defp in_order(keys) when is_map(keys) do
    keys
    |> Enum.flat_map(fn {index, key} ->
      case Integer.parse(to_string(index)) do
        {index, ""} -> [{index, key}]
        _other -> []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp in_order(_keys), do: []

  defp first_key(keys) do
    case List.first(keys) do
      %{} = key -> Value.normalise_value_id(key["value_id"])
      _none -> nil
    end
  end

  # Each key that has no value id gets the next `key-<n>` (`Apiary.Secrets.Value.next_key_id/1`):
  # Qory Apiary gives a new key its name, which the list of model provider keys and Edit
  # key show. The numbers start at 1 without a seed (`given_names/2`): on the `:given` path
  # no given value id has the form `key-<n>`, and on the `:numbered` path every key already
  # has its value id.
  defp name_keys(keys) do
    {keys, _taken} =
      Enum.map_reduce(keys, [], fn
        %{} = key, taken ->
          if Value.normalise_value_id(key["value_id"]) do
            {key, taken}
          else
            id = Value.next_key_id(taken)
            {Map.put(key, "value_id", id), [id | taken]}
          end

        other, taken ->
          {other, taken}
      end)

    keys
  end

  # `value_id`, a value id of the keys' secret, as the provider's default key; else the
  # refusal on `default_value_id`.
  defp default_key(changeset, provider_or_name, %Secret{} = secret, value_id) do
    if is_binary(value_id) and Enum.any?(secret.values, &(&1.value_id == value_id)) do
      {:ok, change(changeset, secret_id: secret.id, default_value_id: value_id)}
    else
      {:error,
       add_error(
         changeset,
         :default_value_id,
         dgettext_noop(
           "errors",
           "Choose one of %{provider}'s keys: %{value} is not one of them."
         ),
         provider: provider_name(changeset, provider_or_name),
         value: to_string(value_id)
       )}
    end
  end

  defp provider_name(changeset, %Provider{title: title}), do: get_field(changeset, :name) || title
  defp provider_name(_changeset, name), do: name

  # The settings of `attrs`, checked against the description and each address setting by
  # the endpoint rule, as the canonical JSON the row keeps; a refusal of the description,
  # or the changeset with the rule's sentence on `settings`.
  defp provider_settings(changeset, %Provider{} = provider, attrs) do
    settings = Map.get(attrs, "settings", %{})

    with {:ok, encoded} <- settings(provider.description, settings) do
      case address_refused(provider, settings) do
        nil ->
          {:ok, put_change(changeset, :settings, encoded)}

        {name, {message, bindings}} ->
          {:error, add_error(changeset, :settings, message, [setting: name] ++ bindings)}
      end
    end
  end

  # The first address setting whose value, or the description's default where it has
  # none, the endpoint rule refuses: `{name, refusal}`, or nil. An address setting with
  # neither is refused as an address without `https://`.
  defp address_refused(%Provider{} = provider, settings) do
    Enum.find_value(Provider.address_settings(provider), fn name ->
      address =
        case Map.fetch(settings, name) do
          {:ok, value} -> value
          :error -> provider |> Provider.setting_default(name) |> default_address()
        end

      case Endpoint.check(address) do
        :ok -> nil
        {:error, refusal} -> {name, refusal}
      end
    end)
  end

  defp default_address({:ok, default}), do: default
  defp default_address(:error), do: nil

  @doc """
  update_provider/3 changes a model provider (`provider.write`): its `name` and
  `settings`, checked as `create_provider/3` checks them. A change of its settings alone
  that changes an address setting is entered as `provider_address_changed`, with the host
  before and after. `{:ok, provider}`, or `{:error, refusal}`: `:provider_changed` for a
  provider whose saved settings no longer fit the catalogue's entry, or
  `:provider_unknown` for a provider whose kind the catalogue no longer has, or
  `:provider_unchecked` for one whose settings check ran out of time or crashed, which
  changes nothing (`provider/1`); for any change of `applies_to`, which is set at the add,
  a changeset whose error is on `applies_to` for a provider whose keys are a workspace's
  secret (`create_provider/3` with `:workspace`), which reaches that workspace alone, and
  `:reach_fixed` for any other. A change that changes nothing leaves no entry.
  """
  @spec update_provider(Scope.t(), Connection.t(), map) ::
          {:ok, Connection.t()} | {:error, refusal}
  def update_provider(%Scope{} = scope, %Connection{} = provider, attrs) do
    attrs = stringify(attrs)

    write_provider(scope, provider, fn scope, organisation, current ->
      changeset =
        current
        |> change(updated_by_id: scope.user && scope.user.id)
        |> attrs_changeset(current, attrs)

      with :ok <- reach_kept(changeset, organisation, current),
           {:ok, description} <- provider(current),
           {:ok, changeset} <- settings_of(changeset, description, attrs),
           :ok <- valid(changeset),
           do: save_provider(scope, current, changeset, description)
    end)
    |> refreshed()
  end

  # The reach is set at the add: a change of `applies_to` is refused. A provider whose keys
  # are a workspace's secret reaches that workspace alone, so no other workspace's run
  # reaches the key: its refusal is on `applies_to`, with the sentence that says to add it
  # again. Any other change goes on.
  defp reach_kept(changeset, organisation, current) do
    case fetch_change(changeset, :applies_to) do
      {:ok, _applies_to} -> reach_refused(changeset, organisation, current)
      :error -> :ok
    end
  end

  defp reach_refused(changeset, organisation, current) do
    with :ok <- not_widened(changeset, organisation, current), do: {:error, :reach_fixed}
  end

  defp not_widened(changeset, %Organisation{} = organisation, %Connection{} = current) do
    case keys_workspace(current) do
      nil ->
        :ok

      %Workspace{} = workspace ->
        {:error,
         add_error(
           changeset,
           :applies_to,
           dgettext_noop(
             "errors",
             "To share this provider, add it again with “Available to every workspace in %{organisation}” on. Its key is a secret of %{workspace}."
           ),
           organisation: organisation.name,
           workspace: workspace.name
         )}
    end
  end

  # The workspace whose secret a model provider links as its keys; nil for the
  # organisation's secret, or for a connection that links none. A secret never moves to
  # another level.
  defp keys_workspace(%Connection{secret_id: secret_id, organisation_id: organisation_id})
       when is_binary(secret_id) do
    Repo.one(
      from s in Secret,
        join: w in Workspace,
        on: w.id == s.workspace_id and w.organisation_id == s.organisation_id,
        where: s.id == ^secret_id and s.organisation_id == ^organisation_id,
        select: w
    )
  end

  defp keys_workspace(%Connection{}), do: nil

  defp settings_of(changeset, description, %{"settings" => _} = attrs),
    do: provider_settings(changeset, description, attrs)

  defp settings_of(changeset, _description, _attrs), do: {:ok, changeset}

  defp save_provider(scope, current, changeset, description) do
    fields = [:name, :applies_to, :settings]

    case Audit.changed(current, apply_changes(changeset), fields) do
      nil ->
        {:ok, current}

      changed ->
        updated = apply_changes(changeset)

        {change, changed} =
          case Map.keys(changed.after) do
            [:settings] ->
              {"provider_address_changed",
               %{
                 before: Map.put(changed.before, :host, address_host(description, current)),
                 after: Map.put(changed.after, :host, address_host(description, updated))
               }}

            _other ->
              {"updated", changed}
          end

        with {:ok, updated} <- changeset |> Coded.seal() |> Repo.update(),
             {:ok, _entry} <-
               Audit.record(
                 Repo,
                 scope,
                 :"provider.write",
                 updated,
                 Map.put(changed, :details, %{
                   change: change,
                   connection_id: updated.public_id,
                   name: updated.name
                 })
               ) do
          {:ok, updated}
        end
    end
  end

  # The host of a provider's first address setting, nil for a provider with none.
  defp address_host(%Provider{} = provider, %Connection{} = connection) do
    with [name | _rest] <- Provider.address_settings(provider),
         {:ok, address} <- Map.fetch(Connection.settings_map(connection), name),
         {:ok, host} <- Endpoint.host(address) do
      host
    else
      _none -> nil
    end
  end

  @doc """
  delete_provider/2 removes a model provider (`provider.write`) with its workspaces and
  its keys' secret: `{:ok, provider}`, the provider as it was, or
  `{:error, refusal}`: `{:model_in_use, places}` while a model choice uses it, with the
  places of those choices; `{:provider_in_use, %{places: places, runs: run_public_ids}}`
  while a run that is pending or running uses it, or one lost after its attach that its
  gateway may still attach again (`Apiary.Runs.Sender.live?/2`), with the public ids of
  those runs, and the places of the choices that use it, if any. It leaves one `provider.write` entry.
  """
  @spec delete_provider(Scope.t(), Connection.t()) :: {:ok, Connection.t()} | {:error, refusal}
  def delete_provider(%Scope{} = scope, %Connection{provider_kind: kind} = provider)
      when is_binary(kind) do
    write_connection(scope, provider, fn scope, _organisation, current ->
      # The model choices and the runs that use the provider and may still read its keys
      # (`live_runs/1`), read without a lock under the provider's row lock. A claim holds
      # the row `FOR SHARE` until it commits (`Apiary.Dispatches.RunSettings`), so a run
      # it registers, with its key rows, is read here, and the deletion fails
      # `provider_in_use`; a claim that comes after reads the provider as deleted. The
      # claim takes neither the organisation's lock nor the integrations lock that this
      # deletion takes before the provider (`Apiary.Dispatches.Handover`).
      # A workflow's choice whose workspace no longer keeps the workflow goes with the
      # provider (`ModelChoices.delete_leftovers_using/2`).
      with :ok <- not_used(ModelChoices.places_using(current), live_runs(current)),
           :ok <- ModelChoices.delete_leftovers_using(scope, current),
           {:ok, deleted} <- delete_with_keys(scope, current),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"provider.write", deleted, %{
               before: provider_audited(current),
               details: %{
                 change: "provider_deleted",
                 connection_id: deleted.public_id,
                 kind: deleted.kind,
                 name: deleted.name,
                 provider: deleted.provider_kind
               }
             }) do
        {:ok, deleted}
      end
    end)
    |> refreshed()
    |> without_keys()
  end

  def delete_provider(%Scope{}, %Connection{}), do: {:error, :not_found}

  # The result of a change of a model provider, once it has committed, with the model
  # providers of the waiting runs that the change may change set again
  # (`Apiary.Dispatches.refresh_model_providers/1`): those of the provider's
  # organisation.
  defp refreshed({:ok, %Connection{organisation_id: id}} = result) do
    :ok = Apiary.Dispatches.refresh_model_providers({:organisation, id})
    result
  end

  defp refreshed(result), do: result

  defp not_used([], []), do: :ok
  defp not_used(places, []), do: {:error, {:model_in_use, places}}
  defp not_used(places, runs), do: {:error, {:provider_in_use, %{places: places, runs: runs}}}

  # The public ids of the runs that have a key of `provider` and may still read it,
  # oldest first: pending or running, or lost after their attach and not lost for good,
  # which their gateway may attach again (`Apiary.Runs.Sender.live?/2`). Any key row of
  # such a run with the provider blocks the deletion, whichever session uses it.
  defp live_runs(%Connection{id: id}) do
    alive = dynamic([run: r], r.state in ^Run.alive_states())
    keyed = from k in Apiary.Runs.ModelKey, where: k.connection_id == ^id, select: k.run_id

    Repo.all(
      from r in Run,
        as: :run,
        where: r.provider_connection_id == ^id or r.id in subquery(keyed),
        where: ^dynamic(^alive or ^Apiary.Runs.Sender.revivable(DateTime.utc_now())),
        order_by: [asc: r.inserted_at, asc: r.id],
        select: r.public_id
    )
  end

  # The provider's row deleted, and with it the secret of its keys, which
  # `Apiary.Secrets` deletes once the row that links it is gone.
  defp delete_with_keys(_scope, %Connection{secret_id: nil} = provider), do: Repo.delete(provider)

  defp delete_with_keys(scope, %Connection{} = provider) do
    with {:ok, _secret} <-
           Secrets.delete_provider_keys(scope, provider, fn -> Repo.delete(provider) end),
         do: {:ok, Ecto.put_meta(provider, state: :deleted)}
  end

  @doc """
  put_default_key/3 makes the key with the value id `value_id` the model provider's
  default key (`provider.write`), with the keys' secret's row held `FOR SHARE`, so the
  key is not deleted meanwhile. `{:ok, provider}`, or `{:error, refusal}`: a changeset
  whose error is on `default_value_id` for a value id the provider's keys do not have.
  """
  @spec put_default_key(Scope.t(), Connection.t(), String.t()) ::
          {:ok, Connection.t()} | {:error, refusal}
  def put_default_key(%Scope{} = scope, %Connection{} = provider, value_id) do
    write_provider(scope, provider, fn scope, _organisation, current ->
      secret = keys_secret(current)
      changeset = change(current, updated_by_id: scope.user && scope.user.id)

      with {:ok, changeset} <- default_key(changeset, current.name, secret, value_id) do
        if current.default_value_id == value_id do
          {:ok, current}
        else
          with {:ok, updated} <- changeset |> Coded.seal() |> Repo.update(),
               {:ok, _entry} <-
                 Audit.record(Repo, scope, :"provider.write", updated, %{
                   before: %{default_value_id: current.default_value_id},
                   after: %{default_value_id: value_id},
                   details: %{
                     change: "provider_default_key_changed",
                     connection_id: updated.public_id,
                     name: updated.name
                   }
                 }),
               do: {:ok, updated}
        end
      end
    end)
  end

  @doc """
  add_provider_key/4 adds a key to a model provider's keys (`provider.write`): `attrs` has
  `value` and, optionally, `value_id`, as `Apiary.Secrets.add_value/4` takes them, the
  `value` without the whitespace at its ends (`String.trim/1`). With no `value_id` the key
  gets `key-<n>` (`Apiary.Secrets.next_key_id/1`); no page sends one.
  `settings` is the key's settings (`Apiary.ModelKeys.Setting.changeset/3`, with the
  provider's limit windows), nil for none. For a provider whose keys are logins the
  `value` is the sign-in of a device sign-in (`t:Apiary.ModelKeys.Login.parsed/0`). The
  key and its settings are written in one transaction.
  `{:ok, provider}`, or `{:error, refusal}` as `Apiary.Secrets.add_value/4` returns, a
  value changeset whose error is on `value_id` for a given `value_id` of the form
  `key-<n>` (as `create_provider/3` refuses it), a value changeset whose error "is invalid"
  is on `value` for a text where a sign-in is expected, or a changeset of the settings.
  No refusal leaves a key added.
  """
  @spec add_provider_key(Scope.t(), Connection.t(), map, map | nil) ::
          {:ok, Connection.t()} | {:error, refusal}
  def add_provider_key(%Scope{} = scope, %Connection{} = provider, attrs, settings \\ nil),
    do: add_named_key(scope, provider, attrs, settings, :given)

  # `add_provider_key/4`, with `names` as `insert_provider/4` has it: `add_key/2` passes
  # `:numbered` for the `key-<n>` it sets.
  defp add_named_key(scope, provider, attrs, settings, names),
    do:
      write_keys(scope, provider, fn scope, secret, current ->
        attrs = trim_value(stringify(attrs))

        with :ok <- given_names([attrs], names) do
          value_id =
            Value.normalise_value_id(attrs["value_id"]) ||
              Secrets.next_key_id(current.secret)

          attrs = Map.put(attrs, "value_id", value_id)

          with {:ok, attrs, login} <- login_attrs(current, attrs),
               {:ok, _secret} <- Secrets.add_value(scope, secret, attrs, provider: current),
               {:ok, _setting} <- put_key_setting(current, value_id, settings),
               :ok <- put_login(current, value_id, login),
               do:
                 {:ok,
                  %{
                    after: %{value_id: value_id},
                    details: %{
                      value_id: value_id,
                      identity: Identity.for_value_id(current, value_id)
                    }
                  }}
        end
      end)

  @doc """
  add_key/2 adds a model provider key to the scope's organisation (`provider.write`), in
  one transaction under the organisation's integrations lock (`write/2`), so two adds take
  turns. `attrs` has:

    * `provider`, the name of a provider of the catalogue, else `:provider_unknown`;
    * `value`, the key, as `add_provider_key/4` takes it;
    * `settings`, the provider's plain settings, such as LiteLLM's address, `%{}` by
      default;
    * `applies_to`, `all` or `selected`, and with `selected`, `workspace_ids`, the
      workspaces of the organisation that the key serves; those the scope's person does not
      reach are left out, and `all` is `:forbidden` unless they reach every workspace;
    * `key_settings`, the key's Resets, Pause for and Use up to
      (`Apiary.ModelKeys.Setting`), nil for none.

  The key goes into the key group: the providers of the organisation's chain with the same
  kind and the same stored settings (`Apiary.ModelKeys.Group.of/2`), intact, whose
  settings still fit the catalogue (`provider/1`). The first of them, oldest first, that
  reaches the same workspaces (every workspace, or the same set) and whose keys' secret
  has room (`Apiary.Secrets.max_values/0`) takes the key as its next value. With none, a new
  provider is created with the key (`create_provider/3`): for one workspace, the key is a
  secret of that workspace (`:workspace`); for several or every workspace, a secret of the
  organisation. The key's value id is `key-<n>`: the number after the highest among the
  value ids of the organisation's current keys of that kind and the key counters
  (`last_key_number`) of those keys' secrets. No current key of that kind has that
  number; a number of a key whose provider was deleted can come again.

  A provider whose description lists no models, such as LiteLLM, takes a key only with
  the feature `model_proxies` on, as `create_provider/3` checks it, also where a provider
  of its group exists. Once the key is committed, the model providers of the
  organisation's waiting runs are set again, as after `create_provider/3`.

  `{:ok, provider, value_id}`, the provider that has the key, or `{:error, refusal}`:
  `:no_workspace` for `selected` without a workspace the person reaches,
  `:workspace_not_found` for a workspace that is not one of the organisation's, a
  changeset whose error is on `provider_kind` for a provider not offered, or a refusal of
  `create_provider/3` or `add_provider_key/4`, which adds no key.
  """
  @spec add_key(Scope.t(), map) :: {:ok, Connection.t(), String.t()} | {:error, refusal}
  def add_key(%Scope{} = scope, attrs) do
    attrs = stringify(attrs)

    write(scope, fn scope, organisation ->
      with :ok <- providers_shown(scope),
           :ok <- Access.check(scope, :"provider.write", organisation),
           {:ok, provider} <- fetch_provider(attrs["provider"]),
           :ok <- offered(change(%Connection{}), provider),
           {:ok, reach} <- key_reach(scope, organisation.id, attrs) do
        value_id = next_key_name(organisation.id, provider.name)

        with {:ok, added} <- add_to_group(scope, organisation, provider, reach, attrs, value_id),
             do: {:ok, {added, value_id}}
      end
    end)
    |> case do
      # The waiting runs are refreshed once the key is committed, so they read it.
      {:ok, {provider, value_id}} ->
        {:ok, provider} = {:ok, provider} |> refreshed() |> reload()
        {:ok, provider, value_id}

      {:error, reason} ->
        without_keys({:error, reason})
    end
  end

  # The workspaces a new key serves: `:all`, for a person who reaches every workspace
  # (`Apiary.Access.reaches_every_workspace_in?/1`), else `:forbidden`; or the sorted ids
  # of the organisation's workspaces it lists that the scope's person reaches
  # (`Apiary.Organisations.workspace_scopes/1`); the others are left out.
  defp key_reach(scope, _organisation_id, %{"applies_to" => "all"}) do
    if Access.reaches_every_workspace_in?(scope), do: {:ok, :all}, else: {:error, :forbidden}
  end

  defp key_reach(scope, organisation_id, %{"applies_to" => "selected"} = attrs) do
    reached = scope |> Apiary.Organisations.workspace_scopes() |> Map.keys()

    case workspace_ids(organisation_id, List.wrap(attrs["workspace_ids"])) do
      {:ok, ids} ->
        case Enum.filter(ids, &(&1 in reached)) do
          [] -> {:error, :no_workspace}
          ids -> {:ok, Enum.sort(ids)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp key_reach(_scope, _organisation_id, _attrs), do: {:error, :no_workspace}

  # The value id of the next key of `kind` in the organisation: the number after the
  # highest among the value ids of its current keys of that kind and the counters of their
  # secrets. A deleted provider's secret is gone, so its numbers are not counted.
  defp next_key_name(organisation_id, kind) do
    rows =
      Repo.all(
        from c in connections(organisation_id),
          join: s in Secret,
          on: s.id == c.secret_id,
          left_join: v in Value,
          on: v.secret_id == s.id,
          where: c.provider_kind == ^kind,
          select: {s.last_key_number, v.value_id}
      )

    counted = rows |> Enum.map(&elem(&1, 1)) |> Value.highest_key_number()
    counters = for {number, _value_id} <- rows, is_integer(number), do: number

    "key-#{Enum.max([counted | counters]) + 1}"
  end

  # The key, with the value id `value_id`, added to the first provider of its group that
  # reaches `reach` and has room, else to a new provider.
  defp add_to_group(scope, organisation, %Provider{} = provider, reach, attrs, value_id) do
    found =
      organisation.id
      |> key_group(provider, attrs["settings"] || %{})
      |> Enum.find(&(same_reach?(&1, reach) and room?(&1)))

    case found do
      %Connection{} = found ->
        key = %{"value_id" => value_id, "value" => attrs["value"]}

        with {:ok, added} <-
               add_named_key(scope, found, key, attrs["key_settings"], :numbered),
             :ok <- take_key_number(added.secret_id, value_id),
             do: {:ok, added}

      nil ->
        new_key_provider(scope, provider, reach, attrs, value_id)
    end
  end

  # The key group of a new key of `provider` with the plain settings `settings`: none when
  # the settings are refused, and `create_provider/3` then returns the refusal.
  defp key_group(organisation_id, %Provider{} = provider, settings) do
    case settings(provider.description, settings) do
      {:ok, encoded} ->
        group_of(%Connection{
          organisation_id: organisation_id,
          provider_kind: provider.name,
          chain: "organisation",
          settings: encoded
        })

      {:error, _refusal} ->
        []
    end
  end

  # The providers of the key group of `provider` (`Apiary.ModelKeys.Group.of/2`), intact
  # and whose settings still fit the catalogue, oldest first, with their workspaces and
  # keys.
  defp group_of(%Connection{} = provider) do
    Repo.all(
      from c in Group.of(provider),
        order_by: [asc: c.inserted_at, asc: c.id],
        preload: ^preloads(%Connection{provider_kind: ""})
    )
    |> Enum.filter(&(intact?(&1) and match?({:ok, _provider}, provider(&1))))
  end

  defp same_reach?(%Connection{applies_to: "all"}, :all), do: true

  # Both sorted: `ids` by `key_reach/2`, a provider's by `workspace_ids_of/1`.
  defp same_reach?(%Connection{applies_to: "selected"} = connection, ids) when is_list(ids),
    do: workspace_ids_of(connection) == ids

  defp same_reach?(%Connection{}, _reach), do: false

  defp room?(%Connection{secret: %Secret{values: values}}) when is_list(values),
    do: length(values) < Secrets.max_values()

  defp room?(%Connection{}), do: false

  # The counter of the keys' secret `secret_id` moved up to the number of `value_id`, so
  # `Apiary.Secrets.next_key_id/1` never returns that number again; nothing for a value id
  # with no number (`Apiary.Secrets.Value.key_number/1`).
  defp take_key_number(secret_id, value_id) do
    with number when is_integer(number) <- Value.key_number(value_id) do
      Repo.update_all(
        from(s in Secret, where: s.id == ^secret_id and s.last_key_number < ^number),
        set: [last_key_number: number]
      )
    end

    :ok
  end

  # A new provider with the key: for one workspace, its key a secret of that workspace;
  # else of the organisation. The key's settings are written with it.
  defp new_key_provider(scope, %Provider{} = provider, reach, attrs, value_id) do
    created = %{
      "provider" => provider.name,
      "settings" => attrs["settings"] || %{},
      "keys" => [%{"value_id" => value_id, "value" => attrs["value"]}]
    }

    with {:ok, added} <- insert_for_reach(scope, created, reach, []),
         {:ok, _setting} <- put_key_setting(added, value_id, attrs["key_settings"]),
         do: {:ok, added}
  end

  # A new provider, `created` as `insert_provider/5` takes it, for `reach`: for one
  # workspace, its keys a secret of that workspace; else of the organisation.
  defp insert_for_reach(scope, created, reach, keys_opts) do
    case reach do
      [workspace_id] ->
        workspace = Repo.get!(Workspace, workspace_id)

        insert_provider(
          %{scope | workspace: workspace},
          created,
          :workspace,
          :numbered,
          keys_opts
        )

      :all ->
        insert_provider(
          scope,
          Map.put(created, "applies_to", "all"),
          :organisation,
          :numbered,
          keys_opts
        )

      ids ->
        insert_provider(
          scope,
          Map.merge(created, %{"applies_to" => "selected", "workspace_ids" => ids}),
          :organisation,
          :numbered,
          keys_opts
        )
    end
  end

  @doc """
  set_provider_key/5 replaces the value of a model provider's key with the value id
  `value_id` (`provider.write`) by `value` without the whitespace at its ends
  (`String.trim/1`; for a provider whose keys are logins, the sign-in of a device sign-in,
  `t:Apiary.ModelKeys.Login.parsed/0`, and any text is refused with "is invalid"), and,
  with `settings`, its settings, in one transaction, which also deletes the key's states
  (`Apiary.ModelKeys.clear_states/2`): the new value is out of cooldown. The details of
  its `provider_keys_changed` entry have `value_set: true`. `{:ok, provider}`, or
  `{:error, refusal}` as `Apiary.Secrets.set_value/5` returns, or a changeset of the
  settings, which leaves the value and the states as they were.
  """
  @spec set_provider_key(
          Scope.t(),
          Connection.t(),
          String.t(),
          String.t() | Login.parsed(),
          map | nil
        ) ::
          {:ok, Connection.t()} | {:error, refusal}
  def set_provider_key(
        %Scope{} = scope,
        %Connection{} = provider,
        value_id,
        value,
        settings \\ nil
      ),
      do:
        write_keys(
          scope,
          provider,
          fn scope, secret, current ->
            with :ok <- set_key(scope, secret, current, value_id, trim_key(value)),
                 {:ok, _setting} <- put_key_setting(current, value_id, settings),
                 do:
                   {:ok,
                    %{
                      details: %{
                        value_id: value_id,
                        identity: Identity.for_value_id(current, value_id),
                        value_set: true
                      }
                    }}
          end
        )

  @doc """
  set_provider_key_of_row/4 replaces the value of the model provider's key whose value has
  the row id `row_id` (`secret_values.id`) by `value`, as `set_provider_key/5` does for a
  value id. The key is looked up by its row id in the transaction that writes, and not by
  the value id of a `provider` that a page read earlier: a key that was deleted and added
  again has the same value id and another row id, and is not written. `{:error,
  :not_found}` for a row id that is not a key of the provider; any other result as
  `set_provider_key/5`.
  """
  @spec set_provider_key_of_row(
          Scope.t(),
          Connection.t(),
          Ecto.UUID.t(),
          String.t() | Login.parsed()
        ) :: {:ok, Connection.t()} | {:error, refusal}
  def set_provider_key_of_row(%Scope{} = scope, %Connection{} = provider, row_id, value),
    do:
      write_keys(scope, provider, fn scope, secret, current ->
        with %Value{value_id: value_id} <-
               Enum.find(current.secret.values, &(&1.id == row_id)) || {:error, :not_found},
             :ok <- set_key(scope, secret, current, value_id, trim_key(value)),
             do:
               {:ok,
                %{
                  details: %{
                    value_id: value_id,
                    identity: Identity.for_value_id(current, value_id),
                    value_set: true
                  }
                }}
      end)

  @doc """
  update_provider_key/4 changes a model provider's key with the value id `value_id`
  (`provider.write`): `attrs` has its new `value_id`, which renames it
  (`Apiary.Secrets.rename_value/5`), its `settings`
  (`Apiary.ModelKeys.Setting.changeset/3`, with the provider's limit windows) and,
  optionally, its new `value`. A rename keeps the settings and the states, which are the
  value's row's; the new value id must be one no key of the provider's kind in the
  organisation has, else the error "is already the name of another key" on `value_id`, and
  it must not be of the form `key-<n>`, which only `add_key/2` sets, else "Choose another
  name: Qory Apiary gives names like key-3 to new keys." on `value_id`; a rename of the
  default key moves the default with it. The `value` loses the whitespace at its ends
  (`String.trim/1`). A `value` that is nil or then empty keeps the value and its states;
  any other replaces the value and deletes the states, as `set_provider_key/5` does, and
  the details of the entry then have `value_set: true`. The value, the name and the
  settings are written in one transaction, and a save that changes none of them leaves no
  entry.
  `{:ok, provider}`, or `{:error, refusal}`: `:not_found` for a value id the provider's
  keys do not have, a refusal of the value as `Apiary.Secrets.set_value/5` returns, a
  refusal of the rename as `Apiary.Secrets.rename_value/5` returns, or a changeset of the
  settings; each leaves the key as it was.

  With `applies_to`, `all` or `selected`, and with `selected`, `workspace_ids`, as
  `add_key/2` takes them, the key then serves those workspaces, in the same transaction
  under the organisation's integrations lock. For other workspaces than the provider's,
  the key moves to the provider that `add_key/2` would choose for them, else to a new
  one, as `add_key/2` makes it: it keeps its value id, its value, its settings, its
  states, its rejection and its sign-in. It is then removed from `provider` as
  `remove_key/3` removes it, and `{:ok, provider}` has the provider the key moved to.
  A workspace the person does not reach stays as the provider has it; when the key moves,
  one marked for deletion goes. A save with the provider's workspaces less the ones
  marked for deletion moves nothing; a marked workspace in `workspace_ids` returns
  `{:error, :workspace_not_found}`. For a key of every workspace, `selected` from a
  person who does not reach every workspace returns `{:error, :forbidden}`. A move of a
  key of a provider that fails its integrity code returns
  `{:error, {:integrity, [public_id]}}` before any write. The other errors of the
  workspaces are `add_key/2`'s, those of the removal `remove_key/3`'s, and each leaves
  every key as it was.
  """
  @spec update_provider_key(Scope.t(), Connection.t(), String.t(), map) ::
          {:ok, Connection.t()} | {:error, refusal}
  def update_provider_key(%Scope{} = scope, %Connection{} = provider, value_id, attrs) do
    attrs = stringify(attrs)

    if Map.has_key?(attrs, "applies_to"),
      do: update_and_move(scope, provider, value_id, attrs),
      else: update_key(scope, provider, value_id, attrs)
  end

  defp update_key(scope, provider, value_id, attrs) do
    new_value_id = Value.normalise_value_id(attrs["value_id"])
    new_value = blank_to_nil(trim_key(attrs["value"]))

    write_keys(scope, provider, fn scope, secret, current ->
      with %Value{} = value <- Enum.find(current.secret.values, &(&1.value_id == value_id)),
           # Only a rename can be refused for a key in use, with the line the key has now.
           renaming = new_value_id not in [nil, value_id],
           before_line = if(renaming, do: Identity.for_value_id(current, value_id)),
           changeset =
             ModelKeys.change_setting(
               value,
               attrs["settings"] || %{},
               ModelKeys.limit_windows(current)
             ),
           :ok <- valid(changeset),
           :ok <- if(renaming, do: name_free(current, new_value_id), else: :ok),
           :ok <-
             if(new_value, do: set_key(scope, secret, current, value_id, new_value), else: :ok),
           {:ok, current} <- follow_default(scope, current, value_id, renaming && new_value_id),
           {:ok, renamed} <-
             scope
             |> rename_key(secret, current, value_id, new_value_id)
             |> with_identity(before_line),
           {:ok, _setting} <- write_setting(changeset) do
        set = if new_value, do: %{value_set: true}, else: %{}
        shown = (renamed && new_value_id) || value_id

        details =
          Map.merge(set, %{value_id: shown, identity: Identity.for_value_id(current, shown)})

        cond do
          renamed ->
            {:ok,
             %{
               before: %{value_id: value_id},
               after: %{value_id: new_value_id},
               details: details
             }}

          new_value || changeset.changes != %{} ->
            {:ok, %{details: details}}

          true ->
            {:ok, :unchanged}
        end
      else
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp update_and_move(scope, provider, value_id, attrs) do
    write_connection(scope, provider, fn scope, organisation, current ->
      with {:ok, reach} <- move_reach(scope, organisation.id, current, attrs),
           %Value{id: row_id} <-
             Enum.find(current.secret.values, &(&1.value_id == value_id)) ||
               {:error, :not_found},
           # A move of a key of a provider that fails its integrity code: checked on the row
           # read `FOR UPDATE`, before the update writes a new code for it.
           true <-
             (same_reach?(current, reach) or intact?(current)) ||
               {:error, {:integrity, [current.public_id]}},
           {:ok, _updated} <- update_key(scope, current, value_id, attrs),
           do: move_key(scope, current, row_id, reach)
    end)
    |> refreshed()
    |> reload()
    |> without_keys()
  end

  # The workspaces a key serves after Edit key: as `key_reach/3` reads them, with the
  # workspaces of `current` that the person does not reach kept, except those marked for
  # deletion. When that is `current`'s workspaces less the marked ones, it is `current`'s
  # workspaces, and the key does not move. For a key of `current` for every workspace,
  # `selected` from a person who does not reach every workspace returns
  # `{:error, :forbidden}`.
  defp move_reach(scope, organisation_id, current, %{"applies_to" => "selected"} = attrs) do
    reached = scope |> Apiary.Organisations.workspace_scopes() |> Map.keys()

    if current.applies_to == "all" and not Access.reaches_every_workspace_in?(scope) do
      {:error, :forbidden}
    else
      with {:ok, ids} <- workspace_ids(organisation_id, List.wrap(attrs["workspace_ids"])) do
        served = if current.applies_to == "all", do: [], else: workspace_ids_of(current)
        unmarked = unmarked(served)

        case Enum.sort(Enum.uniq(Enum.filter(ids, &(&1 in reached)) ++ (unmarked -- reached))) do
          [] -> {:error, :no_workspace}
          ^unmarked when served != [] -> {:ok, served}
          ids -> {:ok, ids}
        end
      end
    end
  end

  defp move_reach(_scope, _organisation_id, %Connection{applies_to: "all"}, %{
         "applies_to" => "all"
       }),
       do: {:ok, :all}

  defp move_reach(scope, organisation_id, _current, attrs),
    do: key_reach(scope, organisation_id, attrs)

  # The workspaces of `ids` not marked for deletion, sorted as `key_reach/3` sorts.
  defp unmarked([]), do: []

  defp unmarked(ids),
    do:
      Enum.sort(
        Repo.all(
          from w in Workspace, where: w.id in ^ids and is_nil(w.deletion_marked_at), select: w.id
        )
      )

  # The key `row_id` of `provider`, read again after its update, moved to the provider of
  # its group that serves `reach` and has room, else to a new provider; nothing for the
  # reach the provider has. The key's rows go with it (`Apiary.ModelKeys.copy_key_rows/2`),
  # then the key leaves `provider` as `remove_key/3` removes it, so a run that has it
  # loses it as it loses a removed key. `{:ok, provider}`, the provider with the key.
  defp move_key(scope, %Connection{} = provider, row_id, reach) do
    current = Repo.preload(Repo.reload!(provider), preloads(provider), force: true)

    if same_reach?(current, reach) do
      {:ok, current}
    else
      key = Enum.find(current.secret.values, &(&1.id == row_id))

      found =
        current
        |> group_of()
        |> Enum.find(&(&1.id != current.id and same_reach?(&1, reach) and room?(&1)))

      with :ok <- name_free_in(found, key.value_id),
           {:ok, moved_to} <- copy_to(scope, current, key, found, reach),
           %Value{id: copy_id} =
             Repo.get_by!(Value, secret_id: moved_to.secret_id, value_id: key.value_id),
           :ok <- ModelKeys.copy_key_rows(key.id, copy_id),
           {:ok, _removed} <- remove_from(scope, current, key.id),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"provider.write", moved_to, %{
               before: reach_audited(current),
               after: reach_audited(moved_to),
               details: %{
                 change: "provider_key_moved",
                 connection_id: moved_to.public_id,
                 name: moved_to.name,
                 value_id: key.value_id,
                 identity: Identity.for_value_id(moved_to, key.value_id)
               }
             }) do
        {:ok, moved_to}
      end
    end
  end

  # A key keeps its value id when it moves: a provider whose keys have that value id, as
  # two providers made before `add_key/2` can have, takes it only after a rename, else the
  # error on `value_id` that a rename to a taken name has.
  defp name_free_in(nil, _value_id), do: :ok

  defp name_free_in(%Connection{secret: %Secret{values: values}}, value_id) do
    if Enum.any?(values, &(&1.value_id == value_id)),
      do:
        {:error,
         %Value{}
         |> change(value_id: value_id)
         |> add_error(:value_id, dgettext_noop("errors", "is already the name of another key"))},
      else: :ok
  end

  # A copy of `key` in the keys of `found`, or of a new provider for `reach`.
  defp copy_to(scope, current, key, %Connection{} = found, _reach) do
    with {:ok, _secret} <- Secrets.copy_provider_key(scope, current, key.id, found),
         :ok <- take_key_number(found.secret_id, key.value_id),
         do: {:ok, found}
  end

  defp copy_to(scope, current, key, nil, reach) do
    created = %{
      "provider" => current.provider_kind,
      "settings" => Jason.decode!(current.settings),
      "keys" => [%{"value_id" => key.value_id}]
    }

    insert_for_reach(scope, created, reach, copy: {current, key.id})
  end

  # The provider and the workspaces it serves, by public ids, for a move's entry.
  defp reach_audited(%Connection{applies_to: "all"} = provider),
    do: %{connection_id: provider.public_id, applies_to: "all"}

  defp reach_audited(%Connection{} = provider) do
    ids = workspace_ids_of(provider)

    %{
      connection_id: provider.public_id,
      applies_to: provider.applies_to,
      workspace_ids:
        Repo.all(
          from w in Workspace, where: w.id in ^ids, order_by: w.public_id, select: w.public_id
        )
    }
  end

  # A new value of the key `value_id`, which deletes its states. `update_provider_key/4`
  # sets it before a rename, under the value id the key has, and the rename encrypts the
  # new value again under its new value id.
  defp set_key(scope, secret, current, value_id, value) do
    with {:ok, %{"value" => value}, login} <- login_attrs(current, %{"value" => value}),
         {:ok, _secret} <- Secrets.set_value(scope, secret, value_id, value, provider: current),
         :ok <- ModelKeys.clear_states(current.secret_id, value_id),
         do: put_login(current, value_id, login)
  end

  # The value of a key of `provider` as it is stored. For a provider whose keys are logins
  # (`Apiary.ModelKeys.Login`), `attrs["value"]` is the sign-in a device sign-in made
  # (`t:Apiary.ModelKeys.Login.parsed/0`), and the document of it replaces it:
  # `{:ok, attrs, parsed}`. A text is no sign-in: `{:error, changeset}` whose error is on
  # `value` and has none of the text. A blank value is left for the checks of the value.
  # The attrs of any other provider are returned with `nil`.
  defp login_attrs(%Connection{} = provider, attrs) do
    with true <- Login.provider?(provider) do
      case attrs["value"] do
        %Login.Parsed{} = parsed -> {:ok, Map.put(attrs, "value", parsed.document), parsed}
        value when is_binary(value) -> blank_or_refused(attrs, value, %Value{}, :value)
        _other -> {:ok, attrs, nil}
      end
    else
      _not_a_login -> {:ok, attrs, nil}
    end
  end

  defp blank_or_refused(attrs, value, schema, field) do
    if String.trim(value) == "",
      do: {:ok, attrs, nil},
      else: {:error, login_refused(schema, field)}
  end

  # The changeset of a text that is no sign-in: an error on `field` and nothing of the text.
  defp login_refused(schema, field) do
    schema
    |> change()
    |> add_error(field, dgettext_noop("errors", "is invalid"))
    |> Map.put(:action, :validate)
  end

  # The keys a new provider is created with: for a provider whose keys are logins, each
  # key's sign-in replaced by its document, with the logins by value id;
  # `{:error, changeset}` with the refusal on the keys' secret's `values` for a text.
  defp login_keys(%Provider{name: name}, keys) do
    if Login.provider?(name), do: read_logins(keys, [], %{}), else: {:ok, keys, %{}}
  end

  defp read_logins([], stored, logins), do: {:ok, Enum.reverse(stored), logins}

  defp read_logins([%{} = key | rest], stored, logins) do
    case key["value"] do
      %Login.Parsed{} = parsed ->
        read_logins(
          rest,
          [Map.put(key, "value", parsed.document) | stored],
          Map.put(logins, Value.normalise_value_id(key["value_id"]), parsed)
        )

      value when is_binary(value) ->
        if String.trim(value) == "",
          do: read_logins(rest, [key | stored], logins),
          else: {:error, login_refused(%Secret{}, :values)}

      _blank ->
        read_logins(rest, [key | stored], logins)
    end
  end

  defp read_logins([other | rest], stored, logins),
    do: read_logins(rest, [other | stored], logins)

  # The login rows of the keys of the secret `secret_id` that `logins` has parsed logins
  # for, by value id; none for nil. `{:error, :login_not_stored}` and no row written when a
  # login matches no key of the secret: the caller's transaction then rolls back, so a key
  # is never left without its row.
  @doc false
  @spec put_logins(Ecto.UUID.t(), %{String.t() => Login.parsed()}) ::
          :ok | {:error, :login_not_stored | Ecto.Changeset.t()}
  def put_logins(_secret_id, logins) when logins == %{}, do: :ok

  def put_logins(secret_id, logins) do
    values =
      Repo.all(
        from v in Value,
          where: v.secret_id == ^secret_id and v.value_id in ^Map.keys(logins),
          select: struct(v, [:id, :organisation_id, :value_id])
      )

    if length(values) == map_size(logins) do
      Enum.reduce_while(values, :ok, fn value, :ok ->
        case Login.put(value, Map.fetch!(logins, value.value_id)) do
          {:ok, _row} -> {:cont, :ok}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
      end)
    else
      {:error, :login_not_stored}
    end
  end

  # The login row of the key `value_id` after its value was written, nothing for a key
  # that is not a login.
  defp put_login(_current, _value_id, nil), do: :ok

  defp put_login(%Connection{secret_id: secret_id}, value_id, parsed),
    do: put_logins(secret_id, %{value_id => parsed})

  @doc """
  trim_key/1 is a model provider's key as the functions here store it: without the
  Unicode whitespace at its ends (`String.trim/1`), the spaces, tabs, newlines and
  no-break spaces that a copy of a key can bring. Any other term is returned as it is.
  Only a provider's keys are trimmed: another secret's value, such as a private key,
  keeps its last newline.
  """
  @spec trim_key(term) :: term
  def trim_key(value) when is_binary(value), do: String.trim(value)
  def trim_key(value), do: value

  defp trim_value(%{"value" => value} = attrs), do: %{attrs | "value" => trim_key(value)}
  defp trim_value(attrs), do: attrs

  defp trim_keys(keys) do
    Enum.map(keys, fn
      %{} = key -> key |> stringify() |> trim_value()
      other -> other
    end)
  end

  # A new name of a key: a valid value id that no key of the provider's kind in the
  # organisation has, as `add_key/2` numbers the keys across the kind, and not of the form
  # `key-<n>`, which only `add_key/2` sets, so a rename never takes a number that a later
  # add would set. The error on `value_id`. It runs under the organisation's integrations
  # lock (`write/2`, through `lock/1`).
  defp name_free(%Connection{} = current, new_value_id) do
    changeset =
      %Value{}
      |> change(value_id: new_value_id)
      |> Value.value_id_changeset(:required)

    value_id = get_field(changeset, :value_id)

    taken =
      changeset.valid? and
        Repo.exists?(
          from c in connections(current.organisation_id),
            join: v in Value,
            on: v.secret_id == c.secret_id,
            where: c.provider_kind == ^current.provider_kind and v.value_id == ^value_id
        )

    cond do
      not changeset.valid? ->
        {:error, changeset}

      key_name?(value_id) ->
        {:error, key_name_refused(changeset)}

      taken ->
        {:error,
         add_error(
           changeset,
           :value_id,
           dgettext_noop("errors", "is already the name of another key")
         )}

      true ->
        :ok
    end
  end

  # Whether `value_id` has the form `key-<n>`, which only `add_key/2` sets, and a key
  # added with no value id gets.
  defp key_name?(value_id) when is_binary(value_id), do: value_id =~ ~r/\Akey-[0-9]+\z/
  defp key_name?(_value_id), do: false

  defp key_name_refused(changeset),
    do:
      add_error(
        changeset,
        :value_id,
        dgettext_noop(
          "errors",
          "Choose another name: Qory Apiary gives names like key-3 to new keys."
        )
      )

  # The value ids `keys` were given, `:numbered` by `add_key/2` or `:given` by a caller,
  # where a `key-<n>` is refused, its error on `value_id`.
  defp given_names(_keys, :numbered), do: :ok

  defp given_names(keys, :given) do
    case Enum.find(List.wrap(keys), &(is_map(&1) and key_name?(given_value_id(&1)))) do
      nil ->
        :ok

      key ->
        {:error, %Value{} |> change(value_id: given_value_id(key)) |> key_name_refused()}
    end
  end

  defp given_value_id(key),
    do: key |> stringify() |> Map.get("value_id") |> Value.normalise_value_id()

  # A rename of the provider's default key moves the default to the new value id first,
  # in the same transaction, so the rename is not refused as a use of the old one.
  defp follow_default(scope, %Connection{default_value_id: value_id} = current, value_id, new)
       when is_binary(new) do
    current
    |> change(default_value_id: new, updated_by_id: scope.user && scope.user.id)
    |> Coded.seal()
    |> Repo.update()
  end

  defp follow_default(_scope, current, _value_id, _new), do: {:ok, current}

  # Adds the line `identity` to the refusal of a key in use that `Apiary.Secrets` returns.
  defp with_identity({:error, {:in_use, uses}}, identity), do: {:error, {:in_use, uses, identity}}
  defp with_identity(result, _identity), do: result

  # A rename of the key `value_id` to `new_value_id`: `{:ok, true}` once renamed,
  # `{:ok, false}` for the same value id.
  defp rename_key(_scope, _secret, _current, value_id, value_id), do: {:ok, false}
  defp rename_key(_scope, _secret, _current, _value_id, nil), do: {:ok, false}

  defp rename_key(scope, secret, current, value_id, new_value_id) do
    with {:ok, _secret} <-
           Secrets.rename_value(scope, secret, value_id, new_value_id, provider: current),
         do: {:ok, true}
  end

  # A settings changeset with no change writes nothing: a key without settings keeps no
  # empty row.
  defp write_setting(%Ecto.Changeset{changes: changes}) when changes == %{}, do: {:ok, nil}
  defp write_setting(changeset), do: Repo.insert_or_update(changeset)

  # The settings of the provider's key `value_id`, its row read in the keys' secret after
  # the write of its value, checked against the provider's limit windows; nothing to
  # write for nil.
  defp put_key_setting(_current, _value_id, nil), do: {:ok, nil}

  defp put_key_setting(%Connection{secret_id: secret_id} = current, value_id, settings) do
    value =
      Repo.one!(
        from v in Value,
          where: v.secret_id == ^secret_id and v.value_id == ^value_id,
          select: struct(v, [:id, :organisation_id])
      )

    value
    |> ModelKeys.change_setting(settings, ModelKeys.limit_windows(current))
    |> write_setting()
  end

  @doc """
  delete_provider_key/3 deletes a model provider's key (`provider.write`).
  `{:ok, provider}`, or `{:error, refusal}` as `Apiary.Secrets.delete_value/4` answers:
  `:last_value` for its only key, or a changeset whose error is on `value_id` for its
  default key or a key a model choice uses.
  """
  @spec delete_provider_key(Scope.t(), Connection.t(), String.t()) ::
          {:ok, Connection.t()} | {:error, refusal}
  def delete_provider_key(%Scope{} = scope, %Connection{} = provider, value_id),
    do:
      write_keys(scope, provider, fn scope, secret, current ->
        # Read before the key goes: the entry has the line the key had.
        identity = Identity.for_value_id(current, value_id)

        with {:ok, _secret} <-
               scope
               |> Secrets.delete_value(secret, value_id, provider: current)
               |> with_identity(identity),
             do:
               {:ok,
                %{
                  before: %{value_id: value_id},
                  details: %{value_id: value_id, identity: identity}
                }}
      end)

  @doc """
  remove_key/3 removes the key of a model provider whose value has the row id `row_id`
  (`secret_values.id`, `provider.write`), in one transaction, found by that row id under
  the provider's row lock:

    * a key that is not the provider's last: its value is deleted
      (`delete_provider_key/3`); for the provider's default key, the key added first of
      the others becomes the default first (`put_default_key/3`);
    * the provider's last key: each model choice and fallback that uses the provider moves
      to another provider of its key group (the same kind, chain and stored settings, as
      `add_key/2` groups keys) that serves the choice's workspace, or, for the
      organisation's default, a provider whose keys are a secret of the organisation and
      that serves every workspace the provider reached; then the provider is deleted with
      its keys' secret, as `delete_provider/2` deletes it, its `provider_deleted` entry
      with the key and the public ids of the providers the choices moved to.

  `{:ok, provider}`, the provider as it was, or `{:error, refusal}`: `:not_found` for a
  row id that is not a key of the provider; `{:last_key, place}` when a choice's place has
  no other provider in the group that it can move to, `place` the workspace, nil for the
  organisation's default, which writes nothing;
  `{:provider_in_use, %{places: [], runs: run_public_ids}}` while a run that may still
  read the provider's keys uses it (`delete_provider/2`).
  """
  @spec remove_key(Scope.t(), Connection.t(), Ecto.UUID.t()) ::
          {:ok, Connection.t()} | {:error, refusal}
  def remove_key(%Scope{} = scope, %Connection{provider_kind: kind} = provider, row_id)
      when is_binary(kind) do
    write_connection(scope, provider, fn scope, _organisation, current ->
      remove_from(scope, current, row_id)
    end)
    |> refreshed()
    |> without_keys()
  end

  def remove_key(%Scope{}, %Connection{}, _row_id), do: {:error, :not_found}

  # The key `row_id` removed from `current`, a provider read under its row lock, as
  # `remove_key/3` removes it; `move_key/4` removes a moved key with it.
  defp remove_from(scope, current, row_id) do
    values = (current.secret && current.secret.values) || []

    case Enum.find(values, &(&1.id == row_id)) do
      nil -> {:error, :not_found}
      %Value{} = key when length(values) == 1 -> remove_last(scope, current, key)
      %Value{} = key -> remove_one(scope, current, key, values)
    end
  end

  defp remove_one(scope, current, %Value{} = key, values) do
    with {:ok, current} <- default_elsewhere(scope, current, key, values),
         {:ok, _provider} <- delete_provider_key(scope, current, key.value_id),
         do: {:ok, current}
  end

  # The provider with another of its keys as its default when `key` is the default: the
  # key added first of the others.
  defp default_elsewhere(
         scope,
         %Connection{default_value_id: id} = current,
         %Value{value_id: id},
         values
       ) do
    other =
      values
      |> Enum.reject(&(&1.value_id == id))
      |> Enum.min_by(&DateTime.to_unix(&1.inserted_at, :microsecond))

    put_default_key(scope, current, other.value_id)
  end

  defp default_elsewhere(_scope, current, _key, _values), do: {:ok, current}

  defp remove_last(scope, current, %Value{} = key) do
    identity = Identity.for_value_id(current, key.value_id)

    # The other providers of the group with at least one key.
    others =
      current
      |> group_of()
      |> Enum.filter(&(&1.id != current.id and match?(%Secret{values: [_ | _]}, &1.secret)))

    reach = if current.applies_to == "all", do: :all, else: workspace_ids_of(current)

    # The organisation's default (place nil) moves only to a provider whose keys are a
    # secret of the organisation, as a save of the default checks.
    shared = Enum.filter(others, &is_nil(&1.secret.workspace_id))

    target = fn
      nil -> serving(shared, reach)
      workspace_id -> serving(others, workspace_id)
    end

    with :ok <- ModelChoices.delete_leftovers_using(scope, current),
         {:ok, moved_to} <- ModelChoices.move_from(scope, current, target),
         :ok <- not_used(ModelChoices.places_using(current), live_runs(current)),
         {:ok, deleted} <- delete_with_keys(scope, current),
         {:ok, _entry} <-
           Audit.record(Repo, scope, :"provider.write", deleted, %{
             before: provider_audited(current),
             details: %{
               change: "provider_deleted",
               connection_id: deleted.public_id,
               kind: deleted.kind,
               name: deleted.name,
               provider: deleted.provider_kind,
               value_id: key.value_id,
               identity: identity,
               moved_to: Enum.map(moved_to, & &1.public_id)
             }
           }) do
      {:ok, deleted}
    end
  end

  # The provider of `others` that serves a workspace (its id), or every workspace of
  # `ids` (a list), or every workspace (`:all`); nil for none.
  defp serving(others, :all), do: Enum.find(others, &(&1.applies_to == "all"))

  defp serving(others, ids) when is_list(ids),
    do: Enum.find(others, &(&1.applies_to == "all" or ids -- workspace_ids_of(&1) == []))

  defp serving(others, workspace_id) when is_binary(workspace_id),
    do: serving(others, [workspace_id])

  # A write to a provider's keys, under the provider's locks. `fun` takes the scope, the
  # keys' secret and the provider, as `Apiary.Secrets` writes it, and returns `{:ok, change}`,
  # where `change` has the `before`, `after` and `details` that the provider's
  # `provider_keys_changed` entry records, or `{:ok, :unchanged}`, which records none. A key
  # that is the default key stays, with the reason on `value_id`.
  # A refusal of a key in use has the identity line of the key as a third element
  # (`with_identity/2`): the failed statement ends this transaction's reads, so the line is
  # read before the write.
  defp write_keys(scope, provider, fun) do
    write_provider(scope, provider, fn scope, _organisation, current ->
      # The level the keys are at is read again from the secret's row
      # (`Apiary.Secrets`): the organisation's, or a workspace's.
      secret = %Secret{id: current.secret_id, organisation_id: current.organisation_id}

      case fun.(scope, secret, current) do
        {:ok, :unchanged} ->
          {:ok, current}

        {:ok, change} ->
          details =
            Map.merge(Map.get(change, :details, %{}), %{
              change: "provider_keys_changed",
              connection_id: current.public_id,
              name: current.name
            })

          with {:ok, _entry} <-
                 Audit.record(
                   Repo,
                   scope,
                   :"provider.write",
                   current,
                   Map.put(change, :details, details)
                 ),
               do: {:ok, current}

        {:error, {:in_use, [%{kind: :model_provider} | _uses], identity}} ->
          {:error,
           current
           |> change()
           |> add_error(
             :value_id,
             dgettext_noop(
               "errors",
               "Choose another default key for %{provider} first: %{value} is its default key."
             ),
             provider: current.name,
             value: identity
           )}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  # The keys' secret of a provider, its row locked `FOR SHARE`, with its values' ids.
  defp keys_secret(%Connection{secret_id: secret_id, organisation_id: organisation_id}) do
    Repo.one!(
      from s in Secret,
        where: s.id == ^secret_id and s.organisation_id == ^organisation_id,
        lock: "FOR SHARE",
        preload: [values: ^from(v in Value, select: struct(v, [:id, :value_id]))]
    )
  end

  defp provider_audited(%Connection{} = provider),
    do:
      Map.take(provider, [
        :kind,
        :name,
        :applies_to,
        :settings,
        :provider_kind,
        :description_ref,
        :default_value_id,
        :chain
      ])

  # A write to one provider: `write_connection/3`, for a provider only.
  defp write_provider(scope, %Connection{provider_kind: kind} = provider, fun)
       when is_binary(kind) do
    write_connection(scope, provider, fun) |> reload() |> without_keys()
  end

  defp write_provider(_scope, %Connection{}, _fun), do: {:error, :not_found}

  # A refusal handed back from a write of a provider keeps no key value. Ecto keeps every
  # param a changeset was cast from, so the keys of a form stay in `params` unless they
  # are dropped here, under a string or an atom key. The `changes` hold none: a provider's
  # own changeset has no key, and the changeset of the keys' secret comes scrubbed from
  # `Apiary.Secrets`.
  @key_params ["keys", "key", "value", "values", :keys, :key, :value, :values]

  defp without_keys({:error, %Ecto.Changeset{params: params} = changeset}) when is_map(params),
    do: {:error, %{changeset | params: Map.drop(params, @key_params)}}

  defp without_keys(other), do: other

  # A provider and everything of it need `factory` and `secrets` shown to the scope.
  defp providers_shown(scope) do
    if Features.visible?(scope, :factory) and Features.visible?(scope, :secrets),
      do: :ok,
      else: {:error, :not_found}
  end

  defp provider_shown(scope, %Connection{provider_kind: kind}) when is_binary(kind),
    do: providers_shown(scope)

  defp provider_shown(_scope, %Connection{}), do: :ok

  # Only the organisation's chain is changed.
  defp organisation_chain(%Connection{chain: "organisation"}), do: :ok
  defp organisation_chain(%Connection{}), do: {:error, :forbidden}

  ## Service definitions

  @doc """
  create_service_definition/2 writes a service definition of the scope's organisation
  (`connection.write`): `definition`, a map or its JSON, checked by
  `Apiary.Kinds.ServiceDefinition`, its `key` unique in the organisation.
  `{:ok, definition}`, or `{:error, refusal}`: `{:definition_invalid, problems}`, a
  changeset whose error is on `key`.
  """
  @spec create_service_definition(Scope.t(), map | String.t()) ::
          {:ok, ServiceDefinition.t()} | {:error, refusal}
  def create_service_definition(%Scope{} = scope, definition) do
    write(scope, fn scope, organisation ->
      with :ok <- Access.check(scope, :"connection.write", organisation),
           {:ok, decoded} <- checked_definition(definition) do
        %ServiceDefinition{
          id: Ecto.UUID.generate(),
          public_id: PublicId.generate("svc"),
          organisation_id: organisation.id,
          created_by_id: scope.user && scope.user.id,
          updated_by_id: scope.user && scope.user.id
        }
        |> definition_changeset(decoded)
        |> insert_sealed()
        |> with_entry(scope, "definition_created")
      end
    end)
  end

  @doc """
  update_service_definition/3 replaces a definition of the organisation
  (`connection.write`); every connection that names it takes it from now on.
  `{:ok, definition}`, or `{:error, refusal}`.
  """
  @spec update_service_definition(Scope.t(), ServiceDefinition.t(), map | String.t()) ::
          {:ok, ServiceDefinition.t()} | {:error, refusal}
  def update_service_definition(%Scope{} = scope, %ServiceDefinition{id: id}, definition) do
    write(scope, fn scope, organisation ->
      with %ServiceDefinition{} = current <-
             Repo.one(
               from d in definitions(organisation.id), where: d.id == ^id, lock: "FOR UPDATE"
             ),
           :ok <- Access.check(scope, :"connection.write", current),
           {:ok, decoded} <- checked_definition(definition) do
        current
        |> definition_changeset(decoded)
        |> put_change(:updated_by_id, scope.user && scope.user.id)
        |> Coded.seal()
        |> Repo.update()
        |> with_entry(scope, "definition_updated")
      else
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  delete_service_definition/2 deletes a definition of the organisation
  (`connection.write`): `{:ok, definition}`, or `{:error, refusal}`,
  `{:in_use, public_ids}` while a connection names it.
  """
  @spec delete_service_definition(Scope.t(), ServiceDefinition.t()) ::
          {:ok, ServiceDefinition.t()} | {:error, refusal}
  def delete_service_definition(%Scope{} = scope, %ServiceDefinition{id: id}) do
    write(scope, fn scope, organisation ->
      with %ServiceDefinition{} = current <-
             Repo.one(
               from d in definitions(organisation.id), where: d.id == ^id, lock: "FOR UPDATE"
             ),
           :ok <- Access.check(scope, :"connection.write", current),
           [] <-
             Repo.all(
               from c in connections(organisation.id),
                 where: c.service_definition_id == ^id,
                 select: c.public_id
             ) do
        current |> Repo.delete() |> with_entry(scope, "definition_deleted")
      else
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
        users when is_list(users) -> {:error, {:in_use, users}}
      end
    end)
  end

  defp checked_definition(definition) when is_binary(definition) do
    case Jason.decode(definition) do
      {:ok, decoded} -> checked_definition(decoded)
      {:error, _} -> {:error, {:definition_invalid, [{:definition_invalid, ""}]}}
    end
  end

  defp checked_definition(definition) do
    case Definition.validate(definition) do
      {:ok, definition} -> {:ok, definition}
      {:error, problems} -> {:error, {:definition_invalid, problems}}
    end
  end

  defp definition_changeset(%ServiceDefinition{} = row, decoded) do
    row
    |> change(
      key: decoded["key"],
      title: decoded["title"],
      definition: Definition.encode(decoded),
      digest: Definition.digest(decoded)
    )
    |> unique_constraint(:key,
      name: :service_definitions_key_index,
      message: dgettext_noop("errors", "is already the key of a service of this organisation")
    )
  end

  defp with_entry({:ok, %ServiceDefinition{} = definition}, scope, change) do
    with {:ok, _entry} <-
           Audit.record(Repo, scope, :"connection.write", definition, %{
             details: %{
               change: change,
               definition_id: definition.public_id,
               key: definition.key,
               name: definition.title,
               digest: definition.digest
             }
           }),
         do: {:ok, definition}
  end

  defp with_entry({:error, reason}, _scope, _change), do: {:error, reason}

  ## The write

  # A write to the scope's organisation, in the lock order of docs/access.md: the
  # organisation `FOR SHARE` (`Access.lock_places/1`), the membership read again under its
  # lock (`Access.reload/2`), then the organisation's integrations lock (`lock/1`); then
  # `fun`, which asks its question first. The changes of the security policy that `fun`
  # made (`rendered/4`) are announced once the write has committed.
  defp write(%Scope{organisation: %Organisation{id: id}} = scope, fun) do
    Repo.transact(fn ->
      :ok = Access.lock_places(scope)
      scope = Access.reload(scope, lock: :share)
      :ok = lock(id)

      case Repo.get(Organisation, id) do
        %Organisation{} = organisation -> fun.(scope, organisation)
        nil -> {:error, :not_found}
      end
    end)
    |> case do
      {:ok, {:rendered, value, changes}} ->
        Policy.announce(changes)
        {:ok, value}

      result ->
        result
    end
  end

  defp write(_scope, _fun), do: {:error, :not_found}

  @doc """
  write_action/1 is the action of `Apiary.Access` that a write to `connection` is asked
  under, by its kind: `provider.write` for a model provider, `runtime.write` for a
  runtime, and `connection.write` for an integration and a service.
  """
  @spec write_action(Connection.t()) :: Access.action()
  def write_action(%Connection{provider_kind: kind}) when is_binary(kind), do: :"provider.write"
  def write_action(%Connection{kind: "runtime"}), do: :"runtime.write"
  def write_action(%Connection{}), do: :"connection.write"

  @doc """
  lock/1 takes the integrations lock of the organisation `organisation_id` for the rest
  of the transaction: a transaction-level advisory lock on the key
  `hashtextextended('apiary:integrations:' || organisation_id, 0)`. Every write to the
  organisation's integrations takes it after the organisation's rows and the
  membership, so two take turns, and the overlap check of the second sees the first.
  Called inside a transaction; `:ok`.
  """
  @spec lock(Ecto.UUID.t()) :: :ok
  def lock(organisation_id) do
    {:ok, uuid} = Ecto.UUID.dump(organisation_id)

    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended('apiary:integrations:' || $1::uuid::text, 0))",
      [uuid]
    )

    :ok
  end

  # A write to one connection: the row read again under `FOR UPDATE` in the scope's
  # organisation, with its workspaces, then asked of under the action for its kind
  # (`write_action/1`). A provider needs its features first, and is of the organisation's
  # chain.
  defp write_connection(scope, %Connection{id: id}, fun) do
    write(scope, fn scope, organisation ->
      with %Connection{} = current <-
             Repo.one(
               from c in connections(organisation.id), where: c.id == ^id, lock: "FOR UPDATE"
             ),
           :ok <- provider_shown(scope, current),
           :ok <- Access.check(scope, write_action(current), current),
           :ok <- organisation_chain(current) do
        current = Repo.preload(current, preloads(current))
        workspaces = lock_rendered(current, organisation.id)

        with {:ok, value} <- fun.(scope, organisation, current),
             do: rendered(scope, workspaces, current, value)
      else
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  ## The security policy of the workspaces an integration reaches

  # An integration's hosts are in the policy of every workspace it reaches
  # (`egress_hosts/1`), so a change to an integration other than a provider renders those
  # workspaces again. Before the change writes, every workspace of the organisation is
  # locked `FOR NO KEY UPDATE`, in the order of their ids, as a write of their policy
  # locks them (`Apiary.Policy`): a write of a workspace's rules then comes wholly before
  # the change, and the render sees it, or wholly after it, and its render sees the change.
  # The locks come after the integrations lock and the connection's row: no write that
  # holds a workspace waits for either (docs/access.md, The lock order).
  defp lock_rendered(%Connection{kind: "integration", provider_kind: nil}, organisation_id) do
    Repo.all(
      from w in Workspace,
        where: w.organisation_id == ^organisation_id and is_nil(w.purge_started_at),
        order_by: [asc: w.id],
        lock: "FOR NO KEY UPDATE"
    )
  end

  defp lock_rendered(%Connection{}, _organisation_id), do: []

  # Once the change is written: every managed workspace the integration reached before it,
  # `before` (nil for a new one), or reaches after it, rendered again
  # (`Apiary.Policy.rerender_in/3`). `{:ok, {:rendered, value, changes}}` for `write/2` to
  # announce, or the first render's failure, which rolls the change back.
  defp rendered(_scope, [], _before, value), do: {:ok, value}

  defp rendered(scope, workspaces, before, %Connection{id: id} = value) do
    reached = reach(before) ++ reach(Repo.get(Connection, id))
    all = :all in reached

    workspaces
    |> Enum.filter(&(all or &1.id in reached))
    |> Enum.reduce_while({:ok, []}, fn workspace, {:ok, changes} ->
      case Policy.rerender_in(workspace, scope) do
        {:ok, more} -> {:cont, {:ok, changes ++ more}}
        {:error, _error} = refusal -> {:halt, refusal}
      end
    end)
    |> case do
      {:ok, changes} -> {:ok, {:rendered, value, changes}}
      refusal -> refusal
    end
  end

  # The workspaces a connection reaches: `[:all]`, or the ids it lists; `[]` for none.
  defp reach(nil), do: []
  defp reach(%Connection{applies_to: "all"}), do: [:all]

  defp reach(%Connection{workspaces: workspaces}) when is_list(workspaces),
    do: Enum.map(workspaces, & &1.workspace_id)

  defp reach(%Connection{} = connection), do: workspace_ids_of(connection)

  defp reload({:ok, %Connection{id: id} = connection}) do
    connection =
      Repo.one!(from c in Connection, where: c.id == ^id, preload: ^preloads(connection))

    {:ok, %{connection | intact: intact?(connection)}}
  end

  defp reload(other), do: other

  defp valid(%Ecto.Changeset{valid?: true}), do: :ok
  defp valid(%Ecto.Changeset{} = changeset), do: {:error, changeset}

  defp stringify(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value
end
