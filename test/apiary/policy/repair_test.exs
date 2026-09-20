defmodule Apiary.Policy.RepairTest do
  @moduledoc """
  The one-off repair of `20260925000300`: the baselines a page's read once rendered and
  stored, with no change behind them, are deleted and the versions after them move down.
  """
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  Code.require_file(
    "priv/repo/migrations/20260925000300_delete_baselines_rendered_by_reads.exs",
    File.cwd!()
  )

  alias Apiary.Policy
  alias Apiary.Policy.{Change, RunConfiguration}
  alias Apiary.Repo.Migrations.DeleteBaselinesRenderedByReads, as: Migration

  # What a read used to store: the empty observe baseline, as the render makes it.
  defp orphan!(scope) do
    document = Apiary.Policy.Render.document(%Apiary.Policy.Effective{})

    Repo.insert!(%RunConfiguration{
      organisation_id: scope.organisation.id,
      hive_id: scope.hive.id,
      version: 1,
      document: document,
      digest: Apiary.Policy.Render.digest(document),
      rendered_at: DateTime.utc_now()
    })
  end

  defp repair!,
    do: Repo.transaction(fn -> for sql <- Migration.repair_sql(), do: Repo.query!(sql) end)

  defp versions(scope) do
    Repo.all(
      from c in RunConfiguration,
        where: c.hive_id == ^scope.hive.id and is_nil(c.repository_id),
        order_by: c.version,
        select: {c.version, not is_nil(c.policy_change_id)}
    )
  end

  test "an unmanaged hive's stored baseline goes, and its first change is version 1" do
    %{scope: scope} = sign_up_fixture()
    orphan!(scope)

    repair!()
    assert versions(scope) == []

    {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
    assert versions(scope) == [{1, true}]
  end

  test "a managed hive whose first change became version 2 is renumbered from 1" do
    %{scope: scope} = sign_up_fixture()
    orphan!(scope)
    {:ok, _} = Policy.set_mode(scope, "enforce")
    {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})

    repository =
      Repo.insert!(%Apiary.Runs.Repository{
        organisation_id: scope.organisation.id,
        hive_id: scope.hive.id,
        forge: "f",
        path: "p",
        first_seen_at: DateTime.utc_now()
      })

    {:ok, _} = Policy.allow(scope, repository, %{host: "mcp.example"})
    assert versions(scope) == [{1, false}, {2, true}, {3, true}]

    repair!()

    assert versions(scope) == [{1, true}, {2, true}]

    assert Repo.all(
             from c in Change,
               where: is_nil(c.repository_id),
               order_by: c.inserted_at,
               select: c.version_after
           ) == [1, 2]

    # The repository's own versions are untouched, and the repair is idempotent.
    assert [%{version: 1}] =
             Repo.all(from c in RunConfiguration, where: c.repository_id == ^repository.id)

    repair!()
    assert versions(scope) == [{1, true}, {2, true}]
    assert {:ok, %{version: 2}} = Policy.current_configuration(scope, nil)
    assert {:ok, %{version: 1}} = Policy.get_configuration(scope, nil, 1)
  end

  test "the only version of a managed baseline stays, whatever made it" do
    %{scope: scope} = sign_up_fixture()
    orphan!(scope)
    # The first change rendered the same bytes: no version 2, and version 1 is what is served.
    {:ok, _} = Policy.deny(scope, nil, %{host: "ads.example"})
    assert versions(scope) == [{1, false}]

    repair!()
    assert versions(scope) == [{1, false}]
    assert {:ok, %{version: 1}} = Policy.current_configuration(scope, nil)
  end
end
