defmodule Apiary.Kinds.ServiceDefinition do
  @moduledoc """
  ServiceDefinition checks a service definition: the one source of a service's hosts, the
  paths its value is set on, how the value is sent (`auth`) and the secrets it needs
  (`declares`). A built-in definition (`Apiary.Kinds.Services`) and a workspace's own
  (`Apiary.Connections.ServiceDefinition`) are checked alike.

  A definition is valid when it passes `priv/schemas/service-definition.schema.json`,
  whose `auth` is the runner contract's `auth.schema.json` (vendored under
  `priv/contract/`) with its `secret` required and a username of at most 128 characters,
  and whose grammar is the contract's for a service item, and the rules the schema cannot
  say, each with the contract's code:

    * every declared id is unique, and `auth.secret` and `auth.username_secret` are
      declared ids (`declaration_unknown`);
    * no host is a refused name, such as `localhost` (`connection_host_invalid`);
    * `auth.header` is not a header the contract refuses (`connection_header_reserved`);
    * no declaration's `name` is a variable a placeholder may not take
      (`placeholder_conflict`), and no two declarations name the same variable.

  `validate/1` answers the definition as given, or every problem found, each a code and
  where.
  """

  alias Apiary.Kinds.{CanonicalJSON, Headers, Hosts, Placeholders, Schema}

  @typedoc "A problem with a definition: a code, and the member it is about."
  @type problem :: {atom, String.t()}

  @doc """
  validate/1 checks the decoded definition `definition`: `{:ok, definition}`, or
  `{:error, problems}`, `definition_invalid` for what the schema refuses, with JSV's
  errors logged by the caller if it wants them.
  """
  @spec validate(term) :: {:ok, map} | {:error, [problem]}
  def validate(definition) do
    with :ok <- schema(definition),
         [] <- problems(definition) do
      {:ok, definition}
    else
      problems when is_list(problems) -> {:error, problems}
      {:error, problems} -> {:error, problems}
    end
  end

  @doc "encode/1 is a valid definition's canonical JSON, the bytes stored and digested."
  @spec encode(map) :: String.t()
  def encode(definition), do: CanonicalJSON.encode!(definition)

  @doc "digest/1 is the lowercase hexadecimal SHA-256 of a definition's canonical JSON."
  @spec digest(map) :: String.t()
  def digest(definition), do: definition |> encode() |> CanonicalJSON.sha256()

  defp schema(definition) do
    case Schema.validate(definition, root()) do
      :ok -> :ok
      {:error, _errors} -> {:error, [{:definition_invalid, ""}]}
    end
  end

  @doc false
  def root, do: Schema.file!(["schemas", "service-definition.schema.json"])

  defp problems(%{"declares" => declares, "auth" => auth, "hosts" => hosts}) do
    ids = Enum.map(declares, & &1["id"])
    names = Enum.flat_map(declares, &List.wrap(&1["name"]))

    Enum.concat([
      if(ids == Enum.uniq(ids), do: [], else: [{:declaration_unknown, "declares"}]),
      for(
        key <- ~w(secret username_secret),
        id = auth[key],
        id not in ids,
        do: {:declaration_unknown, "auth." <> key}
      ),
      for(host <- hosts, Hosts.refused_name?(host), do: {:connection_host_invalid, host}),
      for(
        header <- List.wrap(auth["header"]),
        Headers.refused?(header),
        do: {:connection_header_reserved, header}
      ),
      for(name <- Placeholders.conflicts(names), do: {:placeholder_conflict, name}),
      if(names == Enum.uniq(names), do: [], else: [{:placeholder_conflict, "declares"}])
    ])
  end
end
