defmodule Apiary.Kinds.Schema do
  @moduledoc """
  Schema builds and keeps the JSON Schemas the kinds are validated against with JSV: an
  integration's `description.json` (the integrations contract's
  `description.schema.json`, vendored under `priv/contract/integration/`), a service
  definition (`priv/schemas/service-definition.schema.json`), and an integration's own
  settings schema. Every schema is given `Apiary.Kinds.Pattern.end_only/1` first, so its
  patterns read `$` as the contracts do. A schema from a file is built once and kept in
  `:persistent_term`; nothing is fetched, and a reference outside the file resolves only
  to JSON Schema's own meta-schemas, which JSV embeds.
  """

  alias Apiary.Kinds.Pattern

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
          |> build()

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
end
