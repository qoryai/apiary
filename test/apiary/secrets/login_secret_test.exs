defmodule Apiary.Secrets.LoginSecretTest do
  # The reveal of a secret by its public id (`Apiary.Secrets.reveal_for_sealing/3`) refuses
  # the secret of a model provider whose keys are sign-ins: its documents have a refresh
  # token, and only `Apiary.ModelKeys.reveal_for_sealing/4` seals the access token.
  use Apiary.DataCase, async: true

  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, Secrets}
  alias Apiary.Secrets.Secret

  @moduletag needs: [:factory, :secrets]

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp secret_of(provider), do: Repo.get!(Secret, provider.secret_id)

  test "refuses the secret of a sign-in provider, whichever value it asks for", %{scope: scope} do
    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "openai-subscription",
        keys: [%{value_id: "main", value: device_login()}]
      })

    secret = secret_of(provider)

    for value_id <- ["main", nil, "absent"] do
      assert Secrets.reveal_for_sealing(scope.organisation, secret.public_id, value_id) ==
               if(value_id == "main", do: {:error, :login}, else: {:error, :not_found})
    end
  end

  test "reveals the secret of a provider whose keys are API keys", %{scope: scope} do
    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: "sk-ant-fixture-main-0123456789"}]
      })

    secret = secret_of(provider)

    assert Secrets.reveal_for_sealing(scope.organisation, secret.public_id, "main") ==
             {:ok, "sk-ant-fixture-main-0123456789"}
  end
end
