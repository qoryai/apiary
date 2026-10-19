defmodule Apiary.Connections.ProvidersWithoutFeaturesTest do
  # An instance without `factory`, or without `secrets`: a model provider is not there for
  # anyone, an owner included, and nothing is written. Not async: the features are the
  # whole node's.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, Secrets}
  alias Apiary.Connections.Connection

  defp attrs, do: %{provider: "openrouter", keys: [%{value_id: "main", value: "x"}]}

  # A provider written while every feature was on, then the features switched.
  defp provider!(scope, features) do
    previous = Application.get_env(:apiary, :features)
    Application.put_env(:apiary, :features, Apiary.Features.all())
    {:ok, provider} = Connections.create_provider(scope, attrs())
    Application.put_env(:apiary, :features, features)
    on_exit(fn -> Application.put_env(:apiary, :features, previous) end)
    provider
  end

  for {name, features} <- [
        {"factory", [:observability, :security, :secrets]},
        {"secrets", [:observability, :security, :factory]}
      ] do
    @tag with_features: features
    test "without #{name}, a provider is not found and nothing is written" do
      %{scope: scope} = sign_up_fixture()
      features = Apiary.Features.enabled()
      provider = provider!(scope, features)

      assert Connections.create_provider(scope, attrs()) == {:error, :not_found}
      assert Connections.list_providers(scope) == {:error, :not_found}
      assert Connections.get_provider(scope, provider.public_id) == {:error, :not_found}
      assert Connections.update_provider(scope, provider, %{name: "x"}) == {:error, :not_found}
      assert Connections.update_connection(scope, provider, %{name: "x"}) == {:error, :not_found}
      assert Connections.put_default_key(scope, provider, "main") == {:error, :not_found}

      assert Connections.add_provider_model(scope, provider, %{model_id: "m"}) ==
               {:error, :not_found}

      assert Connections.delete_provider(scope, provider) == {:error, :not_found}
      assert Connections.delete_connection(scope, provider) == {:error, :not_found}
      assert Repo.aggregate(Connection, :count) == 1

      # The keys go by the provider's answer.
      assert Connections.delete_provider_key(scope, provider, "main") == {:error, :not_found}
      assert Secrets.delete_secret(scope, provider.secret) == {:error, :not_found}
    end
  end
end
