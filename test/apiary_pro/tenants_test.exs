defmodule ApiaryPro.TenantsTest do
  @moduledoc """
  Every organisation the edition creates has its tenant and its people lock beside it,
  written in the transaction that inserts the organisation
  (`ApiaryPro.Tenants.organisation_created/2`), by every way there is of creating one: the
  instance's first sign-up, its set-up, a later sign-up, a signed-in person's new
  organisation, an instance admin's, and an operator's client. And the people locks a
  change takes (`ApiaryPro.Tenants.lock_rows/1`), written first where one is missing.
  """
  # Not async: the instance's set-up takes the flag off the suite's instance
  # organisation, an instance admin is made an owner of it, and the kinds a sign-up may
  # create are the node's.
  use Apiary.DataCase, async: false

  import Apiary.AccountsFixtures, only: [unique_user_email: 0]
  import ApiaryPro.SignUpFixtures, only: [open!: 1]
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.Accounts.Scope
  alias ApiaryPro.{Operators, Tenants}
  alias ApiaryPro.Tenants.{PeopleLock, Tenant}

  # The tenant of the organisation `id`, which must be there with its people lock, both
  # written by the transaction that inserted the organisation: a row carries the id of the
  # transaction that wrote it, `xmin`, and in the sandbox each transaction is a savepoint
  # with an id of its own, so a row written by a step after the creation's carries
  # another.
  defp tenant!(id) do
    assert %{rows: [[true, true]]} =
             Repo.query!(
               """
               SELECT o.xmin = t.xmin, o.xmin = p.xmin FROM organisations o
               JOIN tenants t ON t.organisation_id = o.id
               JOIN people_locks p ON p.organisation_id = o.id
               WHERE o.id = $1
               """,
               [Ecto.UUID.dump!(id)]
             )

    assert %PeopleLock{inserted_at: %DateTime{}} = Repo.get!(PeopleLock, id)
    Repo.get!(Tenant, id)
  end

  defp first_sign_up do
    Apiary.EditionKit.hide_instance_organisation()

    {:ok, %{organisation: organisation}} =
      Apiary.Setup.set_up(Apiary.Setup.code!(), %{
        email: unique_user_email(),
        organisation_name: "Acme Hosting"
      })

    organisation
  end

  defp create_organisation(scope, kind) do
    {:ok, %{organisation: organisation}} =
      ApiaryPro.Organisations.create_organisation(scope, %{
        "name" => "Switcher #{kind} #{System.unique_integer([:positive])}",
        "kind" => kind
      })

    organisation
  end

  defp create_on_the_instance(instance_scope, kind) do
    {:ok, %{organisation: organisation}} =
      Operators.create_organisation(instance_scope, %{
        "name" => "Instance #{kind} #{System.unique_integer([:positive])}",
        "kind" => kind
      })

    organisation
  end

  @tag :feature_sets
  test "the instance's first sign-up creates the instance organisation's tenant" do
    organisation = first_sign_up()
    # Of the kind the instance's features give: an operator with `managed_organisations`.
    kind = if Apiary.Features.on?(:managed_organisations), do: :operator, else: :organisation

    assert %Tenant{
             kind: ^kind,
             instance_organisation: true,
             operator_id: nil,
             operator_since: nil,
             suspended_at: nil
           } = tenant!(organisation.id)

    assert Tenants.instance_organisation_id() == organisation.id
  end

  test "a later sign-up's tenant is of the kind it chose, never the instance organisation" do
    %{organisation: organisation} = sign_up_fixture()

    assert %Tenant{kind: :organisation, instance_organisation: false, operator_id: nil} =
             tenant!(organisation.id)

    open!([:organisation, :operator])

    for kind <- [:organisation, :operator] do
      %{organisation: organisation} = sign_up_fixture(%{kind: Atom.to_string(kind)})

      assert %Tenant{
               kind: ^kind,
               instance_organisation: false,
               operator_id: nil,
               operator_since: nil
             } = tenant!(organisation.id)
    end
  end

  test "a new organisation from the switcher has the tenant of the kind asked for" do
    %{scope: scope} = sign_up_fixture()
    open!([:organisation, :operator])

    for kind <- [:organisation, :operator] do
      organisation = create_organisation(scope, Atom.to_string(kind))

      assert %Tenant{kind: ^kind, instance_organisation: false, operator_id: nil} =
               tenant!(organisation.id)
    end
  end

  test "an instance admin's new organisation has the tenant of the kind they asked for" do
    %{instance_scope: instance_scope} = instance_admin_fixture()
    organisation = create_on_the_instance(instance_scope, "organisation")

    assert %Tenant{kind: :organisation, instance_organisation: false, operator_id: nil} =
             tenant!(organisation.id)
  end

  @tag needs: :managed_organisations
  test "an instance admin's new operator has the tenant of an operator" do
    %{instance_scope: instance_scope} = instance_admin_fixture()
    organisation = create_on_the_instance(instance_scope, "operator")

    assert %Tenant{kind: :operator, instance_organisation: false, operator_id: nil} =
             tenant!(organisation.id)
  end

  @tag needs: :managed_organisations
  test "an operator's client has a tenant naming the operator, and since when" do
    %{organisation: operator, scope: operator_scope} = operator_fixture()
    %{organisation: client} = client_fixture(operator_scope)

    operator_id = operator.id

    assert %Tenant{
             kind: :organisation,
             instance_organisation: false,
             operator_id: ^operator_id,
             operator_since: %DateTime{}
           } = tenant!(client.id)
  end

  @tag needs: :managed_organisations
  test "after every way of creating one, no organisation is without its tenant and people lock" do
    first_sign_up()
    %{scope: scope} = sign_up_fixture()
    %{instance_scope: instance_scope} = instance_admin_fixture()
    create_on_the_instance(instance_scope, "organisation")
    create_on_the_instance(instance_scope, "operator")
    %{scope: operator_scope} = operator_fixture()
    client_fixture(operator_scope)

    open!([:organisation, :operator])
    sign_up_fixture(%{kind: "operator"})
    create_organisation(scope, "operator")

    # The organisations of this sandbox and those committed, the suite's instance's among
    # them.
    assert %{rows: [[0]]} =
             Repo.query!("""
             SELECT count(*) FROM organisations o
             WHERE NOT EXISTS (SELECT 1 FROM tenants t WHERE t.organisation_id = o.id)
             """)

    assert %{rows: [[0]]} =
             Repo.query!("""
             SELECT count(*) FROM tenants t
             WHERE NOT EXISTS (SELECT 1 FROM people_locks p WHERE p.organisation_id = t.organisation_id)
             """)
  end

  describe "lock_rows/1" do
    # Operators and their clients are there with the managed organisations.
    @describetag needs: :managed_organisations

    # An operator, a client of it with its owner, and an ordinary organisation, with their
    # people locks deleted, as a tenant written without its row would have none.
    setup do
      %{scope: in_operator} = operator = operator_fixture()
      client = client_fixture(in_operator)
      %{organisation: other} = sign_up_fixture()
      ids = [operator.organisation.id, client.organisation.id, other.id]
      Repo.delete_all(from p in PeopleLock, where: p.organisation_id in ^ids)

      %{
        operator: operator.organisation,
        in_operator: in_operator,
        client: client,
        other: other
      }
    end

    test "a write in a client takes its operator's row, written first when it is missing",
         ctx do
      assert :ok = Tenants.lock_rows({:places, ctx.client.owner.scope})
      assert people_locks(ctx) == [ctx.operator.id]

      # The same rows again, in the same change.
      assert :ok = Tenants.lock_rows({:places, ctx.client.owner.scope})
      assert people_locks(ctx) == [ctx.operator.id]
    end

    test "a write without a person, or in no client, takes no row", ctx do
      assert :ok = Tenants.lock_rows({:places, Scope.for_instance(ctx.client.organisation)})
      assert :ok = Tenants.lock_rows({:places, ctx.in_operator})
      assert people_locks(ctx) == []
    end

    test "a change of an operator's people takes its own row; of a client's, its operator's",
         ctx do
      assert :ok = Tenants.lock_rows({:people, nil, ctx.client.organisation})
      assert people_locks(ctx) == []

      assert :ok = Tenants.lock_rows({:people, ctx.in_operator, ctx.operator})
      assert people_locks(ctx) == [ctx.operator.id]

      Repo.delete_all(from p in PeopleLock, where: p.organisation_id == ^ctx.operator.id)

      assert :ok =
               Tenants.lock_rows({:people, ctx.client.owner.scope, ctx.client.organisation})

      assert people_locks(ctx) == [ctx.operator.id]
    end

    test "an account's deletion takes the rows of exactly the organisations given", ctx do
      ids = [ctx.other.id, ctx.client.organisation.id]
      assert :ok = Tenants.lock_rows({:account, Ecto.UUID.generate(), ids})
      assert people_locks(ctx) == Enum.sort(ids)
    end

    test "an organisation without a tenant has no row to take", ctx do
      Repo.delete_all(from t in Tenant, where: t.organisation_id == ^ctx.other.id)

      assert :ok = Tenants.lock_rows({:account, Ecto.UUID.generate(), [ctx.other.id]})
      assert people_locks(ctx) == []
    end
  end

  # The people locks there are of the test's organisations, in order.
  defp people_locks(ctx) do
    ids = [ctx.operator.id, ctx.client.organisation.id, ctx.other.id]

    Repo.all(
      from p in PeopleLock,
        where: p.organisation_id in ^ids,
        order_by: p.organisation_id,
        select: p.organisation_id
    )
  end

  test "people locks are taken whatever ids are given: repeated, unordered, none, or unknown" do
    %{organisation: a} = sign_up_fixture()
    %{organisation: b} = sign_up_fixture()

    for mode <- [:share, :update] do
      assert :ok = Tenants.lock_people([b.id, a.id, b.id, Ecto.UUID.generate()], mode)
      assert :ok = Tenants.lock_people([], mode)
    end
  end
end
