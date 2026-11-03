defmodule Apiary.WorkItems.Finished do
  # Finished holds the one check for a finished work item whose ticket has not reopened.
  #
  # A work item is **finished** when its last stage finished: closed by the instance, with
  # `stage_state` `:done` (`Apiary.Stages`). A work item a person closed is not finished.
  #
  # A ticket is **reopened** for a finished work item when the item's `state` is `:open`
  # and `last_closed_at` is after the work item's `closed_at`. Qory Apiary wrote both
  # times, so a source's clock plays no part.
  #
  # A finished work item whose ticket has not reopened stays in the Backlog's Taken in,
  # with no Take in again (`Apiary.Sources.Backlog`, `Apiary.WorkItems.Moves`). The module
  # reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.Repo
  alias Apiary.Sources.Item
  alias Apiary.WorkItems.WorkItem

  # finished/2 is the check as a query expression, over a work item and its ticket's item:
  # true or false, and false with no work item, as a left join gives. Every value in it
  # is a column, so a query may select it and group by it.
  @doc false
  defmacro finished(work_item, item) do
    quote do
      fragment(
        "COALESCE(? = 'closed' AND ? = 'done' AND ? IS NULL AND NOT COALESCE(? = 'open' AND ? > ?, false), false)",
        unquote(work_item).state,
        unquote(work_item).stage_state,
        unquote(work_item).closed_by_id,
        unquote(item).state,
        unquote(item).last_closed_at,
        unquote(work_item).closed_at
      )
    end
  end

  # finished?/2 is the same check on one work item and its ticket's item, read again from
  # the database.
  @doc false
  @spec finished?(WorkItem.t(), Item.t()) :: boolean
  def finished?(%WorkItem{id: id}, %Item{id: item_id}) do
    Repo.exists?(
      from w in WorkItem,
        join: i in Item,
        on: i.id == ^item_id,
        where: w.id == ^id and finished(w, i)
    )
  end
end
