defmodule Apiary.Organisations.Organisation do
  @moduledoc "The tenant: an apiary in product words."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "organisations" do
    field :name, :string

    has_many :hives, Apiary.Organisations.Hive
    has_many :memberships, Apiary.Organisations.Membership

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(organisation, attrs) do
    organisation
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 120)
  end
end
