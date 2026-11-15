defmodule ApiaryPro.Places do
  @moduledoc """
  Places is every organisation a person reaches from the organisation switcher and their
  organisations page (`c:Apiary.Edition.places/1`): their memberships, and the
  organisations whose workspaces an operator they belong to operates, which they reach
  through it (`ApiaryPro.Reach`), each an `ApiaryPro.ClientReach`.
  """

  import Ecto.Query, warn: false

  alias Apiary.{Organisations, Repo}
  alias Apiary.Accounts.User
  alias Apiary.Organisations.{Membership, Organisation, Workspace}
  alias ApiaryPro.{ClientReach, Tenants, WorkspaceOperators}
  alias ApiaryPro.Operators.WorkspaceOperator

  @doc """
  places/1 is every organisation the user reaches from the switcher: their memberships,
  as `Apiary.Organisations.list_memberships/1` has them, and each organisation with a
  workspace that an operator they belong to operates, where the operator is not
  suspended, as a `ApiaryPro.ClientReach` with those workspaces, the ones they reach
  through their operators. An organisation they are also a member of is one
  `ClientReach`, which has that membership too, and the workspaces it reaches besides.
  Such an organisation sits under the operator of its first such workspace by name. These
  come after the memberships, by name. None marked for deletion. Each organisation
  has its tenant (`ApiaryPro.Tenants`) and the links of its workspaces
  (`ApiaryPro.WorkspaceOperators`).
  """
  @spec places(%User{}) :: [%Membership{} | ClientReach.t()]
  def places(%User{} = user) do
    memberships = put_tenants(Organisations.list_memberships(user))

    operators =
      for %Membership{organisation: %Organisation{} = organisation} = membership <- memberships,
          Tenants.operator?(organisation) and not Tenants.suspended?(organisation),
          into: %{},
          do: {membership.organisation_id, membership}

    operated =
      if operators == %{} do
        []
      else
        operator_ids = Map.keys(operators)

        Repo.all(
          from l in WorkspaceOperator,
            join: w in Workspace,
            on: w.id == l.workspace_id and w.organisation_id == l.organisation_id,
            join: o in Organisation,
            on: o.id == l.organisation_id,
            where: l.operator_id in ^operator_ids,
            where: is_nil(o.deletion_marked_at) and is_nil(w.deletion_marked_at),
            order_by: [asc: o.name, asc: o.id, asc: w.name, asc: w.id],
            select: {o, w, l.operator_id}
        )
      end

    own = Map.new(memberships, &{&1.organisation_id, &1})

    reached =
      operated
      |> Enum.chunk_by(fn {organisation, _workspace, _operator_id} -> organisation.id end)
      |> Enum.map(fn [{organisation, _workspace, first_operator_id} | _rest] = rows ->
        organisation = organisation |> Tenants.put() |> WorkspaceOperators.put()
        membership = own[organisation.id]
        through = Enum.map(rows, fn {_organisation, workspace, _operator_id} -> workspace end)

        %ClientReach{
          organisation: organisation,
          organisation_id: organisation.id,
          operator_membership: Map.fetch!(operators, first_operator_id),
          membership: membership,
          workspaces: merge_workspaces(through, membership)
        }
      end)

    reached_ids = MapSet.new(reached, & &1.organisation_id)

    Enum.reject(memberships, &MapSet.member?(reached_ids, &1.organisation_id)) ++ reached
  end

  # The workspaces reached through the operators, with those the membership in the
  # organisation reaches besides, by name.
  defp merge_workspaces(through, nil), do: through

  defp merge_workspaces(through, %Membership{workspaces: workspaces}) when is_list(workspaces) do
    (through ++ workspaces)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&{&1.name, &1.id})
  end

  defp merge_workspaces(through, _membership), do: through

  # The memberships' organisations, each carrying its tenant, in one read.
  defp put_tenants(memberships) do
    organisations = memberships |> Enum.map(& &1.organisation) |> Tenants.put()
    Enum.zip_with(memberships, organisations, &%{&1 | organisation: &2})
  end
end
