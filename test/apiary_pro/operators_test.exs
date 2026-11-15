defmodule ApiaryPro.OperatorsTest do
  @moduledoc """
  Operators and the workspaces they operate: the operator's people reading those
  workspaces and changing nothing there, the people of an organisation whose workspace an
  operator operates, an instance admin's reading every organisation, the instance actions,
  and the last-owner rule across kinds.
  """
  # Not async: the rows are asked on an instance with every feature, which is the node's,
  # and instance admins are owners of the suite's one instance organisation.
  use Apiary.DataCase, async: false

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Access, Deletion, Features, Organisations, Policy}
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry
  alias Apiary.Deletion.PurgedOrganisation
  alias Apiary.Organisations.{Membership, Organisation, Workspace}
  alias ApiaryPro.{OperatedPlace, Operators, Tenants}
  alias ApiaryPro.Tenants.Tenant

  @moduletag with_features: Features.all()

  defp entries(organisation_id, action) do
    Repo.all(
      from e in Entry,
        where: e.organisation_id == ^organisation_id and e.action == ^action,
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  # The edits of the policy of the organisation's workspaces, without the version 1 that
  # each workspace got, by the instance, when it was created.
  defp person_edits(organisation_id) do
    organisation_id
    |> entries("security_policy.edit")
    |> Enum.reject(&(&1.details["change"] == "first_version"))
  end

  # The organisation as the database has it now, carrying its tenant.
  defp reload_organisation(%Organisation{id: id}),
    do: Organisation |> Repo.get!(id) |> Tenants.put()

  # An operator that operates the workspace Main of another organisation, and a person of
  # each level in the operator, each with their scope in Main.
  defp operator_with_operated(_ctx) do
    operator = operator_fixture()
    operated = operated_fixture(operator.scope)
    admin = member_fixture(operator.scope, :admin)
    member = member_fixture(operator.scope, :member)

    %{
      operator: operator,
      operated: operated,
      owner_in_operated: operated.scope,
      admin: admin,
      admin_in_operated: scope_in(admin.user, operated.organisation, operated.workspace),
      member: member,
      member_in_operated: scope_in(member.user, operated.organisation, operated.workspace),
      organisation_owner: operated.owner.scope
    }
  end

  describe "an operator's people in a workspace it operates" do
    setup :operator_with_operated

    test "change nothing there, whatever their level in the operator, in can?/3 and authorize/3",
         ctx do
      organisation = ctx.operated.organisation
      workspace = ctx.operated.workspace

      asked = [
        {:"security_policy.lock", workspace},
        {:"security_policy.edit", workspace},
        {:"member.change_level", organisation},
        {:"organisation.delete", organisation},
        {:"organisation.rename", organisation},
        {:"workspace.rename", workspace},
        {:"member.invite", workspace},
        {:"node.create", workspace},
        {:"retention.edit", workspace}
      ]

      # In Main, which the operator operates, forbidden; of what the organisation owns as a
      # whole, and an action asked of the organisation, such as an invitation, not found.
      for {action, subject} <- asked,
          scope <- [ctx.owner_in_operated, ctx.admin_in_operated, ctx.member_in_operated] do
        refute Access.can?(scope, action, subject), "can? #{action}"

        refusal =
          if subject == workspace and Access.action(action).asked_of != :organisation,
            do: :forbidden,
            else: :not_found

        assert Access.authorize(scope, action, subject) == {:error, refusal}, "#{action}"
      end

      for scope <- [ctx.owner_in_operated, ctx.admin_in_operated, ctx.member_in_operated] do
        assert Access.level(scope) == nil
        assert Access.reach(scope) == :operator
        assert Access.reader(scope) == :operator
        assert scope.membership == nil
      end
    end

    test "read everything in Main at every level: the runs, their terminals and the policy",
         ctx do
      for scope <- [ctx.owner_in_operated, ctx.admin_in_operated, ctx.member_in_operated],
          action <- [:"run.read", :"run.read_log", :"security_policy.read"] do
        assert Access.authorize(scope, action, ctx.operated.workspace) == :ok
      end

      # The organisation's policy and trail are not there for a member of the operator.
      assert Access.authorize(
               ctx.member_in_operated,
               :"organisation_policy.read",
               ctx.operated.organisation
             ) == {:error, :not_found}

      assert Access.authorize(ctx.member_in_operated, :"audit.read", ctx.operated.organisation) ==
               {:error, :not_found}

      %{scope: own_member} = member_fixture(ctx.organisation_owner, :member)

      assert Access.authorize(own_member, :"audit.read", ctx.operated.organisation) ==
               {:error, :forbidden}
    end

    test "reach the workspaces the operator operates and no other, a member of the operator too",
         ctx do
      second = workspace_fixture(ctx.operated.organisation, "Second")

      for user <- [ctx.operator.user, ctx.admin.user, ctx.member.user] do
        scope = scope_in(user, ctx.operated.organisation, ctx.operated.workspace)
        assert %Scope{workspace: %Workspace{id: id}} = scope
        assert id == ctx.operated.workspace.id
        refute Access.reaches_every_workspace_in?(scope)
        assert Access.authorize(scope, :"run.read", ctx.operated.workspace) == :ok
        assert scope_in(user, ctx.operated.organisation, second) == nil
      end
    end

    test "are read again by authorize/3, which fails closed", ctx do
      stale_admin = ctx.admin_in_operated

      {:ok, _} = Organisations.remove_member(ctx.operator.scope, ctx.admin.membership.id)

      # The page's scope still carries the operator's membership; the database does not.
      assert Access.can?(stale_admin, :"run.read", stale_admin.workspace)

      assert Access.authorize(stale_admin, :"run.read", stale_admin.workspace) ==
               {:error, :forbidden}

      assert Access.reload(stale_admin).reach == nil
    end

    test "with a membership in the organisation too, that membership decides what they change",
         ctx do
      # A member of the operator, made an admin of the organisation by its owner.
      %{token: token} =
        invitation_fixture(ctx.organisation_owner, %{"email" => ctx.member.user.email})

      {:ok, membership} = Organisations.accept_invitation(ctx.member.user, token)
      {:ok, _} = Organisations.set_member_level(ctx.organisation_owner, membership.id, :admin)

      scope = scope_in(ctx.member.user, ctx.operated.organisation, ctx.operated.workspace)
      assert scope.membership.level == :admin
      assert Access.reach(scope) == :operator
      assert Access.level(scope) == :admin
      assert Access.authorize(scope, :"workspace.rename", scope.workspace) == :ok

      # An admin of the operator, a member of the organisation: a member there.
      %{token: token} =
        invitation_fixture(ctx.organisation_owner, %{"email" => ctx.admin.user.email})

      {:ok, _membership} = Organisations.accept_invitation(ctx.admin.user, token)
      scope = scope_in(ctx.admin.user, ctx.operated.organisation, ctx.operated.workspace)
      assert scope.membership.level == :member
      assert Access.level(scope) == :member
      assert Access.authorize(scope, :"security_policy.edit", scope.workspace) == :ok

      assert Access.authorize(scope, :"workspace.rename", scope.workspace) ==
               {:error, :forbidden}

      # What the organisation owns as a whole they read at their level there.
      assert Access.authorize(scope, :"audit.read", ctx.operated.organisation) ==
               {:error, :forbidden}
    end

    test "reach no organisation whose workspace the operator does not operate", ctx do
      %{organisation: elsewhere} = sign_up_fixture()
      assert scope_in(ctx.operator.user, elsewhere) == nil
      assert scope_in(ctx.member.user, elsewhere) == nil
    end

    test "are not listed among the organisation's members, which they do not see", ctx do
      assert Organisations.list_members(ctx.owner_in_operated) == []

      assert [%Membership{level: :owner, user_id: owner_id}] =
               Organisations.list_members(ctx.organisation_owner)

      assert owner_id == ctx.operated.owner.user.id
    end
  end

  describe "a policy write in an organisation with an operated workspace" do
    setup :operator_with_operated

    @tag needs: :security
    test "the organisation's owner writes its policy, the membership held FOR SHARE while it is written",
         ctx do
      handler = "operated-share-#{System.unique_integer()}"
      parent = self()

      :telemetry.attach(
        handler,
        [:apiary, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if self() == parent, do: send(parent, {:query, query})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, _rule} = Policy.allow(ctx.organisation_owner, nil, %{host: "api.example"})

      queries = collect_queries()
      # The organisation and the operator of its workspace FOR SHARE, in one statement
      # (`Apiary.Organisations.lock_organisations/2`), the membership FOR SHARE, the rows
      # it refers to FOR KEY SHARE: a change of the owner's level or a suspension waits for
      # the write.
      assert Enum.any?(queries, &(&1 =~ "FROM organisations o" and &1 =~ "FOR SHARE"))
      assert Enum.any?(queries, &(&1 =~ ~s(FROM "memberships") and &1 =~ "FOR SHARE OF"))

      [entry] = person_edits(ctx.operated.organisation.id)
      assert {entry.actor_kind, entry.actor_id} == {:person, ctx.operated.owner.user.id}
      assert entry.workspace_id == ctx.operated.workspace.id

      {:ok, rule} = Policy.allow(ctx.organisation_owner, nil, %{host: "git.example"})
      assert {:ok, _locked} = Policy.lock(ctx.organisation_owner, rule)
    end

    @tag needs: :security
    test "the operator's people write none of it, and are told they read it", ctx do
      {:ok, rule} = Policy.allow(ctx.organisation_owner, nil, %{host: "api.example"})

      for scope <- [ctx.owner_in_operated, ctx.admin_in_operated, ctx.member_in_operated] do
        assert {:error, %Policy.Error{reason: :forbidden, message: message}} =
                 Policy.allow(scope, nil, %{host: "git.example"})

        assert message ==
                 "You can read this organisation as a person of its operator, and change nothing here."

        assert {:error, %Policy.Error{reason: :forbidden}} = Policy.lock(scope, rule)
      end

      assert [_one] = person_edits(ctx.operated.organisation.id)
    end
  end

  describe "an organisation with an operated workspace" do
    test "keeps its people: its owner invites them and makes owners, as anywhere" do
      operator = operator_fixture()
      operated = operated_fixture(operator.scope)

      assert operated.owner.membership.level == :owner
      assert Access.reach(operated.owner.scope) == :membership

      %{membership: second, scope: admin} = member_fixture(operated.owner.scope, :admin)
      assert second.level == :admin

      # Its admin invites a member, who joins as one; its owner makes them an owner.
      %{membership: third} = member_fixture(admin)
      assert third.level == :member

      assert {:ok, %Membership{level: :owner}} =
               Organisations.set_member_level(operated.owner.scope, third.id, :owner)

      assert {:error, :forbidden} = Organisations.set_member_level(admin, second.id, :owner)
    end

    test "an ordinary invitation makes a member there" do
      operator = operator_fixture()
      operated = operated_fixture(operator.scope)
      %{membership: joined} = member_fixture(operated.owner.scope)
      assert joined.level == :member
    end
  end

  describe "kinds" do
    setup do
      %{admin: instance_admin_fixture()}
    end

    test "an instance admin makes an organisation an operator, and an operator an organisation again",
         %{admin: admin} do
      %{organisation: organisation} = sign_up_fixture()

      assert {:ok, %Organisation{edition: %{tenant: %Tenant{kind: :operator}}}} =
               Operators.change_kind(admin.instance_scope, organisation.id, :operator)

      assert {:ok, %Organisation{edition: %{tenant: %Tenant{kind: :organisation}}}} =
               Operators.change_kind(admin.instance_scope, organisation.id, "organisation")

      assert [made, unmade] = entries(organisation.id, "instance.change_kind")
      assert {made.actor_kind, made.actor_id} == {:person, admin.user.id}
      assert {made.before, made.after} == {%{"kind" => "organisation"}, %{"kind" => "operator"}}

      assert {unmade.before, unmade.after} ==
               {%{"kind" => "operator"}, %{"kind" => "organisation"}}

      # The kind it has already: nothing changes, and nothing is recorded.
      assert {:ok, _} =
               Operators.change_kind(admin.instance_scope, organisation.id, :organisation)

      assert length(entries(organisation.id, "instance.change_kind")) == 2
    end

    test "a change of kind tells the organisation's people, and its entry keeps no address",
         %{admin: admin} do
      %{organisation: organisation, user: owner} = sign_up_fixture()
      Phoenix.PubSub.subscribe(Apiary.PubSub, Organisations.membership_topic(owner.id))

      from_a_browser =
        Scope.put_origin(admin.instance_scope, %{remote_ip: "192.0.2.7", user_agent: "Browser"})

      {:ok, _} = Operators.change_kind(from_a_browser, organisation.id, :operator)
      assert_receive {:membership_changed, _change}

      [entry] = entries(organisation.id, "instance.change_kind")
      assert {entry.remote_ip, entry.user_agent} == {nil, nil}
      assert {entry.actor_kind, entry.actor_id} == {:person, admin.user.id}
    end

    test "an organisation with an operated workspace is made no operator, nor an operator that operates a workspace an organisation",
         %{admin: admin} do
      operator = operator_fixture()
      operated = operated_fixture(operator.scope)

      assert {:error, :has_operated_workspaces} =
               Operators.change_kind(admin.instance_scope, operated.organisation.id, :operator)

      assert {:error, :has_operated_workspaces} =
               Operators.change_kind(
                 admin.instance_scope,
                 operator.organisation.id,
                 :organisation
               )

      # Its workspace's organisation deleted, and not yet purged, the link is there still.
      {:ok, _} = Deletion.delete_organisation(operated.owner.scope, operated.organisation.slug)

      assert {:error, :has_operated_workspaces} =
               Operators.change_kind(
                 admin.instance_scope,
                 operator.organisation.id,
                 :organisation
               )

      assert Tenants.kind(reload_organisation(operator.organisation)) == :operator
      assert entries(operator.organisation.id, "instance.change_kind") |> length() == 1
    end

    test "the instance organisation's kind changes as any other's, and it stays the instance's",
         %{admin: admin} do
      here = instance_organisation()
      was = Tenants.kind(here)
      other = if was == :operator, do: :organisation, else: :operator
      Phoenix.PubSub.subscribe(Apiary.PubSub, Organisations.membership_topic(admin.user.id))

      from_a_browser =
        Scope.put_origin(admin.instance_scope, %{remote_ip: "192.0.2.7", user_agent: "Browser"})

      assert {:ok, changed} = Operators.change_kind(from_a_browser, here.id, other)
      assert %Tenant{instance_organisation: true} = Tenants.tenant(changed)
      assert Tenants.kind(instance_organisation()) == other
      assert Tenants.instance_organisation_id() == here.id
      # Its people's pages load their scope again, with the features of its kind.
      assert_receive {:membership_changed, _change}

      assert {:ok, _back} = Operators.change_kind(admin.instance_scope, here.id, was)
      assert Tenants.kind(instance_organisation()) == was

      # Each an entry in its trail, by the instance admin, which keeps where they acted
      # from, as a change an owner makes there does.
      assert [there, back] = entries(here.id, "instance.change_kind")
      assert {there.actor_kind, there.actor_id} == {:person, admin.user.id}
      assert {there.before, there.after} == {%{"kind" => "#{was}"}, %{"kind" => "#{other}"}}
      assert {there.remote_ip, there.user_agent} == {"192.0.2.7", "Browser"}
      assert {back.before, back.after} == {%{"kind" => "#{other}"}, %{"kind" => "#{was}"}}
    end

    test "the instance organisation made an operator operates a workspace, and is no organisation again until it operates none",
         %{admin: admin} do
      here = instance_organisation()

      {:ok, operator} =
        if Tenants.operator?(here),
          do: {:ok, here},
          else: Operators.change_kind(admin.instance_scope, here.id, :operator)

      assert Tenants.operator?(operator)
      admin_scope = scope_in(admin.user, operator)
      operated = operated_fixture(admin_scope)

      assert {:error, :has_operated_workspaces} =
               Operators.change_kind(admin.instance_scope, here.id, :organisation)

      # Nothing in the product ends the link to Main: the test deletes the row.
      id = operated.organisation.id

      Repo.delete_all(
        from l in ApiaryPro.Operators.WorkspaceOperator, where: l.organisation_id == ^id
      )

      assert {:ok, organisation} =
               Operators.change_kind(admin.instance_scope, here.id, :organisation)

      refute Tenants.operator?(organisation)

      admin_scope = scope_in(admin.user, organisation)
      assert Access.can?(admin_scope, :"instance.read", organisation)
    end

    test "only an instance admin, in the instance organisation, changes a kind", %{admin: admin} do
      %{organisation: organisation, scope: owner} = sign_up_fixture()
      %{scope: operator_admin} = member_fixture(admin.instance_scope, :admin)

      assert {:error, :forbidden} =
               Operators.change_kind(operator_admin, organisation.id, :operator)

      assert {:error, :not_found} = Operators.change_kind(owner, organisation.id, :operator)
      assert Tenants.kind(reload_organisation(organisation)) == :organisation

      # An organisation passed off as the instance organisation has another id, so
      # `can?/3` returns false and `authorize/3` returns `:not_found`.
      crafted = %{
        owner
        | organisation:
            Tenants.put_tenant(owner.organisation, %Tenant{
              kind: :operator,
              instance_organisation: true
            })
      }

      refute Access.can?(crafted, :"instance.read", crafted.organisation)

      assert Access.authorize(crafted, :"instance.read", crafted.organisation) ==
               {:error, :not_found}
    end

    @tag with_features: [:observability, :security]
    test "without managed_organisations no kind changes", %{admin: admin} do
      %{organisation: organisation} = sign_up_fixture()

      assert {:error, :not_found} =
               Operators.change_kind(admin.instance_scope, organisation.id, :operator)
    end
  end

  describe "the instance" do
    setup do
      %{admin: instance_admin_fixture()}
    end

    test "an instance admin lists every organisation, with its kind", %{admin: admin} do
      operator = operator_fixture()
      operated = operated_fixture(operator.scope)
      %{organisation: plain} = sign_up_fixture()

      assert {:ok, [first | _] = rows} = Operators.list_organisations(admin.instance_scope)
      assert Tenants.instance_organisation?(first.organisation)
      rows = Map.new(rows, &{&1.organisation.id, &1})
      kind = &Tenants.kind(rows[&1].organisation)

      assert kind.(operator.organisation.id) == :operator
      assert kind.(operated.organisation.id) == :organisation
      assert kind.(plain.id) == :organisation

      for id <- [operator.organisation.id, operated.organisation.id, plain.id],
          do: assert(Map.keys(rows[id]) |> Enum.sort() == [:only_owner?, :organisation])
    end

    test "nobody else lists them", %{admin: admin} do
      %{scope: operator_admin} = member_fixture(admin.instance_scope, :admin)
      %{scope: owner} = sign_up_fixture()

      assert {:error, :forbidden} = Operators.list_organisations(operator_admin)
      assert {:error, :not_found} = Operators.list_organisations(owner)
    end

    test "an instance admin creates an organisation or an operator, and is its first owner",
         %{admin: admin} do
      for kind <- ["organisation", "operator"] do
        assert {:ok, %{organisation: created, workspace: nil, membership: membership}} =
                 Operators.create_organisation(admin.instance_scope, %{
                   "name" => "New #{kind}",
                   "kind" => kind
                 })

        tenant = tenant_of(created)
        assert Atom.to_string(tenant.kind) == kind
        refute tenant.instance_organisation
        refute Organisations.has_workspace?(created)
        assert {membership.user_id, membership.level} == {admin.user.id, :owner}

        action = "instance.create_#{kind}"
        [entry] = entries(created.id, action)
        assert {entry.actor_kind, entry.actor_id} == {:person, admin.user.id}
        assert entry.after == %{"kind" => kind}

        # They act there as its owner, through their membership.
        scope = scope_in(admin.user, created)
        assert Access.reach(scope) == :membership
        assert Access.level(scope) == :owner
      end
    end

    test "creating is refused elsewhere, for a kind that is neither, and for a name refused",
         %{admin: admin} do
      %{scope: owner} = sign_up_fixture()

      assert {:error, :not_found} =
               Operators.create_organisation(owner, %{"name" => "Acme", "kind" => "organisation"})

      assert {:error, :not_found} =
               Operators.create_organisation(admin.instance_scope, %{
                 "name" => "Acme",
                 "kind" => "instance_organisation"
               })

      assert {:error, %Ecto.Changeset{}} =
               Operators.create_organisation(admin.instance_scope, %{
                 "name" => "",
                 "kind" => "organisation"
               })
    end

    @tag with_features: [:observability, :security]
    test "an operator is created only with managed_organisations", %{admin: admin} do
      assert {:error, :not_found} =
               Operators.create_organisation(admin.instance_scope, %{
                 "name" => "Acme",
                 "kind" => "operator"
               })

      assert {:ok, _} =
               Operators.create_organisation(admin.instance_scope, %{
                 "name" => "Acme",
                 "kind" => "organisation"
               })
    end

    test "an instance admin purges an organisation at once, and the instance organisation's trail says so",
         %{admin: admin} do
      %{organisation: organisation} = sign_up_fixture()

      assert {:ok, :purged} =
               ApiaryPro.Deletion.purge_on_request(
                 admin.instance_scope,
                 organisation.id,
                 organisation.slug
               )

      refute Repo.get(Organisation, organisation.id)

      assert %PurgedOrganisation{trigger: "erasure_request", requested_by_id: requested_by} =
               Repo.get!(PurgedOrganisation, organisation.id)

      assert requested_by == admin.user.id

      [entry] =
        admin.instance_scope.organisation.id
        |> entries("instance.purge_organisation")

      assert {entry.actor_kind, entry.actor_id} == {:person, admin.user.id}

      assert entry.details == %{
               "organisation_id" => organisation.id,
               "trigger" => "erasure_request"
             }
    end

    test "the purge is refused for the instance organisation, an operator that operates a workspace, a wrong slug and anyone else",
         %{admin: admin} do
      operator = operator_fixture()
      _operated = operated_fixture(operator.scope)
      %{organisation: organisation, scope: owner} = sign_up_fixture()
      %{scope: operator_admin} = member_fixture(admin.instance_scope, :admin)
      here = instance_organisation()

      assert {:error, :forbidden} =
               ApiaryPro.Deletion.purge_on_request(admin.instance_scope, here.id, here.slug)

      assert {:error, :has_operated_workspaces} =
               ApiaryPro.Deletion.purge_on_request(
                 admin.instance_scope,
                 operator.organisation.id,
                 operator.organisation.slug
               )

      assert {:error, :confirmation} =
               ApiaryPro.Deletion.purge_on_request(
                 admin.instance_scope,
                 organisation.id,
                 "not-it"
               )

      assert {:error, :forbidden} =
               ApiaryPro.Deletion.purge_on_request(
                 operator_admin,
                 organisation.id,
                 organisation.slug
               )

      assert {:error, :not_found} =
               ApiaryPro.Deletion.purge_on_request(owner, organisation.id, organisation.slug)

      for org <- [here, operator.organisation, organisation] do
        assert %Organisation{deletion_marked_at: nil} = Repo.get!(Organisation, org.id)
      end

      assert entries(here.id, "instance.purge_organisation") == []
    end

    test "an instance admin reads every other organisation, and changes nothing there",
         %{admin: admin} do
      home = sign_up_fixture()
      scope = scope_in(admin.user, home.organisation, home.workspace)

      assert Access.reach(scope) == :instance
      assert scope.membership == nil
      assert Access.reaches_every_workspace_in?(scope)
      reads = ApiaryPro.Access.reads()

      for action <- [:"run.read", :"run.read_log", :"security_policy.read"] do
        assert Access.authorize(scope, action, home.workspace) == :ok
      end

      assert Access.authorize(scope, :"audit.read", home.organisation) == :ok

      for action <- Access.actions() -- reads,
          subject <- [home.organisation, home.workspace] do
        refute Access.can?(scope, action, subject), "#{action} on #{inspect(subject.__struct__)}"
        assert {:error, _} = Access.authorize(scope, action, subject)
      end

      # A workspace no one added them to, as any other.
      second = workspace_fixture(home.organisation, "Second")
      assert %Scope{} = scope_in(admin.user, home.organisation, second)

      # No longer an instance admin, they read nothing there.
      %{user: other} = sign_up_fixture()
      {:ok, _} = Organisations.grant_instance_admin(other)
      {:ok, _} = Organisations.revoke_instance_admin(admin.user)
      assert Access.authorize(scope, :"run.read", home.workspace) == {:error, :forbidden}
      assert scope_in(admin.user, home.organisation) == nil
    end

    @tag needs: :security
    test "an instance admin's refused change says the reach is read-only", %{admin: admin} do
      home = sign_up_fixture()
      scope = scope_in(admin.user, home.organisation, home.workspace)

      assert {:error, %Policy.Error{reason: :forbidden, message: message}} =
               Policy.allow(scope, nil, %{host: "api.example"})

      assert message ==
               "You can read this organisation as support, and change nothing here."
    end

    test "in an operator and an organisation it operates a workspace of, an instance admin reads as elsewhere, and as the operator's people where the instance organisation operates it",
         %{admin: admin} do
      operator = operator_fixture()
      operated = operated_fixture(operator.scope)

      for organisation <- [operator.organisation, operated.organisation] do
        scope = scope_in(admin.user, organisation)
        assert Access.reach(scope) == :instance
        refute Access.can?(scope, :"organisation.rename", organisation)
      end

      # The instance organisation, made an operator, operates the workspace Main of another
      # organisation: they reach Main as its operator's people, keep the instance admin's
      # reach beside it, so read what the organisation owns as well, and change none of it.
      by_instance = operated_fixture(make_instance_organisation_an_operator(admin))
      assert Access.reach(by_instance.scope) == :operator
      assert Access.level(by_instance.scope) == nil
      assert Access.authorize(by_instance.scope, :"run.read", by_instance.workspace) == :ok

      assert Access.authorize(by_instance.scope, :"audit.read", by_instance.organisation) ==
               :ok

      assert Access.authorize(by_instance.scope, :"secret.read", by_instance.workspace) == :ok

      assert Access.authorize(
               by_instance.scope,
               :"organisation.rename",
               by_instance.organisation
             ) == {:error, :not_found}
    end

    test "the instance organisation's admins and members reach it, read the workspace it operates, and nothing beyond",
         %{admin: admin} do
      %{organisation: elsewhere} = sign_up_fixture()
      by_instance = operated_fixture(make_instance_organisation_an_operator(admin))

      for level <- [:admin, :member] do
        %{user: user} = member_fixture(admin.instance_scope, level)
        refute Access.instance_admin?(Scope.for_user(user))
        assert scope_in(user, elsewhere) == nil

        scope = scope_in(user, by_instance.organisation, by_instance.workspace)
        assert Access.reach(scope) == :operator
        assert Access.reader(scope) == :operator
        assert Access.level(scope) == nil
      end
    end
  end

  describe "the last owner" do
    test "an operator's last owner is not demoted or removed, and its admin changes no level where it operates" do
      operator = operator_fixture()

      assert {:error, :last_owner} =
               Organisations.set_member_level(operator.scope, operator.membership.id, :admin)

      assert {:error, :last_owner} =
               Organisations.remove_member(operator.scope, operator.membership.id)

      operated = operated_fixture(operator.scope)
      %{user: admin} = member_fixture(operator.scope, :admin)
      admin_in_operated = scope_in(admin, operated.organisation, operated.workspace)
      %{membership: member} = member_fixture(operated.owner.scope, :member)

      assert {:error, :not_found} =
               Organisations.set_member_level(admin_in_operated, member.id, :owner)

      assert %Membership{level: :member} = Repo.get!(Membership, member.id)
    end

    test "an organisation with an operated workspace keeps an owner, as any organisation" do
      operator = operator_fixture()
      operated = operated_fixture(operator.scope)
      %{scope: owner, membership: membership} = operated.owner

      assert {:error, :last_owner} = Organisations.set_member_level(owner, membership.id, :admin)
      assert {:error, :last_owner} = Organisations.remove_member(owner, membership.id)
    end

    test "an operator's only owner owns the operator alone; the owner of an organisation it operates a workspace of owns that organisation" do
      operator = operator_fixture()
      operated = operated_fixture(operator.scope)

      assert [%Organisation{id: id}] = Organisations.sole_owned_organisations(operator.user)
      assert id == operator.organisation.id

      assert [%Organisation{id: id}] = Organisations.sole_owned_organisations(operated.owner.user)
      assert id == operated.organisation.id
    end

    test "an operator is not deleted while it operates a workspace, one of an organisation marked for deletion included" do
      operator = operator_fixture()
      operated = operated_fixture(operator.scope)

      assert {:error, :has_operated_workspaces} =
               Deletion.delete_organisation(operator.scope, operator.organisation.slug)

      {:ok, _} = Deletion.delete_organisation(operated.owner.scope, operated.organisation.slug)

      assert {:error, :has_operated_workspaces} =
               Deletion.delete_organisation(operator.scope, operator.organisation.slug)
    end
  end

  describe "scope resolution and the switcher" do
    setup :operator_with_operated

    test "resolve_scope/4 opens the organisation for the operator's people, without a membership there",
         ctx do
      for user <- [ctx.operator.user, ctx.admin.user, ctx.member.user] do
        assert {:ok, scope} =
                 Organisations.resolve_scope(Scope.for_user(user), ctx.operated.organisation.slug)

        assert scope.organisation.id == ctx.operated.organisation.id
        assert scope.membership == nil
        assert %Membership{user_id: user_id} = ApiaryPro.Reach.operator_membership(scope)
        assert user_id == user.id
        assert scope.workspace.id == ctx.operated.workspace.id
      end

      # Nobody else.
      %{user: stranger} = sign_up_fixture()
      slug = ctx.operated.organisation.slug
      assert Organisations.resolve_scope(Scope.for_user(stranger), slug) == :error
    end

    test "list_places/1 lists the organisations reached through the operator, with the workspaces it operates",
         ctx do
      second = workspace_fixture(ctx.operated.organisation, "Second")

      places = Organisations.list_places(ctx.member.user)

      assert [%Membership{organisation_id: operator_id}, %OperatedPlace{} = place] = places
      assert operator_id == ctx.operator.organisation.id
      assert place.organisation.id == ctx.operated.organisation.id

      assert Enum.map(place.workspaces, & &1.id) == [ctx.operated.workspace.id]
      refute second.id in Enum.map(place.workspaces, & &1.id)

      assert [{operator_id, workspace}] = place.operated

      assert {operator_id, workspace.id} ==
               {ctx.operator.organisation.id, ctx.operated.workspace.id}

      assert place.membership == nil
    end

    test "an organisation the person is a member of too is one place, with that membership",
         ctx do
      %{token: token} =
        invitation_fixture(ctx.organisation_owner, %{"email" => ctx.member.user.email})

      {:ok, membership} = Organisations.accept_invitation(ctx.member.user, token)

      places = Organisations.list_places(ctx.member.user)
      assert [%Membership{}, %OperatedPlace{membership: %Membership{id: id}}] = places
      assert id == membership.id
    end

    test "a deleted organisation is gone from the switcher, and its owner cancels its deletion",
         ctx do
      {:ok, _} =
        Deletion.delete_organisation(ctx.organisation_owner, ctx.operated.organisation.slug)

      assert [%Membership{}] = Organisations.list_places(ctx.operator.user)

      assert Organisations.resolve_scope(
               Scope.for_user(ctx.operator.user),
               ctx.operated.organisation.slug
             ) == :error

      # The operator's owner finds nothing the organisation owns as a whole, and cancels
      # nothing there.
      operator_owner = Scope.for_user(ctx.operator.user)
      assert Deletion.list_marked_organisations(operator_owner) == []
      id = ctx.operated.organisation.id
      assert {:error, :not_found} = Deletion.restore_organisation(operator_owner, id)

      owner = Scope.for_user(ctx.operated.owner.user)
      assert [%Organisation{id: ^id}] = Deletion.list_marked_organisations(owner)
      assert {:ok, _} = Deletion.restore_organisation(owner, id)
      assert [%Membership{}, %OperatedPlace{}] = Organisations.list_places(ctx.operator.user)
    end
  end

  defp collect_queries(acc \\ []) do
    receive do
      {:query, query} -> collect_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
