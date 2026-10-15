defmodule Apiary.ConnectionsRacesTest do
  # Two writes to one organisation's integrations, racing. Each side runs on a connection
  # of its own, outside the SQL sandbox, so each commits and each waits on the other's
  # locks as it would in production. Not async: what these tests commit is visible to
  # every other test while they run, and they delete it again before they end.
  #
  # The rule under test (`Apiary.Connections`, Who, and the trail): every write takes the
  # organisation's integrations lock, an advisory lock on the organisation, after the
  # organisation's row and the membership. Two writes that would overlap, even from two
  # workspaces, take turns: the second waits for the first, then its overlap check sees
  # it, and it is refused. A write to another organisation does not wait.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{Connections, OrganisationsFixtures, Repo}
  alias Apiary.Connections.Connection

  @moduletag needs: :secrets

  setup_all :clean_up_leftovers
  setup :setup_races

  test "two writes that would overlap take turns, and the second is refused" do
    %{scope: scope, user: user} = sign_up()
    site = OrganisationsFixtures.workspace_fixture(scope.organisation, "Site")
    at_site = OrganisationsFixtures.workspace_scope(user, site)

    {first, first_pid} =
      hold(fn ->
        Connections.create_runtime(scope, %{
          runtime: "claude",
          applies_to: "selected",
          workspace_ids: [scope.workspace.id, site.id]
        })
      end)

    assert {:ok, %Connection{} = created} = first.result

    second =
      start(fn ->
        Connections.create_runtime(at_site, %{
          runtime: "claude",
          applies_to: "selected",
          workspace_ids: [site.id]
        })
      end)

    await_blocked(second.backend, first_pid)
    commit(first)

    assert Task.await(second.task) == {:error, {:overlap, [created.public_id]}}

    assert Repo.aggregate(
             from(c in Connection, where: c.organisation_id == ^scope.organisation.id),
             :count
           ) == 1
  end

  test "a write to another organisation does not wait" do
    %{scope: scope} = sign_up()
    %{scope: other} = sign_up()

    {first, _first_pid} =
      hold(fn -> Connections.create_runtime(scope, %{runtime: "claude"}) end)

    assert {:ok, %Connection{}} = first.result

    second = start(fn -> Connections.create_runtime(other, %{runtime: "claude"}) end)
    assert {:ok, %Connection{}} = Task.await(second.task)

    commit(first)
  end
end
