defmodule Apiary.Policy.Schema do
  @moduledoc """
  The contract's `run-configuration.schema.json` and the `policy.schema.json` it refers
  to, vendored under `priv/contract/`, and the validation every rendered document passes
  before it is stored. A test compares the vendored files with the runner's contract
  directory when `RUNNER_CONTRACT_DIR` is set, as CI sets it.

  The validator is built once and kept in `:persistent_term`. Nothing is fetched: a
  reference outside the two files does not resolve.
  """

  @behaviour JSV.Resolver

  @base "https://qory.dev/contracts/runner/v1/"
  @files ~w(policy.schema.json run-configuration.schema.json)

  @doc "The vendored schema files, by name."
  def files, do: @files

  @doc "Where a vendored schema file is."
  def path(file) when file in @files, do: Application.app_dir(:apiary, ["priv", "contract", file])

  @doc """
  Validates a run configuration document, as bytes. `:ok`, or `{:error, reason}` with
  what the schema refuses, for a log and not for a page.
  """
  @spec validate(binary) :: :ok | {:error, term}
  def validate(document) when is_binary(document) do
    with {:ok, decoded} <- Jason.decode(document),
         {:ok, _document} <- JSV.validate(decoded, root()) do
      :ok
    else
      {:error, %JSV.ValidationError{} = error} -> {:error, JSV.normalize_error(error)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp root do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        root =
          JSV.build!(%{"$ref" => @base <> "run-configuration.schema.json"},
            resolver: __MODULE__,
            formats: true
          )

        :persistent_term.put(__MODULE__, root)
        root

      root ->
        root
    end
  end

  @impl JSV.Resolver
  def resolve(@base <> file, _opts) when file in @files do
    with {:ok, body} <- File.read(path(file)), do: Jason.decode(body)
  end

  def resolve(url, _opts), do: {:error, {:not_vendored, url}}
end
