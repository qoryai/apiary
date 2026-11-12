defmodule ApiaryPro.OrganisationVariablesAboveTest do
  # What the core makes of the organisation's variables at the level above the workspace,
  # as the edition answers it (`ApiaryPro.Edition.above_workspace/1`): the organisation's
  # policy carrying its variables where a policy is in force, its variables alone
  # (`policy: false`) where none is, nothing where it has neither; resolved through the
  # core's public functions (`Apiary.Variables`, `Apiary.Policy`).
  # Not async: the instance's features are the node's.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.{Features, Policy, Variables}
  alias Apiary.Policy.Above
  alias Apiary.Runs.Target
  alias Apiary.Variables.Resolution
  alias ApiaryPro.{OrganisationPolicy, OrganisationVariables}

  @moduletag with_features: Features.all()
  # The organisation's variables need `secrets`: they run only where both are on.
  @moduletag needs: :organisation_variables

  setup do
    %{scope: owner, organisation: organisation} = sign_up_fixture()

    site =
      Repo.insert!(%Target{
        organisation_id: organisation.id,
        workspace_id: owner.workspace.id,
        system: "github.example",
        path: "example/site",
        first_seen_at: DateTime.utc_now()
      })

    %{owner: owner, organisation: organisation, site: site}
  end

  defp variables!(%{owner: owner}) do
    {:ok, _} =
      OrganisationVariables.create(owner, %{name: "REGION", value: "eu-west-1", locked: true})

    {:ok, log_level} = OrganisationVariables.create(owner, %{name: "Log_Level", value: "info"})
    %{log_level: log_level}
  end

  # A policy kept for the organisation with its settings off the core's defaults and a
  # rule, as its owner would leave it, written as rows so it is there where its feature
  # is off too.
  defp stored_policy!(%{organisation: organisation, owner: owner}) do
    Repo.insert!(%OrganisationPolicy.Policy{
      organisation_id: organisation.id,
      enforce_everywhere: true,
      own_allows: false
    })

    Repo.insert!(%OrganisationPolicy.Rule{
      organisation_id: organisation.id,
      created_by_id: owner.user.id,
      action: "deny",
      host: "paste.example"
    })

    :ok
  end

  describe "what the edition answers" do
    test "with a policy in force: the policy, carrying the variables", ctx do
      variables!(ctx)
      {:ok, _rule} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})
      {:ok, _} = OrganisationPolicy.set_floor(ctx.owner, true)

      assert %Above{
               policy: true,
               floor: true,
               own_allows: true,
               rules: [%{host: "paste.example"}],
               variables: [%{name: "Log_Level"}, %{name: "REGION", locked: true}]
             } = above = Apiary.Edition.above_workspace(ctx.owner.workspace)

      assert {above.id, above.name, above.slug} ==
               {ctx.organisation.id, ctx.organisation.name, ctx.organisation.slug}

      assert Policy.effective(ctx.owner, nil).above.id == ctx.organisation.id
    end

    test "with variables and no policy: the variables alone, with policy: false", ctx do
      variables!(ctx)

      assert %Above{
               policy: false,
               rules: [],
               floor: false,
               own_allows: true,
               variables: [%{name: "Log_Level"}, %{name: "REGION"}]
             } = above = Apiary.Edition.above_workspace(ctx.owner.workspace)

      assert {above.id, above.name, above.slug} ==
               {ctx.organisation.id, ctx.organisation.name, ctx.organisation.slug}

      # The policy's own callers still see none.
      assert OrganisationPolicy.above_workspace(ctx.owner.workspace) == nil
    end

    @tag with_features: Features.all() -- [:organisation_policy]
    test "with variables and a policy whose feature is off: a fresh level, none of the policy's",
         ctx do
      stored_policy!(ctx)
      variables!(ctx)

      assert %Above{policy: false, rules: [], floor: false, own_allows: true} =
               above = Apiary.Edition.above_workspace(ctx.owner.workspace)

      assert [%{name: "Log_Level"}, %{name: "REGION"}] = above.variables
      assert above.id == ctx.organisation.id
    end

    test "with neither: nil", ctx do
      assert Apiary.Edition.above_workspace(ctx.owner.workspace) == nil
    end

    @tag with_features: Features.all() -- [:organisation_variables]
    test "with a policy and the variables' feature off: the policy, carrying none", ctx do
      {:ok, _rule} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})

      Repo.insert!(%OrganisationVariables.Variable{
        organisation_id: ctx.organisation.id,
        name: "REGION",
        value: "eu-west-1"
      })

      assert %Above{policy: true, rules: [_], variables: []} =
               Apiary.Edition.above_workspace(ctx.owner.workspace)
    end

    @tag with_features: Features.all() -- [:organisation_variables]
    test "with variables kept while their feature is off, and no policy: nil", ctx do
      Repo.insert!(%OrganisationVariables.Variable{
        organisation_id: ctx.organisation.id,
        name: "REGION",
        value: "eu-west-1"
      })

      assert Apiary.Edition.above_workspace(ctx.owner.workspace) == nil
    end
  end

  describe "under the organisation's policy" do
    setup ctx do
      {:ok, _rule} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})
      variables!(ctx)
    end

    test "the organisation's variables are resolved first, beside its policy", ctx do
      %{owner: owner, site: site} = ctx

      assert {:ok, resolution} = Variables.resolve(owner, :workspace)
      assert Resolution.values(resolution) == %{"REGION" => "eu-west-1", "Log_Level" => "info"}
      assert %{set_by: :above, locked_by: :above} = Resolution.entry(resolution, "region")

      # A workspace's value overrides the organisation's, and a repository's the workspace's.
      {:ok, _} =
        Variables.create_variable(owner, :workspace, %{name: "Log_Level", value: "debug"})

      {:ok, _} = Variables.create_variable(owner, site, %{name: "Log_Level", value: "trace"})

      assert {:ok, resolution} = Variables.resolve(owner, :workspace)
      assert Resolution.values(resolution)["Log_Level"] == "debug"
      assert {:ok, resolution} = Variables.resolve(owner, site)
      assert Resolution.values(resolution) == %{"REGION" => "eu-west-1", "Log_Level" => "trace"}

      # The policy at the same level holds as it did: its deny is in force.
      effective = Policy.effective(owner, nil)
      assert effective.above.id == owner.organisation.id

      assert Enum.any?(
               effective.entries,
               &(&1.source == :organisation and &1.host == "paste.example" and &1.action == :deny)
             )
    end

    test "a name the organisation locks is set at no level below it", ctx do
      for holder <- [:workspace, ctx.site], name <- ["REGION", "region"] do
        assert {:error, changeset} =
                 Variables.create_variable(ctx.owner, holder, %{name: name, value: "us-east-1"})

        assert {"is locked above, so it cannot be set here", _} = changeset.errors[:name]
      end
    end

    test "another spelling of a name the organisation sets is refused below it", ctx do
      for holder <- [:workspace, ctx.site] do
        assert {:error, changeset} =
                 Variables.create_variable(ctx.owner, holder, %{name: "LOG_LEVEL", value: "debug"})

        assert {"is %{name} in this organisation: use the same spelling", [name: "Log_Level"]} =
                 changeset.errors[:name]
      end
    end

    test "a lock the organisation sets after sets the values below aside", ctx do
      %{owner: owner, site: site} = ctx

      {:ok, _} =
        Variables.create_variable(owner, :workspace, %{name: "Log_Level", value: "debug"})

      {:ok, _} = Variables.create_variable(owner, site, %{name: "Log_Level", value: "trace"})

      assert {:ok, _} = OrganisationVariables.lock(owner, ctx.log_level)

      assert {:ok, resolution} = Variables.resolve(owner, site)

      assert %{value: "info", set_by: :above, locked_by: :above, ignored: [:workspace, :target]} =
               Resolution.entry(resolution, "log_level")

      assert {:ok, %{"log_level" => %{workspaces: 1, repositories: 1, workspace_locked: 0}}} =
               OrganisationVariables.overrides(owner)

      # Unlocked again, the lower values are in force once more.
      assert {:ok, _} = OrganisationVariables.unlock(owner, ctx.log_level)
      assert {:ok, resolution} = Variables.resolve(owner, site)
      assert Resolution.values(resolution)["Log_Level"] == "trace"
    end
  end

  describe "without a policy" do
    setup ctx do
      {:ok, _} = Policy.deny(ctx.owner, nil, %{host: "own.example"})
      variables!(ctx)
    end

    test "the variables are resolved first, and no level of the policy holds", ctx do
      %{owner: owner, site: site} = ctx

      assert {:ok, resolution} = Variables.resolve(owner, site)
      assert Resolution.values(resolution) == %{"REGION" => "eu-west-1", "Log_Level" => "info"}
      assert %{set_by: :above, locked_by: :above} = Resolution.entry(resolution, "region")

      effective = Policy.effective(owner, nil)
      assert effective.above == nil
      assert effective.mode == "observe"
      refute Enum.any?(effective.entries, &(&1.source == :organisation))
      assert Enum.any?(effective.entries, &(&1.host == "own.example"))

      # The run's configuration and the export say nothing of the organisation either.
      assert {:ok, configuration} = Policy.current_configuration(owner, nil)
      refute configuration.document =~ ctx.organisation.slug
      assert {:ok, %{forager_file: forager_file}} = Policy.export(owner, nil)
      assert forager_file =~ "own.example"
      refute forager_file =~ ctx.organisation.name
    end

    test "a workspace admin's write of a name the organisation locks is refused, in any spelling",
         ctx do
      admin = member_fixture(ctx.owner, :admin)
      platform = workspace_fixture(ctx.organisation, "Platform")
      in_platform = workspace_scope(admin.user, platform)

      for name <- ["REGION", "region", "Region"] do
        assert {:error, changeset} =
                 Variables.create_variable(in_platform, :workspace, %{name: name, value: "x"})

        assert {"is locked above, so it cannot be set here", _} = changeset.errors[:name]
      end

      # A name it sets and does not lock is the workspace's to override, in its spelling.
      assert {:error, changeset} =
               Variables.create_variable(in_platform, :workspace, %{name: "LOG_LEVEL", value: "x"})

      assert {"is %{name} in this organisation: use the same spelling", [name: "Log_Level"]} =
               changeset.errors[:name]

      assert {:ok, _} =
               Variables.create_variable(in_platform, :workspace, %{name: "Log_Level", value: "x"})
    end

    test "the workspace's policy writes take the level as nil", ctx do
      %{owner: owner} = ctx

      assert {:ok, _} = Policy.allow(owner, nil, %{host: "cdn.example"})
      assert {:ok, "enforce"} = Policy.set_mode(owner, nil, "enforce")
      assert %{mode: "enforce", above: nil} = Policy.effective(owner, nil)
    end
  end

  @tag with_features: Features.all() -- [:organisation_policy]
  test "a policy kept while its feature is off holds nowhere, and the variables still do", ctx do
    stored_policy!(ctx)
    variables!(ctx)

    effective = Policy.effective(ctx.owner, nil)
    assert effective.above == nil
    refute Enum.any?(effective.entries, &(&1.host == "paste.example"))

    # Its floor would fix the mode and its switch strike a workspace's allow: neither does.
    assert {:ok, _} = Policy.allow(ctx.owner, nil, %{host: "cdn.example"})
    assert {:ok, "observe"} = Policy.set_mode(ctx.owner, nil, "observe")

    assert {:ok, resolution} = Variables.resolve(ctx.owner, :workspace)
    assert Resolution.values(resolution)["REGION"] == "eu-west-1"
  end
end
