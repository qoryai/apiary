defmodule Apiary.Adapters.NotBuiltTest do
  # The functions the adapters' pages call whose bodies are not built: each answers
  # `{:error, :not_built}` and changes nothing. Building one replaces its test here.
  use Apiary.DataCase, async: true

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Adapters
  alias Apiary.Adapters.Collections
  alias Apiary.Nodes.Node

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    %{adapter: adapter} = connectable_adapter_fixture(%{name: "Acme tracker"})
    {connection, _nonce} = connection_fixture(scope, adapter, :listed)
    %{scope: scope, admin: instance_admin_scope(), adapter: adapter, connection: connection}
  end

  test "how often an adapter pulls: read and set", %{admin: admin, adapter: adapter} do
    assert Adapters.sync_settings(admin, adapter) == {:error, :not_built}

    assert Adapters.update_sync_interval(admin, adapter, %{sync_interval: 3600}) ==
             {:error, :not_built}

    assert %Node{sync_interval: nil} = Repo.get!(Node, adapter.id)
  end

  test "the collections a connection reaches: the list, the unassigned count, assigning, the listing's topic",
       %{scope: scope, connection: connection} do
    assert Collections.list_collections(scope, connection) == {:error, :not_built}
    assert Collections.count_unassigned(scope, connection) == {:error, :not_built}

    assert Collections.assign_collections(scope, connection, [], scope.workspace) ==
             {:error, :not_built}

    assert Collections.subscribe(scope, connection) == {:error, :not_built}
  end
end
