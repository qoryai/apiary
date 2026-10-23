defmodule Apiary.ExploreInputsSchema do
  @moduledoc """
  The explore contract's `inputs.schema.json`, from `priv/contract`, with the integration
  contract's schemas it refers to from the vendored fixtures, built for validation. Test
  support: nothing is fetched.
  """

  @behaviour JSV.Resolver

  @base "https://qory.dev/contracts/"

  @doc "`:ok`, or `{:error, error}` with the errors the schema check finds in `inputs`, decoded."
  def validate(inputs) do
    roots = [
      Path.expand("../fixtures/contract", __DIR__),
      Application.app_dir(:apiary, "priv/contract")
    ]

    root =
      JSV.build!(%{"$ref" => @base <> "explore/v1/inputs.schema.json"},
        resolver: {__MODULE__, roots},
        formats: true
      )

    case JSV.validate(inputs, root) do
      {:ok, _inputs} -> :ok
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
