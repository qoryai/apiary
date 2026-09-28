defmodule Apiary.AccessKeysUnreadableTest do
  @moduledoc """
  An access key whose secrets were encrypted under another `CLOAK_KEY`: what a restore of
  a dump without its key, or a changed key, leaves in the table.
  """
  use Apiary.DataCase, async: true

  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Contract.Signature

  # The same secret, encrypted with a key this instance does not hold.
  @other_key [
    ciphers: [
      default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: :crypto.strong_rand_bytes(32)}
    ]
  ]

  defp under_another_key(%AccessKey{id: id}, secret) do
    {:ok, ciphertext} = Cloak.Vault.encrypt(@other_key, secret)
    {:ok, uuid} = Ecto.UUID.dump(id)
    Repo.query!("UPDATE access_keys SET secret_primary = $1 WHERE id = $2", [ciphertext, uuid])
  end

  setup do
    scope = scope_fixture()
    %{access_key: key, secret: secret} = access_key_fixture(scope)
    under_another_key(key, secret)
    %{scope: scope, key: key, secret: secret}
  end

  test "verification says the secret is unreadable, in the log too, never 401's :error", %{
    scope: scope,
    key: key
  } do
    log =
      capture_log(fn ->
        assert AccessKeys.fetch_for_verification(key.key_id) == {:error, :unreadable}
      end)

    assert log =~ "access key secret cannot be decrypted key_id=#{key.key_id}"
    assert log =~ "CLOAK_KEY"
    # The line names the key's organisation and workspace by id, as metadata.
    assert log =~ "organisation_id=#{scope.organisation.id}"
    assert log =~ "workspace_id=#{scope.workspace.id}"
  end

  test "the key is still listed, without its secrets", %{scope: scope, key: key} do
    assert [%AccessKey{id: id, secret_primary: nil}] = AccessKeys.list_access_keys(scope)
    assert id == key.id
    assert %AccessKey{} = AccessKeys.get_access_key!(scope, key.id)
  end

  test "a rotation issues a new secret in place of the unreadable ones, and it verifies", %{
    scope: scope,
    key: key
  } do
    assert {:ok, rotated, secret} = AccessKeys.rotate_access_key(scope, key)
    refute rotated.rotating

    assert {:ok, %AccessKey{} = fetched} = AccessKeys.fetch_for_verification(key.key_id)
    assert AccessKey.secrets(fetched) == [secret]
    assert Signature.verify([secret], "body", Signature.sign(secret, "body"))
  end

  test "retiring and revoking still work", %{scope: scope, key: key} do
    assert {:ok, %AccessKey{rotating: false}} = AccessKeys.retire_previous_secret(scope, key)
    assert {:ok, %AccessKey{revoked_at: %DateTime{}}} = AccessKeys.revoke_access_key(scope, key)
    assert AccessKeys.fetch_for_verification(key.key_id) == :error
  end
end
