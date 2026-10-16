defmodule ApiaryWeb.AdapterLive.Show do
  # An integration's page in Organisation settings › Integrations (`:collections`): its
  # Repositories section, the collections the organisation's connection to the adapter
  # reaches, each with its workspace, assigned to a workspace from a menu on the
  # selection. Its settings and its keys are the instance admins'
  # (`ApiaryWeb.InstanceLive.Adapter`, `ApiaryWeb.AdapterLive.AccessKey`).
  #
  # It answers as a path that does not exist until its page is built here. The feature is
  # hidden from the documentation, so the module is too.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory

  @impl true
  def mount(_params, _session, _socket), do: raise(ApiaryWeb.NotFound)

  @impl true
  def render(assigns), do: ~H""
end
