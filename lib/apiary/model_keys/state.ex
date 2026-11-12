defmodule Apiary.ModelKeys.State do
  @moduledoc """
  The state of one model key in one limit window, as a run's gateway reports it from the
  provider's responses (`Apiary.ModelKeys.Report`): one row per key, by the value's row
  id (`secret_values.id`), and window.

    * `window`: the limit's window, one of `windows/0`, such as `five_hour` or
      `seven_day`. A report may have any code of the form `^[a-z][a-z0-9_]{0,63}$`; a
      window outside `windows/0` is not stored (`Apiary.ModelKeys.record/3`).
    * `status`: `allowed`, `allowed_warning` or `rejected`.
    * `resets_at`: when the window resets, nil when the response gave no time.
    * `utilization`: the window's use in whole percent, 0 to 100, nil when the response
      gave none. A read leaves it out once `resets_at` has passed
      (`Apiary.ModelKeys.current/2`).
    * `cooldown_until`: until when the key is not used; the key is in cooldown while it
      is in the future.
    * `source`: where `cooldown_until` or `resets_at` comes from: `provider`, the response;
      `schedule`, the key's weekly reset; `pause_for`, the key's Pause for.
    * `observed_at`: the gateway's clock when the response arrived. A report keeps the row
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
  # The windows a gateway reports, as the Forager contract lists them for `window` in
  # `model-keys-report.schema.json`: a subscription's, an API key's, and `key` for a limit
  # refusal with no window in it. Change it with the contract's list.
  @windows ~w(five_hour seven_day seven_day_opus seven_day_sonnet overage
              requests tokens input_tokens output_tokens spend_limit key)

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

  @doc "The windows a key's state is kept for, the contract's list: 11 codes."
  @spec windows() :: [String.t()]
  def windows, do: @windows

  @doc "Whether `window` is one of `windows/0`."
  @spec known_window?(term) :: boolean
  def known_window?(window), do: window in @windows

  @doc "Whether `window` is a window's code: `^[a-z][a-z0-9_]{0,63}$`."
  @spec window?(term) :: boolean
  def window?(window), do: is_binary(window) and Regex.match?(@window, window)
end
