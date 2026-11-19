defmodule Apiary.ModelKeys.Copy do
  @moduledoc """
  Which value of a model key a run has: one row per run and key that a gateway's secrets
  request (`POST /v1/secrets`) sealed for the run, with `value_set_at`, when the value it
  sealed last was set (`secret_values.value_set_at`). Migration 20261111220000 also wrote
  a row for each key of each run that was pending or running at the upgrade, with the
  key's `value_set_at` at that time. A report of the run's keys leaves out a key whose
  `value_set_at` differs from the row's (`Apiary.ModelKeys.record/4`). The row goes with
  the run and with the key.

  `login_at` is, for a key that is a sign-in (`Apiary.ModelKeys.Login`), the time of the
  sign-in or of its last refresh when the request read the token it sealed: which token the
  run has, since a refresh changes the token and not `value_set_at`. Nil for any other key
  and for a row written before the column.

  `login_sealed_at` is the database's time (`clock_timestamp()`) at the request that
  sealed the token of that `login_at` for the run, kept while later requests seal the same
  token, and nil where `login_at` is. A 401 that the gateway reports at an `at` before it
  was a 401 for an older token (`Apiary.ModelKeys.reject/4`).

  `marked_at` is the database's time (UTC) at which a report of the run marked the key as
  rejected by its provider (`Apiary.ModelKeys.reject/4`), nil until then. A run copy marks a
  key once for a value: a later report of the key by the run marks nothing and moves
  nothing, and a request that seals a new value for the run (another `value_set_at`)
  clears the mark, so that the run can mark the new value. A request that seals the same
  value keeps it.
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
    field :login_at, :utc_datetime_usec
    field :login_sealed_at, :utc_datetime_usec
    field :marked_at, :utc_datetime_usec
  end
end
