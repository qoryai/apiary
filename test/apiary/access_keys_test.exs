defmodule Apiary.AccessKeysTest do
  use Apiary.DataCase, async: true

  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Contract.Signature

  describe "create_access_key/2" do
    test "secrets never reach the query log" do
      %{scope: scope} = sign_up_fixture()
      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          {:ok, key, secret} = AccessKeys.create_access_key(scope, %{label: "logged"})
          {:ok, key, new_secret} = AccessKeys.rotate_access_key(scope, key)
          {:ok, _key} = AccessKeys.retire_previous_secret(scope, key)
          send(self(), {:secrets, secret, new_secret})
        end)

      assert_received {:secrets, secret, new_secret}
      assert log =~ ~s(INSERT INTO "access_keys")
      assert log =~ ~s(UPDATE "access_keys")
      refute log =~ secret
      refute log =~ new_secret
    end

    test "creates a key with a well-formed id and secret, any member" do
      %{scope: scope, user: user} = sign_up_fixture()
      %{scope: member_scope} = member_fixture(scope, :member)

      assert {:ok, %AccessKey{} = key, secret} =
               AccessKeys.create_access_key(scope, %{label: "laptop"})

      assert key.key_id =~ ~r/^ak_[0-9abcdefghjkmnpqrstvwxyz]{16}$/
      assert byte_size(secret) == 43
      assert {:ok, <<_::binary-size(32)>>} = Base.url_decode64(secret, padding: false)
      assert key.secret_primary == secret
      assert key.secret_secondary == nil
      assert key.created_by_id == user.id
      assert key.hive_id == scope.hive.id
      assert AccessKey.status(key) == :active
      assert AccessKey.never_used?(key)

      assert {:ok, _key, _secret} = AccessKeys.create_access_key(member_scope, %{label: "ci"})
    end

    test "validates the label and its uniqueness among active keys of the hive" do
      %{scope: scope} = sign_up_fixture()
      assert {:error, changeset} = AccessKeys.create_access_key(scope, %{label: ""})
      assert %{label: ["can't be blank"]} = errors_on(changeset)

      assert {:error, changeset} =
               AccessKeys.create_access_key(scope, %{label: String.duplicate("x", 81)})

      assert %{label: [_]} = errors_on(changeset)

      %{access_key: key} = access_key_fixture(scope, %{label: "dup"})
      assert {:error, changeset} = AccessKeys.create_access_key(scope, %{label: "dup"})
      assert %{label: [_]} = errors_on(changeset)

      {:ok, _} = AccessKeys.revoke_access_key(scope, key)
      assert {:ok, _, _} = AccessKeys.create_access_key(scope, %{label: "dup"})

      assert %Ecto.Changeset{} = AccessKeys.change_access_key(%AccessKey{}, %{label: "x"})
    end
  end

  describe "listing" do
    test "list_access_keys/1 puts active keys first, newest first, and get_access_key!/2 is scoped" do
      %{scope: scope} = sign_up_fixture()
      %{scope: other_scope} = sign_up_fixture()
      %{access_key: first} = access_key_fixture(scope)
      %{access_key: second} = access_key_fixture(scope)
      %{access_key: third} = access_key_fixture(scope)
      {:ok, _} = AccessKeys.revoke_access_key(scope, third)
      _elsewhere = access_key_fixture(other_scope)

      assert [second.id, first.id, third.id] ==
               scope |> AccessKeys.list_access_keys() |> Enum.map(& &1.id)

      assert AccessKeys.get_access_key!(scope, first.id).id == first.id

      assert_raise Ecto.NoResultsError, fn ->
        AccessKeys.get_access_key!(other_scope, first.id)
      end
    end
  end

  describe "rotation and revocation" do
    test "rotate keeps the old secret verifying, retire drops it, revoke stops both at once" do
      %{scope: scope} = sign_up_fixture()
      %{access_key: key, secret: old_secret} = access_key_fixture(scope)
      canonical = Signature.canonical_string("get", "/x", 1)

      assert {:ok, key, new_secret} = AccessKeys.rotate_access_key(scope, key)
      assert new_secret != old_secret
      assert key.secret_primary == new_secret
      assert key.secret_secondary == old_secret
      assert key.rotated_at
      assert AccessKey.status(key) == :rotating

      {:ok, loaded} = AccessKeys.fetch_for_verification(key.key_id)

      assert Signature.verify(
               AccessKey.secrets(loaded),
               canonical,
               Signature.sign(old_secret, canonical)
             )

      assert Signature.verify(
               AccessKey.secrets(loaded),
               canonical,
               Signature.sign(new_secret, canonical)
             )

      # A second rotation drops the oldest secret.
      assert {:ok, key, third_secret} = AccessKeys.rotate_access_key(scope, key)
      assert key.secret_secondary == new_secret
      {:ok, loaded} = AccessKeys.fetch_for_verification(key.key_id)

      refute Signature.verify(
               AccessKey.secrets(loaded),
               canonical,
               Signature.sign(old_secret, canonical)
             )

      assert {:ok, key} = AccessKeys.retire_previous_secret(scope, key)
      assert key.secret_secondary == nil
      assert AccessKey.status(key) == :active
      {:ok, loaded} = AccessKeys.fetch_for_verification(key.key_id)

      refute Signature.verify(
               AccessKey.secrets(loaded),
               canonical,
               Signature.sign(new_secret, canonical)
             )

      assert Signature.verify(
               AccessKey.secrets(loaded),
               canonical,
               Signature.sign(third_secret, canonical)
             )

      assert {:ok, key} = AccessKeys.revoke_access_key(scope, key)
      assert key.revoked_at
      assert AccessKey.status(key) == :revoked
      assert :error = AccessKeys.fetch_for_verification(key.key_id)
      assert {:error, :revoked} = AccessKeys.rotate_access_key(scope, key)
    end

    test "fetch_for_verification/1 is :error for unknown ids" do
      assert :error = AccessKeys.fetch_for_verification("ak_0000000000000000")
      assert :error = AccessKeys.fetch_for_verification(nil)
    end

    test "a key of another hive cannot be rotated through a foreign scope" do
      %{scope: scope} = sign_up_fixture()
      %{scope: other_scope} = sign_up_fixture()
      %{access_key: key} = access_key_fixture(scope)

      assert_raise FunctionClauseError, fn -> AccessKeys.rotate_access_key(other_scope, key) end
      assert_raise FunctionClauseError, fn -> AccessKeys.revoke_access_key(other_scope, key) end
    end
  end

  describe "touch/2 and server_block/3" do
    test "touch records the use" do
      %{scope: scope} = sign_up_fixture()
      %{access_key: key} = access_key_fixture(scope)

      assert {:ok, key} =
               AccessKeys.touch(key, %{last_runner_version: "0.9.1", last_contract_version: 1})

      assert key.last_used_at
      assert key.last_runner_version == "0.9.1"
      assert key.last_contract_version == 1
      refute AccessKey.never_used?(key)
    end

    test "server_block renders the runner file section" do
      %{scope: scope} = sign_up_fixture()
      %{access_key: key, secret: secret} = access_key_fixture(scope)

      assert AccessKeys.server_block(key, secret, "https://apiary.example.com") == """
             apiVersion: qory.dev/v1alpha1
             server:
               url: https://apiary.example.com
               access_key: #{key.key_id}
               secret: #{secret}
             """
    end
  end

  describe "K5: secrets at rest" do
    test "the stored column is ciphertext that decrypts through the vault; inspect hides the secret" do
      %{scope: scope} = sign_up_fixture()
      %{access_key: key, secret: secret} = access_key_fixture(scope)

      %{rows: [[stored]]} =
        Repo.query!("SELECT secret_primary FROM access_keys WHERE id = $1", [
          Ecto.UUID.dump!(key.id)
        ])

      refute stored == secret
      refute stored =~ secret
      assert {:ok, ^secret} = Apiary.Vault.decrypt(stored)

      refute inspect(key) =~ secret
      refute inspect(key) =~ "secret_primary"
    end
  end
end
