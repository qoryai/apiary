defmodule Apiary.EditionKit.Core do
  @moduledoc """
  The core's answers to what its tests ask of the edition (`Apiary.EditionKit`): no rows
  of the access test beyond the core's, the instance's organisation, the oldest one in
  use, hidden by marking it for deletion, and nothing kept of an account to forget.
  """

  @behaviour Apiary.EditionKit

  import Ecto.Query

  alias Apiary.Organisations.Organisation
  alias Apiary.Repo

  @impl true
  def access_rows, do: []

  # A mark far from its purge, which no sweep reaches while a test runs.
  @impl true
  def hide_instance_organisation(id) do
    now = DateTime.utc_now()

    {1, _} =
      Repo.update_all(from(o in Organisation, where: o.id == ^id),
        set: [
          deletion_marked_at: now,
          purge_after: DateTime.add(now, 3650, :day),
          purge_trigger: "grace_period"
        ]
      )

    :ok
  end

  @impl true
  def forget_accounts(_user_ids), do: :ok

  @impl true
  def show_instance_organisation(id) do
    {1, _} =
      Repo.update_all(from(o in Organisation, where: o.id == ^id),
        set: [deletion_marked_at: nil, purge_after: nil, purge_trigger: nil]
      )

    :ok
  end
end
