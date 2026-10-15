defmodule Apiary.AdaptersWithoutFactoryTest do
  # An instance without the feature adapters belong to: no adapter is made or changed,
  # none of their keys or codes is made, enrolled, revoked or cancelled, even by an instance
  # admin, and no pool names one. The adapters there already stay as they are. Not async:
  # the features are the whole node's.
  use Apiary.DataCase, async: false

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Access, AccessKeys, Adapters, Nodes}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Connection, Connections}
  alias Apiary.Contract.{Ed25519, Enrolment, SignedMessage}
  alias Apiary.Nodes.Node

  # The adapters are made where the feature is on, before it is turned off.
  @moduletag needs: :factory

  @without [:observability, :security]

  # Made with every feature, as an instance had them before it was launched without one.
  setup do
    %{scope: scope} = sign_up_fixture()
    admin = instance_admin_scope()
    adapter = adapter_fixture()
    {:ok, row, code} = AccessKeys.create_enrolment_code(admin, adapter, %{})
    %{access_key: key} = enrolled_key_fixture(admin, adapter)

    # An adapter the organisation connected to, before the feature went: one connection
    # each, from three organisations.
    connectable = connectable_adapter_fixture()
    %{scope: second} = sign_up_fixture()
    %{scope: third} = sign_up_fixture()

    connections = %{
      pending: connection_fixture(scope, connectable.adapter, :pending),
      connected: elem(connection_fixture(second, connectable.adapter, :connected), 0),
      listed: elem(connection_fixture(third, connectable.adapter, :listed), 0)
    }

    previous = Application.get_env(:apiary, :features)
    {:ok, features} = Apiary.Features.parse(Enum.map_join(@without, ",", &to_string/1))
    Application.put_env(:apiary, :features, features)
    on_exit(fn -> Application.put_env(:apiary, :features, previous) end)

    %{
      scope: scope,
      admin: admin,
      adapter: adapter,
      key: key,
      row: row,
      code: Enrolment.issued_code(code, Apiary.SigningKey.fingerprint()),
      connectable: connectable,
      connections: connections
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

  test "no adapter is made, renamed, connected, deleted or read, even by an instance admin",
       %{scope: scope, admin: admin, adapter: adapter} do
    refute Apiary.Features.on?(:factory)

    for asker <- [admin, scope] do
      assert Adapters.create_adapter(asker, %{name: "Acme tracker"}) == {:error, :not_found}
      assert Adapters.rename_adapter(asker, adapter, %{name: "x"}) == {:error, :not_found}
      assert Adapters.connect(asker, adapter) == {:error, :not_found}
      assert Adapters.delete_adapter(asker, adapter) == {:error, :not_found}
      assert Adapters.list_adapters(asker) == []
      assert Adapters.get_adapter(asker, adapter.public_id) == nil
    end

    assert Repo.get!(Node, adapter.id).deleted_at == nil
  end

  # The instance's switch decides for an instance admin, whatever the organisation their
  # scope carries shows them, and nobody passes it while it is off.
  test "an instance admin is answered as anyone else, shown the feature or not", %{
    scope: scope,
    admin: admin,
    adapter: adapter
  } do
    for hides <- [[], [:factory]] do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
      :ok = Apiary.EditionStubs.HidesNamed.put(hides)

      for asker <- [admin, scope] do
        assert Adapters.authorize_instance(asker) == {:error, :not_found}
        assert Adapters.authorize_instance(asker, sudo: true) == {:error, :not_found}
        assert AccessKeys.subscribe(asker, adapter) == {:error, :not_found}
        assert AccessKeys.list_for_node(Access.reload(asker), adapter) == []
        assert AccessKeys.list_enrolment_codes(Access.reload(asker), adapter) == []
        assert Adapters.list_adapters(Access.reload(asker)) == []
      end
    end
  end

  test "an adapter's code is neither made, cancelled nor redeemed, and its key not revoked",
       %{scope: scope, admin: admin, adapter: adapter, key: key, row: row, code: code} do
    assert AccessKeys.create_enrolment_code(admin, adapter, %{}) == {:error, :not_found}
    assert AccessKeys.cancel_code(admin, row) == {:error, :not_found}
    assert AccessKeys.revoke_access_key(admin, key) == {:error, :not_found}
    assert AccessKeys.revoke_node_keys(admin, adapter, :node_deleted) == {:error, :not_found}
    assert AccessKeys.list_for_node(admin, adapter) == []
    assert AccessKeys.enrol(enrol_request(code)) == {:error, :unauthorized}

    assert Repo.aggregate(
             from(k in AccessKey, where: k.node_id == ^adapter.id and is_nil(k.revoked_at)),
             :count
           ) == 1

    # A node's code still enrols.
    node = node_fixture(scope)
    {:ok, _row, node_code} = AccessKeys.create_enrolment_code(scope, node, %{})

    assert {:ok, %AccessKey{}} =
             AccessKeys.enrol(
               enrol_request(Enrolment.issued_code(node_code, Apiary.SigningKey.fingerprint()))
             )
  end

  test "no connection is started, taken back, found, connected or ended", %{
    scope: scope,
    connectable: %{adapter: adapter, pair: pair, access_key: key},
    connections: %{pending: {pending, nonce}, connected: connected, listed: listed}
  } do
    assert Adapters.connect(scope, adapter) == {:error, :not_found}

    token = return_token(pair.secret, pending.public_id, nonce)

    assert Connections.complete_return(scope, pending.public_id, token, nonce) ==
             {:error, :not_found}

    assert Connections.locate(scope, pending.public_id) == :error
    assert Connections.live_by_adapter(scope) == %{}
    assert Adapters.serving_choices(scope) == []

    key_scope = Scope.for_access_key(key)

    # The feature off, the key has no rights: forbidden, before any lookup, for a
    # connection pending or connected and for an id that names none alike.
    for id <- [pending.public_id, connected.public_id, listed.public_id, "ac_0000000000000000"] do
      assert Connections.connection_for_key(key_scope, id, :"source_item.post") ==
               {:error, :forbidden}

      assert Connections.end_connection(key_scope, id) == {:error, :forbidden}
    end

    assert %Connection{state: :pending, connected_at: nil, pass_nonce_used_at: nil} =
             Repo.get!(Connection, pending.id)

    assert %Connection{state: :connected, listed_at: nil} = Repo.get!(Connection, connected.id)

    assert %Connection{state: :connected, listed_at: %DateTime{}} =
             Repo.get!(Connection, listed.id)
  end

  test "an adapter's key takes none of its actions", %{adapter: adapter, key: key} do
    key_scope = Scope.for_access_key(key)

    for action <- [
          :"source_item.post",
          :"work_item.read_changes",
          :"dispatch.claim",
          :"adapter.disconnect"
        ] do
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

  test "an adapter's key is not revoked, nor its code cancelled", %{
    scope: scope,
    admin: admin,
    adapter: adapter,
    key: key,
    row: code
  } do
    for asker <- [admin, scope] do
      assert AccessKeys.revoke_access_key(asker, key) == {:error, :not_found}
      assert AccessKeys.cancel_code(asker, code) == {:error, :not_found}

      assert Repo.transact(fn ->
               AccessKeys.revoke_node_keys(Access.reload(asker), adapter, :node_deleted)
             end) == {:error, :not_found}
    end

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
