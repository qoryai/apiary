defmodule ApiaryWeb.AdapterLive.AccessKey do
  # An adapter's Access key tab in Instance settings › Adapters, at `…/keys`, for the
  # instance's admins: its keys and enrolment codes, with the acts on them that a node's
  # Access key tab has (`ApiaryWeb.NodeLive.AccessKey`). A page of the Instance level, with
  # no organisation: its gate asks the instance whether the feature is on (`use
  # ApiaryWeb.Features, instance: :factory`), and the keys, the codes and their topic are
  # an instance admin's (`Apiary.AccessKeys.subscribe/2`).
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
