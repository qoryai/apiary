defmodule Apiary.Integrations.Description do
  @moduledoc """
  Description reads an integration's `description.json`, what its program's `describe`
  prints and its release publishes, and checks it as the integrations contract says
  (`priv/contract/integration/description.schema.json`, vendored from the contract at the
  commit in `.integration-contract-ref`).

  `parse/1` validates the bytes with JSV against the vendored schema, its patterns read as
  the contract reads them (`Apiary.Kinds.Pattern`), then checks what the schema cannot:

    * every secret, a top-level property marked `writeOnly`, has a `<name>_file` beside
      it, and no secret is nested in another setting;
    * the credential role's `argument` compiles.

  A role other than `credential` is read as it is and never refused. A refusal is
  `{:error, {:description_invalid, problems}}`.

  The description also bounds what a workspace stores for its connection:
  `check_settings/2` for the plain settings, and `check_argument/2` for the argument.
  """

  alias Apiary.Kinds.{CanonicalJSON, Pattern, Schema}

  @enforce_keys [:name, :title, :program_version, :document]
  defstruct name: nil,
            title: nil,
            about: nil,
            domains: nil,
            program_version: nil,
            roles: [],
            secrets: [],
            settings: [],
            document: nil

  @typedoc """
  A description, read: the integration's `name`, `title`, `about` (its `description`),
  `domains`, `program_version`, every role it names, its secrets (each `name`, and `title`,
  its own or its name), the names of its plain settings, and the decoded document.
  """
  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t(),
          about: String.t() | nil,
          domains: [String.t()] | nil,
          program_version: String.t(),
          roles: [String.t()],
          secrets: [%{name: String.t(), title: String.t()}],
          settings: [String.t()],
          document: map
        }

  @settings_max 65_536

  @doc """
  parse/1 reads and checks the bytes of a `description.json`: `{:ok, description}`, or
  `{:error, {code, details}}` (see the module's documentation).
  """
  @spec parse(binary) :: {:ok, t} | {:error, {atom, term}}
  def parse(bytes) when is_binary(bytes) do
    with {:ok, document} <- decode(bytes),
         :ok <- schema(document),
         [] <- problems(document) do
      {:ok, read(document)}
    else
      {:error, reason} -> {:error, reason}
      problems when is_list(problems) -> {:error, {:description_invalid, problems}}
    end
  end

  defp decode(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{} = document} -> {:ok, document}
      {:ok, _other} -> {:error, {:description_invalid, [:not_an_object]}}
      {:error, _error} -> {:error, {:description_invalid, [:not_json]}}
    end
  end

  defp schema(document) do
    case Schema.validate(document, root()) do
      :ok -> :ok
      {:error, errors} -> {:error, {:description_invalid, [{:schema, errors}]}}
    end
  end

  @doc false
  def root do
    Schema.file!(["contract", "integration", "description.schema.json"])
  end

  defp properties(document), do: get_in(document, ["settings", "properties"]) || %{}

  defp secret?(%{"writeOnly" => true}), do: true
  defp secret?(_property), do: false

  defp secret_names(document),
    do: for({name, property} <- properties(document), secret?(property), do: name)

  defp problems(document) do
    properties = properties(document)

    without_file =
      for name <- secret_names(document),
          not Map.has_key?(properties, name <> "_file"),
          do: {:secret_without_file, name}

    nested =
      for {name, property} <- properties, nested_secret?(property), do: {:secret_nested, name}

    argument =
      for pattern <- List.wrap(get_in(document, ["roles", "credential", "argument"])),
          match?({:error, _}, Pattern.compile(pattern)),
          do: {:argument_invalid, "credential"}

    without_file ++ nested ++ argument
  end

  defp nested_secret?(%{} = schema) do
    Enum.any?(schema, fn
      {_key, %{"writeOnly" => true}} ->
        true

      {_key, %{} = sub} ->
        nested_secret?(sub)

      {_key, list} when is_list(list) ->
        Enum.any?(list, &(is_map(&1) and (secret?(&1) or nested_secret?(&1))))

      _ ->
        false
    end)
  end

  defp nested_secret?(_schema), do: false

  defp read(document) do
    properties = properties(document)
    secrets = secret_names(document) |> Enum.sort()
    files = Enum.map(secrets, &(&1 <> "_file"))

    %__MODULE__{
      name: document["name"],
      title: document["title"],
      about: document["description"],
      domains: document["domains"],
      program_version: document["program_version"],
      roles: document["roles"] |> Map.keys() |> Enum.sort(),
      secrets: for(name <- secrets, do: %{name: name, title: title(properties[name], name)}),
      settings:
        properties |> Map.keys() |> Enum.reject(&(&1 in secrets or &1 in files)) |> Enum.sort(),
      document: document
    }
  end

  defp title(%{"title" => title}, name) when is_binary(title),
    do: if(String.trim(title) == "", do: name, else: title)

  defp title(_property, name), do: name

  @doc """
  check_settings/2 checks `settings`, a workspace's plain settings for a connection of
  `description`, before they are stored:

    * every name must be one of its plain settings, a top-level setting that is neither
      a secret nor a secret's `<name>_file`, else `integration_settings_not_allowed`: a
      connection never holds a secret, and a `<name>_file` is a path on the node that a
      server never sends;
    * each setting must be valid against its own property's schema in the description's
      `settings`, `integration_settings_invalid`;
    * their canonical JSON is at most 65536 bytes, `integration_settings_too_large`.

  `:ok`, or `{:error, {code, names_or_errors}}`.
  """
  @spec check_settings(t, term) :: :ok | {:error, {atom, term}}
  def check_settings(%__MODULE__{} = description, settings) when is_map(settings) do
    refused = for {name, _value} <- settings, name not in description.settings, do: name

    cond do
      refused != [] ->
        {:error, {:integration_settings_not_allowed, Enum.sort(refused)}}

      byte_size(CanonicalJSON.encode!(settings)) > @settings_max ->
        {:error, {:integration_settings_too_large, @settings_max}}

      true ->
        plain_schema(description, settings)
    end
  end

  def check_settings(%__MODULE__{}, _settings),
    do: {:error, {:integration_settings_invalid, :not_an_object}}

  # A connection holds a part of the settings document, its plain settings, so each is
  # checked against its own property's schema alone: a rule across settings, such as the
  # top level's `required` or a `oneOf` between a secret and its `<name>_file`, is the
  # program's to check once the document is whole. The definitions a property refers to
  # stay where its references point.
  defp plain_schema(description, settings) do
    document = description.document["settings"]

    schema =
      document
      |> Map.take(["$schema", "$id", "$defs", "definitions"])
      |> Map.merge(%{
        "type" => "object",
        "properties" => Map.take(document["properties"] || %{}, Map.keys(settings))
      })

    with {:ok, root} <- Schema.build(schema),
         :ok <- Schema.validate(settings, root) do
      :ok
    else
      {:error, errors} -> {:error, {:integration_settings_invalid, errors}}
    end
  end

  @doc """
  check_argument/2 checks the argument a connection of `description` is started with:
  nil, or matched whole by the credential role's `argument` pattern.
  `:ok`, or `{:error, {:integration_argument_not_allowed, ["credential"]}}`.
  """
  @spec check_argument(t, String.t() | nil) :: :ok | {:error, {atom, [String.t()]}}
  def check_argument(%__MODULE__{}, nil), do: :ok

  def check_argument(%__MODULE__{} = description, argument) when is_binary(argument) do
    case argument_pattern(description) do
      nil -> :ok
      pattern -> if Pattern.whole_match?(pattern, argument), do: :ok, else: refused()
    end
  end

  defp refused, do: {:error, {:integration_argument_not_allowed, ["credential"]}}

  @doc "argument_pattern/1 is the credential role's `argument` pattern, or nil when it has none."
  @spec argument_pattern(t) :: String.t() | nil
  def argument_pattern(%__MODULE__{document: document}),
    do: get_in(document, ["roles", "credential", "argument"])

  @doc "hosts/1 is every host pattern of `description`'s credential `hosts`."
  @spec hosts(t) :: [String.t()]
  def hosts(%__MODULE__{document: document}),
    do: get_in(document, ["roles", "credential", "hosts"]) || []
end
