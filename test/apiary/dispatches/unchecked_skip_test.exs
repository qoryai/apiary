defmodule Apiary.Dispatches.UncheckedSkipTest do
  # A claim whose run's model provider settings check ran out of time or crashed
  # (`Apiary.Connections.provider/1`, `:provider_unchecked`) leaves that run waiting, as
  # for keys in cooldown, logs a warning, and takes the next waiting run; a later claim
  # takes the run once the check passes. The test sets the check for every process
  # (`Apiary.Connections.SettingsFit.put_test_check/1`), so it is not async.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.ConnectionsFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures
  import ExUnit.CaptureLog

  alias Apiary.{Connections, Dispatches, ModelChoices, Repo}
  alias Apiary.Connections.SettingsFit
  alias Apiary.Dispatches.{Dispatch, DispatchRun}

  @moduletag needs: [:factory, :secrets]

  @body ~s({"version":1,"time":"2026-10-18T12:00:00Z"})
  @skipped "a claim skipped the run"
  @api_key %{value_id: "main", value: "sk-ant-api03-skip-0123456789"}

  setup do
    SettingsFit.clear()

    on_exit(fn ->
      SettingsFit.put_test_check(nil)
      SettingsFit.clear()
    end)
  end

  # A model provider of `kind` of the scope's organisation, chosen for the runs of its
  # workspace.
  defp chosen!(scope, n, kind \\ "claude-subscription") do
    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: kind,
        keys: [%{value_id: "main", value: "sk-ant-oat01-skip-#{n}-0123456789"}]
      })

    {:ok, _choice} =
      ModelChoices.put_choice(scope, :workspace, %{provider: provider.public_id})

    provider
  end

  defp queued!(scope, attrs \\ %{}) do
    work_item = work_item_fixture(scope, attrs)
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    run
  end

  # The check returns `:unchecked` for its first `stops` calls, then `:fit`.
  defp stops_first(stops) do
    calls = :counters.new(1, [])

    SettingsFit.put_test_check(fn _entry, _settings ->
      :counters.add(calls, 1, 1)
      if :counters.get(calls, 1) <= stops, do: :unchecked, else: :fit
    end)

    SettingsFit.clear()
  end

  # Whether the run of the queue `queued` waits as it was queued: no end, its
  # `model_provider_ids` as they were, and no dispatch.
  # The Claude subscription's check stops each time; any other provider's fits.
  defp subscription_stops do
    SettingsFit.put_test_check(fn
      %{name: "claude-subscription"}, _settings -> :unchecked
      _entry, _settings -> :fit
    end)

    SettingsFit.clear()
  end

  defp waiting?(%DispatchRun{id: id} = queued) do
    %DispatchRun{state: state, end_cause: cause, model_provider_ids: ids} =
      Repo.get!(DispatchRun, id)

    state == :waiting and cause == nil and ids == queued.model_provider_ids and
      Repo.aggregate(from(d in Dispatch, where: d.dispatch_run_id == ^id), :count) == 0
  end

  defp skips(log), do: log |> String.split(@skipped) |> length() |> Kernel.-(1)

  test "a claim skips the run and takes the next of the workspace", _ctx do
    %{scope: scope} = sign_up_fixture()
    place = handover_place_fixture(scope, allow_secrets: true)
    provider = chosen!(scope, 1)
    first = queued!(scope)

    # The second run's target chooses an API provider, whose check fits.
    target = target!(scope, "acme/site")
    {:ok, good} = Connections.create_provider(scope, %{provider: "anthropic", keys: [@api_key]})
    {:ok, _choice} = ModelChoices.put_choice(scope, target, %{provider: good.public_id})
    second = queued!(scope, %{target_system: target.system, target_path: target.path})
    subscription_stops()

    {answer, log} = with_log(fn -> walked_claim(place.key, Dispatches.now(), @body) end)
    assert {:ok, %{run: %DispatchRun{id: taken}}} = answer
    assert taken == second.id
    assert waiting?(first)

    assert skips(log) == 1
    assert log =~ "#{@skipped} #{first.run_id}"
    assert log =~ "model provider #{provider.public_id} (claude-subscription)"
    assert log =~ "reason=provider_unchecked"
    refute log =~ "sk-ant-"

    # The check passes: the next claim takes the run it skipped.
    SettingsFit.put_test_check(fn _entry, _settings -> :fit end)
    {answer, log} = with_log(fn -> walked_claim(place.key, Dispatches.now(), @body) end)
    assert {:ok, %{run: %DispatchRun{id: taken}}} = answer
    assert taken == first.id
    assert skips(log) == 0
  end

  test "a claim with no other run takes none, and the run waits", _ctx do
    %{scope: scope} = sign_up_fixture()
    place = handover_place_fixture(scope, allow_secrets: true)
    _provider = chosen!(scope, 1)
    only = queued!(scope)
    stops_first(2)

    for _claim <- 1..2 do
      {answer, log} = with_log(fn -> walked_claim(place.key, Dispatches.now(), @body) end)
      assert answer == {:ok, :none}
      assert skips(log) == 1
      assert waiting?(only)
    end

    assert {:ok, %{run: %DispatchRun{id: taken}}} =
             walked_claim(place.key, Dispatches.now(), @body)

    assert taken == only.id
  end

  test "a claim checks a stopping provider once for all the runs that need it", _ctx do
    gateway = instance_gateway_fixture()
    installed_key_fixture(gateway, allow_secrets: true)
    pool = instance_pool_fixture()
    %{access_key: key} = installed_key_fixture(pool)

    %{scope: a} = sign_up_fixture()
    %{scope: b} = sign_up_fixture()
    _stopping = chosen!(a, 1)
    _good = chosen!(b, 2, "anthropic")
    stopped = for _run <- 1..3, do: queued!(a)
    good = queued!(b)

    # The Claude subscription's check stops each time; the API provider's fits. Each
    # check of the first is counted.
    calls = :counters.new(1, [])

    SettingsFit.put_test_check(fn
      %{name: "claude-subscription"}, _settings ->
        :counters.add(calls, 1, 1)
        :unchecked

      _entry, _settings ->
        :fit
    end)

    SettingsFit.clear()

    {answer, log} = with_log(fn -> walked_claim(key, Dispatches.now(), @body) end)
    assert {:ok, %{run: %DispatchRun{id: taken}}} = answer
    assert taken == good.id
    assert :counters.get(calls, 1) == 1
    assert skips(log) == 3

    for run <- stopped do
      assert waiting?(run)
      assert log =~ "#{@skipped} #{run.run_id}"
    end

    # The next claim checks the provider again, once.
    {answer, log} = with_log(fn -> walked_claim(key, Dispatches.now(), @body) end)
    assert answer == {:ok, :none}
    assert :counters.get(calls, 1) == 2
    assert skips(log) == 3
  end

  test "the instance's pool skips the run and takes one of another workspace", _ctx do
    gateway = instance_gateway_fixture()
    installed_key_fixture(gateway, allow_secrets: true)
    pool = instance_pool_fixture()
    %{access_key: key} = installed_key_fixture(pool)

    %{scope: a} = sign_up_fixture()
    %{scope: b} = sign_up_fixture()
    _provider_a = chosen!(a, 1)
    _provider_b = chosen!(b, 2)
    first = queued!(a)
    other = queued!(b)
    stops_first(1)

    {answer, log} = with_log(fn -> walked_claim(key, Dispatches.now(), @body) end)
    assert {:ok, %{run: %DispatchRun{id: taken}}} = answer
    assert taken == other.id
    assert waiting?(first)
    assert skips(log) == 1

    assert {:ok, %{run: %DispatchRun{id: taken}}} = walked_claim(key, Dispatches.now(), @body)
    assert taken == first.id
  end
end
