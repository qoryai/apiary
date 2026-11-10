defmodule Apiary.Policy.FirstVersionTest do
  @moduledoc """
  Every workspace has policy version 1 from its creation, in observe with no rules, and no
  person made it. `Apiary.Policy.first_versions/0` writes the same version for each
  workspace that has none, at boot and from `bin/migrate`.
  """
  # `first_versions/0` reads every workspace, and tests set the level above, so the test is
  # not async.
  use Apiary.DataCase, async: false

  @moduletag :capture_log
  @moduletag needs: :security

  import Apiary.AccountsFixtures, only: [unique_user_email: 0]
  import Apiary.ConnectionsFixtures
  import Apiary.DescriptionFixtures
  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Apiary.{Connections, KeyCheck, KeyDerivation, Organisations, Policy, Release}
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.Workspace
  alias Apiary.Policy.{Above, Change, Error, Render, Rule, RunConfiguration}
  alias Apiary.Runs.Target

  # Version 1 allows the host of the vendored contract's runtime (`Apiary.Kinds.Runtimes`).
  @document ~s({"version":1,"security_policy":) <>
              ~s({"version":1,"egress":{"mode":"observe","allow":[],) <>
              ~s("allow_first":["api.anthropic.com"]}}})

  # The core's edition allows one workspace in use.
  setup do
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ManyWorkspaces)
  end

  defp rows(%Workspace{id: id}) do
    Repo.all(from c in RunConfiguration, where: c.workspace_id == ^id, order_by: c.version)
  end

  defp entries(%Workspace{id: id}) do
    Repo.all(
      from e in Entry,
        where: e.workspace_id == ^id and e.action == "security_policy.edit",
        order_by: e.id
    )
  end

  # What a reader can tell of a row and its entry, without the ids and the times.
  defp written(%Workspace{} = workspace) do
    [row] = rows(workspace)
    [entry] = entries(workspace)

    assert row.audit_entry_id == entry.id
    assert entry.subject_id == workspace.id

    %{
      version: row.version,
      target_id: row.target_id,
      document: row.document,
      digest: row.digest,
      changed_by_id: row.changed_by_id,
      actor_kind: entry.actor_kind,
      actor_id: entry.actor_id,
      action: entry.action,
      subject_kind: entry.subject_kind,
      before: entry.before,
      after: entry.after,
      details: entry.details,
      worker: entry.worker,
      remote_ip: entry.remote_ip
    }
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

  defp sign_up_without_workspace do
    {:ok, %{user: user}} =
      Organisations.sign_up_user(
        %{email: unique_user_email(), organisation_name: "Northwind"},
        nil,
        open: true,
        workspace: false
      )

    %{scope: Organisations.load_scope(Apiary.Accounts.Scope.for_user(user))}
  end

  defp second_workspace!(scope, name \\ "Second") do
    {:ok, workspace} =
      Organisations.create_workspace(scope, %{"name" => name, "domain" => "software"})

    workspace
  end

  # A level above over the 1 MiB of a document the gateway reads, so a render is refused.
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

  # Sets the level above each workspace for this test: `fun.(workspace)`.
  defp above!(fun) do
    on_exit(fn -> Application.delete_env(:apiary, Apiary.Policy.Above) end)
    Application.put_env(:apiary, Apiary.Policy.Above, answer: fun)
  end

  @none %{written: 0, refused: 0, failed: 0}

  defp integration!(scope, name, hosts, attrs \\ %{}) do
    description =
      tracker_description(%{
        "name" => name,
        "roles" => %{
          "credential" => %{"argument" => "[A-Z]+", "hosts" => ["#{name}.example.net"]}
        },
        "egress_hosts" => hosts
      })

    release = ready_release!(scope, description, "codeberg.org/acme/#{name}")
    {:ok, connection} = Connections.create_integration(scope, release.id, attrs)
    connection
  end

  describe "the write at creation" do
    test "gives a new workspace version 1, in observe with no rules and by no person" do
      %{scope: scope} = sign_up_fixture()
      workspace = second_workspace!(scope)

      assert %{
               version: 1,
               target_id: nil,
               document: @document,
               changed_by_id: nil,
               actor_kind: :instance,
               actor_id: nil,
               action: "security_policy.edit",
               details: %{"change" => "first_version", "version" => 1}
             } = written(workspace)

      assert Render.digest(@document) == hd(rows(workspace)).digest

      scope = %{scope | workspace: workspace}
      assert Policy.managed?(scope)

      assert %{items: [%Change{action: "first_version", changed_by_id: nil, version_after: 1}]} =
               Policy.list_changes(scope, nil, 1)
    end

    test "writes it for the workspace an organisation is created with" do
      %{workspace: workspace} = sign_up_fixture()
      assert [%RunConfiguration{version: 1, document: @document}] = rows(workspace)
    end

    test "writes it for an organisation's first workspace, and for a workspace of a kind" do
      %{scope: scope} = sign_up_without_workspace()

      assert {:ok, first} =
               Organisations.create_first_workspace(scope, %{"domain" => "software"})

      assert [%RunConfiguration{version: 1, document: @document}] = rows(first)

      assert {:ok, of_kind} =
               Organisations.create_workspace_of_kind(scope, Apiary.Lingo.Domain.Software, :any)

      assert [%RunConfiguration{version: 1, document: @document}] = rows(of_kind)
    end

    test "writes the same version for a workspace type with no repository" do
      %{scope: scope} = sign_up_fixture()
      software = written(second_workspace!(scope))

      {:ok, workspace} =
        Organisations.create_workspace(scope, %{"name" => "Care", "domain" => "example"})

      assert written(workspace) == software

      assert Repo.aggregate(from(t in Target, where: t.workspace_id == ^workspace.id), :count) ==
               0
    end

    test "makes a workspace's first change version 2" do
      %{scope: scope} = sign_up_fixture()
      workspace = second_workspace!(scope)
      scope = %{scope | workspace: workspace}

      assert {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})

      assert [1, 2] = Enum.map(rows(workspace), & &1.version)
      assert {:ok, %RunConfiguration{version: 2}} = Policy.current_configuration(scope, nil)
    end

    test "leaves a workspace that has a version alone" do
      %{scope: scope} = sign_up_fixture()
      workspace = second_workspace!(scope)

      assert {:ok, []} = Policy.first_version(workspace)
      assert [_one] = rows(workspace)
    end

    @tag needs: :secrets
    test "takes the hosts of an integration that applies to every workspace, in one version" do
      %{scope: scope} = sign_up_fixture()
      integration!(scope, "tracker", ["api.example.com"])
      workspace = second_workspace!(scope)

      assert [%RunConfiguration{version: 1, document: document}] = rows(workspace)
      assert document =~ ~s("allow":[],"allow_first":["api.anthropic.com","api.example.com"])
    end

    @tag needs: :secrets
    test "keeps a later integration's hosts as version 2" do
      %{scope: scope} = sign_up_fixture()
      workspace = second_workspace!(scope)
      integration!(scope, "tracker", ["api.example.com"])

      assert [1, 2] = Enum.map(rows(workspace), & &1.version)

      assert %{items: [%Change{action: "rerendered"}, %Change{action: "first_version"}]} =
               Policy.list_changes(%{scope | workspace: workspace}, nil, 1)
    end

    test "fails the creation when the render is refused" do
      %{scope: scope} = sign_up_fixture()
      above = too_big_above()
      above!(fn _workspace -> above end)
      before = Repo.aggregate(Workspace, :count)

      assert {:error, %Error{reason: :invalid_document, message: message}} =
               Organisations.create_workspace(scope, %{
                 "name" => "Refused",
                 "domain" => "software"
               })

      assert message =~ "over 1 MiB"

      assert Repo.aggregate(Workspace, :count) == before
    end

    test "fails a sign-up whose first workspace's render is refused" do
      # The instance is set up first, so the next sign-up is an ordinary one.
      sign_up_fixture()
      above = too_big_above()
      above!(fn _workspace -> above end)
      before = Repo.aggregate(Workspace, :count)

      assert {:error, %Error{reason: :invalid_document}} =
               Organisations.sign_up_user(
                 Apiary.AccountsFixtures.valid_user_attributes(%{}),
                 nil,
                 open: true
               )

      assert Repo.aggregate(Workspace, :count) == before
    end
  end

  describe "first_versions/0" do
    test "writes the same row and entry as the write at creation" do
      %{scope: scope} = sign_up_fixture()
      created = second_workspace!(scope)
      expected = written(created)

      missing = second_workspace!(scope, "Third")
      no_policy_version!(missing)
      assert rows(missing) == []

      assert Policy.first_versions() == %{@none | written: 1}

      assert written(missing) == expected
    end

    test "writes every existing workspace with no version, and a second run writes nothing" do
      %{scope: scope, workspace: first} = sign_up_fixture()
      kept = second_workspace!(scope)

      assert {:ok, _rule} =
               Policy.allow(%{scope | workspace: kept}, nil, %{host: "a.example.com"})

      kept_rows = rows(kept)

      missing =
        for name <- ["Third", "Fourth", "Fifth"] do
          scope |> second_workspace!(name) |> no_policy_version!()
        end

      no_policy_version!(first)

      assert Policy.first_versions() == %{@none | written: 4}

      for workspace <- [first | missing] do
        assert [%RunConfiguration{version: 1, document: @document}] = rows(workspace)
        assert [_one] = entries(workspace)
      end

      assert rows(kept) == kept_rows

      written =
        for workspace <- [first, kept | missing], do: {rows(workspace), entries(workspace)}

      assert Policy.first_versions() == @none
      assert written == for(w <- [first, kept | missing], do: {rows(w), entries(w)})
    end

    test "writes nothing where every workspace has a version" do
      %{scope: scope} = sign_up_fixture()
      workspace = second_workspace!(scope)
      assert Policy.first_versions() == @none
      assert [_one] = rows(workspace)
    end

    test "skips a workspace a purge has claimed" do
      %{scope: scope} = sign_up_fixture()
      workspace = second_workspace!(scope)
      no_policy_version!(workspace)
      now = DateTime.utc_now()

      workspace
      |> Ecto.Changeset.change(
        deletion_marked_at: now,
        purge_after: now,
        purge_trigger: "grace_period",
        purge_started_at: now
      )
      |> Repo.update!()

      assert Policy.first_versions() == @none
      assert rows(workspace) == []
    end

    test "skips a workspace whose organisation a purge has claimed" do
      %{scope: scope, organisation: organisation} = sign_up_fixture()
      workspace = second_workspace!(scope)
      no_policy_version!(workspace)
      now = DateTime.utc_now()

      organisation
      |> Ecto.Changeset.change(
        deletion_marked_at: now,
        purge_after: now,
        purge_trigger: "grace_period",
        purge_started_at: now
      )
      |> Repo.update!()

      assert Policy.first_versions() == @none
      assert rows(workspace) == []
    end

    @tag needs: :secrets
    test "adds the hosts of an integration that reaches the workspace" do
      %{scope: scope} = sign_up_fixture()
      integration!(scope, "tracker", ["api.example.com"])
      created = second_workspace!(scope)
      expected = written(created)

      reached = second_workspace!(scope, "Third")
      no_policy_version!(reached)

      assert Policy.first_versions() == %{@none | written: 1}
      assert written(reached) == expected
      assert expected.document =~ ~s("allow_first":["api.anthropic.com","api.example.com"])
    end

    test "writes a target's mode in the same version" do
      %{scope: scope} = sign_up_fixture()
      workspace = second_workspace!(scope)

      target =
        Repo.insert!(%Target{
          organisation_id: workspace.organisation_id,
          workspace_id: workspace.id,
          system: "github.example",
          path: "northwind/storefront",
          first_seen_at: DateTime.utc_now(),
          egress_mode: "enforce"
        })

      no_policy_version!(workspace)

      assert Policy.first_versions() == %{@none | written: 1}
      assert [nil, target.id] -- Enum.map(rows(workspace), & &1.target_id) == []
    end

    test "counts a refused render, leaves that workspace with no row, and writes the others" do
      %{scope: scope} = sign_up_fixture()
      refused = scope |> second_workspace!() |> no_policy_version!()
      missing = scope |> second_workspace!("Third") |> no_policy_version!()

      above = too_big_above()
      above!(fn workspace -> if workspace.id == refused.id, do: above end)

      assert Policy.first_versions() == %{@none | written: 1, refused: 1}
      assert rows(refused) == []
      assert [%RunConfiguration{version: 1}] = rows(missing)
    end

    test "counts a render that raises, leaves that workspace with no row, and writes the others" do
      %{scope: scope} = sign_up_fixture()
      failed = scope |> second_workspace!() |> no_policy_version!()
      missing = scope |> second_workspace!("Third") |> no_policy_version!()

      above!(fn workspace ->
        if workspace.id == failed.id, do: raise("no level above"), else: nil
      end)

      assert Policy.first_versions() == %{@none | written: 1, failed: 1}
      assert rows(failed) == []
      assert entries(failed) == []
      assert [%RunConfiguration{version: 1}] = rows(missing)

      Application.delete_env(:apiary, Apiary.Policy.Above)
      assert Policy.first_versions() == %{@none | written: 1}
      assert [%RunConfiguration{version: 1, document: @document}] = rows(failed)
    end
  end

  describe "at boot and from bin/migrate" do
    test "Release.migrate/1 writes version 1 of a workspace with no version" do
      %{scope: scope} = sign_up_fixture()
      workspace = scope |> second_workspace!() |> no_policy_version!()

      assert Release.migrate(first_versions: false) == :ok
      assert rows(workspace) == []

      assert Release.migrate() == :ok
      assert [%RunConfiguration{version: 1, document: @document}] = rows(workspace)
    end

    test "Release.migrate/1 writes no version 1 under another encryption secret" do
      %{scope: scope} = sign_up_fixture()
      workspace = scope |> second_workspace!() |> no_policy_version!()
      derivation = another_encryption_secret!()
      Application.put_env(:apiary, KeyCheck, enabled: true)

      {result, log} = with_log(fn -> Release.migrate() end)
      assert result == :ok
      assert rows(workspace) == []

      assert log =~
               "Set APIARY_ENCRYPTION_SECRET and APIARY_SIGNING_SECRET to the instance's " <>
                 "keys and run bin/migrate again: policy version 1 is not written and no " <>
                 "policy is rendered again, because the key check failed."

      assert log =~ KeyCheck.encryption_message()

      Application.put_env(:apiary, KeyDerivation, derivation)
      assert Release.migrate() == :ok
      assert [%RunConfiguration{version: 1, document: @document}] = rows(workspace)
    end

    test "Release.migrate/1 with the key check off writes version 1 under any secret" do
      %{scope: scope} = sign_up_fixture()
      workspace = scope |> second_workspace!() |> no_policy_version!()
      _derivation = another_encryption_secret!()
      Application.put_env(:apiary, KeyCheck, enabled: false)

      assert Release.migrate() == :ok
      assert [%RunConfiguration{version: 1, document: @document}] = rows(workspace)
    end

    test "the boot's step writes version 1, and a raise stops no boot" do
      %{scope: scope} = sign_up_fixture()
      workspace = scope |> second_workspace!() |> no_policy_version!()

      above!(fn _workspace -> raise "no level above" end)
      assert Release.FirstVersions.start_link() == :ignore
      assert rows(workspace) == []

      Application.delete_env(:apiary, Apiary.Policy.Above)
      assert Release.FirstVersions.start_link() == :ignore
      assert [%RunConfiguration{version: 1, document: @document}] = rows(workspace)
    end

    test "an exit from one workspace stops no boot, and the next boot writes it" do
      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)

      %{scope: scope} = sign_up_fixture()
      exited = scope |> second_workspace!() |> no_policy_version!()
      missing = scope |> second_workspace!("Third") |> no_policy_version!()

      above!(fn workspace ->
        if workspace.id == exited.id, do: exit(:timeout), else: nil
      end)

      {result, log} = with_log(fn -> Release.FirstVersions.start_link() end)
      assert result == :ignore
      assert log =~ "policy version 1 failed workspace=#{exited.id}: ** (exit) time out"
      assert log =~ "policy version 1 at boot: written=1 refused=0 failed=1"
      assert rows(exited) == []
      assert [%RunConfiguration{version: 1}] = rows(missing)

      Application.delete_env(:apiary, Apiary.Policy.Above)
      assert Release.FirstVersions.start_link() == :ignore
      assert [%RunConfiguration{version: 1, document: @document}] = rows(exited)
    end

    test "a raise while it lists the workspaces stops no boot" do
      %{scope: scope} = sign_up_fixture()
      workspace = scope |> second_workspace!() |> no_policy_version!()

      # With no schema to find `workspaces` in, the listing raises. The sandbox rolls back
      # the failed query alone, so the test sets the search path back.
      %{rows: [[search_path]]} = Repo.query!("SHOW search_path")
      Repo.query!("SET LOCAL search_path = nowhere")
      {result, log} = with_log(fn -> Release.FirstVersions.start_link() end)
      Repo.query!("SELECT set_config('search_path', $1, true)", [search_path])

      assert result == :ignore

      assert log =~
               "policy version 1 not written at boot: ERROR 42P01 (undefined_table) " <>
                 ~s(relation "workspaces" does not exist)

      assert log =~ "policy not rendered again at boot: ERROR 42P01 (undefined_table) "

      assert rows(workspace) == []

      assert Release.FirstVersions.start_link() == :ignore
      assert [%RunConfiguration{version: 1, document: @document}] = rows(workspace)
    end

    test "the boot writes the versions after the key check, where it migrates" do
      key_check = Application.get_env(:apiary, Apiary.KeyCheck)
      migrate_on_boot = Application.fetch_env(:apiary, :migrate_on_boot)

      on_exit(fn ->
        Application.put_env(:apiary, Apiary.KeyCheck, key_check)

        case migrate_on_boot do
          {:ok, value} -> Application.put_env(:apiary, :migrate_on_boot, value)
          :error -> Application.delete_env(:apiary, :migrate_on_boot)
        end
      end)

      Application.put_env(:apiary, Apiary.KeyCheck, enabled: true)
      Application.put_env(:apiary, :migrate_on_boot, true)

      children = Apiary.Application.children()
      at = &Enum.find_index(children, fn child -> child == &1 end)

      assert at.(Apiary.Release.Migrator) < at.(Apiary.KeyCheck)
      assert at.(Apiary.KeyCheck) < at.(Release.FirstVersions)
      assert at.(Release.FirstVersions) < at.(ApiaryWeb.Endpoint)

      Application.put_env(:apiary, :migrate_on_boot, false)
      refute Release.FirstVersions in Apiary.Application.children()
    end
  end
end
