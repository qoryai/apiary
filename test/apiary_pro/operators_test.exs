defmodule ApiaryPro.OperatorsTest do
  @moduledoc """
  Operators and their clients: the managing relationship, a client's people, the
  operator's people reading its clients and changing nothing there, an instance admin's
  reading every organisation, the instance actions, and the last-owner rule across kinds.
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
  alias ApiaryPro.{ClientReach, Operators, Tenants}
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

  # An operator with a client, and a person of each level in the operator, each with their
  # scope in the client.
  defp operator_with_client(_ctx) do
    operator = operator_fixture()
    client = client_fixture(operator.scope)
    admin = member_fixture(operator.scope, :admin)
    member = member_fixture(operator.scope, :member)

    %{
      operator: operator,
      client: client,
      owner_in_client: client.scope,
      admin: admin,
      admin_in_client: scope_in(admin.user, client.organisation, client.workspace),
      member: member,
      member_in_client: scope_in(member.user, client.organisation, client.workspace),
      client_owner: client.owner.scope
    }
  end

  describe "an operator's people in a client" do
    setup :operator_with_client

    test "change nothing there, whatever their level in the operator, in can?/3 and authorize/3",
         ctx do
      client = ctx.client.organisation
      workspace = ctx.client.workspace

      asked = [
        {:"security_policy.lock", workspace},
        {:"security_policy.edit", workspace},
        {:"member.change_level", client},
        {:"organisation.delete", client},
        {:"organisation.rename", client},
        {:"workspace.rename", workspace},
        {:"member.invite", workspace},
        {:"node.create", workspace},
        {:"retention.edit", workspace}
      ]

      # In Main, which the operator operates, forbidden; of what the client owns as a
      # whole, and an action asked of the client, such as an invitation, not found.
      for {action, subject} <- asked,
          scope <- [ctx.owner_in_client, ctx.admin_in_client, ctx.member_in_client] do
        refute Access.can?(scope, action, subject), "can? #{action}"

        refusal =
          if subject == workspace and Access.action(action).asked_of != :organisation,
            do: :forbidden,
            else: :not_found

        assert Access.authorize(scope, action, subject) == {:error, refusal}, "#{action}"
      end

      for scope <- [ctx.owner_in_client, ctx.admin_in_client, ctx.member_in_client] do
        assert Access.level(scope) == nil
        assert Access.reach(scope) == :operator
        assert Access.reader(scope) == :operator
        assert scope.membership == nil
      end
    end

    test "read everything in Main at every level: the runs, their terminals and the policy",
         ctx do
      for scope <- [ctx.owner_in_client, ctx.admin_in_client, ctx.member_in_client],
          action <- [:"run.read", :"run.read_log", :"security_policy.read"] do
        assert Access.authorize(scope, action, ctx.client.workspace) == :ok
      end

      # The client's policy and trail are not there for a member of the operator.
      assert Access.authorize(
               ctx.member_in_client,
               :"organisation_policy.read",
               ctx.client.organisation
             ) == {:error, :not_found}

      assert Access.authorize(ctx.member_in_client, :"audit.read", ctx.client.organisation) ==
               {:error, :not_found}

      %{scope: own_member} = member_fixture(ctx.client_owner, :member)

      assert Access.authorize(own_member, :"audit.read", ctx.client.organisation) ==
               {:error, :forbidden}
    end

    test "reach the workspaces the operator operates and no other, a member of the operator too",
         ctx do
      second = workspace_fixture(ctx.client.organisation, "Second")

      for user <- [ctx.operator.user, ctx.admin.user, ctx.member.user] do
        scope = scope_in(user, ctx.client.organisation, ctx.client.workspace)
        assert %Scope{workspace: %Workspace{id: id}} = scope
        assert id == ctx.client.workspace.id
        refute Access.reaches_every_workspace_in?(scope)
        assert Access.authorize(scope, :"run.read", ctx.client.workspace) == :ok
        assert scope_in(user, ctx.client.organisation, second) == nil
      end
    end

    test "are read again by authorize/3, which fails closed", ctx do
      stale_admin = ctx.admin_in_client

      {:ok, _} = Organisations.remove_member(ctx.operator.scope, ctx.admin.membership.id)

      # The page's scope still carries the operator's membership; the database does not.
      assert Access.can?(stale_admin, :"run.read", stale_admin.workspace)

      assert Access.authorize(stale_admin, :"run.read", stale_admin.workspace) ==
               {:error, :forbidden}

      assert Access.reload(stale_admin).reach == nil
    end

    test "with a membership in the client too, that membership decides what they change",
         ctx do
      # A member of the operator, made an admin of the client by its owner.
      %{token: token} =
        invitation_fixture(ctx.client_owner, %{"email" => ctx.member.user.email})

      {:ok, membership} = Organisations.accept_invitation(ctx.member.user, token)
      {:ok, _} = Organisations.set_member_level(ctx.client_owner, membership.id, :admin)

      scope = scope_in(ctx.member.user, ctx.client.organisation, ctx.client.workspace)
      assert scope.membership.level == :admin
      assert Access.reach(scope) == :operator
      assert Access.level(scope) == :admin
      assert Access.authorize(scope, :"workspace.rename", scope.workspace) == :ok

      # An admin of the operator, a member of the client: a member there.
      %{token: token} =
        invitation_fixture(ctx.client_owner, %{"email" => ctx.admin.user.email})

      {:ok, _membership} = Organisations.accept_invitation(ctx.admin.user, token)
      scope = scope_in(ctx.admin.user, ctx.client.organisation, ctx.client.workspace)
      assert scope.membership.level == :member
      assert Access.level(scope) == :member
      assert Access.authorize(scope, :"security_policy.edit", scope.workspace) == :ok

      assert Access.authorize(scope, :"workspace.rename", scope.workspace) ==
               {:error, :forbidden}

      # What the client owns as a whole they read at their level there.
      assert Access.authorize(scope, :"audit.read", ctx.client.organisation) ==
               {:error, :forbidden}
    end

    test "reach no organisation the operator does not manage", ctx do
      %{organisation: elsewhere} = sign_up_fixture()
      assert scope_in(ctx.operator.user, elsewhere) == nil
      assert scope_in(ctx.member.user, elsewhere) == nil
    end

    test "are not listed among the client's members, which they do not see, whose settings show the operator",
         ctx do
      assert Organisations.list_members(ctx.owner_in_client) == []

      assert [%Membership{level: :owner, user_id: owner_id}] =
               Organisations.list_members(ctx.client_owner)

      assert owner_id == ctx.client.owner.user.id
      assert %Organisation{id: id} = Operators.operator_of(ctx.owner_in_client)
      assert id == ctx.operator.organisation.id
      assert Operators.operator_of(ctx.operator.scope) == nil
    end
  end

  describe "a policy write in a client" do
    setup :operator_with_client

    @tag needs: :security
    test "the client's owner writes its policy, the membership held FOR SHARE while it is written",
         ctx do
      handler = "client-share-#{System.unique_integer()}"
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

      assert {:ok, _rule} = Policy.allow(ctx.client_owner, nil, %{host: "api.example"})

      queries = collect_queries()
      # The client and its operator FOR SHARE, in one statement
      # (`Apiary.Organisations.lock_organisations/2`), the membership FOR SHARE, the rows
      # it names FOR KEY SHARE: a change of the owner's level or a suspension waits for the
      # write.
      assert Enum.any?(queries, &(&1 =~ "FROM organisations o" and &1 =~ "FOR SHARE"))
      assert Enum.any?(queries, &(&1 =~ ~s(FROM "memberships") and &1 =~ "FOR SHARE OF"))

      [entry] = person_edits(ctx.client.organisation.id)
      assert {entry.actor_kind, entry.actor_id} == {:person, ctx.client.owner.user.id}
      assert entry.workspace_id == ctx.client.workspace.id

      {:ok, rule} = Policy.allow(ctx.client_owner, nil, %{host: "git.example"})
      assert {:ok, _locked} = Policy.lock(ctx.client_owner, rule)
    end

    @tag needs: :security
    test "the operator's people write none of it, and are told they read it", ctx do
      {:ok, rule} = Policy.allow(ctx.client_owner, nil, %{host: "api.example"})

      for scope <- [ctx.owner_in_client, ctx.admin_in_client, ctx.member_in_client] do
        assert {:error, %Policy.Error{reason: :forbidden, message: message}} =
                 Policy.allow(scope, nil, %{host: "git.example"})

        assert message ==
                 "You can read this organisation as a person of its operator, and change nothing here."

        assert {:error, %Policy.Error{reason: :forbidden}} = Policy.lock(scope, rule)
      end

      assert [_one] = person_edits(ctx.client.organisation.id)
    end
  end

  describe "clients" do
    test "a client owns its people: its owner invites them and makes owners, as anywhere" do
      operator = operator_fixture()
      client = client_fixture(operator.scope)

      assert client.owner.membership.level == :owner
      assert Access.reach(client.owner.scope) == :membership

      %{membership: second, scope: admin} = member_fixture(client.owner.scope, :admin)
      assert second.level == :admin

      # Its admin invites a member, who joins as one; its owner makes them an owner.
      %{membership: third} = member_fixture(admin)
      assert third.level == :member

      assert {:ok, %Membership{level: :owner}} =
               Organisations.set_member_level(client.owner.scope, third.id, :owner)

      assert {:error, :forbidden} = Organisations.set_member_level(admin, second.id, :owner)
    end

    test "an ordinary invitation makes a member, whatever the organisation" do
      operator = operator_fixture()
      client = client_fixture(operator.scope)
      %{membership: joined} = member_fixture(client.owner.scope)
      assert joined.level == :member
    end

    test "the database keeps the relationship one level deep" do
      operator = operator_fixture()
      client = client_fixture(operator.scope)
      other = operator_fixture()

      # A client is never an operator.
      assert_raise Postgrex.Error, ~r/tenants_client_kind_check/, fn ->
        Repo.update_all(from(t in Tenant, where: t.organisation_id == ^client.organisation.id),
          set: [kind: :operator]
        )
      end

      # An operator is never a client.
      assert_raise Postgrex.Error, ~r/tenants_client_kind_check/, fn ->
        Repo.update_all(from(t in Tenant, where: t.organisation_id == ^other.organisation.id),
          set: [operator_id: operator.organisation.id]
        )
      end

      # An operator with clients stays one.
      assert_raise Postgrex.Error, ~r/tenants_operator_fkey/, fn ->
        Repo.update_all(from(t in Tenant, where: t.organisation_id == ^operator.organisation.id),
          set: [kind: :organisation]
        )
      end

      # A client's operator is an operator.
      %{organisation: plain} = sign_up_fixture()

      assert_raise Postgrex.Error, ~r/tenants_operator_fkey/, fn ->
        Repo.update_all(from(t in Tenant, where: t.organisation_id == ^client.organisation.id),
          set: [operator_id: plain.id]
        )
      end
    end
  end

  describe "kinds" do
    setup do
      %{admin: instance_admin_fixture()}
    end

    test "an instance admin makes an organisation an operator, and an operator without clients an organisation",
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

    test "a client is made no operator, nor an operator with clients an organisation",
         %{admin: admin} do
      operator = operator_fixture()
      client = client_fixture(operator.scope)

      assert {:error, :client} =
               Operators.change_kind(admin.instance_scope, client.organisation.id, :operator)

      assert {:error, :has_clients} =
               Operators.change_kind(
                 admin.instance_scope,
                 operator.organisation.id,
                 :organisation
               )

      # A client deleted, and not yet purged, is a client still.
      {:ok, _} = Deletion.delete_organisation(client.owner.scope, client.organisation.slug)

      assert {:error, :has_clients} =
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
      # Its people's pages load their scope again: the Clients entry comes or goes.
      assert_receive {:membership_changed, _change}

      assert {:ok, _back} = Operators.change_kind(admin.instance_scope, here.id, was)
      assert Tenants.kind(instance_organisation()) == was

      # Each an entry of its own trail, by the instance admin, which keeps where they
      # acted from, as a change an owner makes there does.
      assert [there, back] = entries(here.id, "instance.change_kind")
      assert {there.actor_kind, there.actor_id} == {:person, admin.user.id}
      assert {there.before, there.after} == {%{"kind" => "#{was}"}, %{"kind" => "#{other}"}}
      assert {there.remote_ip, there.user_agent} == {"192.0.2.7", "Browser"}
      assert {back.before, back.after} == {%{"kind" => "#{other}"}, %{"kind" => "#{was}"}}
    end

    test "the instance organisation made an operator takes clients, and is no organisation again until they go and it operates no workspace",
         %{admin: admin} do
      here = instance_organisation()

      {:ok, operator} =
        if Tenants.operator?(here),
          do: {:ok, here},
          else: Operators.change_kind(admin.instance_scope, here.id, :operator)

      assert Tenants.operator?(operator)
      admin_scope = scope_in(admin.user, operator)
      client = client_fixture(admin_scope)

      assert {:error, :has_clients} =
               Operators.change_kind(admin.instance_scope, here.id, :organisation)

      # Nothing in the product ends the relation or the link to Main any more: the test ends
      # both in the database.
      id = client.organisation.id

      Repo.delete_all(
        from l in ApiaryPro.Operators.WorkspaceOperator, where: l.organisation_id == ^id
      )

      Repo.update_all(from(t in Tenant, where: t.organisation_id == ^id),
        set: [operator_id: nil, operator_since: nil, model_chain: :organisation]
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

    test "an instance admin lists every organisation, with its kind and its operator",
         %{admin: admin} do
      operator = operator_fixture()
      client = client_fixture(operator.scope)
      %{organisation: plain} = sign_up_fixture()

      assert {:ok, [first | _] = rows} = Operators.list_organisations(admin.instance_scope)
      assert Tenants.instance_organisation?(first.organisation)
      rows = Map.new(rows, &{&1.organisation.id, &1})
      kind = &Tenants.kind(rows[&1].organisation)

      assert %{operator: nil, clients: 1} = rows[operator.organisation.id]
      assert kind.(operator.organisation.id) == :operator
      assert %{operator: %Organisation{id: operator_id}} = rows[client.organisation.id]
      assert kind.(client.organisation.id) == :organisation
      assert operator_id == operator.organisation.id
      assert %{operator: nil, clients: 0} = rows[plain.id]
      assert kind.(plain.id) == :organisation
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
        assert tenant.operator_id == nil
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

    test "the purge is refused for the instance organisation, an operator with clients, a wrong slug and anyone else",
         %{admin: admin} do
      operator = operator_fixture()
      _client = client_fixture(operator.scope)
      %{organisation: organisation, scope: owner} = sign_up_fixture()
      %{scope: operator_admin} = member_fixture(admin.instance_scope, :admin)
      here = instance_organisation()

      assert {:error, :forbidden} =
               ApiaryPro.Deletion.purge_on_request(admin.instance_scope, here.id, here.slug)

      assert {:error, :has_clients} =
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

    test "in an operator and its clients, an instance admin reads as elsewhere, and in its own clients as their operator",
         %{admin: admin} do
      operator = operator_fixture()
      client = client_fixture(operator.scope)

      for organisation <- [operator.organisation, client.organisation] do
        scope = scope_in(admin.user, organisation)
        assert Access.reach(scope) == :instance
        refute Access.can?(scope, :"organisation.rename", organisation)
      end

      # A client of the instance organisation's own, made an operator, which operates its
      # Main: they reach Main as its operator's people, keep the instance admin's reach
      # beside it, so read what the client owns as well, and change none of it.
      own = client_fixture(make_instance_organisation_an_operator(admin))
      assert Access.reach(own.scope) == :operator
      assert Access.level(own.scope) == nil
      assert Access.authorize(own.scope, :"run.read", own.workspace) == :ok
      assert Access.authorize(own.scope, :"audit.read", own.organisation) == :ok
      assert Access.authorize(own.scope, :"secret.read", own.workspace) == :ok

      assert Access.authorize(own.scope, :"organisation.rename", own.organisation) ==
               {:error, :not_found}
    end

    test "the instance organisation's admins and members reach it, read its own clients, and nothing beyond",
         %{admin: admin} do
      %{organisation: elsewhere} = sign_up_fixture()
      own = client_fixture(make_instance_organisation_an_operator(admin))

      for level <- [:admin, :member] do
        %{user: user} = member_fixture(admin.instance_scope, level)
        refute Access.instance_admin?(Scope.for_user(user))
        assert scope_in(user, elsewhere) == nil

        scope = scope_in(user, own.organisation, own.workspace)
        assert Access.reach(scope) == :operator
        assert Access.reader(scope) == :operator
        assert Access.level(scope) == nil
      end
    end
  end

  describe "the last owner" do
    test "an operator's last owner is not demoted or removed, and its admin changes no level in a client" do
      operator = operator_fixture()

      assert {:error, :last_owner} =
               Organisations.set_member_level(operator.scope, operator.membership.id, :admin)

      assert {:error, :last_owner} =
               Organisations.remove_member(operator.scope, operator.membership.id)

      client = client_fixture(operator.scope)
      %{user: admin} = member_fixture(operator.scope, :admin)
      admin_in_client = scope_in(admin, client.organisation, client.workspace)
      %{membership: member} = member_fixture(client.owner.scope, :member)

      assert {:error, :not_found} =
               Organisations.set_member_level(admin_in_client, member.id, :owner)

      assert %Membership{level: :member} = Repo.get!(Membership, member.id)
    end

    test "a client keeps an owner, as any organisation" do
      operator = operator_fixture()
      client = client_fixture(operator.scope)
      %{scope: owner, membership: membership} = client.owner

      assert {:error, :last_owner} = Organisations.set_member_level(owner, membership.id, :admin)
      assert {:error, :last_owner} = Organisations.remove_member(owner, membership.id)
    end

    test "an operator's only owner owns the operator alone; a client's owner owns the client" do
      operator = operator_fixture()
      client = client_fixture(operator.scope)

      assert [%Organisation{id: id}] = Organisations.sole_owned_organisations(operator.user)
      assert id == operator.organisation.id

      assert [%Organisation{id: id}] = Organisations.sole_owned_organisations(client.owner.user)
      assert id == client.organisation.id
    end

    test "an operator with clients is not deleted until they are gone" do
      operator = operator_fixture()
      client = client_fixture(operator.scope)

      assert {:error, :has_clients} =
               Deletion.delete_organisation(operator.scope, operator.organisation.slug)

      {:ok, _} = Deletion.delete_organisation(client.owner.scope, client.organisation.slug)

      assert {:error, :has_clients} =
               Deletion.delete_organisation(operator.scope, operator.organisation.slug)
    end
  end

  describe "scope resolution and the switcher" do
    setup :operator_with_client

    test "resolve_scope/4 opens a client for the operator's people, without a membership there",
         ctx do
      for user <- [ctx.operator.user, ctx.admin.user, ctx.member.user] do
        assert {:ok, scope} =
                 Organisations.resolve_scope(Scope.for_user(user), ctx.client.organisation.slug)

        assert scope.organisation.id == ctx.client.organisation.id
        assert scope.membership == nil
        assert %Membership{user_id: user_id} = ApiaryPro.Reach.operator_membership(scope)
        assert user_id == user.id
        assert scope.workspace.id == ctx.client.workspace.id
      end

      # Nobody else.
      %{user: stranger} = sign_up_fixture()

      assert Organisations.resolve_scope(Scope.for_user(stranger), ctx.client.organisation.slug) ==
               :error
    end

    test "list_places/1 lists the clients reached through the operator, with the workspaces it operates",
         ctx do
      second = workspace_fixture(ctx.client.organisation, "Second")

      places = Organisations.list_places(ctx.member.user)

      assert [%Membership{organisation_id: operator_id}, %ClientReach{} = client] = places
      assert operator_id == ctx.operator.organisation.id
      assert client.organisation.id == ctx.client.organisation.id

      assert Enum.map(client.workspaces, & &1.id) == [ctx.client.workspace.id]
      refute second.id in Enum.map(client.workspaces, & &1.id)

      assert [{operator_id, workspace}] = client.operated

      assert {operator_id, workspace.id} ==
               {ctx.operator.organisation.id, ctx.client.workspace.id}

      assert client.membership == nil
    end

    test "a client the person is a member of too is one place, with that membership", ctx do
      %{token: token} =
        invitation_fixture(ctx.client_owner, %{"email" => ctx.member.user.email})

      {:ok, membership} = Organisations.accept_invitation(ctx.member.user, token)

      places = Organisations.list_places(ctx.member.user)
      assert [%Membership{}, %ClientReach{membership: %Membership{id: id}}] = places
      assert id == membership.id
    end

    test "a deleted client is gone from the switcher, and its own owner cancels its deletion",
         ctx do
      {:ok, _} = Deletion.delete_organisation(ctx.client_owner, ctx.client.organisation.slug)

      assert [%Membership{}] = Organisations.list_places(ctx.operator.user)

      assert Organisations.resolve_scope(
               Scope.for_user(ctx.operator.user),
               ctx.client.organisation.slug
             ) == :error

      # The operator's owner finds nothing the client owns as a whole, and cancels nothing
      # there.
      operator_owner = Scope.for_user(ctx.operator.user)
      assert Deletion.list_marked_organisations(operator_owner) == []
      id = ctx.client.organisation.id
      assert {:error, :not_found} = Deletion.restore_organisation(operator_owner, id)

      owner = Scope.for_user(ctx.client.owner.user)
      assert [%Organisation{id: ^id}] = Deletion.list_marked_organisations(owner)
      assert {:ok, _} = Deletion.restore_organisation(owner, id)
      assert [%Membership{}, %ClientReach{}] = Organisations.list_places(ctx.operator.user)
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
