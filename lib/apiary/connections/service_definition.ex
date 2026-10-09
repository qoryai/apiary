defmodule Apiary.Connections.ServiceDefinition do
  @moduledoc """
  A service definition a workspace writes for itself, beside the built-in ones
  (`Apiary.Kinds.Services`): a public id (`svc_` and 16 lowercase Crockford base32
  characters), its `key` and `title`, the definition as canonical JSON (`definition`),
  checked by `Apiary.Kinds.ServiceDefinition`, and its SHA-256 (`digest`).

  The row carries an integrity code over its identity and the definition's bytes
  (`Apiary.Kinds.Coded`). Changed only through `Apiary.Connections`.
  """
  use Ecto.Schema

  @typedoc "A workspace's own service definition."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "service_definitions" do
    field :public_id, :string
    field :key, :string
    field :title, :string
    field :definition, :string
    field :digest, :string
    field :integrity_key_id, :string
    field :integrity_code, :binary, redact: true
    field :integrity_version, :integer

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :created_by, Apiary.Accounts.User
    belongs_to :updated_by, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def integrity_kind, do: "service_definition"
  @doc false
  def integrity_version, do: 1
  @doc false
  def integrity_versions, do: [1]

  @doc false
  def integrity_fields(%__MODULE__{} = definition, 1) do
    [
      id: definition.id,
      organisation_id: definition.organisation_id,
      workspace_id: definition.workspace_id,
      public_id: definition.public_id,
      key: definition.key,
      definition: definition.definition,
      digest: definition.digest
    ]
  end

  @doc "decoded/1 is the definition, decoded."
  @spec decoded(t) :: map
  def decoded(%__MODULE__{definition: definition}), do: Jason.decode!(definition)
end
