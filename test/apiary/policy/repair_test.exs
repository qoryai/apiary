defmodule Apiary.Policy.RepairTest do
  @moduledoc """
  The one-off repair of `20260925000300`: the baselines a page's read once rendered and
  stored, with no change behind them, are deleted and the versions after them move down.
  """
  # Not async: the repair's statements are the database's whole, not one workspace's, and
  # make a temporary table; they run as the migration runs, alone.
  use Apiary.DataCase, async: false

  # The security policy: left out of a run without the security feature.
  @moduletag needs: :security

  import Apiary.OrganisationsFixtures

  Code.require_file(
    "priv/repo/migrations/20260925000300_delete_baselines_rendered_by_reads.exs",
    File.cwd!()
  )

  alias Apiary.Policy
  alias Apiary.Policy.RunConfiguration
  alias Apiary.Repo.Migrations.DeleteBaselinesRenderedByReads, as: Migration

  # What a read used to store: the empty observe baseline, as the render makes it.
  defp orphan!(scope) do
    document = Apiary.Policy.Render.document(%Apiary.Policy.Effective{})

    Repo.insert!(%RunConfiguration{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      version: 1,
      document: document,
      digest: Apiary.Policy.Render.digest(document),
      rendered_at: DateTime.utc_now()
    })
  end

  # The repair's SQL names `repository_id`, since renamed `target_id` by 20260927000100,
  # and `hive_id`, since renamed `workspace_id` by 20260929000100.
  defp repair! do
    Repo.transaction(fn ->
      for sql <- Migration.repair_sql() do
        sql
        |> String.replace("repository_id", "target_id")
        |> String.replace("hive_id", "workspace_id")
        |> Repo.query!()
      end
    end)
  end

  defp versions(scope) do
    Repo.all(
      from c in RunConfiguration,
        where: c.workspace_id == ^scope.workspace.id and is_nil(c.target_id),
        order_by: c.version,
        select: {c.version, not is_nil(c.audit_entry_id)}
    )
  end

  test "an unmanaged workspace's stored baseline goes, and its first change is version 1" do
    %{scope: scope} = sign_up_fixture()
    orphan!(scope)

    repair!()
    assert versions(scope) == []

    {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
    assert versions(scope) == [{1, true}]
  end

  test "a managed workspace whose first change became version 2 is renumbered from 1" do
    %{scope: scope} = sign_up_fixture()
    orphan!(scope)
    {:ok, _} = Policy.set_mode(scope, "enforce")
    {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})

    target =
      Repo.insert!(%Apiary.Runs.Target{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        system: "f",
        path: "p",
        first_seen_at: DateTime.utc_now()
      })

    {:ok, _} = Policy.allow(scope, target, %{host: "mcp.example"})
    assert versions(scope) == [{1, false}, {2, true}, {3, true}]

    repair!()

    assert versions(scope) == [{1, true}, {2, true}]

    assert Repo.query!("""
           SELECT version_after FROM policy_changes
           WHERE target_id IS NULL ORDER BY inserted_at, id
           """).rows == [[1], [2]]

    # The target's own versions are untouched, and the repair is idempotent.
    assert [%{version: 1}] =
             Repo.all(from c in RunConfiguration, where: c.target_id == ^target.id)

    repair!()
    assert versions(scope) == [{1, true}, {2, true}]
    assert {:ok, %{version: 2}} = Policy.current_configuration(scope, nil)
    assert {:ok, %{version: 1}} = Policy.get_configuration(scope, nil, 1)
  end

  test "the only version of a managed baseline stays, whatever made it" do
    %{scope: scope} = sign_up_fixture()
    orphan!(scope)
    # The first change rendered the same bytes (a credential deny is not in the document):
    # no version 2, and version 1 is what is served.
    {:ok, _} = Policy.deny(scope, nil, %{kind: "credential", name: "model"})
    assert versions(scope) == [{1, false}]

    repair!()
    assert versions(scope) == [{1, false}]
    assert {:ok, %{version: 1}} = Policy.current_configuration(scope, nil)
  end
end
