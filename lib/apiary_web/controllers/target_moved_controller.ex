defmodule ApiaryWeb.TargetMovedController do
  @moduledoc """
  A target's policy had a separate page, `/:org/:workspace/policy/targets/:target_id/…`,
  by the target row's id; it is the Policy tab of the target's page now
  (`ApiaryWeb.TargetLive.Show`, `…/targets/tg_…/policy/…`, by the target's public id).
  This sends such a path on to the tab, with what followed the id where it is one of the
  tab's paths (`history`, `document`, `versions/:n`, `versions/:n/export`, `n` a version
  number), else to the bare tab, and with the query, so a bookmark or a link in an old
  message still lands. Nothing else of the old path is carried. A target the reader may
  not read, or that is not in the workspace, is not found, as the page would say.
  """
  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :security

  alias Apiary.{Access, Targets}
  alias ApiaryWeb.TargetComponents

  def show(conn, %{"target_id" => id} = params) do
    scope = conn.assigns.current_scope

    with true <- Access.can?(scope, :"security_policy.read", scope.workspace),
         %{} = target <- Targets.get_by_id(scope, id) do
      rest = tab(List.wrap(params["rest"]))
      query = if conn.query_string == "", do: "", else: "?" <> conn.query_string

      redirect(conn, to: TargetComponents.target_path(scope, target, ["policy" | rest]) <> query)
    else
      _not_found -> raise Ecto.NoResultsError, queryable: Apiary.Runs.Target
    end
  end

  # What followed the id, where it is a path of the Policy tab; nothing otherwise.
  defp tab(["history"]), do: ["history"]
  defp tab(["document"]), do: ["document"]
  defp tab(["versions", n] = rest), do: if(version?(n), do: rest, else: [])
  defp tab(["versions", n, "export"] = rest), do: if(version?(n), do: rest, else: [])
  defp tab(_other), do: []

  # A version number: digits, the first not 0, as many as a version can have.
  defp version?(n), do: Regex.match?(~r/\A[1-9][0-9]{0,17}\z/, n)
end
