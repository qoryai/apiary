defmodule ApiaryPro.RenderOrganisationPoliciesTest do
  # The release command that renders again every workspace of every organisation that
  # has a policy (`ApiaryPro.Release.render_organisation_policies/0`,
  # `ApiaryPro.OrganisationPolicy.render_all/0`): documents rendered without the
  # organisation's policy get it, the unmanaged workspaces their version 1, and a second
  # run writes nothing. Not async: the instance's features are the node's.
  use Apiary.DataCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import Apiary.OrganisationsFixtures

  alias Apiary.{Features, Policy}
  alias ApiaryPro.OrganisationPolicy
  alias ApiaryPro.OrganisationPolicy.Rule

  @moduletag with_features: Features.all()

  # An organisation whose policy denies paste.example, kept as rows and rendered nowhere:
  # Main serves a document written without it, and Platform none, as on an upgrade from a
  # release without version 1.
  setup do
    %{scope: owner, organisation: organisation} = sign_up_fixture()
    platform = organisation |> workspace_fixture("Platform") |> no_policy_version!()
    {:ok, _} = Policy.allow(owner, nil, %{host: "cdn.example"})

    Repo.insert!(%OrganisationPolicy.Policy{organisation_id: organisation.id})
    Repo.insert!(%Rule{organisation_id: organisation.id, action: "deny", host: "paste.example"})

    %{
      owner: owner,
      organisation: organisation,
      in_platform: workspace_scope(owner.user, platform)
    }
  end

  defp served(scope) do
    case Policy.current_configuration(scope, nil) do
      {:ok, configuration} ->
        egress = Jason.decode!(configuration.document)["security_policy"]["egress"]
        %{version: configuration.version, deny: egress["deny"] || []}

      _none ->
        nil
    end
  end

  defp render do
    {result, output} = with_io(&ApiaryPro.Release.render_organisation_policies/0)
    {result, output}
  end

  test "renders every workspace under its organisation's policy, the unmanaged ones too", ctx do
    assert %{version: 2, deny: []} = served(ctx.owner)
    assert served(ctx.in_platform) == nil
    %{scope: other} = sign_up_fixture()
    {:ok, _} = Policy.allow(other, nil, %{host: "cdn.example"})

    assert {%{workspaces: 2, versions: 2}, output} = render()
    assert output =~ "Rendered 2 workspaces under their organisation's policy: 2 new versions."

    assert %{version: 3, deny: ["paste.example"]} = served(ctx.owner)
    assert %{version: 1, deny: ["paste.example"]} = served(ctx.in_platform)
    assert Policy.managed?(ctx.in_platform)

    # An organisation with no policy is left alone.
    assert %{version: 2, deny: []} = served(other)

    # Each change is the instance's, by nobody.
    assert %{items: [%{action: "rerendered", changed_by_id: nil} | _]} =
             Policy.list_changes(ctx.owner, nil, 1)
  end

  test "is idempotent: a second run writes nothing", ctx do
    assert {%{versions: 2}, _output} = render()
    changes = Policy.list_changes(ctx.owner, nil, 1).items

    assert {%{workspaces: 2, versions: 0}, _output} = render()
    assert %{version: 3} = served(ctx.owner)
    assert %{version: 1} = served(ctx.in_platform)
    assert Policy.list_changes(ctx.owner, nil, 1).items == changes
  end

  test "an organisation that cannot be rendered is left as it was, and the others are not",
       ctx do
    # The organisation allows api.example; its Main's rule for *.example on /v1/*
    # cannot hold beside it.
    %{scope: refused, organisation: organisation} = sign_up_fixture()
    {:ok, _} = Policy.allow(refused, nil, %{host: "*.example", paths: ["/v1/*"]})
    Repo.insert!(%OrganisationPolicy.Policy{organisation_id: organisation.id})
    Repo.insert!(%Rule{organisation_id: organisation.id, action: "allow", host: "api.example"})
    before = served(refused)

    log =
      capture_log(fn ->
        assert {%{workspaces: 2, versions: 2}, _output} = render()
      end)

    assert log =~ "organisation policy render refused organisation=#{organisation.id}"
    assert served(refused) == before
    assert %{version: 3, deny: ["paste.example"]} = served(ctx.owner)
  end

  @tag with_features: [:observability, :security, :managed_organisations]
  test "renders nothing on an instance without the feature", ctx do
    assert {%{workspaces: 0, versions: 0}, _output} = render()
    assert %{version: 2, deny: []} = served(ctx.owner)
    assert served(ctx.in_platform) == nil
  end
end
