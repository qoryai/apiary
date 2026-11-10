defmodule Apiary.Release.FirstVersionsTest do
  @moduledoc """
  At boot, `Apiary.Release.FirstVersions` writes version 1 of each workspace that has none,
  then renders every workspace again, so a version that an earlier release wrote gains a
  runtime's host once, as a change by no person. `bin/migrate` (`Apiary.Release.migrate/1`)
  runs the same two steps once the key check passes.
  """
  # The boot's step reads every workspace, so the test is not async.
  use ApiaryWeb.ConnCase, async: false

  @moduletag :capture_log
  @moduletag needs: :security

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.ConnectionsFixtures, only: [target!: 2]
  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Apiary.Audit.Entry
  alias Apiary.Kinds.{Runtime, Runtimes}
  alias Apiary.Organisations.Workspace
  alias Apiary.{KeyCheck, KeyDerivation, Policy, Release, Repo}
  alias Apiary.Policy.{Above, Change, Rule, RunConfiguration}
  alias Apiary.Release.FirstVersions

  @host "api.anthropic.com"

  setup :register_and_log_in_user

  defp stub!(runtimes), do: :ok = Runtimes.put_test_list(runtimes)

  defp runtime(name, hosts),
    do: %Runtime{name: name, title: String.capitalize(name), egress_hosts: hosts}

  defp egress(scope, holder) do
    {:ok, %RunConfiguration{document: document}} = Policy.current_configuration(scope, holder)
    Jason.decode!(document)["security_policy"]["egress"]
  end

  defp versions(scope, holder), do: Policy.list_configurations(scope, holder).total

  defp rows(%Workspace{id: id}) do
    Repo.all(from c in RunConfiguration, where: c.workspace_id == ^id, order_by: c.version)
  end

  # The newest version of the workspace's baseline.
  defp newest(%Workspace{id: id}) do
    Repo.one(
      from c in RunConfiguration,
        where: c.workspace_id == ^id and is_nil(c.target_id),
        order_by: [desc: c.version],
        limit: 1
    )
  end

  defp allow_first(%RunConfiguration{document: document}),
    do: Jason.decode!(document)["security_policy"]["egress"]["allow_first"]

  # Sets the level above each workspace for this test: `fun.(workspace)`.
  defp above!(fun) do
    on_exit(fn -> Application.delete_env(:apiary, Apiary.Policy.Above) end)
    Application.put_env(:apiary, Apiary.Policy.Above, answer: fun)
  end

  # A level above whose rules make a render pass the 1 MiB that a document may have, so
  # the render is refused.
  defp too_big_above do
    %Above{
      id: Ecto.UUID.generate(),
      name: "Northwind",
      slug: "northwind",
      rules:
        for n <- 1..11 do
          %Rule{
            id: Ecto.UUID.generate(),
            kind: "host",
            action: "allow",
            host: "h#{n}.example",
            paths: for(m <- 1..100, do: "/" <> String.duplicate("a", 1000) <> "/#{n}/#{m}"),
            locked: false
          }
        end
    }
  end

  # Three workspaces with version 1 and no runtime host, sorted by id, and the count of
  # the workspaces that have a version, the setup's included.
  defp three_workspaces!(scope) do
    stub!([runtime("claude", [])])
    created = for _n <- 1..3, do: workspace_fixture(scope.organisation)
    listed = Repo.one(from c in RunConfiguration, select: count(c.workspace_id, :distinct))
    {Enum.sort_by(created, & &1.id), listed}
  end

  # Records the keys the instance runs with, as its first boot does, then sets another
  # encryption secret. Returns the configuration to put back; the test's exit puts back
  # the key check's and the secret's.
  defp another_encryption_secret! do
    derivation = Application.get_env(:apiary, KeyDerivation)
    key_check = Application.get_env(:apiary, KeyCheck)

    on_exit(fn ->
      Application.put_env(:apiary, KeyDerivation, derivation)
      Application.put_env(:apiary, KeyCheck, key_check)
    end)

    assert KeyCheck.check() == :ok
    Application.put_env(:apiary, KeyDerivation, secret: :crypto.strong_rand_bytes(32))
    derivation
  end

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
  end

  test "gives each version a runtime's host once, by no person", %{conn: conn, scope: scope} do
    stub!([runtime("claude", [])])
    target = target!(scope, "acme/site")
    {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})
    {:ok, _rule} = Policy.allow(scope, target, %{host: "shop.example.com"})
    bare = scope.organisation |> workspace_fixture() |> no_policy_version!()

    refute Map.has_key?(egress(scope, nil), "allow_first")
    refute Map.has_key?(egress(scope, target), "allow_first")
    baseline = versions(scope, nil)
    kept = versions(scope, target)
    changes = Policy.list_changes(scope, nil).total

    stub!([runtime("claude", [@host])])

    totals = FirstVersions.run()

    assert egress(scope, nil)["allow_first"] == [@host]
    assert egress(scope, target)["allow_first"] == [@host]
    assert versions(scope, nil) == baseline + 1
    assert versions(scope, target) == kept + 1

    assert %{
             first_versions: %{written: 1, refused: 0, failed: 0},
             rerendered: %{versions: 2}
           } = totals

    %{items: [%Change{} = change | _], total: total} = Policy.list_changes(scope, nil)
    assert total == changes + 1
    assert change.action == "rerendered"
    assert change.changed_by_id == nil
    assert Repo.get!(Entry, change.id).worker == "Apiary.Release.FirstVersions"

    assert [%RunConfiguration{version: 1, document: document}] = rows(bare)
    assert Jason.decode!(document)["security_policy"]["egress"]["allow_first"] == [@host]

    {:ok, history, _html} = live(conn, workspace_path(scope, "/policy/history"))
    render_async(history, 5_000)
    assert text(history, "#history-list") =~ "Qory Apiary changed the policy"

    assert %{
             first_versions: %{written: 0, refused: 0, failed: 0},
             rerendered: %{versions: 0}
           } = FirstVersions.run()

    assert versions(scope, nil) == baseline + 1
    assert versions(scope, target) == kept + 1
    assert length(rows(bare)) == 1
  end

  test "renders the other workspaces when one workspace's render raises", %{scope: scope} do
    # Three workspaces with version 1 and no runtime host. The render goes in the order of
    # the workspace's id, so the first of them raises before the other two are rendered.
    # The setup's workspace has the host from its creation, and keeps its version.
    stub!([runtime("claude", [])])
    created = for _n <- 1..3, do: workspace_fixture(scope.organisation)
    [raising | others] = Enum.sort_by(created, & &1.id)
    above!(fn workspace -> if workspace.id == raising.id, do: raise("no level above") end)

    # Every workspace with a version is rendered, except the one that raises.
    listed = Repo.one(from c in RunConfiguration, select: count(c.workspace_id, :distinct))

    stub!([runtime("claude", [@host])])
    {totals, log} = with_log(fn -> FirstVersions.run() end)

    for workspace <- others do
      assert %RunConfiguration{version: 2} = row = newest(workspace)
      assert allow_first(row) == [@host]
    end

    assert %RunConfiguration{version: 1} = row = newest(raising)
    assert allow_first(row) == nil

    assert totals.rerendered == %{workspaces: listed - 1, versions: 2, refused: 0, failed: 1}
    assert log =~ "policy rerender failed workspace=#{raising.id}: no level above"
  end

  test "bin/migrate gives each version a runtime's host once, by no person", %{scope: scope} do
    stub!([runtime("claude", [])])
    {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})
    refute Map.has_key?(egress(scope, nil), "allow_first")
    baseline = versions(scope, nil)

    stub!([runtime("claude", [@host])])
    assert Release.migrate() == :ok

    assert egress(scope, nil)["allow_first"] == [@host]
    assert versions(scope, nil) == baseline + 1

    %{items: [%Change{} = change | _]} = Policy.list_changes(scope, nil)
    assert change.action == "rerendered"
    assert change.changed_by_id == nil
    assert Repo.get!(Entry, change.id).worker == "Apiary.Release.migrate/1"

    assert Release.migrate() == :ok
    assert versions(scope, nil) == baseline + 1
  end

  test "bin/migrate renders nothing again under another encryption secret", %{scope: scope} do
    stub!([runtime("claude", [])])
    {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})
    baseline = versions(scope, nil)

    stub!([runtime("claude", [@host])])
    derivation = another_encryption_secret!()
    Application.put_env(:apiary, KeyCheck, enabled: true)

    {result, log} = with_log(fn -> Release.migrate() end)
    assert result == :ok

    assert log =~
             "policy version 1 is not written and no policy is rendered again, because the " <>
               "key check failed."

    refute Map.has_key?(egress(scope, nil), "allow_first")
    assert versions(scope, nil) == baseline

    Application.put_env(:apiary, KeyDerivation, derivation)
    assert Release.migrate() == :ok
    assert egress(scope, nil)["allow_first"] == [@host]
    assert versions(scope, nil) == baseline + 1
  end

  test "Release.policy_rerender/0 renders nothing again under another encryption secret",
       %{scope: scope} do
    stub!([runtime("claude", [])])
    {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})
    baseline = versions(scope, nil)

    stub!([runtime("claude", [@host])])
    derivation = another_encryption_secret!()
    Application.put_env(:apiary, KeyCheck, enabled: true)

    {result, log} = with_log(fn -> Release.policy_rerender() end)
    assert result == [:key_check_failed]

    assert log =~
             "Set APIARY_ENCRYPTION_SECRET and APIARY_SIGNING_SECRET to the instance's keys " <>
               "and run bin/migrate again: policy version 1 is not written and no policy is " <>
               "rendered again, because the key check failed."

    refute Map.has_key?(egress(scope, nil), "allow_first")
    assert versions(scope, nil) == baseline

    Application.put_env(:apiary, KeyDerivation, derivation)
    assert [%{versions: versions}] = Release.policy_rerender()
    assert versions >= 1
    assert egress(scope, nil)["allow_first"] == [@host]
  end

  test "renders the other workspaces when one workspace's render exits", %{scope: scope} do
    {[exited | others], listed} = three_workspaces!(scope)
    above!(fn workspace -> if workspace.id == exited.id, do: exit(:timeout) end)

    stub!([runtime("claude", [@host])])
    {totals, log} = with_log(fn -> FirstVersions.run() end)

    for workspace <- others do
      assert %RunConfiguration{version: 2} = row = newest(workspace)
      assert allow_first(row) == [@host]
    end

    assert %RunConfiguration{version: 1} = newest(exited)
    assert totals.rerendered == %{workspaces: listed - 1, versions: 2, refused: 0, failed: 1}
    assert log =~ "policy rerender failed workspace=#{exited.id}: ** (exit) time out"
  end

  test "counts a refused render as refused, and renders the others", %{scope: scope} do
    {[refused | others], listed} = three_workspaces!(scope)
    above = too_big_above()
    above!(fn workspace -> if workspace.id == refused.id, do: above end)

    stub!([runtime("claude", [@host])])
    {totals, log} = with_log(fn -> FirstVersions.run() end)

    for workspace <- others do
      assert %RunConfiguration{version: 2} = row = newest(workspace)
      assert allow_first(row) == [@host]
    end

    assert %RunConfiguration{version: 1} = newest(refused)
    assert totals.rerendered == %{workspaces: listed - 1, versions: 2, refused: 1, failed: 0}
    assert log =~ "policy rerender refused workspace=#{refused.id}: "
  end

  test "announces each render, at boot and in bin/migrate", %{scope: scope} do
    stub!([runtime("claude", [])])
    {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})
    workspace_id = scope.workspace.id
    :ok = Policy.subscribe(scope)

    stub!([runtime("claude", [@host])])
    FirstVersions.run()

    assert_receive {:policy_changed,
                    %{workspace_id: ^workspace_id, target_id: nil, action: "rerendered"}}

    stub!([runtime("claude", [@host, "statsig.example.com"])])
    assert Release.migrate() == :ok

    assert_receive {:policy_changed,
                    %{workspace_id: ^workspace_id, target_id: nil, action: "rerendered"}}
  end
end
