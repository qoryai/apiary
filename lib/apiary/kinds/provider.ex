defmodule Apiary.Kinds.Provider do
  @moduledoc """
  Provider is one model provider of the catalogue (`Apiary.Kinds.Providers`): a data
  description of the integrations contract whose one role is `model_provider`, read by
  `Apiary.Integrations.Description.parse/1`.

  Its fields are the role's members, named as the contract names them, with the JSON
  values as JSON maps with string keys: `endpoint`, a URL or `%{"setting" => name}` for
  the address a setting has; `formats`, the model API formats the provider serves;
  `hosts`, `[]` for an endpoint from a setting; `auth`, as the Forager contract's
  `auth.schema.json` has it; `key_variables`, the environment variables the key may be
  set in; and `models`, each with `id`, `title` and, when the description lists them,
  `effort`. `egress_hosts` is the description's top-level list, `[]` when it has none.
  `description` is the description as `parse/1` returns it, and `sha256` the SHA-256 of
  the file's bytes, in lower-case hex, which a provider connection records.

  An **address setting** is a setting that `endpoint` or an entry of `egress_hosts` names
  (`%{"setting" => name}`): its value is an address a run reaches, which
  `Apiary.Kinds.Endpoint` checks wherever it is saved.
  """

  alias Apiary.Integrations.Description
  alias Apiary.Kinds.Endpoint

  @enforce_keys [:name, :title, :description]
  defstruct name: nil,
            title: nil,
            description: nil,
            sha256: nil,
            endpoint: nil,
            formats: [],
            hosts: [],
            auth: nil,
            key_variables: [],
            models: [],
            egress_hosts: []

  @typedoc "A model provider of the catalogue."
  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t(),
          description: Description.t(),
          sha256: String.t() | nil,
          endpoint: String.t() | %{String.t() => String.t()},
          formats: [String.t()],
          hosts: [String.t()],
          auth: map,
          key_variables: [String.t()],
          models: [map],
          egress_hosts: [String.t() | %{String.t() => String.t()}]
        }

  @doc """
  load!/1 is the provider the data description at `path` describes. It raises when
  `parse/1` refuses the file, when the description has a `program_version` or a role
  other than `model_provider`, when its `name` differs from the file's name without
  `.json`, when its URL endpoint or the `default` of an address setting breaks the rule
  of `Apiary.Kinds.Endpoint`, or when it has more than 200 models or a model title of
  more than 128 characters, which a provider connection cannot hold
  (`Apiary.Connections.ProviderModel`). `Apiary.Kinds.Providers` calls it when the application is
  compiled, so a description that fails stops the compile.
  """
  @spec load!(Path.t()) :: t
  def load!(path) do
    file = Path.basename(path, ".json")
    bytes = File.read!(path)

    case Description.parse(bytes) do
      {:ok, %Description{name: ^file, program_version: nil, roles: ["model_provider"]} = read} ->
        provider = %{from(read) | sha256: sha256(bytes)}

        case {addresses_refused(provider), models_refused(provider)} do
          {[], []} ->
            provider

          {[], refused} ->
            raise ArgumentError,
                  "#{path} has more models, or longer titles, than a provider holds: " <>
                    inspect(refused)

          {refused, _models} ->
            raise ArgumentError,
                  "#{path} has an address that Apiary.Kinds.Endpoint refuses: " <>
                    inspect(refused)
        end

      {:ok, %Description{} = read} ->
        raise ArgumentError,
              "#{path} is not a data description of one model provider named #{file}: " <>
                "name #{inspect(read.name)}, program_version " <>
                "#{inspect(read.program_version)}, roles #{inspect(read.roles)}"

      {:error, reason} ->
        raise ArgumentError, "#{path} is refused: #{inspect(reason)}"
    end
  end

  @doc """
  address_settings/1 is the names of `provider`'s address settings, in the order the
  description first names them.
  """
  @spec address_settings(t) :: [String.t()]
  def address_settings(%__MODULE__{endpoint: endpoint, egress_hosts: egress_hosts}) do
    for(%{"setting" => name} <- [endpoint | egress_hosts], do: name) |> Enum.uniq()
  end

  @doc """
  setting_default/2 is the `default` the description gives the setting `name`:
  `{:ok, default}`, or `:error` for a setting with none.
  """
  @spec setting_default(t, String.t()) :: {:ok, term} | :error
  def setting_default(%__MODULE__{description: %Description{document: document}}, name) do
    case get_in(document, ["settings", "properties", name]) do
      %{"default" => default} -> {:ok, default}
      _none -> :error
    end
  end

  # The URL endpoint and every default of an address setting that the endpoint rule
  # refuses, each with its refusal.
  defp addresses_refused(%__MODULE__{} = provider) do
    endpoint = if is_binary(provider.endpoint), do: [provider.endpoint], else: []

    defaults =
      for name <- address_settings(provider),
          {:ok, default} <- [setting_default(provider, name)],
          do: default

    for address <- endpoint ++ defaults,
        {:error, refusal} <- [Endpoint.check(address)],
        do: {address, refusal}
  end

  # What `Apiary.Connections.ProviderModel` holds: 200 models, each title 1 to 128
  # characters.
  defp models_refused(%__MODULE__{models: models}) do
    count = if length(models) > 200, do: [{:models, length(models)}], else: []
    count ++ for(%{"title" => t} <- models, String.length(t) > 128, do: {:title, t})
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp from(%Description{document: document} = description) do
    role = get_in(document, ["roles", "model_provider"])

    %__MODULE__{
      name: description.name,
      title: description.title,
      description: description,
      endpoint: Map.fetch!(role, "endpoint"),
      formats: Map.fetch!(role, "formats"),
      hosts: Map.get(role, "hosts", []),
      auth: Map.fetch!(role, "auth"),
      key_variables: Map.fetch!(role, "key_variables"),
      models: Map.fetch!(role, "models"),
      egress_hosts: Map.get(document, "egress_hosts", [])
    }
  end
end
