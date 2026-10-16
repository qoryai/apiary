defmodule ApiaryWeb.AdapterLive.Index do
  # Organisation settings › Integrations: the list of the instance's adapters, as the
  # organisation's people read them, and Add an integration, where an owner or an admin
  # connects the organisation to one (`:index`, `:new`). Making one is the instance
  # admins' (`ApiaryWeb.InstanceLive.Adapter`).
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
