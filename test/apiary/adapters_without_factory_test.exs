defmodule Apiary.AdaptersWithoutFactoryTest do
  # An instance without the feature adapters belong to: no adapter is made or changed,
  # none of their keys is enrolled or revoked, none of their codes is cancelled, and no pool
  # names one or lets one go. The adapters there already stay as they are. Not async: the
  # features are the whole node's.
  use Apiary.DataCase, async: false

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Access, AccessKeys, Adapters, Nodes}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Accounts.Scope
  alias Apiary.Contract.{Ed25519, Enrolment, SignedMessage}
  alias Apiary.Nodes.Node

  # The adapters are made where the feature is on, before it is turned off.
  @moduletag needs: :factory

  @without [:observability, :security]

  # Made with every feature, as an instance had them before it was launched without one.
  setup do
    %{scope: scope} = sign_up_fixture()
    adapter = adapter_fixture(scope)
    {:ok, code_row, code} = AccessKeys.create_enrolment_code(scope, adapter, %{})
    %{access_key: key} = enrolled_key_fixture(scope, adapter)
    served = pool_fixture(scope, %{served_by_id: adapter.id})
    previous = Application.get_env(:apiary, :features)
    {:ok, features} = Apiary.Features.parse(Enum.map_join(@without, ",", &to_string/1))
    Application.put_env(:apiary, :features, features)
    on_exit(fn -> Application.put_env(:apiary, :features, previous) end)

    %{
      scope: scope,
      adapter: adapter,
      key: key,
      code_row: code_row,
      served: served,
      code: Enrolment.issued_code(code, Apiary.SigningKey.fingerprint())
    }
  end

  defp enrol_request(code) do
    pair = ed25519_key_pair()
    now = System.os_time(:second)
    message = SignedMessage.enrolment(code, pair.encoded, "acme-tracker", now)
    proof = :crypto.sign(:eddsa, :none, message, [pair.secret, :ed25519])

    {:ok, request} =
      Enrolment.decode(
        Jason.encode!(%{
          "version" => 1,
          "code" => code,
          "name" => "acme-tracker",
          "public_key" => pair.encoded,
          "timestamp" => now,
          "proof" => Ed25519.encode(proof)
        })
      )

    request
  end

  test "no adapter is made, renamed, connected or deleted", %{scope: scope, adapter: adapter} do
    refute Apiary.Features.on?(:factory)

    assert Adapters.create_adapter(scope, %{name: "Acme tracker"}) == {:error, :not_found}
    assert Adapters.rename_adapter(scope, adapter, %{name: "x"}) == {:error, :not_found}
    assert Adapters.connect(scope, adapter, fn _ -> {:ok, "pass"} end) == {:error, :not_found}
    assert Adapters.delete_adapter(scope, adapter) == {:error, :not_found}
    assert Repo.get!(Node, adapter.id).deleted_at == nil
  end

  test "an adapter's code is neither made nor redeemed", %{
    scope: scope,
    adapter: adapter,
    code: code
  } do
    assert AccessKeys.create_enrolment_code(scope, adapter, %{}) == {:error, :not_found}
    assert AccessKeys.enrol(enrol_request(code)) == {:error, :unauthorized}

    assert Repo.aggregate(from(k in AccessKey, where: k.node_id == ^adapter.id), :count) == 1

    # A node's code still enrols.
    node = node_fixture(scope)
    {:ok, _row, node_code} = AccessKeys.create_enrolment_code(scope, node, %{})

    assert {:ok, %AccessKey{}} =
             AccessKeys.enrol(
               enrol_request(Enrolment.issued_code(node_code, Apiary.SigningKey.fingerprint()))
             )
  end

  test "an adapter's key takes none of its actions", %{adapter: adapter, key: key} do
    key_scope = Scope.for_access_key(key)

    for action <- [:"source_item.post", :"work_item.read_changes", :"dispatch.claim"] do
      assert Access.authorize(key_scope, action, adapter) == {:error, :not_found}
      assert Adapters.for_key(key_scope, action) == {:error, :not_found}
    end
  end

  test "no pool names an adapter", %{scope: scope, adapter: adapter} do
    pool = pool_fixture(scope)

    assert {:error, changeset} = Nodes.update_node(scope, pool, %{served_by_id: adapter.id})
    assert "is invalid" in errors_on(changeset).served_by_id

    assert {:error, _changeset} =
             Nodes.create_node(scope, %{kind: "pool", name: "spot", served_by_id: adapter.id})
  end

  test "a pool keeps its adapter, and the rest of the edit saves", %{
    scope: scope,
    adapter: adapter,
    served: pool
  } do
    assert {:ok, %Node{name: "renamed", instance_limit: 3, served_by_id: id}} =
             Nodes.update_node(scope, pool, %{
               "name" => "renamed",
               "instance_limit" => "3",
               "served_by_id" => ""
             })

    assert id == adapter.id
    assert {:ok, %Node{served_by_id: ^id}} = Nodes.update_node(scope, pool, %{served_by_id: nil})
    assert Repo.get!(Node, pool.id).served_by_id == adapter.id
  end

  test "an adapter's key is not revoked, nor its code cancelled", %{
    scope: scope,
    adapter: adapter,
    key: key,
    code_row: code
  } do
    assert AccessKeys.revoke_access_key(scope, key) == {:error, :not_found}
    assert AccessKeys.cancel_code(scope, code) == {:error, :not_found}

    assert Repo.transact(fn ->
             AccessKeys.revoke_node_keys(Access.reload(scope), adapter, :node_deleted)
           end) == {:error, :not_found}

    assert Repo.get!(AccessKey, key.id).revoked_at == nil
    assert Repo.get!(EnrolmentCode, code.id).cancelled_at == nil
  end

  test "a node's, a pool's and a gateway's keys and codes are revoked and cancelled as before",
       %{scope: scope} do
    reloaded = Access.reload(scope)

    for node <- [
          node_fixture(scope),
          pool_fixture(scope),
          gateway_fixture(scope),
          organisation_gateway_fixture(scope)
        ] do
      %{access_key: key} = enrolled_key_fixture(scope, node)
      {:ok, code, _plain} = AccessKeys.create_enrolment_code(scope, node, %{})

      assert {:ok, %AccessKey{revoked_at: %DateTime{}}} =
               AccessKeys.revoke_access_key(scope, key)

      assert {:ok, %EnrolmentCode{cancelled_at: %DateTime{}}} =
               AccessKeys.cancel_code(scope, code)

      %{access_key: second} = enrolled_key_fixture(scope, node)
      {:ok, second_code, _plain} = AccessKeys.create_enrolment_code(scope, node, %{})

      assert Repo.transact(fn ->
               AccessKeys.revoke_node_keys(reloaded, node, :node_deleted)
             end) == {:ok, [second.key_id]}

      assert Repo.get!(EnrolmentCode, second_code.id).cancelled_at
    end
  end
end
