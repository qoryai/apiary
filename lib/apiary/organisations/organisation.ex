defmodule Apiary.Organisations.Organisation do
  @moduledoc """
  An organisation, which holds the workspaces. Its `slug` is its name in the
  URL, `/:org/…`, unique on the instance (`Apiary.Organisations.Slug`); a path built with
  `~p"/\#{organisation}"` uses it.

  `edition` is not stored: what the edition says of the organisation beyond the core's
  fields, a map it owns and fills where it loads the organisation, empty in the core's
  (`c:Apiary.Edition.reach/1`). Nothing else of an edition's is on this schema: an edition
  keeps what it knows of an organisation in separate tables.
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
    # Made from the name: at creation by `put_slug/2`, where a taken one refuses the name
    # (`taken: :refuse`, a sign-up's) or is numbered, and on each rename by
    # `put_address/2`; never cast from a form.
    field :slug, :string
    # The edition's (see the moduledoc); never cast from a form.
    field :edition, :map, virtual: true, default: %{}

    has_many :workspaces, Apiary.Organisations.Workspace
    has_many :memberships, Apiary.Organisations.Membership

    # Marked for deletion (`Apiary.Deletion`): when, by whom, from when it may be purged,
    # why (`grace_period` or `erasure_request`), who asked for an erasure, and when a purge
    # claimed it, after which its deletion can no longer be cancelled. All nil for one in use. A marked organisation is
    # gone from every page and menu until its deletion is cancelled or it is purged.
    field :deletion_marked_at, :utc_datetime_usec
    field :purge_after, :utc_datetime_usec
    field :purge_trigger, :string
    field :purge_started_at, :utc_datetime_usec
    belongs_to :deletion_marked_by, Apiary.Accounts.User
    belongs_to :purge_requested_by, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(organisation, attrs) do
    organisation
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_name(:name)
  end

  @doc """
  validate_name/2 checks `field` of `changeset` by the rules of an organisation's name: at
  most 120 characters, and none that is a control character or a line or paragraph
  separator, an invisible one, a joining character at either end, a web address or a
  quotation mark. The name an instance admin
  gives the product keeps the same rules (`Apiary.ProductName`): both are shown inside
  sentences Qory writes.
  """
  @spec validate_name(Ecto.Changeset.t(), atom) :: Ecto.Changeset.t()
  def validate_name(changeset, field) do
    changeset
    |> validate_length(field, min: 1, max: 120)
    |> validate_format(field, ~r/\A[^[:cntrl:]\x{2028}\x{2029}]+\z/u,
      message: dgettext_noop("errors", "must not contain control characters")
    )
    |> refuse_in_name(
      field,
      invisible(),
      dgettext_noop("errors", "must not contain invisible characters")
    )
    |> refuse_in_name(
      field,
      ~r/\A[\x{200C}\x{200D}]|[\x{200C}\x{200D}]\z/u,
      dgettext_noop("errors", "must not start or end with a joining character")
    )
    |> refuse_in_name(
      field,
      ~r{://|www\.}iu,
      dgettext_noop("errors", "must not contain a web address; a name like acme.io is fine")
    )
    |> refuse_in_name(
      field,
      ~r/["„‹›″‶‟＂〝〞״ˮʺ]|(?![‘’])[\p{Pi}\p{Pf}]/u,
      dgettext_noop("errors", "must not contain quotation marks")
    )
  end

  # The name is shown to people the organisation invites, inside a sentence Qory writes:
  # nothing in it may be a web address, close Qory's quotation marks, or reorder or hide
  # the text around it. A bare name that looks like a domain stays allowed, and so does an
  # apostrophe, straight or curly (Dana’s).

  # The Unicode format characters (category Cf), zero-width and bidirectional controls and
  # tag characters among them, but the two join controls, ZWNJ and ZWJ, which a Persian
  # name and an emoji sequence need.
  defp invisible, do: ~r/(?![\x{200C}\x{200D}])\p{Cf}/u

  defp refuse_in_name(changeset, field, pattern, message) do
    validate_change(changeset, field, fn ^field, name ->
      if Regex.match?(pattern, name), do: [{field, message}], else: []
    end)
  end

  @doc """
  displayable_name/1 is an organisation's name with the Unicode format characters a name
  may not hold taken out (category Cf, zero-width and bidirectional controls among them,
  but the join controls ZWNJ and ZWJ), for mail, where a name stored before the rules
  refused them must not reorder or hide what Qory writes around it.
  """
  @spec displayable_name(String.t()) :: String.t()
  def displayable_name(name) when is_binary(name), do: String.replace(name, invisible(), "")

  @doc """
  put_address/2 gives a renamed organisation the slug its new name makes
  (`Apiary.Organisations.Slug.from_name/1`, always of a slug's characters). Whether a page
  or another organisation has it is asked by the caller
  (`Apiary.Organisations.change_organisation/2`); the unique index answers for one taken
  since, on the name.
  """
  def put_address(changeset, slug) do
    changeset
    |> put_change(:slug, slug)
    |> unique_constraint(:slug, error_key: :name, message: taken_slug())
    |> check_constraint(:slug,
      name: :organisations_slug_format,
      message: dgettext_noop("errors", "is not a valid slug")
    )
  end

  @doc """
  The error of a name whose address another organisation has, one marked for deletion
  included: the error does not tell an organisation that another is marked.
  """
  def taken_address,
    do:
      dgettext_noop(
        "errors",
        "Choose another name. Another organisation has the address %{address}."
      )

  @doc "The error of a name whose address is a page of Qory Apiary."
  def page_address,
    do: dgettext_noop("errors", "Choose another name. %{address} is a page of Qory Apiary.")

  defp taken_slug, do: dgettext_noop("errors", "is already the slug of another organisation")

  @doc """
  put_slug/2 gives a new organisation its slug, checked against the rules and the names
  the router reserves; the unique index answers for a slug another organisation holds.
  """
  def put_slug(changeset, slug) do
    changeset
    |> put_change(:slug, slug)
    |> Slug.validate(ApiaryWeb.ReservedSlugs.organisation())
    |> unique_constraint(:slug, message: taken_slug())
    |> check_constraint(:slug,
      name: :organisations_slug_format,
      message: dgettext_noop("errors", "is not a valid slug")
    )
  end
end
