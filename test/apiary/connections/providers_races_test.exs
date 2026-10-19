defmodule Apiary.Connections.ProvidersRacesTest do
  # A model provider deleted while one of its keys is deleted, in each order. Each side
  # runs on a connection apart, outside the SQL sandbox, so each commits and each waits on
  # the other's locks as it would in production. Not async: what these tests commit is
  # visible to every other test while they run, and they delete it again before they end.
  #
  # The rule under test (`Apiary.Connections`, `Apiary.Secrets`): both take the
  # integrations lock and the provider's row, then the organisation's lock for its secrets
  # and the keys' secret row. So the two take turns: a key is deleted from a provider that
  # is there, and the keys go only with their provider.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{Connections, Repo, Secrets}
  alias Apiary.Connections.Connection
  alias Apiary.Secrets.{Secret, Value}

  @moduletag needs: :factory

  setup_all :clean_up_leftovers
  setup :setup_races

  defp provider!(scope) do
    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "openrouter",
        keys: [%{value_id: "main", value: "x"}, %{value_id: "spare", value: "y"}]
      })

    provider
  end

  defp gone?(%Connection{id: id, secret_id: secret_id}),
    do:
      not Repo.exists?(from c in Connection, where: c.id == ^id) and
        not Repo.exists?(from s in Secret, where: s.id == ^secret_id) and
        not Repo.exists?(from v in Value, where: v.secret_id == ^secret_id)

  test "the provider deleted first: the key's deletion waits, and finds it gone" do
    owner = sign_up()
    provider = provider!(owner.scope)

    {first, first_pid} = hold(fn -> Connections.delete_provider(owner.scope, provider) end)
    assert {:ok, %Connection{}} = first.result

    second = start(fn -> Connections.delete_provider_key(owner.scope, provider, "spare") end)

    await_blocked(second.backend, first_pid)
    commit(first)

    assert Task.await(second.task) == {:error, :not_found}
    assert gone?(provider)
  end

  test "the key deleted first: the provider's deletion waits, and takes the rest" do
    owner = sign_up()
    provider = provider!(owner.scope)

    {first, first_pid} =
      hold(fn -> Connections.delete_provider_key(owner.scope, provider, "spare") end)

    assert {:ok, %Connection{}} = first.result

    second = start(fn -> Connections.delete_provider(owner.scope, provider) end)

    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:ok, %Connection{}} = Task.await(second.task)
    assert gone?(provider)
  end

  test "the generic deletion of the keys' secret is not found, while the provider is there" do
    owner = sign_up()
    provider = provider!(owner.scope)

    assert Secrets.delete_secret(owner.scope, provider.secret) == {:error, :not_found}
    refute gone?(provider)
  end
end
