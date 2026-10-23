defmodule Apiary.Dispatches.RunSettingsTimeLimitTest do
  # The `time_limit_minutes` of an explore run's `run_settings`
  # (`Apiary.Dispatches.RunSettings`): the minutes the time limits of the run's target and
  # workspace come to for the workflow of the workspace's entry in the machines file, the
  # last member, and absent with no limit or no workflow; and the model choices of that
  # workflow, which apply only to its runs. Not async: the file read at boot and the
  # features are the whole node's.
  use Apiary.DataCase, async: false

  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, ModelChoices, TimeLimits}
  alias Apiary.Dispatches.MachinesFile
  alias Apiary.Runs.{Run, Target}

  @moduletag needs: :factory
  @moduletag :tmp_dir

  @body ~s({"version":1,"time":"2026-10-18T12:00:00Z"})
  @stack "core"

  setup %{tmp_dir: dir} do
    setting = Application.fetch_env(:apiary, :machines_file_setting)
    file = Application.fetch_env(:apiary, :machines_file)

    on_exit(fn ->
      restore(:machines_file_setting, setting)
      restore(:machines_file, file)
    end)

    %{scope: scope} = sign_up_fixture()
    %{scope: scope, dir: dir}
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:apiary, key, value)
  defp restore(key, :error), do: Application.delete_env(:apiary, key)

  # Boots with a machines file whose entry for the scope's workspace has the stack and
  # `workflow`.
  defp workflow!(%{scope: scope, dir: dir}, workflow) do
    path = Path.join(dir, "machines.json")
    place = "#{scope.organisation.slug}/#{scope.workspace.slug}"

    File.write!(
      path,
      Jason.encode!(%{"workspaces" => %{place => %{"stack" => @stack, "workflow" => workflow}}})
    )

    Application.put_env(:apiary, :machines_file_setting, path)
    MachinesFile.boot!()
  end

  defp no_file! do
    Application.put_env(:apiary, :machines_file_setting, nil)
    nil = MachinesFile.boot!()
  end

  # A fresh work item's explore run, queued and claimed under `place`'s pool key: what
  # the run's documents are made from, with the registered run as `run`.
  defp claim!(%{scope: scope}, place) do
    work_item = work_item_fixture(scope)
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

    {:ok, %{registered: run, documents: documents}} =
      Dispatches.claim(place.key, Dispatches.now(), @body)

    Map.put(documents, :run, run)
  end

  defp settings(%{run_settings: settings}), do: settings |> Jason.encode!() |> Jason.decode!()

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

  describe "with the workspace's workflow in the machines file" do
    test "sends the workspace's limit after the runtime, and the run keeps it", ctx do
      workflow!(ctx, "hello")
      place = handover_place_fixture(ctx.scope)
      {:ok, _} = TimeLimits.put_limit(ctx.scope, :workspace, "hello", 90)

      claimed = claim!(ctx, place)

      assert settings(claimed) == %{"runtime" => "claude", "time_limit_minutes" => 90}
      assert keys(claimed) == ~w(runtime time_limit_minutes)

      assert %Run{run_settings: %{"runtime" => "claude", "time_limit_minutes" => 90}} =
               Repo.get!(Run, claimed.run.id)
    end

    test "sends the target's limit over the workspace's", ctx do
      workflow!(ctx, "hello")
      place = handover_place_fixture(ctx.scope)
      target = target!(ctx.scope)
      {:ok, _} = TimeLimits.put_limit(ctx.scope, :workspace, "hello", 90)
      {:ok, _} = TimeLimits.put_limit(ctx.scope, target, "hello", 1440)

      assert %{"time_limit_minutes" => 1440} = settings(claim!(ctx, place))
    end

    test "leaves the member out with no limit, or a limit of another workflow", ctx do
      workflow!(ctx, "hello")
      place = handover_place_fixture(ctx.scope)
      assert settings(claim!(ctx, place)) == %{"runtime" => "claude"}

      {:ok, _} = TimeLimits.put_limit(ctx.scope, :workspace, "review", 90)
      assert settings(claim!(ctx, place)) == %{"runtime" => "claude"}
    end

    test "sends the limit after the model choice's members", ctx do
      workflow!(ctx, "hello")

      {:ok, provider} =
        Connections.create_provider(ctx.scope, %{
          provider: "anthropic",
          keys: [%{value_id: "main", value: "sk-ant-time-limit-0123456789"}]
        })

      {:ok, _choice} =
        ModelChoices.put_choice(ctx.scope, :workspace, %{
          provider: provider.public_id,
          model: "claude-opus-5-5",
          tiers: %{"fast" => "claude-haiku-5-5"}
        })

      {:ok, _} = TimeLimits.put_limit(ctx.scope, :workspace, "hello", 45)

      claimed = claim!(ctx, handover_place_fixture(ctx.scope, allow_secrets: true))

      assert %{"model" => "claude-opus-5-5", "time_limit_minutes" => 45} = settings(claimed)
      assert keys(claimed) == ~w(runtime model provider_models tiers time_limit_minutes)
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
      workflow!(ctx, "hello")
      place = handover_place_fixture(ctx.scope, allow_secrets: true)
      target = target!(ctx.scope)

      ctx.choose.({:workspace, "review"}, "claude-haiku-5-5")
      assert %{"model" => "claude-opus-5-5"} = settings(claim!(ctx, place))

      ctx.choose.({:workspace, "hello"}, "claude-sonnet-5-5")
      assert %{"model" => "claude-sonnet-5-5"} = settings(claim!(ctx, place))

      ctx.choose.({target, "hello"}, "claude-haiku-5-5")
      assert %{"model" => "claude-haiku-5-5"} = settings(claim!(ctx, place))
    end

    test "do not apply without a machines file", ctx do
      no_file!()
      place = handover_place_fixture(ctx.scope, allow_secrets: true)
      ctx.choose.({:workspace, "hello"}, "claude-sonnet-5-5")

      assert %{"model" => "claude-opus-5-5"} = settings(claim!(ctx, place))
    end
  end

  test "without a machines file, the member is absent whatever the limits", ctx do
    no_file!()
    place = handover_place_fixture(ctx.scope)
    {:ok, _} = TimeLimits.put_limit(ctx.scope, :workspace, "hello", 90)
    assert settings(claim!(ctx, place)) == %{"runtime" => "claude"}
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
