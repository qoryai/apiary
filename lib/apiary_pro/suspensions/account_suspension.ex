defmodule ApiaryPro.Suspensions.AccountSuspension do
  @moduledoc """
  An account suspension: a row means the account `user_id` is suspended
  (`ApiaryPro.Suspensions`), since `suspended_at`, by `suspended_by_id`, empty when a
  release command suspended it with no person behind it. Suspending the account inserts
  the row and activating it deletes the row, each under the account's row locked
  `FOR NO KEY UPDATE`, since the absence of a row cannot be locked; the row is never
  updated. The audit trail keeps the history. The row goes with its account.
  """
  use Ecto.Schema

  @primary_key {:user_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "account_suspensions" do
    field :suspended_at, :utc_datetime_usec
    field :suspended_by_id, :binary_id
  end

  @typedoc "A suspended account."
  @type t :: %__MODULE__{
          user_id: Ecto.UUID.t() | nil,
          suspended_at: DateTime.t() | nil,
          suspended_by_id: Ecto.UUID.t() | nil
        }
end
