defmodule Apiary.ModelKeys.RejectionTest do
  # A key whose model provider returned 401 to a request that carried it, as a run's gateway
  # reports it (`Apiary.ModelKeys.reject/3`, `Apiary.ModelKeys.Rejection`): the key is
  # skipped at a claim until it gets a new value, a value equal to the old one included, and
  # a provider's rejection of the value again puts it back. A sign-in that a refresh may
  # still renew is not marked. The tests read the claim's reads (`claim_keys/3`,
  # `claimable/2`, `first_to_leave/2`, `waiting_reason/3`) with no call to any provider.
  use Apiary.DataCase, async: true

  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, ModelKeys}
  alias Apiary.Connections.Connection
  alias Apiary.ModelKeys.{Copy, Login, Rejection}
  alias Apiary.Secrets.Value

  @moduletag needs: [:factory, :secrets]

  setup do
    %{scope: scope} = sign_up_fixture()
    {provider, values} = provider!(scope, ["main", "spare"])
    %{scope: scope, provider: provider, values: values}
  end

  defp provider!(scope, value_ids) do
    keys = for id <- value_ids, do: %{value_id: id, value: "sk-ant-fixture-#{id}-0123456789"}
    {:ok, provider} = Connections.create_provider(scope, %{provider: "anthropic", keys: keys})
    values = Repo.all(from v in Value, where: v.secret_id == ^provider.secret_id)
    {provider, Map.new(values, &{&1.value_id, &1})}
  end

  # A key of a new run that has the value as it is now, with the copy a secrets request
  # keeps for it (`run_key!/4`).
  defp key(ctx, %Value{} = value, name \\ "model-1"), do: run_key!(ctx.scope, value, name)

  defp unauthorized(name \\ "model-1", at \\ DateTime.utc_now()),
    do: %{credential: name, at: at}

  defp rows(%Value{id: id}),
    do: Repo.all(from r in Rejection, where: r.secret_value_id == ^id)

  defp claim_key(provider, value_id, now \\ DateTime.utc_now()) do
    provider |> ModelKeys.claim_keys(now) |> Enum.find(&(&1.value_id == value_id))
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

  # The key gets `new` as its value, as the Edit key page saves it.
  defp new_value!(scope, provider, value_id, new) do
    {:ok, _provider} =
      Connections.update_provider_key(scope, provider, value_id, %{
        value_id: value_id,
        value: new
      })
  end

  describe "reject/3" do
    test "marks a key of the run: the claim skips it, with the time of the 401", ctx do
      main = ctx.values["main"]
      at = ~U[2026-11-18 09:12:00.000000Z]

      :ok =
        ModelKeys.reject(
          [key(ctx, main)],
          [unauthorized("model-1", at)],
          DateTime.utc_now()
        )

      assert [%Rejection{rejected_at: ^at}] = rows(main)
      assert %{blocked: :new_key} = claim_key(ctx.provider, "main")
      assert %{blocked: nil} = claim_key(ctx.provider, "spare")
      main_id = main.id
      assert %{^main_id => %Rejection{rejected_at: ^at}} = ModelKeys.rejections(ctx.provider)
    end

    test "makes the gate refuse the key, and a new value makes it serve it again", ctx do
      main = ctx.values["main"]
      spare = ctx.values["spare"]
      provider = Repo.get!(Connection, ctx.provider.id)
      run = %Apiary.Runs.Run{}

      assert {:ok, "sk-ant-fixture-main-0123456789", nil, %DateTime{}, nil} =
               ModelKeys.reveal_for_sealing(provider, main.id, run, wait: 100)

      :ok = ModelKeys.reject([key(ctx, main)], [unauthorized()], DateTime.utc_now())

      assert ModelKeys.reveal_for_sealing(provider, main.id, run, wait: 100) ==
               {:error, :new_key_needed}

      assert {:ok, "sk-ant-fixture-spare-0123456789", nil, %DateTime{}, nil} =
               ModelKeys.reveal_for_sealing(provider, spare.id, run, wait: 100)

      new_value!(ctx.scope, ctx.provider, "main", "sk-ant-fixture-new-0123456789")

      assert {:ok, "sk-ant-fixture-new-0123456789", nil, %DateTime{}, nil} =
               ModelKeys.reveal_for_sealing(provider, main.id, run, wait: 100)
    end

    test "leaves out a credential the run does not have, and a key that is gone", ctx do
      main = ctx.values["main"]

      :ok =
        ModelKeys.reject(
          [key(ctx, main)],
          [unauthorized("model-9")],
          DateTime.utc_now()
        )

      assert rows(main) == []

      gone = %{key(ctx, main) | secret_value_id: Ecto.UUID.generate()}
      :ok = ModelKeys.reject([gone], [unauthorized()], DateTime.utc_now())
      assert Repo.aggregate(Rejection, :count) == 0
    end

    test "leaves out a key whose value the run does not have: a new value was set since the seal",
         ctx do
      main = ctx.values["main"]
      old = %{key(ctx, main) | copy_set_at: DateTime.add(main.value_set_at, -60)}

      :ok = ModelKeys.reject([old], [unauthorized()], DateTime.utc_now())

      assert rows(main) == []
      assert %{blocked: nil} = claim_key(ctx.provider, "main")
    end

    test "marks a key once for a run: a second report of it marks nothing and moves nothing",
         ctx do
      main = ctx.values["main"]
      run_key = key(ctx, main)
      first = ~U[2026-11-18 09:12:00.000000Z]
      later = ~U[2026-11-18 09:30:00.000000Z]

      :ok =
        ModelKeys.reject(
          [run_key],
          [unauthorized("model-1", first)],
          DateTime.utc_now()
        )

      for at <- [later, DateTime.add(first, -600)] do
        :ok =
          ModelKeys.reject(
            [run_key],
            [unauthorized("model-1", at)],
            DateTime.utc_now()
          )

        assert [%Rejection{rejected_at: ^first}] = rows(main)
      end
    end

    test "marks a key once for a report that has it twice", ctx do
      main = ctx.values["main"]
      first = ~U[2026-11-18 09:12:00.000000Z]
      later = ~U[2026-11-18 09:30:00.000000Z]

      :ok =
        ModelKeys.reject(
          [key(ctx, main)],
          [unauthorized("model-1", first), unauthorized("model-1", later)],
          DateTime.utc_now()
        )

      assert [%Rejection{rejected_at: ^first}] = rows(main)
    end

    test "keeps the run's mark when a request seals the same value again", ctx do
      main = ctx.values["main"]
      run_key = key(ctx, main)
      first = ~U[2026-11-18 09:12:00.000000Z]

      :ok =
        ModelKeys.reject(
          [run_key],
          [unauthorized("model-1", first)],
          DateTime.utc_now()
        )

      :ok = ModelKeys.keep_copies(run_key.run_id, [{main.id, main.value_set_at}])
      assert %Copy{marked_at: %DateTime{}} = Repo.get_by!(Copy, run_id: run_key.run_id)

      :ok =
        ModelKeys.reject(
          [run_key],
          [unauthorized("model-1", DateTime.add(first, 600))],
          DateTime.utc_now()
        )

      assert [%Rejection{rejected_at: ^first}] = rows(main)
    end

    test "lets the run mark a new value once a request sealed it for the run", ctx do
      main = ctx.values["main"]
      run_key = key(ctx, main)
      first = ~U[2026-11-18 09:12:00.000000Z]
      later = ~U[2026-11-18 09:30:00.000000Z]

      :ok =
        ModelKeys.reject(
          [run_key],
          [unauthorized("model-1", first)],
          DateTime.utc_now()
        )

      new_value!(ctx.scope, ctx.provider, "main", "sk-ant-fixture-main-9876543210")
      assert rows(main) == []
      renewed = Repo.get!(Value, main.id)
      assert DateTime.compare(renewed.value_set_at, main.value_set_at) == :gt

      # The run still has the old value until a request seals the new one: it marks nothing.
      :ok =
        ModelKeys.reject(
          [run_key],
          [unauthorized("model-1", later)],
          DateTime.utc_now()
        )

      assert rows(main) == []

      :ok = ModelKeys.keep_copies(run_key.run_id, [{main.id, renewed.value_set_at}])
      assert %Copy{marked_at: nil} = Repo.get_by!(Copy, run_id: run_key.run_id)

      resealed = %{run_key | copy_set_at: renewed.value_set_at}

      :ok =
        ModelKeys.reject(
          [resealed],
          [unauthorized("model-1", later)],
          DateTime.utc_now()
        )

      assert [%Rejection{rejected_at: ^later}] = rows(main)

      # The new value is marked once for the run as well.
      :ok =
        ModelKeys.reject(
          [resealed],
          [unauthorized("model-1", DateTime.add(later, 600))],
          DateTime.utc_now()
        )

      assert [%Rejection{rejected_at: ^later}] = rows(main)
    end

    test "marks nothing for a key the gateway never received", ctx do
      main = ctx.values["main"]
      never_sent = %{key(ctx, main) | copy_kept: false}

      :ok = ModelKeys.reject([never_sent], [unauthorized()], DateTime.utc_now())

      assert rows(main) == []
      assert %{blocked: nil} = claim_key(ctx.provider, "main")
    end

    test "lets a new run mark a key that another run marked", ctx do
      main = ctx.values["main"]
      first = ~U[2026-11-18 09:12:00.000000Z]
      later = ~U[2026-11-18 09:30:00.000000Z]

      :ok =
        ModelKeys.reject(
          [key(ctx, main)],
          [unauthorized("model-1", first)],
          DateTime.utc_now()
        )

      :ok =
        ModelKeys.reject(
          [key(ctx, main)],
          [unauthorized("model-1", later)],
          DateTime.utc_now()
        )

      assert [%Rejection{rejected_at: ^later}] = rows(main)
    end

    test "marks the keys of one report each, in any order", ctx do
      main = ctx.values["main"]
      spare = ctx.values["spare"]
      keys = [key(ctx, spare, "model-2"), key(ctx, main, "model-1")]

      :ok =
        ModelKeys.reject(
          keys,
          [unauthorized("model-2"), unauthorized("model-1")],
          DateTime.utc_now()
        )

      assert length(rows(main)) == 1 and length(rows(spare)) == 1
    end
  end

  describe "a new value" do
    test "clears the mark and the claim takes the key again", ctx do
      main = ctx.values["main"]
      :ok = ModelKeys.reject([key(ctx, main)], [unauthorized()], DateTime.utc_now())
      assert %{blocked: :new_key} = claim_key(ctx.provider, "main")

      new_value!(ctx.scope, ctx.provider, "main", "sk-ant-fixture-main-9876543210")

      assert rows(main) == []
      assert %{blocked: nil} = claim_key(ctx.provider, "main")
      assert ModelKeys.rejections(ctx.provider) == %{}
    end

    test "clears the mark when it equals the stored value", ctx do
      main = ctx.values["main"]
      :ok = ModelKeys.reject([key(ctx, main)], [unauthorized()], DateTime.utc_now())

      new_value!(ctx.scope, ctx.provider, "main", "sk-ant-fixture-main-0123456789")

      assert rows(main) == []
      assert %{blocked: nil} = claim_key(ctx.provider, "main")
    end

    test "a row left by another write path stops counting when the value's time moves", ctx do
      main = ctx.values["main"]
      :ok = ModelKeys.reject([key(ctx, main)], [unauthorized()], DateTime.utc_now())

      Repo.update_all(from(v in Value, where: v.id == ^main.id),
        set: [value_set_at: DateTime.add(main.value_set_at, 5)]
      )

      assert [_row] = rows(main)
      assert %{blocked: nil} = claim_key(ctx.provider, "main")
      assert ModelKeys.rejections(ctx.provider) == %{}
    end

    test "the provider's rejection of the new value marks the key again", ctx do
      main = ctx.values["main"]
      :ok = ModelKeys.reject([key(ctx, main)], [unauthorized()], DateTime.utc_now())
      new_value!(ctx.scope, ctx.provider, "main", "sk-ant-fixture-main-9876543210")

      renewed = Repo.get!(Value, main.id)

      :ok =
        ModelKeys.reject([key(ctx, renewed)], [unauthorized()], DateTime.utc_now())

      assert %{blocked: :new_key} = claim_key(ctx.provider, "main")
    end

    test "a rename keeps the mark", ctx do
      main = ctx.values["main"]
      :ok = ModelKeys.reject([key(ctx, main)], [unauthorized()], DateTime.utc_now())

      Repo.update_all(from(v in Value, where: v.id == ^main.id), set: [value_id: "renamed"])

      assert %{blocked: :new_key} = claim_key(ctx.provider, "renamed")
    end
  end

  describe "the claim's reads" do
    test "a provider whose every key needs a new value is not claimable, and has no end", ctx do
      now = DateTime.utc_now()
      assert claimable?([ctx.provider.id], now)

      :ok = ModelKeys.reject([key(ctx, ctx.values["main"])], [unauthorized()], now)
      assert claimable?([ctx.provider.id], now)

      :ok =
        ModelKeys.reject(
          [key(ctx, ctx.values["spare"], "model-2")],
          [unauthorized("model-2")],
          now
        )

      refute claimable?([ctx.provider.id], now)
      assert ModelKeys.cooling_until([ctx.provider.id], now) == nil
      assert ModelKeys.first_to_leave([ctx.provider.id], now) == nil
      assert {:new_key, %Connection{}, "main"} = ModelKeys.waiting_reason([ctx.provider.id], now)
    end

    test "a key that needs a new value beside a key in cooldown leaves with the cooldown", ctx do
      now = DateTime.utc_now()
      later = DateTime.add(now, 3600)

      :ok = ModelKeys.reject([key(ctx, ctx.values["main"])], [unauthorized()], now)

      ModelKeys.record(
        [key(ctx, ctx.values["spare"])],
        [
          %{
            credential: "model-1",
            window: "five_hour",
            status: "rejected",
            resets_at: later,
            utilization: nil,
            cooldown_until: later,
            source: "provider",
            observed_at: now
          }
        ],
        now
      )

      refute claimable?([ctx.provider.id], now)
      assert {id, until} = ModelKeys.first_to_leave([ctx.provider.id], now)
      assert id == ctx.provider.id and DateTime.compare(until, later) == :eq

      # One key is in cooldown and the other needs a new value: the reason says both.
      assert {:cooldown_or_new_key, %Connection{}, ^until} =
               ModelKeys.waiting_reason([ctx.provider.id], now)

      assert ModelKeys.new_key_counts([ctx.provider]) == %{ctx.provider.id => 1}
    end

    test "a provider with every key in cooldown has the cooldown as its reason", ctx do
      now = DateTime.utc_now()
      later = DateTime.add(now, 3600)

      for {value, name} <- [{ctx.values["main"], "model-1"}, {ctx.values["spare"], "model-2"}] do
        ModelKeys.record(
          [key(ctx, value, name)],
          [
            %{
              credential: name,
              window: "five_hour",
              status: "rejected",
              resets_at: later,
              utilization: nil,
              cooldown_until: later,
              source: "provider",
              observed_at: now
            }
          ],
          now
        )
      end

      assert {:cooldown, %Connection{}, ^later} = ModelKeys.waiting_reason([ctx.provider.id], now)
      assert ModelKeys.new_key_counts([ctx.provider]) == %{ctx.provider.id => 0}
    end

    test "has no reason to wait while one key is free, and for a provider with no key", ctx do
      now = DateTime.utc_now()
      :ok = ModelKeys.reject([key(ctx, ctx.values["main"])], [unauthorized()], now)

      assert ModelKeys.waiting_reason([ctx.provider.id], now) == nil
      assert ModelKeys.waiting_reason([], now) == nil
    end
  end

  describe "when keys of two providers need a person" do
    test "the reason is the first key in the run's order of providers", ctx do
      now = DateTime.utc_now()
      :ok = ModelKeys.reject([key(ctx, ctx.values["main"])], [unauthorized()], now)

      :ok =
        ModelKeys.reject(
          [key(ctx, ctx.values["spare"], "model-2")],
          [unauthorized("model-2")],
          now
        )

      {:ok, login} =
        Connections.create_provider(ctx.scope, %{
          provider: "openai-subscription",
          keys: [%{value_id: "login", value: device_login()}]
        })

      Repo.update_all(Login,
        set: [state: "sign_in_needed", sign_in_cause: "refresh_token_expired"]
      )

      assert {:new_key, %Connection{}, name} =
               ModelKeys.waiting_reason([ctx.provider.id, login.id], now)

      assert name in ["main", "spare"]

      assert {:sign_in, %Connection{}, "login"} =
               ModelKeys.waiting_reason([login.id, ctx.provider.id], now)

      assert ModelKeys.new_key_counts([ctx.provider, login]) ==
               %{ctx.provider.id => 2, login.id => 1}
    end

    test "with a key in cooldown too, the reason has no provider", ctx do
      now = DateTime.utc_now()
      later = DateTime.add(now, 3600)

      :ok = ModelKeys.reject([key(ctx, ctx.values["main"])], [unauthorized()], now)

      ModelKeys.record(
        [key(ctx, ctx.values["spare"], "model-2")],
        [
          %{
            credential: "model-2",
            window: "five_hour",
            status: "rejected",
            resets_at: later,
            utilization: nil,
            cooldown_until: later,
            source: "provider",
            observed_at: now
          }
        ],
        now
      )

      {:ok, login} =
        Connections.create_provider(ctx.scope, %{
          provider: "openai-subscription",
          keys: [%{value_id: "login", value: device_login()}]
        })

      Repo.update_all(Login,
        set: [state: "sign_in_needed", sign_in_cause: "refresh_token_expired"]
      )

      assert {:cooldown_or_new_key, nil, ^later} =
               ModelKeys.waiting_reason([ctx.provider.id, login.id], now)
    end
  end

  describe "a key of a provider whose keys are sign-ins" do
    setup ctx do
      {:ok, provider} =
        Connections.create_provider(ctx.scope, %{
          provider: "openai-subscription",
          keys: [%{value_id: "login", value: device_login()}]
        })

      value = key_value!(provider, "login")
      %{subscription: provider, login: value}
    end

    # The sign-in's row as a key of a run reads it, with `login_at` as the run's copy has it.
    defp login_key(ctx, login_at),
      do: key(ctx, ctx.login) |> Map.put(:copy_login_at, login_at)

    defp token_time(ctx) do
      login = Repo.get!(Login, ctx.login.id)
      login.refreshed_at || login.signed_in_at
    end

    defp set_login!(ctx, changes) do
      {1, _rows} =
        Repo.update_all(from(l in Login, where: l.secret_value_id == ^ctx.login.id),
          set: changes
        )
    end

    defp reject!(_ctx, key),
      do: :ok = ModelKeys.reject([key], [unauthorized()], DateTime.utc_now())

    test "a 401 on the token the run has, under 5 minutes old, marks the key", ctx do
      reject!(ctx, login_key(ctx, token_time(ctx)))

      assert [_row] = rows(ctx.login)
      assert %{blocked: :new_key} = claim_key(ctx.subscription, "login")
    end

    test "a 401 on the token the run has, a refreshed one, marks the key", ctx do
      refreshed = DateTime.add(DateTime.utc_now(), -30)
      set_login!(ctx, refreshed_at: refreshed)

      reject!(ctx, login_key(ctx, token_time(ctx)))

      assert [_row] = rows(ctx.login)
    end

    test "a 401 on a token 5 minutes old or older marks nothing: a refresh may renew it",
         ctx do
      set_login!(ctx, signed_in_at: DateTime.add(DateTime.utc_now(), -3600))
      reject!(ctx, login_key(ctx, token_time(ctx)))

      assert rows(ctx.login) == []
      assert %{blocked: nil} = claim_key(ctx.subscription, "login")

      set_login!(ctx, refreshed_at: DateTime.add(DateTime.utc_now(), -301))
      reject!(ctx, login_key(ctx, token_time(ctx)))

      assert rows(ctx.login) == []
    end

    test "a 401 on a token older than the one the sign-in holds, after a refresh, marks nothing",
         ctx do
      sealed = token_time(ctx)
      set_login!(ctx, refreshed_at: DateTime.add(DateTime.utc_now(), 0))

      reject!(ctx, login_key(ctx, sealed))

      assert rows(ctx.login) == []
      assert %{blocked: nil} = claim_key(ctx.subscription, "login")
    end

    test "an entry before the time the run's copy took the token marks nothing", ctx do
      sealed = DateTime.utc_now()
      key = login_key(ctx, token_time(ctx)) |> Map.put(:copy_login_sealed_at, sealed)

      # Before the sealing time the 401 is for an earlier token; at it, for the token the run has.
      for at <- [DateTime.add(sealed, -1, :second), DateTime.add(sealed, -3600, :second)] do
        :ok = ModelKeys.reject([key], [unauthorized("model-1", at)], sealed)
        assert rows(ctx.login) == []
      end

      :ok = ModelKeys.reject([key], [unauthorized("model-1", sealed)], sealed)
      assert [_row] = rows(ctx.login)
    end

    test "a key with no time for its copy drops no entry for its time", ctx do
      key = login_key(ctx, token_time(ctx)) |> Map.put(:copy_login_sealed_at, nil)
      at = DateTime.add(DateTime.utc_now(), -3600, :second)

      :ok = ModelKeys.reject([key], [unauthorized("model-1", at)], at)

      assert [_row] = rows(ctx.login)
    end

    test "a 401 for a run that holds no sign-in time marks nothing", ctx do
      reject!(ctx, login_key(ctx, nil))
      assert rows(ctx.login) == []

      reject!(ctx, key(ctx, ctx.login))
      assert rows(ctx.login) == []
    end
  end

  describe "a run with the keys of two providers, the second a sign-in" do
    setup ctx do
      {:ok, subscription} =
        Connections.create_provider(ctx.scope, %{
          provider: "openai-subscription",
          keys: [%{value_id: "login", value: device_login()}]
        })

      login = key_value!(subscription, "login")
      main = ctx.values["main"]
      pool = Apiary.NodesFixtures.pool_fixture(ctx.scope)
      %{access_key: access_key} = Apiary.AccessKeysFixtures.enrolled_key_fixture(ctx.scope, pool)

      %{run: run} =
        Apiary.DispatchedRunsFixtures.handed_over_fixture(ctx.scope, access_key, %{
          provider_connection_id: ctx.provider.id,
          run_settings: %{}
        })

      run_keys!(run, [
        %{provider: ctx.provider, secret_value_id: main.id, name: "model-1"},
        %{provider: subscription, secret_value_id: login.id, name: "model-2"}
      ])

      %{subscription: subscription, login: login, run: run}
    end

    # The run holds the first provider's key and the sign-in as of `login_at`, as a secrets
    # request kept them, and reports both as 401, as a gateway lists them.
    defp report!(ctx, login_at) do
      :ok =
        ModelKeys.keep_copies(ctx.run.id, [
          {ctx.values["main"].id, ctx.values["main"].value_set_at, nil},
          {ctx.login.id, ctx.login.value_set_at, login_at}
        ])

      keys = ModelKeys.run_keys(ctx.run)
      assert length(keys) == 2

      :ok =
        ModelKeys.reject(
          keys,
          [unauthorized("model-1"), unauthorized("model-2")],
          DateTime.utc_now()
        )
    end

    test "a 401 on a token a refresh may renew marks the first provider's key and not the sign-in",
         ctx do
      set_login!(ctx, signed_in_at: DateTime.add(DateTime.utc_now(), -3600))

      report!(ctx, token_time(ctx))

      assert [_row] = rows(ctx.values["main"])
      assert rows(ctx.login) == []
      assert %{blocked: nil} = claim_key(ctx.subscription, "login")
    end

    test "a 401 on the token the run has, a new one, marks the sign-in too", ctx do
      report!(ctx, token_time(ctx))

      assert [_row] = rows(ctx.values["main"])
      assert [_row] = rows(ctx.login)
      assert %{blocked: :new_key} = claim_key(ctx.subscription, "login")
    end

    test "after a refresh, a 401 on the older token marks nothing and on the newer one marks it",
         ctx do
      older = token_time(ctx)
      set_login!(ctx, refreshed_at: DateTime.add(DateTime.utc_now(), 1))

      report!(ctx, older)
      assert rows(ctx.login) == []

      report!(ctx, token_time(ctx))
      assert [_row] = rows(ctx.login)
    end
  end
end
