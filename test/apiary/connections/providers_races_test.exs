defmodule Apiary.Connections.ProvidersRacesTest do
  # A model provider deleted while the secret of its keys is deleted, in each order. Each
  # side runs on a connection apart, outside the SQL sandbox, so each commits and each
  # waits on the other's locks as it would in production. Not async: what these tests
  # commit is visible to every other test while they run, and they delete it again before
  # they end.
  #
  # The rule under test (`Apiary.Connections`, `Apiary.Secrets`): a provider's deletion
  # takes the integrations lock, the provider's row, then the organisation's lock for its
  # secrets and the secret's row; a secret's deletion takes the lock for its secrets and
  # the secret's row, then reads what uses the secret. So the two take turns, and the
  # secret goes only with its provider.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{Connections, Repo, Secrets}
  alias Apiary.Connections.Connection
  alias Apiary.Secrets.Secret

  @moduletag needs: :factory

  setup_all :clean_up_leftovers
  setup :setup_races

  defp provider!(scope) do
    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "openrouter",
        keys: [%{value_id: "main", value: "x"}]
      })

    provider
  end

  defp gone?(%Connection{id: id, secret_id: secret_id}),
    do:
      not Repo.exists?(from c in Connection, where: c.id == ^id) and
        not Repo.exists?(from s in Secret, where: s.id == ^secret_id)

  test "the provider deleted first: the secret's deletion waits, and finds it gone" do
    owner = sign_up()
    provider = provider!(owner.scope)

    {first, first_pid} = hold(fn -> Connections.delete_provider(owner.scope, provider) end)
    assert {:ok, %Connection{}} = first.result

    second = start(fn -> Secrets.delete_secret(owner.scope, provider.secret) end)

    await_blocked(second.backend, first_pid)
    commit(first)

    assert Task.await(second.task) == {:error, :not_found}
    assert gone?(provider)
  end

  test "the secret deleted first: refused while the provider links it, then the provider goes with it" do
    owner = sign_up()
    provider = provider!(owner.scope)

    {first, first_pid} = hold(fn -> Secrets.delete_secret(owner.scope, provider.secret) end)

    assert {:error, {:in_use, [%{kind: :model_provider, id: id}]}} = first.result
    assert id == provider.public_id

    second = start(fn -> Connections.delete_provider(owner.scope, provider) end)

    # The refused deletion holds its locks until its transaction ends, rolled back.
    await_blocked(second.backend, first_pid)
    send(first.pid, :commit)
    assert Task.await(first.task) == {:error, :rollback}

    assert {:ok, %Connection{}} = Task.await(second.task)
    assert gone?(provider)
  end
end
