defmodule ApiaryPro.Races do
  @moduledoc """
  The edition's helpers for the tests that race two changes on separate connections,
  beside the core's (`Apiary.Races`), whose setup and clean-up they share: what they make is
  remembered for `on_exit` to delete, and named as a race's.
  """

  alias Apiary.{OrganisationsFixtures, Races, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Organisation

  @doc """
  An organisation whose first workspace the scope's operator operates, made as
  `ApiaryPro.OperatorsFixtures.operated_fixture/2` makes one: its first person signs up
  with a race's address and creates it, with its first workspace Main, under a race's
  name, and the operator operates Main (`ApiaryPro.OperatorsFixtures.operate_fixture/2`).
  The organisation, its workspace, `scope`, the operator's person's scope in it, and
  `owner`, the first person's fixture, `scope` theirs in Main.
  """
  @spec operated(Scope.t()) :: map
  def operated(%Scope{} = operator_scope) do
    operator = operator_scope.organisation

    owner =
      Races.created(
        OrganisationsFixtures.sign_up_fixture(%{
          email: Races.email(),
          organisation_name: Races.name("operated")
        })
      )

    %{organisation: organisation, workspace: workspace} = owner
    ApiaryPro.OperatorsFixtures.operate_fixture(workspace, operator)

    %{
      organisation: ApiaryPro.Tenants.put(Repo.get!(Organisation, organisation.id)),
      workspace: workspace,
      scope: OrganisationsFixtures.workspace_scope(operator_scope.user, workspace),
      owner: %{owner | scope: OrganisationsFixtures.workspace_scope(owner.user, workspace)}
    }
  end
end
