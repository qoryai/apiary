defmodule Apiary.Kinds.Runtimes do
  @moduledoc """
  Runtimes is the catalogue of the runtimes a workspace can set up: the runner contract's
  `contracts/forager/v1/runtimes.json`, vendored byte for byte as
  `priv/contract/runtimes.json` at the commit in `.forager-contract-ref`. The runner
  generates it from its built-in descriptors, in name order; per runtime it has its
  `name`, such as `claude`, a `title`, its `reserves`, its `denies`, its
  `credential_files`, its `declares` (each with its `id`, `title`, the variable `name` it
  sets, its `hosts`, its `auth`, as the contract's `auth.schema.json` has it, and its
  `paths`, which may be absent), and its `one_of` groups (each with `id`, `required` and
  `of`). A test compares the file with the runner's contract directory.

  The catalogue is read when the application is compiled: a runtime is added by a
  release. Every list of a runtime is read with `Map.fetch!/2`, since the runner always
  writes them, so a key the contract renames fails the compile instead of reading as an
  empty list.

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
                   reserves: Map.fetch!(runtime, "reserves"),
                   denies: Map.fetch!(runtime, "denies"),
                   credential_files: Map.fetch!(runtime, "credential_files"),
                   declares: Map.fetch!(runtime, "declares"),
                   one_of: Map.fetch!(runtime, "one_of")
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
  def hosts(%Runtime{declares: declares}),
    do: declares |> Enum.flat_map(&Map.get(&1, "hosts", [])) |> Enum.uniq()

  @doc """
  variables/0 is every variable a runtime of the catalogue declares or reserves: the
  names no other connection may take for a placeholder (`Apiary.Kinds.Placeholders`).
  """
  @spec variables() :: [String.t()]
  def variables do
    @runtimes
    |> Enum.flat_map(fn runtime ->
      Enum.flat_map(runtime.declares, &List.wrap(&1["name"])) ++ runtime.reserves
    end)
    |> Enum.uniq()
  end
end
