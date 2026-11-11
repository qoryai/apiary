defmodule Apiary.ModelKeys.Copy do
  @moduledoc """
  Which value of a model key a run has: one row per run and key that a gateway's secrets
  request (`POST /v1/secrets`) sealed for the run, with `value_set_at`, when the value it
  sealed last was set (`secret_values.value_set_at`). A report of the run's keys leaves
  out a key whose value was set after the run's value (`Apiary.ModelKeys.record/3`). The
  row goes with the run and with the key.
  """

  use Ecto.Schema

  @typedoc "The value of a model key a run has."
  @type t :: %__MODULE__{}

  @primary_key false
  @foreign_key_type :binary_id
  schema "model_key_copies" do
    field :run_id, :binary_id, primary_key: true
    field :secret_value_id, :binary_id, primary_key: true
    field :value_set_at, :utc_datetime_usec
  end
end
