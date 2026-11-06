defmodule ApiaryWeb.WorkItemRedirectController do
  # A work item's permanent address (`GET /work-items/:work_item_id`, `wi_…`), which
  # `Apiary.WorkItems.stable_url/1` returns for another system. Not a page.
  #
  # To a signed-in person who may open the work item (`Apiary.WorkItems.locate/2`), it
  # redirects to the work item's page at the organisation's and the workspace's addresses
  # when the request comes, so it still leads there after a rename or a move. The query
  # is dropped: the page reads none from this address. To anyone else, and for an unknown
  # or malformed id, the response is the `404` of a path that does not exist, so it does
  # not show whether the work item exists. Behind sign-in: an anonymous visitor is
  # sent to log in first, whatever the id, and comes back here.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :factory

  alias Apiary.WorkItems

  def show(conn, %{"work_item_id" => id}) do
    case WorkItems.locate(conn.assigns.current_scope, id) do
      {:ok, work_item, scope} ->
        redirect(conn,
          to: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{work_item.number}"
        )

      :error ->
        raise ApiaryWeb.NotFound
    end
  end
end
