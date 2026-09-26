defmodule Apiary.Organisations.Workspace do
  @moduledoc """
  The workspace inside an organisation: the unit of use. Its `slug` is its name in the
  URL, `/:org/:workspace/…`, unique within its organisation
  (`Apiary.Organisations.Slug`); a path built with `~p"/\#{organisation}/\#{workspace}"`
  uses it.
  """
  use Ecto.Schema
  use Gettext, backend: ApiaryWeb.Gettext
  import Ecto.Changeset

  alias Apiary.Organisations.Slug

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Phoenix.Param, key: :slug}
  schema "workspaces" do
    field :name, :string
    # Set once, at creation, by `put_slug/2`; never cast from a form.
    field :slug, :string
    # The mode of the workspace's security policy; changed through
    # `Apiary.Policy.set_mode/2`.
    field :egress_mode, :string, default: "observe"
    # How long a run's events and log bytes are kept, in days; nil is unlimited. Changed
    # through `Apiary.Retention.update_retention/2`.
    field :events_retention_days, :integer
    field :log_retention_days, :integer
    # The workspace's domain by name (`Apiary.Lingo.Domain.domains/0`): the words its
    # members read and how a run's labels name its target. Set when the workspace is
    # created (`create_changeset/2`) and changed by nothing after.
    field :domain, :string, default: "software"

    belongs_to :organisation, Apiary.Organisations.Organisation

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  The changeset of a new workspace: its name, as `changeset/2` checks it, and its domain,
  one of `Apiary.Lingo.Domain.names/0`. The domain is chosen here only.
  """
  def create_changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:domain])
    |> validate_required([:domain])
    |> validate_inclusion(:domain, Apiary.Lingo.Domain.names())
    |> changeset(attrs)
  end

  @doc "The changeset of a workspace's name, on creation and on rename."
  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_format(:name, ~r/\A[^[:cntrl:]]+\z/u,
      message: dgettext_noop("errors", "must not contain control characters")
    )
    |> unique_constraint([:organisation_id, :name],
      error_key: :name,
      message: dgettext_noop("errors", "is already the name of a workspace in this organisation")
    )
  end

  @doc """
  put_slug/2 gives a new workspace its slug, checked against the rules and the names of
  the organisation's own pages; the unique index answers for a slug another workspace of
  the organisation holds.
  """
  def put_slug(changeset, slug) do
    changeset
    |> put_change(:slug, slug)
    |> Slug.validate(ApiaryWeb.ReservedSlugs.workspace())
    |> unique_constraint([:organisation_id, :slug],
      error_key: :slug,
      message: dgettext_noop("errors", "is already the slug of a workspace in this organisation")
    )
    |> check_constraint(:slug,
      name: :workspaces_slug_format,
      message: dgettext_noop("errors", "is not a valid slug")
    )
  end

  @retention_days 1..3650

  # The message names the range above: a message built at compile time could not be
  # extracted for the catalogue.
  @retention_message dgettext_noop(
                       "errors",
                       "must be between 1 and 3650 days, or empty to keep everything"
                     )

  @doc "The days a retention setting may hold; nil, unlimited, is always allowed."
  def retention_days, do: @retention_days

  @doc """
  The retention settings: each a whole number of days within `retention_days/0`, or nil for
  unlimited. The log is part of a run's events, so it is not kept longer than they are.
  """
  def retention_changeset(workspace, attrs) do
    first..last//_ = @retention_days

    workspace
    |> cast(attrs, [:events_retention_days, :log_retention_days])
    |> validate_number(:events_retention_days,
      greater_than_or_equal_to: first,
      less_than_or_equal_to: last,
      message: @retention_message
    )
    |> validate_number(:log_retention_days,
      greater_than_or_equal_to: first,
      less_than_or_equal_to: last,
      message: @retention_message
    )
    |> validate_log_within_events()
    |> check_constraint(:events_retention_days, name: :workspaces_events_retention_days_check)
    |> check_constraint(:log_retention_days, name: :workspaces_log_retention_days_check)
  end

  defp validate_log_within_events(changeset) do
    events = get_field(changeset, :events_retention_days)
    log = get_field(changeset, :log_retention_days)

    if is_integer(events) and is_integer(log) and log > events do
      add_error(
        changeset,
        :log_retention_days,
        dgettext_noop(
          "errors",
          "cannot be longer than the events are kept: the log goes with a run's events"
        )
      )
    else
      changeset
    end
  end
end
