defmodule Apiary.WorkItems do
  # WorkItems holds a workspace's work items (`Apiary.WorkItems.WorkItem`): what the
  # sidebar counts, for now; taking in, undoing, closing and the comments come with their
  # pages.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  alias Apiary.Accounts.Scope
  alias Apiary.WorkItems.WorkItem

  @doc false
  # How many of the scope's workspace's work items wait on the scope's person: the count
  # beside the sidebar's Work items. Nothing waits on a person before the stages that ask
  # one something, so it is 0.
  @spec count_waiting_on(Scope.t()) :: non_neg_integer
  def count_waiting_on(%Scope{}), do: 0

  @doc false
  # stable_url/1 is the address of `work_item` that Qory gives another system: the
  # instance's public URL, then `/work-items/` and the work item's public id. It names no
  # organisation and no workspace, so it stays the same when the work item moves to
  # another workspace. No route of the instance serves it yet.
  @spec stable_url(WorkItem.t()) :: String.t()
  def stable_url(%WorkItem{public_id: public_id}) when is_binary(public_id),
    do: ApiaryWeb.Endpoint.url() <> "/work-items/" <> public_id
end
