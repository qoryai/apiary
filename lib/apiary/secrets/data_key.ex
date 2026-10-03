defmodule Apiary.Secrets.DataKey do
  @moduledoc """
  A workspace's data key, the key its stored secret values are encrypted under, kept only
  wrapped: `wrapped_key` is the data key encrypted under the instance's values key
  (`Apiary.KeyDerivation`, purpose `:values`; `Apiary.Secrets.Cipher`), and
  `wrapping_key_id` that key's id. One per workspace, made with its first secret, and
  read only inside `Apiary.Secrets`.
  """
  use Ecto.Schema

  @typedoc "A workspace's wrapped data key."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "workspace_data_keys" do
    field :wrapped_key, :binary, redact: true
    field :wrapping_key_id, :string

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
