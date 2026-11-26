defmodule Apiary.Connections.AddKeyRacesTest do
  # Two model provider keys of one key group added at once (`Apiary.Connections.add_key/2`).
  # Each side runs on a connection apart, outside the SQL sandbox, so each commits and each
  # waits on the other's locks as it would in production. Not async: what these tests
  # commit is visible to every other test while they run, and they delete it again before
  # they end.
  #
  # The rule under test: an add takes the organisation's integrations lock before it reads
  # the key group. So the second add waits for the first, then finds the provider the first
  # made, and the two keys are values of one provider, key-1 and key-2.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{Connections, Repo}
  alias Apiary.Connections.Connection
  alias Apiary.Secrets.Value

  @moduletag needs: :factory

  setup_all :clean_up_leftovers
  setup :setup_races

  defp add(scope),
    do:
      Connections.add_key(scope, %{
        "provider" => "anthropic",
        "value" => "sk-ant-race-0123456789abcdef",
        "applies_to" => "all"
      })

  test "the second add waits for the first, and adds its key to the provider the first made" do
    owner = sign_up()

    {first, first_pid} = hold(fn -> add(owner.scope) end)
    assert {:ok, %Connection{} = provider, "key-1"} = first.result

    second = start(fn -> add(owner.scope) end)

    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:ok, %Connection{id: id}, "key-2"} = Task.await(second.task)
    assert id == provider.id

    assert Repo.all(
             from c in Connection,
               where: c.organisation_id == ^owner.scope.organisation.id,
               select: c.id
           ) == [provider.id]

    assert Repo.all(
             from v in Value,
               where: v.secret_id == ^provider.secret_id,
               order_by: v.value_id,
               select: v.value_id
           ) == ["key-1", "key-2"]
  end
end
