defmodule ApiaryWeb.TemplateReads do
  # The reads behind New workspace's template cards (`ApiaryWeb.WorkspaceSetupLive`,
  # `ApiaryWeb.SetUpComponents.template_cards/1`): the state of each place in the socket's
  # assigns, and the reads of the places' templates (`Apiary.Stacks.Sources.templates/2`)
  # that run outside the page's process.
  #
  # The assigns: `template_places`, the places to read (`Apiary.Stacks.Sources.listed/1`
  # without the Qory one); `template_reads`, each place's state by its prefix, `:waiting`,
  # `:reading`, `{:ok, templates}` or `{:error, reason}`; `template_limit`, nil or the
  # place whose read `{:error, {:limited, seconds}}` stopped, with `seconds`;
  # `template_running`, how many reads are under way; `template_queue`, the prefixes still
  # to start.
  #
  # `start/1` starts reads when the socket is connected, at most 4 at a time, one
  # `start_async/3` for each place. A result reaches the page when its read finishes
  # (`done/3`). A read that returns `{:limited, seconds}` goes back to the front of the
  # queue, and no read starts until `resume/1`, which `done/3` schedules `seconds` later
  # as the message `:templates_resume`. Reads are not cached.
  @moduledoc false

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [connected?: 1, start_async: 3]

  alias Apiary.Stacks.Sources

  @parallel 4

  @doc false
  # init/2 sets the assigns for `places`, with no read started.
  def init(socket, places) do
    assign(socket,
      template_places: places,
      template_reads: Map.new(places, &{&1.prefix, :waiting}),
      template_queue: Enum.map(places, & &1.prefix),
      template_running: 0,
      template_limit: nil,
      template_started: false
    )
  end

  @doc false
  # start/1 starts the first reads once the socket is connected, and only once.
  def start(%{assigns: %{template_started: false}} = socket) do
    if connected?(socket), do: socket |> assign(template_started: true) |> fill(), else: socket
  end

  def start(socket), do: socket

  @doc false
  # done/3 takes the result of the read of the place `prefix`: `{:ok, {:ok, templates}}`
  # or `{:ok, {:error, reason}}` from `Apiary.Stacks.Sources.templates/2`, or `{:exit,
  # reason}`.
  def done(socket, prefix, result) do
    socket = assign(socket, template_running: socket.assigns.template_running - 1)

    case result do
      {:ok, {:ok, templates}} ->
        socket |> put(prefix, {:ok, templates}) |> fill()

      {:ok, {:error, {:limited, seconds}}} ->
        limited(socket, prefix, seconds)

      {:ok, {:error, reason}} ->
        socket |> put(prefix, {:error, reason}) |> fill()

      {:exit, _reason} ->
        socket |> put(prefix, {:error, :exited}) |> fill()
    end
  end

  @doc false
  # resume/1 reads the places left, once the window of the person's reads is over.
  def resume(socket), do: socket |> assign(template_limit: nil) |> fill()

  # The place's state, `state`.
  defp put(socket, prefix, state),
    do: assign(socket, template_reads: Map.put(socket.assigns.template_reads, prefix, state))

  # A read the person's limit stopped: its place waits again at the front of the queue, and
  # the reads resume after `seconds`. A second limited read of the same window keeps the
  # first one's timer.
  defp limited(socket, prefix, seconds) do
    %{template_limit: limit, template_queue: queue} = socket.assigns
    place = Enum.find(socket.assigns.template_places, &(&1.prefix == prefix))

    if is_nil(limit), do: Process.send_after(self(), :templates_resume, seconds * 1000)

    socket
    |> put(prefix, :waiting)
    |> assign(
      template_queue: [prefix | queue],
      template_limit: limit || %{seconds: seconds, place: place}
    )
  end

  # Starts reads while fewer than 4 run, the queue has a place and no limit stops them.
  defp fill(%{assigns: %{template_limit: nil, template_queue: [prefix | queue]}} = socket)
       when socket.assigns.template_running < @parallel do
    scope = socket.assigns.current_scope
    place = Enum.find(socket.assigns.template_places, &(&1.prefix == prefix))

    socket
    |> assign(template_queue: queue, template_running: socket.assigns.template_running + 1)
    |> put(prefix, :reading)
    |> start_async({:templates, prefix}, fn -> Sources.templates(scope, place.source) end)
    |> fill()
  end

  defp fill(socket), do: socket
end
