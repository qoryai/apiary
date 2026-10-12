defmodule Apiary.SignUpTest do
  @moduledoc """
  What a sign-up without an invitation creates: nothing before the instance is set up
  (`Apiary.Setup`, whose own tests are `Apiary.SetupTest`), and after it an organisation
  where the edition opens a later sign-up, or nothing. The suite's instance is set up
  (`ensure_instance_organisation!/0`); a test before set-up hides its organisation inside
  its sandbox (`Apiary.EditionKit`).
  """
  # Not async: a test before set-up holds the suite's instance organisation's row.
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

  describe "before set-up" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    test "nobody signs up, whether or not the edition opens a later sign-up, and nothing is made" do
      before = {count(Organisation), count(Workspace), count(Membership)}

      for open <- [false, true] do
        assert Organisations.sign_up_offer(open: open) == :not_set_up
        assert sign_up(open: open) == {:error, :not_set_up}
      end

      refute Organisations.sign_up_offered?()
      assert {count(Organisation), count(Workspace), count(Membership)} == before
    end

    test "the set-up makes the instance's organisation; a sign-up after it is a later one" do
      assert {:ok, %{organisation: organisation}} =
               Apiary.Setup.set_up(Apiary.Setup.code!(), %{
                 email: "first@example.com",
                 organisation_name: "Acme Hosting"
               })

      assert Apiary.Edition.instance_organisation_id() == organisation.id
      assert Organisations.sign_up_offer(open: false) == :closed
      assert Organisations.sign_up_offer(open: true) == :open
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
