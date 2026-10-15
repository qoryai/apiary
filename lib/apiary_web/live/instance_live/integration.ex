defmodule ApiaryWeb.InstanceLive.Integration do
  # An integration's Settings tab in Instance settings › Integrations, for the instance's
  # admins: renaming it and removing it (`:settings`, `:rename`, `:remove`). A page of the
  # Instance level, with no organisation: its gate asks the instance whether the feature
  # is on (`use ApiaryWeb.Features, instance: :factory`), and anyone but an instance admin
  # is answered as a path that does not exist, as on the Instance's other pages.
  #
  # It answers as a path that does not exist until its page is built here. The feature is
  # hidden from the documentation, so the module is too.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, instance: :factory

  @impl true
  def mount(_params, _session, _socket), do: raise(ApiaryWeb.NotFound)

  @impl true
  def render(assigns), do: ~H""
end
