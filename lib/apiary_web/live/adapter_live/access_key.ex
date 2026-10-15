defmodule ApiaryWeb.AdapterLive.AccessKey do
  # An integration's Access key tab: its adapter's keys and enrolment codes, with the acts
  # on them at the paths a node's Access key tab has (`ApiaryWeb.NodeLive.AccessKey`).
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
