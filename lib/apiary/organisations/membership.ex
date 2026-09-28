defmodule Apiary.Organisations.Membership do
  @moduledoc """
  A user's place in an organisation, once per organisation, at one of three levels: owner,
  admin or member. The level is the organisation's, and so is the membership. The levels
  of `c:Apiary.Edition.every_workspace_levels/0` reach every workspace of it; which
  workspaces another level reaches is the edition's to say
  (`Apiary.Access.reaches_every_workspace?/1`). What a level may do is `Apiary.Access`'s
  answer.

  `workspaces` and `edition` are not stored: the workspaces of the organisation the
  membership reaches, by name, where `Apiary.Organisations.list_memberships/1` or
  `Apiary.Organisations.list_members/1` loaded them, and what the edition said of the
  membership in each, a list under each of its keys
  (`c:Apiary.Edition.reached_workspaces/2`).
  """
  use Ecto.Schema
  use Gettext, backend: ApiaryWeb.Gettext
  import Ecto.Changeset

  @levels [:owner, :admin, :member]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "memberships" do
    field :level, Ecto.Enum, values: @levels
    field :workspaces, {:array, :any}, virtual: true, default: []
    field :edition, :map, virtual: true, default: %{}
    # When the membership was suspended, and by whom (`Apiary.Organisations.suspend_member/2`):
    # its person acts in the organisation no more, as if they had no membership there,
    # until it is activated. Nil for one in use. Never cast from a form.
    field :suspended_at, :utc_datetime_usec
    field :suspended_by_id, :binary_id

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :user, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A level of `levels/0`."
  @type level :: :owner | :admin | :member

  @doc "The levels, from the one that may most to the one that may least."
  @spec levels() :: [level]
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
