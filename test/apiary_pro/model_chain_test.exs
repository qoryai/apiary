defmodule ApiaryPro.ModelChainTest do
  # Which model providers the runs of a client use: its switch, `model_chain` on its
  # tenant, read while the operator owns its clients
  # (`ApiaryPro.Flags.operator_infrastructure?/0`) by `ApiaryPro.Edition.model_choice_chain/1`
  # and by the access check. No code in the product sets the switch any more: the tests
  # write it to the tenant row (`model_chain_fixture/3`).
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.Access
  alias ApiaryPro.{Edition, Flags, Tenants}
  alias ApiaryPro.Tenants.Tenant

  @moduletag with_features: Apiary.Features.all()

  # An operator and its client, made while the flag is off, then the flag on; and another
  # operator with a client.
  setup do
    Flags.put_operator_infrastructure(false)

    operator = operator_fixture()
    client = client_fixture(operator.scope)
    operator_admin = member_fixture(operator.scope, :admin)
    operator_member = member_fixture(operator.scope, :member)
    client_admin = client_member_fixture(client, :admin)

    elsewhere = operator_fixture()
    other_client = client_fixture(elsewhere.scope)

    Flags.put_operator_infrastructure(true)

    %{
      operator: operator,
      client: client,
      client_admin: client_admin,
      operator_admin: operator_admin,
      operator_member: operator_member,
      elsewhere: elsewhere,
      other_client: other_client
    }
  end

  defp chain(client), do: Tenants.model_chain_of(client.organisation.id)

  # The client's switch set to `chain`, written to its tenant row.
  defp set(ctx, chain), do: model_chain_fixture(ctx.operator.scope, ctx.client, chain)

  defp id(ctx), do: ctx.client.organisation.id

  describe "the switch" do
    test "is the organisation's by default, and so is the chain", ctx do
      assert chain(ctx.client) == :organisation
      assert Edition.model_choice_chain(id(ctx)) == "organisation"
      assert Edition.model_choice_chain(ctx.operator.organisation.id) == "organisation"
      assert Edition.model_choice_chain(sign_up_fixture().organisation.id) == "organisation"
    end

    test "set to the operator's, the chain follows", ctx do
      client = set(ctx, :operator)
      assert Tenants.model_chain(client.organisation) == :operator
      assert Edition.model_choice_chain(id(ctx)) == "operator"

      set(ctx, :organisation)
      assert Edition.model_choice_chain(id(ctx)) == "organisation"
    end

    test "of one client leaves the other clients of the operator and of others as they are",
         ctx do
      set(ctx, :operator)

      assert Edition.model_choice_chain(ctx.other_client.organisation.id) == "organisation"
      assert Edition.model_choice_chain(ctx.operator.organisation.id) == "organisation"
    end

    test "answers the organisation's with the flag off", ctx do
      set(ctx, :operator)
      Flags.put_operator_infrastructure(false)

      assert Edition.model_choice_chain(id(ctx)) == "organisation"
      assert chain(ctx.client) == :operator

      Flags.put_operator_infrastructure(true)
      assert Edition.model_choice_chain(id(ctx)) == "operator"
    end

    test "is refused by the database for an organisation that has no operator", _ctx do
      organisation = sign_up_fixture().organisation
      tenant = Repo.get!(Tenant, organisation.id)

      assert {:error, changeset} =
               tenant |> Tenants.model_chain_changeset(:operator) |> Repo.update()

      assert %{model_chain: [_message]} = errors_on(changeset)
      assert Repo.get!(Tenant, organisation.id).model_chain == :organisation
    end
  end

  defp fresh(person, client), do: scope_in(person.user, client.organisation, client.workspace)

  describe "who may write the model providers" do
    @chain_held [
      {:"provider.write", :organisation},
      {:"runtime.write", :organisation},
      {:"model_choice.write", :workspace}
    ]
    @always_operator_held [{:"time_limit.edit", :workspace}, {:"retention.edit", :workspace}]

    defp subject(client, :organisation), do: client.organisation
    defp subject(client, :workspace), do: client.workspace

    defp may?(scope, {action, on}, client), do: Access.can?(scope, action, subject(client, on))

    defp scopes(ctx, client) do
      %{
        client_owner: client.owner.scope,
        client_admin: fresh(ctx.client_admin, client),
        operator_owner: client.scope,
        operator_admin: fresh(ctx.operator_admin, client),
        operator_member: fresh(ctx.operator_member, client)
      }
    end

    test "on the client's providers, the client's owner and admin do, the operator's do not",
         ctx do
      # The default; set again to show the write leaves it.
      client = model_chain_fixture(ctx.operator.scope, ctx.client, :organisation)
      scopes = scopes(ctx, client)

      for held <- @chain_held do
        assert may?(scopes.client_owner, held, client), inspect(held)
        assert may?(scopes.client_admin, held, client), inspect(held)
        refute may?(scopes.operator_owner, held, client), inspect(held)
        refute may?(scopes.operator_admin, held, client), inspect(held)
        refute may?(scopes.operator_member, held, client), inspect(held)
      end

      # In Main through the operator, forbidden; of what the client owns as a whole, not
      # found.
      assert Access.authorize(scopes.operator_admin, :"model_choice.write", client.workspace) ==
               {:error, :forbidden}

      assert Access.authorize(scopes.operator_admin, :"provider.write", client.organisation) ==
               {:error, :not_found}
    end

    test "on the operator's providers, the operator's owner and admin do in Main, the client's do not",
         ctx do
      client = model_chain_fixture(ctx.operator.scope, ctx.client, :operator)
      scopes = scopes(ctx, client)

      # The client's providers and runtimes, which it owns as a whole, nobody writes: a
      # level in the operator counts in Main alone.
      for {_action, on} = held <- @chain_held do
        refute may?(scopes.client_owner, held, client), inspect(held)
        refute may?(scopes.client_admin, held, client), inspect(held)
        assert may?(scopes.operator_owner, held, client) == (on == :workspace), inspect(held)
        assert may?(scopes.operator_admin, held, client) == (on == :workspace), inspect(held)
        refute may?(scopes.operator_member, held, client), inspect(held)
      end

      {action, on} = hd(@chain_held)

      assert Access.authorize(scopes.client_admin, action, subject(client, on)) ==
               {:error, :not_found}
    end

    test "the time limits and the retention stay the operator's on either", ctx do
      for chain <- [:organisation, :operator] do
        client = model_chain_fixture(ctx.operator.scope, ctx.client, chain)
        scopes = scopes(ctx, client)

        for held <- @always_operator_held do
          refute may?(scopes.client_owner, held, client), "#{chain} #{inspect(held)}"
          refute may?(scopes.client_admin, held, client), "#{chain} #{inspect(held)}"
          assert may?(scopes.operator_owner, held, client), "#{chain} #{inspect(held)}"
          assert may?(scopes.operator_admin, held, client), "#{chain} #{inspect(held)}"
        end
      end
    end

    test "with the flag off, the client's owner holds them and the operator's people do not",
         ctx do
      client = model_chain_fixture(ctx.operator.scope, ctx.client, :operator)
      Flags.put_operator_infrastructure(false)
      scopes = scopes(ctx, client)

      for held <- @chain_held do
        assert may?(scopes.client_owner, held, client), inspect(held)
        refute may?(scopes.operator_owner, held, client), inspect(held)
      end
    end

    test "a refusal says the operator sets them only on the operator's providers", ctx do
      sentence = "Set by your operator, #{ctx.operator.organisation.name}. Ask them to change it."

      for action <- [:"provider.write", :"runtime.write", :"model_choice.write"] do
        on_client = model_chain_fixture(ctx.operator.scope, ctx.client, :organisation)
        assert ApiaryProWeb.Edition.who_may_sentence(action, on_client.owner.scope) == nil

        on_operator = model_chain_fixture(ctx.operator.scope, ctx.client, :operator)
        assert ApiaryProWeb.Edition.who_may_sentence(action, on_operator.owner.scope) == sentence
      end

      for action <- [:"time_limit.edit", :"retention.edit"],
          chain <- [:organisation, :operator] do
        client = model_chain_fixture(ctx.operator.scope, ctx.client, chain)
        assert ApiaryProWeb.Edition.who_may_sentence(action, client.owner.scope) == sentence
      end
    end

    test "a person of the operator who is also in the client acts at the higher level", ctx do
      # An admin of the operator, made a member of the client: the operator level is higher.
      member = join_fixture(ctx.client.owner.scope, ctx.operator_admin.user)
      client = model_chain_fixture(ctx.operator.scope, ctx.client, :organisation)
      scope = fresh(ctx.operator_admin, client)

      for {action, on} <- @chain_held do
        assert Access.authorize(scope, action, subject(client, on)) == {:error, :forbidden},
               "#{action}"
      end

      # Made an admin of the client too, they are level with it and act there as its admin.
      {:ok, _} =
        Apiary.Organisations.set_member_level(
          ctx.client.owner.scope,
          member.membership.id,
          :admin
        )

      scope = fresh(ctx.operator_admin, client)

      for {action, on} <- @chain_held do
        assert Access.authorize(scope, action, subject(client, on)) == :ok, "#{action}"
      end
    end
  end
end
