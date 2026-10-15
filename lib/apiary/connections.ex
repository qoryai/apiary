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

  Nothing here links a stored secret to a connection or holds a secret, and the audit
  trail never carries a value.

  ## Where a connection applies

  `applies_to` is `all`, every workspace of the organisation, those made later included,
  or `selected`, the workspaces it lists (`Apiary.Connections.ConnectionWorkspace`), each
  of the organisation; a workspace's purge takes it from every list, so a `selected`
  connection may list none. A save that would make two connections collide in a
  workspace where both apply, the same runtime, the same integration, or a host in
  common, is refused, `{:error, {:overlap, public_ids}}` (`Apiary.Connections.Overlap`).

  ## Integrity

  Every connection, release and custom definition carries an integrity code
  (`Apiary.Kinds.Coded`). A listing marks each connection `intact`;
  `list_for_rendering/1` refuses the connections that apply to a workspace when one of
  them, its release or its definition fails its code, with an error in the log.

  ## Who, and the trail

  Reading is `connection.read`, every member; every change is `connection.write`, owners
  and admins, both asked of the organisation, with one `connection.write` entry in the
  organisation's audit trail, in its transaction, `details.change` saying what. A write
  locks the scope's organisation `FOR SHARE` and reads the membership again under its
  locks (`Apiary.Access.lock_places/1`, `Apiary.Access.reload/2`, docs/access.md), then
  takes the organisation's integrations lock, a transaction-level advisory lock on
  `apiary:integrations:` and the organisation's id: two writes to one organisation take
  turns, so the overlap check sees every write before it.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Changeset
  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{Access, Audit, Integrations, LogMetadata, PublicId, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Connections.{Connection, ConnectionWorkspace, Overlap, ServiceDefinition}
  alias Apiary.Integrations.{Description, Release}
  alias Apiary.Kinds.{CanonicalJSON, Coded, Runtimes, Services}
  alias Apiary.Kinds.ServiceDefinition, as: Definition
  alias Apiary.Organisations.{Organisation, Workspace}

  @typedoc """
  Why a change is refused: the reasons of `Apiary.Access`, a changeset, or a code with
  what it is about: `{:overlap, public_ids}`, `{:in_use, public_ids}`, `:runtime_unknown`,
  `:service_unknown`, `:release_not_ready`, `:integration_source_refused`,
  `:workspace_not_found`, `{:integration_source_mismatch, why}`, and the description's
  `{:integration_settings_not_allowed, names}`, `{:integration_settings_invalid, errors}`,
  `{:integration_settings_too_large, max}` and `{:integration_argument_not_allowed, roles}`;
  for a definition, `{:definition_invalid, problems}`.
  """
  @type refusal :: Access.reason() | Ecto.Changeset.t() | atom | {atom, term}

  ## Reading

  @doc """
  list_connections/1 is the scope's organisation's connections, by kind and name, each
  with its workspaces, its release and its definition, and `intact` set:
  `{:ok, connections}` for a reader who may `connection.read`.
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
  `{:error, reason}`, `:not_found` for one the organisation does not have.
  """
  @spec get_connection(Scope.t(), term) :: {:ok, Connection.t()} | {:error, Access.reason()}
  def get_connection(%Scope{} = scope, public_id) do
    with {:ok, organisation} <- may_read(scope),
         true <- PublicId.valid?("con", public_id),
         %Connection{} = connection <-
           Repo.one(from c in connections(organisation.id), where: c.public_id == ^public_id) do
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
  def description(%Connection{kind: "integration", release: %Release{} = release}),
    do: Integrations.description(release)

  def description(%Connection{kind: "integration"} = connection),
    do: connection |> Repo.preload(:release) |> description()

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

  defp load_all(organisation_id) do
    Repo.all(
      from c in connections(organisation_id),
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
    Coded.verify(connection) == :ok and part_intact?(connection)
  end

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
  release or its definition is not as it was written, with an error in the log. It asks
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

  ## Connections

  @doc """
  create_runtime/2 sets up a runtime of the catalogue (`connection.write`): `attrs` has
  `runtime`, its name, `applies_to` (`all` by default) and `workspace_ids`, the workspaces
  of a `selected` one, each of the organisation, else `:workspace_not_found`. `{:ok, connection}`, or `{:error, refusal}`: `:runtime_unknown`.
  """
  @spec create_runtime(Scope.t(), map) :: {:ok, Connection.t()} | {:error, refusal}
  def create_runtime(%Scope{} = scope, attrs) do
    attrs = stringify(attrs)

    with {:ok, runtime} <- fetch_runtime(attrs["runtime"]) do
      create(scope, attrs, fn connection ->
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

    create(scope, attrs, fn connection, organisation_id ->
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

    create(scope, attrs, fn connection, organisation_id ->
      with {:ok, title, fields} <- service(organisation_id, attrs) do
        {:ok,
         struct(
           %{connection | kind: "service", name: blank_to_nil(attrs["name"]) || title},
           fields
         )}
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

  # A new connection: `build` fills in its kind from the attributes, with the organisation
  # when it needs to read from it; then the name, where it applies, the overlap check, the
  # row, its workspaces and the entry, in one write.
  defp create(scope, attrs, build) do
    write(scope, fn scope, organisation ->
      new = %Connection{
        id: Ecto.UUID.generate(),
        public_id: PublicId.generate("con"),
        organisation_id: organisation.id,
        created_by_id: scope.user && scope.user.id,
        updated_by_id: scope.user && scope.user.id
      }

      with :ok <- Access.check(scope, :"connection.write", organisation),
           {:ok, connection} <- built(build, new, organisation.id),
           changeset = connection |> change() |> attrs_changeset(connection, attrs),
           :ok <- valid(changeset),
           {:ok, workspace_ids} <-
             workspace_ids(organisation.id, connection_reach_ids(changeset, attrs)),
           :ok <- no_overlap(organisation.id, apply_changes(changeset), workspace_ids),
           {:ok, inserted} <- changeset |> Coded.seal() |> Repo.insert(),
           :ok <- insert_workspaces(inserted, workspace_ids),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"connection.write", inserted, %{
               after: audited(inserted),
               details: %{
                 change: "created",
                 connection_id: inserted.public_id,
                 kind: inserted.kind,
                 name: inserted.name
               }
             }) do
        {:ok, inserted}
      end
    end)
    |> reload()
  end

  defp built(build, new, _organisation_id) when is_function(build, 1), do: {:ok, build.(new)}
  defp built(build, new, organisation_id), do: build.(new, organisation_id)

  defp attrs_changeset(changeset, %Connection{kind: kind}, attrs) do
    fields = if kind == "service", do: [:name, :applies_to], else: [:applies_to]
    fields = if kind == "integration", do: [:argument | fields], else: fields

    changeset
    |> cast(attrs, fields, empty_values: [nil])
    |> update_change(:name, &String.trim/1)
    |> update_change(:argument, &blank_to_nil/1)
    |> validate_required([:name, :applies_to])
    |> validate_inclusion(:applies_to, Connection.applies())
    |> validate_length(:name, min: 1, max: 128, count: :codepoints)
    |> validate_format(:name, ~r/\A[^[:cntrl:]]*\z/u,
      message: dgettext_noop("errors", "must not contain control characters")
    )
    |> validate_length(:argument, min: 1, max: 4096, count: :bytes)
  end

  defp connection_reach_ids(changeset, attrs) do
    if get_field(changeset, :applies_to) == "selected",
      do: List.wrap(attrs["workspace_ids"]),
      else: []
  end

  @doc """
  update_connection/3 changes a connection (`connection.write`): `applies_to`; a
  service's `name`; an integration's `settings` and `argument`, checked against its
  description. Switching to `selected` keeps the workspaces it lists.
  `{:ok, connection}`, or `{:error, refusal}`. A change that changes nothing leaves no
  entry.
  """
  @spec update_connection(Scope.t(), Connection.t(), map) ::
          {:ok, Connection.t()} | {:error, refusal}
  def update_connection(%Scope{} = scope, %Connection{} = connection, attrs) do
    attrs = stringify(attrs)

    write_connection(scope, connection, fn scope, organisation, current ->
      changeset =
        current
        |> change(updated_by_id: scope.user && scope.user.id)
        |> attrs_changeset(current, attrs)

      with :ok <- valid(changeset),
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
  def change_release(%Scope{} = scope, %Connection{kind: "integration"} = connection, release_id) do
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
  put_workspace/3 makes a connection apply to the workspace `workspace_id` of the scope's
  organisation (`connection.write`), not marked for deletion: `{:ok, connection}`, or
  `{:error, refusal}`, `:workspace_not_found`. A workspace it lists already is kept, with
  no entry.
  """
  @spec put_workspace(Scope.t(), Connection.t(), term) ::
          {:ok, Connection.t()} | {:error, refusal}
  def put_workspace(%Scope{} = scope, %Connection{} = connection, workspace_id) do
    write_connection(scope, connection, fn scope, organisation, current ->
      listed = workspace_ids_of(current)

      with {:ok, [workspace_id]} <- workspace_ids(organisation.id, [workspace_id]) do
        if workspace_id in listed,
          do: {:ok, current},
          else: add_workspace(scope, organisation, current, listed, workspace_id)
      end
    end)
    |> reload()
  end

  defp add_workspace(scope, organisation, current, listed, workspace_id) do
    with :ok <- no_overlap(organisation.id, current, [workspace_id | listed]),
         :ok <- insert_workspaces(current, [workspace_id]),
         {:ok, _entry} <-
           Audit.record(Repo, scope, :"connection.write", current, %{
             details: %{
               change: "workspace_added",
               connection_id: current.public_id,
               name: current.name,
               workspace_id: workspace_id
             }
           }),
         do: {:ok, current}
  end

  @doc """
  remove_workspace/3 takes the workspace `workspace_id` from a connection's list
  (`connection.write`): `{:ok, connection}`, or `{:error, refusal}`,
  `:workspace_not_found` for one it does not list.
  """
  @spec remove_workspace(Scope.t(), Connection.t(), term) ::
          {:ok, Connection.t()} | {:error, refusal}
  def remove_workspace(%Scope{} = scope, %Connection{} = connection, workspace_id) do
    write_connection(scope, connection, fn scope, _organisation, current ->
      with {:ok, uuid} <- cast_uuid(workspace_id),
           {1, _} <-
             Repo.delete_all(
               from w in ConnectionWorkspace,
                 where: w.connection_id == ^current.id and w.workspace_id == ^uuid
             ),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"connection.write", current, %{
               details: %{
                 change: "workspace_removed",
                 connection_id: current.public_id,
                 name: current.name,
                 workspace_id: uuid
               }
             }) do
        {:ok, current}
      else
        {0, _} -> {:error, :workspace_not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> reload()
  end

  @doc """
  delete_connection/2 removes a connection with its list of workspaces (`connection.write`):
  `{:ok, connection}`, the connection as it was, or `{:error, refusal}`.
  """
  @spec delete_connection(Scope.t(), Connection.t()) :: {:ok, Connection.t()} | {:error, refusal}
  def delete_connection(%Scope{} = scope, %Connection{} = connection) do
    write_connection(scope, connection, fn scope, _organisation, current ->
      with {:ok, deleted} <- Repo.delete(current),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"connection.write", deleted, %{
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
                 :"connection.write",
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
      # Found before the operator's settings changed, it is still not one to add now.
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
  # holds the organisation's integrations lock, so every write before it is seen.
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
        |> Coded.seal()
        |> Repo.insert()
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
  # `fun`, which asks its question first.
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
  end

  defp write(_scope, _fun), do: {:error, :not_found}

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
  # organisation, with its workspaces, then asked of.
  defp write_connection(scope, %Connection{id: id}, fun) do
    write(scope, fn scope, organisation ->
      with %Connection{} = current <-
             Repo.one(
               from c in connections(organisation.id), where: c.id == ^id, lock: "FOR UPDATE"
             ),
           :ok <- Access.check(scope, :"connection.write", current) do
        fun.(scope, organisation, Repo.preload(current, preloads()))
      else
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp reload({:ok, %Connection{id: id}}) do
    connection = Repo.one!(from c in Connection, where: c.id == ^id, preload: ^preloads())
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
