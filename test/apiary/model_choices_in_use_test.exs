defmodule Apiary.ModelChoicesInUseTest do
  # What stops a model provider or one of its keys from being removed
  # while a model choice uses it, and the words of the refusal. The live runs that use a
  # provider are not read yet: a run keeps its provider only once the handover writes it.
  use Apiary.DataCase, async: true

  import Apiary.ConnectionsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, ModelChoices}
  alias Apiary.Connections.Connection
  alias Apiary.Runs.Target

  @moduletag needs: :factory

  @model "claude-sonnet-5-5"

  setup do
    %{scope: scope} = sign_up_fixture()

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [
          %{value_id: "main", value: "sk-in-use-1"},
          %{value_id: "spare", value: "sk-in-use-2"}
        ]
      })

    %{scope: scope, provider: provider, target: target!(scope, "acme/shop")}
  end

  defp attrs(provider),
    do: %{provider: provider.public_id, key: "spare", model: @model, effort: "high"}

  defp errors(result) do
    assert {:error, %Ecto.Changeset{} = changeset} = result
    errors_on(changeset)
  end

  describe "while a choice uses a provider" do
    setup ctx do
      %{scope: scope, provider: provider, target: target} = ctx

      {:ok, _} =
        ModelChoices.put_choice(
          scope,
          {target, "hello"},
          Map.put(attrs(provider), :tiers, %{"light" => "claude-haiku-5-5"})
        )

      {:ok, _} = ModelChoices.put_choice(scope, :organisation, %{provider: provider.public_id})
      :ok
    end

    test "the places name each choice (T30, T31)", %{provider: provider} do
      places = ModelChoices.places_using(provider)
      assert Enum.map(places, & &1.level) == [6, 2]

      assert Enum.map(places, &ModelChoices.place_words/1) ==
               ["the organisation's default", "github.example/acme/shop, hello runs"]
    end

    test "the provider is not removed, and the refusal names the places (T27)", %{
      scope: scope,
      provider: provider
    } do
      assert {:error, {:model_in_use, places}} = Connections.delete_provider(scope, provider)
      assert length(places) == 2

      assert ModelChoices.in_use_words("Anthropic API key", places) ==
               "Change the model choices that use Anthropic API key first: the organisation's default, github.example/acme/shop, hello runs."

      assert Repo.get(Connection, provider.id)

      assert Repo.aggregate(
               from(e in Apiary.Audit.Entry, where: e.subject_id == ^provider.id),
               :count
             ) == 1

      {:ok, _} = ModelChoices.delete_choice(scope, :organisation)
      {:ok, _} = ModelChoices.delete_choice(scope, {Repo.one!(Target), "hello"})
      assert {:ok, _} = Connections.delete_provider(scope, provider)
    end

    test "a key is not removed or renamed while a choice names it (T34)", %{
      scope: scope,
      provider: provider
    } do
      assert %{value_id: [message]} =
               errors(Connections.delete_provider_key(scope, provider, "spare"))

      assert message ==
               "Change the model choices that use the key spare first: github.example/acme/shop, hello runs."

      assert %{value_id: [^message]} =
               errors(Connections.rename_provider_key(scope, provider, "spare", "other"))

      # A key no choice names is removed; the provider's default key is kept by the rule of
      # `Apiary.Connections.delete_provider_key/3`.
      assert {:ok, _} =
               Connections.add_provider_key(scope, provider, %{value_id: "third", value: "z"})

      assert {:ok, _} = Connections.delete_provider_key(scope, provider, "third")
    end

    test "a listing of five and more names five and counts the rest", %{provider: provider} do
      places =
        for n <- 1..7,
            do: %{level: 3, workspace: "W", target: "t#{n}", workflow: nil, value_id: nil}

      words = ModelChoices.in_use_words(provider.name, places)
      assert words =~ "t1, t2, t3, t4, t5 and 2 more."
      refute words =~ "t6"
      assert ModelChoices.in_use_words(provider.name, []) == nil
    end
  end
end
