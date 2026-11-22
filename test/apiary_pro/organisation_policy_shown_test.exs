defmodule ApiaryPro.OrganisationPolicyShownTest do
  # The organisation's policy and its variables hold above its workspaces while the
  # instance has their feature, whatever the organisation is granted
  # (`ApiaryPro.OrganisationPolicy.above_workspace/1`,
  # `ApiaryPro.OrganisationVariables.for_above/1`): taken away from the organisation, the
  # feature leaves its pages, and its workspaces' documents and runs keep the policy. A
  # grant renders nothing, and writes nothing to a workspace's History.
  # Not async: the instance's features are the node's, and every test here asks on an
  # instance with all of them, or without the feature.
  use Apiary.DataCase, async: false

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  import Apiary.OrganisationsFixtures
  import Apiary.AccessKeysFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Features, Organisations, Policy}
  alias Apiary.Organisations.Organisation
  alias Apiary.Policy.{Above, Serving}
  alias ApiaryPro.{Grants, OrganisationPolicy, OrganisationVariables}

  @moduletag with_features: Features.all()

  setup do
    %{scope: owner, organisation: organisation, workspace: main} = sign_up_fixture()
    platform = workspace_fixture(organisation, "Platform")

    %{
      owner: owner,
      organisation: organisation,
      main: main,
      platform: platform,
      in_platform: workspace_scope(owner.user, platform),
      admin: instance_admin_fixture().instance_scope
    }
  end

  defp deny(scope) do
    {:ok, configuration} = Policy.current_configuration(scope, nil)
    Jason.decode!(configuration.document)["security_policy"]["egress"]["deny"] || []
  end

  # What a run of the workspace is served: the document and its digest.
  defp fetched(scope) do
    %{access_key: key} = access_key_fixture(scope)
    assert Serving.managed?(key)
    assert {:ok, configuration} = Serving.fetch(key, %{}, nil)
    configuration
  end

  defp fetched_deny(scope),
    do: Jason.decode!(fetched(scope).document)["security_policy"]["egress"]["deny"] || []

  defp history(scope), do: Policy.list_changes(scope, nil, 1).items

  defp has?(organisation, feature),
    do: feature in ApiaryPro.Features.of(Repo.get!(Organisation, organisation.id))

  # Every feature the organisation's page offers, but `features`, which are taken away.
  defp take_away(ctx, features) do
    organisation = Repo.get!(Organisation, ctx.organisation.id)
    kept = Grants.shown(organisation) -- features
    assert {:ok, _features} = Grants.set_organisation(ctx.admin, organisation.id, kept)
    for feature <- features, do: refute(has?(organisation, feature))
  end

  describe "the organisation's grant taken away" do
    test "its policy still holds above every workspace, in the documents and the fetch", ctx do
      {:ok, _} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})

      take_away(ctx, [:organisation_policy])

      assert %Above{rules: [%{host: "paste.example"}]} =
               OrganisationPolicy.above_workspace(ctx.main)

      for scope <- [ctx.owner, ctx.in_platform] do
        assert %Above{} = Policy.effective(scope, nil).above
        assert deny(scope) == ["paste.example"]
        assert fetched_deny(scope) == ["paste.example"]
      end
    end

    test "the policy still reaches runs: the deny is in the fetch, the digest unchanged", ctx do
      {:ok, _} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})
      served = fetched(ctx.owner)

      take_away(ctx, [:organisation_policy])

      assert %{version: version, digest: digest} = fetched(ctx.owner)
      assert {version, digest} == {served.version, served.digest}
      assert fetched_deny(ctx.owner) == ["paste.example"]
    end

    test "taken away and granted again, nothing is written to a workspace's History", ctx do
      {:ok, _} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})
      changes = Enum.map([ctx.owner, ctx.in_platform], &history/1)
      organisation = Repo.get!(Organisation, ctx.organisation.id)
      shown = Grants.shown(organisation)

      take_away(ctx, [:organisation_policy])
      assert Enum.map([ctx.owner, ctx.in_platform], &history/1) == changes

      assert {:ok, _} = Grants.set_organisation(ctx.admin, organisation.id, shown)
      assert has?(organisation, :organisation_policy)
      assert Enum.map([ctx.owner, ctx.in_platform], &history/1) == changes
    end

    test "a workspace created meanwhile is rendered under the policy", ctx do
      {:ok, _} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})
      take_away(ctx, [:organisation_policy])

      {:ok, workspace} =
        Organisations.create_workspace(ctx.owner, %{
          "name" => "Staging",
          "slug" => "staging",
          "domain" => "software"
        })

      staging = workspace_scope(ctx.owner.user, workspace)
      assert Policy.managed?(staging)
      assert deny(staging) == ["paste.example"]
      assert fetched_deny(staging) == ["paste.example"]
    end

    # The variables' feature needs `security`: a page that takes `security` away from an
    # organisation with no operator takes it too, and the policy with it.
    test "its variables are still above every workspace", ctx do
      {:ok, _} = OrganisationVariables.create(ctx.owner, %{name: "LOG_LEVEL", value: "info"})

      take_away(ctx, [:security, :organisation_policy, :organisation_variables])
      refute has?(ctx.organisation, :organisation_variables)

      for workspace <- [ctx.main, ctx.platform] do
        assert [%{name: "LOG_LEVEL", value: "info"}] = OrganisationVariables.for_above(workspace)

        assert %Above{variables: [%{name: "LOG_LEVEL"}]} =
                 Apiary.Edition.above_workspace(workspace)
      end
    end
  end

  describe "an instance without the feature" do
    @tag with_features: [:observability, :security, :secrets, :managed_organisations]
    test "has nothing above the workspaces", ctx do
      Repo.insert!(%OrganisationPolicy.Policy{
        organisation_id: ctx.organisation.id,
        enforce_everywhere: true
      })

      Repo.insert!(%OrganisationVariables.Variable{
        organisation_id: ctx.organisation.id,
        name: "LOG_LEVEL",
        value: "info"
      })

      assert OrganisationPolicy.above_workspace(ctx.main) == nil
      assert OrganisationVariables.for_above(ctx.main) == []
      assert Apiary.Edition.above_workspace(ctx.main) == nil
      assert Policy.effective(ctx.owner, nil).mode == "observe"
    end
  end
end
