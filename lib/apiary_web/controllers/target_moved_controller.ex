defmodule ApiaryWeb.TargetMovedController do
  @moduledoc """
  A target's policy had a page of its own, `/:org/:workspace/policy/targets/:target_id/…`,
  by the target row's id; it is the Policy tab of the target's page now
  (`ApiaryWeb.TargetLive.Show`, `…/targets/:system/*path/-/policy/…`). This sends such a
  path on to the tab, with whatever followed the id (`history`, `document`,
  `versions/:n`, `versions/:n/export`) and the query, so a bookmark or a link in an old
  message still lands. A target the reader may not read, or that is not in the
  workspace, is not found, as the page would say.
  """
  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :security

  alias Apiary.{Access, Targets}
  alias ApiaryWeb.TargetComponents

  def show(conn, %{"target_id" => id} = params) do
    scope = conn.assigns.current_scope

    with true <- Access.can?(scope, :"security_policy.read", scope.workspace),
         %{} = target <- Targets.get_by_id(scope, id) do
      rest = List.wrap(params["rest"])
      query = if conn.query_string == "", do: "", else: "?" <> conn.query_string

      redirect(conn,
        to:
          TargetComponents.target_path(scope, target.system, target.path, ["policy" | rest]) <>
            query
      )
    else
      _not_found -> raise Ecto.NoResultsError, queryable: Apiary.Runs.Target
    end
  end
end
