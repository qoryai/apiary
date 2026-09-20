defmodule Apiary.ContractSchema do
  @moduledoc """
  The server contract's JSON Schemas, read from the runner's contract directory
  (`Apiary.ContractFixtures.contract_dir/0`) and built for validation. Test support:
  the apiary itself checks an event's envelope and stores `data` as received.
  """

  @behaviour JSV.Resolver

  @base "https://qory.dev/contracts/runner/v1/"

  @doc "The validator of one event, `event.schema.json` with the data schema of each type."
  def event!(contract_dir) do
    JSV.build!(%{"$ref" => @base <> "event.schema.json"},
      resolver: {__MODULE__, contract_dir},
      formats: true
    )
  end

  @doc "`:ok`, or `{:error, error}` with what the schema refuses in `event`, a decoded map."
  def validate(root, event) do
    case JSV.validate(event, root) do
      {:ok, _event} -> :ok
      {:error, error} -> {:error, JSV.normalize_error(error)}
    end
  end

  # The schemas name each other by URL under the contract's base; the files are beside
  # each other under the contract's directory. Nothing is fetched.
  @impl JSV.Resolver
  def resolve(@base <> path, contract_dir) do
    file = Path.expand(path, contract_dir)

    with true <- String.starts_with?(file, contract_dir <> "/"),
         {:ok, body} <- File.read(file),
         {:ok, schema} <- Jason.decode(body) do
      {:ok, schema}
    else
      _ -> {:error, {:not_in_the_contract, path}}
    end
  end

  def resolve(url, _contract_dir), do: {:error, {:not_in_the_contract, url}}
end
