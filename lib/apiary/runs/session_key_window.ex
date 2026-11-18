defmodule Apiary.Runs.SessionKeyWindow do
  @moduledoc """
  What one model key's limit window showed while one session ran: one row for each
  session (`Apiary.Runs.SessionRecord`), key and window, written from the gateway's key
  reports that name the session (`Apiary.ModelKeys.record/4`).

  `key_id` is the id of the key's value (`model_key_states.secret_value_id`); no foreign
  key holds it, so the history stays when the key is deleted. `window` is a window of
  `Apiary.ModelKeys.State.windows/0`. `first_utilization` is the utilization, in whole
  percent, of the report with the earliest `observed_at` of the session, `last_utilization`
  that of the latest, with their times; `share` is the last less the first. A window that
  reset during the session makes the share negative. One percent of a large subscription
  is more than one percent of a small one, so a share compares only within one key.
  """
  use Ecto.Schema

  @typedoc "One key's window in one session."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "session_key_windows" do
    field :key_id, :binary_id
    field :window, :string
    field :first_utilization, :decimal
    field :first_observed_at, :utc_datetime_usec
    field :last_utilization, :decimal
    field :last_observed_at, :utc_datetime_usec
    field :share, :decimal

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :session_record, Apiary.Runs.SessionRecord

    timestamps(type: :utc_datetime_usec)
  end
end
