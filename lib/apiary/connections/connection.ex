defmodule Apiary.Connections.Connection do
  @moduledoc """
  A runtime, an integration or a service set up in an organisation: what the contract
  calls a connection, and the pages call an integration. It has a public id (`con_` and
  16 lowercase Crockford base32 characters), a `kind`, a `name`, and applies to every
  workspace of the organisation, those made later included (`applies_to` `all`), or to
  the workspaces it lists (`selected`, `Apiary.Connections.ConnectionWorkspace`).

    * **runtime**: `name` is the runtime's, from the catalogue (`Apiary.Kinds.Runtimes`).
    * **integration**: `name` is its description's; the row names the release it was added
      from (`release_id`) and copies its `source`, `forge_kind`, `version` and
      `description_sha256`. `settings` are its plain settings, as canonical JSON of an
      object, and `argument` its argument, if any.
    * **model provider**, an integration with no release: `provider_kind` is the name of
      its description in the catalogue (`Apiary.Kinds.Providers`), `description_ref` the
      integrations commit that description was vendored from, and `description_sha256` its
      digest. `name` is shown, the description's title unless one is given. `settings` are
      its plain settings, such as the address of an endpoint from a setting. `secret_id`
      is the organisation's secret whose values are its keys, and `default_value_id` the
      value id of its default key. Its models are `Apiary.Connections.ProviderModel` rows.
    * **service**: `name` is shown; the row names its definition, built in
      by key (`service_builtin`) or one of the organisation's (`service_definition_id`), and
      never holds a host, a path or an auth itself.

  `chain` is `organisation` for a connection the organisation sets up, or `operator` for a
  provider an operator sets up for a client, which the edition manages.

  The row holds no secret: a provider links its keys' secret by its id. The row carries an integrity code over
  everything above (`Apiary.Kinds.Coded`), which `Apiary.Connections` checks where it reads
  the row. Changed only through `Apiary.Connections`.
  """
  use Ecto.Schema

  @typedoc "A connection of an organisation."
  @type t :: %__MODULE__{}

  @kinds ~w(runtime integration service)
  @applies ~w(all selected)
  @chains ~w(organisation operator)

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "organisation_connections" do
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
    field :provider_kind, :string
    field :description_ref, :string
    field :default_value_id, :string
    field :chain, :string, default: "organisation"
    field :integrity_key_id, :string
    field :integrity_code, :binary, redact: true
    field :integrity_version, :integer
    field :intact, :boolean, virtual: true

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :release, Apiary.Integrations.Release
    belongs_to :service_definition, Apiary.Connections.ServiceDefinition
    belongs_to :secret, Apiary.Secrets.Secret
    belongs_to :created_by, Apiary.Accounts.User
    belongs_to :updated_by, Apiary.Accounts.User

    has_many :workspaces, Apiary.Connections.ConnectionWorkspace,
      preload_order: [asc: :workspace_id]

    has_many :models, Apiary.Connections.ProviderModel, preload_order: [asc: :position]

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The kinds of connection."
  def kinds, do: @kinds

  @doc "What a connection applies to: `all` the workspaces, or `selected` ones."
  def applies, do: @applies

  @doc "The chains a connection belongs to."
  def chains, do: @chains

  @doc "provider?/1 says whether `connection` is a model provider."
  @spec provider?(t) :: boolean
  def provider?(%__MODULE__{provider_kind: kind}), do: is_binary(kind)

  @doc false
  def integrity_kind, do: "connection"
  # Version 2: a connection is the organisation's, and names no workspace. No row of
  # version 1 is left (`Apiary.Repo.Migrations.MoveConnectionsToTheOrganisation`).
  # Version 3 adds a model provider's columns. A row of version 2 was coded before they
  # existed, so `Apiary.Connections.intact?/1` takes one only while they are empty.
  @doc false
  def integrity_version, do: 3
  @doc false
  def integrity_versions, do: [2, 3]

  @doc false
  def integrity_fields(%__MODULE__{} = connection, 3) do
    integrity_fields(connection, 2) ++
      [
        provider_kind: connection.provider_kind,
        description_ref: connection.description_ref,
        secret_id: connection.secret_id,
        default_value_id: connection.default_value_id,
        chain: connection.chain
      ]
  end

  def integrity_fields(%__MODULE__{} = connection, 2) do
    [
      id: connection.id,
      organisation_id: connection.organisation_id,
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

  @doc """
  coded_columns?/1 says whether the integrity code of `connection` covers every column it
  has set: a row of version 3 always; a row of version 2 only while a provider's columns
  are empty, since version 2 does not cover them.
  """
  @spec coded_columns?(t) :: boolean
  def coded_columns?(%__MODULE__{integrity_version: 2} = connection) do
    is_nil(connection.provider_kind) and is_nil(connection.description_ref) and
      is_nil(connection.secret_id) and is_nil(connection.default_value_id) and
      connection.chain == "organisation"
  end

  def coded_columns?(%__MODULE__{}), do: true

  @doc "settings_map/1 is a connection's plain settings, decoded."
  @spec settings_map(t) :: map
  def settings_map(%__MODULE__{settings: settings}), do: Jason.decode!(settings)
end
