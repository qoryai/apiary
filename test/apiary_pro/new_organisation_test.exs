defmodule ApiaryPro.NewOrganisationTest do
  @moduledoc """
  An organisation created by a person who has an account already
  (`ApiaryPro.Organisations.create_organisation/2`): of a kind the instance's sign-up
  settings open, made as a sign-up makes one, and nothing when the kind's setting is
  closed.
  """
  # Not async: the sign-up settings are the node's.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import ApiaryPro.SignUpFixtures, only: [open!: 1]
  import ApiaryPro.OperatorsFixtures, only: [tenant_of: 1]

  alias Apiary.Organisations
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.{Membership, Organisation, Workspace}
  alias ApiaryPro.Tenants
  alias ApiaryPro.Suspensions.AccountSuspension
  alias ApiaryPro.Tenants.Tenant

  setup do
    %{home: sign_up_fixture()}
  end

  defp count(schema), do: Repo.aggregate(schema, :count)
  defp counts, do: {count(Organisation), count(Workspace), count(Membership), count(Entry)}

  defp create(scope, attrs) do
    ApiaryPro.Organisations.create_organisation(
      scope,
      Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    )
  end

  describe "with a kind open" do
    test "makes an organisation with no workspace, and the person its first owner", %{
      home: home
    } do
      open!([:organisation])
      Phoenix.PubSub.subscribe(Apiary.PubSub, Organisations.membership_topic(home.user.id))

      assert {:ok, %{organisation: organisation, workspace: nil, membership: membership}} =
               create(home.scope, name: "  Northwind Labs  ")

      assert %Organisation{name: "Northwind Labs"} = organisation

      assert %Tenant{kind: :organisation, instance_organisation: false, operator_id: nil} =
               tenant_of(organisation)

      assert organisation.slug =~ ~r/\Anorthwind-labs(-[a-z0-9]+)?\z/
      refute Organisations.has_workspace?(organisation)
      assert %Membership{level: :owner, user_id: user_id} = membership
      assert user_id == home.user.id

      # The switcher of the person's open pages shows it.
      organisation_id = organisation.id
      assert_receive {:membership_changed, %{organisation_id: ^organisation_id}}

      # They reach it, and the organisation they were in is theirs as before; their first
      # workspace is theirs to make on the set-up page.
      assert [_, _] = Organisations.list_memberships(home.user)
      assert {:ok, scope} = Organisations.resolve_scope(home.scope, organisation.slug)
      assert is_nil(scope.workspace)

      assert {:ok, workspace} =
               Organisations.create_first_workspace(scope, %{"domain" => "software"})

      assert workspace.name == "Main"
    end

    test "begins its trail as a sign-up does, by the person, who did not sign up", %{
      home: home
    } do
      open!([:organisation])
      scope = Apiary.Accounts.Scope.put_origin(home.scope, %{remote_ip: "192.0.2.7"})
      {:ok, %{organisation: organisation} = created} = create(scope, name: "Trail")

      assert [entry] =
               Repo.all(
                 from e in Entry,
                   where:
                     e.organisation_id == ^organisation.id and e.action == "organisation.create"
               )

      assert entry.actor_kind == :person
      assert entry.actor_id == home.user.id
      assert entry.remote_ip == "192.0.2.7"
      assert entry.after == %{"kind" => "organisation"}

      assert entry.details == %{
               "membership_id" => created.membership.id,
               "user_id" => home.user.id,
               "instance_organisation" => false,
               "sign_up" => false
             }
    end

    test "makes an operator where operators are open", %{home: home} do
      open!([:operator])

      assert {:ok, %{organisation: organisation}} = create(home.scope, name: "Harbour Ops")
      assert %Tenant{kind: :operator, instance_organisation: false} = tenant_of(organisation)
    end

    test "with both open, makes the kind chosen, and asks for one", %{home: home} do
      open!([:organisation, :operator])

      for kind <- Tenants.kinds() do
        assert {:ok, %{organisation: organisation}} =
                 create(home.scope, name: "Both #{kind}", kind: Atom.to_string(kind))

        assert %Tenant{kind: ^kind} = tenant_of(organisation)
      end

      before = counts()
      assert {:error, %Ecto.Changeset{} = changeset} = create(home.scope, name: "Unchosen")
      assert "choose what to create" in errors_on(changeset).kind
      assert counts() == before
    end

    test "names it as a sign-up does: the same rules, a slug of Latin letters", %{home: home} do
      open!([:organisation])
      before = counts()

      for name <- ["", "   ", String.duplicate("a", 121), "Tab\tname"] do
        assert {:error, %Ecto.Changeset{} = changeset} = create(home.scope, name: name)
        assert errors_on(changeset).name != [], inspect(name)
      end

      assert counts() == before

      {:ok, %{organisation: organisation}} = create(home.scope, name: "Café Ärger Ωmega")
      assert organisation.slug =~ ~r/\A[a-z0-9-]+\z/
    end

    test "a person in no organisation creates one", %{home: home} do
      open!([:organisation])
      user = Apiary.AccountsFixtures.user_fixture()
      scope = Organisations.load_scope(Apiary.Accounts.Scope.for_user(user))
      assert scope.organisation == nil

      assert {:ok, %{membership: %Membership{level: :owner}}} = create(scope, name: "Solo")
      assert [_] = Organisations.list_memberships(user)
      assert home.user.id != user.id
    end
  end

  describe "with the kind's setting closed" do
    test "nothing is made when both are closed", %{home: home} do
      open!([])
      assert ApiaryPro.Organisations.new_organisation_kinds(home.scope) == []
      before = counts()

      for attrs <- [
            [name: "Closed"],
            [name: "Closed", kind: "organisation"],
            [name: "Closed", kind: "operator"]
          ] do
        assert create(home.scope, attrs) == {:error, :forbidden}
      end

      assert counts() == before
    end

    test "a forged kind is refused, whatever the form says", %{home: home} do
      before = counts()

      open!([:organisation])
      assert ApiaryPro.Organisations.new_organisation_kinds(home.scope) == [:organisation]
      assert create(home.scope, name: "Forged", kind: "operator") == {:error, :forbidden}

      open!([:operator])
      assert ApiaryPro.Organisations.new_organisation_kinds(home.scope) == [:operator]
      assert create(home.scope, name: "Forged", kind: "organisation") == {:error, :forbidden}

      assert create(home.scope, name: "Forged", kind: "instance_organisation") ==
               {:error, :forbidden}

      assert counts() == before
    end

    test "nothing is made for an account deleted meanwhile", %{home: home} do
      open!([:organisation])
      now = DateTime.utc_now(:second)

      Repo.update_all(from(u in Apiary.Accounts.User, where: u.id == ^home.user.id),
        set: [deleted_at: now]
      )

      before = counts()
      assert create(home.scope, name: "Late") == {:error, :not_found}
      assert counts() == before
    end

    test "nothing is made for an account suspended meanwhile", %{home: home} do
      open!([:organisation])
      Repo.insert!(%AccountSuspension{user_id: home.user.id, suspended_at: DateTime.utc_now()})

      before = counts()
      assert create(home.scope, name: "Late") == {:error, :forbidden}
      assert counts() == before
    end
  end
end
