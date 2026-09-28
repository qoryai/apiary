defmodule Apiary.Deletion.PurgedOrganisation do
  @moduledoc """
  The one line the instance keeps of an organisation it purged (`Apiary.Deletion`),
  written in the transaction that deletes the organisation's row, since the
  organisation's audit trail goes with it: its id, when it was marked for deletion and by
  whom (a person's id, nil for the instance), when it was purged, and why (`trigger`),
  with the instance admin who asked for an erasure (`requested_by_id`):
  `grace_period`, the daily sweep once the grace period was over, or `erasure_request`,
  a purge at once on an erasure request (`Apiary.Deletion.purge_now/3`). No name and no
  slug: nothing that says who the organisation was.

  The instance's own table, of no organisation: it is not one of `Apiary.Deletion.Tables`'s.
  Written once per organisation and never changed.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @triggers ~w(grace_period erasure_request)

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "purged_organisations" do
    field :marked_at, :utc_datetime_usec
    field :purged_at, :utc_datetime_usec
    field :trigger, :string

    belongs_to :marked_by, Apiary.Accounts.User
    belongs_to :requested_by, Apiary.Accounts.User
  end

  @doc "Why an organisation was purged: `grace_period` or `erasure_request`."
  @spec triggers() :: [String.t()]
  def triggers, do: @triggers
end
