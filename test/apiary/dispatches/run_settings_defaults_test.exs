defmodule Apiary.Dispatches.RunSettingsDefaultsTest do
  # Every explore run's `run_settings` (`Apiary.Dispatches.RunSettings`): the runtime and
  # model of the choice in effect, in the order a workflow's choice, the workspace's, the
  # organisation's default, then the catalogue's default runtime alone; the same with the
  # feature `factory` or `secrets` off, with no key for the run; and none for a prebuild.
  # Not async: the tests set the features in the application environment.
  use Apiary.DataCase, async: false

  import Apiary.DispatchedRunsFixtures
  import Apiary.ModelKeysFixtures, only: [stored_keys: 1]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, ModelChoices, Stacks}
  alias Apiary.Dispatches.{DispatchRun, RunSettings}
  alias Apiary.Runs.Run

  @moduletag needs: :factory

  # The catalogue's runtime, read from the list rather than named here.
  @runtime hd(Apiary.Kinds.Runtimes.list()).name

  @body ~s({"version":1,"time":"2026-10-18T12:00:00Z"})
  @harness "extends: {git: https://code.example.com/team/stacks, ref: main, path: core}\n"
  @workflow "explore-a-ticket"

  setup do
    %{scope: scope} = sign_up_fixture()

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: "sk-ant-defaults-0123456789"}]
      })

    %{scope: scope, provider: provider}
  end

  defp choose!(ctx, place, model) do
    {:ok, _choice} =
      ModelChoices.put_choice(ctx.scope, place, %{provider: ctx.provider.public_id, model: model})
  end

  # Stores the workspace's stack row for the workflow: the run's one row with a workflow.
  defp workflow!(%{scope: scope}) do
    {:ok, _stack} = Stacks.put_stack(scope, {:workspace, scope.workspace, @workflow}, @harness)
  end

  # A fresh work item's explore run, queued and claimed under `place`'s pool key: what the
  # run's documents are made from, with the registered run as `run`.
  defp claim!(%{scope: scope}, place) do
    work_item = work_item_fixture(scope)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    walk_resolved!(queued, [])

    {:ok, %{registered: run, documents: documents}} =
      walked_claim(place.key, Dispatches.now(), @body)

    Map.put(documents, :run, run)
  end

  defp settings(%{run_settings: settings}), do: settings |> Jason.encode!() |> Jason.decode!()

  # The instance's features set to `features` for the rest of the test.
  defp features!(features), do: Application.put_env(:apiary, :features, features)

  describe "with every feature on, the runtime and model come from" do
    test "the workflow's choice, else the workspace's, else the organisation's, else the catalogue's runtime",
         ctx do
      workflow!(ctx)
      place = handover_place_fixture(ctx.scope, allow_secrets: true)

      claimed = claim!(ctx, place)
      assert settings(claimed) == %{"runtime" => @runtime}
      assert %{"time_limit_minutes" => 180} = Map.new(claimed.session)

      choose!(ctx, :organisation, "claude-haiku-5-5")

      assert %{"runtime" => @runtime, "model" => "claude-haiku-5-5"} =
               settings(claim!(ctx, place))

      choose!(ctx, :workspace, "claude-opus-5-5")
      assert %{"runtime" => @runtime, "model" => "claude-opus-5-5"} = settings(claim!(ctx, place))

      choose!(ctx, {:workspace, @workflow}, "claude-sonnet-5-5")

      assert %{"runtime" => @runtime, "model" => "claude-sonnet-5-5"} =
               claimed = settings(claim!(ctx, place))

      assert claimed["provider_models"] != nil
    end
  end

  # A fresh work item's explore run, queued under every feature: the run of the queue.
  defp queued!(%{scope: scope}) do
    work_item = work_item_fixture(scope)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    queued
  end

  # The run settings a claim of `queued` builds under the instance's features now: a pool
  # claims nothing with `factory` off (`dispatch.claim` is of `factory`), so these tests
  # call what the claim calls.
  defp built!(queued) do
    {:ok, built} = queued |> RunSettings.hold() |> RunSettings.build()
    built
  end

  defp wire(%{wire: wire}), do: wire |> Jason.encode!() |> Jason.decode!()

  describe "with the feature factory off" do
    @describetag with_features: Apiary.Features.all()
    test "the run gets the workspace's runtime and model, with no key and no time limit", ctx do
      workflow!(ctx)
      choose!(ctx, :workspace, "claude-opus-5-5")
      queued = queued!(ctx)

      features!([:observability, :security, :secrets])
      built = built!(queued)

      assert %{"runtime" => @runtime, "model" => "claude-opus-5-5", "provider_models" => [_ | _]} =
               settings = wire(built)

      assert built.stored == settings
      assert built.columns == %{}
      assert %{time_limit: nil, time_limits: %{}} = RunSettings.hold(queued)
    end

    test "the workflow's choice wins over the workspace's", ctx do
      workflow!(ctx)
      choose!(ctx, :workspace, "claude-opus-5-5")
      choose!(ctx, {:workspace, @workflow}, "claude-sonnet-5-5")
      queued = queued!(ctx)

      features!([:observability, :security, :secrets])

      assert %{"runtime" => @runtime, "model" => "claude-sonnet-5-5"} = wire(built!(queued))
    end

    test "with no choice at any level, the run gets the catalogue's runtime alone", ctx do
      workflow!(ctx)
      queued = queued!(ctx)

      features!([:observability, :security, :secrets])
      assert wire(built!(queued)) == %{"runtime" => @runtime}
    end
  end

  describe "with the feature secrets off" do
    @describetag with_features: Apiary.Features.all()
    test "the run gets the runtime and model with no key, whatever the gateway's keys", ctx do
      workflow!(ctx)
      choose!(ctx, :workspace, "claude-opus-5-5")
      choose!(ctx, {:workspace, @workflow}, "claude-sonnet-5-5")
      # The gateway's key has no stored-secrets flag: with no key for the run, the claim
      # does not end it `secrets_not_allowed`.
      place = handover_place_fixture(ctx.scope)

      # `factory` needs `secrets`, so no value of QORY_FEATURES gives these features: they
      # are set here so that a pool claims, which needs `factory`.
      features!(Apiary.Features.all() -- [:secrets])
      claimed = claim!(ctx, place)

      assert %{"runtime" => @runtime, "model" => "claude-sonnet-5-5"} = settings(claimed)

      assert %Run{provider_connection_id: nil} = Repo.get!(Run, claimed.run.id)
      assert stored_keys(claimed.run) == []
    end

    test "with factory off too, the run gets the runtime and model with no key", ctx do
      choose!(ctx, :workspace, "claude-opus-5-5")
      queued = queued!(ctx)

      features!([:observability, :security])
      built = built!(queued)

      assert %{"runtime" => @runtime, "model" => "claude-opus-5-5"} = wire(built)
      assert built.columns == %{}
    end

    test "a key the choice names that the provider no longer has ends no run", ctx do
      choose!(ctx, :workspace, "claude-opus-5-5")
      queued = queued!(ctx)

      Repo.update_all(
        from(c in ModelChoices.ModelChoice, where: c.workspace_id == ^ctx.scope.workspace.id),
        set: [value_id: "gone"]
      )

      features!([:observability, :security])

      assert %{"runtime" => @runtime, "model" => "claude-opus-5-5"} = wire(built!(queued))
    end
  end

  describe "a claim of a run of a shared stage" do
    @describetag needs: [:factory, :workflow_model]

    test "keeps the model of each later session's workflow on the run", ctx do
      stage = %{
        "id" => "st_6ns22c4pav",
        "name" => "Build",
        "inputs" => [],
        "shared_run" => true,
        "sequence" => [
          %{"workflow" => "plan-the-build"},
          %{"workflow" => "write-acceptance-checks"}
        ],
        "outputs" => [],
        "gate" => %{"kind" => "person", "approvers" => "members"}
      }

      document = %{"schema" => "qory.process/v1", "machine" => "default", "stages" => [stage]}
      {:ok, _version} = Apiary.Processes.save(ctx.scope, ctx.scope.workspace, document)

      choose!(ctx, :workspace, "claude-opus-5-5")
      choose!(ctx, {:workspace, "write-acceptance-checks"}, "claude-sonnet-5-5")
      place = handover_place_fixture(ctx.scope, allow_secrets: true)
      claimed = claim!(ctx, place)

      assert %{"model" => "claude-opus-5-5"} = settings(claimed)

      assert %Run{session_settings: %{"1" => session}} = Repo.get!(Run, claimed.run.id)

      assert %{
               "workflow" => "write-acceptance-checks",
               "model_choice" => %{"runtime" => "claude", "model" => "claude-sonnet-5-5"}
             } = session

      # Every key of the run is the provider's: the session joins with the start key's group.
      refute Map.has_key?(session, "model_credential")
    end
  end

  describe "a prebuild" do
    @describetag with_features: Apiary.Features.all()
    test "has no run settings, whatever the features", _ctx do
      prebuild = %DispatchRun{step: DispatchRun.prebuild()}
      assert RunSettings.hold(prebuild) == nil

      features!([:observability, :security])
      assert RunSettings.hold(prebuild) == nil
    end
  end
end
