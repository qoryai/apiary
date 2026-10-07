defmodule Apiary.AccessKeysTest do
  use Apiary.DataCase, async: true

  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.AccessKey

  describe "fetch_for_verification/1" do
    test "is :error for unknown ids, and for anything but a binary" do
      assert :error = AccessKeys.fetch_for_verification("ak_0000000000000000")
      assert :error = AccessKeys.fetch_for_verification(nil)
    end

    test "gives the key with its workspace and node" do
      %{scope: scope} = sign_up_fixture()
      %{access_key: key, node: node} = access_key_fixture(scope)

      assert {:ok, %AccessKey{} = fetched} = AccessKeys.fetch_for_verification(key.key_id)
      assert fetched.id == key.id
      assert fetched.workspace.id == scope.workspace.id
      assert fetched.node.id == node.id
    end
  end

  describe "revoke_access_key/2" do
    test "an admin whose membership is gone cannot revoke" do
      %{scope: scope} = sign_up_fixture()
      %{scope: admin_scope, membership: membership} = member_fixture(scope, :admin)
      %{access_key: key} = access_key_fixture(admin_scope)

      assert {:ok, _} = Apiary.Organisations.remove_member(scope, membership.id)

      assert {:error, :forbidden} = AccessKeys.revoke_access_key(admin_scope, key)
      assert {:ok, %AccessKey{revoked_at: nil}} = AccessKeys.fetch_for_verification(key.key_id)
    end

    test "a key of another workspace cannot be revoked through a foreign scope" do
      %{scope: scope} = sign_up_fixture()
      %{scope: other_scope} = sign_up_fixture()
      %{access_key: key} = access_key_fixture(scope)

      assert_raise FunctionClauseError, fn -> AccessKeys.revoke_access_key(other_scope, key) end
    end
  end

  describe "touch/2" do
    test "records the use" do
      %{scope: scope} = sign_up_fixture()
      %{access_key: key} = access_key_fixture(scope)

      assert {:ok, key} =
               AccessKeys.touch(key, %{last_runner_version: "0.9.1", last_contract_version: 1})

      assert key.last_used_at
      assert key.last_runner_version == "0.9.1"
      assert key.last_contract_version == 1
      refute AccessKey.never_used?(key)
    end
  end
end
