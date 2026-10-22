defmodule Mix.Tasks.Apiary.Demo.Shell do
  @moduledoc false

  # Where the demo's lines and failures go. Under `mix apiary.demo.*` a line goes to the
  # Mix shell and a failure is `Mix.raise/1`. Under the release command
  # (`Apiary.Release.demo/1`), whose release has no Mix, `quietly/1` runs the fill: a line
  # is dropped, as the command prints lines of its own, and a failure raises a
  # `RuntimeError`. The setting is the calling process's: every line of the demo is
  # printed from the process that runs it.

  @key {__MODULE__, :quiet}

  @doc false
  # quietly/1 runs `fun` with the demo's lines dropped and its failures raised without
  # Mix, and returns its result.
  @spec quietly((-> result)) :: result when result: term
  def quietly(fun) when is_function(fun, 0) do
    previous = Process.put(@key, true)

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  @doc false
  @spec info(String.t()) :: :ok
  def info(message) do
    if Process.get(@key), do: :ok, else: Mix.shell().info(message)
  end

  @doc false
  @spec raise!(String.t()) :: no_return
  def raise!(message) do
    if Process.get(@key), do: raise(message), else: Mix.raise(message)
  end
end
