defmodule Apiary.ModelKeysRacesTest do
  # The states of model keys (`Apiary.ModelKeys.record/3`) written by two reports at
  # once, and by a report while a key is deleted. Each side runs on a connection apart,
  # outside the SQL sandbox, so each commits and each waits on the other's locks as it
  # would in production. Not async: what these tests commit is visible to every other
  # test while they run, and the organisation they make is deleted again before they end.
  use ExUnit.Case, async: false

  # A list in `needs:` is read by this hook (`Apiary.TestSetup`).
  @before_compile Apiary.TestSetup

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{Connections, ModelKeys, Repo}
  alias Apiary.ModelKeys.State
  alias Apiary.Secrets.Value

  @moduletag needs: [:factory, :secrets]

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    %{scope: scope} = sign_up()
    keys = for id <- ~w(main spare), do: %{value_id: id, value: "sk-ant-races-#{id}-0123456789"}
    {:ok, provider} = Connections.create_provider(scope, %{provider: "anthropic", keys: keys})
    values = Repo.all(from v in Value, where: v.secret_id == ^provider.secret_id)
    %{scope: scope, provider: provider, values: Map.new(values, &{&1.value_id, &1})}
  end

  defp key(%Value{} = value, name),
    do: %{
      name: name,
      secret_value_id: value.id,
      organisation_id: value.organisation_id,
      copy_set_at: value.value_set_at,
      copy_kept: true
    }

  defp item(credential, window, observed_at, status \\ "allowed") do
    %{
      credential: credential,
      window: window,
      status: status,
      resets_at: nil,
      utilization: nil,
      cooldown_until: nil,
      source: "provider",
      observed_at: observed_at
    }
  end

  defp states(ids),
    do:
      Repo.all(
        from s in State,
          where: s.secret_value_id in ^ids,
          order_by: [s.secret_value_id, s.window],
          select: {s.secret_value_id, s.window, s.observed_at}
      )

  test "two reports of the same keys at once both commit, and the newer state stays", ctx do
    keys = [key(ctx.values["main"], "model-1"), key(ctx.values["spare"], "model-2")]
    windows = ~w(five_hour seven_day requests tokens)
    first = ~U[2026-11-11 10:00:00.000000Z]
    second = ~U[2026-11-11 10:00:01.000000Z]

    items = fn at ->
      for credential <- ~w(model-1 model-2), window <- windows, do: item(credential, window, at)
    end

    # The two reports list the items in opposite orders: written in their item order,
    # each would take its rows' locks in the other's reverse order.
    for _round <- 1..10 do
      assert [:ok, :ok] =
               together([
                 fn -> ModelKeys.record(keys, items.(first), DateTime.utc_now()) end,
                 fn ->
                   ModelKeys.record(keys, Enum.reverse(items.(second)), DateTime.utc_now())
                 end
               ])
    end

    ids = Enum.map(keys, & &1.secret_value_id)
    rows = states(ids)
    assert length(rows) == 8
    assert Enum.all?(rows, fn {_id, _window, at} -> at == second end)
  end

  test "a report while its key is deleted leaves that key out and writes the others",
       ctx do
    main = ctx.values["main"]
    spare = ctx.values["spare"]
    keys = [key(main, "model-1"), key(spare, "model-2")]
    at = ~U[2026-11-11 10:00:00.000000Z]
    items = [item("model-1", "five_hour", at), item("model-2", "five_hour", at)]

    # The deletion holds the key's row until it commits; the report waits for it.
    {held, holder} =
      hold(fn ->
        {:ok, _provider} = Connections.delete_provider_key(ctx.scope, ctx.provider, "spare")
      end)

    report = start(fn -> ModelKeys.record(keys, items, DateTime.utc_now()) end)
    await_blocked(report.backend, holder)
    commit(held)

    assert Task.await(report.task) == :ok
    assert states([spare.id]) == []
    assert [{_id, "five_hour", ^at}] = states([main.id])
  end

  # The rows of the provider's keys, in the order a scan of the table reads them.
  defp stored_order(secret_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT id FROM secret_values WHERE secret_id = $1 ORDER BY ctid",
        [Ecto.UUID.dump!(secret_id)]
      )

    for [id] <- rows, do: Ecto.UUID.load!(id)
  end

  test "a provider's deletion while a secrets request locks its keys does not deadlock", ctx do
    # The key read first, by the scan and by its value id, gets the higher row id: a
    # cascade that deletes in that order would hold it while it waits for the lower one.
    [low, high] = Enum.sort([Ecto.UUID.generate(), Ecto.UUID.generate()])

    for {value_id, id} <- [{"main", high}, {"spare", low}] do
      {1, _} =
        Repo.update_all(from(v in Value, where: v.id == ^ctx.values[value_id].id), set: [id: id])
    end

    assert stored_order(ctx.provider.secret_id) == [high, low]

    # A secrets request takes the keys' rows `FOR KEY SHARE` by id
    # (`Apiary.ModelKeys.keep_copies/2`): the lower first.
    lock = fn id ->
      Repo.all(from v in Value, where: v.id == ^id, lock: "FOR KEY SHARE", select: v.id)
    end

    {held, holder} = hold(fn -> lock.(low) end)
    deletion = start(fn -> Connections.delete_provider(ctx.scope, ctx.provider) end)
    await_blocked(deletion.backend, holder)

    # The deletion holds no key's row yet, so the request takes the higher one.
    assert continue(held, fn -> lock.(high) end) == [high]
    commit(held)

    assert {:ok, _deleted} = Task.await(deletion.task)
    assert Repo.all(from v in Value, where: v.id in ^[low, high]) == []
  end
end
