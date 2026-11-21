defmodule Apiary.Connections.KeyNumbersTest do
  # The value id `key-<n>` that Apiary gives a model provider's key (`Apiary.Secrets.next_key_id/1`):
  # a number is never given twice, even after the key that had it is deleted, and two keys
  # added at once get two numbers. The two adds commit on connections apart, outside the
  # SQL sandbox, so the second waits on the first's lock as it would in production, so this
  # module is not async.
  use ExUnit.Case, async: false

  # A list in `needs:` is read by this hook (`Apiary.TestSetup`).
  @before_compile Apiary.TestSetup

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{Connections, Repo}
  alias Apiary.Secrets.{Secret, Value}

  @moduletag needs: [:factory, :secrets]

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    %{scope: scope} = sign_up()
    %{scope: scope}
  end

  defp provider!(scope, count) do
    keys = for n <- 1..count, do: %{value: "sk-ant-numbers-#{n}-0123456789"}
    {:ok, provider} = Connections.create_provider(scope, %{provider: "anthropic", keys: keys})
    provider
  end

  defp add!(scope, provider) do
    {:ok, _provider} =
      Connections.add_provider_key(scope, provider, %{
        value: "sk-ant-added-#{System.unique_integer([:positive])}-0123456789"
      })
  end

  defp value_ids(provider) do
    Repo.all(from v in Value, where: v.secret_id == ^provider.secret_id, select: v.value_id)
    |> Enum.sort()
  end

  defp counter(provider),
    do: Repo.one!(from s in Secret, where: s.id == ^provider.secret_id, select: s.last_key_number)

  test "the first key of a provider is key-1", %{scope: scope} do
    provider = provider!(scope, 1)

    assert value_ids(provider) == ["key-1"]
    assert counter(provider) == 1
  end

  test "a key added after the highest one was deleted gets a higher number", %{scope: scope} do
    provider = provider!(scope, 2)
    {:ok, _} = Connections.delete_provider_key(scope, provider, "key-2")
    assert value_ids(provider) == ["key-1"]

    add!(scope, provider)

    assert value_ids(provider) == ["key-1", "key-3"]
  end

  test "a key added after a middle one was deleted does not reuse its number",
       %{scope: scope} do
    provider = provider!(scope, 3)
    {:ok, _} = Connections.delete_provider_key(scope, provider, "key-2")

    add!(scope, provider)

    assert value_ids(provider) == ["key-1", "key-3", "key-4"]
  end

  test "two keys added at once get two numbers", %{scope: scope} do
    provider = provider!(scope, 1)

    {held, holder} = hold(fn -> add!(scope, provider) end)
    second = start(fn -> add!(scope, provider) end)
    await_blocked(second.backend, holder)
    commit(held)
    assert {:ok, _provider} = Task.await(second.task)

    assert value_ids(provider) == ["key-1", "key-2", "key-3"]
    assert counter(provider) == 3
  end
end
