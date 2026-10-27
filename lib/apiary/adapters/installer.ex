defmodule Apiary.Adapters.Installer do
  # The installer of the adapters installed with Qory Apiary (`Apiary.Adapters.Installed`):
  # one process, a child of the application's supervisor once the database and the
  # migrations are up, that passes every 10 seconds, and at once when nudged on
  # `Apiary.Adapters.Installed.topic/0`. Off in test (`config :apiary,
  # Apiary.Adapters.Installer, enabled: false`), where the tests call `pass/0` themselves.
  #
  # **A pass** (`pass/0`), on an instance with the feature `factory`:
  #
  # - Until the instance is set up (`Apiary.Setup.set_up?/0`), it waits, and says so in
  #   the log once.
  # - For each name listed, in the setting's order: the adapter installed as it, found or
  #   made (`Apiary.Adapters.install/2`), then a code while it needs one
  #   (`Apiary.AccessKeys.issue_installed_code/2`): a code written to its file, in the
  #   folder of that adapter, which only that adapter mounts
  #   (`Apiary.Adapters.Installed.CodeFile`), while it has no key, the file deleted once it
  #   has one.
  # - For each adapter in use installed as a name no longer listed: its outstanding codes
  #   cancelled and its file deleted (`Apiary.AccessKeys.cancel_installed_codes/2`); the
  #   adapter, its keys and its connections stay.
  # - Then the instance's node pool and gateway (`Apiary.Nodes.Installed`), alike: each
  #   one declared, found or made (`Apiary.Nodes.Installed.install/2`), then a code while
  #   it needs one; each one in use whose kind is no longer declared, its codes cancelled
  #   and its file deleted. Their failures are named `{kind, name}`.
  #
  # All as the instance, by itself, in the instance's organisation
  # (`Apiary.Accounts.Scope.for_instance/2`). A name whose pass fails is said in the log
  # once until it passes again, and the others go on; the next pass tries again. A failure
  # is caught of every kind, a raise, an exit or a throw, around each name's pass and
  # around the whole pass, so that the process stays up and does not take the
  # application's supervisor past its limit of restarts.
  #
  # **Nothing secret in it.** The process keeps no code: a code is written to its file
  # inside the transaction that makes it, and its state holds whether it said it waits and
  # the names it said failed. No line it logs carries a code, nor the message or the reason
  # of a failure caught, only its kind: the exception's module, or `:exit` or `:throw`.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use GenServer

  require Logger

  import Ecto.Query, warn: false

  alias Apiary.{AccessKeys, Adapters, Features, Repo, Setup}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.Installed
  alias Apiary.Adapters.Installed.CodeFile
  alias Apiary.Nodes.Installed, as: NodesInstalled
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation

  @every :timer.seconds(10)

  @doc false
  # enabled?/0 is whether the application starts the installer: true unless configured off.
  @spec enabled?() :: boolean
  def enabled?, do: Keyword.get(Application.get_env(:apiary, __MODULE__, []), :enabled, true)

  @doc false
  @spec start_link(term) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init([]) do
    :ok = Phoenix.PubSub.subscribe(Apiary.PubSub, Installed.topic())
    send(self(), :pass)
    {:ok, %{waiting_said: false, failing: MapSet.new(), timer: nil}}
  end

  @impl true
  def handle_info(message, state) when message in [:pass, :nudge] do
    if state.timer, do: Process.cancel_timer(state.timer)
    state = said(safe_pass(), state)
    {:noreply, %{state | timer: Process.send_after(self(), :pass, @every)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A pass that fails, of any kind, the database out of reach among the causes, is said and
  # tried again at the next: the process stays up.
  defp safe_pass do
    pass()
  catch
    kind, reason -> {:failed, kind(kind, reason, __STACKTRACE__)}
  end

  @doc false
  # One pass, as the module says, in the caller's process: `:off` on an instance without
  # the feature, `:waiting` before the instance is set up, else `{:ok, failures}`, each
  # name whose pass failed with its reason.
  @spec pass() :: :off | :waiting | {:ok, [{String.t(), term}]}
  def pass do
    cond do
      not Features.on?(:factory) -> :off
      not Setup.set_up?() -> :waiting
      true -> pass(instance_scope())
    end
  end

  defp pass(scope) do
    names = Installed.names()

    failures =
      Enum.flat_map(names, fn name -> failed(name, install(scope, name)) end) ++
        Enum.flat_map(unlisted(names), fn adapter ->
          failed(adapter.installed_as, unlist(scope, adapter))
        end) ++
        Enum.flat_map([:pool, :gateway], fn kind ->
          case NodesInstalled.name(kind) do
            nil -> []
            name -> failed({kind, name}, install_node(scope, kind))
          end
        end) ++
        Enum.flat_map(NodesInstalled.undeclared(), fn node ->
          failed({node.kind, node.installed_as}, unlist(scope, node))
        end)

    {:ok, failures}
  end

  defp install_node(scope, kind) do
    guarded(fn ->
      with {:ok, node} <- NodesInstalled.install(scope, kind),
           {:ok, _state} <- AccessKeys.issue_installed_code(scope, node),
           do: :ok
    end)
  end

  defp instance_scope do
    Apiary.Edition.instance_organisation_id()
    |> then(&Repo.get!(Organisation, &1))
    |> Scope.for_instance()
  end

  defp install(scope, name) do
    guarded(fn ->
      with {:ok, adapter} <- Adapters.install(scope, name),
           {:ok, _state} <- AccessKeys.issue_installed_code(scope, adapter),
           do: :ok
    end)
  end

  defp unlist(scope, adapter) do
    guarded(fn ->
      with {:ok, _count} <- AccessKeys.cancel_installed_codes(scope, adapter), do: :ok
    end)
  end

  # The adapters in use installed as a name `names` does not list.
  defp unlisted(names) do
    Repo.all(
      from n in Node,
        where: n.kind == :adapter and is_nil(n.deleted_at) and not is_nil(n.installed_as),
        where: is_nil(n.organisation_id) and is_nil(n.workspace_id),
        where: n.installed_as not in ^names,
        order_by: [asc: n.installed_as]
    )
  end

  # A failure, caught of any kind or returned, is the name's alone: the pass goes on with
  # the next. Of a failure caught, only its kind is kept, never its message or its reason.
  defp guarded(fun) do
    fun.()
  catch
    kind, reason -> {:error, {:caught, kind(kind, reason, __STACKTRACE__)}}
  end

  # The kind of a failure caught: the module of the exception an error is, else `:exit` or
  # `:throw`.
  defp kind(:error, reason, stacktrace),
    do: Exception.normalize(:error, reason, stacktrace).__struct__

  defp kind(kind, _reason, _stacktrace), do: kind

  defp failed(_name, :ok), do: []
  defp failed(name, {:error, reason}), do: [{name, reason}]

  # What the log says of a pass: once that it waits, until it no longer does; once that a
  # name failed, until it passes again.
  defp said(:waiting, %{waiting_said: false} = state) do
    if NodesInstalled.names() != [] do
      Logger.info(
        "QORY_INSTALLED_POOL or QORY_INSTALLED_GATEWAY declares a node of the instance: " <>
          "it is installed once Qory Apiary is set up"
      )
    end

    if Installed.names() != [] do
      Logger.info(
        "QORY_INSTALLED_ADAPTERS names adapters: they are installed once Qory Apiary is set up"
      )
    end

    %{state | waiting_said: true}
  end

  defp said(:waiting, state), do: state
  defp said(:off, state), do: state

  defp said({:failed, kind}, state) do
    unless MapSet.member?(state.failing, :pass) do
      Logger.error("could not install the adapters: #{inspect(kind)}; trying again")
    end

    %{state | failing: MapSet.new([:pass])}
  end

  defp said({:ok, failures}, state) do
    failing = MapSet.new(failures, &elem(&1, 0))

    for {name, reason} <- failures, not MapSet.member?(state.failing, name) do
      Logger.error(failure_line(name, reason))
    end

    %{state | waiting_said: false, failing: failing}
  end

  @doc false
  # The line that says a name's pass failed, with its reason alone.
  @spec failure_line(String.t() | {:pool | :gateway, String.t()}, term) :: String.t()
  def failure_line({kind, name}, {:code_file, reason}),
    do:
      "could not write the one-time code of the instance's #{NodesInstalled.noun(kind)} " <>
        "#{name} to #{CodeFile.folder(name)}: #{CodeFile.format_error(reason)}; trying again"

  def failure_line({kind, name}, {:caught, kind_caught}),
    do:
      "could not install the instance's #{NodesInstalled.noun(kind)} #{name}: " <>
        "#{inspect(kind_caught)}; trying again"

  def failure_line({kind, name}, %Ecto.Changeset{}),
    do:
      "could not install the instance's #{NodesInstalled.noun(kind)} #{name}: " <>
        "it was not valid; trying again"

  def failure_line({kind, name}, reason),
    do:
      "could not install the instance's #{NodesInstalled.noun(kind)} #{name}: " <>
        "#{inspect(reason)}; trying again"

  def failure_line(name, {:code_file, reason}),
    do:
      "could not write the one-time code of the installed adapter #{name} to " <>
        "#{CodeFile.folder(name)}: #{CodeFile.format_error(reason)}; trying again"

  def failure_line(name, {:caught, kind}),
    do: "could not install the adapter #{name}: #{inspect(kind)}; trying again"

  def failure_line(name, %Ecto.Changeset{}),
    do: "could not install the adapter #{name}: it was not valid; trying again"

  def failure_line(name, reason),
    do: "could not install the adapter #{name}: #{inspect(reason)}; trying again"
end
