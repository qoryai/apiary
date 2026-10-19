defmodule Apiary.ModelChoicesWithoutFeaturesTest do
  # An instance without `factory`, or without `secrets`: a model choice is not there for
  # anyone, an owner included, and nothing is stored, listed or resolved. Not async: the
  # features are the whole node's.
  use Apiary.DataCase, async: false

  import Apiary.ConnectionsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, ModelChoices, WorkItems}
  alias Apiary.ModelChoices.{ModelChoice, TakeInChoice}

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
            {:workspace, "explore"},
            target,
            {target, "explore"}
          ] do
        assert ModelChoices.put_choice(scope, place, attrs) == {:error, :not_found}
        assert ModelChoices.delete_choice(scope, place) == {:error, :not_found}
        assert ModelChoices.lock_choice(scope, place) == {:error, :not_found}
        assert ModelChoices.unlock_choice(scope, place) == {:error, :not_found}
      end

      assert ModelChoices.list_choices(scope) == {:error, :not_found}
      assert ModelChoices.resolve(scope, target, "explore") == {:error, :not_found}
      assert {:ok, nil} = ModelChoices.take_in_input(scope, %{provider: provider.public_id})

      assert Repo.aggregate(ModelChoice, :count) == 1
      assert Repo.get_by!(ModelChoice, workspace_id: scope.workspace.id).locked
    end
  end

  # With `factory` off a take in is not there at all; with `secrets` off it goes on and
  # stores no choice.
  @tag with_features: [:observability, :security, :factory]
  test "without secrets, a take in that sends a choice stores none" do
    %{scope: scope} = sign_up_fixture()
    target = target!(scope, "acme/shop")
    ticket = backlog_ticket_fixture(scope)
    {provider, _target} = written!(scope, target, Apiary.Features.enabled())

    assert {:ok, work_item} =
             WorkItems.take_in(scope, ticket.public_id, %{
               model_choice: %{provider: provider.public_id, model: "claude-sonnet-5-5"}
             })

    assert ModelChoices.take_in_choice(work_item.id, 1) == nil
    assert Repo.aggregate(TakeInChoice, :count) == 0
  end
end
