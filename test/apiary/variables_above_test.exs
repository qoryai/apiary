defmodule Apiary.VariablesAboveTest do
  # Not async: the level above is the edition's answer, set for a test through the
  # configuration `Apiary.Policy.Above.for_workspace/1` reads, and put back after it.
  use Apiary.DataCase, async: false

  @moduletag needs: :security

  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias Apiary.Policy.Above
  alias Apiary.Runs.Target
  alias Apiary.Variables
  alias Apiary.Variables.{Resolution, Variable}

  setup do
    previous = Application.get_env(:apiary, Above)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:apiary, Above, previous),
        else: Application.delete_env(:apiary, Above)
    end)

    Application.put_env(:apiary, Above,
      answer: fn _workspace ->
        %Above{
          id: Ecto.UUID.generate(),
          name: "Example level",
          slug: "example",
          variables: [
            %Variable{name: "REGION", value: "eu-west-1", locked: true},
            %Variable{name: "Log_Level", value: "info"},
            %Variable{name: "QORY_SNEAKY", value: "x"}
          ]
        }
      end
    )

    scope = sign_up_fixture().scope

    site =
      Repo.insert!(%Target{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        system: "github.example",
        path: "example/site",
        first_seen_at: DateTime.utc_now()
      })

    %{scope: scope, site: site}
  end

  test "the level above is resolved first, its locks hold, and its QORY_ names are left out",
       %{scope: scope, site: site} do
    {:ok, resolution} = Variables.resolve(scope, :workspace)

    assert Resolution.values(resolution) == %{
             "REGION" => "eu-west-1",
             "Log_Level" => "info"
           }

    {:ok, _} = Variables.create_variable(scope, :workspace, %{name: "Log_Level", value: "debug"})
    {:ok, _} = Variables.create_variable(scope, site, %{name: "Log_Level", value: "trace"})

    {:ok, resolution} = Variables.resolve(scope, site)
    assert Resolution.values(resolution) == %{"REGION" => "eu-west-1", "Log_Level" => "trace"}
    assert %{set_by: :above, locked_by: :above} = Resolution.entry(resolution, "region")
  end

  test "a name the level above locks is set at no level below", %{scope: scope, site: site} do
    for holder <- [:workspace, site], name <- ["REGION", "region"] do
      assert {:error, changeset} =
               Variables.create_variable(scope, holder, %{name: name, value: "us-east-1"})

      assert {"is locked above, so it cannot be set here", _} = changeset.errors[:name]
    end
  end

  test "another spelling of a name the level above sets is refused", %{scope: scope, site: site} do
    for holder <- [:workspace, site] do
      assert {:error, changeset} =
               Variables.create_variable(scope, holder, %{name: "LOG_LEVEL", value: "debug"})

      assert {"is %{name} elsewhere in this workspace: use the same spelling",
              [name: "Log_Level"]} =
               changeset.errors[:name]
    end
  end

  test "a workspace's own value that hid a larger one above is not deleted past the limits",
       %{scope: scope} do
    above = Above.for_workspace(scope.workspace)
    big = %Variable{name: "BIG", value: String.duplicate("a", 4096)}
    Application.put_env(:apiary, Above, answer: fn _workspace -> %{above | variables: [big]} end)

    # BIG's 4 bytes in place of the 4099 above leave room, which the workspace fills:
    # 4 + 15 × (4 + 4096) + 4 + 4028 = 65536.
    {:ok, own} = Variables.create_variable(scope, :workspace, %{name: "BIG", value: "x"})

    for i <- 10..24 do
      {:ok, _} =
        Variables.create_variable(scope, :workspace, %{
          name: "V_#{i}",
          value: String.duplicate("v", 4096)
        })
    end

    {:ok, _} =
      Variables.create_variable(scope, :workspace, %{
        name: "FILL",
        value: String.duplicate("f", 4028)
      })

    {:ok, resolution} = Variables.resolve(scope, :workspace)
    assert Resolution.size(resolution).bytes == 65_536

    # Deleted, the level above's BIG would take the workspace to 69631 bytes.
    assert {:error, %Ecto.Changeset{} = changeset} = Variables.delete_variable(scope, own)
    assert {"would give a run more than 64 KiB of variables", []} = changeset.errors[:value]
    assert Repo.reload!(own)

    changes =
      Repo.all(from e in Entry, where: e.subject_kind == "variable", select: e.details)

    refute Enum.any?(changes, &(&1["change"] == "deleted"))
  end

  test "a level with variables and no policy is still resolved first, and its locks hold",
       %{scope: scope, site: site} do
    above = Above.for_workspace(scope.workspace)
    variables_only = %{above | policy: false}
    Application.put_env(:apiary, Above, answer: fn _workspace -> variables_only end)

    {:ok, resolution} = Variables.resolve(scope, site)
    assert Resolution.values(resolution) == %{"REGION" => "eu-west-1", "Log_Level" => "info"}
    assert %{set_by: :above, locked_by: :above} = Resolution.entry(resolution, "region")

    assert {:error, changeset} =
             Variables.create_variable(scope, site, %{name: "REGION", value: "us-east-1"})

    assert {"is locked above, so it cannot be set here", _} = changeset.errors[:name]
    assert Apiary.Policy.effective(scope, nil).above == nil
  end
end
