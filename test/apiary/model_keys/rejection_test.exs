defmodule Apiary.ModelKeys.RejectionTest do
  # A key whose model provider returned 401 to a request that carried it, as a run's gateway
  # reports it (`Apiary.ModelKeys.reject/4`, `Apiary.ModelKeys.Rejection`): the key is
  # skipped at a claim until it gets a new value, a value equal to the old one included, and
  # a provider's rejection of the value again puts it back. A sign-in that a refresh may
  # still renew is not marked. The tests read the claim's reads (`claim_keys/4`,
  # `claimable/2`, `first_to_leave/2`, `waiting_reason/3`) with no call to any provider.
  use Apiary.DataCase, async: true

  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, ModelKeys}
  alias Apiary.Connections.Connection
  alias Apiary.ModelKeys.{Login, Rejection}
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

  # A key of a run that has the value as it is now.
  defp key(%Value{} = value, name \\ "model-1"),
    do: %{
      name: name,
      secret_value_id: value.id,
      organisation_id: value.organisation_id,
      copy_set_at: value.value_set_at,
      copy_kept: true
    }

  defp unauthorized(name \\ "model-1", at \\ DateTime.utc_now()),
    do: %{credential: name, at: at}

  defp rows(%Value{id: id}),
    do: Repo.all(from r in Rejection, where: r.secret_value_id == ^id)

  defp claim_key(provider, value_id, now \\ DateTime.utc_now()) do
    provider |> ModelKeys.claim_keys(nil, now) |> Enum.find(&(&1.value_id == value_id))
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

  describe "reject/4" do
    test "marks a key of the run: the claim skips it, with the time of the 401", ctx do
      main = ctx.values["main"]
      at = ~U[2026-11-18 09:12:00.000000Z]

      :ok =
        ModelKeys.reject(
          [key(main)],
          [unauthorized("model-1", at)],
          ctx.provider,
          DateTime.utc_now()
        )

      assert [%Rejection{rejected_at: ^at}] = rows(main)
      assert %{blocked: :new_key} = claim_key(ctx.provider, "main")
      assert %{blocked: nil} = claim_key(ctx.provider, "spare")
      main_id = main.id
      assert %{^main_id => %Rejection{rejected_at: ^at}} = ModelKeys.rejections(ctx.provider)
    end

    test "leaves out a credential the run does not have, and a key that is gone", ctx do
      main = ctx.values["main"]

      :ok =
        ModelKeys.reject([key(main)], [unauthorized("model-9")], ctx.provider, DateTime.utc_now())

      assert rows(main) == []

      gone = %{key(main) | secret_value_id: Ecto.UUID.generate()}
      :ok = ModelKeys.reject([gone], [unauthorized()], ctx.provider, DateTime.utc_now())
      assert Repo.aggregate(Rejection, :count) == 0
    end

    test "leaves out a key whose value the run does not have: a new value was set since the seal",
         ctx do
      main = ctx.values["main"]
      old = %{key(main) | copy_set_at: DateTime.add(main.value_set_at, -60)}

      :ok = ModelKeys.reject([old], [unauthorized()], ctx.provider, DateTime.utc_now())

      assert rows(main) == []
      assert %{blocked: nil} = claim_key(ctx.provider, "main")
    end

    test "a later report of the same 401 keeps the row, a newer 401 moves its time", ctx do
      main = ctx.values["main"]
      first = ~U[2026-11-18 09:12:00.000000Z]
      newer = ~U[2026-11-18 09:30:00.000000Z]

      :ok =
        ModelKeys.reject(
          [key(main)],
          [unauthorized("model-1", first)],
          ctx.provider,
          DateTime.utc_now()
        )

      :ok =
        ModelKeys.reject(
          [key(main)],
          [unauthorized("model-1", DateTime.add(first, -600))],
          ctx.provider,
          DateTime.utc_now()
        )

      assert [%Rejection{rejected_at: ^first}] = rows(main)

      :ok =
        ModelKeys.reject(
          [key(main)],
          [unauthorized("model-1", newer)],
          ctx.provider,
          DateTime.utc_now()
        )

      assert [%Rejection{rejected_at: ^newer}] = rows(main)
    end

    test "marks the keys of one report each, in any order", ctx do
      main = ctx.values["main"]
      spare = ctx.values["spare"]
      keys = [key(spare, "model-2"), key(main, "model-1")]

      :ok =
        ModelKeys.reject(
          keys,
          [unauthorized("model-2"), unauthorized("model-1")],
          ctx.provider,
          DateTime.utc_now()
        )

      assert length(rows(main)) == 1 and length(rows(spare)) == 1
    end
  end

  describe "a new value" do
    test "clears the mark and the claim takes the key again", ctx do
      main = ctx.values["main"]
      :ok = ModelKeys.reject([key(main)], [unauthorized()], ctx.provider, DateTime.utc_now())
      assert %{blocked: :new_key} = claim_key(ctx.provider, "main")

      new_value!(ctx.scope, ctx.provider, "main", "sk-ant-fixture-main-9876543210")

      assert rows(main) == []
      assert %{blocked: nil} = claim_key(ctx.provider, "main")
      assert ModelKeys.rejections(ctx.provider) == %{}
    end

    test "clears the mark when it equals the stored value", ctx do
      main = ctx.values["main"]
      :ok = ModelKeys.reject([key(main)], [unauthorized()], ctx.provider, DateTime.utc_now())

      new_value!(ctx.scope, ctx.provider, "main", "sk-ant-fixture-main-0123456789")

      assert rows(main) == []
      assert %{blocked: nil} = claim_key(ctx.provider, "main")
    end

    test "a row left by another write path stops counting when the value's time moves", ctx do
      main = ctx.values["main"]
      :ok = ModelKeys.reject([key(main)], [unauthorized()], ctx.provider, DateTime.utc_now())

      Repo.update_all(from(v in Value, where: v.id == ^main.id),
        set: [value_set_at: DateTime.add(main.value_set_at, 5)]
      )

      assert [_row] = rows(main)
      assert %{blocked: nil} = claim_key(ctx.provider, "main")
      assert ModelKeys.rejections(ctx.provider) == %{}
    end

    test "the provider's rejection of the new value marks the key again", ctx do
      main = ctx.values["main"]
      :ok = ModelKeys.reject([key(main)], [unauthorized()], ctx.provider, DateTime.utc_now())
      new_value!(ctx.scope, ctx.provider, "main", "sk-ant-fixture-main-9876543210")

      renewed = Repo.get!(Value, main.id)
      :ok = ModelKeys.reject([key(renewed)], [unauthorized()], ctx.provider, DateTime.utc_now())

      assert %{blocked: :new_key} = claim_key(ctx.provider, "main")
    end

    test "a rename keeps the mark", ctx do
      main = ctx.values["main"]
      :ok = ModelKeys.reject([key(main)], [unauthorized()], ctx.provider, DateTime.utc_now())

      Repo.update_all(from(v in Value, where: v.id == ^main.id), set: [value_id: "renamed"])

      assert %{blocked: :new_key} = claim_key(ctx.provider, "renamed")
    end
  end

  describe "the claim's reads" do
    test "a provider whose every key needs a new value is not claimable, and has no end", ctx do
      now = DateTime.utc_now()
      assert claimable?([ctx.provider.id], now)

      :ok = ModelKeys.reject([key(ctx.values["main"])], [unauthorized()], ctx.provider, now)
      assert claimable?([ctx.provider.id], now)

      :ok =
        ModelKeys.reject(
          [key(ctx.values["spare"], "model-2")],
          [unauthorized("model-2")],
          ctx.provider,
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

      :ok = ModelKeys.reject([key(ctx.values["main"])], [unauthorized()], ctx.provider, now)

      ModelKeys.record(
        [key(ctx.values["spare"])],
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
      assert {:cooldown, %Connection{}, ^until} = ModelKeys.waiting_reason([ctx.provider.id], now)
    end

    test "has no reason to wait while one key is free, and for a provider with no key", ctx do
      now = DateTime.utc_now()
      :ok = ModelKeys.reject([key(ctx.values["main"])], [unauthorized()], ctx.provider, now)

      assert ModelKeys.waiting_reason([ctx.provider.id], now) == nil
      assert ModelKeys.waiting_reason([], now) == nil
    end
  end

  describe "when keys of two providers need a person" do
    test "the reason is the first key in the run's order of providers", ctx do
      now = DateTime.utc_now()
      :ok = ModelKeys.reject([key(ctx.values["main"])], [unauthorized()], ctx.provider, now)

      :ok =
        ModelKeys.reject(
          [key(ctx.values["spare"], "model-2")],
          [unauthorized("model-2")],
          ctx.provider,
          now
        )

      {:ok, login} =
        Connections.create_provider(ctx.scope, %{
          provider: "openai-subscription",
          keys: [%{value_id: "login", value: login_paste()}]
        })

      Repo.update_all(Login,
        set: [state: "sign_in_needed", sign_in_cause: "refresh_token_expired"]
      )

      assert {:new_key, %Connection{}, name} =
               ModelKeys.waiting_reason([ctx.provider.id, login.id], now)

      assert name in ["main", "spare"]

      assert {:sign_in, %Connection{}, "login"} =
               ModelKeys.waiting_reason([login.id, ctx.provider.id], now)
    end
  end

  describe "a key of a provider whose keys are sign-ins" do
    setup ctx do
      {:ok, provider} =
        Connections.create_provider(ctx.scope, %{
          provider: "openai-subscription",
          keys: [%{value_id: "login", value: login_paste()}]
        })

      value = key_value!(provider, "login")
      %{subscription: provider, login: value}
    end

    test "is marked only after a 401 on a token under 5 minutes old, not before",
         ctx do
      login = Repo.get!(Login, ctx.login.id)

      Repo.update_all(from(l in Login, where: l.secret_value_id == ^ctx.login.id),
        set: [signed_in_at: DateTime.add(DateTime.utc_now(), -3600)]
      )

      :ok =
        ModelKeys.reject([key(ctx.login)], [unauthorized()], ctx.subscription, DateTime.utc_now())

      assert rows(ctx.login) == []
      assert %{blocked: nil} = claim_key(ctx.subscription, "login")

      Repo.update_all(from(l in Login, where: l.secret_value_id == ^ctx.login.id),
        set: [signed_in_at: login.signed_in_at]
      )

      :ok =
        ModelKeys.reject([key(ctx.login)], [unauthorized()], ctx.subscription, DateTime.utc_now())

      assert [_row] = rows(ctx.login)
      assert %{blocked: :new_key} = claim_key(ctx.subscription, "login")
    end
  end
end
