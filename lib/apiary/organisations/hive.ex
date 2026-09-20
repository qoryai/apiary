defmodule Apiary.Organisations.Hive do
  @moduledoc "The team inside an organisation: the unit of use."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "hives" do
    field :name, :string
    # The mode of the hive's security policy; changed through `Apiary.Policy.set_mode/2`.
    field :egress_mode, :string, default: "observe"

    belongs_to :organisation, Apiary.Organisations.Organisation

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(hive, attrs) do
    hive
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_format(:name, ~r/\A[^[:cntrl:]]+\z/u,
      message: "must not contain control characters"
    )
    |> unique_constraint([:organisation_id, :name],
      error_key: :name,
      message: "is already the name of a hive in this organisation"
    )
  end
end
