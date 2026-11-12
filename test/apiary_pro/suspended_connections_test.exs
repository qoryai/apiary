defmodule ApiaryPro.SuspendedConnectionsTest do
  # What an adapter's key finds through an organisation's connection while the edition
  # holds the organisation suspended (`ApiaryPro.Suspensions`), asked of the core's
  # connections (`Apiary.Adapters.Connections`) with the edition's answer: the
  # connection is suspended, never refused on the key's rights, and the key still ends
  # it. Another organisation, not suspended, is found as before.
  use Apiary.DataCase, async: true

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{AccessKeys, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Connection, Connections}
  alias ApiaryPro.Suspensions

  @moduletag with_features: Apiary.Features.all()

  setup do
    connectable = connectable_adapter_fixture(%{name: "Example tracker"})
    suspended = sign_up_fixture()
    active = sign_up_fixture()
    {suspended_connection, _nonce} = connection_fixture(suspended.scope, connectable.adapter)
    {active_connection, _nonce} = connection_fixture(active.scope, connectable.adapter)
    %{instance_scope: admin} = suite_instance_admin()

    {:ok, _suspension} = Suspensions.suspend_organisation(admin, suspended.organisation.id)

    %{
      key_scope: key_scope(connectable.access_key),
      suspended_connection: suspended_connection,
      active_connection: active_connection
    }
  end

  # The verified key's scope, as a signed request carries it.
  defp key_scope(key) do
    {:ok, verified} = AccessKeys.fetch_for_verification(key.key_id)
    Scope.for_access_key(verified)
  end

  test "an adapter's key finds a suspended organisation's connection suspended, not refused",
       %{key_scope: key_scope, suspended_connection: connection} do
    assert Connections.connection_for_key(key_scope, connection.public_id, :"source_item.post") ==
             {:error, :suspended}
  end

  test "an adapter's key ends a suspended organisation's connection",
       %{key_scope: key_scope, suspended_connection: connection} do
    assert {:ok, %Connection{state: :ended, ended_reason: :adapter_reported}} =
             Connections.end_connection(key_scope, connection.public_id)

    assert %Connection{state: :ended, ended_at: %DateTime{}} =
             Repo.get!(Connection, connection.id)
  end

  test "an adapter's key finds the connection of an organisation that is not suspended",
       %{key_scope: key_scope, active_connection: connection} do
    assert {:ok, %Connection{id: id}, %Scope{}} =
             Connections.connection_for_key(
               key_scope,
               connection.public_id,
               :"source_item.post"
             )

    assert id == connection.id
  end
end
