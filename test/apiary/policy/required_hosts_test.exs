defmodule Apiary.Policy.RequiredHostsTest do
  # The hosts Qory Apiary allows for every run of a workspace, read at the workspace's
  # level (`Apiary.Policy.RequiredHosts`), against the hosts the same code builds for a
  # run of that workspace. Each group is compared on the same inputs: the list is the
  # workspace-level part of what the run's policy gains, and the run adds nothing else of
  # the group in these cases. Not async: the features are the whole node's.
  use Apiary.DataCase, async: false

  import Apiary.ConnectionsFixtures, only: [ready_release!: 3]
  import Apiary.DescriptionFixtures, only: [tracker_description: 1]
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures

  alias Apiary.{Connections, ModelChoices, Policy, Repo}
  alias Apiary.Harnesses.RunHarness
  alias Apiary.Lingo.Domain.Definition
  alias Apiary.Policy.{ComposedConfiguration, RequiredHosts}
  alias Apiary.Registry.RunAccess
  alias Apiary.Runs.{ProviderCredential, Run, RunCredentials, Target}
  alias Apiary.Stacks

  @apply [
    %{"hosts" => ["git.example.com"], "scheme" => "bearer", "paths" => ["/{target.path}/*"]}
  ]

  defp hosts(group), do: group.rows |> Enum.map(& &1.host) |> Enum.sort()

  defp run_members(run) do
    {:ok, members} = ComposedConfiguration.members(Repo.get!(Run, run.id))
    members
  end

  defp integration!(scope, name, hosts, attrs \\ %{}) do
    release =
      ready_release!(
        scope,
        tracker_description(%{
          "name" => name,
          "egress_hosts" => hosts,
          "roles" => %{"credential" => %{"argument" => "[A-Z]+", "hosts" => hosts}}
        }),
        "codeberg.org/acme/#{name}"
      )

    {:ok, connection} = Connections.create_integration(scope, release.id, attrs)
    connection
  end

  describe "harness sources" do
    @describetag needs: :factory

    test "are the hosts a run's stack_hosts has for the workspace's chosen harness" do
      %{scope: scope} = sign_up_fixture()
      run = sealed_run_fixture(scope).run
      git = Definition.qory_harness().git

      RunHarness
      |> Repo.get_by!(dispatch_run_id: run.dispatch_run_id)
      |> Ecto.Changeset.change(pins: [%{"git" => git, "ref" => "main", "at" => "x"}])
      |> Repo.update!()

      group = RequiredHosts.harness(scope.workspace)
      assert hosts(group) == Enum.sort(run_members(run).stack_hosts)
      assert [%{source: :qory, required_by: :instance}] = group.rows
    end

    # The run is given the pins of the harness sources in `gits`; the list has the hosts
    # its stack_hosts has for the same sources.
    defp same_as_run(scope, gits) do
      run = sealed_run_fixture(scope).run

      RunHarness
      |> Repo.get_by!(dispatch_run_id: run.dispatch_run_id)
      |> Ecto.Changeset.change(
        pins: for(git <- gits, do: %{"git" => git, "ref" => "main", "at" => "x"})
      )
      |> Repo.update!()

      group = RequiredHosts.harness(scope.workspace)
      assert hosts(group) == Enum.sort(run_members(run).stack_hosts)
      group.rows
    end

    defp harness_document(git), do: "extends:\n  git: \"#{git}\"\n  ref: \"main\"\n"

    test "a harness repository the workspace chose is this workspace's choice" do
      %{scope: scope} = sign_up_fixture()
      git = "https://code.example/acme/harness"

      {:ok, _stack} =
        Stacks.put_stack(scope, {:workspace, scope.workspace}, harness_document(git),
          choice: :repository
        )

      assert [%{host: "code.example", source: {:repository, "acme/harness"}} = row] =
               same_as_run(scope, [git])

      assert row.required_by == :workspace
    end

    test "a harness the organisation shares is the organisation's choice" do
      %{scope: scope} = sign_up_fixture()
      git = "https://code.example/acme/shared"

      {:ok, _stack} =
        Stacks.put_stack(scope, {:organisation, scope.organisation}, harness_document(git),
          choice: :repository
        )

      assert [%{host: "code.example", source: {:repository, "acme/shared"}} = row] =
               same_as_run(scope, [git])

      assert row.required_by == :organisation
    end

    test "a harness chosen in this workspace for one target is this workspace's choice" do
      %{scope: scope} = sign_up_fixture()
      git = "https://tools.example/acme/target-harness"

      :ok =
        Target.insert_new(scope.organisation.id, scope.workspace.id, [
          %{system: "forge.example.com", path: "acme/shop"}
        ])

      target = Apiary.Runs.fetch_target(scope, "forge.example.com", "acme/shop")

      {:ok, _stack} =
        Stacks.put_stack(scope, {:target, target}, harness_document(git), choice: :repository)

      rows = same_as_run(scope, [Definition.qory_harness().git, git])

      assert Enum.sort(Enum.map(rows, &{&1.host, &1.source, &1.required_by})) == [
               {"github.com", :qory, :instance},
               {"tools.example", {:repository, "acme/target-harness"}, :workspace}
             ]
    end
  end

  describe "integrations" do
    @describetag needs: :secrets

    test "are the hosts the workspace's effective policy takes in, for the organisation or the workspace" do
      %{scope: scope} = sign_up_fixture()
      integration!(scope, "tracker", ["api.tracker.example"])

      integration!(scope, "chat", ["hooks.chat.example"], %{
        applies_to: "selected",
        workspace_ids: [scope.workspace.id]
      })

      group = RequiredHosts.integrations(scope.workspace)

      effective = Policy.effective(scope, nil, integrations: true)

      assert hosts(group) ==
               effective.entries
               |> Enum.filter(&(&1.source == :integration))
               |> Enum.map(& &1.host)
               |> Enum.sort()

      assert Enum.sort(Enum.map(group.rows, &{&1.host, &1.source, &1.required_by})) == [
               {"api.tracker.example", {:integration, "tracker"}, :organisation},
               {"hooks.chat.example", {:integration, "chat"}, :workspace}
             ]
    end
  end

  describe "model providers" do
    @describetag needs: [:factory, :secrets]

    test "are the hosts of the providers the model choices use, as a run of it is given them" do
      %{scope: scope} = sign_up_fixture()
      ctx = sealed_run_fixture(scope)
      {:ok, %{hosts: run_hosts}} = ProviderCredential.for_run(Repo.get!(Run, ctx.run.id))

      group = RequiredHosts.providers(scope.workspace)
      assert hosts(group) == Enum.sort(run_hosts)
      assert [%{source: {:provider, _name}, required_by: :workspace}] = group.rows
    end

    test "are none for a provider no model choice uses" do
      %{scope: scope} = sign_up_fixture()
      ctx = sealed_run_fixture(scope)
      {:ok, _} = ModelChoices.delete_choice(scope, :workspace)
      refute ModelChoices.list_choices(scope) |> elem(1) |> Enum.any?(&(&1.workspace_id != nil))
      assert RequiredHosts.providers(scope.workspace).rows == []
      assert ctx.provider.public_id
    end
  end

  describe "registry and Qory Apiary" do
    @describetag needs: [:factory, :registry]

    test "are the instance's host and the registry's, as a run through a gateway is given them" do
      %{scope: scope} = sign_up_fixture()
      run = sealed_run_fixture(scope).run

      group = RequiredHosts.registry()
      assert Enum.map(group.rows, & &1.host) == RunAccess.member(Repo.get!(Run, run.id)).hosts
      assert Enum.map(group.rows, & &1.source) == [:instance, :registry]
      assert Enum.all?(group.rows, &(&1.required_by == :instance))
    end
  end

  describe "the system of the target" do
    @describetag needs: [:factory, :secrets]

    test "are the hosts of the work entry a run of the workspace's assigned collection has" do
      %{scope: scope} = sign_up_fixture()

      :ok =
        Target.insert_new(scope.organisation.id, scope.workspace.id, [
          %{system: "forge.example.com", path: "acme/shop"}
        ])

      ctx = sealed_run_fixture(scope, work: @apply)

      group = RequiredHosts.forge(scope.workspace)
      assert hosts(group) == Enum.sort(RunCredentials.work(ctx.run).hosts)
      assert [%{source: {:adapter, _title}, required_by: :workspace}] = group.rows
    end

    test "are none for a workspace with no collection whose adapter declares apply items" do
      %{scope: scope} = sign_up_fixture()
      assert RequiredHosts.forge(scope.workspace).rows == []
    end
  end

  test "of/1 leaves out the groups without a row and chooses the line by the domain" do
    scope = scope_fixture()
    result = RequiredHosts.of(scope.workspace)
    assert Enum.all?(result.groups, &(&1.rows != []))
    assert result.target_required? == true
  end
end
