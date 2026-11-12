defmodule Apiary.ModelKeys.UseUpToTest do
  # A model key's Use up to percentage (`Apiary.ModelKeys`): only for a key of a provider
  # whose catalogue entry lists limit windows, 1 to 99; a key in cooldown while a listed
  # window's use is at or above it, until that window resets, at the claim, in the claim's
  # filter, in the first key to leave its cooldown and in the counts; the run's keys and
  # its run configuration with each key's percentage and the windows the run keeps once.
  use Apiary.DataCase, async: true

  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, ModelKeys}
  alias Apiary.ModelKeys.{Setting, State}
  alias Apiary.Runs.{ProviderCredential, Run}
  alias Apiary.Secrets.Value

  @moduletag needs: [:factory, :secrets]

  @subscription_api %{
    "format" => "anthropic-messages",
    "endpoint" => "https://api.anthropic.com",
    "auth" => %{"scheme" => "bearer", "oauth" => true}
  }
  @windows_api Map.put(@subscription_api, "use_up_to_windows", ~w(five_hour seven_day))

  setup do
    %{scope: scope} = sign_up_fixture()
    {subscription, values} = provider!(scope, "claude-subscription", ["main", "spare"])
    {api, api_values} = provider!(scope, "anthropic", ["main"])

    %{
      scope: scope,
      subscription: subscription,
      values: values,
      api: api,
      api_values: api_values
    }
  end

  # A provider of `kind` of the scope's organisation with a key for each value id, and its
  # values by value id.
  defp provider!(scope, kind, value_ids) do
    keys =
      for id <- value_ids, do: %{value_id: id, value: "sk-ant-oat01-fixture-#{id}-0123456789"}

    {:ok, provider} = Connections.create_provider(scope, %{provider: kind, keys: keys})
    values = Repo.all(from v in Value, where: v.secret_id == ^provider.secret_id)
    {provider, Map.new(values, &{&1.value_id, &1})}
  end

  # A state of `value` in `window`, written as a report writes one.
  defp state!(%Value{} = value, window, attrs) do
    ModelKeys.record(
      [
        %{
          name: "model-1",
          secret_value_id: value.id,
          organisation_id: value.organisation_id,
          copy_set_at: value.value_set_at,
          copy_kept: true
        }
      ],
      [
        Map.merge(
          %{
            credential: "model-1",
            window: window,
            status: "allowed",
            resets_at: nil,
            utilization: nil,
            cooldown_until: nil,
            source: "provider",
            observed_at: DateTime.utc_now()
          },
          Map.new(attrs)
        )
      ],
      DateTime.utc_now()
    )
  end

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

  defp at(seconds), do: DateTime.add(DateTime.utc_now(), seconds) |> DateTime.truncate(:second)

  describe "the setting" do
    test "is only for a key of a provider with limit windows", ctx do
      assert ModelKeys.limit_windows(ctx.subscription) == ["five_hour", "seven_day"]
      assert ModelKeys.limit_windows(ctx.api) == []
      assert ModelKeys.limit_windows("no-such-provider") == []

      assert {:ok, %Setting{use_up_to_percent: 90}} =
               put_key_setting(ctx.scope, ctx.values["main"], %{"use_up_to_percent" => 90})

      assert {:error, %Ecto.Changeset{errors: [use_up_to_percent: _]}} =
               put_key_setting(ctx.scope, ctx.api_values["main"], %{"use_up_to_percent" => 90})

      assert ModelKeys.setting(ctx.api_values["main"].id) == nil

      # An empty field clears it; for an API key, an empty field is no change.
      assert {:ok, %Setting{use_up_to_percent: nil}} =
               put_key_setting(ctx.scope, ctx.values["main"], %{"use_up_to_percent" => ""})

      assert {:ok, nil} =
               put_key_setting(ctx.scope, ctx.api_values["main"], %{"use_up_to_percent" => ""})
    end

    test "is a whole percent from 1 to 99", ctx do
      windows = ModelKeys.limit_windows(ctx.subscription)

      for percent <- [1, 50, 99] do
        assert Setting.changeset(%Setting{}, %{use_up_to_percent: percent}, windows).valid?
      end

      for percent <- [0, 100, -1, "9.5"] do
        refute Setting.changeset(%Setting{}, %{use_up_to_percent: percent}, windows).valid?,
               inspect(percent)
      end

      assert {:error, %Ecto.Changeset{}} =
               put_key_setting(ctx.scope, ctx.values["main"], %{"use_up_to_percent" => 100})

      # The table's check holds the bound too.
      assert_raise Ecto.ConstraintError, ~r/model_key_settings_use_up_to_percent_check/, fn ->
        Repo.insert!(%Setting{
          secret_value_id: ctx.values["main"].id,
          organisation_id: ctx.scope.organisation.id,
          use_up_to_percent: 100
        })
      end
    end
  end

  describe "a key in cooldown" do
    test "while a listed window's use is at or above the percentage, until it resets" do
      now = ~U[2026-11-12 12:00:00.000000Z]
      reset = ~U[2026-11-12 14:00:00.000000Z]
      later = ~U[2026-11-15 09:00:00.000000Z]
      windows = ["five_hour", "seven_day"]
      five = %State{window: "five_hour", utilization: 90, resets_at: reset}

      assert {^reset, {:use_up_to, ^five}} = ModelKeys.cooldown([five], 90, windows, now)
      assert ModelKeys.cooldown([%{five | utilization: 89}], 90, windows, now) == nil

      assert {^reset, _source} =
               ModelKeys.cooldown([%{five | utilization: 100}], 90, windows, now)

      # No percentage, no windows, a window not listed, no use, or a reset that passed.
      assert ModelKeys.cooldown([five], nil, windows, now) == nil
      assert ModelKeys.cooldown([five], 90, [], now) == nil
      assert ModelKeys.cooldown([%{five | window: "seven_day_opus"}], 90, windows, now) == nil
      assert ModelKeys.cooldown([%{five | utilization: nil}], 90, windows, now) == nil
      assert ModelKeys.cooldown([%{five | resets_at: now}], 90, windows, now) == nil
      assert ModelKeys.cooldown([%{five | resets_at: nil}], 90, windows, now) == nil

      # Of several windows, the latest reset.
      seven = %State{window: "seven_day", utilization: 95, resets_at: later}
      assert {^later, {:use_up_to, ^seven}} = ModelKeys.cooldown([five, seven], 90, windows, now)

      # A stored cooldown counts too, the later end first; a stored one at the same end.
      stored = %State{window: "key", cooldown_until: ~U[2026-11-12 13:00:00.000000Z]}
      assert {^reset, {:use_up_to, _}} = ModelKeys.cooldown([stored, five], 90, windows, now)
      stored = %{stored | cooldown_until: reset}
      assert {^reset, {:stored, ^stored}} = ModelKeys.cooldown([five, stored], 90, windows, now)
      assert {^reset, {:stored, ^stored}} = ModelKeys.cooldown([stored], nil, [], now)
      assert ModelKeys.cooldown([%{stored | cooldown_until: now}], nil, [], now) == nil
    end

    test "at the claim, with the percentage only for a provider with windows", ctx do
      now = DateTime.utc_now()
      reset = at(3600)
      main = ctx.values["main"]
      {:ok, _} = put_key_setting(ctx.scope, main, %{"use_up_to_percent" => 90})
      state!(main, "five_hour", utilization: 92, resets_at: reset)
      state!(ctx.values["spare"], "five_hour", utilization: 92, resets_at: reset)

      keys = ctx.subscription |> ModelKeys.claim_keys(nil, now) |> Map.new(&{&1.value_id, &1})
      assert %{use_up_to_percent: 90, cooldown_until: until, resets_at: resets_at} = keys["main"]
      assert DateTime.compare(until, reset) == :eq
      assert DateTime.compare(resets_at, reset) == :eq
      assert %{use_up_to_percent: nil, cooldown_until: nil} = keys["spare"]

      # An API key's stored percentage, written past the changeset, is ignored.
      api_main = ctx.api_values["main"]

      Repo.insert!(%Setting{
        secret_value_id: api_main.id,
        organisation_id: api_main.organisation_id,
        use_up_to_percent: 10
      })

      state!(api_main, "five_hour", utilization: 50, resets_at: reset)

      assert [%{use_up_to_percent: nil, cooldown_until: nil}] =
               ModelKeys.claim_keys(ctx.api, nil, now)

      assert ModelKeys.use_up_to_percents(ctx.api) == %{}
      assert ModelKeys.use_up_to_percents(ctx.subscription) == %{main.id => 90}
    end

    test "is the same in the claim's filter as in cooldown/4 at the edges", ctx do
      now = DateTime.utc_now()
      reset = at(3600)
      {solo, %{"solo" => value}} = provider!(ctx.scope, "claude-subscription", ["solo"])
      api_value = ctx.api_values["main"]

      # {provider, key, window, percent, utilization, resets_at, in cooldown}
      cases = [
        {solo, value, "five_hour", 90, 90, reset, true},
        {solo, value, "five_hour", 90, 89, reset, false},
        {solo, value, "five_hour", 90, nil, reset, false},
        {solo, value, "five_hour", 90, 95, nil, false},
        {ctx.api, api_value, "five_hour", 10, 95, reset, false}
      ]

      for {provider, key, window, percent, used, resets_at, cooling} <- cases do
        Repo.delete_all(from s in State, where: s.secret_value_id == ^key.id)
        Repo.delete_all(from s in Setting, where: s.secret_value_id == ^key.id)

        # Written past the changeset, which has no percentage for an API key.
        Repo.insert!(%Setting{
          secret_value_id: key.id,
          organisation_id: key.organisation_id,
          use_up_to_percent: percent
        })

        state!(key, window, utilization: used, resets_at: resets_at)
        states = Repo.all(from s in State, where: s.secret_value_id == ^key.id)
        windows = ModelKeys.limit_windows(provider)
        label = inspect({provider.provider_kind, used, resets_at})

        assert ModelKeys.cooldown(states, percent, windows, now) != nil == cooling, label
        assert claimable?([provider.id], now) == not cooling, label

        assert ModelKeys.cooldown_counts([provider], now) == %{
                 provider.id => if(cooling, do: 1, else: 0)
               },
               label
      end
    end

    test "leaves a run of the queue waiting while every key is at its percentage", ctx do
      now = DateTime.utc_now()
      soon = at(600)
      later = at(1800)

      for {name, reset} <- [{"main", soon}, {"spare", later}] do
        value = ctx.values[name]
        {:ok, _} = put_key_setting(ctx.scope, value, %{"use_up_to_percent" => 80})
        state!(value, "seven_day", utilization: 85, resets_at: reset)
      end

      refute claimable?([ctx.subscription.id], now)
      assert claimable?([ctx.subscription.id, ctx.api.id], now)
      assert DateTime.compare(ModelKeys.cooling_until([ctx.subscription.id], now), soon) == :eq

      assert ModelKeys.cooldown_counts([ctx.subscription, ctx.api], now) == %{
               ctx.subscription.id => 2,
               ctx.api.id => 0
             }

      # The window's reset ends it; a higher percentage, or a window not listed, never
      # starts it.
      assert claimable?([ctx.subscription.id], DateTime.add(soon, 1))
      {:ok, _} = put_key_setting(ctx.scope, ctx.values["main"], %{"use_up_to_percent" => 86})
      assert claimable?([ctx.subscription.id], now)
      assert ModelKeys.cooling_until([ctx.subscription.id], now) == nil

      assert ModelKeys.cooldown_counts([ctx.subscription], now) == %{ctx.subscription.id => 1}

      {:ok, _} = put_key_setting(ctx.scope, ctx.values["main"], %{"use_up_to_percent" => 50})
      Repo.delete_all(from s in State, where: s.secret_value_id == ^ctx.values["main"].id)
      state!(ctx.values["main"], "seven_day_opus", utilization: 99, resets_at: later)
      assert claimable?([ctx.subscription.id], now)
    end
  end

  describe "a run's keys" do
    # A run of the subscription with `keys` as it keeps them, and `api`.
    defp run(ctx, keys, api \\ @windows_api) do
      %Run{
        id: Ecto.UUID.generate(),
        provider_connection_id: ctx.subscription.id,
        provider_secret_id: ctx.subscription.secret_id,
        provider_api: api,
        model_keys: keys
      }
    end

    defp configuration(credential) do
      Jason.encode!(%{
        "version" => 1,
        "model_credential" => credential.name,
        "credentials" => Enum.map(credential.keys, & &1.entry)
      })
    end

    test "send the percentage with the run's windows, or neither", ctx do
      main = ctx.values["main"].id
      spare = ctx.values["spare"].id

      keys = [
        %{
          "id" => main,
          "name" => "k-1",
          "start" => true,
          "pause_for_s" => 3600,
          "use_up_to_percent" => 90
        },
        %{"id" => spare, "name" => "k-2", "pause_for_s" => 3600}
      ]

      assert {:ok, credential} = ProviderCredential.for_run(run(ctx, keys))
      [first, second] = Enum.map(credential.keys, &Jason.decode!(Jason.encode!(&1.entry)))
      assert first["use_up_to_percent"] == 90
      assert first["use_up_to_windows"] == ["five_hour", "seven_day"]
      refute Map.has_key?(second, "use_up_to_percent")
      refute Map.has_key?(second, "use_up_to_windows")

      bytes = configuration(credential)
      assert Apiary.ForagerSchemas.validate("run-configuration.schema.json", bytes) == :ok

      # A run that keeps no windows, such as one claimed before runs kept them, sends
      # neither, though its key has a percentage.
      assert {:ok, credential} = ProviderCredential.for_run(run(ctx, keys, @subscription_api))

      for %{entry: entry} <- credential.keys do
        entry = Jason.decode!(Jason.encode!(entry))
        refute Map.has_key?(entry, "use_up_to_percent")
        refute Map.has_key?(entry, "use_up_to_windows")
      end

      assert Apiary.ForagerSchemas.validate(
               "run-configuration.schema.json",
               configuration(credential)
             ) == :ok
    end

    test "fit runs.model_keys at 6 keys with every member, the windows once in the API",
         ctx do
      %{scope: scope} = ctx
      pool = Apiary.NodesFixtures.pool_fixture(scope)
      %{access_key: key} = Apiary.AccessKeysFixtures.enrolled_key_fixture(scope, pool)

      name = fn n -> String.duplicate("k", 62) <> "-#{n}" end
      time = "2026-11-12T14:00:00Z"
      windows = for n <- 1..11, do: String.pad_trailing("w#{n}_", 64, "x")
      assert Enum.all?(windows, &(String.length(&1) == 64 and State.window?(&1)))

      keys =
        for n <- 1..6 do
          first = if n == 1, do: %{"start" => true, "chosen" => true}, else: %{}

          Map.merge(first, %{
            "id" => Ecto.UUID.generate(),
            "name" => name.(n),
            "pause_for_s" => 604_800,
            "resets_at" => time,
            "schedule_resets_at" => time,
            "cooldown_until" => time,
            "use_up_to_percent" => 99
          })
        end

      api = Map.put(@subscription_api, "use_up_to_windows", windows)

      %{run: run} =
        Apiary.DispatchedRunsFixtures.handed_over_fixture(scope, key, %{
          provider_connection_id: ctx.subscription.id,
          provider_secret_id: ctx.subscription.secret_id,
          provider_chain: "organisation",
          provider_api: api,
          model_keys: keys,
          run_settings: %{}
        })

      assert %Run{model_keys: stored, provider_api: ^api} = Repo.get!(Run, run.id)
      assert stored == keys

      size =
        Repo.one(
          from r in Run,
            where: r.id == ^run.id,
            select: fragment("octet_length(?::text)", r.model_keys)
        )

      assert size <= 4096

      # The run configuration, with the 11 windows of 64 characters on each key, passes
      # the contract's schema.
      entries = for k <- keys, do: ProviderCredential.entry(k["name"], api, k)
      assert Enum.all?(entries, &(&1["use_up_to_windows"] == windows))
      document = Jason.encode!(%{"version" => 1, "credentials" => entries})
      assert Apiary.ForagerSchemas.validate("run-configuration.schema.json", document) == :ok

      # Kept on each key, those windows break the column's check: each key keeps the
      # percentage alone, and the run keeps the windows once, in `provider_api`.
      with_windows = Enum.map(keys, &Map.put(&1, "use_up_to_windows", windows))

      assert_raise Postgrex.Error, ~r/runs_model_keys_check/, fn ->
        Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [model_keys: with_windows])
      end
    end
  end
end
