defmodule Apiary.Secrets.InstanceSecretValue do
  @moduledoc """
  A value of a secret of the instance (`Apiary.Secrets.InstanceSecret`): its value id,
  unique in its secret, and the value encrypted under the instance's data key
  (`Apiary.Secrets.InstanceDataKey`) with the v3 associated data
  (`Apiary.Secrets.Cipher`), as a nonce and a ciphertext with its tag. `value`, virtual,
  is the plaintext: set by the caller of a write, and by
  `Apiary.Secrets.Instance.reveal_app_values_for_sealing/1`, whose values a delivery
  seals (`Apiary.Secrets.AdapterSealing.delivery/3`). `nonce`, `ciphertext` and `value` are left
  out of `inspect`.
  """
  use Ecto.Schema

  @typedoc "A value of a secret of the instance."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "instance_secret_values" do
    field :value_id, :string
    field :nonce, :binary, redact: true
    field :ciphertext, :binary, redact: true
    field :value, :string, virtual: true, redact: true

    belongs_to :secret, Apiary.Secrets.InstanceSecret

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
