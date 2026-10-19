defmodule Apiary.Kinds.Providers do
  @moduledoc """
  Providers is the catalogue of the model providers an organisation can add: the
  integrations contract's data descriptions, vendored under
  `priv/contract/integration/descriptions/` at the commit in `.integration-contract-ref`,
  one file per provider, named after the description's `name`. Each file is read by
  `Apiary.Kinds.Provider.load!/1` when the application is compiled, so a description that
  fails stops the compile; a provider is added by a release.

  `serve/2` checks whether a provider can serve a runtime of `Apiary.Kinds.Runtimes`.

  `ref/0` is the integrations commit the descriptions were vendored from, which a provider
  connection records with the description's digest. It is read from
  `.integration-contract-ref` when the application is compiled: the commit is the file's
  one line that is not a comment, 40 lower-case hex digits, or the compile stops.
  """

  alias Apiary.Kinds.{Provider, Runtime, Runtimes}

  @ref_path Path.expand("../../../.integration-contract-ref", __DIR__)
  @external_resource @ref_path

  @ref (case @ref_path
             |> File.read!()
             |> String.split("\n", trim: true)
             |> Enum.reject(&String.starts_with?(&1, "#")) do
          [ref] ->
            if Regex.match?(~r/\A[0-9a-f]{40}\z/, ref),
              do: ref,
              else:
                raise("#{@ref_path} has no commit of 40 lower-case hex digits: #{inspect(ref)}")

          lines ->
            raise "#{@ref_path} has #{length(lines)} lines that are not comments, not one"
        end)

  @dir Path.expand("../../../priv/contract/integration/descriptions", __DIR__)

  @paths @dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()

  for path <- @paths, do: @external_resource(path)

  @providers Enum.map(@paths, &Provider.load!/1)

  # A file added to or removed from the directory changes no file of @paths, so the
  # module also compiles again when the list of files differs.
  @doc false
  def __mix_recompile__? do
    @dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort() != @paths
  end

  @doc "ref/0 is the integrations commit the descriptions were vendored from."
  @spec ref() :: String.t()
  def ref, do: @ref

  @doc "list/0 is every provider of the catalogue, in the order of its name."
  @spec list() :: [Provider.t()]
  def list, do: @providers

  @doc "fetch/1 is the provider named `name`: `{:ok, provider}`, or `:error`."
  @spec fetch(term) :: {:ok, Provider.t()} | :error
  def fetch(name) do
    case Enum.find(@providers, &(&1.name == name)) do
      %Provider{} = provider -> {:ok, provider}
      nil -> :error
    end
  end

  @doc """
  serve/2 checks whether `provider` can serve `runtime`, in this order:

    1. the provider's `formats` and the runtime's model formats (`Runtimes.formats/1`)
       share a value, or else `{:error, :format}`;
    2. the runtime's `declares` has an entry whose `name` is one of the provider's
       `key_variables` and whose `auth` equals the provider's `auth`, or else
       `{:error, :key_variable}`. A variable the runtime only reserves does not count.

  The result is `:ok` when both hold.
  """
  @spec serve(Provider.t(), Runtime.t()) :: :ok | {:error, :format | :key_variable}
  def serve(%Provider{} = provider, %Runtime{} = runtime) do
    cond do
      not Enum.any?(provider.formats, &(&1 in Runtimes.formats(runtime))) ->
        {:error, :format}

      not Enum.any?(runtime.declares, &declared_key?(&1, provider)) ->
        {:error, :key_variable}

      true ->
        :ok
    end
  end

  @doc "serves?/2 is whether `serve/2` returns `:ok`."
  @spec serves?(Provider.t(), Runtime.t()) :: boolean
  def serves?(%Provider{} = provider, %Runtime{} = runtime),
    do: serve(provider, runtime) == :ok

  defp declared_key?(declare, %Provider{key_variables: variables, auth: auth}),
    do: Map.get(declare, "name") in variables and Map.get(declare, "auth") == auth
end
