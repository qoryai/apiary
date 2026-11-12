defmodule ApiaryPro.EditionKit do
  @moduledoc """
  What the core's test support asks of the edition (`Apiary.EditionKit`): the edition's rows
  of the access test (`ApiaryPro.AccessRows`); the instance organisation hidden by taking
  its tenant's flag off (`ApiaryPro.Tenants.Tenant`), as on an instance nobody has signed
  up to yet; and the account suspensions and the suspenders of organisations forgotten
  before a test deletes the accounts they name.
  """

  @behaviour Apiary.EditionKit

  import Ecto.Query

  alias Apiary.Repo
  alias ApiaryPro.Suspensions.AccountSuspension
  alias ApiaryPro.Tenants.Tenant

  @impl true
  def access_rows, do: [ApiaryPro.AccessRows]

  @impl true
  def hide_instance_organisation(id) do
    {1, _} =
      Repo.update_all(from(t in Tenant, where: t.organisation_id == ^id),
        set: [instance_organisation: false]
      )

    :ok
  end

  @impl true
  def forget_accounts(user_ids) do
    Repo.delete_all(
      from s in AccountSuspension,
        where: s.user_id in ^user_ids or s.suspended_by_id in ^user_ids
    )

    Repo.update_all(from(t in Tenant, where: t.suspended_by_id in ^user_ids),
      set: [suspended_by_id: nil]
    )

    :ok
  end

  @impl true
  def show_instance_organisation(id) do
    {1, _} =
      Repo.update_all(from(t in Tenant, where: t.organisation_id == ^id),
        set: [instance_organisation: true]
      )

    :ok
  end
end
