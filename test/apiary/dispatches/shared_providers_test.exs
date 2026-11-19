defmodule Apiary.Dispatches.SharedProvidersTest do
  # A claim of a run of a stage whose workflows share one run, with the model providers of
  # its workflows' choices (`Apiary.Dispatches.RunSettings`): the key each later session
  # starts on, the run's keys of several providers and its run configuration, a later
  # session whose provider is gone, and the check of the stage's choices at the save
  # (`Apiary.Processes.shared_models/3`) and again at the claim
  # (`Apiary.Stages.shared_models/1`), with the lines of a run that claim ended; and a run
  # that paused: the cooldown it keeps and its Paused line by the session that paused, and
  # its continuation, which starts on that session's provider.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.DispatchedRunsFixtures
  import Apiary.ModelKeysFixtures, only: [stored_keys: 1, key_state!: 3, in_seconds: 1]
  import Apiary.RunEventsFixtures, only: [event_fixture: 4]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, ModelChoices, Processes}
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Pause, RunSettings}
  alias Apiary.Runs.{ModelKey, Projector, ProviderCredential, Run, Transcript}
  alias Apiary.Stages.StopCause
  alias Apiary.WorkItems.{ExploreView, WorkItem}
  alias ApiaryWeb.StagesLive.Words

  @moduletag needs: [:factory, :secrets, :workflow_model]

  @body ~s({"version":1,"time":"2026-10-18T12:00:00Z"})
  @build "st_6ns22c4pav"

  setup do
    %{scope: scope} = sign_up_fixture()

    scope
    |> handover_place_fixture(allow_secrets: true)
    |> Map.put(:scope, scope)
  end

  # A model provider of the scope's organisation of `kind`, named `name`, with `count`
  # keys.
  defp provider!(scope, name, opts \\ []) do
    kind = Keyword.get(opts, :kind, "anthropic")
    prefix = if kind == "claude-subscription", do: "sk-ant-oat01-", else: "sk-ant-"
    prefix = if kind == "openai", do: "sk-", else: prefix
    slug = name |> String.downcase() |> String.replace(" ", "-")

    keys =
      for n <- 1..Keyword.get(opts, :count, 1),
          do: %{value_id: "key-#{n}", value: "#{prefix}#{slug}-#{n}-0123456789"}

    {:ok, provider} =
      Connections.create_provider(scope, %{provider: kind, name: name, keys: keys})

    provider
  end

  # The choice at `place` on `provider`: Claude Code's model, or Codex's for an OpenAI
  # provider.
  defp choose!(scope, place, provider, attrs \\ %{}) do
    model =
      if provider.provider_kind == "openai",
        do: %{runtime: "codex", model: "gpt-6-astra"},
        else: %{model: "claude-opus-5-5"}

    {:ok, choice} =
      Apiary.ModelChoicesFixtures.put_choice(
        scope,
        place,
        Map.merge(Map.put(model, :provider, provider.public_id), attrs)
      )

    choice
  end

  # The process with one stage, Build, whose workflows share one run.
  defp document(workflows) do
    stage = %{
      "id" => @build,
      "name" => "Build",
      "inputs" => [],
      "shared_run" => true,
      "sequence" => Enum.map(workflows, &%{"workflow" => &1}),
      "outputs" => [],
      "gate" => %{"kind" => "person", "approvers" => "members"}
    }

    %{"schema" => "qory.process/v1", "machine" => "default", "stages" => [stage]}
  end

  defp save(scope, workflows), do: Processes.save(scope, scope.workspace, document(workflows))

  # A fresh work item's explore run, queued and claimed: `{:ok, run}`, the registered run
  # read again, or `{:ended, cause}` where the claim ended the run; and the run of the
  # queue.
  defp claim!(ctx), do: claimed!(ctx, queued!(ctx))

  defp queued!(ctx) do
    work_item = work_item_fixture(ctx.scope)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    queued
  end

  # The claim of `queued`, the oldest waiting run of the queue, as `claim!/1` returns it.
  defp claimed!(ctx, %DispatchRun{} = queued) do
    case walked_claim(ctx.key, Dispatches.now(), @body) do
      {:ok, %{run: %DispatchRun{id: id}, registered: run}} ->
        assert id == queued.id
        {{:ok, Repo.get!(Run, run.id)}, queued}

      {:ok, :none} ->
        assert %DispatchRun{state: :ended, end_cause: cause, result_outcome: :error} =
                 Repo.get!(DispatchRun, queued.id)

        assert %Dispatch{end_cause: ^cause, handed_over_at: nil} =
                 Repo.one!(from d in Dispatch, where: d.dispatch_run_id == ^queued.id)

        assert stored_keys_of_queue(queued) == []
        {{:ended, cause}, queued}
    end
  end

  defp stored_keys_of_queue(%DispatchRun{id: id}),
    do:
      Repo.all(
        from k in ModelKey, join: r in Run, on: r.id == k.run_id, where: r.dispatch_run_id == ^id
      )

  defp names(keys), do: Enum.map(keys, & &1.name)

  # `provider` with every key deleted, as no page of Qory Apiary deletes a provider's last
  # key.
  defp no_keys!(provider) do
    Repo.delete_all(from v in Apiary.Secrets.Value, where: v.secret_id == ^provider.secret_id)
    provider
  end

  # The catalogue in this process with a second runtime, a copy of the release's under
  # another name, which uses a second API of the Anthropic provider, with another auth;
  # the second runtime.
  defp second_api! do
    release = ModelChoices.default_runtime()
    second = %{release | name: release.name <> "-second", title: release.title <> " second"}
    :ok = Apiary.Kinds.Runtimes.put_test_list([release, second])

    providers =
      for provider <- Apiary.Kinds.Providers.list() do
        if provider.name == "anthropic" do
          [api] = provider.apis

          other =
            api |> Map.put("runtimes", [second.name]) |> Map.put("auth", %{"scheme" => "bearer"})

          %{provider | apis: [Map.put(api, "runtimes", [release.name]), other]}
        else
          provider
        end
      end

    :ok = Apiary.Kinds.Providers.put_test_list(providers)
    second
  end

  # What a claim of `queued` builds once the guard of the stage's choices has passed, as
  # `Apiary.Dispatches.Handover` calls it: a choice changed between the guard and the
  # build.
  defp built(queued), do: queued |> RunSettings.hold() |> RunSettings.build()

  describe "a claim of a stage whose workflows use two providers" do
    test "gives each session the key of its provider, and the run the keys of both", ctx do
      northwind = provider!(ctx.scope, "Northwind keys")
      checkout = provider!(ctx.scope, "Checkout keys")
      workflows = ~w(plan-the-build write-acceptance-checks review-the-build)
      choose!(ctx.scope, {:workspace, "plan-the-build"}, northwind)
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, checkout)
      choose!(ctx.scope, {:workspace, "review-the-build"}, northwind)
      assert {:ok, _version} = save(ctx.scope, workflows)

      {{:ok, run}, _queued} = claim!(ctx)
      start = "#{northwind.public_id}-1"
      other = "#{checkout.public_id}-1"

      # Session 1 starts on the start key; session 2 on the other provider's key; session
      # 3, on the start key's provider, joins the start key's group.
      assert run.provider_connection_id == northwind.id
      assert %{"1" => second, "2" => third} = run.session_settings
      assert %{"workflow" => "write-acceptance-checks", "model_credential" => ^other} = second
      assert %{"workflow" => "review-the-build"} = third
      refute Map.has_key?(third, "model_credential")

      assert [
               %ModelKey{position: 1, start: true, connection_id: start_id, secret_id: secret},
               %ModelKey{position: 2, start: false, connection_id: other_id, secret_id: theirs}
             ] = keys = stored_keys(run)

      assert names(keys) == [start, other]
      assert {start_id, secret} == {northwind.id, northwind.secret_id}
      assert {other_id, theirs} == {checkout.id, checkout.secret_id}

      # The run configuration sends both keys, and starts on the start key.
      assert {:ok, credential} = ProviderCredential.for_run(run)
      assert credential.name == start
      assert Enum.map(credential.keys, & &1.entry["name"]) == [start, other]
      assert Enum.map(credential.providers, & &1.id) == [northwind.id, checkout.id]
    end

    test "with 5 keys on each provider keeps 5 of the start key's provider, then 1 of the other",
         ctx do
      northwind = provider!(ctx.scope, "Northwind keys", count: 5)
      checkout = provider!(ctx.scope, "Checkout keys", count: 5)
      choose!(ctx.scope, {:workspace, "plan-the-build"}, northwind)
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, checkout)
      assert {:ok, _version} = save(ctx.scope, ~w(plan-the-build write-acceptance-checks))

      {{:ok, run}, _queued} = claim!(ctx)

      assert names(stored_keys(run)) ==
               for(n <- 1..5, do: "#{northwind.public_id}-#{n}") ++
                 ["#{checkout.public_id}-1"]

      assert %{"1" => %{"model_credential" => credential}} = run.session_settings
      assert credential == "#{checkout.public_id}-1"
    end

    test "with 1 key on the start key's provider and 5 on the other keeps 1, then 5", ctx do
      northwind = provider!(ctx.scope, "Northwind keys", count: 1)
      checkout = provider!(ctx.scope, "Checkout keys", count: 5)
      choose!(ctx.scope, {:workspace, "plan-the-build"}, northwind)
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, checkout)
      assert {:ok, _version} = save(ctx.scope, ~w(plan-the-build write-acceptance-checks))

      {{:ok, run}, _queued} = claim!(ctx)

      # The start key's provider keeps fewer than its share: the other provider's
      # remaining keys fill the run to 6.
      assert names(stored_keys(run)) ==
               ["#{northwind.public_id}-1"] ++ for(n <- 1..5, do: "#{checkout.public_id}-#{n}")
    end

    test "keeps the provider of a later session's keys from deletion while the run is live",
         ctx do
      northwind = provider!(ctx.scope, "Northwind keys")
      checkout = provider!(ctx.scope, "Checkout keys")
      choose!(ctx.scope, {:workspace, "plan-the-build"}, northwind)
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, checkout)
      assert {:ok, _version} = save(ctx.scope, ~w(plan-the-build write-acceptance-checks))

      {{:ok, run}, _queued} = claim!(ctx)
      assert run.provider_connection_id == northwind.id

      # No choice uses Checkout keys now; the run has a key row of it, for session 2.
      {:ok, _deleted} =
        ModelChoices.delete_choice(ctx.scope, {:workspace, "write-acceptance-checks"})

      assert Connections.delete_provider(ctx.scope, checkout) ==
               {:error, {:provider_in_use, %{places: [], runs: [run.public_id]}}}
    end

    test "whose first session runs on the machine's key ends session_key_missing where a later session runs on a provider with keys",
         ctx do
      northwind = provider!(ctx.scope, "Northwind keys", count: 2)
      # plan-the-build has no model choice at any level: session 1 runs on the default
      # runtime with the machine's key, so the run gets no key.
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, northwind)
      assert {:ok, _version} = save(ctx.scope, ~w(plan-the-build write-acceptance-checks))

      # `claim!/1` checks that the ended claim stored no key row.
      assert {{:ended, :session_key_missing}, _queued} = claim!(ctx)
    end

    test "where every session runs on the machine's key keeps no key", ctx do
      _northwind = provider!(ctx.scope, "Northwind keys", count: 2)
      assert {:ok, _version} = save(ctx.scope, ~w(plan-the-build write-acceptance-checks))

      {{:ok, run}, _queued} = claim!(ctx)
      assert run.provider_connection_id == nil
      assert stored_keys(run) == []
      assert %{"1" => second} = run.session_settings
      refute Map.has_key?(second, "model_credential")
      assert ProviderCredential.for_run(run) == {:ok, nil}
    end

    test "ends the claim provider_gone where a later session's provider kind is gone", ctx do
      northwind = provider!(ctx.scope, "Northwind keys")
      checkout = provider!(ctx.scope, "Checkout keys", kind: "claude-subscription")
      choose!(ctx.scope, {:workspace, "plan-the-build"}, northwind)
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, checkout)
      assert {:ok, _version} = save(ctx.scope, ~w(plan-the-build write-acceptance-checks))

      # The catalogue no longer has the kind of the later session's provider; the start
      # key's provider is of another kind, which it still has.
      :ok =
        Apiary.Kinds.Providers.list()
        |> Enum.reject(&(&1.name == "claude-subscription"))
        |> Apiary.Kinds.Providers.put_test_list()

      assert {{:ended, :provider_gone}, _queued} = claim!(ctx)
    end
  end

  describe "a claim of a stage whose later workflow's provider has every key in cooldown" do
    # Northwind keys for the first workflow; the workspace's choice on Checkout keys, with
    # Claude Opus, and a fallback on Storefront keys, with Claude Sonnet, for the second,
    # which has no choice of its own; saved. Then Checkout keys' one key cools.
    defp cooling_later!(ctx) do
      northwind = provider!(ctx.scope, "Northwind keys")
      checkout = provider!(ctx.scope, "Checkout keys")
      storefront = provider!(ctx.scope, "Storefront keys")
      sonnet = Apiary.ModelChoicesFixtures.every_tier("claude-sonnet-5-5")
      fallback = Apiary.ModelChoicesFixtures.fallback_attrs(storefront, sonnet)
      choose!(ctx.scope, {:workspace, "plan-the-build"}, northwind)
      choose!(ctx.scope, :workspace, checkout, %{fallbacks: [fallback]})
      assert {:ok, _version} = save(ctx.scope, ~w(plan-the-build write-acceptance-checks))
      key_state!(checkout, "key-1", until: in_seconds(3_600))
      %{northwind: northwind, checkout: checkout, storefront: storefront}
    end

    test "starts the later session on the first fallback with a free key", ctx do
      %{northwind: northwind, storefront: storefront} = cooling_later!(ctx)

      {{:ok, run}, _queued} = claim!(ctx)
      fallback = "#{storefront.public_id}-1"

      assert run.provider_connection_id == northwind.id
      assert %{"1" => second} = run.session_settings

      assert %{
               "workflow" => "write-acceptance-checks",
               "model_credential" => ^fallback,
               "model_choice" => %{"model" => "claude-sonnet-5-5"}
             } = second

      assert names(stored_keys(run)) == ["#{northwind.public_id}-1", fallback]
    end

    test "starts the later session on its provider's choice and keys where every fallback's key is in cooldown too",
         ctx do
      %{northwind: northwind, checkout: checkout, storefront: storefront} =
        cooling_later!(ctx)

      key_state!(storefront, "key-1", until: in_seconds(3_600))

      {{:ok, run}, _queued} = claim!(ctx)
      cooling = "#{checkout.public_id}-1"

      assert run.provider_connection_id == northwind.id
      assert %{"1" => second} = run.session_settings

      assert %{
               "workflow" => "write-acceptance-checks",
               "model_credential" => ^cooling,
               "model_choice" => %{"model" => "claude-opus-5-5"}
             } = second

      assert names(stored_keys(run)) == ["#{northwind.public_id}-1", cooling]
    end
  end

  # `count` providers of the scope's organisation, named Northwind 1, Northwind 2 and so
  # on.
  defp providers!(scope, count),
    do: for(n <- 1..count, do: provider!(scope, "Northwind #{n}"))

  defp steps(count), do: for(n <- 1..count, do: "step-#{n}")

  defp error(errors, kind), do: Enum.find(errors, &(&1.error == kind))

  @missing "Choose a model for workflow write-acceptance-checks. Without one it runs on Claude Code, and this stage's runs can start on Storefront keys, which Claude Code cannot use."
  @no_key "Add a model key to Checkout keys, or choose a model of another provider for workflow write-acceptance-checks. Checkout keys has no model key."
  @other_api "Choose a model for workflow write-acceptance-checks that uses the Anthropic Messages API of Northwind keys, as workflow plan-the-build does, or a model of another provider. One run uses one API of each provider."

  defp too_many(names),
    do:
      "Use at most 6 model providers in one stage. Its workflows use #{length(names)}: " <>
        Enum.join(names, ", ") <> "."

  # A stage whose first workflow runs on an OpenAI provider, Storefront keys, which Claude
  # Code cannot use, and whose second has a choice on an Anthropic provider; saved.
  defp openai_first!(ctx) do
    storefront = provider!(ctx.scope, "Storefront keys", kind: "openai")
    northwind = provider!(ctx.scope, "Northwind keys")
    choose!(ctx.scope, {:workspace, "plan-the-build"}, storefront)
    choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, northwind)
    assert {:ok, _version} = save(ctx.scope, ~w(plan-the-build write-acceptance-checks))
    %{storefront: storefront, northwind: northwind}
  end

  # A stage of 7 workflows: workflow n of the first 6 with a choice on
  # Northwind n, the 7th on the workspace's choice, Northwind 1; and Northwind 7,
  # which no choice uses; saved.
  defp six_providers!(ctx) do
    providers = providers!(ctx.scope, 7)

    for {provider, workflow} <- Enum.zip(Enum.take(providers, 6), steps(6)),
        do: choose!(ctx.scope, {:workspace, workflow}, provider)

    choose!(ctx.scope, :workspace, hd(providers))
    assert {:ok, _version} = save(ctx.scope, steps(7))
    providers
  end

  describe "the save of a stage whose workflows share one run" do
    test "fails where a workflow has no model and the stage's runs start on a provider its runtime cannot use",
         ctx do
      storefront = provider!(ctx.scope, "Storefront keys", kind: "openai")
      choose!(ctx.scope, {:workspace, "plan-the-build"}, storefront)
      workflows = ~w(plan-the-build write-acceptance-checks)

      assert {:error, errors} = save(ctx.scope, workflows)
      assert %{path: "#/stages/0"} = refused = error(errors, :model_choice_missing)
      assert Words.refusal(refused, document(workflows)) == @missing
    end

    test "fails where a later workflow's provider has no model key, and passes where a later step of its choice has one",
         ctx do
      northwind = provider!(ctx.scope, "Northwind keys")
      checkout = provider!(ctx.scope, "Checkout keys")
      choose!(ctx.scope, {:workspace, "plan-the-build"}, northwind)
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, checkout)
      no_keys!(checkout)
      workflows = ~w(plan-the-build write-acceptance-checks)

      assert {:error, errors} = save(ctx.scope, workflows)
      assert %{path: "#/stages/0"} = refused = error(errors, :session_key_missing)

      assert refused.detail ==
               {:session_key_missing, :no_key, "write-acceptance-checks", "Checkout keys"}

      assert Words.refusal(refused, document(workflows)) == @no_key

      # The workspace's choice, on Northwind keys, is the default step that the workflow's
      # choice walks after its provider: a later step with a key.
      choose!(ctx.scope, :workspace, northwind)
      assert {:ok, _version} = save(ctx.scope, workflows)
    end

    test "fails where a workflow's runtime uses another API of the provider an earlier workflow uses",
         ctx do
      second = second_api!()
      northwind = provider!(ctx.scope, "Northwind keys")
      choose!(ctx.scope, {:workspace, "plan-the-build"}, northwind)

      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, northwind, %{
        runtime: second.name
      })

      workflows = ~w(plan-the-build write-acceptance-checks)

      assert {:error, errors} = save(ctx.scope, workflows)
      assert %{path: "#/stages/0"} = refused = error(errors, :session_key_missing)

      assert refused.detail ==
               {:session_key_missing, :other_api, "write-acceptance-checks", "Anthropic Messages",
                "Northwind keys", "plan-the-build"}

      assert Words.refusal(refused, document(workflows)) == @other_api
    end

    test "fails where the workflows use 7 providers", ctx do
      providers = providers!(ctx.scope, 7)

      for {provider, workflow} <- Enum.zip(providers, steps(7)),
          do: choose!(ctx.scope, {:workspace, workflow}, provider)

      assert {:error, errors} = save(ctx.scope, steps(7))
      refused = error(errors, :too_many_providers)

      assert Words.refusal(refused, document(steps(7))) ==
               too_many(Enum.map(providers, & &1.name))
    end

    test "counts a 7th provider that only a fallback uses", ctx do
      providers = providers!(ctx.scope, 7)
      [seventh | _] = Enum.reverse(providers)

      for {provider, workflow} <- Enum.zip(Enum.take(providers, 5), steps(5)),
          do: choose!(ctx.scope, {:workspace, workflow}, provider)

      # The 6th workflow has no choice for it: it takes the workspace's, on Northwind 6,
      # which falls back to Northwind 7. A workflow's choice stores no fallbacks; each
      # workflow's choice walks the workspace's, then its fallbacks, after its provider.
      [first | rest] = Enum.take(providers, 5)
      sixth = Enum.at(providers, 5)
      fallback = Apiary.ModelChoicesFixtures.fallback_attrs(seventh)
      choose!(ctx.scope, :workspace, sixth, %{fallbacks: [fallback]})

      assert {:error, errors} = save(ctx.scope, steps(6))
      refused = error(errors, :too_many_providers)

      assert Words.refusal(refused, document(steps(6))) ==
               too_many(Enum.map([first, sixth, seventh | rest], & &1.name))

      # Saved without the fallback, then the fallback added: the claim ends the run.
      choose!(ctx.scope, :workspace, sixth, %{fallbacks: []})
      assert {:ok, _version} = save(ctx.scope, steps(6))
      choose!(ctx.scope, :workspace, sixth, %{fallbacks: [fallback]})

      assert {{:ended, :too_many_providers}, _queued} = claim!(ctx)
    end
  end

  describe "the claim of a stage saved with choices that fit one run" do
    test "ends the run too_many_providers after a change of the workspace's choice", ctx do
      providers = six_providers!(ctx)
      assert {{:ok, _run}, _queued} = claim!(ctx)

      # The 7th workflow now runs on Northwind 7.
      choose!(ctx.scope, :workspace, List.last(providers))
      assert {{:ended, :too_many_providers}, _queued} = claim!(ctx)
    end

    test "ends the run model_choice_missing after a model choice is cleared",
         ctx do
      openai_first!(ctx)

      {:ok, _deleted} =
        ModelChoices.delete_choice(ctx.scope, {:workspace, "write-acceptance-checks"})

      assert {{:ended, :model_choice_missing}, _queued} = claim!(ctx)
    end

    test "ends the run session_key_missing after the keys of a later workflow's provider are deleted",
         ctx do
      northwind = provider!(ctx.scope, "Northwind keys")
      checkout = provider!(ctx.scope, "Checkout keys")
      choose!(ctx.scope, {:workspace, "plan-the-build"}, northwind)
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, checkout)
      assert {:ok, _version} = save(ctx.scope, ~w(plan-the-build write-acceptance-checks))

      no_keys!(checkout)
      assert {{:ended, :session_key_missing}, _queued} = claim!(ctx)
    end

    test "ends the run session_key_missing after a workflow's runtime moves to another API of the start key's provider",
         ctx do
      second = second_api!()
      northwind = provider!(ctx.scope, "Northwind keys")
      choose!(ctx.scope, {:workspace, "plan-the-build"}, northwind)
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, northwind)
      assert {:ok, _version} = save(ctx.scope, ~w(plan-the-build write-acceptance-checks))

      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, northwind, %{
        runtime: second.name
      })

      assert {{:ended, :session_key_missing}, _queued} = claim!(ctx)

      # The build ends it too, where the choice changed after the guard.
      assert built(queued!(ctx)) == {:end, :session_key_missing}
    end

    test "after a first session on the machine's key, ends the run session_key_missing where two later sessions use two APIs of one provider",
         ctx do
      second = second_api!()
      northwind = provider!(ctx.scope, "Northwind keys")
      workflows = ~w(plan-the-build write-acceptance-checks review-the-build)
      # plan-the-build has no model choice at any level: session 1 runs on the machine's
      # key, and the run has no start key.
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, northwind)
      choose!(ctx.scope, {:workspace, "review-the-build"}, northwind)
      assert {:ok, _version} = save(ctx.scope, workflows)

      choose!(ctx.scope, {:workspace, "review-the-build"}, northwind, %{runtime: second.name})
      assert {{:ended, :session_key_missing}, _queued} = claim!(ctx)
      assert built(queued!(ctx)) == {:end, :session_key_missing}

      # The save finds the same fault, against the first workflow on that provider.
      assert {:error, errors} = save(ctx.scope, workflows)

      assert error(errors, :session_key_missing).detail ==
               {:session_key_missing, :other_api, "review-the-build", "Anthropic Messages",
                "Northwind keys", "write-acceptance-checks"}
    end

    test "after a first session on another provider, ends the build session_key_missing where two later sessions use two APIs of one provider",
         ctx do
      second = second_api!()
      northwind = provider!(ctx.scope, "Northwind keys")
      checkout = provider!(ctx.scope, "Checkout keys")
      workflows = ~w(plan-the-build write-acceptance-checks review-the-build)
      # Session 1 starts on Northwind keys' key; sessions 2 and 3 run on Checkout keys.
      choose!(ctx.scope, {:workspace, "plan-the-build"}, northwind)
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, checkout)
      choose!(ctx.scope, {:workspace, "review-the-build"}, checkout)
      assert {:ok, _version} = save(ctx.scope, workflows)

      # Session 3 moves to a runtime of a second API of Checkout keys. The claim's guard
      # refuses that too, so the build is called as the claim calls it after the guard.
      choose!(ctx.scope, {:workspace, "review-the-build"}, checkout, %{runtime: second.name})
      assert built(queued!(ctx)) == {:end, :session_key_missing}
    end

    test "ends the run too_many_providers after the 7th workflow's choice is set", ctx do
      providers = six_providers!(ctx)
      assert {{:ok, _run}, _queued} = claim!(ctx)

      choose!(ctx.scope, {:workspace, "step-7"}, List.last(providers))
      assert {{:ended, :too_many_providers}, _queued} = claim!(ctx)
    end

    # A version saved from a harness without the check of the model choices, as the
    # harness switch saves its update (`Apiary.Processes.save_harness/5` with no
    # `models:`).
    defp harness_version!(ctx, workflows) do
      template = %{
        "source" => "repository",
        "commit" => Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
      }

      {:ok, version} =
        Processes.save_harness(ctx.scope, ctx.scope.workspace, document(workflows), template,
          based_on: nil
        )

      version
    end

    test "ends the build too_many_providers for 7 providers that the guard did not see",
         ctx do
      providers = providers!(ctx.scope, 7)

      for {provider, workflow} <- Enum.zip(providers, steps(7)),
          do: choose!(ctx.scope, {:workspace, workflow}, provider)

      # Saved without the check of the model choices; the claim's guard would end the run
      # first, so the build is called as the claim calls it after the guard.
      harness_version!(ctx, steps(7))
      assert built(queued!(ctx)) == {:end, :too_many_providers}
    end

    test "ends the run model_choice_missing, or too_many_providers, after a harness change",
         ctx do
      openai_first!(ctx)
      harness_version!(ctx, ~w(plan-the-build write-acceptance-checks review-the-build))
      assert {{:ended, :model_choice_missing}, _queued} = claim!(ctx)

      providers = providers!(ctx.scope, 6)

      for {provider, workflow} <- Enum.zip(providers, steps(6)),
          do: choose!(ctx.scope, {:workspace, workflow}, provider)

      harness_version!(ctx, ~w(plan-the-build write-acceptance-checks) ++ steps(6))
      assert {{:ended, :too_many_providers}, _queued} = claim!(ctx)
    end
  end

  describe "the lines of a run the claim ended for its stage's model choices" do
    defp work_item(%DispatchRun{work_item_id: id}), do: Repo.get!(WorkItem, id)

    defp line(%DispatchRun{id: id} = queued),
      do: StopCause.text(Repo.get!(DispatchRun, id), work_item(queued), %{})

    defp view_models(queued),
      do: ExploreView.explore(work_item(queued), DateTime.utc_now()).run.shared_models

    @missing_cause "The run did not start, because a workflow of Build had no model, and that workflow's runtime could not use the provider that the run would start on."
    @key_cause "The run did not start, because a workflow of Build would run on a provider that has no key in the run, or on a second API of a provider that an earlier workflow uses."
    @too_many_cause "The run did not start, because the workflows of Build used more than 6 model providers."

    test "of model_choice_missing show the fix with its values while that fault remains, else the round again",
         ctx do
      %{storefront: storefront, northwind: northwind} = openai_first!(ctx)

      {:ok, _deleted} =
        ModelChoices.delete_choice(ctx.scope, {:workspace, "write-acceptance-checks"})

      {{:ended, :model_choice_missing}, queued} = claim!(ctx)

      assert line(queued) == @missing_cause <> "\n" <> @missing

      assert view_models(queued) ==
               {:model_choice_missing, "write-acceptance-checks", "Claude Code",
                "Storefront keys"}

      # The fault fixed: the cause's line, and the round again.
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, northwind)
      assert line(queued) == @missing_cause <> "\nRun the round again."
      assert view_models(queued) == nil

      # The other fault, 7 providers through the fallbacks: the same. A workflow's choice
      # stores no fallbacks, so write-acceptance-checks takes the workspace's choice, on
      # Northwind keys, with 5 fallbacks.
      others = providers!(ctx.scope, 5)
      fallbacks = Enum.map(others, &Apiary.ModelChoicesFixtures.fallback_attrs/1)
      choose!(ctx.scope, :workspace, northwind, %{fallbacks: fallbacks})

      {:ok, _deleted} =
        ModelChoices.delete_choice(ctx.scope, {:workspace, "write-acceptance-checks"})

      assert line(queued) == @missing_cause <> "\nRun the round again."

      names = Enum.map([storefront, northwind | others], & &1.name)
      assert view_models(queued) == {:too_many_providers, 7, names}
    end

    test "of session_key_missing for a provider with no key show the fix with its values while that fault remains, else the round again",
         ctx do
      northwind = provider!(ctx.scope, "Northwind keys")
      checkout = provider!(ctx.scope, "Checkout keys")
      choose!(ctx.scope, {:workspace, "plan-the-build"}, northwind)
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, checkout)
      assert {:ok, _version} = save(ctx.scope, ~w(plan-the-build write-acceptance-checks))
      no_keys!(checkout)

      {{:ended, :session_key_missing}, queued} = claim!(ctx)

      assert line(queued) == @key_cause <> "\n" <> @no_key

      assert view_models(queued) ==
               {:session_key_missing, :no_key, "write-acceptance-checks", "Checkout keys"}

      # The stop line's fix is the save's refusal.
      refusal = %{error: :session_key_missing, detail: view_models(queued)}
      assert Words.refusal(refusal, nil) == @no_key

      # The fault fixed: the cause's line, and the round again.
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, northwind)
      assert line(queued) == @key_cause <> "\nRun the round again."
      assert view_models(queued) == nil
    end

    test "of session_key_missing for a second API show the fix with its values while that fault remains, else the round again",
         ctx do
      second = second_api!()
      northwind = provider!(ctx.scope, "Northwind keys")
      choose!(ctx.scope, {:workspace, "plan-the-build"}, northwind)
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, northwind)
      assert {:ok, _version} = save(ctx.scope, ~w(plan-the-build write-acceptance-checks))

      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, northwind, %{
        runtime: second.name
      })

      {{:ended, :session_key_missing}, queued} = claim!(ctx)

      assert line(queued) == @key_cause <> "\n" <> @other_api

      assert view_models(queued) ==
               {:session_key_missing, :other_api, "write-acceptance-checks", "Anthropic Messages",
                "Northwind keys", "plan-the-build"}

      refusal = %{error: :session_key_missing, detail: view_models(queued)}
      assert Words.refusal(refusal, nil) == @other_api

      # The fault fixed: the cause's line, and the round again.
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, northwind, %{
        runtime: ModelChoices.default_runtime().name
      })

      assert line(queued) == @key_cause <> "\nRun the round again."
      assert view_models(queued) == nil
    end

    test "of too_many_providers show the fix with its values while that fault remains, else the round again",
         ctx do
      [first | rest] = providers = six_providers!(ctx)
      choose!(ctx.scope, :workspace, List.last(providers))
      {{:ended, :too_many_providers}, queued} = claim!(ctx)

      # In the order the claim walks them: step-1's choice, then the workspace's, which
      # each workflow's choice walks after its provider.
      {others, [seventh]} = Enum.split(rest, -1)
      names = Enum.map([first, seventh | others], & &1.name)
      assert line(queued) == @too_many_cause <> "\n" <> too_many(names)
      assert view_models(queued) == {:too_many_providers, 7, names}

      # The fault fixed: the cause's line, and the round again.
      choose!(ctx.scope, :workspace, hd(providers))
      assert line(queued) == @too_many_cause <> "\nRun the round again."
      assert view_models(queued) == nil

      # The other fault: step-7 has no model, and the runs start on Storefront keys.
      {:ok, _deleted} = ModelChoices.delete_choice(ctx.scope, :workspace)
      storefront = provider!(ctx.scope, "Storefront keys", kind: "openai")
      choose!(ctx.scope, {:workspace, "step-1"}, storefront)
      assert line(queued) == @too_many_cause <> "\nRun the round again."

      assert view_models(queued) ==
               {:model_choice_missing, "step-7", "Claude Code", "Storefront keys"}
    end
  end

  describe "a run of the stage that paused" do
    # Session 2 writes its transcript at a path of its session id.
    @session_id "e5f6a7b8"
    @transcript "~/.claude/projects/-workspace/#{@session_id}.jsonl"

    # The run stores the verdict `verdict` during its session, as a run does through the
    # run API.
    defp verdict!(run, verdict) do
      {:ok, _version} =
        Apiary.Stages.Artifacts.push_json(
          {:run, run},
          Repo.get!(WorkItem, run.work_item_id),
          "verdict",
          %{"verdict" => verdict},
          stage_id: run.stage_id
        )

      :ok
    end

    # A fresh work item's run of the stage, claimed and handed over; then, before its exit,
    # `before_exit` called with the registered run. With `session: 2` the run moves to its
    # second session, which writes a transcript chunk and pauses with `reason`; with
    # `session: nil` the run pauses with no session's exit. With `runtimes`, a runtime by
    # session number, sessions 1 and 2 start on those runtimes, else on `claude`. The
    # paused run, its run of the queue read again, and the continuation.
    defp paused!(ctx, opts) do
      reason = Keyword.get(opts, :reason, "model_key_limit")
      queued = queued!(ctx)
      %{dispatch_run: dispatch_run, run: run} = handed_over(ctx.scope, ctx.key, queued, %{})

      if opts[:session] == 2 do
        :ok = verdict!(dispatch_run, "passed")

        assert {:session, %{session: 2}} =
                 Apiary.Stages.next_session(dispatch_run, %{
                   session: 1,
                   state: "succeeded",
                   reason: nil
                 })

        chunk = %{
          "session" => 2,
          "session_id" => @session_id,
          "path" => @transcript,
          "offset" => 0,
          "bytes" => Base.encode64(~s({"s":2}\n))
        }

        if runtimes = opts[:runtimes] do
          for session <- [1, 2] do
            runtime = Map.get(runtimes, session, "claude")
            data = %{"session" => session, "runtime" => runtime, "command" => runtime}
            data = Apiary.RunEventsFixtures.session_started_data(data)
            event_fixture(run, session, "session.started", data)
          end
        end

        event_fixture(run, 3, "session.transcript", chunk)
        exited = %{"session" => 1, "state" => "succeeded", "exit_code" => 0}
        event_fixture(run, 4, "session.exited", exited)
        paused = %{"session" => 2, "state" => "paused", "exit_code" => 1, "reason" => reason}
        event_fixture(run, 5, "session.exited", paused)
      end

      if fun = opts[:before_exit], do: fun.(run)
      exited = %{"state" => "paused", "reason" => reason, "exit_code" => 143}
      event_fixture(run, 9, "run.exited", exited)
      assert {:ok, %Run{state: "paused"}} = Projector.project(run)

      continuation =
        Repo.one!(from d in DispatchRun, where: d.continues_id == ^dispatch_run.id)

      {Repo.get!(Run, run.id), Repo.get!(DispatchRun, dispatch_run.id), continuation}
    end

    defp paused_line(paused),
      do:
        paused
        |> Pause.of_run()
        |> ApiaryWeb.PauseWords.line(nil)
        |> ApiaryWeb.RichText.plain_text()

    # Northwind keys for the first workflow and Checkout keys for the second, each with one
    # key; saved.
    defp two_providers!(ctx) do
      northwind = provider!(ctx.scope, "Northwind keys")
      checkout = provider!(ctx.scope, "Checkout keys")
      choose!(ctx.scope, {:workspace, "plan-the-build"}, northwind)
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, checkout)
      assert {:ok, _version} = save(ctx.scope, ~w(plan-the-build write-acceptance-checks))
      %{northwind: northwind, checkout: checkout}
    end

    test "in its second session keeps the end of the cooldown of that session's provider, which the Paused line shows",
         ctx do
      %{northwind: northwind, checkout: checkout} = two_providers!(ctx)
      soon = in_seconds(3_600)
      later = in_seconds(7_200)

      # Every key cools after the claim: the start provider's until soon, Checkout keys'
      # until later.
      cool = fn _run ->
        key_state!(northwind, "key-1", until: soon)
        key_state!(checkout, "key-1", until: later)
      end

      {paused, dispatch_run, _continuation} = paused!(ctx, session: 2, before_exit: cool)

      assert paused.paused_session == 2
      assert Run.session_provider_ids(paused, 2) == [checkout.id]
      assert DateTime.compare(dispatch_run.paused_until, later) == :eq
      assert %{provider: "Checkout keys", until: until} = Pause.of_run(paused)
      assert DateTime.compare(until, later) == :eq
      assert paused_line(paused) =~ "Paused: every key of Checkout keys is in cooldown until "
    end

    test "with no session that paused keeps the earliest end among every provider; the Paused line shows the start key's",
         ctx do
      %{northwind: northwind, checkout: checkout} = two_providers!(ctx)
      soon = in_seconds(3_600)
      later = in_seconds(7_200)

      cool = fn _run ->
        key_state!(northwind, "key-1", until: later)
        key_state!(checkout, "key-1", until: soon)
      end

      {paused, dispatch_run, _continuation} = paused!(ctx, session: nil, before_exit: cool)

      assert paused.paused_session == nil
      assert Run.session_provider_ids(paused, nil) == [northwind.id, checkout.id]
      assert DateTime.compare(dispatch_run.paused_until, soon) == :eq
      assert %{provider: "Northwind keys"} = Pause.of_run(paused)
      assert paused_line(paused) =~ "Paused: every key of Northwind keys is in cooldown until "
    end

    test "in a Codex session after a Claude Code session resumes the Codex session with an OpenAI key",
         ctx do
      northwind = provider!(ctx.scope, "Northwind keys")
      storefront = provider!(ctx.scope, "Storefront keys", kind: "openai")
      choose!(ctx.scope, {:workspace, "plan-the-build"}, northwind)
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, storefront)
      assert {:ok, _version} = save(ctx.scope, ~w(plan-the-build write-acceptance-checks))

      # Session 1 runs on Claude Code, and session 2 on Codex.
      {paused, _dispatch_run, continuation} =
        paused!(ctx, session: 2, runtimes: %{1 => "claude", 2 => "codex"})

      assert paused.paused_session == 2
      assert paused.runtime == "codex"
      assert Run.session_provider_ids(paused, 2) == [storefront.id]

      assert {{:ok, run}, _queued} = claimed!(ctx, continuation)
      start = "#{storefront.public_id}-1"

      assert run.provider_connection_id == storefront.id
      assert [%ModelKey{name: ^start, start: true} | _rest] = stored_keys(run)
      assert {:ok, %{name: ^start}} = ProviderCredential.for_run(run)
      assert %{"session_id" => @session_id, "path" => @transcript} = run.resume
      assert Transcript.last(paused.id, 2) == %{session_id: @session_id, path: @transcript}
      assert %{"runtime" => "codex", "model" => "gpt-6-astra"} = run.run_settings
    end

    test "in a Codex session with model_key_switch resumes the Codex session once the report window has passed",
         ctx do
      northwind = provider!(ctx.scope, "Northwind keys")
      storefront = provider!(ctx.scope, "Storefront keys", kind: "openai")
      choose!(ctx.scope, {:workspace, "plan-the-build"}, northwind)
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, storefront)
      assert {:ok, _version} = save(ctx.scope, ~w(plan-the-build write-acceptance-checks))

      {paused, _dispatch_run, continuation} =
        paused!(ctx,
          session: 2,
          reason: "model_key_switch",
          runtimes: %{1 => "claude", 2 => "codex"}
        )

      assert paused.exit_reason == "model_key_switch"
      assert paused.paused_session == 2
      assert %DateTime{} = continuation.report_wait_until

      # The report window has passed: a claim takes the continuation.
      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^continuation.id),
          set: [report_wait_until: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      assert {{:ok, run}, _queued} = claimed!(ctx, continuation)
      assert run.provider_connection_id == storefront.id
      assert %{"session_id" => @session_id, "path" => @transcript} = run.resume
      assert %{"runtime" => "codex"} = run.run_settings
    end

    test "is continued on the paused session's provider, which the default runtime can use, though session 1's cannot",
         ctx do
      storefront = provider!(ctx.scope, "Storefront keys", kind: "openai")
      northwind = provider!(ctx.scope, "Northwind keys")
      workflows = ~w(plan-the-build write-acceptance-checks review-the-build)
      choose!(ctx.scope, {:workspace, "plan-the-build"}, storefront)
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, northwind)
      choose!(ctx.scope, {:workspace, "review-the-build"}, northwind)
      assert {:ok, _version} = save(ctx.scope, workflows)

      # After the claim, review-the-build has no model choice: it runs on Claude Code,
      # which cannot use Storefront keys, the provider of session 1.
      clear = fn _run ->
        {:ok, _deleted} = ModelChoices.delete_choice(ctx.scope, {:workspace, "review-the-build"})
      end

      {paused, _dispatch_run, continuation} = paused!(ctx, session: 2, before_exit: clear)
      assert Run.session_provider_ids(paused, 2) == [northwind.id]

      assert {{:ok, run}, _queued} = claimed!(ctx, continuation)
      assert run.provider_connection_id == northwind.id

      # A new run of the stage starts on Storefront keys, and ends.
      assert {{:ended, :model_choice_missing}, _queued} = claim!(ctx)
    end

    test "on a provider the default runtime cannot use ends the continuation model_choice_missing",
         ctx do
      northwind = provider!(ctx.scope, "Northwind keys")
      storefront = provider!(ctx.scope, "Storefront keys", kind: "openai")
      choose!(ctx.scope, {:workspace, "plan-the-build"}, northwind)
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, storefront)

      assert {:ok, _version} =
               save(ctx.scope, ~w(plan-the-build write-acceptance-checks review-the-build))

      {paused, _dispatch_run, continuation} = paused!(ctx, session: 2)
      assert Run.session_provider_ids(paused, 2) == [storefront.id]

      assert {{:ended, :model_choice_missing}, _queued} = claimed!(ctx, continuation)
    end

    test "on such a provider ends the continuation model_choice_missing though no choice uses that provider any more",
         ctx do
      northwind = provider!(ctx.scope, "Northwind keys")
      storefront = provider!(ctx.scope, "Storefront keys", kind: "openai")
      choose!(ctx.scope, {:workspace, "plan-the-build"}, northwind)
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, storefront)

      assert {:ok, _version} =
               save(ctx.scope, ~w(plan-the-build write-acceptance-checks review-the-build))

      {paused, _dispatch_run, continuation} = paused!(ctx, session: 2)
      assert Run.session_provider_ids(paused, 2) == [storefront.id]

      # After the pause, write-acceptance-checks moves to Northwind keys: the continuation
      # still starts on Storefront keys, which no choice of the stage uses now.
      choose!(ctx.scope, {:workspace, "write-acceptance-checks"}, northwind)

      assert {{:ended, :model_choice_missing}, _queued} = claimed!(ctx, continuation)
    end
  end
end
