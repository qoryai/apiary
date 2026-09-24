defmodule Apiary.Organisations.Invitation do
  @moduledoc """
  An invitation to join an organisation's hive, sent to an email address.

  The URL token is never stored; only its SHA-256 hash is. An invitation is
  pending while `accepted_at` is nil and `expires_at` is in the future.
  """
  use Ecto.Schema
  use Gettext, backend: ApiaryWeb.Gettext
  import Ecto.Changeset

  @validity_days 7

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "invitations" do
    field :email, :string
    field :level, Ecto.Enum, values: Apiary.Organisations.Membership.levels(), default: :member
    field :token_hash, :binary, redact: true
    field :accepted_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :hive, Apiary.Organisations.Hive
    belongs_to :invited_by, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def validity_days, do: @validity_days

  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:email, :level])
    |> update_change(:email, &String.downcase(String.trim(&1)))
    |> validate_required([:email, :level])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: dgettext_noop("errors", "must have the @ sign and no spaces")
    )
    |> validate_length(:email, max: 160)
    |> unique_constraint([:organisation_id, :email],
      name: :invitations_pending_email_index,
      error_key: :email,
      message: dgettext_noop("errors", "has already been invited")
    )
  end

  @doc "A fresh URL token and the hash that is stored for it."
  def build_token do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    {token, hash_token(token)}
  end

  def hash_token(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  def pending?(%__MODULE__{accepted_at: nil, expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  def pending?(%__MODULE__{}), do: false
end
