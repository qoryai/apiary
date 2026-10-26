defmodule Apiary.ModelChoicesRacesTest do
  # A model choice saved while the provider it names is deleted, in each order. Each side runs on a connection apart, outside the SQL sandbox, so each
  # commits and each waits on the other's locks as it would in production. Not async: what
  # these tests commit is visible to every other test while they run, and they delete it
  # again before they end.
  #
  # The rule under test (`Apiary.ModelChoices`, `Apiary.Connections`): a save takes the
  # provider's row `FOR SHARE`, and a delete of the provider takes it `FOR UPDATE`, so the
  # two take turns. A save that comes first is seen by the delete,
  # which is refused; a delete that comes first is seen by the save, which is refused too.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.ConnectionsFixtures, only: [target!: 2]
  import Apiary.Races

  alias Apiary.{Connections, ModelChoices, Repo}
  alias Apiary.Connections.Connection
  alias Apiary.ModelChoices.ModelChoice

  @moduletag needs: :factory

  @model "claude-sonnet-5-5"

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    %{scope: scope} = owner = sign_up()

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: "x"}]
      })

    %{owner: owner, scope: scope, provider: provider, target: target!(scope, "acme/shop")}
  end

  defp choice(provider, model \\ @model),
    do: %{provider: provider.public_id, model: model}

  defp chosen, do: Repo.aggregate(ModelChoice, :count)

  defp provider_there?(provider),
    do: Repo.exists?(from c in Connection, where: c.id == ^provider.id)

  for {name, place} <- [
        {"the workspace's", :workspace},
        {"a target's and a workflow's", :target_and_workflow},
        {"the organisation's default", :organisation}
      ] do
    describe "#{name} choice and the provider's deletion" do
      test "the choice saved first: the deletion waits, and is refused", ctx do
        place = place(unquote(place), ctx)

        {first, first_pid} =
          hold(fn -> ModelChoices.put_choice(ctx.scope, place, choice(ctx.provider)) end)

        assert {:ok, %ModelChoice{}} = first.result

        second = start(fn -> Connections.delete_provider(ctx.scope, ctx.provider) end)
        await_blocked(second.backend, first_pid)
        commit(first)

        assert {:error, {:model_in_use, [%{level: level}]}} = Task.await(second.task)
        assert level in [2, 5, 6]
        assert provider_there?(ctx.provider)
        assert chosen() == 1
      end

      test "the provider deleted first: the save waits, and is refused", ctx do
        place = place(unquote(place), ctx)

        {first, first_pid} = hold(fn -> Connections.delete_provider(ctx.scope, ctx.provider) end)
        assert {:ok, %Connection{}} = first.result

        second = start(fn -> ModelChoices.put_choice(ctx.scope, place, choice(ctx.provider)) end)
        await_blocked(second.backend, first_pid)
        commit(first)

        assert {:error, %Ecto.Changeset{errors: [provider: {"is invalid", _}]}} =
                 Task.await(second.task)

        refute provider_there?(ctx.provider)
        assert chosen() == 0
      end
    end
  end

  defp place(:workspace, _ctx), do: :workspace
  defp place(:organisation, _ctx), do: :organisation
  defp place(:target_and_workflow, ctx), do: {ctx.target, "hello"}
end
