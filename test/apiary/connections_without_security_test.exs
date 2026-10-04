defmodule Apiary.ConnectionsWithoutSecurityTest do
  # The connections are the security feature's: without it, they are not found, and no
  # release is fetched. The features are the node's, so this module is not async.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, Integrations}

  setup do
    %{scope: sign_up_fixture().scope}
  end

  @tag with_features: [:observability]
  test "without the security feature nothing of the connections is found", %{scope: scope} do
    assert Connections.list_connections(scope) == {:error, :not_found}
    assert Connections.get_connection(scope, "con_0123456789abcdef") == {:error, :not_found}
    assert Connections.create_runtime(scope, %{runtime: "claude"}) == {:error, :not_found}
    assert Connections.create_service(scope, %{service: "sentry"}) == {:error, :not_found}
    assert Connections.list_service_definitions(scope) == {:error, :not_found}

    assert Integrations.request_release(scope, %{
             source: "github.com/qoryai/qory-github",
             version: "0.1.0"
           }) == {:error, :not_found}

    assert Integrations.get_release(scope, Ecto.UUID.generate()) == {:error, :not_found}
  end
end
