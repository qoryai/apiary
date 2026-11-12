defmodule Apiary.Connections.SettingsFitTest do
  # Whether a model provider's saved settings fit the catalogue entry of its kind
  # (`Apiary.Connections.SettingsFit`, `Apiary.Connections.provider/1`): an answer the
  # settings decide is kept by the settings and the entry; a check that ran out of time
  # or crashed is kept by no one, ends no run and leaves a claim to the next one. The test
  # sets the check in the application environment, which every process reads, so it is
  # not async.
  use Apiary.DataCase, async: false

  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures
  import ExUnit.CaptureLog

  alias Apiary.{Connections, Dispatches, ModelChoices, Repo}
  alias Apiary.Connections.{Connection, SettingsFit}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Runs.{ProviderCredential, Run}

  @moduletag needs: [:factory, :secrets]

  @body ~s({"version":1,"time":"2026-10-18T12:00:00Z"})

  setup do
    %{scope: scope} = sign_up_fixture()

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "claude-subscription",
        keys: [%{value_id: "main", value: "sk-ant-oat01-fit-main-0123456789"}]
      })

    SettingsFit.clear()

    on_exit(fn ->
      Application.delete_env(:apiary, SettingsFit)
      SettingsFit.clear()
    end)

    scope
    |> handover_place_fixture(allow_secrets: true)
    |> Map.merge(%{scope: scope, provider: provider})
  end

  # Each check returns `answer`, and sends the test the settings it checked.
  defp check_returns(answer) do
    test = self()

    Application.put_env(:apiary, SettingsFit,
      check: fn _entry, settings ->
        send(test, {:checked, settings})
        answer
      end
    )

    SettingsFit.clear()
  end

  defp handover!(ctx) do
    work_item = work_item_fixture(ctx.scope, %{})
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    {queued, walked_claim(ctx.key, Dispatches.now(), @body)}
  end

  describe "the kept answer" do
    test "is read again for the same settings and entry", ctx do
      check_returns(:fit)
      assert {:ok, _entry} = Connections.provider(ctx.provider)
      assert_received {:checked, %{}}

      assert {:ok, _entry} = Connections.provider(ctx.provider)
      refute_received {:checked, _settings}
    end

    test "is checked again for other settings", ctx do
      check_returns(:unfit)
      assert Connections.provider(ctx.provider) == {:error, :provider_changed}
      assert_received {:checked, %{}}

      other = %{ctx.provider | settings: ~s({"region":"eu"})}
      assert Connections.provider(other) == {:error, :provider_changed}
      assert_received {:checked, %{"region" => "eu"}}

      assert Connections.provider(other) == {:error, :provider_changed}
      refute_received {:checked, _settings}
    end

    test "is none for a check that ran out of time or crashed", ctx do
      check_returns(:unchecked)
      assert Connections.provider(ctx.provider) == {:error, :provider_unchecked}
      assert Connections.provider(ctx.provider) == {:error, :provider_unchecked}
      assert_received {:checked, _settings}
      assert_received {:checked, _settings}

      check_returns(:fit)
      assert {:ok, _entry} = Connections.provider(ctx.provider)
    end
  end

  describe "a check that ran out of time or crashed" do
    test "fails the claim and leaves the run waiting for the next one", ctx do
      pid = ctx.provider.public_id
      {:ok, _choice} = ModelChoices.put_choice(ctx.scope, :workspace, %{provider: pid})
      check_returns(:unchecked)

      {{queued, answer}, log} = with_log(fn -> handover!(ctx) end)
      assert answer == {:error, :unavailable}
      assert log =~ "the check of the settings of the run's model provider ran out of time"
      assert %DispatchRun{state: :waiting, end_cause: nil} = Repo.get!(DispatchRun, queued.id)

      check_returns(:fit)
      assert {:ok, %{registered: run}} = walked_claim(ctx.key, Dispatches.now(), @body)
      assert %Run{model_keys: [_key]} = Repo.get!(Run, run.id)
    end

    test "leaves a run without a run configuration for that request, and ends nothing", ctx do
      pid = ctx.provider.public_id
      {:ok, _choice} = ModelChoices.put_choice(ctx.scope, :workspace, %{provider: pid})
      check_returns(:fit)
      assert {_queued, {:ok, %{registered: run}}} = handover!(ctx)
      run = Repo.get!(Run, run.id)

      check_returns(:unchecked)

      log =
        capture_log(fn -> assert ProviderCredential.for_run(run) == {:error, :unavailable} end)

      assert log =~ "ran out of time or crashed: the run has no run configuration"
      refute log =~ "catalogue"

      check_returns(:fit)
      assert {:ok, %{keys: [_key]}} = ProviderCredential.for_run(run)
    end

    test "leaves the provider out of the models, and Edit fails without a change", ctx do
      check_returns(:unchecked)
      assert Connections.provider_models(ctx.provider) == []

      assert Connections.update_provider(ctx.scope, ctx.provider, %{name: "Other"}) ==
               {:error, :provider_unchecked}

      assert %Connection{name: name} = Repo.get!(Connection, ctx.provider.id)
      assert name == ctx.provider.name
      assert Connections.intact?(Repo.get!(Connection, ctx.provider.id))
    end
  end
end
