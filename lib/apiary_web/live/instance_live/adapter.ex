defmodule ApiaryWeb.InstanceLive.Adapter do
  # Add for one entry of the catalogue in Instance settings › Adapters, for the instance's
  # admins, which makes the adapter and its first enrolment code (`:new`, by the entry),
  # held by this page's process alone; and an adapter's Settings tab, how often it pulls,
  # renaming it and removing it (`:settings`, `:rename`, `:remove`). Its Overview tab is
  # `ApiaryWeb.InstanceLive.Adapters`, its Access key tab `ApiaryWeb.AdapterLive.AccessKey`.
  # A page of the Instance level, with no organisation: its gate asks the instance whether
  # the feature is on (`use ApiaryWeb.Features, instance: :factory`), and anyone but an
  # instance admin is answered as a path that does not exist, as on the Instance's other
  # pages.
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
