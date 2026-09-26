defmodule Apiary.OrganisationsTest do
  use Apiary.DataCase, async: true

  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations
  alias Apiary.Organisations.{Invitation, Membership, Organisation}

  describe "sign_up_user/2" do
    test "creates the user, an organisation named from the email, a Main workspace and an owner membership" do
      {:ok,
       %{user: user, organisation: organisation, workspace: workspace, membership: membership}} =
        Organisations.sign_up_user(%{email: "alice@example.com"})

      assert user.email == "alice@example.com"
      assert organisation.name == "alice"
      assert workspace.name == "Main"
      assert workspace.organisation_id == organisation.id
      assert membership.level == :owner
      assert membership.user_id == user.id
      assert membership.organisation_id == organisation.id
      assert membership.workspace_id == workspace.id
    end

    test "returns the user changeset when the email is invalid, creating nothing" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Organisations.sign_up_user(%{email: "nope"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
      assert Repo.aggregate(Organisation, :count) == 0
    end

    test "with a valid invitation token creates no organisation and accepts the invitation" do
      %{scope: scope, organisation: organisation, workspace: workspace} = sign_up_fixture()
      %{invitation: invitation, token: token} = invitation_fixture(scope, %{"level" => "member"})
      count = Repo.aggregate(Organisation, :count)

      {:ok, result} = Organisations.sign_up_user(%{email: invitation.email}, token)

      assert result.organisation.id == organisation.id
      assert result.workspace.id == workspace.id
      assert result.membership.level == :member
      assert Repo.aggregate(Organisation, :count) == count
      assert Repo.get!(Invitation, invitation.id).accepted_at
      assert Organisations.get_invitation_by_token(token) == nil
    end

    test "with an invalid token behaves as without a token" do
      {:ok, %{organisation: organisation, membership: membership}} =
        Organisations.sign_up_user(%{email: unique_user_email()}, "not-a-token")

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
    test "the workspace last opened while the user holds it, else the earliest" do
      %{user: user, workspace: first} = sign_up_fixture()
      other = sign_up_fixture()
      %{token: token} = invitation_fixture(other.scope, %{"email" => user.email})
      {:ok, _membership} = Organisations.accept_invitation(user, token)

      assert Organisations.home_membership(user).workspace_id == first.id

      assert Organisations.home_membership(user, other.workspace.id).workspace_id ==
               other.workspace.id

      assert Organisations.home_membership(user, sign_up_fixture().workspace.id).workspace_id ==
               first.id

      scope = Organisations.load_home_scope(Scope.for_user(user), other.workspace.id)
      assert scope.workspace.id == other.workspace.id
      assert scope.organisation.id == other.organisation.id

      loner = user_fixture()
      assert Organisations.home_membership(loner) == nil
      assert Organisations.load_home_scope(Scope.for_user(loner), nil) == Scope.for_user(loner)
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

      assert {:error, :unauthorized} =
               Organisations.update_organisation(member_scope, %{name: "X"})

      assert {:error, :unauthorized} = Organisations.update_workspace(member_scope, %{name: "X"})

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

  describe "members" do
    test "list_members/1 puts owners first, then by insertion" do
      %{scope: scope, user: owner} = sign_up_fixture()
      %{user: member} = member_fixture(scope, :member)
      %{user: second_owner} = member_fixture(scope, :owner)

      assert [owner.id, second_owner.id, member.id] ==
               scope |> Organisations.list_members() |> Enum.map(& &1.user.id)
    end

    test "set_member_level/3 promotes and demotes, owners only, never the last owner" do
      %{scope: scope, membership: owner_membership} = sign_up_fixture()
      %{scope: member_scope, membership: membership} = member_fixture(scope, :member)

      assert {:error, :unauthorized} =
               Organisations.set_member_level(member_scope, owner_membership.id, :member)

      assert {:error, :last_owner} =
               Organisations.set_member_level(scope, owner_membership.id, "member")

      assert {:ok, %Membership{level: :owner}} =
               Organisations.set_member_level(scope, membership.id, "owner")

      assert {:error, :not_found} =
               Organisations.set_member_level(scope, Ecto.UUID.generate(), :member)

      assert {:error, :not_found} = Organisations.set_member_level(scope, "not-a-uuid", :member)

      assert {:ok, %Membership{level: :member}} =
               Organisations.set_member_level(scope, owner_membership.id, :member)
    end

    test "M1: a scope loaded before a demotion has no owner rights left" do
      %{scope: scope} = sign_up_fixture()
      %{scope: stale, membership: stale_membership} = member_fixture(scope, :owner)
      %{membership: third} = member_fixture(scope, :member)
      %{invitation: invitation} = invitation_fixture(scope)

      assert Organisations.owner?(stale)
      assert {:ok, _} = Organisations.set_member_level(scope, stale_membership.id, :member)
      # The struct still says owner; the database does not.
      assert Organisations.owner?(stale)

      assert {:error, :unauthorized} = Organisations.set_member_level(stale, third.id, :owner)
      assert {:error, :unauthorized} = Organisations.remove_member(stale, third.id)

      assert {:error, :unauthorized} =
               Organisations.invite_member(
                 stale,
                 %{"email" => "late@example.com", "level" => "owner"},
                 &"http://localhost/invitations/#{&1}"
               )

      assert {:error, :unauthorized} = Organisations.revoke_invitation(stale, invitation.id)
      assert {:error, :unauthorized} = Organisations.update_organisation(stale, %{name: "Mine"})
      assert {:error, :unauthorized} = Organisations.update_workspace(stale, %{name: "Mine"})

      assert Repo.get!(Membership, third.id).level == :member
      assert Repo.get!(Organisations.Organisation, scope.organisation.id).name != "Mine"
    end

    test "M1: a scope loaded before a removal has no rights left" do
      %{scope: scope} = sign_up_fixture()
      %{scope: stale, membership: stale_membership} = member_fixture(scope, :owner)
      %{membership: third} = member_fixture(scope, :member)

      assert {:ok, _} = Organisations.remove_member(scope, stale_membership.id)

      assert {:error, :unauthorized} = Organisations.set_member_level(stale, third.id, :owner)
      assert {:error, :unauthorized} = Organisations.remove_member(stale, third.id)
      assert {:error, :unauthorized} = Organisations.update_organisation(stale, %{name: "Mine"})
      assert {:error, :unauthorized} = Organisations.update_workspace(stale, %{name: "Mine"})

      assert {:error, :unauthorized} =
               Organisations.invite_member(
                 stale,
                 %{"email" => "late@example.com", "level" => "owner"},
                 &"http://localhost/invitations/#{&1}"
               )
    end

    test "M1: a level change and a removal are announced to the member's open pages" do
      %{scope: scope} = sign_up_fixture()
      %{user: member, membership: membership} = member_fixture(scope, :member)
      organisation_id = scope.organisation.id

      Phoenix.PubSub.subscribe(Apiary.PubSub, Organisations.membership_topic(member.id))

      assert {:ok, _} = Organisations.set_member_level(scope, membership.id, :owner)
      assert_receive {:membership_changed, %{organisation_id: ^organisation_id}}

      assert {:ok, _} = Organisations.remove_member(scope, membership.id)
      assert_receive {:membership_changed, %{organisation_id: ^organisation_id}}
    end

    test "H7: a membership of another workspace of the organisation is not found" do
      %{scope: scope, organisation: organisation} = sign_up_fixture()
      %{user: outsider} = sign_up_fixture()

      other_workspace =
        Repo.insert!(%Organisations.Workspace{
          organisation_id: organisation.id,
          name: "Second",
          slug: "second"
        })

      elsewhere =
        Repo.insert!(%Membership{
          organisation_id: organisation.id,
          workspace_id: other_workspace.id,
          user_id: outsider.id,
          level: :member
        })

      assert {:error, :not_found} = Organisations.set_member_level(scope, elsewhere.id, :owner)
      assert {:error, :not_found} = Organisations.remove_member(scope, elsewhere.id)
      assert Repo.get!(Membership, elsewhere.id).level == :member
    end

    test "remove_member/2 removes members, owners only, never the last owner" do
      %{scope: scope, membership: owner_membership} = sign_up_fixture()
      %{scope: member_scope, membership: membership} = member_fixture(scope, :member)
      %{scope: other_scope} = sign_up_fixture()

      assert {:error, :unauthorized} = Organisations.remove_member(member_scope, membership.id)
      assert {:error, :last_owner} = Organisations.remove_member(scope, owner_membership.id)
      assert {:error, :not_found} = Organisations.remove_member(other_scope, membership.id)
      assert {:ok, %Membership{}} = Organisations.remove_member(scope, membership.id)
      assert Repo.get(Membership, membership.id) == nil
    end

    test "an owner may remove themselves when another owner exists" do
      %{scope: scope, membership: owner_membership} = sign_up_fixture()
      _second_owner = member_fixture(scope, :owner)

      assert {:ok, %Membership{}} = Organisations.remove_member(scope, owner_membership.id)
    end
  end

  describe "invitations" do
    test "invite_member/3 stores a hash, emails the URL, and lists pending; owners only" do
      %{scope: scope, user: inviter, organisation: organisation} = sign_up_fixture()

      assert {:ok, invitation} =
               Organisations.invite_member(
                 scope,
                 %{"email" => "Bob@Example.com", "level" => "member"},
                 &"http://localhost/invitations/#{&1}"
               )

      assert invitation.email == "bob@example.com"
      assert invitation.level == :member
      assert invitation.invited_by_id == inviter.id
      assert invitation.workspace_id == scope.workspace.id
      assert byte_size(invitation.token_hash) == 32
      assert DateTime.diff(invitation.expires_at, DateTime.utc_now(), :day) in 6..7

      assert_receive {:email, %Swoosh.Email{to: [{"", "bob@example.com"}]} = email}
      assert email.subject =~ organisation.name
      assert email.text_body =~ inviter.email
      assert email.text_body =~ "http://localhost/invitations/"
      refute email.text_body =~ Base.encode16(invitation.token_hash)

      assert [%Invitation{id: id}] = Organisations.list_invitations(scope)
      assert id == invitation.id

      %{scope: member_scope} = member_fixture(scope, :member)

      assert {:error, :unauthorized} =
               Organisations.invite_member(member_scope, %{"email" => "x@example.com"}, & &1)

      assert Organisations.list_invitations(member_scope) |> length() == 1
    end

    test "invite_member/3 refuses an existing member and a duplicate pending invitation" do
      %{scope: scope, user: owner} = sign_up_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Organisations.invite_member(scope, %{"email" => owner.email}, & &1)

      assert %{email: ["is already a member of this organisation"]} = errors_on(changeset)

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

    test "accept_invitation/2 joins at the invitation's level, once" do
      %{scope: scope, organisation: organisation} = sign_up_fixture()
      %{token: token} = invitation_fixture(scope, %{"level" => "owner"})
      user = user_fixture()

      assert {:ok, %Membership{level: :owner} = membership} =
               Organisations.accept_invitation(user, token)

      assert membership.organisation_id == organisation.id
      assert {:error, :invalid} = Organisations.accept_invitation(user, token)

      %{token: token} = invitation_fixture(scope)
      assert {:error, :already_member} = Organisations.accept_invitation(user, token)
      assert {:error, :invalid} = Organisations.accept_invitation(user, "garbage")
    end

    test "M3: one invitation makes one membership, whoever holds it" do
      %{scope: scope, organisation: organisation} = sign_up_fixture()
      %{token: token} = invitation_fixture(scope, %{"level" => "owner"})
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

    test "M3: an invited sign-up that lost the invitation creates nothing" do
      %{scope: scope, organisation: organisation} = sign_up_fixture()
      %{token: token} = invitation_fixture(scope, %{"level" => "owner"})
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

    test "M3: concurrent accepts of one invitation make one membership" do
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

    test "H4: an organisation holds at most 50 pending invitations" do
      %{scope: scope, organisation: organisation, workspace: workspace} = sign_up_fixture()
      now = DateTime.utc_now()

      rows =
        for n <- 1..50 do
          %{
            id: Ecto.UUID.generate(),
            organisation_id: organisation.id,
            workspace_id: workspace.id,
            email: "pending-#{n}@example.com",
            level: :member,
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
                 %{"email" => "one-more@example.com", "level" => "member"},
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

      assert {:error, :unauthorized} =
               Organisations.revoke_invitation(member_scope, invitation.id)

      assert {:error, :not_found} = Organisations.revoke_invitation(scope, Ecto.UUID.generate())
      assert {:ok, %Invitation{}} = Organisations.revoke_invitation(scope, invitation.id)
      assert Organisations.get_invitation_by_token(token) == nil
    end

    test "change_invitation/2 downcases the email" do
      changeset = Organisations.change_invitation(%Invitation{}, %{"email" => "A@B.example"})
      assert get_change(changeset, :email) == "a@b.example"
    end
  end
end
