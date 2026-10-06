defmodule Apiary.Kinds.Schema do
  @moduledoc """
  Schema builds and keeps the JSON Schemas the kinds are validated against with JSV: an
  integration's `description.json` (the integrations contract's
  `description.schema.json`, vendored under `priv/contract/integration/`), a service
  definition (`priv/schemas/service-definition.schema.json`), and an integration's own
  settings schema. Every schema is given `Apiary.Kinds.Pattern.end_only/1` first, so its
  patterns read `$` as the contracts do. A schema from a file is built once and kept in
  `:persistent_term`. Nothing is fetched over the network: a reference outside the file
  resolves to the runner contract's `auth.schema.json`, vendored under `priv/contract/`,
  which a service definition's `auth` refers to by its URL, or through JSV's own local
  resolvers, to JSON Schema's meta-schemas it embeds and to schemas of loaded modules.
  """

  @behaviour JSV.Resolver

  alias Apiary.Kinds.Pattern

  @runner "https://qory.dev/contracts/runner/v1/"
  @vendored ~w(auth.schema.json)

  @doc """
  build/2 builds `schema`, a decoded JSON Schema: `{:ok, root}`, or `{:error, reason}` for
  one JSV cannot build, such as a pattern PCRE does not take.
  """
  @spec build(map, keyword) :: {:ok, JSV.Root.t()} | {:error, term}
  def build(schema, opts \\ []) when is_map(schema) do
    {:ok, JSV.build!(Pattern.end_only(schema), Keyword.merge([formats: true], opts))}
  rescue
    error -> {:error, error}
  end

  @doc """
  file!/2 is the root built from the JSON Schema file at `path` under the application's
  `priv`, after `adjust`, a function of the decoded schema; built once and kept.
  """
  @spec file!([String.t()], (map -> map)) :: JSV.Root.t()
  def file!(path, adjust \\ & &1) when is_list(path) do
    key = {__MODULE__, path}

    case :persistent_term.get(key, nil) do
      nil ->
        {:ok, root} =
          Application.app_dir(:apiary, ["priv" | path])
          |> File.read!()
          |> Jason.decode!()
          |> adjust.()
          |> build(resolver: __MODULE__)

        :persistent_term.put(key, root)
        root

      root ->
        root
    end
  end

  @doc """
  validate/2 validates the decoded JSON `value` against `root`: `:ok`, or
  `{:error, errors}` with JSV's normalised errors, for a log and not for a page.
  """
  @spec validate(term, JSV.Root.t()) :: :ok | {:error, map}
  def validate(value, root) do
    case JSV.validate(value, root) do
      {:ok, _value} -> :ok
      {:error, %JSV.ValidationError{} = error} -> {:error, JSV.normalize_error(error)}
    end
  end

  # A file of ours that refers to the runner's contract gets the vendored copy, whose
  # patterns are read as the contract reads them, like the file's own.
  @impl JSV.Resolver
  def resolve(@runner <> file, _opts) when file in @vendored do
    with {:ok, body} <- File.read(Application.app_dir(:apiary, ["priv", "contract", file])),
         {:ok, schema} <- Jason.decode(body),
         do: {:ok, Pattern.end_only(schema)}
  end

  def resolve(url, _opts), do: {:error, {:not_vendored, url}}
end
