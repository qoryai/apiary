defmodule ApiaryProWeb.RunLogControllerTest do
  @moduledoc """
  A run's log under workspace access: a member removed from the workspace, while still a
  member of the organisation, reads its runs' logs no more.
  """
  use ApiaryWeb.ConnCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Runs.Projector

  defp run_with_log(scope) do
    run = run_fixture(scope)
    events_fixture(run, record())
    {:ok, run} = Projector.project(run)
    run
  end

  test "a member removed from the workspace is not found, as a workspace that does not exist",
       %{conn: conn} do
    %{scope: owner} = sign_up_fixture()
    run = run_with_log(owner)
    %{user: user, membership: membership} = member_fixture(owner, :member)
    conn = log_in_user(conn, user)
    path = ~p"/#{owner.organisation}/#{owner.workspace}/runs/#{run}/log"

    assert conn |> get(path) |> response(200)

    {:ok, _} = ApiaryPro.WorkspaceAccess.remove(owner, membership.id, owner.workspace.id)

    assert conn |> get(path) |> response(404)
  end
end
