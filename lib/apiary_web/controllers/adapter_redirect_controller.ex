defmodule ApiaryWeb.AdapterRedirectController do
  # A link that names an integration by its adapter's public id alone, as an adapter gives
  # one (`GET /integrations/:adapter_id`). Not a page.
  #
  # An adapter is the instance's, with no organisation, so the link names no organisation
  # to lead to: it is answered as a path that does not exist, whoever asks and whatever
  # adapter it names, so the link does not tell whether one exists. Behind sign-in: an
  # anonymous visitor is sent to log in first.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :factory

  def show(_conn, %{"adapter_id" => _adapter_id}), do: raise(ApiaryWeb.NotFound)
end
