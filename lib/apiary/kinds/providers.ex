defmodule Apiary.Kinds.Providers do
  @moduledoc """
  Providers is the catalogue of the model providers an organisation can add: the
  integrations contract's data descriptions, vendored under
  `priv/contract/integration/descriptions/` at the commit in `.integration-contract-ref`,
  one file per provider, named after the description's `name`. Each file is read by
  `Apiary.Kinds.Provider.load!/1` when the application is compiled, so a description that
  fails stops the compile; a provider is added by a release.

  `serve/2` checks whether a provider can serve a runtime of `Apiary.Kinds.Runtimes`, and
  `api/2` picks the API of the provider that a run of that runtime uses.

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

    1. an API of the provider has a `format` among the runtime's model formats
       (`Runtimes.formats/1`), or else `{:error, :format}`;
    2. an API of the provider has the `format` and the `auth` of an entry of the
       runtime's `model_keys`, or else `{:error, :key_variable}`: the runtime has no
       variable for a key of the provider.

  The result is `:ok` when both hold. Two auths are the same when their `scheme` is the
  same, their `header` is the same with case ignored, as HTTP header names are, and both
  or neither are marked `oauth`, as Forager compares them when it starts a run.
  """
  @spec serve(Provider.t(), Runtime.t()) :: :ok | {:error, :format | :key_variable}
  def serve(%Provider{} = provider, %Runtime{} = runtime) do
    case api(provider, runtime) do
      {:ok, _api} -> :ok
      {:error, _reason} = refused -> refused
    end
  end

  @doc "serves?/2 is whether `serve/2` returns `:ok`."
  @spec serves?(Provider.t(), Runtime.t()) :: boolean
  def serves?(%Provider{} = provider, %Runtime{} = runtime),
    do: serve(provider, runtime) == :ok

  @doc """
  api/2 is the API of `provider` that a run of `runtime` uses: the first in the
  description's order whose `format` and `auth` an entry of the runtime's `model_keys`
  has, as `serve/2` compares them. `{:ok, api}`, or the refusal of `serve/2`.
  """
  @spec api(Provider.t(), Runtime.t()) ::
          {:ok, Provider.api()} | {:error, :format | :key_variable}
  def api(%Provider{apis: apis}, %Runtime{} = runtime) do
    formats = Runtimes.formats(runtime)
    spoken = Enum.filter(apis, &(&1["format"] in formats))

    case Enum.find(spoken, fn api -> Enum.any?(runtime.model_keys, &key?(&1, api)) end) do
      %{} = api -> {:ok, api}
      nil when spoken == [] -> {:error, :format}
      nil -> {:error, :key_variable}
    end
  end

  defp key?(%{"format" => format, "auth" => key_auth}, %{"format" => format, "auth" => auth}),
    do: same_auth?(key_auth, auth)

  defp key?(_key, _api), do: false

  defp same_auth?(%{"scheme" => scheme} = a, %{"scheme" => scheme} = b) do
    header(a) == header(b) and Map.get(a, "oauth", false) == Map.get(b, "oauth", false)
  end

  defp same_auth?(_a, _b), do: false

  defp header(%{"header" => header}) when is_binary(header), do: String.downcase(header, :ascii)
  defp header(_auth), do: nil
end
