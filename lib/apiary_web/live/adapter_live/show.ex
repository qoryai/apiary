defmodule ApiaryWeb.AdapterLive.Show do
  # An integration's page in Organisation settings › Integrations: its repositories and
  # projects, and assigning them to workspaces (`:collections`, `:assign`). Its settings
  # and its access key are the instance admins' (`ApiaryWeb.InstanceLive.Integration`,
  # `ApiaryWeb.AdapterLive.AccessKey`).
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
