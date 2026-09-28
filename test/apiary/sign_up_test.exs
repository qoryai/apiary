defmodule Apiary.SignUpTest do
  @moduledoc """
  What a sign-up without an invitation creates: the instance's own organisation on the
  instance's first, and after it an organisation where the edition opens a later sign-up,
  or nothing. The suite's instance has had its first sign-up
  (`ensure_instance_organisation!/0`); a test of the first hides its organisation inside
  its sandbox (`Apiary.EditionKit`).
  """
  # Not async: a test of the first sign-up holds the suite's instance organisation's row.
  use Apiary.DataCase, async: false

  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias Apiary.Organisations
  alias Apiary.Organisations.{Invitation, Membership, Organisation, Workspace}

  defp count(schema), do: Repo.aggregate(schema, :count)

  defp sign_up(attrs \\ %{}, opts) do
    attrs
    |> Enum.into(%{email: unique_user_email(), organisation_name: unique_organisation_name()})
    |> Organisations.sign_up_user(nil, opts)
  end

  describe "the instance's first sign-up" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    test "creates the instance's organisation it names, its Main workspace and its owner, and nothing else" do
      before = {count(Organisation), count(Workspace), count(Membership)}

      assert Organisations.sign_up_offer(open: false) == :first
      assert Organisations.sign_up_offered?()

      assert {:ok,
              %{user: user, organisation: organisation, workspace: workspace, membership: owner}} =
               Organisations.sign_up_user(
                 %{email: "first@example.com", organisation_name: "Acme Hosting"},
                 nil,
                 open: false
               )

      assert %Organisation{name: "Acme Hosting"} = organisation
      assert Apiary.Edition.instance_organisation_id() == organisation.id
      assert %Workspace{name: "Main"} = workspace
      assert %Membership{level: :owner, user_id: user_id} = owner
      assert user_id == user.id
      assert Apiary.Access.instance_admin?(Apiary.Accounts.Scope.for_user(user))

      {organisations, workspaces, memberships} = before
      assert count(Organisation) == organisations + 1
      assert count(Workspace) == workspaces + 1
      assert count(Membership) == memberships + 1

      # Its entry is the sign-up's, as any organisation's is.
      assert [entry] =
               Repo.all(
                 from e in Entry,
                   where:
                     e.organisation_id == ^organisation.id and e.action == "organisation.create"
               )

      assert entry.details["sign_up"] == true
      assert entry.details["workspace_id"] == workspace.id
      assert entry.details["membership_id"] == owner.id

      # The next sign-up is a later one.
      assert Organisations.sign_up_offer(open: false) == :closed
      assert Organisations.sign_up_offer(open: true) == :open
    end

    test "is the first whether or not the edition opens a later sign-up" do
      assert {:ok, %{organisation: organisation}} = sign_up(open: true)
      assert Apiary.Edition.instance_organisation_id() == organisation.id
    end
  end

  describe "a later sign-up" do
    test "where the edition opens none is refused, and creates nothing" do
      before = {count(Organisation), count(Apiary.Accounts.User)}
      assert Organisations.sign_up_offer(open: false) == :closed

      assert {:error, changeset} = sign_up(open: false)
      assert %{email: [message]} = errors_on(changeset)
      assert message =~ "without an invitation"

      assert {count(Organisation), count(Apiary.Accounts.User)} == before
    end

    test "where the edition opens one creates an organisation, its workspace and its owner" do
      assert Organisations.sign_up_offer(open: true) == :open

      assert {:ok, %{organisation: organisation, workspace: workspace, membership: owner}} =
               sign_up(open: true)

      refute Apiary.Edition.instance_organisation_id() == organisation.id
      assert %Workspace{name: "Main"} = workspace
      assert %Membership{level: :owner} = owner

      assert [entry] =
               Repo.all(
                 from e in Entry,
                   where:
                     e.organisation_id == ^organisation.id and e.action == "organisation.create"
               )

      assert entry.details["sign_up"] == true
    end

    test "with an invitation creates no organisation, whatever the edition opens" do
      %{scope: scope} = sign_up_fixture()
      %{invitation: invitation, token: token} = invitation_fixture(scope)
      organisations = count(Organisation)

      assert {:ok, %{membership: %Membership{level: :member}, organisation: organisation}} =
               Organisations.sign_up_user(%{email: invitation.email}, token, open: false)

      assert organisation.id == scope.organisation.id
      assert count(Organisation) == organisations
      refute Repo.get(Invitation, invitation.id)
    end
  end

  describe "change_sign_up/2" do
    test "asks for the address, and for a sign-up without an invitation the organisation's name" do
      changeset = Organisations.change_sign_up(%{"email" => "a@example.com"})
      assert %{organisation_name: [_required]} = errors_on(changeset)

      changeset =
        Organisations.change_sign_up(%{"email" => "a@example.com", "organisation_name" => "Acme"})

      assert changeset.valid?

      changeset = Organisations.change_sign_up(%{"email" => "a@example.com"}, invited: true)
      assert changeset.valid?
    end
  end
end
