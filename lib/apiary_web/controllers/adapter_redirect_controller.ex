defmodule ApiaryWeb.AdapterRedirectController do
  # A link that names an integration by its adapter's public id alone, as an adapter gives
  # one (`GET /integrations/:adapter_id`), sent on to the integration's page in its
  # organisation's settings, `/:org/settings/integrations/:adapter_id`. Not a page: a
  # redirect.
  #
  # Behind sign-in: an anonymous visitor is sent to log in, and comes back here. A signed-in
  # person is sent on where they reach the adapter's organisation and may read its
  # integrations there (`adapter.read`); anyone else is answered as a path that does not
  # exist, the same for an adapter that is not there, deleted or of an organisation they
  # do not reach, so the link does not tell whether it exists.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :factory

  alias Apiary.{Access, Adapters, Organisations}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation

  def show(conn, %{"adapter_id" => adapter_id}) do
    with %Organisation{slug: slug} <- Adapters.organisation_of(adapter_id),
         {:ok, scope} <- Organisations.resolve_scope(conn.assigns.current_scope, slug),
         true <- Access.can?(scope, :"adapter.read", scope.organisation),
         %Node{} = adapter <- Adapters.get_adapter(scope, adapter_id) do
      redirect(conn, to: ~p"/#{scope.organisation}/settings/integrations/#{adapter}")
    else
      _not_found -> raise ApiaryWeb.NotFound
    end
  end
end
