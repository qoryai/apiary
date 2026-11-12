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
  import Apiary.ModelKeysFixtures, only: [key_state!: 3, in_seconds: 1]
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
    provider = provider!(scope, n, kind)

    {:ok, _choice} =
      ModelChoices.put_choice(scope, :workspace, %{provider: provider.public_id})

    provider
  end

  # A model provider of `kind` of the scope's organisation, chosen for no run.
  defp provider!(scope, n, kind \\ "claude-subscription") do
    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: kind,
        keys: [%{value_id: "main", value: "sk-ant-oat01-skip-#{n}-0123456789"}]
      })

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

  # The Claude subscription's check stops each time, and any other provider's fits.
  # Returns the counter of the subscription's checks.
  defp subscription_stops do
    calls = :counters.new(1, [])

    SettingsFit.put_test_check(fn
      %{name: "claude-subscription"}, _settings ->
        :counters.add(calls, 1, 1)
        :unchecked

      _entry, _settings ->
        :fit
    end)

    SettingsFit.clear()
    calls
  end

  # Whether the run of the queue `queued` waits as it was queued: no end, its
  # `model_provider_ids` and its `updated_at` as they were, and no dispatch.
  defp waiting?(%DispatchRun{id: id} = queued) do
    %DispatchRun{state: state, end_cause: cause, model_provider_ids: ids, updated_at: at} =
      Repo.get!(DispatchRun, id)

    state == :waiting and cause == nil and ids == queued.model_provider_ids and
      at == queued.updated_at and
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

  test "a claim checks a stopping provider once, and the next claim again", _ctx do
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

    calls = subscription_stops()

    {answer, log} = with_log(fn -> walked_claim(key, Dispatches.now(), @body) end)
    assert {:ok, %{run: %DispatchRun{id: taken}}} = answer
    assert taken == good.id
    assert :counters.get(calls, 1) == 1

    # The oldest run is skipped with a line in the log; the claim's query leaves out the
    # two others.
    assert skips(log) == 1
    assert log =~ "#{@skipped} #{hd(stopped).run_id}"
    assert Enum.all?(stopped, &waiting?/1)

    # The next claim checks the provider again, once.
    {answer, log} = with_log(fn -> walked_claim(key, Dispatches.now(), @body) end)
    assert answer == {:ok, :none}
    assert :counters.get(calls, 1) == 2
    assert skips(log) == 1
  end

  test "the claim's query leaves out the runs of a stopped provider", _ctx do
    gateway = instance_gateway_fixture()
    installed_key_fixture(gateway, allow_secrets: true)
    pool = instance_pool_fixture()
    %{access_key: key} = installed_key_fixture(pool)

    %{scope: a} = sign_up_fixture()
    %{scope: b} = sign_up_fixture()
    _stopping = chosen!(a, 1)
    _good = chosen!(b, 2, "anthropic")

    # 101 runs on the stopping provider, more than a claim's 100 tries, then one run on
    # the API provider.
    tickets = ticket_connection_fixture(a)

    stopped =
      for i <- 1..101,
          do: queued!(a, %{connection_id: tickets.id, external_ref: "acme/shop##{i}"})

    good = queued!(b)
    calls = subscription_stops()

    {answer, log} = with_log(fn -> walked_claim(key, Dispatches.now(), @body) end)
    assert {:ok, %{run: %DispatchRun{id: taken}}} = answer
    assert taken == good.id
    assert :counters.get(calls, 1) == 1
    assert skips(log) == 1
    assert Enum.all?(stopped, &waiting?/1)
  end

  test "a run whose fallback stops forms on its choice", _ctx do
    %{scope: scope} = sign_up_fixture()
    place = handover_place_fixture(scope, allow_secrets: true)
    {:ok, good} = Connections.create_provider(scope, %{provider: "anthropic", keys: [@api_key]})
    stopping = provider!(scope, 1)

    {:ok, _choice} =
      ModelChoices.put_choice(scope, :workspace, %{
        provider: good.public_id,
        fallbacks: [%{provider: stopping.public_id, model: nil, effort: nil}]
      })

    run = queued!(scope)
    calls = subscription_stops()

    {answer, log} = with_log(fn -> walked_claim(place.key, Dispatches.now(), @body) end)
    assert {:ok, %{run: %DispatchRun{id: taken}, registered: registered}} = answer
    assert taken == run.id
    assert registered.provider_connection_id == good.id
    assert :counters.get(calls, 1) == 1
    assert skips(log) == 0
  end

  test "a fallback known stopped is passed over without a check in the same claim", _ctx do
    %{scope: scope} = sign_up_fixture()
    place = handover_place_fixture(scope, allow_secrets: true)
    stopping = chosen!(scope, 1)
    first = queued!(scope)

    # The second run's target chooses an API provider, with the stopping one as its
    # fallback.
    target = target!(scope, "acme/site")
    {:ok, good} = Connections.create_provider(scope, %{provider: "anthropic", keys: [@api_key]})

    {:ok, _choice} =
      ModelChoices.put_choice(scope, target, %{
        provider: good.public_id,
        fallbacks: [%{provider: stopping.public_id, model: nil, effort: nil}]
      })

    second = queued!(scope, %{target_system: target.system, target_path: target.path})
    calls = subscription_stops()

    {answer, log} = with_log(fn -> walked_claim(place.key, Dispatches.now(), @body) end)
    assert {:ok, %{run: %DispatchRun{id: taken}}} = answer
    assert taken == second.id
    assert waiting?(first)
    assert :counters.get(calls, 1) == 1
    assert skips(log) == 1
  end

  test "a run waits for a stopped fallback too while every key of its choice cools down",
       _ctx do
    %{scope: scope} = sign_up_fixture()
    place = handover_place_fixture(scope, allow_secrets: true)

    {:ok, cooling} =
      Connections.create_provider(scope, %{provider: "anthropic", keys: [@api_key]})

    stopping = provider!(scope, 1)

    {:ok, _choice} =
      ModelChoices.put_choice(scope, :workspace, %{
        provider: cooling.public_id,
        fallbacks: [%{provider: stopping.public_id, model: nil, effort: nil}]
      })

    key_state!(cooling, "main", until: in_seconds(5 * 3600))
    run = queued!(scope)
    assert run.model_provider_ids == [cooling.id, stopping.id]
    calls = subscription_stops()

    {answer, log} = with_log(fn -> walked_claim(place.key, Dispatches.now(), @body) end)
    assert answer == {:ok, :none}
    assert :counters.get(calls, 1) == 1
    assert skips(log) == 0
    assert %DispatchRun{state: :waiting, model_provider_ids: ids} = Repo.get!(DispatchRun, run.id)
    assert ids == [cooling.id, stopping.id]

    # Once the fallback's check passes, a claim takes the run on the fallback.
    SettingsFit.put_test_check(fn _entry, _settings -> :fit end)
    SettingsFit.clear()

    assert {:ok, %{run: %DispatchRun{id: taken}, registered: registered}} =
             walked_claim(place.key, Dispatches.now(), @body)

    assert taken == run.id
    assert registered.provider_connection_id == stopping.id
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
