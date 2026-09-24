defmodule Apiary.Organisations.Hive do
  @moduledoc "The workplace inside an organisation: the unit of use."
  use Ecto.Schema
  use Gettext, backend: ApiaryWeb.Gettext
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "hives" do
    field :name, :string
    # The mode of the hive's security policy; changed through `Apiary.Policy.set_mode/2`.
    field :egress_mode, :string, default: "observe"
    # How long a run's events and log bytes are kept, in days; nil is unlimited. Changed
    # through `Apiary.Retention.update_retention/2`.
    field :events_retention_days, :integer
    field :log_retention_days, :integer

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
      message: dgettext_noop("errors", "is already the name of a hive in this organisation")
    )
  end

  @retention_days 1..3650

  @doc "The days a retention setting may hold; nil, unlimited, is always allowed."
  def retention_days, do: @retention_days

  @doc """
  The retention settings: each a whole number of days within `retention_days/0`, or nil for
  unlimited. The log is part of a run's events, so it is not kept longer than they are.
  """
  def retention_changeset(hive, attrs) do
    first..last//_ = @retention_days

    hive
    |> cast(attrs, [:events_retention_days, :log_retention_days])
    |> validate_number(:events_retention_days,
      greater_than_or_equal_to: first,
      less_than_or_equal_to: last,
      message: "must be between #{first} and #{last} days, or empty to keep everything"
    )
    |> validate_number(:log_retention_days,
      greater_than_or_equal_to: first,
      less_than_or_equal_to: last,
      message: "must be between #{first} and #{last} days, or empty to keep everything"
    )
    |> validate_log_within_events()
    |> check_constraint(:events_retention_days, name: :hives_events_retention_days_check)
    |> check_constraint(:log_retention_days, name: :hives_log_retention_days_check)
  end

  defp validate_log_within_events(changeset) do
    events = get_field(changeset, :events_retention_days)
    log = get_field(changeset, :log_retention_days)

    if is_integer(events) and is_integer(log) and log > events do
      add_error(
        changeset,
        :log_retention_days,
        "cannot be longer than the events are kept: the log goes with a run's events"
      )
    else
      changeset
    end
  end
end
