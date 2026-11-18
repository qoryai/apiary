defmodule Apiary.Dispatches.RunSettingsTimeLimitTest do
  # The `time_limit_minutes` of an explore run's documents, after `run_settings`
  # (`Apiary.Dispatches.RunSettings`, `Apiary.Dispatches.Handover`): the minutes the time
  # limits of the run's target and workspace come to for the run's workflow, read from the
  # one stack row with a workflow (`Apiary.Stacks.workflow/2`) or, with the workflow
  # model, from the run's stage entry; 180 minutes for a workflow with no limit, and
  # absent with no workflow. `run_settings` has no time limit. A stage entry's time limit is not read. Also the model choices of that
  # workflow, which apply only to its runs. Not async: the features are the whole node's.
  use Apiary.DataCase, async: false

  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, ModelChoices, Stacks, TimeLimits}
  alias Apiary.Runs.{Run, Target}

  @moduletag needs: :factory

  # The catalogue's runtime, read from the list rather than named here.
  @runtime hd(Apiary.Kinds.Runtimes.list()).name

  @body ~s({"version":1,"time":"2026-10-18T12:00:00Z"})
  @harness "extends: {git: https://code.example.com/team/stacks, ref: main, path: core}\n"
  @version "0123456789abcdef0123456789abcdef01234567"

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  # Stores the workspace's stack row for `workflow`: the run's one row with a workflow.
  defp workflow!(%{scope: scope}, workflow) do
    {:ok, _stack} = Stacks.put_stack(scope, {:workspace, scope.workspace, workflow}, @harness)
  end

  # A fresh work item's explore run, queued, its harness walk resolved with `walk`, and
  # claimed under `place`'s pool key: what the run's documents are made from, with the
  # registered run as `run`.
  defp claim!(%{scope: scope}, place, walk \\ []) do
    work_item = work_item_fixture(scope)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    walk_resolved!(queued, walk)

    {:ok, %{registered: run, documents: documents}} =
      Apiary.DispatchedRunsFixtures.walked_claim(place.key, Dispatches.now(), @body)

    Map.put(documents, :run, run)
  end

  defp settings(%{run_settings: settings}), do: settings |> Jason.encode!() |> Jason.decode!()

  # The members of the documents about the run's first session, by name.
  defp session(%{session: members}), do: Map.new(members)

  defp keys(%{run_settings: settings}) do
    ordered = settings |> Jason.encode!() |> Jason.decode!(objects: :ordered_objects)
    Enum.map(ordered.values, &elem(&1, 0))
  end

  # The work item's target, as the claim finds it by system and path.
  defp target!(scope) do
    Repo.insert!(%Target{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      system: "forge.example.com",
      path: "acme/shop",
      first_seen_at: DateTime.utc_now()
    })
  end

  describe "with the workflow model, a run of a stage entry with limits" do
    @describetag needs: [:factory, :workflow_model]

    # The workspace's process: Explore runs `workflow`, explore-a-ticket by default, with
    # `limits`.
    defp entry_limits!(%{scope: scope}, limits, workflow \\ "explore-a-ticket") do
      stage = %{
        "id" => "st_r79kph11eg",
        "name" => "Explore",
        "inputs" => [],
        "sequence" => [Map.merge(%{"workflow" => workflow}, limits)],
        "outputs" => [],
        "gate" => %{"kind" => "person", "approvers" => "members"}
      }

      document = %{"schema" => "qory.process/v1", "machine" => "default", "stages" => [stage]}
      {:ok, _version} = Apiary.Processes.save(scope, scope.workspace, document)
    end

    test "a saved limit reaches the sessions of that workflow in its next run; with none, 180 minutes",
         ctx do
      place = handover_place_fixture(ctx.scope)
      entry_limits!(ctx, %{})
      assert %{"time_limit_minutes" => 180} = session(claim!(ctx, place))

      {:ok, _} = TimeLimits.put_limit(ctx.scope, :workspace, "explore-a-ticket", 90)
      assert %{"time_limit_minutes" => 90} = session(claim!(ctx, place))

      {:ok, _} = TimeLimits.put_limit(ctx.scope, :workspace, "explore-a-ticket", 240)
      assert %{"time_limit_minutes" => 240} = session(claim!(ctx, place))
    end

    test "a saved limit of 45 minutes for explore-a-ticket reaches its run", ctx do
      place = handover_place_fixture(ctx.scope)
      {:ok, _} = TimeLimits.put_limit(ctx.scope, :workspace, "explore-a-ticket", 45)

      assert %{"time_limit_minutes" => 45} = session(claim!(ctx, place))
    end

    test "a cleared limit sends 180 minutes, whatever another workflow has", ctx do
      workflow!(ctx, "hello")
      place = handover_place_fixture(ctx.scope)
      {:ok, _} = TimeLimits.put_limit(ctx.scope, :workspace, "hello", 90)
      {:ok, _} = TimeLimits.put_limit(ctx.scope, :workspace, "explore-a-ticket", 30)

      assert %{"time_limit_minutes" => 30} = session(claim!(ctx, place))

      {:ok, _} = TimeLimits.delete_limit(ctx.scope, :workspace, "explore-a-ticket")
      assert %{"time_limit_minutes" => 180} = session(claim!(ctx, place))
    end

    test "a time limit on a stage entry of an older document is not read", ctx do
      workflow!(ctx, "explore-a-ticket")
      place = handover_place_fixture(ctx.scope)

      entry_limits!(ctx, %{"time_limit" => "45m"})
      assert %{"time_limit_minutes" => 180} = session(claim!(ctx, place))

      {:ok, _} = TimeLimits.put_limit(ctx.scope, :workspace, "explore-a-ticket", 90)
      assert %{"time_limit_minutes" => 90} = session(claim!(ctx, place))
    end

    test "any other workflow resolves its limit by the name of its entry", ctx do
      workflow!(ctx, "hello")
      place = handover_place_fixture(ctx.scope)
      {:ok, _} = TimeLimits.put_limit(ctx.scope, :workspace, "hello", 30)
      {:ok, _} = TimeLimits.put_limit(ctx.scope, :workspace, "review", 90)

      entry_limits!(ctx, %{}, "review")
      assert %{"time_limit_minutes" => 90} = session(claim!(ctx, place))
    end

    test "reads the target when the entry's access is read, whatever the walk resolved",
         ctx do
      workflow!(ctx, "explore-a-ticket")
      place = handover_place_fixture(ctx.scope)
      section = %{"extends" => %{"git" => "https://code.example.com/team/stacks"}}
      walk = [origin: :setting, document: section, access_level: :write]

      assert %{access: :write} = claim!(ctx, place, walk).harness

      entry_limits!(ctx, %{"access" => "read"})
      assert %{access: :read} = claim!(ctx, place, walk).harness
    end
  end

  describe "with one stack row with a workflow" do
    test "sends the workspace's limit after the runtime, and the run keeps it", ctx do
      workflow!(ctx, "explore-a-ticket")
      place = handover_place_fixture(ctx.scope)
      {:ok, _} = TimeLimits.put_limit(ctx.scope, :workspace, "explore-a-ticket", 90)

      section = %{"extends" => %{"git" => "https://code.example.com/team/stacks"}}
      claimed = claim!(ctx, place, origin: :setting, document: section, target_version: @version)

      assert claimed.harness == %{
               target_version: @version,
               workflow: "explore-a-ticket",
               harness_hidden: false,
               access: :read,
               harness: section
             }

      assert settings(claimed) == %{"runtime" => @runtime}
      assert session(claimed) == %{"time_limit_minutes" => 90}

      kept = Repo.get!(Run, claimed.run.id)
      assert kept.run_settings == %{"runtime" => @runtime}

      # The documents the run keeps have the limit right after `run_settings`.
      documents = Jason.decode!(kept.run_documents, objects: :ordered_objects)
      names = Enum.map(documents.values, &elem(&1, 0))

      assert names |> Enum.drop_while(&(&1 != "run_settings")) |> Enum.take(2) ==
               ~w(run_settings time_limit_minutes)

      assert documents["time_limit_minutes"] == 90
    end

    test "sends the target's limit over the workspace's", ctx do
      workflow!(ctx, "explore-a-ticket")
      place = handover_place_fixture(ctx.scope)
      target = target!(ctx.scope)
      {:ok, _} = TimeLimits.put_limit(ctx.scope, :workspace, "explore-a-ticket", 90)
      {:ok, _} = TimeLimits.put_limit(ctx.scope, target, "explore-a-ticket", 1440)

      assert %{"time_limit_minutes" => 1440} = session(claim!(ctx, place))
    end

    test "sends 180 minutes with no limit, or a limit of another workflow", ctx do
      workflow!(ctx, "explore-a-ticket")
      place = handover_place_fixture(ctx.scope)
      assert session(claim!(ctx, place)) == %{"time_limit_minutes" => 180}

      {:ok, _} = TimeLimits.put_limit(ctx.scope, :workspace, "review", 90)
      assert session(claim!(ctx, place)) == %{"time_limit_minutes" => 180}
    end

    test "sends the limit beside run_settings, which has the model choice's members alone",
         ctx do
      workflow!(ctx, "explore-a-ticket")

      {:ok, provider} =
        Connections.create_provider(ctx.scope, %{
          provider: "anthropic",
          keys: [%{value_id: "main", value: "sk-ant-time-limit-0123456789"}]
        })

      {:ok, _choice} =
        ModelChoices.put_choice(ctx.scope, :workspace, %{
          provider: provider.public_id,
          model: "claude-opus-5-5",
          tiers: %{"balanced" => "claude-haiku-5-5"}
        })

      {:ok, _} = TimeLimits.put_limit(ctx.scope, :workspace, "explore-a-ticket", 45)

      claimed = claim!(ctx, handover_place_fixture(ctx.scope, allow_secrets: true))

      assert %{"model" => "claude-opus-5-5"} = settings(claimed)
      assert session(claimed) == %{"time_limit_minutes" => 45}
      assert keys(claimed) == ~w(runtime model provider_models tiers)
    end
  end

  describe "the model choices of a workflow" do
    setup ctx do
      {:ok, provider} =
        Connections.create_provider(ctx.scope, %{
          provider: "anthropic",
          keys: [%{value_id: "main", value: "sk-ant-workflow-choice-0123456789"}]
        })

      choose = fn place, model ->
        {:ok, _choice} =
          ModelChoices.put_choice(ctx.scope, place, %{provider: provider.public_id, model: model})
      end

      choose.(:workspace, "claude-opus-5-5")
      %{choose: choose}
    end

    test "apply to the runs of the workspace's workflow, the target's over the workspace's",
         ctx do
      workflow!(ctx, "explore-a-ticket")
      place = handover_place_fixture(ctx.scope, allow_secrets: true)
      target = target!(ctx.scope)

      ctx.choose.({:workspace, "review"}, "claude-haiku-5-5")
      assert %{"model" => "claude-opus-5-5"} = settings(claim!(ctx, place))

      ctx.choose.({:workspace, "explore-a-ticket"}, "claude-sonnet-5-5")
      assert %{"model" => "claude-sonnet-5-5"} = settings(claim!(ctx, place))

      ctx.choose.({target, "explore-a-ticket"}, "claude-haiku-5-5")
      assert %{"model" => "claude-haiku-5-5"} = settings(claim!(ctx, place))
    end

    test "do not apply to a run of another workflow", ctx do
      place = handover_place_fixture(ctx.scope, allow_secrets: true)
      ctx.choose.({:workspace, "hello"}, "claude-sonnet-5-5")

      assert %{"model" => "claude-opus-5-5"} = settings(claim!(ctx, place))
    end

    @tag needs: [:factory, :workflow_model]
    test "apply to a stage's run of that workflow, with no stack row", ctx do
      place = handover_place_fixture(ctx.scope, allow_secrets: true)
      ctx.choose.({:workspace, "explore-a-ticket"}, "claude-sonnet-5-5")

      assert %{"model" => "claude-sonnet-5-5"} = settings(claim!(ctx, place))
    end

    @tag needs: [:factory, :workflow_model]
    test "of a saved row's workflow do not apply to a stage's run of another", ctx do
      workflow!(ctx, "hello")
      place = handover_place_fixture(ctx.scope, allow_secrets: true)
      ctx.choose.({:workspace, "hello"}, "claude-sonnet-5-5")

      assert %{"model" => "claude-opus-5-5"} = settings(claim!(ctx, place))
    end
  end

  @tag with_features: Apiary.Features.all() -- [:workflow_model]
  test "without a stack row with a workflow, the member is absent whatever the limits", ctx do
    place = handover_place_fixture(ctx.scope)
    {:ok, _} = TimeLimits.put_limit(ctx.scope, :workspace, "hello", 90)

    claimed = claim!(ctx, place)
    assert settings(claimed) == %{"runtime" => @runtime}
    assert session(claimed) == %{}
    assert claimed.harness == nil
  end

  @tag with_features: Apiary.Features.all() -- [:workflow_model]
  test "with two stack rows with a workflow, the member is absent whatever the limits", ctx do
    workflow!(ctx, "hello")
    {:ok, _stack} = Stacks.put_stack(ctx.scope, {:target, target!(ctx.scope), "hello"}, @harness)
    place = handover_place_fixture(ctx.scope)
    {:ok, _} = TimeLimits.put_limit(ctx.scope, :workspace, "hello", 90)

    claimed = claim!(ctx, place)
    assert settings(claimed) == %{"runtime" => @runtime}
    assert session(claimed) == %{}
    assert claimed.harness == nil
  end

  describe "with the feature factory off" do
    @describetag with_features: [:observability, :security]
    test "every function answers not_found, and nothing is written", ctx do
      %{scope: scope} = ctx

      assert TimeLimits.list_limits(scope) == {:error, :not_found}
      assert TimeLimits.resolve(scope, :workspace, "hello") == {:error, :not_found}

      assert TimeLimits.put_limit(scope, :workspace, "hello", 90) ==
               {:error, :not_found}

      assert TimeLimits.put_limit(scope, :workspace, "hello", 5) ==
               {:error, :not_found}

      assert TimeLimits.delete_limit(scope, :workspace, "hello") ==
               {:error, :not_found}

      assert Repo.aggregate(TimeLimits.TimeLimit, :count) == 0
    end
  end
end
