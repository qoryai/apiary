defmodule ApiaryWeb.ProductName do
  @moduledoc """
  The `on_mount` hook every LiveView runs (`use ApiaryWeb, :live_view`): once the page is
  connected, it reads the product's name on the instance for the page's process
  (`Apiary.ProductName.hold/0`), so the page's updates show it without reading it again.
  The first render, before the page connects, reads it as any request does.
  """

  @doc "Holds the product's name for a connected page's process."
  def on_mount(:default, _params, _session, socket) do
    if Phoenix.LiveView.connected?(socket), do: Apiary.ProductName.hold()
    {:cont, socket}
  end
end
