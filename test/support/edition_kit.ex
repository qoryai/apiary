defmodule Apiary.EditionKit do
  @moduledoc """
  EditionKit is what the core's tests ask of the edition the suite runs with, where the
  edition changes what a core test sets up or asserts. The configuration names the
  edition's kit, a module of this behaviour among the edition's test support:

      config :apiary, Apiary.EditionKit, module: MyEdition.EditionKit

  Without one the core's answers stand (`Apiary.EditionKit.Core`): no rows of the access
  test beyond the core's, and the instance's organisation hidden by its deletion mark.
  """

  @doc """
  The edition's modules of rows of the access test (`Apiary.AccessCase`), whose rows of
  the core's actions for the core's actors the core's access test asks too.
  """
  @callback access_rows() :: [module]

  @doc """
  Hides the instance's organisation `id` (`c:Apiary.Edition.instance_organisation_id/0`)
  from the edition, as on an instance nobody has signed up to yet: inside a test's
  sandbox, or committed by a test outside it, which shows it again before it ends.
  """
  @callback hide_instance_organisation(Ecto.UUID.t()) :: :ok

  @doc "Shows again the instance's organisation `hide_instance_organisation/1` hid."
  @callback show_instance_organisation(Ecto.UUID.t()) :: :ok

  @doc """
  Deletes, or empties, what the edition keeps that names the accounts `user_ids` by a key
  that takes no action on their deletion, before a test that made them outside the
  sandbox deletes them (`Apiary.Races`). The product never deletes an account's row, only
  a test does, and one statement that deletes an account and another that names it may
  meet such a key before the other's rows are gone.
  """
  @callback forget_accounts([Ecto.UUID.t()]) :: :ok

  @doc "module/0 is the edition's kit, or the core's."
  @spec module() :: module
  def module,
    do: Application.get_env(:apiary, __MODULE__, [])[:module] || Apiary.EditionKit.Core

  @doc "access_rows/0 is the edition's rows of the access test (`c:access_rows/0`)."
  @spec access_rows() :: [module]
  def access_rows, do: module().access_rows()

  @doc """
  hide_instance_organisation/0 hides the instance's organisation
  (`c:hide_instance_organisation/1`) and returns its id, for
  `show_instance_organisation/1`; `c:Apiary.Edition.instance_organisation_id/0` answers
  nil after.
  """
  @spec hide_instance_organisation() :: Ecto.UUID.t()
  def hide_instance_organisation do
    id = Apiary.Edition.instance_organisation_id()
    :ok = module().hide_instance_organisation(id)
    nil = Apiary.Edition.instance_organisation_id()
    id
  end

  @doc "show_instance_organisation/1 shows the instance's organisation `id` again."
  @spec show_instance_organisation(Ecto.UUID.t()) :: :ok
  def show_instance_organisation(id), do: module().show_instance_organisation(id)

  @doc "forget_accounts/1 is the edition's `c:forget_accounts/1`, before accounts are deleted."
  @spec forget_accounts([Ecto.UUID.t()]) :: :ok
  def forget_accounts(user_ids), do: module().forget_accounts(user_ids)
end
