defmodule ApiaryWeb.BacklogLive.Index do
  # A workspace's Backlog: the tickets of the repositories and projects assigned to it, and
  # the Take in dialog over it (`:index`, `:take_in`).
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
