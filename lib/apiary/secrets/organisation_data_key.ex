defmodule Apiary.Secrets.OrganisationDataKey do
  @moduledoc """
  An organisation's data key, the key the values of its organisation's stored secrets are
  encrypted under, kept only wrapped: `wrapped_key` is the data key encrypted under the
  instance's values key (`Apiary.KeyDerivation`, purpose `:values`;
  `Apiary.Secrets.Cipher`), and `wrapping_key_id` that key's id. One per organisation,
  made with its first secret, and read only inside `Apiary.Secrets`. A workspace's
  secrets have the workspace's data key (`Apiary.Secrets.DataKey`).
  """
  use Ecto.Schema

  @typedoc "An organisation's wrapped data key."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "organisation_data_keys" do
    field :wrapped_key, :binary, redact: true
    field :wrapping_key_id, :string

    belongs_to :organisation, Apiary.Organisations.Organisation

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
