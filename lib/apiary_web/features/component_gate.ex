defmodule ApiaryWeb.Features.ComponentGate do
  @moduledoc false
  # `use ApiaryWeb, :live_component` compiles this into each LiveComponent: its mount/1,
  # or one added where it has none, first attaches `ApiaryWeb.Features.component_gate/1`,
  # so an event sent to the component checks the gates of the LiveView it is in.

  defmacro __before_compile__(env) do
    if Module.defines?(env.module, {:mount, 1}, :def) do
      quote do
        defoverridable mount: 1

        @impl Phoenix.LiveComponent
        def mount(socket), do: super(ApiaryWeb.Features.component_gate(socket))
      end
    else
      quote do
        @impl Phoenix.LiveComponent
        def mount(socket), do: {:ok, ApiaryWeb.Features.component_gate(socket)}
      end
    end
  end
end
