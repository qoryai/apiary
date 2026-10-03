defmodule Apiary.AccessKeys.AccessKey do
  @moduledoc """
  A workspace's credential for the server contract, named by its key id, `ak_` and
  sixteen characters (`Apiary.PublicId`). It is one of two:

    * **today's key**, with up to two signing secrets the server made, encrypted at rest
      and never shown after creation, and no node: `secret_primary`, `secret_secondary`,
      `rotated_at`;
    * **a node's key**: one Ed25519 public key (`public_key`, 32 bytes) on a node or a
      node pool of the workspace (`node_id`), with no secret. It arrived by an enrolment
      code or by a paste (`arrived_by`), awaits approval until an owner or an admin
      approves it (a pasted key is approved as it is entered), and carries the
      stored-secrets flag (`allow_secrets`) it was made with.

  A node's key's node, public key, stored-secrets flag and arrival are fixed when it is
  made (`insert_changeset/2`): no changeset casts them after, and the database refuses an
  UPDATE that changes them. Its row carries an integrity code (`Apiary.Integrity`) over
  `integrity_fields/1`, which `Apiary.AccessKeys` writes with every change of those
  fields and checks before the key is trusted.
  """
  use Ecto.Schema
  use Gettext, backend: ApiaryWeb.Gettext
  import Ecto.Changeset

  @typedoc "An access key of a workspace."
  @type t :: %__MODULE__{}

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
    field :last_heartbeat_at, :utc_datetime_usec
    field :public_key, :binary
    field :received_at, :utc_datetime_usec
    field :approved_at, :utc_datetime_usec
    field :allow_secrets, :boolean, default: false
    field :rate, :integer
    field :burst, :integer
    field :arrived_by, Ecto.Enum, values: [:code, :paste]
    field :integrity_code, :binary, redact: true
    field :integrity_key_id, :string
    field :last_pending_at, :utc_datetime_usec
    # Set by the queries that leave the secret columns unloaded (listings and
    # everything handed to the web layer): whether a previous secret still verifies.
    field :rotating, :boolean, virtual: true, default: false

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :created_by, Apiary.Accounts.User
    belongs_to :node, Apiary.Nodes.Node
    belongs_to :approved_by, Apiary.Accounts.User
    belongs_to :revoked_by, Apiary.Accounts.User
    belongs_to :enrolment_code, Apiary.AccessKeys.EnrolmentCode

    timestamps(type: :utc_datetime_usec)
  end

  @integrity_kind "access_key"
  @integrity_version 1

  @doc """
  changeset/2 is the changeset of a key's label: 1 to 80 characters without control
  characters, unique among the workspace's keys in use for today's key, and among the
  node's keys in use for a node's key.
  """
  @spec changeset(t, map) :: Ecto.Changeset.t()
  def changeset(access_key, attrs) do
    access_key
    |> cast(attrs, [:label])
    |> validate_required([:label])
    |> validate_length(:label, min: 1, max: 80)
    |> validate_format(:label, ~r/\A[^[:cntrl:]]+\z/u,
      message: dgettext_noop("errors", "must not contain control characters")
    )
    |> unique_constraint([:organisation_id, :workspace_id, :label],
      name: :access_keys_active_label_index,
      error_key: :label,
      message: dgettext_noop("errors", "is already the label of an active key in this workspace")
    )
    |> unique_constraint([:node_id, :label],
      name: :access_keys_node_label_index,
      error_key: :label,
      message: dgettext_noop("errors", "is already the label of a key of this node")
    )
  end

  @doc """
  refuse_public_key/1 is `changeset` with the one error every refused public key gets,
  whatever the reason: "this key cannot be used", so a refusal reveals nothing about other
  keys.
  """
  @spec refuse_public_key(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def refuse_public_key(%Ecto.Changeset{} = changeset) do
    changeset
    |> add_error(:public_key, dgettext_noop("errors", "this key cannot be used"))
    |> Map.put(:action, :insert)
  end

  @doc """
  insert_changeset/2 is the changeset of a new node's key, `access_key` carrying its
  organisation, workspace, node, key id, public key, arrival and maker as the caller set
  them: the label as `changeset/2` checks it, and the stored-secrets flag from `attrs`,
  the one time it is cast.
  """
  @spec insert_changeset(t, map) :: Ecto.Changeset.t()
  def insert_changeset(%__MODULE__{} = access_key, attrs) do
    access_key
    |> cast(attrs, [:allow_secrets])
    |> validate_required([:allow_secrets])
    |> changeset(attrs)
  end

  def touch_changeset(access_key, attrs) do
    access_key
    |> cast(attrs, [:last_runner_version, :last_contract_version])
    |> validate_length(:last_runner_version, max: 80)
    |> put_change(:last_used_at, DateTime.utc_now())
  end

  @doc """
  status/1 is `:revoked` once revoked (or, for a node's key, rejected), `:pending` for a
  node's key that awaits approval, `:rotating` while a previous secret of today's key
  still verifies, else `:active`.
  """
  @spec status(t) :: :revoked | :pending | :rotating | :active
  def status(%__MODULE__{revoked_at: revoked_at}) when not is_nil(revoked_at), do: :revoked

  def status(%__MODULE__{public_key: public_key, approved_at: nil}) when is_binary(public_key),
    do: :pending

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

  @doc """
  The secrets that verify a request: the primary and, during a rotation, the previous
  one. A node's key has none, so no secret verifies a request under it.
  """
  def secrets(%__MODULE__{secret_primary: nil}), do: []
  def secrets(%__MODULE__{secret_primary: primary, secret_secondary: nil}), do: [primary]

  def secrets(%__MODULE__{secret_primary: primary, secret_secondary: secondary}),
    do: [primary, secondary]

  @doc "A fresh key id: `ak_` and 16 lowercase Crockford base32 characters (`Apiary.PublicId`)."
  def generate_key_id, do: Apiary.PublicId.generate("ak")

  @doc "A fresh secret: 32 random bytes as base64url without padding."
  def generate_secret do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  @doc "node_key?/1 says whether `access_key` is a node's key, with a public key."
  @spec node_key?(t) :: boolean
  def node_key?(%__MODULE__{public_key: public_key}), do: is_binary(public_key)

  @doc """
  fingerprint/1 is a node's key's fingerprint, `base64url(SHA-256(public key)[:16])`, 22
  characters (`Apiary.Contract.Ed25519.fingerprint/1`), or nil for today's key.
  """
  @spec fingerprint(t) :: String.t() | nil
  def fingerprint(%__MODULE__{public_key: <<_::binary-size(32)>> = key}),
    do: Apiary.Contract.Ed25519.fingerprint(key)

  def fingerprint(%__MODULE__{}), do: nil

  @doc """
  integrity_fields/1 is what a node's key's integrity code covers, in its fixed order:
  what names it and binds it to its workspace and node, its public key, its stored-secrets
  flag and rate, how and when it arrived, and its approval and revocation. Its label and
  its last use are outside the code.
  """
  @spec integrity_fields(t) :: Apiary.Integrity.fields()
  def integrity_fields(%__MODULE__{} = key) do
    [
      id: key.id,
      organisation_id: key.organisation_id,
      workspace_id: key.workspace_id,
      node_id: key.node_id,
      key_id: key.key_id,
      public_key: key.public_key,
      allow_secrets: key.allow_secrets,
      rate: key.rate,
      burst: key.burst,
      arrived_by: key.arrived_by,
      enrolment_code_id: key.enrolment_code_id,
      received_at: key.received_at,
      approved_at: key.approved_at,
      approved_by_id: key.approved_by_id,
      revoked_at: key.revoked_at,
      revoked_by_id: key.revoked_by_id
    ]
  end

  @doc """
  put_integrity/1 sets a node's key's integrity code and its key id from the fields of
  `changeset` as they will be written (`integrity_fields/1`).
  """
  @spec put_integrity(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def put_integrity(%Ecto.Changeset{} = changeset) do
    {key_id, code} =
      Apiary.Integrity.code(
        @integrity_kind,
        @integrity_version,
        changeset |> apply_changes() |> integrity_fields()
      )

    changeset
    |> put_change(:integrity_key_id, key_id)
    |> put_change(:integrity_code, code)
  end

  @doc """
  verify_integrity/1 checks a node's key's integrity code against its row: `:ok`, or
  `{:error, :mismatch | :unknown_key}` (`Apiary.Integrity.verify/5`). Today's key has no
  code, and nothing to check.
  """
  @spec verify_integrity(t) :: :ok | {:error, :mismatch | :unknown_key}
  def verify_integrity(%__MODULE__{public_key: nil}), do: :ok

  def verify_integrity(%__MODULE__{} = key) do
    Apiary.Integrity.verify(
      @integrity_kind,
      @integrity_version,
      integrity_fields(key),
      key.integrity_key_id,
      key.integrity_code
    )
  end
end
