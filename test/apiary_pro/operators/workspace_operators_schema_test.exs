defmodule ApiaryPro.Operators.WorkspaceOperatorsSchemaTest do
  # The database's rules of an operated workspace, and the changeset beside them: the
  # operator of a workspace (`workspace_operators`). The rules are checked with raw SQL, so that no changeset stands between the write and the
  # database; the changeset tests check that each constraint violation becomes an error.
  #
  # Async: each test writes fresh organisations, and an operator is a fresh organisation
  # whose tenant row is set to the kind `operator`, never the suite's instance
  # organisation.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations.Workspace
  alias ApiaryPro.Operators.WorkspaceOperator

  # A fresh organisation with its first workspace, as sign-up makes them.
  defp organisation! do
    %{organisation: organisation, workspace: workspace} = sign_up_fixture()
    %{organisation: organisation, workspace: workspace}
  end

  # A fresh organisation of the kind `operator`.
  defp operator! do
    %{organisation: organisation} = organisation!()
    kind!(organisation.id, "operator")
    organisation
  end

  defp kind!(id, kind) do
    assert %{num_rows: 1} =
             Repo.query!("UPDATE tenants SET kind = $2 WHERE organisation_id = $1", [
               dump(id),
               kind
             ])
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  defp refused(constraint, fun), do: assert_raise(Postgrex.Error, ~r/#{constraint}/, fun)

  defp link!(%Workspace{} = workspace, operator_id) do
    Repo.query!(
      "INSERT INTO workspace_operators " <>
        "(organisation_id, workspace_id, operator_id, since, inserted_at, updated_at) " <>
        "VALUES ($1, $2, $3, now(), now(), now())",
      [dump(workspace.organisation_id), dump(workspace.id), dump(operator_id)]
    )
  end

  defp count(table, column, id) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table} WHERE #{column} = $1", [dump(id)])
    n
  end

  defp delete_organisation!(id),
    do: Repo.query!("DELETE FROM organisations WHERE id = $1", [dump(id)])

  describe "workspace_operators" do
    test "a workspace has at most one operator" do
      %{workspace: workspace} = organisation!()
      operator = operator!()

      link!(workspace, operator.id)
      refused("workspace_operators_pkey", fn -> link!(workspace, operator!().id) end)
      refused("workspace_operators_pkey", fn -> link!(workspace, operator.id) end)
    end

    test "an operator operates workspaces of several organisations, and one has several operators" do
      operator = operator!()
      %{organisation: first, workspace: w1} = organisation!()
      %{workspace: w2} = organisation!()
      w3 = workspace_fixture(first)

      link!(w1, operator.id)
      link!(w2, operator.id)
      link!(w3, operator!().id)

      assert count("workspace_operators", "operator_id", operator.id) == 2
      assert count("workspace_operators", "organisation_id", first.id) == 2
    end

    test "the operator is an organisation of the kind operator" do
      %{workspace: workspace} = organisation!()
      %{organisation: ordinary} = organisation!()

      for operator_id <- [ordinary.id, Ecto.UUID.generate()] do
        refused("workspace_operators_operator_fkey", fn -> link!(workspace, operator_id) end)
      end
    end

    test "an operator does not operate a workspace of its organisation" do
      operator = operator!()
      workspace = workspace_fixture(operator)

      refused("workspace_operators_not_its_organisation", fn -> link!(workspace, operator.id) end)
    end

    test "the workspace is one of the row's organisation" do
      %{workspace: workspace} = organisation!()
      %{organisation: other} = organisation!()
      operator = operator!()

      refused("workspace_operators_workspace_id_fkey", fn ->
        link!(%{workspace | organisation_id: other.id}, operator.id)
      end)
    end

    test "the row goes with its workspace and with its organisation" do
      operator = operator!()
      %{organisation: client, workspace: w1} = organisation!()
      w2 = workspace_fixture(client)
      link!(w1, operator.id)
      link!(w2, operator.id)

      Repo.query!("DELETE FROM workspaces WHERE id = $1", [dump(w1.id)])
      assert count("workspace_operators", "workspace_id", w1.id) == 0
      assert count("workspace_operators", "workspace_id", w2.id) == 1

      delete_organisation!(client.id)
      assert count("workspace_operators", "operator_id", operator.id) == 0
    end

    test "an operator keeps its kind and its row while it operates a workspace" do
      operator = operator!()
      %{workspace: workspace} = organisation!()
      link!(workspace, operator.id)

      refused("workspace_operators_operator_fkey", fn -> kind!(operator.id, "organisation") end)
      refused("workspace_operators_operator_fkey", fn -> delete_organisation!(operator.id) end)

      Repo.query!("DELETE FROM workspace_operators WHERE workspace_id = $1", [dump(workspace.id)])
      kind!(operator.id, "organisation")
    end

    test "the changeset writes a link and turns each constraint violation into an error" do
      operator = operator!()
      %{workspace: workspace} = organisation!()
      since = ~U[2026-11-13 09:00:00.000000Z]

      assert {:ok, link} =
               workspace
               |> WorkspaceOperator.create_changeset(operator.id, since)
               |> Repo.insert()

      assert %{since: ^since} = link
      assert link.organisation_id == workspace.organisation_id

      assert {:error, changeset} =
               workspace
               |> WorkspaceOperator.create_changeset(operator!().id, since)
               |> Repo.insert()

      assert {_message, constraint: :unique, constraint_name: "workspace_operators_pkey"} =
               changeset.errors[:workspace_id]

      %{workspace: other} = organisation!()
      %{organisation: ordinary} = organisation!()

      assert {:error, changeset} =
               other
               |> WorkspaceOperator.create_changeset(ordinary.id, since)
               |> Repo.insert()

      assert {_message, constraint: :foreign, constraint_name: _} = changeset.errors[:operator_id]

      operators_workspace = workspace_fixture(operator)

      assert {:error, changeset} =
               operators_workspace
               |> WorkspaceOperator.create_changeset(operator.id, since)
               |> Repo.insert()

      assert {_message, constraint: :check, constraint_name: _} = changeset.errors[:operator_id]
    end
  end
end
