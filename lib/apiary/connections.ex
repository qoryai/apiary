defmodule Apiary.Connections do
  @moduledoc """
  Connections holds what a workspace sets up for its runs: the runtimes, integrations and
  services the contract calls connections, and the pages call integrations
  (`Apiary.Connections.Connection`), where each applies, and the workspace's own service
  definitions (`Apiary.Connections.ServiceDefinition`).

  ## The kinds

    * A **runtime** connection names a runtime of the catalogue
      (`Apiary.Kinds.Runtimes`), such as `claude`.
    * An **integration** connection is added from a release the workspace found
      (`Apiary.Integrations`), ready and intact, whose source the instance's settings
      still accept, else `integration_source_refused`: it takes the description's name
      and the release's source, its forge's kind, its version and its description digest.
      Its plain `settings` are checked against the description
      (`Apiary.Integrations.Description.check_settings/2`): a secret, or a secret's
      `<name>_file`, is never a setting. Its `argument` must match every pattern of its
      roles. Moving it to another release keeps its source and its name, else
      `integration_source_mismatch`.
    * A **service** connection names its definition, a built-in one by key
      (`Apiary.Kinds.Services`) or the workspace's own, and nothing else: the definition is
      the one source of its hosts, paths, auth and declared secrets.

  The secrets a connection needs are linked to stored secrets by the piece that links
  them; nothing here holds a secret, and the audit trail never carries a value.

  ## Where a connection applies

  `applies_to` is `all`, every repository of the workspace, or `selected`, the
  repositories of its targets (`Apiary.Connections.Target`). A target of an integration
  may also carry the **ways** it is used in that repository, of which there is one,
  `credential` ("Calls its API"), when its description offers it; nil is the same
  (`used_ways/2`). The
  `tool` way ("Uses it as a tool (MCP)") a description may offer is refused. A save that
  would make two connections collide where both apply, the same runtime, the same
  integration, or a host in common, is refused, `{:error, {:overlap, public_ids}}`
  (`Apiary.Connections.Overlap`).

  ## Integrity

  Every connection, release and custom definition carries an integrity code
  (`Apiary.Kinds.Coded`). A listing marks each connection `intact`;
  `list_for_rendering/1`, what renders a run configuration asks, refuses the workspace's
  connections when one of them, its release or its definition fails its code, with an
  error in the log.

  ## Who, and the trail

  Reading is `connection.read`, every member; every change is `connection.write`, owners
  and admins, with one `connection.write` entry in the audit trail, in its transaction,
  `details.change` saying what. A write locks the scope's organisation `FOR SHARE`, the
  workspace `FOR NO KEY UPDATE` and reads the membership again (docs/access.md): two
  writes to one workspace take turns, so the overlap check sees every write before it.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Changeset
  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{Access, Audit, Integrations, LogMetadata, PublicId, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Connections.{Connection, Overlap, ServiceDefinition, Target}
  alias Apiary.Integrations.{Description, Release}
  alias Apiary.Kinds.{CanonicalJSON, Coded, Runtimes, Services}
  alias Apiary.Kinds.ServiceDefinition, as: Definition
  alias Apiary.Organisations.{Organisation, Workspace}

  @typedoc """
  Why a change is refused: the reasons of `Apiary.Access`, a changeset, or a code with
  what it is about: `{:overlap, public_ids}`, `{:in_use, public_ids}`, `:runtime_unknown`,
  `:service_unknown`, `:release_not_ready`, `:integration_source_refused`,
  `:target_not_found`, `:ways_not_allowed`, `{:integration_source_mismatch, why}`, and the
  description's
  `{:integration_settings_not_allowed, names}`, `{:integration_settings_invalid, errors}`,
  `{:integration_settings_too_large, max}` and `{:integration_argument_not_allowed, roles}`;
  for a definition, `{:definition_invalid, problems}`.
  """
  @type refusal :: Access.reason() | Ecto.Changeset.t() | atom | {atom, term}

  # A description may offer the tool way too, but no runner runs it yet, so a connection
  # is used through its credential alone.
  @ways ~w(credential)

  ## Reading

  @doc """
  list_connections/1 is the scope's workspace's connections, by kind and name, each with
  its targets, its release and its definition, and `intact` set: `{:ok, connections}`
  for a reader who may `connection.read`.
  """
  @spec list_connections(Scope.t()) :: {:ok, [Connection.t()]} | {:error, Access.reason()}
  def list_connections(%Scope{} = scope) do
    with {:ok, workspace} <- may_read(scope) do
      {:ok, workspace |> load_all() |> Enum.map(&%{&1 | intact: intact?(&1)})}
    end
  end

  @doc """
  get_connection/2 is the scope's workspace's connection with the public id `public_id`,
  loaded as `list_connections/1` loads it: `{:ok, connection}`, or `{:error, reason}`,
  `:not_found` for one the workspace does not have.
  """
  @spec get_connection(Scope.t(), term) :: {:ok, Connection.t()} | {:error, Access.reason()}
  def get_connection(%Scope{} = scope, public_id) do
    with {:ok, workspace} <- may_read(scope),
         true <- PublicId.valid?("con", public_id),
         %Connection{} = connection <-
           Repo.one(from c in connections(workspace), where: c.public_id == ^public_id) do
      connection = Repo.preload(connection, preloads())
      {:ok, %{connection | intact: intact?(connection)}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  list_service_definitions/1 is the scope's workspace's own service definitions, by key:
  `{:ok, definitions}` for a reader who may `connection.read`.
  """
  @spec list_service_definitions(Scope.t()) ::
          {:ok, [ServiceDefinition.t()]} | {:error, Access.reason()}
  def list_service_definitions(%Scope{} = scope) do
    with {:ok, workspace} <- may_read(scope) do
      {:ok, Repo.all(from d in definitions(workspace), order_by: [asc: d.key])}
    end
  end

  @doc """
  get_service_definition/2 is the scope's workspace's own service definition with the
  public id `public_id`: `{:ok, definition}`, or `{:error, reason}`.
  """
  @spec get_service_definition(Scope.t(), term) ::
          {:ok, ServiceDefinition.t()} | {:error, Access.reason()}
  def get_service_definition(%Scope{} = scope, public_id) do
    with {:ok, workspace} <- may_read(scope),
         true <- PublicId.valid?("svc", public_id),
         %ServiceDefinition{} = definition <-
           Repo.one(from d in definitions(workspace), where: d.public_id == ^public_id) do
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
  `{:ok, description}`, its `publisher` among it, the name to show beside the source's
  owner, and for a URL source the one name a page has; or `{:error, :not_ready}`.
  """
  @spec description(Connection.t()) :: {:ok, Description.t()} | {:error, :not_ready}
  def description(%Connection{kind: "integration", release: %Release{} = release}),
    do: Integrations.description(release)

  def description(%Connection{kind: "integration"} = connection),
    do: connection |> Repo.preload(:release) |> description()

  @doc """
  used_ways/2 is the ways the integration `connection` is used in at the repository
  `target_id`: the ways its target there carries, or, where it carries none, the
  credential way when its description offers it, never the tool way. A connection that
  does not apply there, a runtime, a service, or an integration whose release is not
  ready, is used in none.
  """
  @spec used_ways(Connection.t(), Ecto.UUID.t()) :: [String.t()]
  def used_ways(%Connection{kind: "integration"} = connection, target_id) do
    connection = Repo.preload(connection, [:release, :targets])

    case {connection.applies_to, Enum.find(connection.targets, &(&1.target_id == target_id))} do
      {_applies_to, %Target{ways: [_ | _] = ways}} -> Enum.filter(@ways, &(&1 in ways))
      {"selected", nil} -> []
      _none_of_its_own -> offered_ways(connection)
    end
  end

  def used_ways(%Connection{}, _target_id), do: []

  defp offered_ways(connection) do
    case description(connection) do
      {:ok, description} -> Enum.filter(@ways, &(&1 in description.ways))
      {:error, :not_ready} -> []
    end
  end

  defp may_read(%Scope{workspace: %Workspace{} = workspace} = scope) do
    with :ok <- Access.authorize(scope, :"connection.read", workspace), do: {:ok, workspace}
  end

  defp may_read(_scope), do: {:error, :not_found}

  defp connections(%Workspace{id: id, organisation_id: organisation_id}),
    do:
      from(c in Connection,
        where: c.organisation_id == ^organisation_id and c.workspace_id == ^id
      )

  defp definitions(%Workspace{id: id, organisation_id: organisation_id}),
    do:
      from(d in ServiceDefinition,
        where: d.organisation_id == ^organisation_id and d.workspace_id == ^id
      )

  defp preloads,
    do: [:release, :service_definition, targets: from(t in Target, order_by: t.target_id)]

  defp load_all(workspace) do
    Repo.all(
      from c in connections(workspace),
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
  list_for_rendering/1 is `workspace`'s connections for what renders its run
  configurations, loaded as `list_connections/1` loads them, every one checked:
  `{:ok, connections}`, or `{:error, {:integrity, public_ids}}` when a connection, its
  release or its definition is not as it was written, with an error in the log. It asks
  nothing of `Apiary.Access`: it is the server's own rendering path, with no person's
  scope to ask about.
  """
  @spec list_for_rendering(%Workspace{}) ::
          {:ok, [Connection.t()]} | {:error, {:integrity, [String.t()]}}
  def list_for_rendering(%Workspace{} = workspace) do
    connections = load_all(workspace)

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
  `runtime`, its name, `applies_to` (`all` by default) and `target_ids`, the repositories
  of a `selected` one. `{:ok, connection}`, or `{:error, refusal}`: `:runtime_unknown`.
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
  create_integration/3 adds an integration from the scope's workspace's release
  `release_id`, ready and intact (`connection.write`): `attrs` has `settings`, the plain
  settings (`%{}` by default), `argument`, `applies_to` and `target_ids`.
  `{:ok, connection}`, or `{:error, refusal}`: `:release_not_ready`,
  `:integration_source_refused` for a release whose source the instance's settings no
  longer accept (`Apiary.Integrations.accepted_source/1`), and the description's refusals
  of the settings and the argument.
  """
  @spec create_integration(Scope.t(), term, map) :: {:ok, Connection.t()} | {:error, refusal}
  def create_integration(%Scope{} = scope, release_id, attrs) do
    attrs = stringify(attrs)

    create(scope, attrs, fn connection, workspace ->
      with {:ok, release, description} <- ready_release(workspace, release_id),
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
  of a built-in definition, or `definition_id`, the public id of one of the workspace's
  own, and `name` (the definition's title by default), `applies_to` and `target_ids`.
  `{:ok, connection}`, or `{:error, refusal}`: `:service_unknown`.
  """
  @spec create_service(Scope.t(), map) :: {:ok, Connection.t()} | {:error, refusal}
  def create_service(%Scope{} = scope, attrs) do
    attrs = stringify(attrs)

    create(scope, attrs, fn connection, workspace ->
      with {:ok, title, fields} <- service(workspace, attrs) do
        {:ok,
         struct(
           %{connection | kind: "service", name: blank_to_nil(attrs["name"]) || title},
           fields
         )}
      end
    end)
  end

  defp service(_workspace, %{"service" => key}) when is_binary(key) do
    case Services.fetch(key) do
      {:ok, definition} -> {:ok, definition["title"], service_builtin: key}
      :error -> {:error, :service_unknown}
    end
  end

  defp service(workspace, %{"definition_id" => public_id}) when is_binary(public_id) do
    with true <- PublicId.valid?("svc", public_id),
         %ServiceDefinition{} = definition <-
           Repo.one(from d in definitions(workspace), where: d.public_id == ^public_id) do
      {:ok, definition.title,
       service_definition_id: definition.id, service_definition: definition}
    else
      _ -> {:error, :service_unknown}
    end
  end

  defp service(_workspace, _attrs), do: {:error, :service_unknown}

  # A new connection: `build` fills in its kind from the attributes, with the workspace
  # when it needs to read from it; then the name, where it applies, the overlap check, the
  # row, its targets and the entry, in one write.
  defp create(scope, attrs, build) do
    write(scope, fn scope, workspace ->
      new = %Connection{
        id: Ecto.UUID.generate(),
        public_id: PublicId.generate("con"),
        organisation_id: workspace.organisation_id,
        workspace_id: workspace.id,
        created_by_id: scope.user && scope.user.id,
        updated_by_id: scope.user && scope.user.id
      }

      built =
        if is_function(build, 1), do: {:ok, build.(new)}, else: build.(new, workspace)

      with :ok <- Access.check(scope, :"connection.write", workspace),
           {:ok, connection} <- built,
           changeset = connection |> change() |> attrs_changeset(connection, attrs),
           :ok <- valid(changeset),
           {:ok, target_ids} <- target_ids(workspace, connection_reach_ids(changeset, attrs)),
           :ok <- no_overlap(workspace, apply_changes(changeset), target_ids),
           {:ok, inserted} <- changeset |> Coded.seal() |> Repo.insert(),
           :ok <- insert_targets(inserted, target_ids),
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
      do: List.wrap(attrs["target_ids"]),
      else: []
  end

  @doc """
  update_connection/3 changes a connection (`connection.write`): `applies_to`; a
  service's `name`; an integration's `settings` and `argument`, checked against its
  description. Switching to `selected` keeps the targets it has as its repositories.
  `{:ok, connection}`, or `{:error, refusal}`. A change that changes nothing leaves no
  entry.
  """
  @spec update_connection(Scope.t(), Connection.t(), map) ::
          {:ok, Connection.t()} | {:error, refusal}
  def update_connection(%Scope{} = scope, %Connection{} = connection, attrs) do
    attrs = stringify(attrs)

    write_connection(scope, connection, fn scope, workspace, current ->
      changeset =
        current
        |> change(updated_by_id: scope.user && scope.user.id)
        |> attrs_changeset(current, attrs)

      with :ok <- valid(changeset),
           {:ok, changeset} <- settings_change(changeset, current, attrs),
           :ok <- argument_change(changeset, current),
           :ok <- no_overlap(workspace, apply_changes(changeset), target_ids_of(current)) do
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
  the scope's workspace (`connection.write`), of the same source and the same
  integration, its settings and argument checked again against the new description.
  `{:ok, connection}`, or `{:error, refusal}`: `{:integration_source_mismatch, why}` for a
  release of another source or another integration, and the refusals of
  `create_integration/3` of the release.
  """
  @spec change_release(Scope.t(), Connection.t(), term) ::
          {:ok, Connection.t()} | {:error, refusal}
  def change_release(%Scope{} = scope, %Connection{kind: "integration"} = connection, release_id) do
    write_connection(scope, connection, fn scope, workspace, current ->
      with {:ok, release, description} <- ready_release(workspace, release_id),
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
                 workspace,
                 %{apply_changes(changeset) | release: release},
                 target_ids_of(current)
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
  put_target/4 makes a connection apply to the repository `target_id` of the scope's
  workspace, or changes the ways an integration is used there (`connection.write`):
  `ways` is nil, the credential way when its description offers it, or `["credential"]`
  when its description offers it; `tool`, or any other way, is refused. A runtime or a
  service takes nil only. `{:ok, connection}`, or `{:error, refusal}`:
  `:target_not_found`, `:ways_not_allowed`.
  """
  @spec put_target(Scope.t(), Connection.t(), term, [String.t()] | nil) ::
          {:ok, Connection.t()} | {:error, refusal}
  def put_target(%Scope{} = scope, %Connection{} = connection, target_id, ways \\ nil) do
    write_connection(scope, connection, fn scope, workspace, current ->
      with {:ok, [target_id]} <- target_ids(workspace, [target_id]),
           {:ok, ways} <- ways(current, ways),
           reach = Enum.uniq([target_id | target_ids_of(current)]),
           :ok <- no_overlap(workspace, current, reach) do
        now = DateTime.utc_now()

        Repo.insert_all(
          Target,
          [
            %{
              organisation_id: current.organisation_id,
              workspace_id: current.workspace_id,
              connection_id: current.id,
              target_id: target_id,
              ways: ways,
              inserted_at: now,
              updated_at: now
            }
          ],
          on_conflict: [set: [ways: ways, updated_at: now]],
          conflict_target: [:connection_id, :target_id]
        )

        with {:ok, _entry} <-
               Audit.record(Repo, scope, :"connection.write", current, %{
                 details: %{
                   change: "target_set",
                   connection_id: current.public_id,
                   name: current.name,
                   target_id: target_id,
                   ways: ways
                 }
               }),
             do: {:ok, current}
      end
    end)
    |> reload()
  end

  defp ways(%Connection{}, nil), do: {:ok, nil}

  defp ways(%Connection{kind: "integration"} = connection, ways) when is_list(ways) do
    with {:ok, description} <- current_description(connection) do
      ways = Enum.uniq(ways)

      if ways != [] and Enum.all?(ways, &(&1 in @ways and &1 in description.ways)),
        do: {:ok, Enum.filter(@ways, &(&1 in ways))},
        else: {:error, :ways_not_allowed}
    end
  end

  defp ways(%Connection{}, _ways), do: {:error, :ways_not_allowed}

  @doc """
  remove_target/3 takes the repository `target_id` from a connection's targets
  (`connection.write`): `{:ok, connection}`, or `{:error, refusal}`, `:target_not_found`
  for one it does not have.
  """
  @spec remove_target(Scope.t(), Connection.t(), term) ::
          {:ok, Connection.t()} | {:error, refusal}
  def remove_target(%Scope{} = scope, %Connection{} = connection, target_id) do
    write_connection(scope, connection, fn scope, _workspace, current ->
      with {:ok, uuid} <- cast_uuid(target_id),
           {1, _} <-
             Repo.delete_all(
               from t in Target, where: t.connection_id == ^current.id and t.target_id == ^uuid
             ),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"connection.write", current, %{
               details: %{
                 change: "target_removed",
                 connection_id: current.public_id,
                 name: current.name,
                 target_id: uuid
               }
             }) do
        {:ok, current}
      else
        {0, _} -> {:error, :target_not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> reload()
  end

  @doc """
  delete_connection/2 removes a connection with its targets (`connection.write`):
  `{:ok, connection}`, the connection as it was, or `{:error, refusal}`.
  """
  @spec delete_connection(Scope.t(), Connection.t()) :: {:ok, Connection.t()} | {:error, refusal}
  def delete_connection(%Scope{} = scope, %Connection{} = connection) do
    write_connection(scope, connection, fn scope, _workspace, current ->
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

  defp ready_release(workspace, release_id) do
    with {:ok, uuid} <- cast_uuid(release_id),
         %Release{state: "ready"} = release <-
           Repo.one(
             from r in Release,
               where:
                 r.id == ^uuid and r.organisation_id == ^workspace.organisation_id and
                   r.workspace_id == ^workspace.id
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

  defp no_overlap(workspace, %Connection{} = candidate, target_ids) do
    others = load_all(workspace)
    entry = overlap_entry(candidate, target_ids)

    case Overlap.conflicts(entry, Enum.map(others, &overlap_entry(&1, target_ids_of(&1)))) do
      [] ->
        :ok

      ids ->
        {:error, {:overlap, for(c <- others, c.id in ids, do: c.public_id)}}
    end
  end

  defp overlap_entry(%Connection{} = connection, target_ids) do
    reach = if connection.applies_to == "all", do: :all, else: MapSet.new(target_ids)
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

  defp target_ids_of(%Connection{targets: targets}) when is_list(targets),
    do: Enum.map(targets, & &1.target_id)

  defp target_ids_of(%Connection{id: id}),
    do: Repo.all(from t in Target, where: t.connection_id == ^id, select: t.target_id)

  ## Targets

  defp target_ids(_workspace, []), do: {:ok, []}

  defp target_ids(workspace, ids) do
    with {:ok, uuids} <- cast_uuids(ids) do
      uuids = Enum.uniq(uuids)

      found =
        Repo.all(
          from t in Apiary.Runs.Target,
            where:
              t.organisation_id == ^workspace.organisation_id and t.workspace_id == ^workspace.id and
                t.id in ^uuids,
            select: t.id
        )

      if length(found) == length(uuids), do: {:ok, uuids}, else: {:error, :target_not_found}
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
      :error -> {:error, :target_not_found}
    end
  end

  defp insert_targets(_connection, []), do: :ok

  defp insert_targets(%Connection{} = connection, target_ids) do
    now = DateTime.utc_now()

    rows =
      for target_id <- target_ids do
        %{
          organisation_id: connection.organisation_id,
          workspace_id: connection.workspace_id,
          connection_id: connection.id,
          target_id: target_id,
          inserted_at: now,
          updated_at: now
        }
      end

    {_count, _} = Repo.insert_all(Target, rows)
    :ok
  end

  ## Service definitions

  @doc """
  create_service_definition/2 writes a service definition of the scope's workspace's own
  (`connection.write`): `definition`, a map or its JSON, checked by
  `Apiary.Kinds.ServiceDefinition`, its `key` unique in the workspace.
  `{:ok, definition}`, or `{:error, refusal}`: `{:definition_invalid, problems}`, a
  changeset whose error is on `key`.
  """
  @spec create_service_definition(Scope.t(), map | String.t()) ::
          {:ok, ServiceDefinition.t()} | {:error, refusal}
  def create_service_definition(%Scope{} = scope, definition) do
    write(scope, fn scope, workspace ->
      with :ok <- Access.check(scope, :"connection.write", workspace),
           {:ok, decoded} <- checked_definition(definition) do
        %ServiceDefinition{
          id: Ecto.UUID.generate(),
          public_id: PublicId.generate("svc"),
          organisation_id: workspace.organisation_id,
          workspace_id: workspace.id,
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
  update_service_definition/3 replaces a definition of the workspace's own
  (`connection.write`); every connection that names it takes it from now on.
  `{:ok, definition}`, or `{:error, refusal}`.
  """
  @spec update_service_definition(Scope.t(), ServiceDefinition.t(), map | String.t()) ::
          {:ok, ServiceDefinition.t()} | {:error, refusal}
  def update_service_definition(%Scope{} = scope, %ServiceDefinition{id: id}, definition) do
    write(scope, fn scope, workspace ->
      with %ServiceDefinition{} = current <-
             Repo.one(from d in definitions(workspace), where: d.id == ^id, lock: "FOR UPDATE"),
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
  delete_service_definition/2 deletes a definition of the workspace's own
  (`connection.write`): `{:ok, definition}`, or `{:error, refusal}`,
  `{:in_use, public_ids}` while a connection names it.
  """
  @spec delete_service_definition(Scope.t(), ServiceDefinition.t()) ::
          {:ok, ServiceDefinition.t()} | {:error, refusal}
  def delete_service_definition(%Scope{} = scope, %ServiceDefinition{id: id}) do
    write(scope, fn scope, workspace ->
      with %ServiceDefinition{} = current <-
             Repo.one(from d in definitions(workspace), where: d.id == ^id, lock: "FOR UPDATE"),
           :ok <- Access.check(scope, :"connection.write", current),
           [] <-
             Repo.all(
               from c in connections(workspace),
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
      message: dgettext_noop("errors", "is already the key of a service of this workspace")
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

  # A write to the scope's workspace: the organisation `FOR SHARE`, the workspace
  # `FOR NO KEY UPDATE`, the membership read again under its lock, then `fun`, which asks
  # its question first.
  defp write(
         %Scope{organisation: %Organisation{id: org}, workspace: %Workspace{id: ws}} = scope,
         fun
       ) do
    Repo.transact(fn ->
      :ok = Access.lock_places(scope)

      case Repo.one(
             from w in Workspace,
               where: w.id == ^ws and w.organisation_id == ^org,
               lock: "FOR NO KEY UPDATE"
           ) do
        %Workspace{} = workspace -> fun.(Access.reload(scope, lock: :share), workspace)
        nil -> {:error, :not_found}
      end
    end)
  end

  defp write(_scope, _fun), do: {:error, :not_found}

  # A write to one connection: the row read again under `FOR UPDATE` in the scope's
  # workspace, with its targets, then asked of.
  defp write_connection(scope, %Connection{id: id}, fun) do
    write(scope, fn scope, workspace ->
      with %Connection{} = current <-
             Repo.one(from c in connections(workspace), where: c.id == ^id, lock: "FOR UPDATE"),
           :ok <- Access.check(scope, :"connection.write", current) do
        fun.(scope, workspace, Repo.preload(current, preloads()))
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
