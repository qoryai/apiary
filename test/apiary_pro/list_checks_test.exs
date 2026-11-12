defmodule ApiaryPro.ListChecksTest do
  @moduledoc """
  The checks of a list's rows read no tenant for each row. A scope of a person's
  membership, as `Apiary.Organisations.load_scope/2` and
  `Apiary.Organisations.load_home_scope/2` put it, has the organisation's tenant on its
  organisation, read once for the scope (`c:Apiary.Edition.put_organisation/1`), as a scope
  of the path has it (`c:Apiary.Edition.reach/1`): five rows take the queries of one.
  """
  use Apiary.DataCase, async: true

  # The rows are work items, which the factory reads.
  @moduletag needs: :factory

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Access, Organisations}
  alias Apiary.Accounts.Scope

  # The queries this process runs during `fun`, counted on the repo's telemetry event.
  defp queries(fun) do
    handler = "list-checks-#{System.unique_integer([:positive])}"
    me = self()

    :ok =
      :telemetry.attach(
        handler,
        [:apiary, :repo, :query],
        fn _event, _measurements, _meta, _config -> if self() == me, do: send(me, :query) end,
        nil
      )

    try do
      fun.()
      count_queries(0)
    after
      :telemetry.detach(handler)
    end
  end

  defp count_queries(n) do
    receive do
      :query -> count_queries(n + 1)
    after
      0 -> n
    end
  end

  # Five work items of the scope's workspace, from one connection.
  defp rows(scope) do
    connection = ticket_connection_fixture(scope)

    for n <- 1..5 do
      work_item_fixture(scope, %{connection_id: connection.id, external_ref: "acme/shop##{n}"})
    end
  end

  # Each row checked as a list checks its rows, and the queries the checks took.
  defp check(scope, rows) do
    {queries(fn -> Enum.map(rows, &Access.can?(scope, :"work_item.read", &1)) end),
     Enum.map(rows, &Access.can?(scope, :"work_item.read", &1))}
  end

  # The scopes of `user` in their membership in `organisation`, as the core loads them
  # without the edition's reach.
  defp membership_scopes(user, organisation, workspace) do
    [
      Organisations.load_scope(Scope.for_user(user), organisation.id),
      Organisations.load_home_scope(Scope.for_user(user), workspace.id)
    ]
  end

  test "an organisation's owner: five rows take the queries of one" do
    %{user: user, organisation: organisation, workspace: workspace, scope: scope} =
      sign_up_fixture()

    rows = rows(scope)

    for loaded <- membership_scopes(user, organisation, workspace) do
      assert loaded.organisation.id == organisation.id
      assert loaded.workspace.id == workspace.id
      {one, [true]} = check(loaded, Enum.take(rows, 1))
      assert check(loaded, rows) == {one, List.duplicate(true, 5)}
    end
  end

  @tag needs: [:factory, :managed_organisations]
  test "a client's owner: five rows take the queries of one" do
    operator = operator_fixture()
    client = client_fixture(operator.scope)
    rows = rows(client.owner.scope)

    for loaded <- membership_scopes(client.owner.user, client.organisation, client.workspace) do
      assert loaded.organisation.id == client.organisation.id
      assert loaded.workspace.id == client.workspace.id
      {one, [true]} = check(loaded, Enum.take(rows, 1))
      assert check(loaded, rows) == {one, List.duplicate(true, 5)}
    end
  end
end
