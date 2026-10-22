defmodule Apiary.ModelChoicesWithoutFeaturesTest do
  # An instance without `factory`, or without `secrets`: a model choice is not there for
  # anyone, an owner included, and nothing is stored, listed or resolved. Not async: the
  # features are the whole node's.
  use Apiary.DataCase, async: false

  import Apiary.ConnectionsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, ModelChoices}
  alias Apiary.ModelChoices.ModelChoice

  # Choices written while every feature was on, then the features switched.
  defp written!(scope, target, features) do
    previous = Application.get_env(:apiary, :features)
    Application.put_env(:apiary, :features, Apiary.Features.all())

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: "x"}]
      })

    {:ok, _} =
      ModelChoices.put_choice(scope, :workspace, %{provider: provider.public_id, locked: true})

    Application.put_env(:apiary, :features, features)
    on_exit(fn -> Application.put_env(:apiary, :features, previous) end)
    {provider, target}
  end

  for {name, features} <- [
        {"factory", [:observability, :security, :secrets]},
        {"secrets", [:observability, :security, :factory]}
      ] do
    @tag with_features: features
    test "without #{name}, a choice is not found and nothing is written" do
      %{scope: scope} = sign_up_fixture()
      target = target!(scope, "acme/shop")
      {provider, target} = written!(scope, target, Apiary.Features.enabled())
      attrs = %{provider: provider.public_id}

      for place <- [
            :organisation,
            :workspace,
            {:workspace, "hello"},
            target,
            {target, "hello"}
          ] do
        assert ModelChoices.put_choice(scope, place, attrs) == {:error, :not_found}
        assert ModelChoices.delete_choice(scope, place) == {:error, :not_found}
        assert ModelChoices.lock_choice(scope, place) == {:error, :not_found}
        assert ModelChoices.unlock_choice(scope, place) == {:error, :not_found}
      end

      assert ModelChoices.list_choices(scope) == {:error, :not_found}
      assert ModelChoices.resolve(scope, target, "hello") == {:error, :not_found}

      assert Repo.aggregate(ModelChoice, :count) == 1
      assert Repo.get_by!(ModelChoice, workspace_id: scope.workspace.id).locked
    end
  end
end
