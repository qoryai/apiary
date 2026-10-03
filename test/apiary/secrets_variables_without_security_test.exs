defmodule Apiary.SecretsVariablesWithoutSecurityTest do
  # Stored secrets and variables belong to the security feature. Without it they are
  # absent: every read and write answers not found. Runs in every mode: the test sets the
  # instance's features itself, so it is not async.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.{Repo, Secrets, Variables}
  alias Apiary.Runs.Target

  @moduletag with_features: [:observability]

  setup do
    scope = sign_up_fixture().scope

    site =
      Repo.insert!(%Target{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        system: "github.example",
        path: "example/site",
        first_seen_at: DateTime.utc_now()
      })

    %{scope: scope, site: site}
  end

  test "the secrets are not found", %{scope: scope} do
    assert Secrets.create_secret(scope, %{name: "API_KEY", value: "x"}) == {:error, :not_found}
    assert Secrets.list_secrets(scope) == {:error, :not_found}
    assert Secrets.get_secret(scope, "sec_0123456789abcdef") == {:error, :not_found}
  end

  test "the variables are not found", %{scope: scope, site: site} do
    assert Variables.list_variables(scope, :workspace) == {:error, :not_found}
    assert Variables.get_variable(scope, Ecto.UUID.generate()) == {:error, :not_found}
    assert Variables.resolve(scope, site) == {:error, :not_found}

    assert Variables.create_variable(scope, :workspace, %{name: "A", value: "b"}) ==
             {:error, :not_found}

    assert Variables.create_variable(scope, site, %{name: "A", value: "b"}) ==
             {:error, :not_found}
  end
end
