defmodule ApiaryWeb.AccessTest do
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Accounts.Scope

  defp socket(scope),
    do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_scope: scope}}

  test "a member of the workspace mounts the page" do
    %{scope: owner} = sign_up_fixture()
    %{scope: member} = member_fixture(owner, :member)

    socket = socket(member)
    assert {:cont, ^socket} = ApiaryWeb.Access.on_mount(:"run.read", %{}, %{}, socket)
  end

  test "a scope without a membership there is a path that does not exist" do
    %{organisation: organisation, workspace: workspace} = sign_up_fixture()
    %{user: stranger} = sign_up_fixture()

    scope = %Scope{user: stranger, organisation: organisation, workspace: workspace}

    assert_raise ApiaryWeb.NotFound, fn ->
      ApiaryWeb.Access.on_mount(:"run.read", %{}, %{}, socket(scope))
    end
  end
end
