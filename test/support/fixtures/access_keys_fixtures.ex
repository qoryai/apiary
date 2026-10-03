defmodule Apiary.AccessKeysFixtures do
  @moduledoc "Test helpers for access keys."

  alias Apiary.{AccessKeys, Repo}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode, PublicKey}

  def unique_label, do: "runner #{System.unique_integer([:positive])}"

  @doc """
  A key in the scope's workspace, and the secret it was created with. The key carries its
  workspace, as a verified key does (`Apiary.AccessKeys.fetch_for_verification/1`).
  """
  def access_key_fixture(scope, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{label: unique_label()})
    {:ok, access_key, secret} = AccessKeys.create_access_key(scope, attrs)
    %{access_key: %{access_key | workspace: scope.workspace}, secret: secret}
  end

  @doc """
  A fresh Ed25519 key pair, as `qory access-key create` makes one: `%{public_key: raw,
  encoded: base64url, secret: raw}`.
  """
  def ed25519_key_pair do
    {public, secret} = :crypto.generate_key(:eddsa, :ed25519)
    %{public_key: public, encoded: Base.url_encode64(public, padding: false), secret: secret}
  end

  @doc """
  A key pasted on `node` by the scope's person, an owner or an admin: approved at once.
  Returns `%{access_key: key, pair: key pair}`.
  """
  def node_key_fixture(scope, node, attrs \\ %{}) do
    pair = ed25519_key_pair()
    attrs = Enum.into(attrs, %{label: unique_label(), public_key: pair.encoded})
    {:ok, key} = AccessKeys.add_access_key(scope, node, attrs)
    %{access_key: key, pair: pair}
  end

  @doc """
  A key awaiting approval on `node`, as an enrolment with a code of the scope's person
  leaves one: the code made and used, the key inserted pending, with its integrity code
  and its row of the ledger. A stand-in for the enrolment endpoint, which is not built
  yet. Returns `%{access_key: key, pair: key pair, code: code row}`.
  """
  def pending_key_fixture(scope, node, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{allow_secrets: false, label: unique_label()})
    {:ok, code_row, _code} = AccessKeys.create_enrolment_code(scope, node, attrs)
    pair = ed25519_key_pair()
    now = DateTime.utc_now()
    key_id = AccessKey.generate_key_id()

    code_row =
      code_row
      |> Ecto.Changeset.change(used_at: now, used_by_key_id: key_id, public_key: pair.public_key)
      |> EnrolmentCode.put_integrity()
      |> Repo.update!()

    key =
      %AccessKey{
        id: Ecto.UUID.generate(),
        organisation_id: node.organisation_id,
        workspace_id: node.workspace_id,
        node_id: node.id,
        key_id: key_id,
        public_key: pair.public_key,
        arrived_by: :code,
        enrolment_code_id: code_row.id,
        received_at: now,
        created_by_id: code_row.created_by_id
      }
      |> AccessKey.insert_changeset(%{allow_secrets: code_row.allow_secrets, label: attrs.label})
      |> AccessKey.put_integrity()
      |> Repo.insert!()

    Repo.insert!(%PublicKey{
      public_key: pair.public_key,
      key_id: key_id,
      state: :pending,
      received_at: now
    })

    %{access_key: key, pair: pair, code: code_row}
  end
end
