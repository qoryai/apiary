defmodule Apiary.Kinds.Schema do
  @moduledoc """
  Schema builds and keeps the JSON Schemas the kinds are validated against with JSV: an
  integration's `description.json` (the integrations contract's
  `description.schema.json`, vendored under `priv/contract/integration/`), a service
  definition (`priv/schemas/service-definition.schema.json`), and an integration's
  settings schema. Every schema is given `Apiary.Kinds.Pattern.end_only/1` first, so its
  patterns read `$` as the contracts do. A schema from a file is built once and kept in
  `:persistent_term`. Nothing is fetched over the network: a reference outside the file
  resolves to the Forager contract's `auth.schema.json`, vendored under `priv/contract/`,
  which a service definition's `auth` refers to by its URL, or through JSV's local
  resolvers, to JSON Schema's meta-schemas it embeds and to schemas of loaded modules. A
  settings schema reaches no module it names: `Apiary.Kinds.SettingsResolver` answers its
  `jsv:` references first.
  """

  @behaviour JSV.Resolver

  alias Apiary.Kinds.{Bounds, Pattern}

  @forager_contract "https://qory.dev/contracts/forager/v1/"
  @vendored ~w(auth.schema.json)

  @doc """
  build/2 builds `schema`, a decoded JSON Schema: `{:ok, root}`, or `{:error, reason}` for
  one JSV cannot build, such as a pattern PCRE does not take.

  It is built with `atoms: false`, whatever `opts` say: a cast that makes atoms, such as
  `"jsv-cast": ["Elixir.JSV.Cast", "string_to_atom"]` or `"aprops"`, is left out, so a
  schema from an untrusted input can make no atom, which the runtime never frees.
  """
  @spec build(map, keyword) :: {:ok, JSV.Root.t()} | {:error, term}
  def build(schema, opts \\ []) when is_map(schema) do
    opts = [formats: true] |> Keyword.merge(opts) |> Keyword.put(:atoms, false)
    {:ok, JSV.build!(Pattern.end_only(schema), opts)}
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
  `{:error, errors}` with JSV's normalised errors, for a log and not for a page. JSV
  validates with `cast: false`: the value is checked, and no cast the schema names is
  called on it.
  """
  @spec validate(term, JSV.Root.t()) :: :ok | {:error, map}
  def validate(value, root) do
    case JSV.validate(value, root, cast: false) do
      {:ok, _value} -> :ok
      {:error, %JSV.ValidationError{} = error} -> {:error, JSV.normalize_error(error)}
    end
  end

  @doc """
  valid?/2 is whether the decoded JSON `value` is valid against `root`, validated as
  `validate/2` validates it, with JSV's errors neither normalised nor returned.
  """
  @spec valid?(term, JSV.Root.t()) :: boolean
  def valid?(value, root), do: match?({:ok, _value}, JSV.validate(value, root, cast: false))

  @doc """
  validate/3 is `validate/2` once `value` is within `limits`
  (`Apiary.Kinds.Bounds.within?/2`). A value outside the limits is never given to JSV:
  `{:error, %{valid: false, limits: limits}}`, the limits as a map.
  """
  @spec validate(term, JSV.Root.t(), Bounds.limits()) :: :ok | {:error, map}
  def validate(value, root, limits) do
    if Bounds.within?(value, limits),
      do: validate(value, root),
      else: {:error, %{valid: false, limits: Map.new(limits)}}
  end

  # A file of ours that refers to Forager's contract gets the vendored copy, whose
  # patterns are read as the contract reads them, like the file's own.
  @impl JSV.Resolver
  def resolve(@forager_contract <> file, _opts) when file in @vendored do
    with {:ok, body} <- File.read(Application.app_dir(:apiary, ["priv", "contract", file])),
         {:ok, schema} <- Jason.decode(body),
         do: {:ok, Pattern.end_only(schema)}
  end

  def resolve(url, _opts), do: {:error, {:not_vendored, url}}
end
