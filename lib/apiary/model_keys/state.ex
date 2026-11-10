defmodule Apiary.ModelKeys.State do
  @moduledoc """
  The state of one model key in one limit window, as a run's gateway reports it from the
  provider's answers (`Apiary.ModelKeys.Report`): one row per key, by the value's row id
  (`secret_values.id`), and window.

    * `window`: the limit's window, an open code such as `five_hour` or `seven_day`,
      `^[a-z][a-z0-9_]{0,63}$`.
    * `status`: `allowed`, `allowed_warning` or `rejected`.
    * `resets_at`: when the window resets, nil when the answer gave no time.
    * `utilization`: the window's use in whole percent, 0 to 100, nil when the answer
      gave none. A read leaves it out once `resets_at` has passed
      (`Apiary.ModelKeys.current/2`).
    * `cooldown_until`: until when the key is not used; the key is in cooldown while it
      is in the future.
    * `source`: where `cooldown_until` or `resets_at` comes from: `provider`, the answer;
      `schedule`, the key's weekly reset; `pause_for`, the key's Pause for.
    * `observed_at`: the gateway's clock when the answer arrived. A report keeps the row
      only when it is newer by this time.
    * `updated_at`: when this server last wrote the row.

  The row is of the key's organisation: the database holds `organisation_id` to the
  value's.
  """

  use Ecto.Schema

  @typedoc "The state of a model key in one window."
  @type t :: %__MODULE__{}

  @statuses ~w(allowed allowed_warning rejected)
  @sources ~w(provider schedule pause_for)
  @window ~r/\A[a-z][a-z0-9_]{0,63}\z/

  @primary_key false
  @foreign_key_type :binary_id
  schema "model_key_states" do
    field :secret_value_id, :binary_id, primary_key: true
    field :window, :string, primary_key: true
    belongs_to :organisation, Apiary.Organisations.Organisation

    field :status, :string
    field :resets_at, :utc_datetime_usec
    field :utilization, :integer
    field :cooldown_until, :utc_datetime_usec
    field :source, :string
    field :observed_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @doc "The statuses a window has: allowed, allowed_warning and rejected."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The sources of a cooldown or a reset: provider, schedule and pause_for."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc "Whether `window` is a window's code: `^[a-z][a-z0-9_]{0,63}$`."
  @spec window?(term) :: boolean
  def window?(window), do: is_binary(window) and Regex.match?(@window, window)
end
