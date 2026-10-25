defmodule Apiary.Secrets.InstanceSecret do
  @moduledoc """
  A secret of the instance, of no organisation and no workspace: it belongs to one adapter
  (`adapter_id`, a node of kind `adapter`), has a public id (`sec_` and 16 lowercase
  Crockford base32 characters, `Apiary.PublicId`), a name, unique for its adapter whatever
  its case, and a `revision`, 1 when it is made and one more each time its values are
  replaced. Its values are `Apiary.Secrets.InstanceSecretValue`s. The row holds no value.
  Changed only through `Apiary.Secrets.Instance`.
  """
  use Ecto.Schema

  @typedoc "A secret of the instance."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "instance_secrets" do
    field :public_id, :string
    field :name, :string
    field :revision, :integer

    belongs_to :adapter, Apiary.Nodes.Node

    has_many :values, Apiary.Secrets.InstanceSecretValue,
      foreign_key: :secret_id,
      preload_order: [asc: :value_id]

    timestamps(type: :utc_datetime_usec)
  end
end
