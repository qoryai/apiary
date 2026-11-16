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
  `/:org`, so every page signed out keeps the core's list without the steps of the flow:
  Your account, Invitation before it on an invitation's page, and on the set-up link's
  page the instance's steps (`group: :connect`) too.

  A signed-in person's list is the core's. The workspace's pages need the flow in it, to
  open a step and to find the next one, and the instance admin's set-up pages need it to
  find the step that follows the connections.
  """

  alias Apiary.WorkspaceSetup
  alias Apiary.Accounts.Scope

  @doc """
  steps/2 is the list of the set-up's steps for `scope`, given the core's (`steps`): for no
  scope, signed out, the core's list without the steps of its flow; `steps` otherwise.
  """
  @spec steps(Scope.t() | nil, [Apiary.Edition.set_up_step()]) :: [Apiary.Edition.set_up_step()]
  def steps(nil, steps), do: account_steps(steps)

  def steps(_scope, steps), do: steps

  # The core's list without the steps of its flow, which are set up in the workspace.
  defp account_steps(steps), do: Enum.reject(steps, &(&1.id in WorkspaceSetup.flow()))
end
