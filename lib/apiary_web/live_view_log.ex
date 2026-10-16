defmodule ApiaryWeb.LiveViewLog do
  @moduledoc """
  LiveViewLog writes the lines a page logs as it mounts, as it handles the parameters of
  its URL and as it handles an event (`MOUNT`, `HANDLE PARAMS` and `HANDLE EVENT`, an
  event of a component's included), in place of `Phoenix.LiveView.Logger`'s, whose
  handlers of those events it detaches at boot (`attach/0`). The lines are the same, at the
  same level (debug, unless a page sets another), but for the values: every value of the
  parameters, and of the session a page mounts with, is written as `[FILTERED]`, and the
  keys, the maps and lists they are nested in, the page's module, the component's and the
  event's name are kept.

  The session holds the token a person is signed in with, and the socket's id, which holds
  that token in base64; the parameters hold what a person typed. `:filter_parameters`
  masks a parameter by its name alone, and `Phoenix.LiveView.Logger` writes the session as
  it is. The `Replied in` lines, and their timing, are still `Phoenix.LiveView.Logger`'s.
  """

  require Logger

  @filtered "[FILTERED]"

  # The events whose lines are written here.
  @events [
    [:phoenix, :live_view, :mount, :start],
    [:phoenix, :live_view, :handle_params, :start],
    [:phoenix, :live_view, :handle_event, :start],
    [:phoenix, :live_component, :handle_event, :start]
  ]

  @handler_id "apiary-live-view-log"

  @doc """
  attach/0 detaches `Phoenix.LiveView.Logger`'s handlers of the mount, the parameters and
  the events, and attaches this module's, once: attaching it again changes nothing.
  """
  @spec attach() :: :ok
  def attach do
    for event <- @events,
        %{id: id, event_name: ^event} = handler <- :telemetry.list_handlers(event),
        live_view_logger?(handler) do
      :telemetry.detach(id)
    end

    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  defp live_view_logger?(%{id: {Phoenix.LiveView.Logger, _event}}), do: true

  defp live_view_logger?(%{function: function}) when is_function(function),
    do: Function.info(function, :module) == {:module, Phoenix.LiveView.Logger}

  defp live_view_logger?(_handler), do: false

  @doc false
  # Never raises: a handler that raises is detached, and its lines would stop.
  def handle_event(event, _measurements, metadata, _config) do
    with %{socket: socket} <- metadata,
         level when level not in [nil, false] <- level(event, socket) do
      Logger.log(level, fn -> line(event, metadata) end)
    end

    :ok
  catch
    _kind, _reason -> :ok
  end

  # The page's level, as LiveView reads it; nil for a mount and for the parameters before
  # the page is connected, which LiveView does not log.
  defp level([_phoenix, :live_view, callback, _start], socket)
       when callback in [:mount, :handle_params] do
    if Phoenix.LiveView.connected?(socket), do: log_level(socket)
  end

  defp level(_event, socket), do: log_level(socket)

  defp log_level(socket), do: Map.get(socket.view.__live__(), :log, :debug)

  # The line, as LiveView writes it, with each value `[FILTERED]`. Should building it fail,
  # the line is its title and `[FILTERED]`.
  defp line(event, metadata) do
    {title, fields} = parts(event, metadata)
    [title | Enum.map(fields, fn {name, value} -> ["\n  ", name, ": ", value] end)]
  catch
    _kind, _reason -> [title(event), " ", @filtered]
  end

  defp parts([_phoenix, :live_view, :mount, _start], metadata) do
    {["MOUNT ", inspect(metadata.socket.view)],
     [{"Parameters", masked(metadata.params)}, {"Session", masked(metadata.session)}]}
  end

  defp parts([_phoenix, :live_view, :handle_params, _start], metadata) do
    {["HANDLE PARAMS in ", inspect(metadata.socket.view)],
     [{"Parameters", masked(metadata.params)}]}
  end

  defp parts([_phoenix, :live_view, :handle_event, _start], metadata) do
    {["HANDLE EVENT ", inspect(metadata.event), " in ", inspect(metadata.socket.view)],
     [{"Parameters", masked(metadata.params)}]}
  end

  defp parts([_phoenix, :live_component, :handle_event, _start], metadata) do
    {["HANDLE EVENT ", inspect(metadata.event), " in ", inspect(metadata.socket.view)],
     [{"Component", inspect(metadata.component)}, {"Parameters", masked(metadata.params)}]}
  end

  defp title([_phoenix, :live_view, :mount, _start]), do: "MOUNT"
  defp title([_phoenix, :live_view, :handle_params, _start]), do: "HANDLE PARAMS"
  defp title(_event), do: "HANDLE EVENT"

  defp masked(term), do: term |> mask() |> inspect()

  @doc false
  # A map with its keys kept and each value masked, a list element by element, and any
  # other term, a struct among them, `[FILTERED]`.
  @spec mask(term) :: term
  def mask(%{__struct__: _}), do: @filtered
  def mask(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, mask(value)} end)
  def mask(list) when is_list(list), do: mask_list(list)
  def mask(_value), do: @filtered

  # Element by element, and an improper list's tail `[FILTERED]`.
  defp mask_list([head | tail]), do: [mask(head) | mask_list(tail)]
  defp mask_list([]), do: []
  defp mask_list(_tail), do: @filtered
end
