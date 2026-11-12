defmodule ApiaryPro.ModelChainTest do
  # Which model providers the runs of a client use: its switch, `model_chain` on its
  # tenant, set by its operator's owners and admins (`ApiaryPro.Operators.set_model_chain/3`)
  # while the operator owns its clients (`ApiaryPro.Flags.operator_infrastructure?/0`), and
  # read by `ApiaryPro.Edition.model_choice_chain/1` and by the access check.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  import Ecto.Query, only: [from: 2]

  alias Apiary.Access
  alias Apiary.Audit.Entry
  alias ApiaryPro.{Edition, Flags, Operators, Tenants, Transfers}
  alias ApiaryPro.Tenants.Tenant

  @moduletag with_features: Apiary.Features.all()

  # An operator and its client, made while the flag is off, then the flag on; and another
  # operator with a client.
  setup do
    Flags.put_transfers(true)
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

  defp set(ctx, chain), do: Operators.set_model_chain(ctx.operator.scope, id(ctx), chain)

  defp id(ctx), do: ctx.client.organisation.id

  defp entries(action),
    do: Repo.all(from e in Entry, where: e.action == ^action, order_by: [asc: e.inserted_at])

  describe "the switch" do
    test "is the organisation's by default, and so is the chain", ctx do
      assert chain(ctx.client) == :organisation
      assert Edition.model_choice_chain(id(ctx)) == "organisation"
      assert Edition.model_choice_chain(ctx.operator.organisation.id) == "organisation"
      assert Edition.model_choice_chain(sign_up_fixture().organisation.id) == "organisation"
    end

    test "is set to the operator's by an owner of the operator, and the chain follows", ctx do
      assert {:ok, client} = set(ctx, :operator)
      assert Tenants.model_chain(client) == :operator
      assert Repo.get!(Tenant, id(ctx)).model_chain == :operator
      assert Edition.model_choice_chain(id(ctx)) == "operator"

      assert {:ok, _client} = set(ctx, "organisation")
      assert Edition.model_choice_chain(id(ctx)) == "organisation"
    end

    test "is set by an admin of the operator", ctx do
      assert {:ok, _client} =
               Operators.set_model_chain(ctx.operator_admin.scope, id(ctx), "operator")

      assert Edition.model_choice_chain(id(ctx)) == "operator"
    end

    test "is not set to a value that is neither", ctx do
      assert {:error, :not_found} = set(ctx, "everyone")
      assert chain(ctx.client) == :organisation
    end

    test "leaves the other clients of the operator and of others as they are", ctx do
      {:ok, _client} = set(ctx, :operator)

      assert Edition.model_choice_chain(ctx.other_client.organisation.id) == "organisation"
      assert Edition.model_choice_chain(ctx.operator.organisation.id) == "organisation"
    end

    test "answers the organisation's with the flag off, and is not set", ctx do
      {:ok, _client} = set(ctx, :operator)
      Flags.put_operator_infrastructure(false)

      assert Edition.model_choice_chain(id(ctx)) == "organisation"
      assert {:error, :not_found} = set(ctx, :organisation)
      assert chain(ctx.client) == :operator

      Flags.put_operator_infrastructure(true)
      assert Edition.model_choice_chain(id(ctx)) == "operator"
    end

    test "is not set with the flag off", ctx do
      Flags.put_operator_infrastructure(false)

      assert {:error, :not_found} = set(ctx, :operator)

      assert {:error, :not_found} =
               Operators.set_model_chain(ctx.operator_admin.scope, id(ctx), :operator)

      assert chain(ctx.client) == :organisation
      assert entries("client.set_model_chain") == []
    end

    test "is not set by the client's people", ctx do
      for scope <- [ctx.client.owner.scope, ctx.client_admin.scope] do
        assert {:error, :not_found} = Operators.set_model_chain(scope, id(ctx), :operator)
      end

      assert chain(ctx.client) == :organisation
    end

    test "is not set by a member of the operator", ctx do
      assert {:error, :forbidden} =
               Operators.set_model_chain(ctx.operator_member.scope, id(ctx), :operator)

      assert chain(ctx.client) == :organisation
    end

    test "is not set by the people of another operator", ctx do
      assert {:error, :not_found} =
               Operators.set_model_chain(ctx.elsewhere.scope, id(ctx), :operator)

      assert {:error, :not_found} = Operators.set_model_chain(ctx.operator.scope, "x", :operator)

      assert {:error, :not_found} =
               Operators.set_model_chain(
                 ctx.operator.scope,
                 ctx.other_client.organisation.id,
                 :operator
               )

      assert chain(ctx.client) == :organisation
      assert chain(ctx.other_client) == :organisation
    end

    test "is not set for an organisation that is no client", ctx do
      assert {:error, :not_found} =
               Operators.set_model_chain(
                 ctx.operator.scope,
                 sign_up_fixture().organisation.id,
                 :operator
               )

      assert {:error, :not_found} =
               Operators.set_model_chain(
                 ctx.operator.scope,
                 ctx.operator.organisation.id,
                 :operator
               )
    end

    test "is refused by the database for an organisation that has no operator", _ctx do
      organisation = sign_up_fixture().organisation
      tenant = Repo.get!(Tenant, organisation.id)

      assert {:error, changeset} =
               tenant |> Tenants.model_chain_changeset(:operator) |> Repo.update()

      assert %{model_chain: [_message]} = errors_on(changeset)
      assert Repo.get!(Tenant, organisation.id).model_chain == :organisation
    end

    test "is written in the operator's trail, by the person who set it", ctx do
      {:ok, _client} = Operators.set_model_chain(ctx.operator_admin.scope, id(ctx), :operator)

      assert [entry] = entries("client.set_model_chain")
      assert entry.organisation_id == ctx.operator.organisation.id
      assert {entry.actor_kind, entry.actor_id} == {:person, ctx.operator_admin.user.id}
      assert entry.details == %{"organisation_id" => id(ctx)}
      assert entry.before == %{"model_chain" => "organisation"}
      assert entry.after == %{"model_chain" => "operator"}
    end

    test "writes no entry for the value it has", ctx do
      assert {:ok, _client} = set(ctx, :organisation)
      assert entries("client.set_model_chain") == []

      {:ok, _client} = set(ctx, :operator)
      {:ok, _client} = set(ctx, :operator)
      assert [_one] = entries("client.set_model_chain")
    end

    test "is not set for a suspended client", ctx do
      {:ok, _tenant} =
        ctx.client.organisation
        |> Tenants.tenant()
        |> Tenants.suspension_changeset(:suspend, nil)
        |> Repo.update()

      assert {:error, :suspended} = set(ctx, :operator)
      assert chain(ctx.client) == :organisation
    end
  end

  describe "a drop" do
    test "sets the switch back to the organisation's", ctx do
      {:ok, _client} = set(ctx, :operator)
      assert chain(ctx.client) == :operator

      # A drop is not offered while the operator owns its clients: it is done as before.
      Flags.put_operator_infrastructure(false)
      id = id(ctx)

      assert {:ok, _client} =
               Transfers.drop(ctx.operator.scope, id, ctx.client.organisation.name)

      assert Repo.get!(Tenant, id).operator_id == nil
      assert Repo.get!(Tenant, id).model_chain == :organisation
      Flags.put_operator_infrastructure(true)
      assert Edition.model_choice_chain(id) == "organisation"
    end

    test "is refused with the switch unchanged when it fails", ctx do
      {:ok, _client} = set(ctx, :operator)
      Flags.put_operator_infrastructure(false)

      assert {:error, :confirmation} = Transfers.drop(ctx.operator.scope, id(ctx), "Not it")
      assert Repo.get!(Tenant, id(ctx)).model_chain == :operator
    end

    test "is also what a client's leaving does", ctx do
      {:ok, _client} = set(ctx, :operator)
      Flags.put_operator_infrastructure(false)

      assert {:ok, _client} =
               Transfers.leave(ctx.client.owner.scope, ctx.operator.organisation.name)

      assert Repo.get!(Tenant, id(ctx)).model_chain == :organisation
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

      {action, on} = hd(@chain_held)

      assert Access.authorize(scopes.operator_admin, action, subject(client, on)) ==
               {:error, :forbidden}
    end

    test "on the operator's providers, the operator's owner and admin do, the client's do not",
         ctx do
      client = model_chain_fixture(ctx.operator.scope, ctx.client, :operator)
      scopes = scopes(ctx, client)

      for held <- @chain_held do
        refute may?(scopes.client_owner, held, client), inspect(held)
        refute may?(scopes.client_admin, held, client), inspect(held)
        assert may?(scopes.operator_owner, held, client), inspect(held)
        assert may?(scopes.operator_admin, held, client), inspect(held)
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

    test "the action is the operator's, found in the operator alone", ctx do
      action = :"client.set_model_chain"

      assert Access.can?(ctx.operator.scope, action, ctx.operator.organisation)
      assert Access.can?(ctx.operator_admin.scope, action, ctx.operator.organisation)
      refute Access.can?(ctx.operator_member.scope, action, ctx.operator.organisation)
      refute Access.can?(ctx.client.owner.scope, action, ctx.client.organisation)

      Flags.put_operator_infrastructure(false)
      refute Access.can?(ctx.operator.scope, action, ctx.operator.organisation)
    end
  end
end
