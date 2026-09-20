defmodule Apiary.AccessKeys.AccessKey do
  @moduledoc """
  A hive's credential for the server contract: a public key id and up to two
  signing secrets, encrypted at rest and never shown after creation.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "access_keys" do
    field :key_id, :string
    field :label, :string
    field :secret_primary, Apiary.Encrypted.Binary, redact: true
    field :secret_secondary, Apiary.Encrypted.Binary, redact: true
    field :rotated_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :last_runner_version, :string
    field :last_contract_version, :integer
    # Set by the queries that leave the secret columns unloaded (listings and
    # everything handed to the web layer): whether a previous secret still verifies.
    field :rotating, :boolean, virtual: true, default: false

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :hive, Apiary.Organisations.Hive
    belongs_to :created_by, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(access_key, attrs) do
    access_key
    |> cast(attrs, [:label])
    |> validate_required([:label])
    |> validate_length(:label, min: 1, max: 80)
    |> validate_format(:label, ~r/\A[^[:cntrl:]]+\z/u,
      message: "must not contain control characters"
    )
    |> unique_constraint([:organisation_id, :hive_id, :label],
      name: :access_keys_active_label_index,
      error_key: :label,
      message: "is already the label of an active key in this hive"
    )
  end

  def touch_changeset(access_key, attrs) do
    access_key
    |> cast(attrs, [:last_runner_version, :last_contract_version])
    |> validate_length(:last_runner_version, max: 80)
    |> put_change(:last_used_at, DateTime.utc_now())
  end

  @doc "`:revoked` once revoked, `:rotating` while a previous secret still verifies, else `:active`."
  def status(%__MODULE__{revoked_at: revoked_at}) when not is_nil(revoked_at), do: :revoked
  def status(%__MODULE__{rotating: true}), do: :rotating
  def status(%__MODULE__{secret_secondary: secondary}) when not is_nil(secondary), do: :rotating
  def status(%__MODULE__{}), do: :active

  @doc "The schema fields a listing loads: everything except the two secret columns."
  def public_fields, do: __schema__(:fields) -- [:secret_primary, :secret_secondary]

  @doc "The key as the web layer may hold it: no secrets, `rotating` set from the secondary."
  def without_secrets(%__MODULE__{} = access_key) do
    %{
      access_key
      | rotating: access_key.rotating || not is_nil(access_key.secret_secondary),
        secret_primary: nil,
        secret_secondary: nil
    }
  end

  def never_used?(%__MODULE__{last_used_at: last_used_at}), do: is_nil(last_used_at)

  @doc "The secrets that verify a request: the primary and, during a rotation, the previous one."
  def secrets(%__MODULE__{secret_primary: primary, secret_secondary: nil}), do: [primary]

  def secrets(%__MODULE__{secret_primary: primary, secret_secondary: secondary}),
    do: [primary, secondary]

  # Crockford base32 without the ambiguous letters i, l, o, u.
  @crockford ~c"0123456789abcdefghjkmnpqrstvwxyz"

  @doc "A fresh key id: `ak_` and 16 lowercase Crockford base32 characters (80 random bits)."
  def generate_key_id do
    "ak_" <> crockford_encode(:crypto.strong_rand_bytes(10))
  end

  @doc "A fresh secret: 32 random bytes as base64url without padding."
  def generate_secret do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp crockford_encode(bytes) do
    for <<chunk::5 <- bytes>>, into: "", do: <<Enum.at(@crockford, chunk)>>
  end
end
