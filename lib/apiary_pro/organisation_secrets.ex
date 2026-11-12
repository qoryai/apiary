defmodule ApiaryPro.OrganisationSecrets do
  @moduledoc """
  The organisation's secrets beside its workspaces' secrets: who may read, change and
  link them, and whether they may be sealed, the edition's answer to the core
  (`c:Apiary.Edition.organisation_secrets/2` in `ApiaryPro.Edition`). The core keeps the
  secrets, their values and their audit entries (`Apiary.Secrets`); nothing of them is
  kept here.

  - **Read, write and use**, checked with the scope's person: `Apiary.Access.check/3`
    checks the action on the organisation, and nothing else is checked here.
    `ApiaryPro.Access` returns not found where the organisation does not have the feature
    `organisation_variables` (`ApiaryPro.Features.of/2`), the feature of its variables
    too, which needs `security` and `secrets`. Then `organisation_secret.read` is for the
    owners, the admins and the readers, as the organisation's variables;
    `organisation_secret.write` and `organisation_secret.use` are for the owners and the
    admins.
    A suspended organisation's are read only.
  - **Seal**, asked with no scope: the instance alone answers
    (`Apiary.Features.on?/1`), as it does for the organisation's variables
    (`ApiaryPro.OrganisationVariables.for_above/1`). An organisation that does not have
    the feature still has its secrets sealed; where the instance does not have it, no
    organisation's secret is sealed.

  Nothing is inherited and nothing is locked: a workspace's secret with the same name is
  a different secret.
  """

  alias Apiary.{Access, Features}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Organisation

  @feature :organisation_variables

  @actions %{
    read: :"organisation_secret.read",
    write: :"organisation_secret.write",
    use: :"organisation_secret.use"
  }

  @doc """
  may/2 is the answer to `c:Apiary.Edition.organisation_secrets/2`: `:ok`, or
  `{:error, reason}`, for `:read`, `:write` or `:use` by the scope's person in the
  scope's organisation, as the scope carries it, which the core has read again; for
  `:seal`, asked with a nil scope, whether the instance has the feature.
  """
  @spec may(Scope.t() | nil, :read | :write | :use | :seal) ::
          :ok | {:error, Access.reason()}
  def may(nil, :seal), do: if(Features.on?(@feature), do: :ok, else: {:error, :not_found})

  def may(%Scope{organisation: %Organisation{} = organisation} = scope, verb)
      when is_map_key(@actions, verb),
      do: Access.check(scope, Map.fetch!(@actions, verb), organisation)

  def may(_scope, _verb), do: {:error, :not_found}

  @doc """
  shown?/1 says whether the scope's person reads the organisation's secrets, as the scope
  carries it (`may/2`, `:read`): the organisation's secrets and the Variables tab of the
  settings' Secrets and variables section are there only then. The section and its palette
  entry are also there, as a page of the keys of the model providers alone, for whoever
  changes them under `provider.write` where the features `factory` and `secrets` are shown.
  """
  @spec shown?(Scope.t() | nil) :: boolean
  def shown?(scope), do: may(scope, :read) == :ok
end
