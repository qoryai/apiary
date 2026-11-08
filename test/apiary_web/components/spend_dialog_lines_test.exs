defmodule ApiaryWeb.SpendDialogLinesTest do
  use Apiary.DataCase, async: true

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias ApiaryWeb.SpendDialog

  # The pool of a run's machine in the line on what starts (`SpendDialog.test_line/1`):
  # none, one or several pools serve the workspace.
  test "no pool: a machine; one pool: a machine of the pool; several: a machine of a pool in the workspace" do
    scope = scope_fixture()

    assert SpendDialog.test_line(scope.workspace) ==
             "Starts a run of qory's hello example on a machine. The run uses model tokens."

    pool_fixture(scope, name: "build-eu")

    assert SpendDialog.test_line(scope.workspace) ==
             "Starts a run of qory's hello example on a machine of build-eu. " <>
               "The run uses model tokens."

    pool_fixture(scope, name: "build-us")

    assert SpendDialog.test_line(scope.workspace) ==
             "Starts a run of qory's hello example on a machine of a pool in " <>
               "#{scope.workspace.name}. The run uses model tokens."
  end
end
