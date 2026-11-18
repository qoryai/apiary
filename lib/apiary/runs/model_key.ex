defmodule Apiary.Runs.ModelKey do
  @moduledoc """
  One model key a run's claim stored for the run (`Apiary.Dispatches.RunSettings`), in
  `run_model_keys`: at most 6 per run, of one or more model providers, one provider per
  session. Written once, with the run's registration, and never changed; not folded, so a
  rebuild keeps it.

  `position` is the key's place in the run configuration's `credentials`, from 1; `name`
  its credential name, `<provider's public id>-<place>`, the place counted per provider;
  `start` is true on the run's start key, the run configuration's `model_credential`.
  `secret_value_id` is the key's row id (`secret_values.id`), which a rename of the value
  id leaves as it is. `connection_id` and `secret_id` are the key's provider and that
  provider's keys' secret, each nil should its row be deleted, and `chain` the provider's
  chain. `api` is the provider's API that the key's sessions use: `format`, `endpoint`
  with a setting resolved to its address, `auth`, and, when the description lists them,
  `key_prefixes` and the limit windows as `use_up_to_windows`. The rest is what the claim
  wrote for the run configuration: the key's Pause for (`pause_for_s`), and, where the
  claim had them, `resets_at`, `schedule_resets_at`, `cooldown_until`, `chosen` and
  `use_up_to_percent`. No row has a key value. The key's row id, the secret's id and the
  API are left out of the struct's inspection.
  """
  use Ecto.Schema

  @typedoc "A model key of a run."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "run_model_keys" do
    belongs_to :run, Apiary.Runs.Run
    field :position, :integer
    field :name, :string
    field :start, :boolean, default: false
    field :secret_value_id, :binary_id, redact: true
    belongs_to :connection, Apiary.Connections.Connection
    field :secret_id, :binary_id, redact: true
    field :chain, :string
    field :api, :map, redact: true
    field :pause_for_s, :integer
    field :resets_at, :utc_datetime
    field :schedule_resets_at, :utc_datetime
    field :cooldown_until, :utc_datetime
    field :chosen, :boolean, default: false
    field :use_up_to_percent, :integer
  end

  # The fields a claim writes for a key, all but the run's id.
  @fields ~w(position name start secret_value_id connection_id secret_id chain api
             pause_for_s resets_at schedule_resets_at cooldown_until chosen
             use_up_to_percent)a

  @doc false
  # fields/0 is the fields a claim writes for each key, besides `run_id`.
  @spec fields() :: [atom]
  def fields, do: @fields
end
