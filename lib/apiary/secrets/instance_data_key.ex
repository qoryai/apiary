defmodule Apiary.Secrets.InstanceDataKey do
  @moduledoc """
  The instance's data key, the key the values of the instance's secrets are encrypted
  under (`Apiary.Secrets.Instance`), kept only wrapped: `wrapped_key` is the data key
  encrypted under the instance's values key (`Apiary.KeyDerivation`, purpose `:values`;
  `Apiary.Secrets.Cipher`, v3), and `wrapping_key_id` that key's id. One row, whose `id`
  is `true`, made with the instance's first secret.
  """
  use Ecto.Schema

  @typedoc "The instance's wrapped data key."
  @type t :: %__MODULE__{}

  @primary_key {:id, :boolean, autogenerate: false}
  schema "instance_data_keys" do
    field :wrapped_key, :binary, redact: true
    field :wrapping_key_id, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
