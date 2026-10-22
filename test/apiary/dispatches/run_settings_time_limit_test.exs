defmodule Apiary.Dispatches.RunSettingsTimeLimitTest do
  # The `time_limit_minutes` of an explore run's `run_settings`
  # (`Apiary.Dispatches.RunSettings`): the minutes the time limits of the run's target and
  # workspace come to for the workflow of the workspace's entry in the machines file, the
  # last member, and absent with no limit or no workflow. Not async: the file read at boot
  # and the features are the whole node's.
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
  @stack %{
    "url" => "https://stacks.example.com/acme/stacks",
    "commit" => "0123456789abcdef0123456789abcdef01234567",
    "path" => "examples/hello"
  }

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

  # A fresh work item's explore run, queued, claimed under `place`'s pool key, said
  # started and handed over: the handover's answer.
  defp handover!(%{scope: scope}, place) do
    work_item = work_item_fixture(scope)
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    %{dispatch: dispatch} = dispatched!(place.key)
    {:ok, handed} = Dispatches.handover(place.key, dispatch.public_id, %{body: @body})
    handed
  end

  defp settings(%{run_settings: settings}), do: settings |> Jason.encode!() |> Jason.decode!()

  defp keys(%{run_settings: settings}) do
    ordered = settings |> Jason.encode!() |> Jason.decode!(objects: :ordered_objects)
    Enum.map(ordered.values, &elem(&1, 0))
  end

  # The work item's target, as the handover finds it by system and path.
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

      handed = handover!(ctx, place)

      assert settings(handed) == %{"runtime" => "claude", "time_limit_minutes" => 90}
      assert keys(handed) == ~w(runtime time_limit_minutes)

      assert %Run{run_settings: %{"runtime" => "claude", "time_limit_minutes" => 90}} =
               Repo.get!(Run, handed.run.id)
    end

    test "sends the target's limit over the workspace's", ctx do
      workflow!(ctx, "hello")
      place = handover_place_fixture(ctx.scope)
      target = target!(ctx.scope)
      {:ok, _} = TimeLimits.put_limit(ctx.scope, :workspace, "hello", 90)
      {:ok, _} = TimeLimits.put_limit(ctx.scope, target, "hello", 1440)

      assert %{"time_limit_minutes" => 1440} = settings(handover!(ctx, place))
    end

    test "leaves the member out with no limit, or a limit of another workflow", ctx do
      workflow!(ctx, "hello")
      place = handover_place_fixture(ctx.scope)
      assert settings(handover!(ctx, place)) == %{"runtime" => "claude"}

      {:ok, _} = TimeLimits.put_limit(ctx.scope, :workspace, "review", 90)
      assert settings(handover!(ctx, place)) == %{"runtime" => "claude"}
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

      handed = handover!(ctx, handover_place_fixture(ctx.scope, allow_secrets: true))

      assert %{"model" => "claude-opus-5-5", "time_limit_minutes" => 45} = settings(handed)
      assert keys(handed) == ~w(runtime model provider_models tiers time_limit_minutes)
    end
  end

  test "without a machines file, the member is absent whatever the limits", ctx do
    no_file!()
    place = handover_place_fixture(ctx.scope)
    {:ok, _} = TimeLimits.put_limit(ctx.scope, :workspace, "hello", 90)
    assert settings(handover!(ctx, place)) == %{"runtime" => "claude"}
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
