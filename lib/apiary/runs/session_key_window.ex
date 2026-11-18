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

  import Ecto.Changeset

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

  @fields ~w(key_id window first_utilization first_observed_at last_utilization
             last_observed_at share)a

  @doc """
  The changeset of a window of a session record: the key and the window are required, each
  utilization is 0 to 100 and the share -100 to 100; the record's ids are the caller's to
  put.
  """
  @spec changeset(t, map) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = window, attrs) do
    window
    |> cast(attrs, @fields)
    |> validate_required([:key_id, :window])
    |> validate_format(:window, ~r/\A[a-z][a-z0-9_]{0,63}\z/)
    |> validate_number(:first_utilization,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> validate_number(:last_utilization, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:share, greater_than_or_equal_to: -100, less_than_or_equal_to: 100)
    |> unique_constraint(:window,
      name: :session_key_windows_session_record_id_key_id_window_index
    )
    |> check_constraint(:window, name: :session_key_windows_window_check)
    |> check_constraint(:first_utilization, name: :session_key_windows_utilization_check)
    |> check_constraint(:share, name: :session_key_windows_share_check)
  end
end
