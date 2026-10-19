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
  `description` is the description as `parse/1` returns it.
  """

  alias Apiary.Integrations.Description

  @enforce_keys [:name, :title, :description]
  defstruct name: nil,
            title: nil,
            description: nil,
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
  other than `model_provider`, or when its `name` differs from the file's name without
  `.json`. `Apiary.Kinds.Providers` calls it when the application is compiled, so a
  description that fails stops the compile.
  """
  @spec load!(Path.t()) :: t
  def load!(path) do
    file = Path.basename(path, ".json")

    case path |> File.read!() |> Description.parse() do
      {:ok, %Description{name: ^file, program_version: nil, roles: ["model_provider"]} = read} ->
        from(read)

      {:ok, %Description{} = read} ->
        raise ArgumentError,
              "#{path} is not a data description of one model provider named #{file}: " <>
                "name #{inspect(read.name)}, program_version " <>
                "#{inspect(read.program_version)}, roles #{inspect(read.roles)}"

      {:error, reason} ->
        raise ArgumentError, "#{path} is refused: #{inspect(reason)}"
    end
  end

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
