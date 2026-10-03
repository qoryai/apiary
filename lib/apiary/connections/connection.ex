defmodule Apiary.Connections.Connection do
  @moduledoc """
  A runtime, an integration or a service set up in a workspace: what the contract calls a
  connection, and the pages call an integration. It has a public id (`con_` and 16
  lowercase Crockford base32 characters), which the run configuration names, a `kind`, a
  `name`, and applies to every repository of the workspace (`applies_to` `all`) or to
  those its targets name (`selected`).

    * **runtime**: `name` is the runtime's, from the catalogue (`Apiary.Kinds.Runtimes`).
    * **integration**: `name` is its description's; the row names the release it was added
      from (`release_id`) and copies its `source`, `forge_kind`, `version` and
      `description_sha256`. `settings` are its plain settings, as canonical JSON of an
      object, and `argument` the argument it is started with, if any.
    * **service**: `name` is shown and rendered; the row names its definition, built in
      by key (`service_builtin`) or the workspace's own (`service_definition_id`), and
      never holds a host, a path or an auth of its own.

  A connection's secrets are linked to stored secrets by the links that piece of the
  application keeps; the row holds no secret. The row carries an integrity code over
  everything above (`Apiary.Kinds.Coded`), which `Apiary.Connections` checks before it
  hands the row to what renders a run configuration. Changed only through
  `Apiary.Connections`.
  """
  use Ecto.Schema

  @typedoc "A connection of a workspace."
  @type t :: %__MODULE__{}

  @kinds ~w(runtime integration service)
  @applies ~w(all selected)

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "workspace_connections" do
    field :public_id, :string
    field :kind, :string
    field :name, :string
    field :applies_to, :string, default: "all"
    field :settings, :string, default: "{}"
    field :argument, :string
    field :source, :string
    field :forge_kind, :string
    field :version, :string
    field :description_sha256, :string
    field :service_builtin, :string
    field :integrity_key_id, :string
    field :integrity_code, :binary, redact: true
    field :integrity_version, :integer
    field :intact, :boolean, virtual: true

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :release, Apiary.Integrations.Release
    belongs_to :service_definition, Apiary.Connections.ServiceDefinition
    belongs_to :created_by, Apiary.Accounts.User
    belongs_to :updated_by, Apiary.Accounts.User
    has_many :targets, Apiary.Connections.Target, preload_order: [asc: :target_id]

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The kinds of connection."
  def kinds, do: @kinds

  @doc "What a connection applies to: `all` the repositories, or `selected` ones."
  def applies, do: @applies

  @doc false
  def integrity_kind, do: "connection"
  @doc false
  def integrity_version, do: 1
  @doc false
  def integrity_versions, do: [1]

  @doc false
  def integrity_fields(%__MODULE__{} = connection, 1) do
    [
      id: connection.id,
      organisation_id: connection.organisation_id,
      workspace_id: connection.workspace_id,
      public_id: connection.public_id,
      kind: connection.kind,
      name: connection.name,
      applies_to: connection.applies_to,
      settings: connection.settings,
      argument: connection.argument,
      release_id: connection.release_id,
      source: connection.source,
      forge_kind: connection.forge_kind,
      version: connection.version,
      description_sha256: connection.description_sha256,
      service_builtin: connection.service_builtin,
      service_definition_id: connection.service_definition_id
    ]
  end

  @doc "settings_map/1 is a connection's plain settings, decoded."
  @spec settings_map(t) :: map
  def settings_map(%__MODULE__{settings: settings}), do: Jason.decode!(settings)
end
