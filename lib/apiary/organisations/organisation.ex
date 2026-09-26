defmodule Apiary.Organisations.Organisation do
  @moduledoc """
  The tenant: an organisation, which holds the workspaces. Its `slug` is its name in the
  URL, `/:org/…`, unique on the instance (`Apiary.Organisations.Slug`); a path built with
  `~p"/\#{organisation}"` uses it.
  """
  use Ecto.Schema
  use Gettext, backend: ApiaryWeb.Gettext
  import Ecto.Changeset

  alias Apiary.Organisations.Slug

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Phoenix.Param, key: :slug}
  schema "organisations" do
    field :name, :string
    # Set once, at creation, by `put_slug/2`; never cast from a form.
    field :slug, :string

    has_many :workspaces, Apiary.Organisations.Workspace
    has_many :memberships, Apiary.Organisations.Membership

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(organisation, attrs) do
    organisation
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_format(:name, ~r/\A[^[:cntrl:]]+\z/u,
      message: dgettext_noop("errors", "must not contain control characters")
    )
  end

  @doc """
  put_slug/2 gives a new organisation its slug, checked against the rules and the names
  the router reserves; the unique index answers for a slug another organisation holds.
  """
  def put_slug(changeset, slug) do
    changeset
    |> put_change(:slug, slug)
    |> Slug.validate(ApiaryWeb.ReservedSlugs.organisation())
    |> unique_constraint(:slug,
      message: dgettext_noop("errors", "is already the slug of another organisation")
    )
    |> check_constraint(:slug,
      name: :organisations_slug_format,
      message: dgettext_noop("errors", "is not a valid slug")
    )
  end
end
