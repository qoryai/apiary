defmodule Apiary.Kinds.Runtimes do
  @moduledoc """
  Runtimes is the catalogue of the runtimes a workspace can set up, as the runner
  contract's `contracts/runner/v1/runtimes.json` lists them, vendored at the same name as
  `priv/contract/runtimes.json`: per runtime its `name`, such as `claude`, a `title`, its
  `reserves`, its `denies`, its `credential_files`, its `declarations` (each with its
  `id`, `title`, the variable `name` it sets, its `hosts`, its `auth` with its `header`,
  and its `paths`), and its `one_of` groups (each with `id`, `required` and `of`).

  The runner generates the file from its built-in descriptors and ships it with the
  secrets contract. Until the pin moves to that release, the file here is an interim
  copy written from the contract's text, in that shape; the change that moves the pin
  puts the runner's file in its place, which this module reads unchanged. The
  catalogue is read when the application is compiled: a runtime is added by a release.

  A runtime connection (`Apiary.Connections`) names its runtime by `name`, and links each
  declaration to a stored secret.
  """

  @path Path.join([__DIR__, "..", "..", "..", "priv", "contract", "runtimes.json"])
  @external_resource @path

  alias Apiary.Kinds.Runtime

  @runtimes (fn ->
               %{"version" => 1, "runtimes" => runtimes} =
                 @path |> File.read!() |> Jason.decode!()

               for runtime <- runtimes do
                 %Runtime{
                   name: Map.fetch!(runtime, "name"),
                   title: Map.fetch!(runtime, "title"),
                   declarations: Map.get(runtime, "declarations", []),
                   one_of: Map.get(runtime, "one_of", []),
                   reserves: Map.get(runtime, "reserves", []),
                   denies: Map.get(runtime, "denies", []),
                   credential_files: Map.get(runtime, "credential_files", [])
                 }
               end
             end).()

  @doc "list/0 is every runtime of the catalogue, in its order."
  @spec list() :: [Runtime.t()]
  def list, do: @runtimes

  @doc "fetch/1 is the runtime named `name`: `{:ok, runtime}`, or `:error`."
  @spec fetch(term) :: {:ok, Runtime.t()} | :error
  def fetch(name) do
    case Enum.find(@runtimes, &(&1.name == name)) do
      %Runtime{} = runtime -> {:ok, runtime}
      nil -> :error
    end
  end

  @doc "hosts/1 is every host a runtime's declarations set a value on, each once."
  @spec hosts(Runtime.t()) :: [String.t()]
  def hosts(%Runtime{declarations: declarations}),
    do: declarations |> Enum.flat_map(&Map.get(&1, "hosts", [])) |> Enum.uniq()

  @doc """
  variables/0 is every variable a runtime of the catalogue declares or reserves: the
  names no other connection may take for a placeholder (`Apiary.Kinds.Placeholders`).
  """
  @spec variables() :: [String.t()]
  def variables do
    @runtimes
    |> Enum.flat_map(fn runtime ->
      Enum.flat_map(runtime.declarations, &List.wrap(&1["name"])) ++ runtime.reserves
    end)
    |> Enum.uniq()
  end
end
