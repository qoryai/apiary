defmodule ApiaryPro.OrganisationPolicyTest do
  # The organisation's policy, the level above its workspaces' security policy: who reads
  # and changes it, what a write does to every workspace, the floor and the switch, and
  # what the core makes of it through `Apiary.Policy.Above`.
  # Not async: the instance's features are the node's, and every test here asks on an
  # instance with all of them, or without the feature.
  use Apiary.DataCase, async: false

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  import Ecto.Query
  import Apiary.OrganisationsFixtures
  import Apiary.AccessKeysFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Features, Organisations, Policy}
  alias Apiary.Audit.Entry
  alias Apiary.Policy.{Above, Error, Serving}
  alias ApiaryPro.OrganisationPolicy
  alias ApiaryPro.OrganisationPolicy.Rule

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
      admin: member_fixture(owner, :admin).scope,
      member: member_fixture(owner, :member).scope
    }
  end

  defp egress!(scope, holder \\ nil) do
    {:ok, configuration} = Policy.current_configuration(scope, holder)
    Jason.decode!(configuration.document)["security_policy"]["egress"]
  end

  defp version(scope) do
    case Policy.current_configuration(scope, nil) do
      {:ok, configuration} -> configuration.version
      _none -> nil
    end
  end

  defp entries(organisation) do
    Repo.all(
      from e in Entry,
        where: e.organisation_id == ^organisation.id and e.subject_kind == "organisation",
        where: like(e.action, "organisation_policy.%"),
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  describe "reading" do
    test "the owners, the admins and the readers read it; a member does not", ctx do
      {:ok, _} = OrganisationPolicy.allow(ctx.owner, %{host: "api.example", paths: ["/v1/*"]})

      for reader <- [ctx.owner, ctx.admin] do
        assert {:ok, %{policy: %{own_allows: true, enforce_everywhere: false}, rules: [rule]}} =
                 OrganisationPolicy.get(reader)

        assert %Apiary.Policy.Rule{host: "api.example", paths: ["/v1/*"], kind: "host"} = rule
      end

      instance_admin = instance_admin_fixture()
      reader = scope_in(instance_admin.user, ctx.organisation)
      assert {:ok, %{rules: [_rule]}} = OrganisationPolicy.get(reader)

      assert {:error, :forbidden} = OrganisationPolicy.get(ctx.member)
    end

    test "a rule of another organisation is not reachable", ctx do
      other = sign_up_fixture()
      {:ok, theirs} = OrganisationPolicy.allow(other.scope, %{host: "theirs.example"})
      {:ok, mine} = OrganisationPolicy.allow(ctx.owner, %{host: "mine.example"})

      assert {:ok, %{rules: [%{host: "mine.example"}]}} = OrganisationPolicy.get(ctx.owner)
      assert {:ok, %{host: "mine.example"}} = OrganisationPolicy.get_rule(ctx.owner, mine.id)

      assert {:error, %Error{reason: :not_found}} =
               OrganisationPolicy.get_rule(ctx.owner, theirs.id)

      assert {:error, %Error{reason: :not_found}} =
               OrganisationPolicy.remove_rule(ctx.owner, theirs.id)

      assert {:error, %Error{reason: :not_found}} =
               OrganisationPolicy.get_rule(ctx.owner, "nonsense")

      assert Repo.get(Rule, theirs.id)
    end

    test "there is no policy until the first change, and no level above the workspaces", ctx do
      assert {:ok, %{policy: nil, rules: []}} = OrganisationPolicy.get(ctx.owner)
      assert OrganisationPolicy.above_workspace(ctx.main) == nil
      assert Policy.effective(ctx.owner, nil).above == nil
    end
  end

  describe "who may change it" do
    test "an owner; an admin, a member and a reader do not", ctx do
      instance_admin = instance_admin_fixture()
      reader = scope_in(instance_admin.user, ctx.organisation)

      for scope <- [ctx.admin, ctx.member, reader] do
        assert {:error, %Error{reason: :forbidden, message: message}} =
                 OrganisationPolicy.allow(scope, %{host: "api.example"})

        assert message =~ "Only an owner"
        assert {:error, %Error{reason: :forbidden}} = OrganisationPolicy.set_floor(scope, true)
        assert {:error, %Error{reason: :forbidden}} = OrganisationPolicy.set_switch(scope, false)
      end

      assert entries(ctx.organisation) == []
      assert {:ok, _} = OrganisationPolicy.allow(ctx.owner, %{host: "api.example"})
    end

    test "the owner's level is read again under the locks", ctx do
      %{scope: second, membership: membership} = member_fixture(ctx.owner, :owner)
      {:ok, _} = Organisations.set_member_level(ctx.owner, membership.id, :admin)

      assert {:error, %Error{reason: :forbidden}} =
               OrganisationPolicy.allow(second, %{host: "api.example"})
    end

    @tag with_features: [:observability, :security, :managed_organisations]
    test "without the feature nothing is found, and nothing holds above the workspaces", ctx do
      assert {:error, :not_found} = OrganisationPolicy.get(ctx.owner)

      assert {:error, %Error{reason: :not_found}} =
               OrganisationPolicy.allow(ctx.owner, %{host: "api.example"})

      Repo.insert!(%OrganisationPolicy.Policy{
        organisation_id: ctx.organisation.id,
        enforce_everywhere: true
      })

      assert OrganisationPolicy.above_workspace(ctx.main) == nil
      assert Policy.effective(ctx.owner, nil).mode == "observe"
    end
  end

  describe "a rule" do
    test "is checked as the core checks a host rule", ctx do
      assert {:error, %Error{reason: :invalid, field: :host, message: message}} =
               OrganisationPolicy.allow(ctx.owner, %{host: "http://api.example/v1"})

      assert message =~ "A host is a lower-case name"

      assert {:error, %Error{reason: :invalid, field: :host}} =
               OrganisationPolicy.allow(ctx.owner, %{host: ""})

      assert {:error, %Error{reason: :invalid, field: :paths, message: message}} =
               OrganisationPolicy.allow(ctx.owner, %{host: "api.example", paths: ["v1"]})

      assert message =~ "is not a path"
      assert entries(ctx.organisation) == []
    end

    test "is one per host: the next write of the host changes it, keeping what it does not name",
         ctx do
      {:ok, added} =
        OrganisationPolicy.allow(ctx.owner, %{host: "API.example ", paths: ["/v1/*"]})

      assert added.host == "api.example"

      {:ok, changed} = OrganisationPolicy.allow(ctx.owner, %{host: "api.example"})
      assert changed.id == added.id
      assert changed.paths == ["/v1/*"]

      {:ok, opened} = OrganisationPolicy.allow(ctx.owner, %{host: "api.example", paths: nil})
      assert opened.paths == nil

      {:ok, denied} = OrganisationPolicy.deny(ctx.owner, %{host: "api.example", paths: ["/x"]})
      assert denied.id == added.id
      assert denied.action == "deny"
      assert denied.paths == nil

      assert {:ok, %{rules: [%{host: "api.example", action: "deny"}]}} =
               OrganisationPolicy.get(ctx.owner)

      assert Enum.map(entries(ctx.organisation), & &1.details["change"]) ==
               ~w(rule_added rule_changed rule_changed rule_changed)

      {:ok, removed} = OrganisationPolicy.remove_rule(ctx.owner, denied)
      assert removed.id == added.id
      assert {:ok, %{rules: []}} = OrganisationPolicy.get(ctx.owner)

      assert {:error, %Error{reason: :not_found}} =
               OrganisationPolicy.remove_rule(ctx.owner, denied)

      [_, _, _, _, last] = entries(ctx.organisation)
      assert last.details["change"] == "rule_removed"
      assert last.details["subject"] == "api.example"

      assert last.before["rules"] == [
               %{
                 "kind" => "host",
                 "action" => "deny",
                 "host" => "api.example",
                 "paths" => nil,
                 "locked" => false
               }
             ]

      assert last.after["rules"] == []
    end

    test "two of the organisation's own that cannot both hold are refused, with no workspace to render",
         ctx do
      {:ok, _} = OrganisationPolicy.allow(ctx.owner, %{host: "api.example"})

      assert {:error, %Error{message: message}} =
               OrganisationPolicy.allow(ctx.owner, %{host: "*.example", paths: ["/v1/*"]})

      assert message =~ "api.example"
      assert {:ok, %{rules: [%{host: "api.example"}]}} = OrganisationPolicy.get(ctx.owner)
    end
  end

  describe "a write" do
    test "renders every workspace again, the unmanaged ones too, and says the versions it left",
         ctx do
      # Platform has no row yet, as on an upgrade from a release without version 1.
      no_policy_version!(ctx.platform)
      {:ok, _} = Policy.allow(ctx.owner, nil, %{host: "cdn.example"})
      assert version(ctx.owner) == 2
      assert version(ctx.in_platform) == nil
      refute Policy.managed?(ctx.in_platform)

      Policy.subscribe(ctx.owner)
      Policy.subscribe(ctx.in_platform)
      OrganisationPolicy.subscribe(ctx.owner)

      {:ok, rule} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})

      assert version(ctx.owner) == 3
      assert version(ctx.in_platform) == 1
      assert Policy.managed?(ctx.in_platform)
      assert egress!(ctx.owner)["deny"] == ["paste.example"]
      assert egress!(ctx.in_platform)["deny"] == ["paste.example"]

      assert %{above: %Above{rules: [%{id: id}], floor: false, own_allows: true}} =
               Policy.effective(ctx.owner, nil)

      assert id == rule.id

      [entry] = entries(ctx.organisation)
      assert entry.action == "organisation_policy.edit"
      assert entry.workspace_id == nil
      assert entry.actor_id == ctx.owner.user.id
      assert entry.details["change"] == "rule_added"
      assert entry.details["subject"] == "paste.example"
      assert entry.details["rendered"] == %{ctx.main.id => 3, ctx.platform.id => 1}

      # Each workspace's history says the level changed, and names the cause.
      assert %{items: [change | _]} = Policy.list_changes(ctx.owner, nil, 1)
      assert change.action == "above_changed"
      assert change.cause == entry.id
      assert change.version_after == 3

      main_id = ctx.main.id
      platform_id = ctx.platform.id
      organisation_id = ctx.organisation.id
      assert_receive {:policy_changed, %{workspace_id: ^main_id, action: "above_changed"}}
      assert_receive {:policy_changed, %{workspace_id: ^platform_id, action: "above_changed"}}

      assert_receive {:organisation_policy_changed,
                      %{organisation_id: ^organisation_id, action: :"organisation_policy.edit"}}
    end

    test "leaves a workspace whose bytes stay the same at its version", ctx do
      {:ok, _} = Policy.allow(ctx.owner, nil, %{host: "api.example"})
      {:ok, _} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})
      assert version(ctx.owner) == 3
      assert version(ctx.in_platform) == 2

      # The organisation's allow of api.example holds over Main's own: the same bytes.
      {:ok, _} = OrganisationPolicy.allow(ctx.owner, %{host: "api.example"})
      assert version(ctx.owner) == 3
      assert version(ctx.in_platform) == 3

      [_first, second] = entries(ctx.organisation)
      assert second.details["rendered"] == %{ctx.main.id => nil, ctx.platform.id => 3}
    end

    test "is refused, and nothing is written, when a workspace's rules cannot resolve with it",
         ctx do
      {:ok, _} = Policy.allow(ctx.in_platform, nil, %{host: "*.example", paths: ["/v1/*"]})
      {:ok, _} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})
      assert version(ctx.in_platform) == 3

      assert {:error, %Error{message: message}} =
               OrganisationPolicy.allow(ctx.owner, %{host: "api.example"})

      assert message =~ "In Platform:"
      assert message =~ "*.example"

      assert {:ok, %{rules: [%{host: "paste.example"}]}} = OrganisationPolicy.get(ctx.owner)
      assert version(ctx.in_platform) == 3
      assert length(entries(ctx.organisation)) == 1
    end

    test "nothing is written when a setting holds already", ctx do
      assert {:ok, policy} = OrganisationPolicy.set_switch(ctx.owner, true)
      assert policy.own_allows
      assert {:ok, _} = OrganisationPolicy.set_floor(ctx.owner, false)
      assert entries(ctx.organisation) == []
      # Main keeps the version 1 it got when it was created.
      assert version(ctx.owner) == 1

      # The row is there all the same, so the level holds above the workspaces.
      assert %Above{rules: [], floor: false, own_allows: true} =
               OrganisationPolicy.above_workspace(ctx.main)
    end
  end

  describe "the floor" do
    test "fixes every workspace's and target's mode to enforce, and is undone", ctx do
      {:ok, policy} = OrganisationPolicy.set_floor(ctx.owner, true)
      assert policy.enforce_everywhere

      assert %{mode: "enforce", mode_source: :organisation} = Policy.effective(ctx.owner, nil)

      assert %{mode: "enforce", mode_source: :organisation} =
               Policy.effective(ctx.in_platform, nil)

      assert egress!(ctx.in_platform)["mode"] == "enforce"
      assert Policy.get_mode(ctx.owner) == "observe"

      assert {:error, %Error{reason: :fixed, field: :mode, message: message}} =
               Policy.set_mode(ctx.owner, "observe")

      assert message =~ ctx.organisation.name

      [entry] = entries(ctx.organisation)
      assert entry.action == "organisation_policy.set_floor"
      assert entry.details["change"] == "floor_changed"
      assert entry.before["enforce_everywhere"] == false
      assert entry.after["enforce_everywhere"] == true
      assert entry.details["rendered"] == %{ctx.main.id => 2, ctx.platform.id => 2}

      {:ok, _} = OrganisationPolicy.set_floor(ctx.owner, false)
      assert %{mode: "observe", mode_source: :workspace} = Policy.effective(ctx.owner, nil)
      assert {:ok, "enforce"} = Policy.set_mode(ctx.owner, "enforce")
    end
  end

  describe "the switch" do
    test "off, a workspace's allow is listed but not in force, and its deny still holds", ctx do
      {:ok, _} = Policy.allow(ctx.owner, nil, %{host: "cdn.example"})
      {:ok, _} = Policy.deny(ctx.owner, nil, %{host: "tracker.example"})
      {:ok, _} = OrganisationPolicy.allow(ctx.owner, %{host: "api.example"})
      assert egress!(ctx.owner)["allow"] == ["api.example", "cdn.example"]

      {:ok, policy} = OrganisationPolicy.set_switch(ctx.owner, false)
      refute policy.own_allows

      effective = Policy.effective(ctx.owner, nil)
      assert effective.allow == ["api.example"]
      assert effective.deny == ["tracker.example"]

      assert %{in_force: false, reason: :only_above_allows} =
               Enum.find(effective.entries, &(&1.host == "cdn.example"))

      assert egress!(ctx.owner)["allow"] == ["api.example"]

      [_, entry] = entries(ctx.organisation)
      assert entry.action == "organisation_policy.set_switch"
      assert entry.details["change"] == "switch_changed"
      assert entry.after["own_allows"] == false
    end
  end

  describe "the workspaces" do
    test "are summed up under the policy: the mode, their own rules and the allows not in force",
         ctx do
      {:ok, _} = Policy.allow(ctx.owner, nil, %{host: "cdn.example"})
      {:ok, _} = Policy.allow(ctx.owner, nil, %{host: "paste.example"})
      {:ok, _} = Policy.deny(ctx.owner, nil, %{host: "tracker.example"})
      {:ok, _} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})
      {:ok, _} = OrganisationPolicy.set_floor(ctx.owner, true)

      assert {:ok, [main, platform]} = OrganisationPolicy.workspaces_summary(ctx.owner)

      assert %{mode: "enforce", own_rules: 3, own_allows: 2, allows_off: 1, version: 6} = main
      # What the floor holds over: the mode the workspace set for itself.
      assert %{own_mode: "observe", targets_observing: 0} = main
      assert main.workspace.id == ctx.main.id
      assert %{mode: "enforce", own_rules: 0, own_allows: 0, allows_off: 0, version: 3} = platform

      {:ok, _} = OrganisationPolicy.set_switch(ctx.owner, false)
      assert {:ok, [%{allows_off: 2} | _]} = OrganisationPolicy.workspaces_summary(ctx.owner)

      assert {:error, :forbidden} = OrganisationPolicy.workspaces_summary(ctx.member)
    end

    # A workspace has its organisation's features, so no workspace is left out of the
    # policy: each one's runs are served the organisation's rules.
    test "are each served the organisation's rules in their runs' configuration", ctx do
      {:ok, _} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})

      for scope <- [ctx.owner, ctx.in_platform] do
        assert ApiaryPro.Features.hidden(scope) ==
                 ApiaryPro.Features.hidden(%{scope | workspace: nil})

        %{access_key: key} = access_key_fixture(scope)
        assert Serving.managed?(key)
        assert {:ok, configuration} = Serving.fetch(key, %{})

        assert Jason.decode!(configuration.document)["security_policy"]["egress"]["deny"] ==
                 ["paste.example"]
      end
    end

    test "a workspace created under the policy gets its version 1 at once", ctx do
      {:ok, _} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})

      {:ok, workspace} =
        Organisations.create_workspace(ctx.owner, %{
          "name" => "Staging",
          "slug" => "staging",
          "domain" => "software"
        })

      there = workspace_scope(ctx.owner.user, workspace)
      assert version(there) == 1
      assert egress!(there)["deny"] == ["paste.example"]
      assert %{items: [%{action: "above_changed"}]} = Policy.list_changes(there, nil, 1)

      # Without a policy, a new workspace gets its version 1 too, with no rules.
      other = sign_up_fixture()

      {:ok, workspace} =
        Organisations.create_workspace(other.scope, %{
          "name" => "Staging",
          "slug" => "staging",
          "domain" => "software"
        })

      in_staging = workspace_scope(other.user, workspace)
      assert Policy.managed?(in_staging)
      assert version(in_staging) == 1
      assert egress!(in_staging)["deny"] == nil
      # The core's version 1, and no render of the organisation's level when it was created.
      assert %{items: [%{action: "first_version"}]} = Policy.list_changes(in_staging, nil, 1)
    end

    test "list the organisation's changes, newest first, with who and what they rendered",
         ctx do
      {:ok, _} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})
      {:ok, _} = OrganisationPolicy.set_floor(ctx.owner, true)

      assert {:ok, %{items: [floor, deny], page: 1, pages: 1, total: 2}} =
               OrganisationPolicy.list_changes(ctx.owner, 1)

      assert floor.action == :"organisation_policy.set_floor"
      assert floor.change == "floor_changed"
      assert floor.changed_by_id == ctx.owner.user.id
      assert floor.rendered == %{ctx.main.id => 3, ctx.platform.id => 3}
      assert deny.change == "rule_added"
      assert deny.subject == "paste.example"
      assert deny.before["rules"] == []
      assert [%{"host" => "paste.example"}] = deny.after["rules"]

      assert {:ok, %{items: [_, _], page: 1}} = OrganisationPolicy.list_changes(ctx.owner, 7)
      assert {:error, :forbidden} = OrganisationPolicy.list_changes(ctx.member, 1)
    end

    test "count the use of the organisation's rules over every workspace", ctx do
      {:ok, rule} = OrganisationPolicy.allow(ctx.owner, %{host: "api.example"})
      since = DateTime.add(DateTime.utc_now(), -14 * 24 * 3600, :second)

      assert {:ok, %{}} = OrganisationPolicy.rule_activity(ctx.owner, since)
      assert OrganisationPolicy.rule_activity(ctx.member, since) == :unavailable
      assert is_binary(rule.id)
    end
  end

  describe "a policy request" do
    test "accepted under the floor keeps its rules and refuses a mode of observe", _ctx do
      operator = operator_fixture()
      client = client_fixture(operator.scope, "Acme")
      owner = client.owner.scope

      {:ok, _} = OrganisationPolicy.set_floor(owner, true)

      {:ok, request} =
        ApiaryPro.PolicyRequests.send_request(operator.scope, %{
          "changes" => %{
            "mode" => "observe",
            "rules" => [
              %{"change" => "rule_added", "action" => "allow", "host" => "api.harness.example"}
            ]
          },
          "note" => "The harness calls its API."
        })

      answer =
        Repo.get_by!(ApiaryPro.PolicyRequests.Answer,
          request_id: request.id,
          organisation_id: client.organisation.id
        )

      assert {:error, %Error{reason: :fixed, message: message}} =
               ApiaryPro.PolicyRequests.accept(owner, answer.id, [client.workspace.id])

      assert message =~ "Enforce is required by"
      assert Policy.list_rules(owner, nil) == []
    end
  end
end
