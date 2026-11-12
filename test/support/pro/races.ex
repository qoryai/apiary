defmodule ApiaryPro.Races do
  @moduledoc """
  The edition's helpers for the tests that race two changes on separate connections,
  beside the core's (`Apiary.Races`), whose setup and clean-up they share: what they make is
  remembered for `on_exit` to delete, and named as a race's.
  """

  import ExUnit.Assertions

  alias Apiary.{OrganisationsFixtures, Races}
  alias Apiary.Accounts.Scope
  alias ApiaryPro.Operators

  @doc """
  A client of the scope's operator, created by the scope's person, with its first owner,
  who signed up with the operator's invitation, and its first workspace Main, which the
  client starts without (`ApiaryPro.OperatorsFixtures.first_workspace_fixture/3`): the
  client, its workspace, `scope`, the operator's person's scope in it, and `owner`, the
  owner's fixture, `scope` theirs in Main. Its name and its owner's address are a race's.
  """
  @spec client(Scope.t()) :: map
  def client(%Scope{} = operator_scope) do
    parent = self()
    ref = make_ref()
    email = Races.email()

    {:ok, %{organisation: client, sent: {:ok, _invitation}}} =
      Operators.create_client(
        operator_scope,
        %{"name" => Races.name("client"), "email" => email},
        fn token ->
          send(parent, {ref, token})
          "http://localhost/invitations/#{token}"
        end
      )

    token =
      receive do
        {^ref, token} -> token
      after
        0 -> flunk("create_client did not call the URL function")
      end

    owner =
      Races.created(
        OrganisationsFixtures.sign_up_fixture(%{email: email, invitation_token: token})
      )

    workspace = ApiaryPro.OperatorsFixtures.first_workspace_fixture(operator_scope, client, owner)

    %{
      organisation: client,
      workspace: workspace,
      scope: OrganisationsFixtures.workspace_scope(operator_scope.user, workspace),
      owner: %{owner | scope: OrganisationsFixtures.workspace_scope(owner.user, workspace)}
    }
  end
end
