defmodule ApiaryPro.Races do
  @moduledoc """
  The edition's helpers for the tests that race two changes on separate connections,
  beside the core's (`Apiary.Races`), whose setup and clean-up they share: what they make is
  remembered for `on_exit` to delete, and named as a race's.
  """

  import Ecto.Query, only: [from: 2]

  alias Apiary.{OrganisationsFixtures, Races, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Membership, Organisation}

  @doc """
  A client of the scope's operator, made as `ApiaryPro.OperatorsFixtures.client_fixture/2`
  makes one: its first person signs up with a race's address and creates it, with its
  first workspace Main, under a race's name; its tenant row is written with the operator,
  it is granted what the operator has, and the operator operates Main
  (`ApiaryPro.OperatorsFixtures.operate_fixture/2`). While
  `ApiaryPro.Flags.operator_infrastructure?/0` is on, the first person is its admin. The
  client, its workspace, `scope`, the operator's person's scope in it, and `owner`, the
  first person's fixture, `scope` theirs in Main.
  """
  @spec client(Scope.t()) :: map
  def client(%Scope{} = operator_scope) do
    operator = operator_scope.organisation

    owner =
      Races.created(
        OrganisationsFixtures.sign_up_fixture(%{
          email: Races.email(),
          organisation_name: Races.name("client")
        })
      )

    %{organisation: organisation, workspace: workspace} = owner

    {1, _} =
      Repo.update_all(
        from(t in ApiaryPro.Tenants.Tenant, where: t.organisation_id == ^organisation.id),
        set: [kind: :organisation, operator_id: operator.id, operator_since: DateTime.utc_now()]
      )

    client = ApiaryPro.Tenants.put(Repo.get!(Organisation, organisation.id))
    {:ok, _features} = ApiaryPro.Grants.written_out(client, {:client, operator})

    if ApiaryPro.Flags.operator_infrastructure?() do
      {1, _} =
        Repo.update_all(
          from(m in Membership, where: m.id == ^owner.membership.id),
          set: [level: :admin]
        )
    end

    ApiaryPro.OperatorsFixtures.operate_fixture(workspace, operator)

    %{
      organisation: client,
      workspace: workspace,
      scope: OrganisationsFixtures.workspace_scope(operator_scope.user, workspace),
      owner: %{owner | scope: OrganisationsFixtures.workspace_scope(owner.user, workspace)}
    }
  end
end
