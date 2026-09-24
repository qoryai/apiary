defmodule Apiary.Organisations.Membership do
  @moduledoc "A user's place in an organisation and its hive, at one of two levels."
  use Ecto.Schema
  use Gettext, backend: ApiaryWeb.Gettext
  import Ecto.Changeset

  @levels [:owner, :member]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "memberships" do
    field :level, Ecto.Enum, values: @levels

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :hive, Apiary.Organisations.Hive
    belongs_to :user, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def levels, do: @levels

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:level])
    |> validate_required([:level])
    |> unique_constraint([:organisation_id, :user_id],
      error_key: :user_id,
      message: dgettext_noop("errors", "is already a member of this organisation")
    )
  end
end
