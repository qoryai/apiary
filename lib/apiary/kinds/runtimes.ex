defmodule Apiary.Kinds.Runtimes do
  @moduledoc """
  Runtimes is the catalogue of the runtimes a workspace can set up, as the runner
  contract's `runtimes.json` lists them (`priv/contract/runtimes.json`): per runtime its
  `name`, such as `claude`, a `title`, the secrets it declares (`declares`: each with its
  `id`, `title`, the variable `name` it sets, its `hosts`, its `paths` and its `auth`), its
  `one_of` groups, the variables it `reserves`, the variables the runner `denies` it, and
  its `credential_files`.

  The contract ships the file with the secrets contract; until the pin moves to that
  release, the file here is written from the contract's text, and the release that moves
  the pin replaces it with the contract's own, which this module reads unchanged. The
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
                   declares: Map.get(runtime, "declares", []),
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
