defmodule ApiaryPro.GatewaysTest do
  # The two answers the edition gives `Apiary.Gateways` (`ApiaryPro.Gateways`): while an
  # operator runs its clients' infrastructure (`ApiaryPro.Flags.operator_infrastructure?/0`),
  # a client is served by its operator, and an operator serves its clients; otherwise
  # nobody serves anybody. Neither answer looks at suspension or a mark for deletion. The
  # test of the instance organisation made an operator is in
  # `ApiaryPro.GatewaysInstanceOperatorTest`.
  use Apiary.DataCase, async: true
  use ExUnitProperties

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures
  import Ecto.Query, only: [from: 2]

  alias Apiary.{Deletion, Edition, Repo}
  alias ApiaryPro.{Flags, Gateways, Suspensions, Transfers}
  alias ApiaryPro.Tenants.Tenant

  @moduletag with_features: Apiary.Features.all()

  setup do
    Flags.put_transfers(true)
    Flags.put_operator_infrastructure(false)

    operator = operator_fixture()
    first = client_fixture(operator.scope)
    second = client_fixture(operator.scope)
    plain = sign_up_fixture()
    %{instance_scope: instance_admin} = suite_instance_admin()

    %{
      operator: operator,
      first: first,
      second: second,
      clients: Enum.sort([first.organisation.id, second.organisation.id]),
      plain: plain,
      instance_admin: instance_admin
    }
  end

  defp answers(%{id: id}), do: answers(id)

  defp answers(id) when is_binary(id),
    do: {Gateways.serving_organisations(id), Gateways.served_organisations(id)}

  describe "while the operator does not run its clients' infrastructure" do
    test "nobody serves anybody", ctx do
      for organisation <- [
            ctx.operator.organisation,
            ctx.first.organisation,
            ctx.second.organisation,
            ctx.plain.organisation,
            instance_organisation()
          ] do
        assert answers(organisation) == {[], []}
      end
    end

    test "the edition answers the core as the core's edition does", ctx do
      assert Edition.serving_organisations(ctx.first.organisation.id) == []
      assert Edition.served_organisations(ctx.operator.organisation.id) == []
      assert Apiary.Gateways.serving_organisations(ctx.first.organisation.id) == []
      assert Apiary.Gateways.served_organisations(ctx.operator.organisation.id) == []
    end
  end

  describe "while the operator runs its clients' infrastructure" do
    setup do: Flags.put_operator_infrastructure(true)

    test "a client is served by its operator, and by nobody else", ctx do
      operator_id = ctx.operator.organisation.id

      assert answers(ctx.first.organisation) == {[operator_id], []}
      assert answers(ctx.second.organisation) == {[operator_id], []}
    end

    test "an operator serves its clients, by id, and is served by nobody", ctx do
      assert answers(ctx.operator.organisation) == {[], ctx.clients}
    end

    test "an operator without clients, and an organisation with no operator, have none",
         ctx do
      lone = operator_fixture()

      assert answers(lone.organisation) == {[], []}
      assert answers(ctx.plain.organisation) == {[], []}
    end

    test "the edition and the core give the same answers", ctx do
      operator_id = ctx.operator.organisation.id

      assert Edition.serving_organisations(ctx.first.organisation.id) == [operator_id]
      assert Edition.served_organisations(operator_id) == ctx.clients
      assert Apiary.Gateways.serving_organisations(ctx.first.organisation.id) == [operator_id]
      assert Apiary.Gateways.served_organisations(operator_id) == ctx.clients
    end

    test "a suspended operator or client gives the same answers", ctx do
      before = Enum.map([ctx.operator.organisation, ctx.first.organisation], &answers/1)

      {:ok, _} =
        Suspensions.suspend_organisation(ctx.instance_admin, ctx.operator.organisation.id)

      {:ok, _} = Suspensions.suspend_organisation(ctx.instance_admin, ctx.first.organisation.id)

      assert Enum.map([ctx.operator.organisation, ctx.first.organisation], &answers/1) == before
    end

    test "a client marked for deletion gives the same answers", ctx do
      before = Enum.map([ctx.operator.organisation, ctx.first.organisation], &answers/1)

      Flags.put_operator_infrastructure(false)

      {:ok, _} =
        Deletion.delete_organisation(ctx.first.owner.scope, ctx.first.organisation.slug)

      Flags.put_operator_infrastructure(true)

      assert Enum.map([ctx.operator.organisation, ctx.first.organisation], &answers/1) == before
    end

    test "a dropped client is served by nobody, and its operator serves it no more", ctx do
      Flags.put_operator_infrastructure(false)

      {:ok, _} =
        Transfers.drop(
          ctx.operator.scope,
          ctx.first.organisation.id,
          ctx.first.organisation.name
        )

      Flags.put_operator_infrastructure(true)

      assert answers(ctx.first.organisation) == {[], []}
      assert answers(ctx.operator.organisation) == {[], [ctx.second.organisation.id]}
    end
  end

  describe "the two answers agree" do
    # A world of organisations: `operators` operators, and organisations each of which is
    # a client of one of them, or of none. Made by writing their tenants, as the database
    # keeps them: a client's operator is an operator.
    property "X serves Y exactly when Y is served by X, never itself, with the flag on and off" do
      check all(
              operators <- integer(1..3),
              others <- list_of(integer(0..3), max_length: 6),
              max_runs: 15
            ) do
        world = world(operators, others)

        for on? <- [true, false] do
          Flags.put_operator_infrastructure(on?)

          serving = Map.new(world.ids, &{&1, Gateways.serving_organisations(&1)})
          served = Map.new(world.ids, &{&1, Gateways.served_organisations(&1)})

          for x <- world.ids, y <- world.ids do
            assert x in serving[y] == y in served[x]
          end

          for id <- world.ids do
            refute id in serving[id]
            refute id in served[id]
            assert served[id] == Enum.sort(served[id])
            assert serving[id] == if(on?, do: List.wrap(world.operator_of[id]), else: [])
          end
        end
      end
    end
  end

  # The world's organisation ids, and each client's operator.
  defp world(operators, others) do
    operator_ids =
      for _ <- 1..operators do
        %{organisation: %{id: id}} = sign_up_fixture()

        Repo.update_all(from(t in Tenant, where: t.organisation_id == ^id),
          set: [kind: :operator]
        )

        id
      end

    pairs =
      for pick <- others do
        %{organisation: %{id: id}} = sign_up_fixture()
        operator_id = if pick > 0, do: Enum.at(operator_ids, rem(pick - 1, operators))

        if operator_id do
          Repo.update_all(from(t in Tenant, where: t.organisation_id == ^id),
            set: [operator_id: operator_id, operator_since: DateTime.utc_now()]
          )
        end

        {id, operator_id}
      end

    %{
      ids: operator_ids ++ Enum.map(pairs, &elem(&1, 0)),
      operator_of: Map.new(pairs)
    }
  end
end
