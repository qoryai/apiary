defmodule Apiary.OrganisationsTest do
  use Apiary.DataCase, async: true
  use Oban.Testing, repo: Apiary.Repo

  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures
  import Ecto.Query, only: [from: 2]

  alias Apiary.Organisations
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.{Invitation, Membership, Organisation, Workspace}

  describe "sign_up_user/2" do
    test "creates the user, the organisation it names, a Main workspace and an owner membership" do
      {:ok,
       %{user: user, organisation: organisation, workspace: workspace, membership: membership}} =
        Organisations.sign_up_user(
          %{email: "alice@example.com", organisation_name: " Acme Ltd "},
          nil,
          open: true
        )

      assert user.email == "alice@example.com"
      # Its name and its slug are the name's; nothing is made from the address.
      assert organisation.name == "Acme Ltd"
      assert organisation.slug == "acme-ltd"
      assert workspace.name == "Main"
      assert workspace.organisation_id == organisation.id
      assert membership.level == :owner
      assert membership.user_id == user.id
      assert membership.organisation_id == organisation.id
    end

    test "returns the form's changeset when the email is invalid, creating nothing" do
      # Counted from what is there: the tests that race on connections of their own commit
      # what they make, and a run stopped half way leaves it until the next.
      organisations = Repo.aggregate(Organisation, :count)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Organisations.sign_up_user(%{email: "nope", organisation_name: "Acme"}, nil,
                 open: true
               )

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
      assert Repo.aggregate(Organisation, :count) == organisations
    end

    test "asks for the organisation's name, checked as an organisation's name is" do
      email = unique_user_email()
      organisations = Repo.aggregate(Organisation, :count)

      for name <- [nil, "   ", String.duplicate("a", 121), "Acme\nLtd"] do
        assert {:error, changeset} =
                 Organisations.sign_up_user(%{email: email, organisation_name: name}, nil,
                   open: true
                 )

        assert %{organisation_name: [_]} = errors_on(changeset)
        refute Map.has_key?(errors_on(changeset), :email)
      end

      assert Apiary.Accounts.get_user_by_email(email) == nil
      assert Repo.aggregate(Organisation, :count) == organisations
    end

    test "an address already signed up is refused on the email" do
      %{user: user} = sign_up_fixture()

      assert {:error, changeset} =
               Organisations.sign_up_user(%{email: user.email, organisation_name: "Acme"}, nil,
                 open: true
               )

      assert "has already been taken" in errors_on(changeset).email
    end

    test "with a valid invitation token creates no organisation and accepts the invitation" do
      %{scope: scope, organisation: organisation, workspace: workspace} = sign_up_fixture()
      %{invitation: invitation, token: token} = invitation_fixture(scope)
      count = Repo.aggregate(Organisation, :count)

      # An invited sign-up creates no organisation, and so names none.
      {:ok, result} = Organisations.sign_up_user(%{email: invitation.email}, token)

      assert result.organisation.id == organisation.id
      assert result.workspace.id == workspace.id
      assert result.membership.level == :member
      assert Repo.aggregate(Organisation, :count) == count
      # Accepted, the invitation is gone: the membership it became is what is left.
      assert Repo.get(Invitation, invitation.id) == nil
      assert Organisations.get_invitation_by_token(token) == nil
    end

    test "with an invalid token behaves as without a token" do
      {:ok, %{organisation: organisation, membership: membership}} =
        Organisations.sign_up_user(
          %{email: unique_user_email(), organisation_name: "Acme"},
          "not-a-token",
          open: true
        )

      assert organisation.name
      assert membership.level == :owner
    end
  end

  describe "load_scope/2 and list_memberships/1" do
    test "loads the earliest membership by default and a named organisation on request" do
      %{user: user, organisation: first} = sign_up_fixture()
      %{scope: other_scope, organisation: second} = sign_up_fixture()
      %{token: token} = invitation_fixture(other_scope, %{"email" => user.email})
      {:ok, _membership} = Organisations.accept_invitation(user, token)

      scope = Organisations.load_scope(Scope.for_user(user))
      assert scope.organisation.id == first.id
      assert scope.workspace.organisation_id == first.id
      assert scope.membership.level == :owner

      scope = Organisations.load_scope(Scope.for_user(user), second.id)
      assert scope.organisation.id == second.id
      assert scope.membership.level == :member

      assert [first.id, second.id] ==
               user |> Organisations.list_memberships() |> Enum.map(& &1.organisation.id)
    end

    test "leaves the scope unchanged for a user without memberships, and nil for no user" do
      user = user_fixture()
      scope = Scope.for_user(user)
      assert Organisations.load_scope(scope) == scope
      assert Organisations.load_scope(nil) == nil
    end
  end

  describe "load_scope/2 of a member" do
    test "loads the workspace the member was invited to" do
      %{scope: owner_scope} = sign_up_fixture()
      %{scope: scope} = member_fixture(owner_scope, :member)

      assert scope.membership.level == :member
      assert scope.workspace.id == owner_scope.workspace.id
    end
  end

  describe "resolve_scope/4 and the workspaces a person reaches" do
    setup do
      %{scope: owner_scope, organisation: organisation} = sign_up_fixture()
      second = workspace_fixture(organisation, "Platform")
      %{user: admin} = member_fixture(owner_scope, :admin)

      %{
        owner: owner_scope.user,
        organisation: organisation,
        first: owner_scope.workspace,
        second: second,
        admin: admin
      }
    end

    test "an owner and an admin reach every workspace", ctx do
      for user <- [ctx.owner, ctx.admin], workspace <- [ctx.first, ctx.second] do
        assert {:ok, scope} =
                 Organisations.resolve_scope(
                   Scope.for_user(user),
                   ctx.organisation.slug,
                   workspace.slug
                 )

        assert scope.workspace.id == workspace.id
      end
    end

    test "an organisation's page opens the workspace last opened while it is reached, else the first",
         ctx do
      # By name: Main before Platform.
      assert {:ok, %{workspace: %{id: first_id}}} =
               Organisations.resolve_scope(Scope.for_user(ctx.owner), ctx.organisation.slug)

      assert first_id == ctx.first.id

      assert {:ok, %{workspace: %{id: second_id}}} =
               Organisations.resolve_scope(Scope.for_user(ctx.owner), ctx.organisation.slug, nil,
                 last_workspace: ctx.second.id
               )

      assert second_id == ctx.second.id
    end

    test "list_memberships/1 carries the workspaces each membership reaches", ctx do
      assert [%Membership{workspaces: owner_workspaces}] =
               Organisations.list_memberships(ctx.owner)

      assert Enum.map(owner_workspaces, & &1.id) == [ctx.first.id, ctx.second.id]
    end
  end

  describe "resolve_scope/3" do
    setup do
      %{user: user} = signed_up = sign_up_fixture()
      other = sign_up_fixture()
      %{token: token} = invitation_fixture(other.scope, %{"email" => user.email})
      {:ok, _membership} = Organisations.accept_invitation(user, token)
      %{user: user, mine: signed_up, joined: other, stranger: sign_up_fixture()}
    end

    test "loads each organisation and workspace the user is a member of, by their slugs", ctx do
      for %{organisation: organisation, workspace: workspace} <- [ctx.mine, ctx.joined] do
        assert {:ok, scope} =
                 Organisations.resolve_scope(
                   Scope.for_user(ctx.user),
                   organisation.slug,
                   workspace.slug
                 )

        assert scope.organisation.id == organisation.id
        assert scope.workspace.id == workspace.id
        assert scope.membership.user_id == ctx.user.id

        assert {:ok, %{workspace: %{id: id}}} =
                 Organisations.resolve_scope(Scope.for_user(ctx.user), organisation.slug)

        assert id == workspace.id
      end
    end

    test "is one answer for a slug that does not exist and for one the user is no member of",
         ctx do
      scope = Scope.for_user(ctx.user)
      stranger = ctx.stranger

      assert :error =
               Organisations.resolve_scope(
                 scope,
                 stranger.organisation.slug,
                 stranger.workspace.slug
               )

      assert :error = Organisations.resolve_scope(scope, stranger.organisation.slug)
      assert :error = Organisations.resolve_scope(scope, "no-such-organisation", "main")
      assert :error = Organisations.resolve_scope(scope, ctx.mine.organisation.slug, "nothing")
      assert :error = Organisations.resolve_scope(nil, ctx.mine.organisation.slug, "main")
    end

    test "never pairs an organisation with a workspace of another", ctx do
      # A workspace of the stranger's organisation, with a slug the user's own does not
      # hold.
      {:ok, platform} =
        %Apiary.Organisations.Workspace{organisation_id: ctx.stranger.organisation.id}
        |> Apiary.Organisations.Workspace.changeset(%{name: "Platform"})
        |> Apiary.Organisations.Workspace.put_slug("platform")
        |> Apiary.Repo.insert()

      assert :error =
               Organisations.resolve_scope(
                 Scope.for_user(ctx.user),
                 ctx.mine.organisation.slug,
                 platform.slug
               )
    end
  end

  describe "home_membership/2 and load_home_scope/2" do
    test "the workspace last opened while the user reaches it, else the earliest membership's" do
      %{user: user, organisation: first} = sign_up_fixture()
      other = sign_up_fixture()
      %{token: token} = invitation_fixture(other.scope, %{"email" => user.email})
      {:ok, _membership} = Organisations.accept_invitation(user, token)

      assert Organisations.home_membership(user).organisation_id == first.id

      assert Organisations.home_membership(user, other.workspace.id).organisation_id ==
               other.organisation.id

      assert Organisations.home_membership(user, sign_up_fixture().workspace.id).organisation_id ==
               first.id

      scope = Organisations.load_home_scope(Scope.for_user(user), other.workspace.id)
      assert scope.workspace.id == other.workspace.id
      assert scope.organisation.id == other.organisation.id

      loner = user_fixture()
      assert Organisations.home_membership(loner) == nil
      assert Organisations.load_home_scope(Scope.for_user(loner), nil) == Scope.for_user(loner)
    end

    test "with none opened yet, the organisation's oldest workspace, whatever the names" do
      %{user: user, organisation: organisation, workspace: main} = sign_up_fixture()
      # Before Main by name, after it by age.
      alpha = workspace_fixture(organisation, "Alpha")

      # A second apart, the younger with the fewer microseconds: a term comparison of the two
      # DateTime structs would call it the older.
      set_inserted_at(main, ~U[2026-01-01 10:00:00.900000Z])
      set_inserted_at(alpha, ~U[2026-01-01 10:00:01.100000Z])

      assert Organisations.load_home_scope(Scope.for_user(user), nil).workspace.id == main.id
      assert Organisations.load_scope(Scope.for_user(user)).workspace.id == main.id

      assert {:ok, scope} = Organisations.resolve_scope(Scope.for_user(user), organisation.slug)
      assert scope.workspace.id == main.id

      # The one opened last still wins while it is reached.
      assert {:ok, scope} =
               Organisations.resolve_scope(Scope.for_user(user), organisation.slug, nil,
                 last_workspace: alpha.id
               )

      assert scope.workspace.id == alpha.id
    end
  end

  describe "settings" do
    test "owners rename the organisation and the workspace; members cannot" do
      %{scope: owner_scope} = sign_up_fixture()
      %{scope: member_scope} = member_fixture(owner_scope, :member)

      assert {:ok, %Organisation{name: "Acme"}} =
               Organisations.update_organisation(owner_scope, %{name: "Acme"})

      assert {:ok, %{name: "Platform"}} =
               Organisations.update_workspace(owner_scope, %{name: "Platform"})

      assert {:error, :forbidden} =
               Organisations.update_organisation(member_scope, %{name: "X"})

      assert {:error, :forbidden} = Organisations.update_workspace(member_scope, %{name: "X"})

      assert {:error, %Ecto.Changeset{}} =
               Organisations.update_organisation(owner_scope, %{name: ""})

      for name <- ["two\nlines", "bell\a", "esc\e[2J", "nul\0"] do
        assert {:error, changeset} = Organisations.update_organisation(owner_scope, %{name: name})
        assert %{name: ["must not contain control characters"]} = errors_on(changeset)
        assert {:error, changeset} = Organisations.update_workspace(owner_scope, %{name: name})
        assert %{name: ["must not contain control characters"]} = errors_on(changeset)
      end

      assert {:ok, %Organisation{name: "Übergrößen & Söhne"}} =
               Organisations.update_organisation(owner_scope, %{name: "Übergrößen & Söhne"})

      assert %Ecto.Changeset{} = Organisations.change_organisation(%Organisation{})
    end
  end

  describe "create_workspace/2" do
    # The core's edition allows one workspace in use, the one the organisation was made
    # with: another is created in its place once it is marked for deletion. The scope,
    # loaded again, then holds no workspace.
    defp mark_only_workspace(%{workspace: workspace} = scope) do
      now = DateTime.utc_now()

      workspace
      |> Ecto.Changeset.change(
        deletion_marked_at: now,
        purge_after: DateTime.add(now, 30, :day),
        purge_trigger: "grace_period"
      )
      |> Repo.update!()

      Organisations.load_scope(Scope.for_user(scope.user), scope.organisation.id)
    end

    test "an owner creates one, named, at a slug made from the name, empty and in observe" do
      %{scope: scope, organisation: organisation} = sign_up_fixture()
      scope = mark_only_workspace(scope)

      assert {:ok, workspace} =
               Organisations.create_workspace(scope, %{"name" => "Café Société, Data"})

      assert %{name: "Café Société, Data", slug: "cafe-societe-data", domain: "software"} =
               workspace

      assert workspace.organisation_id == organisation.id
      assert workspace.egress_mode == "observe"
      assert workspace.deletion_marked_at == nil
      assert Enum.map(Organisations.list_workspaces(scope), & &1.id) == [workspace.id]

      assert %Entry{action: "workspace.create", workspace_id: nil, after: after_} =
               Repo.one!(
                 from e in Entry,
                   where: e.organisation_id == ^organisation.id and e.action == "workspace.create"
               )

      assert after_ == %{"name" => "Café Société, Data", "slug" => "cafe-societe-data"}
    end

    test "the slug is the form's where it gives one, and checked as a slug" do
      %{scope: scope} = sign_up_fixture()
      scope = mark_only_workspace(scope)

      assert {:error, changeset} =
               Organisations.create_workspace(scope, %{name: "Data", slug: "Data Lake"})

      assert %{slug: [_rule]} = errors_on(changeset)

      assert {:error, changeset} =
               Organisations.create_workspace(scope, %{name: "Data", slug: "settings"})

      assert %{slug: ["is reserved for a page of Qory Apiary"]} = errors_on(changeset)

      assert {:ok, %{slug: "lake"}} =
               Organisations.create_workspace(scope, %{name: "Data", slug: " lake "})
    end

    test "a name or a slug another workspace of the organisation holds is refused" do
      %{scope: scope, workspace: main} = sign_up_fixture()
      scope = mark_only_workspace(scope)

      # The marked one still holds its name and slug.
      assert {:error, changeset} = Organisations.create_workspace(scope, %{name: main.name})
      assert %{name: [_taken]} = errors_on(changeset)

      assert {:error, changeset} =
               Organisations.create_workspace(scope, %{name: "Another", slug: main.slug})

      assert %{slug: [_taken]} = errors_on(changeset)

      # Made from a name whose slug is taken, the next free one is picked.
      assert Organisations.suggest_workspace_slug(scope, main.name) == "#{main.slug}-2"
      assert Organisations.suggest_workspace_slug(scope, "Data") == "data"
      assert Organisations.suggest_workspace_slug(scope, "") == "workspace"

      assert {:ok, %{name: "Main ", slug: "main-2"}} =
               Organisations.create_workspace(scope, %{name: "Main ", slug: ""})
    end

    test "an empty name is refused, and the form's changeset says so" do
      %{scope: scope} = sign_up_fixture()
      scope = mark_only_workspace(scope)

      assert {:error, changeset} = Organisations.create_workspace(scope, %{"name" => ""})
      assert %{name: ["can't be blank"]} = errors_on(changeset)

      changeset = Organisations.change_new_workspace(scope, %{"name" => "Data", "slug" => ""})
      assert Ecto.Changeset.get_field(changeset, :slug) == "data"
      assert Ecto.Changeset.get_field(changeset, :name) == "Data"
    end

    test "the edition's limit of workspaces in use: one in the core's edition" do
      %{scope: scope} = sign_up_fixture()

      case Apiary.Edition.limits().workspaces do
        1 ->
          assert {:error, :limit} = Organisations.create_workspace(scope, %{"name" => "Data"})
          assert [_main] = Organisations.list_workspaces(scope)
          refute Repo.exists?(from e in Entry, where: e.action == "workspace.create")

          scope = mark_only_workspace(scope)
          assert {:ok, _workspace} = Organisations.create_workspace(scope, %{"name" => "Data"})
          assert {:error, :limit} = Organisations.create_workspace(scope, %{"name" => "More"})

        :unlimited ->
          assert {:ok, _workspace} = Organisations.create_workspace(scope, %{"name" => "Data"})
          assert {:ok, _workspace} = Organisations.create_workspace(scope, %{"name" => "More"})
          assert length(Organisations.list_workspaces(scope)) == 3
      end
    end

    test "only an owner creates one" do
      %{scope: owner} = sign_up_fixture()
      %{scope: admin} = member_fixture(owner, :admin)
      %{scope: member} = member_fixture(owner, :member)

      assert {:error, :forbidden} = Organisations.create_workspace(admin, %{"name" => "Data"})
      assert {:error, :forbidden} = Organisations.create_workspace(member, %{"name" => "Data"})
      refute Repo.exists?(from e in Entry, where: e.action == "workspace.create")
    end

    test "the core's edition is told and adds nothing" do
      %{scope: scope} = sign_up_fixture()
      assert Apiary.Edition.Core.workspace_created(Repo, scope.workspace, scope) == :ok
    end
  end

  describe "members" do
    test "list_members/1 puts owners first, then admins, then members, each by insertion" do
      %{scope: scope, user: owner} = sign_up_fixture()
      %{user: member} = member_fixture(scope, :member)
      %{user: admin} = member_fixture(scope, :admin)
      %{user: second_owner} = member_fixture(scope, :owner)

      assert [owner.id, second_owner.id, admin.id, member.id] ==
               scope |> Organisations.list_members() |> Enum.map(& &1.user.id)
    end

    test "set_member_level/3 promotes and demotes, owners only, never the last owner" do
      %{scope: scope, membership: owner_membership} = sign_up_fixture()
      %{scope: member_scope, membership: membership} = member_fixture(scope, :member)
      %{scope: admin_scope, membership: admin_membership} = member_fixture(scope, :admin)

      assert {:error, :forbidden} =
               Organisations.set_member_level(member_scope, owner_membership.id, :member)

      # An admin changes nobody's level, a member's included.
      for {target, level} <- [{membership, :admin}, {admin_membership, :member}] do
        assert {:error, :forbidden} =
                 Organisations.set_member_level(admin_scope, target.id, level)
      end

      assert {:error, :last_owner} =
               Organisations.set_member_level(scope, owner_membership.id, "member")

      assert {:error, :last_owner} =
               Organisations.set_member_level(scope, owner_membership.id, "admin")

      assert {:ok, %Membership{level: :admin}} =
               Organisations.set_member_level(scope, membership.id, "admin")

      assert {:ok, %Membership{level: :owner}} =
               Organisations.set_member_level(scope, membership.id, "owner")

      assert {:error, :not_found} =
               Organisations.set_member_level(scope, Ecto.UUID.generate(), :member)

      assert {:error, :not_found} = Organisations.set_member_level(scope, "not-a-uuid", :member)

      assert {:ok, %Membership{level: :member}} =
               Organisations.set_member_level(scope, owner_membership.id, :member)
    end

    test "a scope loaded before a demotion has no owner rights left" do
      %{scope: scope} = sign_up_fixture()
      %{scope: stale, membership: stale_membership} = member_fixture(scope, :owner)
      %{membership: third} = member_fixture(scope, :member)
      %{invitation: invitation} = invitation_fixture(scope)

      assert Apiary.Access.can?(stale, :"member.change_level", stale.workspace)
      assert {:ok, _} = Organisations.set_member_level(scope, stale_membership.id, :member)
      # The struct still says owner; the database does not.
      assert Apiary.Access.can?(stale, :"member.change_level", stale.workspace)

      assert {:error, :forbidden} = Organisations.set_member_level(stale, third.id, :owner)
      assert {:error, :forbidden} = Organisations.remove_member(stale, third.id)

      assert {:error, :forbidden} =
               Organisations.invite_member(
                 stale,
                 %{"email" => "late@example.com"},
                 &"http://localhost/invitations/#{&1}"
               )

      assert {:error, :forbidden} = Organisations.revoke_invitation(stale, invitation.id)
      assert {:error, :forbidden} = Organisations.update_organisation(stale, %{name: "Mine"})
      assert {:error, :forbidden} = Organisations.update_workspace(stale, %{name: "Mine"})

      assert Repo.get!(Membership, third.id).level == :member
      assert Repo.get!(Organisations.Organisation, scope.organisation.id).name != "Mine"
    end

    test "a scope loaded before a removal has no rights left" do
      %{scope: scope} = sign_up_fixture()
      %{scope: stale, membership: stale_membership} = member_fixture(scope, :owner)
      %{membership: third} = member_fixture(scope, :member)

      assert {:ok, _} = Organisations.remove_member(scope, stale_membership.id)

      assert {:error, :forbidden} = Organisations.set_member_level(stale, third.id, :owner)
      assert {:error, :forbidden} = Organisations.remove_member(stale, third.id)
      assert {:error, :forbidden} = Organisations.update_organisation(stale, %{name: "Mine"})
      assert {:error, :forbidden} = Organisations.update_workspace(stale, %{name: "Mine"})

      assert {:error, :forbidden} =
               Organisations.invite_member(
                 stale,
                 %{"email" => "late@example.com"},
                 &"http://localhost/invitations/#{&1}"
               )
    end

    test "a level change and a removal are announced to the member's open pages" do
      %{scope: scope} = sign_up_fixture()
      %{user: member, membership: membership} = member_fixture(scope, :member)
      organisation_id = scope.organisation.id

      Phoenix.PubSub.subscribe(Apiary.PubSub, Organisations.membership_topic(member.id))

      assert {:ok, _} = Organisations.set_member_level(scope, membership.id, :owner)
      assert_receive {:membership_changed, %{organisation_id: ^organisation_id}}

      assert {:ok, _} = Organisations.remove_member(scope, membership.id)
      assert_receive {:membership_changed, %{organisation_id: ^organisation_id}}
    end

    test "a membership of another organisation is not found" do
      %{scope: scope} = sign_up_fixture()
      %{membership: elsewhere} = sign_up_fixture()

      assert {:error, :not_found} = Organisations.set_member_level(scope, elsewhere.id, :member)
      assert {:error, :not_found} = Organisations.remove_member(scope, elsewhere.id)
      assert Repo.get!(Membership, elsewhere.id).level == :owner
    end

    test "remove_member/2 removes members, owners and admins, never the last owner" do
      %{scope: scope, membership: owner_membership} = sign_up_fixture()
      %{membership: membership} = member_fixture(scope, :member)
      %{scope: member_scope} = member_fixture(scope, :member)
      %{scope: other_scope} = sign_up_fixture()

      assert {:error, :forbidden} = Organisations.remove_member(member_scope, membership.id)
      assert {:error, :last_owner} = Organisations.remove_member(scope, owner_membership.id)
      assert {:error, :not_found} = Organisations.remove_member(other_scope, membership.id)
      assert {:ok, %Membership{}} = Organisations.remove_member(scope, membership.id)
      assert Repo.get(Membership, membership.id) == nil
    end

    test "an admin removes members, and neither an owner nor an admin" do
      %{scope: scope, membership: owner_membership} = sign_up_fixture()
      _second_owner = member_fixture(scope, :owner)
      %{scope: admin_scope, membership: admin_membership} = member_fixture(scope, :admin)
      %{membership: other_admin} = member_fixture(scope, :admin)
      %{membership: membership} = member_fixture(scope, :member)

      for target <- [owner_membership, other_admin] do
        assert {:error, :forbidden} = Organisations.remove_member(admin_scope, target.id)
        assert Repo.get(Membership, target.id)
      end

      assert {:ok, %Membership{}} = Organisations.remove_member(admin_scope, membership.id)
      # Themselves, they may: leaving.
      assert {:ok, %Membership{}} = Organisations.remove_member(admin_scope, admin_membership.id)
    end

    test "anyone may leave, at any level; the last owner may not" do
      %{scope: scope, membership: owner_membership} = sign_up_fixture()
      %{scope: admin_scope, membership: admin} = member_fixture(scope, :admin)
      %{scope: member_scope, membership: member} = member_fixture(scope, :member)
      %{membership: other_member} = member_fixture(scope, :member)

      # A member removes nobody but themselves.
      assert {:error, :forbidden} = Organisations.remove_member(member_scope, other_member.id)

      assert {:ok, %Membership{}} = Organisations.remove_member(admin_scope, admin.id)
      assert {:ok, %Membership{}} = Organisations.remove_member(member_scope, member.id)
      refute Repo.get(Membership, admin.id)
      refute Repo.get(Membership, member.id)

      assert [entry | _] =
               Repo.all(
                 from e in Entry,
                   where: e.action == "member.remove",
                   order_by: [desc: e.inserted_at, desc: e.id]
               )

      assert entry.actor_id == member_scope.user.id
      assert entry.subject_id == member.id

      assert {:error, :last_owner} = Organisations.remove_member(scope, owner_membership.id)
    end

    test "an owner may remove themselves when another owner exists" do
      %{scope: scope, membership: owner_membership} = sign_up_fixture()
      _second_owner = member_fixture(scope, :owner)

      assert {:ok, %Membership{}} = Organisations.remove_member(scope, owner_membership.id)
    end
  end

  describe "demotion" do
    test "the invitations a person sent stay when they are demoted, leave or are removed" do
      %{scope: scope} = sign_up_fixture()
      %{scope: owner_scope, membership: owner} = member_fixture(scope, :owner)
      %{scope: admin_scope, membership: admin} = member_fixture(scope, :admin)
      %{invitation: by_owner} = invitation_fixture(owner_scope)
      %{invitation: by_admin} = invitation_fixture(admin_scope)

      {:ok, _} = Organisations.set_member_level(scope, owner.id, :member)
      {:ok, _} = Organisations.remove_member(scope, admin.id)

      # An invitation makes a member, whoever sent it: nothing it grants was its sender's.
      assert Repo.get(Invitation, by_owner.id)
      assert Repo.get(Invitation, by_admin.id)
      refute Repo.exists?(from e in Entry, where: e.action == "invitation.revoke")
    end

    test "an owner made an admin keeps reaching every workspace" do
      %{scope: scope} = sign_up_fixture()
      second = workspace_fixture(scope.organisation, "Platform")
      %{membership: membership, user: user} = member_fixture(scope, :owner)

      {:ok, _} = Organisations.set_member_level(scope, membership.id, :admin)
      assert workspace_scope(user, scope.workspace)
      assert workspace_scope(user, second)
    end
  end

  describe "invitations" do
    test "invite_member/3 stores a hash, emails the URL, and lists pending; owners only" do
      %{scope: scope, user: inviter, organisation: organisation} = sign_up_fixture()

      assert {:ok, invitation} =
               Organisations.invite_member(
                 scope,
                 %{"email" => "Bob@Example.com"},
                 &"http://localhost/invitations/#{&1}"
               )

      assert invitation.email == "bob@example.com"
      assert invitation.invited_by_id == inviter.id
      assert invitation.workspace_id == scope.workspace.id
      assert byte_size(invitation.token_hash) == 32
      assert DateTime.diff(invitation.expires_at, DateTime.utc_now(), :day) in 6..7

      assert_receive {:email, %Swoosh.Email{to: [{"", "bob@example.com"}]} = email}
      assert email.text_body =~ "“#{organisation.name}”"
      refute email.text_body =~ inviter.email
      assert email.text_body =~ "http://localhost/invitations/"
      refute email.text_body =~ Base.encode16(invitation.token_hash)

      assert [%Invitation{id: id}] = Organisations.list_invitations(scope)
      assert id == invitation.id

      %{scope: member_scope} = member_fixture(scope, :member)

      assert {:error, :forbidden} =
               Organisations.invite_member(member_scope, %{"email" => "x@example.com"}, & &1)

      assert Organisations.list_invitations(member_scope) |> length() == 1
    end

    test "an admin invites, and revokes any invitation, an owner's included" do
      %{scope: scope} = sign_up_fixture()
      %{scope: admin_scope} = member_fixture(scope, :admin)

      assert {:ok, %Invitation{}} =
               Organisations.invite_member(admin_scope, %{"email" => "m@example.com"}, & &1)

      %{invitation: by_owner} = invitation_fixture(scope)
      assert {:ok, _} = Organisations.revoke_invitation(admin_scope, by_owner.id)
    end

    test "an invitation is an address and nothing else: a level given is not read" do
      %{scope: scope} = sign_up_fixture()

      %{invitation: invitation, token: token} =
        invitation_fixture(scope, %{"level" => "owner", "message" => "Hello from the bank"})

      refute Map.has_key?(invitation, :level)
      user = user_fixture(%{email: invitation.email})

      assert {:ok, %Membership{level: :member}} = Organisations.accept_invitation(user, token)
      # A member, who reaches the workspace the invitation was sent from.
      assert workspace_scope(user, scope.workspace)

      assert_received {:email, %Swoosh.Email{subject: "Your invitation to Qory Apiary"} = email}
      refute email.text_body =~ "bank"
    end

    test "an inviter whose account is not confirmed invites nobody" do
      %{scope: scope} = sign_up_fixture()
      unconfirmed = %{scope | user: %{scope.user | confirmed_at: nil}}

      assert {:error, :unconfirmed} =
               Organisations.invite_member(unconfirmed, %{"email" => "x@example.com"}, & &1)

      refute Repo.exists?(
               from i in Invitation, where: i.organisation_id == ^scope.organisation.id
             )

      refute_received {:email, %Swoosh.Email{to: [{"", "x@example.com"}]}}
    end

    test "invite_member/3 refuses an existing member and a duplicate pending invitation" do
      %{scope: scope, user: owner} = sign_up_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Organisations.invite_member(scope, %{"email" => owner.email}, & &1)

      assert %{email: [message]} = errors_on(changeset)
      assert message =~ "is already a member of this organisation"

      assert {:ok, _} = Organisations.invite_member(scope, %{"email" => "c@example.com"}, & &1)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Organisations.invite_member(scope, %{"email" => "c@example.com"}, & &1)

      assert %{email: ["has already been invited"]} = errors_on(changeset)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Organisations.invite_member(scope, %{"email" => "bad"}, & &1)

      assert %{email: [_]} = errors_on(changeset)
    end

    test "get_invitation_by_token/1 returns only pending invitations" do
      %{scope: scope} = sign_up_fixture()
      %{invitation: invitation, token: token} = invitation_fixture(scope)

      assert %Invitation{id: id, organisation: %Organisation{}, workspace: %{}} =
               Organisations.get_invitation_by_token(token)

      assert id == invitation.id
      assert Organisations.get_invitation_by_token("nope") == nil
      assert Organisations.get_invitation_by_token(nil) == nil

      Repo.update!(change(invitation, expires_at: DateTime.add(DateTime.utc_now(), -1, :second)))
      assert Organisations.get_invitation_by_token(token) == nil
      assert Organisations.list_invitations(scope) == []

      # The expired invitation no longer blocks a new one for the same address.
      assert {:ok, _} = Organisations.invite_member(scope, %{"email" => invitation.email}, & &1)
    end

    test "accept_invitation/2 joins as a member, once" do
      %{scope: scope, organisation: organisation} = sign_up_fixture()
      %{token: token} = invitation_fixture(scope)
      user = user_fixture()

      assert {:ok, %Membership{level: :member} = membership} =
               Organisations.accept_invitation(user, token)

      assert membership.organisation_id == organisation.id
      # A member reaches the workspace the invitation was sent from.
      assert workspace_scope(user, scope.workspace)
      assert {:error, :invalid} = Organisations.accept_invitation(user, token)

      %{token: token} = invitation_fixture(scope)
      assert {:error, :already_member} = Organisations.accept_invitation(user, token)
      assert {:error, :invalid} = Organisations.accept_invitation(user, "garbage")
    end

    test "one invitation makes one membership, whoever holds it" do
      %{scope: scope, organisation: organisation} = sign_up_fixture()
      %{token: token} = invitation_fixture(scope)
      first = user_fixture()
      second = user_fixture()

      # Both callers read the invitation while it was pending, as two concurrent
      # requests do; then both accept.
      held_by_first = Organisations.get_invitation_by_token(token)
      held_by_second = Organisations.get_invitation_by_token(token)

      assert {:ok, %Membership{}} = Organisations.accept_invitation(first, held_by_first)
      assert {:error, :invalid} = Organisations.accept_invitation(second, held_by_second)
      assert {:error, :invalid} = Organisations.accept_invitation(second, token)

      assert [_founder, _first] =
               Repo.all(from m in Membership, where: m.organisation_id == ^organisation.id)
    end

    test "an invited sign-up that lost the invitation creates nothing" do
      %{scope: scope, organisation: organisation} = sign_up_fixture()
      %{token: token} = invitation_fixture(scope)
      held = Organisations.get_invitation_by_token(token)

      assert {:ok, %Membership{}} = Organisations.accept_invitation(user_fixture(), token)

      email = unique_user_email()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Organisations.sign_up_user(%{email: email}, held)

      assert %{email: [_]} = errors_on(changeset)
      assert Apiary.Accounts.get_user_by_email(email) == nil

      assert 2 ==
               Repo.aggregate(
                 from(m in Membership, where: m.organisation_id == ^organisation.id),
                 :count
               )
    end

    test "concurrent accepts of one invitation make one membership" do
      %{scope: scope, organisation: organisation} = sign_up_fixture()
      %{token: token} = invitation_fixture(scope)
      users = for _ <- 1..4, do: user_fixture()
      parent = self()

      results =
        users
        |> Enum.map(fn user ->
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
            Organisations.accept_invitation(user, token)
          end)
        end)
        |> Task.await_many()

      assert [{:ok, %Membership{}}] = Enum.filter(results, &match?({:ok, _}, &1))
      assert Enum.count(results, &(&1 == {:error, :invalid})) == 3

      assert 2 ==
               Repo.aggregate(
                 from(m in Membership, where: m.organisation_id == ^organisation.id),
                 :count
               )
    end

    test "an organisation holds at most 50 pending invitations" do
      %{scope: scope, organisation: organisation, workspace: workspace} = sign_up_fixture()
      now = DateTime.utc_now()

      rows =
        for n <- 1..50 do
          %{
            id: Ecto.UUID.generate(),
            organisation_id: organisation.id,
            workspace_id: workspace.id,
            email: "pending-#{n}@example.com",
            token_hash: :crypto.strong_rand_bytes(32),
            expires_at: DateTime.add(now, 7, :day),
            inserted_at: now,
            updated_at: now
          }
        end

      assert {50, _} = Repo.insert_all(Invitation, rows)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Organisations.invite_member(
                 scope,
                 %{"email" => "one-more@example.com"},
                 &"http://localhost/invitations/#{&1}"
               )

      assert %{email: ["too many pending invitations"]} = errors_on(changeset)

      # Another organisation is not affected.
      assert %{invitation: %Invitation{}} = invitation_fixture(sign_up_fixture().scope)
    end

    test "revoke_invitation/2 deletes the row; owners only" do
      %{scope: scope} = sign_up_fixture()
      %{scope: member_scope} = member_fixture(scope, :member)
      %{invitation: invitation, token: token} = invitation_fixture(scope)

      assert {:error, :forbidden} =
               Organisations.revoke_invitation(member_scope, invitation.id)

      assert {:error, :not_found} = Organisations.revoke_invitation(scope, Ecto.UUID.generate())
      assert {:ok, %Invitation{}} = Organisations.revoke_invitation(scope, invitation.id)
      assert Organisations.get_invitation_by_token(token) == nil
    end

    test "an invitation sent from a workspace, accepted: the member reaches it, and the entry is that workspace's" do
      %{scope: scope, organisation: organisation} = sign_up_fixture()
      second = workspace_fixture(organisation, "Platform")
      from_second = workspace_scope(scope.user, second)
      %{token: token, invitation: invitation} = invitation_fixture(from_second)
      assert invitation.workspace_id == second.id
      user = user_fixture()

      assert {:ok, %Membership{level: :member}} = Organisations.accept_invitation(user, token)
      assert workspace_scope(user, second)

      assert [entry] = Repo.all(from e in Entry, where: e.action == "invitation.accept")
      assert entry.workspace_id == second.id
    end

    test "an invitation sent from another workspace is revoked from any page of the organisation" do
      %{scope: scope, organisation: organisation} = sign_up_fixture()
      platform = workspace_fixture(organisation, "Platform")
      %{invitation: invitation} = invitation_fixture(workspace_scope(scope.user, platform))
      assert invitation.workspace_id == platform.id

      # The owner stands in Main now.
      assert scope.workspace.id != platform.id
      assert [%Invitation{workspace: %{id: workspace_id}}] = Organisations.list_invitations(scope)
      assert workspace_id == platform.id
      assert Apiary.Access.can?(scope, :"invitation.revoke", invitation)
      assert {:ok, %Invitation{}} = Organisations.revoke_invitation(scope, invitation.id)

      # So does an admin; a member revokes nothing.
      %{invitation: again} = invitation_fixture(workspace_scope(scope.user, platform))
      %{scope: member_scope} = member_fixture(scope, :member)
      assert {:error, :forbidden} = Organisations.revoke_invitation(member_scope, again.id)
      %{scope: admin_scope} = member_fixture(scope, :admin)
      assert {:ok, %Invitation{}} = Organisations.revoke_invitation(admin_scope, again.id)
    end

    test "accept_invitation/2 deletes the invitation, once the membership exists" do
      %{scope: scope} = sign_up_fixture()
      %{invitation: invitation, token: token} = invitation_fixture(scope)
      user = user_fixture()

      assert {:ok, %Membership{}} = Organisations.accept_invitation(user, token)
      assert Repo.get(Invitation, invitation.id) == nil
    end

    test "delete_old_invitations/2 deletes what expired 30 days ago, as the instance only" do
      %{scope: scope, organisation: organisation} = sign_up_fixture()
      %{invitation: old} = invitation_fixture(scope)
      %{invitation: recent} = invitation_fixture(scope)
      %{invitation: pending} = invitation_fixture(scope)
      %{scope: other} = sign_up_fixture()
      %{invitation: elsewhere} = invitation_fixture(other)

      for {invitation, days} <- [{old, 31}, {recent, 29}, {elsewhere, 31}] do
        Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id),
          set: [expires_at: DateTime.add(DateTime.utc_now(), -days * 86_400, :second)]
        )
      end

      # A row an earlier release kept after it was accepted goes too, with no entry: its
      # acceptance is its entry.
      Repo.update_all(from(i in Invitation, where: i.id == ^pending.id),
        set: [accepted_at: DateTime.utc_now()]
      )

      assert {:error, :forbidden} = Organisations.delete_old_invitations(scope)

      assert {:ok, 2} =
               Organisations.delete_old_invitations(Scope.for_instance(organisation))

      assert Repo.get(Invitation, old.id) == nil
      assert Repo.get(Invitation, pending.id) == nil
      assert Repo.get(Invitation, recent.id)
      assert Repo.get(Invitation, elsewhere.id)

      assert {:ok, 0} =
               Organisations.delete_old_invitations(Scope.for_instance(organisation))
    end

    test "the invitation sweep enqueues a job per organisation, once a day" do
      %{organisation: first} = sign_up_fixture()
      %{organisation: second} = sign_up_fixture()

      assert :ok = perform_job(Apiary.Organisations.InvitationSweep, %{})

      for organisation <- [first, second] do
        assert_enqueued(
          worker: Apiary.Organisations.OldInvitationsJob,
          args: %{"organisation_id" => organisation.id, "workspace_id" => nil}
        )
      end

      crontab = Application.get_env(:apiary, Oban)[:crontab]

      assert {expression, _} =
               List.keyfind(crontab, Apiary.Organisations.InvitationSweep, 1)

      assert {:ok, _} = Oban.Cron.Expression.parse(expression)
    end

    test "change_invitation/2 downcases the email" do
      changeset = Organisations.change_invitation(%Invitation{}, %{"email" => "A@B.example"})
      assert get_change(changeset, :email) == "a@b.example"
    end
  end

  defp set_inserted_at(workspace, at) do
    Apiary.Repo.update_all(
      from(w in Workspace, where: w.id == ^workspace.id),
      set: [inserted_at: at]
    )
  end
end
