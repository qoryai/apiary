defmodule Apiary.DiagnosticsSchema do
  @moduledoc """
  The run diagnostics contract's schemas (`priv/contract/diagnostics/v1/`): the document,
  the run list and its refusal, each built for validation, with the integration and
  provisioner definitions it refers to, vendored under `test/fixtures/contract/`. Nothing is fetched. Test support.
  """

  @behaviour JSV.Resolver

  @base "https://qory.dev/contracts/"
  @roots [
    Path.expand("../../priv/contract", __DIR__),
    Path.expand("../fixtures/contract", __DIR__)
  ]

  @doc "The contract's fixtures, under `test/fixtures/contract/diagnostics/v1/`."
  def fixtures_dir, do: Path.expand("../fixtures/contract/diagnostics/v1", __DIR__)

  @doc "The validator of a document."
  def root, do: build("diagnostics.schema.json")

  @doc "The validator of the run list, the `200` answer to `GET /v1/runs`."
  def runs, do: build("runs.schema.json")

  @doc "The validator of a refusal of `GET /v1/runs`."
  def runs_refusal, do: build("runs-refusal.schema.json")

  defp build(file) do
    JSV.build!(%{"$ref" => @base <> "diagnostics/v1/" <> file},
      resolver: {__MODULE__, @roots},
      formats: true
    )
  end

  @doc "`:ok`, or `{:error, error}` with what the schema refuses in `document`, decoded."
  def validate(root, document) do
    case JSV.validate(document, root) do
      {:ok, _document} -> :ok
      {:error, error} -> {:error, JSV.normalize_error(error)}
    end
  end

  @impl JSV.Resolver
  def resolve(@base <> path, roots) do
    Enum.find_value(roots, {:error, {:not_vendored, path}}, fn root ->
      file = Path.expand(path, root)

      with true <- String.starts_with?(file, root <> "/"),
           {:ok, body} <- File.read(file),
           {:ok, schema} <- Jason.decode(body) do
        {:ok, schema}
      else
        _ -> nil
      end
    end)
  end

  def resolve(url, _roots), do: {:error, {:not_vendored, url}}
end
