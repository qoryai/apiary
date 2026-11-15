defmodule ApiaryPro.Mix.Tasks.ApiaryPro.DemoTest do
  # The demo world (`Mix.Tasks.ApiaryPro.Demo`): organisations the owner owns and joins, an
  # operator, runs in every workspace with an owner, and the arbitration and suspensions
  # after. Not async: it fills workspaces from several processes at
  # once, so the sandbox is shared, and it writes through the suite's instance
  # organisation, committed once outside the sandbox (docs/conventions.md, Tests). The
  # instance has every feature while it runs.
  use Apiary.DataCase, async: false

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  # The lapse of the arbiter's offer (`organisation.withdraw_transfer`) is found here, for
  # this process and those it starts (`ApiaryPro.Flags.put_transfers/1`).
  setup do: ApiaryPro.Flags.put_transfers(true)

  import ApiaryPro.OperatorsFixtures

  alias Apiary.Organisations.{Invitation, Membership, Organisation, Workspace}
  alias Apiary.Runs.Run
  alias ApiaryPro.Suspensions.AccountSuspension
  alias ApiaryPro.Tenants.Tenant
  alias ApiaryPro.Transfers.Transfer
  alias ApiaryPro.WorkspaceAccess.Row
  alias Mix.Tasks.ApiaryPro.Demo

  @moduletag with_features: Apiary.Features.all()

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)

    %{admin: instance_admin_fixture()}
  end

  defp build(admin, extra \\ []) do
    Demo.run(["--owner", admin.user.email, "--scale", "0.001"] ++ extra)
  end

  defp organisation(name), do: Repo.get_by!(Organisation, name: name)

  defp workspaces(%Organisation{id: id}),
    do: Repo.all(from w in Workspace, where: w.organisation_id == ^id)

  defp runs?(%Workspace{id: id}), do: Repo.exists?(from r in Run, where: r.workspace_id == ^id)

  defp counts do
    for schema <- [Organisation, Workspace, Apiary.Accounts.User, Membership, Invitation],
        into: %{},
        do: {schema, Repo.aggregate(schema, :count)}
  end

  test "the owner owns, administers and joins organisations of every kind", %{admin: admin} do
    build(admin)
    owner = admin.user

    levels =
      Map.new(
        Repo.all(
          from m in Membership,
            join: o in assoc(m, :organisation),
            where: m.user_id == ^owner.id,
            select: {o.name, m.level}
        )
      )

    assert %{
             "Vellorin Analytics" => :owner,
             "Quistral Studio" => :owner,
             "Ostrevane Robotics" => :admin,
             "Marrowick & Pend" => :member,
             "Zentrevo Works" => :owner
           } = levels

    # A member reaches the workspaces they were invited from and added to, and no other.
    marrowick = organisation("Marrowick & Pend")

    reached =
      Repo.all(
        from a in Row,
          join: w in assoc(a, :workspace),
          where: a.user_id == ^owner.id and a.organisation_id == ^marrowick.id,
          select: w.name
      )

    assert Enum.sort(reached) == ["Main", "Storefront"]
    assert length(workspaces(marrowick)) == 4

    # The twelve people the task makes, confirmed, one of them suspended in Vellorin Analytics.
    people =
      for name <- ~w(aisha.rahman bruno.costa chloe.martin dmitri.volkov farah.haddad
                     gustav.lind hana.sato ines.moreau jakub.novak kofi.mensah lucia.romano
                     mateo.garcia),
          do: Apiary.Accounts.get_user_by_email("#{name}@example.com")

    assert Enum.all?(people, &(&1 && &1.confirmed_at))

    vellorin = organisation("Vellorin Analytics")

    assert Repo.exists?(
             from m in Membership,
               where: m.organisation_id == ^vellorin.id and not is_nil(m.suspended_at)
           )
  end

  test "an operator with no clients, and runs in every workspace with an owner", %{admin: admin} do
    build(admin)
    operator = organisation("Zentrevo Works")
    assert Repo.get!(Tenant, operator.id).kind == :operator
    refute Repo.exists?(from t in Tenant, where: t.operator_id == ^operator.id)

    for name <- ["Vellorin Analytics", "Ostrevane Robotics", "Zentrevo Works"],
        workspace <- workspaces(organisation(name)),
        do: assert(runs?(workspace))
  end

  test "the runs of each workspace of the demo have different numbers", %{admin: admin} do
    build(admin)
    numbers = Repo.all(from r in Run, select: {r.workspace_id, r.number})
    assert length(numbers) > 100
    assert Enum.all?(numbers, fn {_workspace, number} -> is_integer(number) and number > 0 end)
    assert length(Enum.uniq(numbers)) == length(numbers)
  end

  test "features narrowed, an arbitration and suspensions",
       %{admin: admin} do
    build(admin, ["--skip-runs"])
    marrowick = organisation("Marrowick & Pend")

    assert :observability in ApiaryPro.Features.of(marrowick)
    refute :security in ApiaryPro.Features.of(marrowick)

    # A workspace has its organisation's features: nothing narrows one.
    vellorin = organisation("Vellorin Analytics")
    sandbox = Repo.get_by!(Workspace, organisation_id: vellorin.id, name: "Sandbox")

    assert ApiaryPro.Features.hidden(%Apiary.Accounts.Scope{
             organisation: vellorin,
             workspace: sandbox
           }) ==
             ApiaryPro.Features.hidden(%Apiary.Accounts.Scope{organisation: vellorin})

    refute Repo.get_by(Transfer, organisation_id: organisation("Quistral Studio").id)

    ines = Apiary.Accounts.get_user_by_email("ines.moreau@example.com")
    kofi = Apiary.Accounts.get_user_by_email("kofi.mensah@example.com")
    assert Repo.get_by(AccountSuspension, user_id: ines.id)

    assert %Transfer{kind: :to_admin, arbitrated: true, recipient_id: recipient} =
             Repo.get_by!(Transfer, organisation_id: marrowick.id)

    assert recipient == kofi.id
  end

  test "an instance set up with no workspace yet gets Main from the demo", %{admin: admin} do
    instance = ApiaryPro.Organisations.instance_organisation()
    Repo.delete_all(from w in Workspace, where: w.organisation_id == ^instance.id)
    refute Apiary.Organisations.has_workspace?(instance)

    build(admin)

    assert [%Workspace{name: "Main", domain: "software"}] = workspaces(instance)
    assert Apiary.Organisations.has_workspace?(instance)
  end

  test "a second run finds what the first made and makes nothing twice", %{admin: admin} do
    build(admin, ["--skip-runs"])
    made = counts()
    entries = Repo.aggregate(Apiary.Audit.Entry, :count)

    build(admin, ["--skip-runs"])

    assert counts() == made
    assert Repo.aggregate(Apiary.Audit.Entry, :count) == entries
  end

  test "an instance without the operators' feature is refused" do
    Application.put_env(
      :apiary,
      :features,
      Apiary.Features.all() -- [:managed_organisations]
    )

    assert_raise Mix.Error, ~r/QORY_FEATURES=all/, fn -> Demo.run(["--skip-runs"]) end
  end
end
