defmodule Apiary.ModelKeysTest do
  # The settings and the states of model keys (`Apiary.ModelKeys`): a key's weekly reset
  # and Pause for, the default Pause for of its provider, the next reset of its schedule,
  # a daylight-saving week included, and the states the gateways of runs report, the
  # newest by `observed_at` kept. Not async: one test switches the features, which are
  # the whole node's.
  use Apiary.DataCase, async: false

  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, ModelKeys}
  alias Apiary.Connections.Connection
  alias Apiary.ModelKeys.{Copy, Order, Report, Setting, State}
  alias Apiary.Runs.Run
  alias Apiary.Secrets.Value

  @moduletag needs: [:factory, :secrets]

  setup do
    %{scope: scope} = sign_up_fixture()
    {provider, values} = provider!(scope, ["main", "spare"])
    %{scope: scope, provider: provider, values: values}
  end

  # A provider of the scope's organisation with a key for each value id, and its values
  # by value id.
  defp provider!(scope, value_ids) do
    keys = for id <- value_ids, do: %{value_id: id, value: "sk-ant-fixture-#{id}-0123456789"}
    {:ok, provider} = Connections.create_provider(scope, %{provider: "anthropic", keys: keys})
    values = Repo.all(from v in Value, where: v.secret_id == ^provider.secret_id)
    {provider, Map.new(values, &{&1.value_id, &1})}
  end

  # A key of a run that has its value.
  defp key(%Value{} = value, name \\ "model-1"),
    do: %{
      name: name,
      secret_value_id: value.id,
      organisation_id: value.organisation_id,
      copy_set_at: value.value_set_at,
      copy_kept: true
    }

  defp item(attrs) do
    Map.merge(
      %{
        credential: "model-1",
        window: "five_hour",
        status: "allowed",
        resets_at: nil,
        utilization: nil,
        cooldown_until: nil,
        source: "provider",
        observed_at: ~U[2026-11-10 12:00:00.000000Z]
      },
      Map.new(attrs)
    )
  end

  # The key `value_id` of the provider of `ctx` as a claim at `at` reads it.
  defp claim_key(ctx, value_id, at) do
    ctx.provider |> ModelKeys.claim_keys(nil, at) |> Enum.find(&(&1.value_id == value_id))
  end

  defp states(%Value{id: id}),
    do: Repo.all(from s in State, where: s.secret_value_id == ^id, order_by: s.window)

  # A run of the scope's queue, handed over to a gateway, with the key `value` of the
  # provider of `ctx`.
  defp keys_run(ctx, %Value{id: id}) do
    pool = Apiary.NodesFixtures.pool_fixture(ctx.scope)
    %{access_key: key} = Apiary.AccessKeysFixtures.enrolled_key_fixture(ctx.scope, pool)

    %{run: run} =
      Apiary.DispatchedRunsFixtures.handed_over_fixture(ctx.scope, key, %{
        provider_connection_id: ctx.provider.id,
        provider_secret_id: ctx.provider.secret_id,
        provider_chain: "organisation",
        provider_api: %{
          "format" => "anthropic-messages",
          "endpoint" => "https://api.model.example/anthropic",
          "auth" => %{"scheme" => "x-api-key"}
        },
        model_keys: [%{"id" => id, "name" => "model-1", "pause_for_s" => 60}],
        run_settings: %{}
      })

    run
  end

  # Keeps the value the key `value` has now as the run's, as a secrets request that
  # sealed it does.
  defp seal(run, %Value{id: id}) do
    {:ok, _plaintext, value_set_at} =
      Apiary.Secrets.reveal_key_and_set_at(Repo.get!(Connection, run.provider_connection_id), id)

    ModelKeys.keep_copies(run.id, [{id, value_set_at}])
  end

  # A new value of the key `spare` of the provider of `ctx`, as Edit key saves it.
  defp set_value!(ctx, value) do
    {:ok, _provider} = Connections.set_provider_key(ctx.scope, ctx.provider, "spare", value, nil)
  end

  describe "the settings" do
    test "are saved at the key's organisation, by the value's row id", ctx do
      value = ctx.values["main"]

      assert {:ok, setting} =
               put_key_setting(ctx.scope, value, %{
                 "reset_weekday" => 1,
                 "reset_time" => "09:00:00",
                 "reset_time_zone" => "Europe/Berlin",
                 "pause_seconds" => 600,
                 "organisation_id" => Ecto.UUID.generate()
               })

      assert setting.secret_value_id == value.id
      assert setting.organisation_id == ctx.scope.organisation.id
      assert ModelKeys.setting(value.id).pause_seconds == 600

      # A second save changes the row; an empty field clears its setting.
      assert {:ok, _} = put_key_setting(ctx.scope, value, %{"pause_seconds" => ""})
      assert %Setting{pause_seconds: nil, reset_weekday: 1} = ModelKeys.setting(value.id)
      assert Repo.aggregate(Setting, :count) == 1
      assert ModelKeys.setting(ctx.values["spare"].id) == nil
    end

    test "refuse a weekday, a time zone or a Pause for out of range" do
      for {attrs, field} <- [
            {%{reset_weekday: 0, reset_time: ~T[09:00:00], reset_time_zone: "Etc/UTC"},
             :reset_weekday},
            {%{reset_weekday: 8, reset_time: ~T[09:00:00], reset_time_zone: "Etc/UTC"},
             :reset_weekday},
            {%{reset_weekday: 1, reset_time: ~T[09:00:00], reset_time_zone: "Mars/Olympus"},
             :reset_time_zone},
            {%{pause_seconds: 0}, :pause_seconds},
            {%{pause_seconds: 604_801}, :pause_seconds}
          ] do
        changeset = Setting.changeset(%Setting{}, attrs)
        refute changeset.valid?, inspect(attrs)
        assert Map.has_key?(errors_on(changeset), field), inspect(attrs)
      end

      assert Setting.changeset(%Setting{}, %{pause_seconds: 1}).valid?
      assert Setting.changeset(%Setting{}, %{pause_seconds: 604_800}).valid?
    end

    test "take a reset whole: a weekday alone leaves the time and the zone blank" do
      changeset = Setting.changeset(%Setting{}, %{reset_weekday: 3})

      assert errors_on(changeset) == %{
               reset_time: ["can't be blank"],
               reset_time_zone: ["can't be blank"]
             }

      assert Setting.changeset(%Setting{}, %{}).valid?
    end
  end

  describe "the Pause for" do
    test "is the key's setting, else 60 s for an API key and 3600 s for a subscription",
         ctx do
      assert ModelKeys.default_pause_seconds(ctx.provider) == 60
      assert ModelKeys.pause_seconds(ctx.provider, nil) == 60
      assert ModelKeys.pause_seconds(ctx.provider, %Setting{pause_seconds: 5}) == 5

      subscription = %Connection{provider_kind: "claude-subscription"}
      assert ModelKeys.default_pause_seconds(subscription) == 3600
      assert ModelKeys.pause_seconds(subscription, %Setting{}) == 3600

      assert ModelKeys.default_pause_seconds(%Connection{provider_kind: "gone"}) == 60
    end
  end

  describe "the next scheduled reset" do
    defp weekly(day, time, zone),
      do: %Setting{reset_weekday: day, reset_time: time, reset_time_zone: zone}

    test "is the next weekday and time in the zone, strictly after the time" do
      monday = weekly(1, ~T[09:00:00], "Europe/Berlin")

      # Wednesday 2026-11-11: the Monday after, at 09:00 CET.
      assert ModelKeys.next_reset(monday, ~U[2026-11-11 10:00:00Z]) ==
               ~U[2026-11-16 08:00:00.000000Z]

      # At the reset itself, the one a week later.
      assert ModelKeys.next_reset(monday, ~U[2026-11-16 08:00:00Z]) ==
               ~U[2026-11-23 08:00:00.000000Z]

      # The same Monday, before the reset.
      assert ModelKeys.next_reset(monday, ~U[2026-11-16 07:59:59Z]) ==
               ~U[2026-11-16 08:00:00.000000Z]

      assert ModelKeys.next_reset(nil, ~U[2026-11-11 10:00:00Z]) == nil
      assert ModelKeys.next_reset(%Setting{pause_seconds: 60}, ~U[2026-11-11 10:00:00Z]) == nil
    end

    test "of a zone the time zone database no longer has is in UTC, with one log line" do
      # Setting.changeset/2 accepts only a known zone: a zone written before a database
      # update that dropped it.
      gone = %{weekly(1, ~T[09:00:00], "Europe/Nowhere") | secret_value_id: Ecto.UUID.generate()}

      # Two reads of the key log one line.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ModelKeys.next_reset(gone, ~U[2026-11-11 10:00:00Z]) ==
                   ~U[2026-11-16 09:00:00.000000Z]

          assert ModelKeys.next_reset(gone, ~U[2026-11-17 10:00:00Z]) ==
                   ~U[2026-11-23 09:00:00.000000Z]
        end)

      assert [_one] = Regex.scan(~r/reset time zone is not in the time zone database/, log)
      assert log =~ gone.secret_value_id

      # Another key with that zone logs one line too.
      other = %{gone | secret_value_id: Ecto.UUID.generate()}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          ModelKeys.next_reset(other, ~U[2026-11-11 10:00:00Z])
        end)

      assert [_one] = Regex.scan(~r/reset time zone is not in the time zone database/, log)
      assert log =~ other.secret_value_id
    end

    test "follows the zone's clock across a daylight-saving week" do
      monday = weekly(1, ~T[09:00:00], "Europe/Berlin")

      # Berlin moves to summer time on Sunday 2026-03-29: 09:00 is 08:00 UTC the Monday
      # before, and 07:00 UTC the Monday after.
      assert ModelKeys.next_reset(monday, ~U[2026-03-20 12:00:00Z]) ==
               ~U[2026-03-23 08:00:00.000000Z]

      assert ModelKeys.next_reset(monday, ~U[2026-03-28 12:00:00Z]) ==
               ~U[2026-03-30 07:00:00.000000Z]

      # 02:30 that Sunday does not exist: the first moment after the gap, 03:00 CEST.
      sunday = weekly(7, ~T[02:30:00], "Europe/Berlin")

      assert ModelKeys.next_reset(sunday, ~U[2026-03-28 12:00:00Z]) ==
               ~U[2026-03-29 01:00:00.000000Z]

      # 02:30 on Sunday 2026-10-25 happens twice: the first, 02:30 CEST.
      assert ModelKeys.next_reset(sunday, ~U[2026-10-24 12:00:00Z]) ==
               ~U[2026-10-25 00:30:00.000000Z]
    end
  end

  describe "a run's keys" do
    test "are the keys the run keeps, in its order, by their credential names", ctx do
      stored = [
        %{"id" => ctx.values["spare"].id, "name" => "model-1", "pause_for_s" => 60},
        %{"id" => ctx.values["main"].id, "name" => "model-2", "pause_for_s" => 60}
      ]

      run = %Run{
        provider_api: %{"format" => "anthropic-messages"},
        provider_connection_id: ctx.provider.id,
        provider_secret_id: ctx.provider.secret_id,
        model_keys: stored
      }

      assert ModelKeys.run_keys(run) == [
               %{
                 name: "model-1",
                 secret_value_id: ctx.values["spare"].id,
                 organisation_id: ctx.scope.organisation.id,
                 copy_set_at: nil,
                 copy_kept: false
               },
               %{
                 name: "model-2",
                 secret_value_id: ctx.values["main"].id,
                 organisation_id: ctx.scope.organisation.id,
                 copy_set_at: nil,
                 copy_kept: false
               }
             ]

      # A key renamed since the claim stays a key of the run, by its row id.
      {1, _rows} =
        Repo.update_all(from(v in Value, where: v.id == ^ctx.values["spare"].id),
          set: [value_id: "renamed"]
        )

      assert [%{name: "model-1"}, %{name: "model-2"}] = ModelKeys.run_keys(run)

      # A key of another secret is not a key of the run, nor are the keys of a run with
      # none, of a provider of another secret, or with no provider.
      {other, other_values} = provider!(ctx.scope, ["spare"])

      assert ModelKeys.run_keys(%{
               run
               | model_keys: [%{"id" => other_values["spare"].id, "name" => "model-1"}]
             }) == []

      assert ModelKeys.run_keys(%{run | model_keys: []}) == []

      assert ModelKeys.run_keys(%{run | provider_connection_id: other.id}) == []
      assert ModelKeys.run_keys(%{run | provider_api: nil}) == []
      assert ModelKeys.run_keys(%Run{}) == []
    end

    test "are none where model keys do not apply", ctx do
      # The provider was added with every feature on; the instance runs without
      # `factory` and `secrets` from here, until the test ends.
      Apiary.DataCase.setup_features(%{with_features: [:observability, :security]})

      run = %Run{
        provider_api: %{"format" => "anthropic-messages"},
        provider_connection_id: ctx.provider.id,
        provider_secret_id: ctx.provider.secret_id,
        model_keys: [%{"id" => ctx.values["main"].id, "name" => "model-1"}]
      }

      assert ModelKeys.run_keys(run) == []

      # And a report is answered as for a run the server does not know.
      assert Report.answer(
               %Apiary.AccessKeys.AccessKey{},
               Ecto.UUID.generate(),
               %{time: DateTime.utc_now(), keys: []},
               nil,
               DateTime.utc_now()
             ) == {:error, :not_found}
    end
  end

  describe "the keys at a claim" do
    # A state of `value` in `window`, written as a report writes one.
    defp state!(%Value{} = value, window, attrs) do
      ModelKeys.record(
        [key(value)],
        [item(Keyword.merge([window: window, observed_at: DateTime.utc_now()], attrs))],
        DateTime.utc_now()
      )
    end

    # Whether a claim at `now` may take a run of the queue with the providers `ids`, as
    # the claim's filter reads it.
    defp claimable?(ids, now) do
      Repo.one(
        from r in fragment(
               "SELECT ?::uuid[] AS model_provider_ids",
               type(^ids, {:array, Ecto.UUID})
             ),
             as: :run,
             where: ^ModelKeys.claimable(now),
             select: true
      ) == true
    end

    test "have their resets, schedule, cooldown, Pause for and whether they are named", ctx do
      now = ~U[2026-11-10 12:00:00.000000Z]
      main = ctx.values["main"]
      spare = ctx.values["spare"]

      state!(main, "five_hour", resets_at: ~U[2026-11-10 14:00:00Z])
      state!(main, "seven_day", resets_at: ~U[2026-11-09 14:00:00Z])

      state!(spare, "five_hour",
        status: "rejected",
        resets_at: ~U[2026-11-10 13:00:00Z],
        cooldown_until: ~U[2026-11-10 13:00:00Z]
      )

      {:ok, _setting} =
        put_key_setting(ctx.scope, spare, %{
          reset_weekday: 1,
          reset_time: ~T[09:00:00],
          reset_time_zone: "Etc/UTC",
          pause_seconds: 120
        })

      keys = ctx.provider |> ModelKeys.claim_keys("spare", now) |> Map.new(&{&1.value_id, &1})

      assert %{
               id: main_id,
               named: false,
               default: true,
               resets_at: ~U[2026-11-10 14:00:00.000000Z],
               schedule_resets_at: nil,
               known_reset: ~U[2026-11-10 14:00:00.000000Z],
               cooldown_until: nil,
               pause_seconds: 60
             } = keys["main"]

      assert main_id == main.id

      assert %{
               named: true,
               default: false,
               resets_at: ~U[2026-11-10 13:00:00.000000Z],
               schedule_resets_at: ~U[2026-11-16 09:00:00.000000Z],
               cooldown_until: ~U[2026-11-10 13:00:00.000000Z],
               pause_seconds: 120
             } = keys["spare"]
    end

    test "a run of the queue waits while every key of each of its providers is in cooldown",
         ctx do
      now = DateTime.utc_now()
      later = DateTime.add(now, 3600)
      {fallback, fallback_values} = provider!(ctx.scope, ["only"])

      # None in cooldown, and a run with no providers: claimable.
      assert claimable?([ctx.provider.id, fallback.id], now)
      assert claimable?([], now)

      # One key of the first provider in cooldown: the other is free.
      state!(ctx.values["main"], "five_hour", status: "rejected", cooldown_until: later)
      assert claimable?([ctx.provider.id], now)
      assert ModelKeys.cooling_until([ctx.provider.id], now) == nil

      # Both keys of the first provider in cooldown: the fallback's key is free.
      state!(ctx.values["spare"], "seven_day",
        status: "rejected",
        cooldown_until: DateTime.add(now, 600)
      )

      refute claimable?([ctx.provider.id], now)
      assert claimable?([ctx.provider.id, fallback.id], now)

      assert ModelKeys.cooling_until([ctx.provider.id], now) ==
               DateTime.truncate(DateTime.add(now, 600), :microsecond)

      # Every key of both in cooldown: the run waits until the first key's end.
      state!(fallback_values["only"], "five_hour",
        status: "rejected",
        cooldown_until: DateTime.add(now, 1200)
      )

      refute claimable?([ctx.provider.id, fallback.id], now)

      assert ModelKeys.cooling_until([ctx.provider.id, fallback.id], now) ==
               DateTime.truncate(DateTime.add(now, 600), :microsecond)

      # At the end of a cooldown the key is free again; a provider that is gone does not
      # count as cooling.
      assert claimable?([ctx.provider.id, fallback.id], DateTime.add(now, 600))
      assert claimable?([ctx.provider.id, Ecto.UUID.generate()], now)
      assert ModelKeys.cooling_until([ctx.provider.id, Ecto.UUID.generate()], now) == nil
    end
  end

  describe "the states" do
    test "keep the newest report by observed_at: an older one never overwrites", ctx do
      value = ctx.values["main"]
      keys = [key(value)]
      now = DateTime.utc_now()

      newer =
        item(
          status: "rejected",
          utilization: 100,
          resets_at: ~U[2026-11-10 14:00:00.000000Z],
          cooldown_until: ~U[2026-11-10 14:00:00.000000Z],
          observed_at: ~U[2026-11-10 12:00:04.000000Z]
        )

      :ok = ModelKeys.record(keys, [newer], now)

      assert [%State{status: "rejected", utilization: 100, organisation_id: org}] =
               states(value)

      assert org == ctx.scope.organisation.id

      # An older report of the same window, from any gateway, leaves the row.
      older = item(status: "allowed", utilization: 40, observed_at: ~U[2026-11-10 12:00:01Z])
      :ok = ModelKeys.record(keys, [older], now)
      assert [%State{status: "rejected", utilization: 100}] = states(value)

      # The same time again is not newer either.
      :ok = ModelKeys.record(keys, [%{older | observed_at: newer.observed_at}], now)
      assert [%State{status: "rejected"}] = states(value)

      # A newer one replaces it, the members it leaves out cleared.
      latest = item(status: "allowed", observed_at: ~U[2026-11-10 14:00:02.000000Z])
      :ok = ModelKeys.record(keys, [latest], now)

      assert [
               %State{
                 status: "allowed",
                 utilization: nil,
                 cooldown_until: nil,
                 resets_at: nil,
                 observed_at: ~U[2026-11-10 14:00:02.000000Z]
               }
             ] = states(value)
    end

    test "of one window twice in a report keep the newer, and other credentials none",
         ctx do
      value = ctx.values["main"]

      :ok =
        ModelKeys.record(
          [key(value)],
          [
            item(utilization: 70, observed_at: ~U[2026-11-10 12:00:03Z]),
            item(utilization: 80, observed_at: ~U[2026-11-10 12:00:05Z]),
            item(utilization: 60, observed_at: ~U[2026-11-10 12:00:04Z]),
            item(window: "seven_day", utilization: 20),
            item(credential: "model-2", window: "requests")
          ],
          DateTime.utc_now()
        )

      assert [%State{window: "five_hour", utilization: 80}, %State{window: "seven_day"}] =
               states(value)

      assert Repo.aggregate(State, :count) == 2
    end

    test "are kept for the contract's windows alone: another is left out, the rest kept",
         ctx do
      value = ctx.values["main"]

      :ok =
        ModelKeys.record(
          [key(value)],
          [item(window: "five_hour"), item(window: "seven_day_haiku"), item(window: "key")],
          DateTime.utc_now()
        )

      assert Enum.map(states(value), & &1.window) == ["five_hour", "key"]
      assert length(State.windows()) == 11
    end

    test "of a run are at most 66: 6 keys of 11 windows", ctx do
      {_provider, values} = provider!(ctx.scope, ~w(k1 k2 k3 k4 k5 k6))
      keys = for {id, value} <- values, do: key(value, id)
      now = DateTime.utc_now()

      items =
        for name <- Map.keys(values),
            window <- State.windows() ++ ["seven_day_haiku"],
            do: item(credential: name, window: window)

      :ok = ModelKeys.record(keys, items, now)
      assert Repo.aggregate(State, :count) == 66

      # A row of another window, written by an earlier release, is not read.
      value = values["k1"]

      Repo.insert_all(State, [
        %{
          secret_value_id: value.id,
          organisation_id: value.organisation_id,
          window: "seven_day_haiku",
          status: "allowed",
          source: "provider",
          observed_at: now,
          updated_at: now
        }
      ])

      states = ModelKeys.run_states(keys, now)
      assert length(states) == 6 * 11
      assert length(Jason.decode!(Report.body(states))["keys"]) == 66
    end

    test "leave out the utilization of a window whose reset has passed", ctx do
      value = ctx.values["main"]
      now = ~U[2026-11-10 15:00:00.000000Z]

      :ok =
        ModelKeys.record(
          [key(value)],
          [
            item(utilization: 88, resets_at: ~U[2026-11-10 14:00:00Z]),
            item(window: "seven_day", utilization: 40, resets_at: ~U[2026-11-16 09:00:00Z])
          ],
          now
        )

      assert [{"model-1", five}, {"model-1", seven}] = ModelKeys.run_states([key(value)], now)
      assert {five.window, five.utilization} == {"five_hour", nil}
      assert {seven.window, seven.utilization} == {"seven_day", 40}

      assert %{} = by_key = ModelKeys.provider_states(ctx.provider, now)
      assert [%State{utilization: nil}, %State{utilization: 40}] = by_key[value.id]

      # Before the reset, the utilization reads.
      assert [{_, %State{utilization: 88}}, _] =
               ModelKeys.run_states([key(value)], ~U[2026-11-10 13:00:00Z])
    end

    test "of a provider are its keys' states, by key", ctx do
      %{"main" => main, "spare" => spare} = ctx.values
      {other, %{"spare" => elsewhere}} = provider!(ctx.scope, ["spare"])
      now = DateTime.utc_now()

      :ok =
        ModelKeys.record(
          [key(main, "a"), key(spare, "b")],
          [item(credential: "a"), item(credential: "b", window: "seven_day")],
          now
        )

      :ok = ModelKeys.record([key(elsewhere)], [item([])], now)

      by_key = ModelKeys.provider_states(ctx.provider, now)
      assert Map.keys(by_key) |> Enum.sort() == Enum.sort([main.id, spare.id])
      assert [%State{window: "seven_day"}] = by_key[spare.id]
      assert Map.keys(ModelKeys.provider_states(other, now)) == [elsewhere.id]
    end

    test "give a key's known reset at a claim: the earliest future reset, else its schedule",
         ctx do
      value = ctx.values["main"]
      now = ~U[2026-11-10 15:00:00.000000Z]
      known_reset = fn at -> claim_key(ctx, "main", at).known_reset end

      assert known_reset.(now) == nil

      {:ok, _} =
        put_key_setting(ctx.scope, value, %{
          reset_weekday: 1,
          reset_time: ~T[09:00:00],
          reset_time_zone: "Europe/Berlin"
        })

      assert known_reset.(now) == ~U[2026-11-16 08:00:00.000000Z]

      :ok =
        ModelKeys.record(
          [key(value)],
          [
            item(window: "five_hour", resets_at: ~U[2026-11-10 14:00:00Z]),
            item(window: "seven_day", resets_at: ~U[2026-11-14 09:00:00Z]),
            item(window: "requests", resets_at: ~U[2026-11-10 15:01:00Z])
          ],
          now
        )

      # The five-hour window's reset has passed: the request window's is the earliest.
      assert known_reset.(now) == ~U[2026-11-10 15:01:00.000000Z]
      assert known_reset.(~U[2026-11-10 15:01:00.000000Z]) == ~U[2026-11-14 09:00:00.000000Z]
    end

    test "give a key's cooldown at a claim, until its latest cooldown", ctx do
      value = ctx.values["main"]
      cooling? = fn value_id, at -> Order.cooling?(claim_key(ctx, value_id, at), at) end
      refute cooling?.("main", ~U[2026-11-10 13:00:00.000000Z])
      assert claim_key(ctx, "main", ~U[2026-11-10 13:00:00.000000Z]).cooldown_until == nil

      :ok =
        ModelKeys.record(
          [key(value)],
          [
            item(
              window: "five_hour",
              status: "rejected",
              cooldown_until: ~U[2026-11-10 14:00:00Z]
            ),
            item(window: "seven_day")
          ],
          DateTime.utc_now()
        )

      assert claim_key(ctx, "main", ~U[2026-11-10 13:00:00.000000Z]).cooldown_until ==
               ~U[2026-11-10 14:00:00.000000Z]

      assert cooling?.("main", ~U[2026-11-10 13:59:59.000000Z])
      refute cooling?.("main", ~U[2026-11-10 14:00:00.000000Z])
      refute cooling?.("spare", ~U[2026-11-10 13:00:00.000000Z])

      # The 7-day window rejected too, until a later reset: the key stays in cooldown
      # until then, past the 5-hour window's end.
      :ok =
        ModelKeys.record(
          [key(value)],
          [
            item(
              window: "seven_day",
              status: "rejected",
              cooldown_until: ~U[2026-11-14 09:00:00Z],
              observed_at: ~U[2026-11-10 12:00:10Z]
            )
          ],
          DateTime.utc_now()
        )

      assert claim_key(ctx, "main", ~U[2026-11-10 14:00:00.000000Z]).cooldown_until ==
               ~U[2026-11-14 09:00:00.000000Z]

      assert cooling?.("main", ~U[2026-11-10 14:00:00.000000Z])
      refute cooling?.("main", ~U[2026-11-14 09:00:00.000000Z])
    end

    test "end at their cooldown_until: a key whose cooldown ends now is free for each reader",
         ctx do
      %{provider: provider, values: values} = ctx
      until = ~U[2026-11-10 14:00:00.000000Z]
      before = DateTime.add(until, -1, :microsecond)

      for value <- Map.values(values) do
        :ok =
          ModelKeys.record(
            [key(value)],
            [item(window: "five_hour", status: "rejected", cooldown_until: until)],
            DateTime.utc_now()
          )
      end

      states = fn at ->
        provider |> ModelKeys.provider_states(at) |> Map.fetch!(values["main"].id)
      end

      # A microsecond before the end, every reader has the keys in cooldown.
      assert Order.cooling?(claim_key(ctx, "main", before), before)
      assert ModelKeys.cooldown_counts([provider], before) == %{provider.id => 2}
      assert ModelKeys.cooling_until([provider.id], before) == until
      refute ModelKeys.claim_keys(provider, nil, before) |> Order.start(before)

      assert {:cooldown, _words, _source} =
               ApiaryWeb.ModelKeyComponents.state(states.(before), before)

      # At the end itself, none has.
      refute Order.cooling?(claim_key(ctx, "main", until), until)
      assert ModelKeys.cooldown_counts([provider], until) == %{provider.id => 0}
      assert ModelKeys.cooling_until([provider.id], until) == nil
      assert ModelKeys.claim_keys(provider, nil, until) |> Order.start(until)
      assert {:available, _segments} = ApiaryWeb.ModelKeyComponents.state(states.(until), until)
    end

    test "count the keys in cooldown of each provider, as a claim reads them", ctx do
      %{scope: scope, provider: provider, values: values} = ctx
      {other, other_values} = provider!(scope, ["first", "second"])
      at = ~U[2026-11-10 13:00:00.000000Z]

      assert ModelKeys.cooldown_counts([provider, other], at) == %{
               provider.id => 0,
               other.id => 0
             }

      rejected = fn value, window, until ->
        :ok =
          ModelKeys.record(
            [key(value)],
            [item(window: window, status: "rejected", cooldown_until: until)],
            DateTime.utc_now()
          )
      end

      rejected.(values["main"], "five_hour", ~U[2026-11-10 14:00:00Z])
      rejected.(values["main"], "seven_day", ~U[2026-11-14 09:00:00Z])
      rejected.(values["spare"], "five_hour", ~U[2026-11-10 12:00:00Z])
      rejected.(other_values["second"], "requests", ~U[2026-11-10 13:00:01Z])

      counts = ModelKeys.cooldown_counts([provider, other], at)
      assert counts == %{provider.id => 1, other.id => 1}

      for p <- [provider, other] do
        cooling = p |> ModelKeys.claim_keys(nil, at) |> Enum.count(&Order.cooling?(&1, at))
        assert counts[p.id] == cooling
      end

      assert ModelKeys.cooldown_counts([], at) == %{}
    end

    test "and the settings go with their key", ctx do
      value = ctx.values["main"]
      {:ok, _} = put_key_setting(ctx.scope, value, %{pause_seconds: 90})
      :ok = ModelKeys.record([key(value)], [item([])], DateTime.utc_now())

      Repo.delete!(value)
      assert Repo.aggregate(State, :count) == 0
      assert Repo.aggregate(Setting, :count) == 0
    end

    test "of a key whose value changed leave out a report of a run with the old value",
         ctx do
      value = ctx.values["spare"]
      run = keys_run(ctx, value)
      until = in_seconds(3_600)

      # A cooldown observed after the change, as a run hits the limit on its old value.
      report = fn ->
        rejected =
          item(
            status: "rejected",
            resets_at: until,
            cooldown_until: until,
            observed_at: in_seconds(1)
          )

        ModelKeys.record(ModelKeys.run_keys(run), [rejected], DateTime.utc_now())
      end

      # The run's secrets request sealed the value it has; then the value changes.
      :ok = seal(run, value)
      set_value!(ctx, "sk-ant-fixture-new-0123456789")

      :ok = report.()
      assert states(value) == []

      # At its next secrets request the run gets the new value: its report is of it.
      :ok = seal(run, value)
      :ok = report.()
      assert [%State{status: "rejected", cooldown_until: cooldown_until}] = states(value)
      assert DateTime.compare(cooldown_until, until) == :eq
    end

    test "of a key whose value Edit key changed leave out a report of a run with the old value",
         ctx do
      value = ctx.values["spare"]
      run = keys_run(ctx, value)
      :ok = seal(run, value)

      {:ok, _provider} =
        Connections.update_provider_key(ctx.scope, ctx.provider, "spare", %{
          "value_id" => "spare",
          "value" => "sk-ant-fixture-new-0123456789"
        })

      until = in_seconds(3_600)

      report = fn ->
        rejected =
          item(
            status: "rejected",
            resets_at: until,
            cooldown_until: until,
            observed_at: in_seconds(1)
          )

        ModelKeys.record(ModelKeys.run_keys(run), [rejected], DateTime.utc_now())
      end

      :ok = report.()
      assert states(value) == []

      # The same report of a run with the new value is recorded.
      :ok = seal(run, value)
      :ok = report.()
      assert [%State{status: "rejected"}] = states(value)
    end

    test "of a key whose new value was set before the run's copy by its clock leave out the report",
         ctx do
      value = ctx.values["spare"]
      run = keys_run(ctx, value)
      :ok = seal(run, value)
      [%Copy{value_set_at: copy_set_at}] = Repo.all(from c in Copy, where: c.run_id == ^run.id)

      # A new value set by a server whose clock runs a second behind the one that kept the
      # copy: its `value_set_at` is before the copy's, and differs from it.
      {1, _rows} =
        Repo.update_all(from(v in Value, where: v.id == ^value.id),
          set: [value_set_at: DateTime.add(copy_set_at, -1, :second)]
        )

      :ok = ModelKeys.record(ModelKeys.run_keys(run), [item([])], DateTime.utc_now())
      assert states(value) == []
    end

    test "of a run no secrets request sealed the key for leave out a value set since the run",
         ctx do
      value = ctx.values["spare"]
      run = keys_run(ctx, value)
      set_value!(ctx, "sk-ant-fixture-new-0123456789")

      :ok = ModelKeys.record(ModelKeys.run_keys(run), [item([])], DateTime.utc_now())
      assert states(value) == []
    end

    test "of a key renamed since the run got its value are kept", ctx do
      value = ctx.values["spare"]
      run = keys_run(ctx, value)
      :ok = seal(run, value)

      {:ok, _provider} =
        Connections.rename_provider_key(ctx.scope, ctx.provider, "spare", "renamed")

      :ok = ModelKeys.record(ModelKeys.run_keys(run), [item([])], DateTime.utc_now())
      assert [%State{status: "allowed"}] = states(value)
    end

    test "belong to the key's organisation alone", ctx do
      value = ctx.values["main"]
      %{scope: other} = sign_up_fixture()

      # A row of another organisation for this key is refused by the database.
      assert_raise Postgrex.Error, ~r/model_key_states/, fn ->
        ModelKeys.record(
          [%{key(value) | organisation_id: other.organisation.id}],
          [item([])],
          DateTime.utc_now()
        )
      end
    end
  end
end
