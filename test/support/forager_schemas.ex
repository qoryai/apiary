defmodule Apiary.ForagerSchemas do
  @moduledoc """
  Validates a document against a schema of Forager's contract vendored under
  `priv/contract/` (`.forager-contract-ref`), by its file name, with the schemas it
  refers to read from the same directory. Nothing is fetched.
  """

  @behaviour JSV.Resolver

  @base "https://qory.dev/contracts/forager/v1/"

  @doc """
  validate/2 validates `document`, bytes or decoded JSON, against the schema `file`:
  `:ok`, or `{:error, error}`.
  """
  @spec validate(String.t(), binary | map) :: :ok | {:error, term}
  def validate(file, document) when is_binary(document),
    do: validate(file, Jason.decode!(document))

  def validate(file, document) do
    root = JSV.build!(%{"$ref" => @base <> file}, resolver: __MODULE__, formats: true)

    case JSV.validate(document, root, cast: false) do
      {:ok, _document} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @impl JSV.Resolver
  def resolve(@base <> file, _opts) do
    path = Application.app_dir(:apiary, ["priv", "contract", Path.basename(file)])
    with {:ok, body} <- File.read(path), do: Jason.decode(body)
  end

  def resolve(url, _opts), do: {:error, {:not_vendored, url}}
end
