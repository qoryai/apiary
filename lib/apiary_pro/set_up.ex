defmodule ApiaryPro.SetUp do
  @moduledoc """
  SetUp is what the edition changes in the steps list of the set-up's pages
  (`c:Apiary.Edition.set_up_steps/2`, `steps/2`).

  Signed out, the core lists Invitation, Your account and the steps of its flow in one
  list: Name, Work sources, Destinations, Model, Harness, Machines and Test run (7 steps
  with every feature, Model only with `secrets`, Name alone without `factory`). The pages
  that read the list signed out are the sign-up, the sign-up with `?invitation=`, an
  invitation's page and the instance's set-up link. They are the account's step. The flow
  is set up inside the workspace, which the person opens from the organisation's overview,
  `/:org`, so the list on those pages stops at the account's steps:

  - **A client's invitation**, the sign-up with `?invitation=` and `/invitations/:token`,
    while the client has no workspace in use: Invitation alone. Your account is left out,
    and Invitation is current where Your account was.
  - **Every other page signed out** keeps the core's list without the steps of the flow:
    Your account, Invitation before it on an invitation's page, and on the set-up link's
    page the instance's steps (`group: :connect`) too.

  A signed-in person's list is the core's. The workspace's pages need the flow in it, to
  open a step and to find the next one, and the instance admin's set-up pages need it to
  find the step that follows the connections.
  """

  alias Apiary.{Organisations, WorkspaceSetup}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Organisation
  alias ApiaryPro.Tenants

  @doc """
  steps/2 is the list of the set-up's steps for `scope`, given the core's (`steps`): for no
  scope, signed out, the core's list without the steps of its flow, and Invitation alone
  on a client's invitation; `steps` otherwise.
  """
  @spec steps(Scope.t() | nil, [Apiary.Edition.set_up_step()]) :: [Apiary.Edition.set_up_step()]
  def steps(nil, steps), do: steps |> account_steps() |> client_invitation_steps()

  def steps(_scope, steps), do: steps

  # The core's list without the steps of its flow, which are set up in the workspace.
  defp account_steps(steps), do: Enum.reject(steps, &(&1.id in WorkspaceSetup.flow()))

  # A client's invitation, read signed out, while the client has no workspace in use: the
  # person sees Invitation alone. Once it has one, a person who joins sets up no workspace,
  # and the list stays as `account_steps/1` left it. The core lists the invitation's
  # organisation's id on the Invitation step, which no page shows.
  defp client_invitation_steps(steps) do
    with %{organisation_id: id} when is_binary(id) <- Enum.find(steps, &(&1.id == :invitation)),
         client = %Organisation{id: id},
         true <- Tenants.client?(client),
         false <- Organisations.has_workspace?(client) do
      account_current? = Enum.any?(steps, &(&1.id == :account and &1.state == :current))

      for %{id: :invitation} = step <- steps,
          do:
            step
            |> Map.delete(:organisation_id)
            |> then(&if(account_current?, do: %{&1 | state: :current}, else: &1))
    else
      _not_a_client_invitation -> steps
    end
  end
end
