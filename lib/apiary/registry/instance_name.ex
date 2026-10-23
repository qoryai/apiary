defmodule Apiary.Registry.InstanceName do
  @moduledoc false

  # With the `registry` feature: at boot, after the migrator, the instance's registry
  # name is made where the instance's row has none, and kept for the life of the node
  # (`Apiary.InstanceConfig.registry_instance/0`). It starts once and leaves nothing in
  # the supervision tree. On a schema whose migration of the name has not run yet, as
  # with `MIGRATE_ON_BOOT=false`, it keeps nothing, and the name is read when first
  # needed. Off in test, where each test reads the name inside its sandbox.

  @doc false
  @spec child_spec(term) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      restart: :temporary,
      type: :worker
    }
  end

  @doc false
  @spec start_link() :: :ignore
  def start_link do
    case Apiary.InstanceConfig.record_registry_instance() do
      name when is_binary(name) -> Application.put_env(:apiary, :registry_instance, name)
      nil -> :ok
    end

    :ignore
  end

  @doc false
  # children/0 is this worker where the feature is on and the worker enabled.
  @spec children() :: [module]
  def children do
    enabled = Keyword.get(Application.get_env(:apiary, __MODULE__, []), :enabled, true)
    if enabled and Apiary.Features.on?(:registry), do: [__MODULE__], else: []
  end
end
