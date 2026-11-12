defmodule ApiaryPro.Places do
  @moduledoc """
  Places is every organisation a person reaches from the organisation switcher and their
  organisations page (`c:Apiary.Edition.places/1`): their memberships,
  and the clients of each operator they belong to, which they read through it
  (`ApiaryPro.Reach`), each an `ApiaryPro.ClientReach`.
  """

  import Ecto.Query, warn: false

  alias Apiary.{Organisations, Repo}
  alias Apiary.Accounts.User
  alias Apiary.Organisations.{Membership, Organisation, Workspace}
  alias ApiaryPro.{ClientReach, Tenants}
  alias ApiaryPro.Tenants.Tenant

  @doc """
  places/1 is every organisation the user reaches from the switcher: their memberships,
  as `Apiary.Organisations.list_memberships/1` has them, and the clients of each operator
  they belong to that is not suspended, each a `ApiaryPro.ClientReach` with
  every workspace of the client, since they read them all through the operator. A client
  they are also a member of is one `ClientReach`, which carries that membership too.
  Clients come after the memberships, by name. None marked for deletion. Each
  organisation carries its tenant (`ApiaryPro.Tenants`).
  """
  @spec places(%User{}) :: [%Membership{} | ClientReach.t()]
  def places(%User{} = user) do
    memberships = put_tenants(Organisations.list_memberships(user))

    operators =
      for %Membership{organisation: %Organisation{} = organisation} = membership <- memberships,
          Tenants.operator?(organisation) and not Tenants.suspended?(organisation),
          into: %{},
          do: {membership.organisation_id, membership}

    clients =
      if operators == %{} do
        []
      else
        operator_ids = Map.keys(operators)

        Repo.all(
          from o in Organisation,
            join: t in Tenant,
            on: t.organisation_id == o.id,
            where: t.operator_id in ^operator_ids and is_nil(o.deletion_marked_at),
            order_by: [asc: o.name, asc: o.id],
            select: {o, t}
        )
        |> Enum.map(fn {organisation, tenant} -> Tenants.put_tenant(organisation, tenant) end)
      end

    client_ids = MapSet.new(clients, & &1.id)

    workspaces =
      Repo.all(
        from w in Workspace,
          where:
            w.organisation_id in ^MapSet.to_list(client_ids) and is_nil(w.deletion_marked_at),
          order_by: [asc: w.name, asc: w.id]
      )
      |> Enum.group_by(& &1.organisation_id)

    own = Map.new(memberships, &{&1.organisation_id, &1})

    reached =
      for client <- clients do
        %ClientReach{
          organisation: client,
          organisation_id: client.id,
          operator_membership: Map.fetch!(operators, Tenants.operator_id(client)),
          membership: own[client.id],
          workspaces: Map.get(workspaces, client.id, [])
        }
      end

    Enum.reject(memberships, &MapSet.member?(client_ids, &1.organisation_id)) ++ reached
  end

  # The memberships' organisations, each carrying its tenant, in one read.
  defp put_tenants(memberships) do
    organisations = memberships |> Enum.map(& &1.organisation) |> Tenants.put()
    Enum.zip_with(memberships, organisations, &%{&1 | organisation: &2})
  end
end
