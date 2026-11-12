defmodule ApiaryPro.SignUpKindsTest do
  @moduledoc """
  What a sign-up without an invitation creates on an instance: the instance
  organisation on the instance's first, its set-up (`Apiary.Setup`), an operator where
  the instance has `managed_organisations` and an organisation otherwise, and after it
  the kind the instance's settings open (`ApiaryPro.SignUp`), or nothing. Before the
  set-up nobody signs up. The suite's instance is set up; a test of the set-up takes the
  flag off it inside its sandbox. A test opens the kinds it needs itself, for the node,
  and puts the suite's back after; a test of the set-up names the features it runs with.
  """
  # Not async: the kinds opened are the node's, and a test of the set-up holds the suite's
  # instance organisation's row.
  use Apiary.DataCase, async: false

  import ExUnit.CaptureLog
  import ApiaryPro.SignUpFixtures, only: [open!: 1]
  import Apiary.AccountsFixtures
  import ApiaryPro.OperatorsFixtures, only: [tenant_of: 1]

  alias Apiary.Audit.Entry
  alias Apiary.Features
  alias Apiary.Organisations
  alias Apiary.Organisations.{Membership, Organisation, Workspace}
  alias ApiaryPro.SignUp
  alias ApiaryPro.Tenants.Tenant

  defp count(schema), do: Repo.aggregate(schema, :count)

  defp sign_up(attrs \\ %{}) do
    attrs
    |> Enum.into(%{email: unique_user_email(), organisation_name: unique_organisation_name()})
    |> Organisations.sign_up_user(nil)
  end

  describe "the instance's first sign-up" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      assert ApiaryPro.Organisations.instance_organisation() == nil
      :ok
    end

    @tag with_features: Features.all()
    test "with managed_organisations creates the instance organisation, an operator, no workspace and its owner" do
      assert ApiaryPro.Tenants.first_sign_up_kind() == :operator
      first_sign_up!(:operator)
    end

    @tag with_features: Features.all() -- [:managed_organisations]
    test "without managed_organisations creates the instance organisation, an organisation like any other" do
      assert ApiaryPro.Tenants.first_sign_up_kind() == :organisation
      first_sign_up!(:organisation)
    end

    @tag with_features: Features.all()
    test "is the instance organisation, an operator, whatever kind it asks for and whatever is open" do
      open!([:organisation, :operator])

      assert {:ok, %{organisation: operator}} = set_up(%{kind: "organisation"})
      assert %Tenant{kind: :operator, instance_organisation: true} = tenant_of(operator)
    end

    @tag with_features: Features.all() -- [:managed_organisations]
    test "is the instance organisation, an organisation, whatever kind it asks for and whatever is open" do
      open!([:organisation, :operator])

      assert {:ok, %{organisation: organisation}} = set_up(%{kind: "operator"})
      assert %Tenant{kind: :organisation, instance_organisation: true} = tenant_of(organisation)
    end

    test "nobody signs up before it, whatever is open, and nothing is created" do
      before = {count(Organisation), count(Apiary.Accounts.User)}

      for open <- [[], [:organisation], [:operator], [:organisation, :operator]],
          kind <- [nil, "organisation", "operator"] do
        open!(open)
        assert SignUp.offer() == :not_set_up
        assert sign_up(%{kind: kind}) == {:error, :not_set_up}
      end

      assert {count(Organisation), count(Apiary.Accounts.User)} == before
      assert ApiaryPro.Organisations.instance_organisation() == nil
    end

    @tag with_features: Features.all()
    test "by the link a start logs, with managed_organisations, is the instance organisation, an operator" do
      set_up_by_logged_link!(:operator)
    end

    @tag with_features: Features.all() -- [:managed_organisations]
    test "by the link a start logs, without managed_organisations, is the instance organisation, an organisation" do
      set_up_by_logged_link!(:organisation)
    end
  end

  # The instance's set-up, with the code `Apiary.Setup.code!/0` finds or makes.
  defp set_up(attrs) do
    attrs = Enum.into(attrs, %{email: unique_user_email(), organisation_name: "Acme Hosting"})
    Apiary.Setup.set_up(Apiary.Setup.code!(), attrs)
  end

  # The core's step at a start (`Apiary.Setup`), as the application's supervisor starts
  # it, and the set-up by the link it logs: the instance organisation of `kind`, its owner
  # an instance admin, and no workspace.
  defp set_up_by_logged_link!(kind) do
    level = Logger.level()
    Logger.configure(level: :info)

    log =
      try do
        capture_log([level: :info], fn -> assert Apiary.Setup.start_link() == :ignore end)
      after
        Logger.configure(level: level)
      end

    assert [_line, code] = Regex.run(~r{Set up Qory Apiary at \S+/setup/([\w-]+)\.}, log)

    assert {:ok, _signed_up} =
             Apiary.Setup.set_up(code, %{
               email: "setup-admin@example.com",
               organisation_name: "Acme Setup"
             })

    assert %Organisation{name: "Acme Setup"} =
             organisation = ApiaryPro.Tenants.instance_organisation()

    assert ApiaryPro.Tenants.kind(organisation) == kind

    user = Apiary.Accounts.get_user_by_email("setup-admin@example.com")

    assert %Membership{level: :owner} =
             Repo.get_by(Membership, organisation_id: organisation.id, user_id: user.id)

    assert Apiary.Access.instance_admin?(Apiary.Accounts.Scope.for_user(user))

    assert [] = Organisations.list_workspaces(Apiary.Accounts.Scope.for_instance(organisation))
  end

  # The instance's set-up, with both settings closed: the instance organisation of
  # `kind`, with no workspace, its owner an instance admin, and its entry, the
  # instance's.
  defp first_sign_up!(kind) do
    open!([])
    before = {count(Organisation), count(Workspace), count(Membership)}

    assert SignUp.offer() == :not_set_up

    assert {:ok, %{user: user, organisation: organisation, workspace: nil}} =
             set_up(%{email: "first@example.com"})

    assert %Organisation{name: "Acme Hosting"} = organisation
    assert %Tenant{kind: ^kind, instance_organisation: true} = tenant_of(organisation)

    assert ApiaryPro.Organisations.instance_organisation().id == organisation.id
    assert Apiary.Access.instance_admin?(Apiary.Accounts.Scope.for_user(user))

    {organisations, workspaces, memberships} = before
    assert count(Organisation) == organisations + 1
    assert count(Workspace) == workspaces
    assert count(Membership) == memberships + 1

    assert [entry] =
             Repo.all(
               from e in Entry,
                 where:
                   e.organisation_id == ^organisation.id and e.action == "organisation.create"
             )

    assert entry.after == %{"kind" => Atom.to_string(kind)}
    assert entry.details["instance_organisation"] == true
    assert entry.details["sign_up"] == true
    # By the instance, from the set-up.
    assert {entry.actor_kind, entry.actor_id} == {:instance, nil}
    assert entry.worker == "Apiary.Setup"
    assert entry.details["user_id"] == user.id

    # The next sign-up is a later one: none, with both closed.
    assert SignUp.offer() == []
  end

  describe "a later sign-up" do
    test "with both settings closed is refused, and creates nothing" do
      open!([])
      before = {count(Organisation), count(Apiary.Accounts.User)}
      assert SignUp.offer() == []

      for kind <- [nil, "organisation", "operator"] do
        assert {:error, changeset} = sign_up(%{kind: kind})
        assert %{email: [message]} = errors_on(changeset)
        assert message =~ "without an invitation"
      end

      assert {count(Organisation), count(Apiary.Accounts.User)} == before
    end

    test "with organisations open creates an organisation, and nothing else" do
      open!([:organisation])
      assert SignUp.offer() == [:organisation]

      assert {:ok, %{organisation: created}} =
               sign_up()

      assert %Tenant{kind: :organisation, instance_organisation: false} = tenant_of(created)

      assert {:ok, %{organisation: created}} =
               sign_up(%{kind: "organisation"})

      assert %Tenant{kind: :organisation} = tenant_of(created)

      assert {:error, changeset} = sign_up(%{kind: "operator"})
      assert %{kind: ["is not open for sign-up"]} = errors_on(changeset)
    end

    test "with operators open creates an operator, and nothing else" do
      open!([:operator])
      assert SignUp.offer() == [:operator]

      assert {:ok, %{organisation: created}} =
               sign_up()

      assert %Tenant{kind: :operator, instance_organisation: false} = tenant_of(created)

      assert {:error, changeset} = sign_up(%{kind: "organisation"})
      assert %{kind: ["is not open for sign-up"]} = errors_on(changeset)
    end

    test "with both open asks which, and creates the one chosen" do
      open!([:organisation, :operator])
      assert SignUp.offer() == [:organisation, :operator]

      assert {:error, changeset} = sign_up()
      assert %{kind: ["choose what to create"]} = errors_on(changeset)

      for kind <- [:organisation, :operator] do
        assert {:ok, %{organisation: created}} =
                 sign_up(%{kind: Atom.to_string(kind)})

        assert %Tenant{kind: ^kind, instance_organisation: false} = tenant_of(created)
      end

      # The instance organisation is never a kind to choose.
      for kind <- ["instance_organisation", "instance", "bank"] do
        assert {:error, changeset} = sign_up(%{kind: kind})
        assert %{kind: ["choose what to create"]} = errors_on(changeset)
      end

      assert [_one] = Repo.all(from t in Tenant, where: t.instance_organisation)
    end

    test "the instance's settings answer when the sign-up names none: organisations, in the suite" do
      assert SignUp.offer() == [:organisation]
      assert Organisations.sign_up_offer() == :open
      assert {:ok, %{organisation: created}} = sign_up()
      assert %Tenant{kind: :organisation} = tenant_of(created)
    end

    test "an operator's entry says its kind" do
      open!([:operator])

      assert {:ok, %{organisation: operator}} = sign_up(%{kind: "operator"})

      assert [entry] =
               Repo.all(
                 from e in Entry,
                   where: e.organisation_id == ^operator.id and e.action == "organisation.create"
               )

      assert entry.after == %{"kind" => "operator"}
      assert entry.details["instance_organisation"] == false
    end
  end

  describe "a crafted later sign-up" do
    test "never makes the instance organisation, whatever it names" do
      for open <- [[:organisation], [:operator], [:organisation, :operator]],
          attrs <- [
            %{kind: "instance_organisation"},
            %{instance_organisation: "true"},
            %{instance_organisation: true, kind: "operator"},
            %{kind: "instance_organisation", instance_organisation: "true"}
          ] do
        open!(open)

        case sign_up(attrs) do
          {:ok, %{organisation: organisation}} ->
            tenant = tenant_of(organisation)
            refute tenant.instance_organisation
            assert tenant.kind in open

          {:error, changeset} ->
            assert errors_on(changeset)[:kind]
        end
      end

      assert [_one] = Repo.all(from t in Tenant, where: t.instance_organisation)
    end
  end

  describe "change_sign_up/2" do
    test "asks for a kind among two, takes the one of one, and asks none of none" do
      attrs = %{"email" => "a@example.com", "organisation_name" => "Acme"}

      changeset = SignUp.change_sign_up(attrs, kinds: [:organisation, :operator])
      assert %{kind: ["choose what to create"]} = errors_on(changeset)

      changeset =
        SignUp.change_sign_up(Map.put(attrs, "kind", "operator"),
          kinds: [:organisation, :operator]
        )

      assert changeset.valid?

      changeset = SignUp.change_sign_up(attrs, kinds: [:operator])
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :kind) == "operator"

      changeset =
        SignUp.change_sign_up(Map.put(attrs, "kind", "organisation"), kinds: [:operator])

      assert %{kind: ["is not open for sign-up"]} = errors_on(changeset)

      changeset = SignUp.change_sign_up(Map.put(attrs, "kind", "operator"), kinds: [])
      assert Ecto.Changeset.get_field(changeset, :kind) == nil
    end

    test "asks no kind of a sign-up with an invitation" do
      changeset = SignUp.change_sign_up(%{"email" => "a@example.com"}, invited: true)
      assert changeset.valid?
    end
  end
end
