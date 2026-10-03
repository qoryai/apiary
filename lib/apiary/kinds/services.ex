defmodule Apiary.Kinds.Services do
  @moduledoc """
  Services is the catalogue of the built-in service definitions, which ship with the
  application in `priv/services/*.json`, one file per definition, named for its `key`.
  Each is checked by `Apiary.Kinds.ServiceDefinition` in the test suite, and read when the
  application is compiled: a built-in definition changes with a release, and reaches every
  connection that names it from that release on.

  A service connection names a built-in definition by its key (`Apiary.Connections`), and
  holds no host and no auth of its own. Each definition's `digest`, the SHA-256 of its
  canonical JSON, says which revision a rendering was made from.
  """

  alias Apiary.Kinds.ServiceDefinition

  @dir Path.join([__DIR__, "..", "..", "..", "priv", "services"])
  @paths @dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()

  for path <- @paths, do: @external_resource(path)
  @external_resource @dir

  @definitions (for path <- @paths do
                  definition = path |> File.read!() |> Jason.decode!()

                  unless definition["key"] == Path.basename(path, ".json"),
                    do: raise("#{path} is not named for its key")

                  definition
                end)

  @doc "list/0 is every built-in definition, by key, each as decoded JSON."
  @spec list() :: [map]
  def list, do: @definitions

  @doc "keys/0 is the key of every built-in definition."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(@definitions, & &1["key"])

  @doc "fetch/1 is the built-in definition with `key`: `{:ok, definition}`, or `:error`."
  @spec fetch(term) :: {:ok, map} | :error
  def fetch(key) do
    case Enum.find(@definitions, &(&1["key"] == key)) do
      %{} = definition -> {:ok, definition}
      nil -> :error
    end
  end

  @doc "digest/1 is the digest of the built-in definition with `key`, or nil."
  @spec digest(term) :: String.t() | nil
  def digest(key) do
    case fetch(key) do
      {:ok, definition} -> ServiceDefinition.digest(definition)
      :error -> nil
    end
  end
end
