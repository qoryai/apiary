defmodule Apiary.Runs.Delivery do
  @moduledoc """
  One batch as the receiver answered it: which key delivered it, for which
  subject, how many events it held and how many were new, and the status
  answered. `run_id` is the subject of the batch, not a row of `runs`.
  `run_configuration_digest` is what the batch's `X-Qory-Run-Configuration` said
  the run holds, nil when it said nothing or no digest. Nothing else of the
  request's headers, and nothing of its body, is kept here.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "deliveries" do
    field :delivery_id, Ecto.UUID
    field :run_id, Ecto.UUID
    field :received_at, :utc_datetime_usec
    field :event_count, :integer, default: 0
    field :inserted_count, :integer, default: 0
    field :status, :integer
    field :run_configuration_digest, :string

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :hive, Apiary.Organisations.Hive
    belongs_to :access_key, Apiary.AccessKeys.AccessKey
  end
end
