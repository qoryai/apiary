defmodule Apiary.ModelKeys.Setting do
  @moduledoc """
  The settings of one model key, a value of a model provider's secret, by the value's
  row id (`secret_values.id`), which a rename of the value id leaves as it is. Every
  setting is optional:

    * **Resets:** a weekly reset, `reset_weekday` (1 for Monday to 7 for Sunday),
      `reset_time` and `reset_time_zone`, an IANA time zone: all three, or none.
    * **Pause for:** `pause_seconds`, the cooldown when no reset is known, from 1 to
      604800 seconds (7 days). Without it, the provider's default applies
      (`Apiary.ModelKeys.pause_seconds/2`).
    * **Use up to:** `use_up_to_percent`, a whole percent from 1 to 99, only for a key of
      a provider whose catalogue entry lists limit windows
      (`Apiary.ModelKeys.limit_windows/1`). Runs skip the key while one of those windows'
      use is at or above it, until that window resets (`Apiary.ModelKeys.cooldown/4`).
      Without it, runs use the key up to the provider's limit.

  The row is of the key's organisation, which `Apiary.ModelKeys.change_setting/3` takes
  from the value, never from the attributes.
  """

  use Ecto.Schema
  use Gettext, backend: ApiaryWeb.Gettext
  import Ecto.Changeset

  alias Apiary.Accounts.Preferences

  @typedoc "The settings of a model key."
  @type t :: %__MODULE__{}

  @reset_fields [:reset_weekday, :reset_time, :reset_time_zone]
  @max_pause_seconds 604_800

  @primary_key {:secret_value_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "model_key_settings" do
    belongs_to :organisation, Apiary.Organisations.Organisation

    field :reset_weekday, :integer
    field :reset_time, :time
    field :reset_time_zone, :string
    field :pause_seconds, :integer
    field :use_up_to_percent, :integer

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The longest Pause for, in seconds: 7 days."
  @spec max_pause_seconds() :: pos_integer
  def max_pause_seconds, do: @max_pause_seconds

  @doc """
  The changeset of the settings: the weekly reset, all three fields or none, a weekday
  from 1 to 7 and a time zone the zone database knows; `pause_seconds` from 1 to 604800;
  and `use_up_to_percent` from 1 to 99, which a key gets only when `limit_windows`, its
  provider's limit windows (`Apiary.ModelKeys.limit_windows/1`), are not empty. An empty
  field clears the setting.
  """
  @spec changeset(t, map, [String.t()]) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = setting, attrs, limit_windows \\ []) do
    setting
    |> cast(attrs, @reset_fields ++ [:pause_seconds, :use_up_to_percent])
    |> validate_number(:reset_weekday, greater_than_or_equal_to: 1, less_than_or_equal_to: 7)
    |> validate_time_zone()
    |> validate_reset_whole()
    |> validate_number(:pause_seconds,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max_pause_seconds
    )
    |> validate_number(:use_up_to_percent, greater_than_or_equal_to: 1, less_than_or_equal_to: 99)
    |> validate_use_up_to(limit_windows)
  end

  # A provider without limit windows reports no use a percentage could stop at.
  defp validate_use_up_to(changeset, [_ | _]), do: changeset

  defp validate_use_up_to(changeset, _none) do
    # Ecto calls the function only for a change that is not nil.
    validate_change(changeset, :use_up_to_percent, fn :use_up_to_percent, _percent ->
      [
        use_up_to_percent:
          dgettext_noop("errors", "is only for a key of a provider with limit windows")
      ]
    end)
  end

  defp validate_time_zone(changeset) do
    validate_change(changeset, :reset_time_zone, fn :reset_time_zone, zone ->
      if Preferences.time_zone?(zone),
        do: [],
        else: [reset_time_zone: dgettext_noop("errors", "is not a known time zone")]
    end)
  end

  # A reset is the weekday, the time and the zone together: one set without the others
  # has each missing field blank.
  defp validate_reset_whole(changeset) do
    if Enum.any?(@reset_fields, &(not is_nil(get_field(changeset, &1)))),
      do: validate_required(changeset, @reset_fields),
      else: changeset
  end

  @doc "Whether the settings have a weekly reset."
  @spec reset?(t | nil) :: boolean
  def reset?(%__MODULE__{reset_weekday: day, reset_time: %Time{}, reset_time_zone: zone})
      when is_integer(day) and is_binary(zone),
      do: true

  def reset?(_setting), do: false
end
