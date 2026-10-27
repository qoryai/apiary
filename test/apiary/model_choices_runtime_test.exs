defmodule Apiary.ModelChoicesRuntimeTest do
  # The runtime of a model choice: stored at each level, resolved with the provider, sent
  # in a run's `run_settings.runtime`, and checked at the save against the catalogue and
  # the provider. The catalogue of the release has one runtime; the tests that need two
  # put a list of two in their process (`Apiary.Kinds.Runtimes.put_test_list/1`), the
  # release's runtime and a copy of it under another name, or one that sends a format no
  # provider serves. No runtime is named here: each name is read from the list.
  use Apiary.DataCase, async: true

  import Apiary.ConnectionsFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, ModelChoices}
  alias Apiary.Kinds.{Runtime, Runtimes}
  alias Apiary.ModelChoices.{ModelChoice, Resolution}

  @moduletag needs: [:factory, :secrets]

  setup do
    %{scope: scope} = sign_up_fixture()

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: "sk-ant-runtime-test-0123456789"}]
      })

    [release] = Runtimes.list()

    %{
      scope: scope,
      provider: provider,
      release: release,
      target: target!(scope, "acme/shop")
    }
  end

  # The release's runtime under another name and title: it sends the same formats.
  defp copy(%Runtime{} = runtime),
    do: %{runtime | name: runtime.name <> "-second", title: runtime.title <> " second"}

  # A runtime that sends only a format no provider of the catalogue serves.
  defp unserved(%Runtime{} = runtime) do
    model = %{runtime.model | "formats" => ["no-such-format"]}

    %{
      runtime
      | name: runtime.name <> "-unserved",
        title: runtime.title <> " unserved",
        model: model,
        model_keys: for(key <- runtime.model_keys, do: %{key | "format" => "no-such-format"})
    }
  end

  defp errors(result) do
    assert {:error, %Ecto.Changeset{} = changeset} = result
    errors_on(changeset)
  end

  test "a choice that names no runtime resolves to the list's only runtime", ctx do
    %{scope: scope, provider: provider, release: release} = ctx

    {:ok, choice} = ModelChoices.put_choice(scope, :workspace, %{provider: provider.public_id})
    assert choice.runtime == nil
    assert ModelChoices.default_runtime() == release

    assert {:ok, {:ok, %Resolution{runtime: name}}} =
             ModelChoices.resolve(scope, :workspace, "hello")

    assert name == release.name
  end

  test "the runtime is stored at each level, and resolves with the provider's choice", ctx do
    %{scope: scope, provider: provider, release: release, target: target} = ctx
    second = copy(release)
    :ok = Runtimes.put_test_list([release, second])

    for place <- [:organisation, :workspace, {:workspace, "hello"}, target, {target, "hello"}] do
      {:ok, choice} =
        ModelChoices.put_choice(scope, place, %{
          provider: provider.public_id,
          runtime: second.name
        })

      assert %ModelChoice{runtime: name} = Repo.get!(ModelChoice, choice.id)
      assert name == second.name
    end

    # The target's choice with the workflow comes first; set back to the release's runtime,
    # it resolves to that one.
    {:ok, _choice} =
      ModelChoices.put_choice(scope, {target, "hello"}, %{
        provider: provider.public_id,
        runtime: release.name
      })

    assert {:ok, {:ok, %Resolution{level: 2, runtime: name}}} =
             ModelChoices.resolve(scope, target, "hello")

    assert name == release.name

    assert {:ok, {:ok, %Resolution{level: 3, runtime: name}}} =
             ModelChoices.resolve(scope, target, "other")

    assert name == second.name
  end

  test "a runtime the list does not have is refused", %{scope: scope, provider: provider} do
    name = "not-" <> ModelChoices.default_runtime().name

    assert %{runtime: [message]} =
             errors(
               ModelChoices.put_choice(scope, :workspace, %{
                 provider: provider.public_id,
                 runtime: name
               })
             )

    assert message == "Choose one of the offered runtimes: #{name} is not one of them."
  end

  test "a runtime needs a provider", %{scope: scope, release: release} do
    assert %{provider: ["can't be blank"]} =
             errors(
               ModelChoices.put_choice(scope, :workspace, %{
                 runtime: release.name,
                 tiers: %{"fast" => "claude-haiku-5-5"}
               })
             )
  end

  test "a provider that cannot serve the runtime is refused", ctx do
    %{scope: scope, provider: provider, release: release} = ctx
    unserved = unserved(release)
    :ok = Runtimes.put_test_list([release, unserved])

    assert %{provider: [message]} =
             errors(
               ModelChoices.put_choice(scope, :workspace, %{
                 provider: provider.public_id,
                 runtime: unserved.name
               })
             )

    assert message ==
             "Choose another provider for #{unserved.title}. #{provider.name} serves no request format that #{unserved.title} sends."

    assert ModelChoices.list_choices(scope) == {:ok, []}
  end

  test "a run sends the runtime its choice resolves to", ctx do
    %{scope: scope, provider: provider, release: release} = ctx
    second = copy(release)
    :ok = Runtimes.put_test_list([release, second])
    place = handover_place_fixture(scope, allow_secrets: true)

    {:ok, _choice} =
      ModelChoices.put_choice(scope, :workspace, %{
        provider: provider.public_id,
        runtime: second.name,
        model: "claude-sonnet-5-5"
      })

    assert claim!(scope, place)["runtime"] == second.name

    {:ok, _choice} =
      ModelChoices.put_choice(scope, :workspace, %{provider: provider.public_id})

    assert claim!(scope, place)["runtime"] == release.name
  end

  test "a run whose choices name no provider sends the default runtime", ctx do
    place = handover_place_fixture(ctx.scope, allow_secrets: true)
    assert claim!(ctx.scope, place) == %{"runtime" => ctx.release.name}
  end

  # A fresh work item's explore run, queued and claimed: its run settings.
  defp claim!(scope, place) do
    work_item = work_item_fixture(scope)
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

    {:ok, %{documents: documents}} =
      Dispatches.claim(
        place.key,
        Dispatches.now(),
        ~s({"version":1,"time":"2026-10-26T12:00:00Z"})
      )

    documents.run_settings |> Jason.encode!() |> Jason.decode!()
  end
end
