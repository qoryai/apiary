defmodule Apiary.Integrations.Description do
  @moduledoc """
  Description reads an integration's `description.json`, what its program's `describe`
  prints and its release publishes, and checks it as the integrations contract says
  (`priv/contract/integration/description.schema.json`, vendored from the contract at the
  commit in `.integration-contract-ref`).

  `parse/1` validates the bytes with JSV against the vendored schema, its patterns read as
  the contract reads them (`Apiary.Kinds.Pattern`), once the decoded document is within
  the limits below, then checks what the schema cannot:

    * every secret, a top-level property marked `writeOnly`, has a `<name>_file` beside
      it, and no secret is nested in another setting;
    * the credential role's `argument` compiles.

  A role other than `credential` is read as it is and never refused. A refusal is
  `{:error, {:description_invalid, problems}}`.

  The schema bounds no list, and its `settings` and `roles` take objects of any members.
  So a description is refused before the schema when it holds a list of more than 1024
  entries, an object of more than 1024 members, more than 4096 values in all, a string of
  more than 16 KiB or more than 64 lists and objects nested in one another
  (`Apiary.Kinds.Bounds.within?/2`): `{:error, {:description_invalid, [{:schema,
  %{valid: false, limits: limits}}]}}`. Its `settings`, the schema `check_settings/2`
  builds from, is inside the description and so within the same limits.

  The description also bounds what a workspace stores for its connection:
  `check_settings/2` for the plain settings, and `check_argument/2` for the argument.
  """

  alias Apiary.Kinds.{
    Bounds,
    Budget,
    CanonicalJSON,
    Pattern,
    RegexFormat,
    Schema,
    SettingsResolver
  }

  require Logger

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
  the secret's title or else its name), the names of its plain settings, and the decoded document.
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

  # The limits of a description, and of the plain settings checked against its schema,
  # before a schema is applied (see the module's documentation and `check_settings/2`).
  @limits [list: 1024, members: 1024, nodes: 4096, string: 16_384, depth: 64]
  @settings_limits [list: 1024, members: 1024, nodes: 4096, depth: 64]

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
    case Schema.validate(document, root(), @limits) do
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
    * their canonical JSON is at most 65536 bytes, `integration_settings_too_large`;
    * they hold no list of more than 1024 entries, no object of more than 1024 members,
      no more than 4096 values in all and no more than 64 lists and objects nested in one
      another (`Apiary.Kinds.Bounds.within?/2`), else `integration_settings_invalid` with
      `%{valid: false, limits: limits}`: the schema comes from the description and need
      bound none of them;
    * each setting must be valid against its property's schema in the description's
      `settings`, else `integration_settings_invalid` with `%{valid: false}`, as for a
      schema that JSV cannot build: JSV's errors are not returned. A few references in
      that schema can make the work of the check grow exponentially with their nesting,
      which the limits do not bound, so the schema is built and the settings validated
      in another process (`Apiary.Kinds.Budget`), within 5000000 reductions, the
      runtime's count of its work, and 2097152 words of heap (16 MiB on a 64-bit
      machine), the binaries the process refers to counted in it. A check that goes over
      that budget is refused as `integration_settings_invalid` with
      `%{valid: false, budget: :exceeded}`, and one that fails with
      `%{valid: false, crashed: true}`.

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

      not Bounds.within?(settings, @settings_limits) ->
        {:error,
         {:integration_settings_invalid, %{valid: false, limits: Map.new(@settings_limits)}}}

      true ->
        # The process is given copies of the schema it builds and of the settings, never
        # the description: a string of the description can be a part of its bytes, which
        # the budget would count in full for each such string (`Apiary.Kinds.Budget`).
        # The copies are linear in the schema, a part of the description, and so bounded
        # by the bytes a release's description may have (`Apiary.Integrations`), and in
        # the settings, at most 65536 bytes as canonical JSON.
        schema = copy(plain_schema(description, settings))
        settings = copy(settings)
        within_budget(description, fn -> check(schema, settings) end)
    end
  end

  def check_settings(%__MODULE__{}, _settings),
    do: {:error, {:integration_settings_invalid, :not_an_object}}

  # The budget of the settings check, the build of the schema and the validation
  # (`Apiary.Kinds.Budget`): 5000000 reductions and 2097152 words of heap, which decide,
  # and 10 s, a bound only on a check that runs while it counts few reductions.
  # Measured on OTP 29: valid settings of 4096 values, two lists and an object of 1024
  # entries each, the entries of one list checked against 32 patterns, and 64 lists and
  # objects deep, do 1486870 reductions, 3.3 times fewer than the budget; 1000 settings,
  # each against a pattern, 642740; a setting of 15000 bytes against
  # `"format": "regex"`, its compile charged in reductions (`Apiary.Kinds.RegexFormat`),
  # 151978. The valid settings of 4096 values, in a description of 261772 bytes whose
  # definitions hold 1000 strings of 234 bytes, pass within 545508 words of heap, the
  # binaries the process refers to counted, 3.8 times fewer than the budget. Without the
  # budget, a schema that refers twice to the next level at each of 20 levels does
  # 157253942.
  @settings_budget [reductions: 5_000_000, heap_words: 2_097_152, ms: 10_000]

  defp within_budget(description, check) do
    case Budget.run(check, @settings_budget) do
      {:ok, result} ->
        result

      {:error, reason} ->
        Logger.warning(
          "an integration's settings check was stopped name=#{description.name} " <>
            "program_version=#{description.program_version} reason=#{reason}"
        )

        {:error, {:integration_settings_invalid, budget_refusal(reason)}}
    end
  end

  defp budget_refusal(:crashed), do: %{valid: false, crashed: true}

  defp budget_refusal(over) when over in [:reductions, :heap, :time],
    do: %{valid: false, budget: :exceeded}

  # A connection holds a part of the settings document, its plain settings, so each is
  # checked against its own property's schema alone: a rule across settings, such as the
  # top level's `required` or a `oneOf` between a secret and its `<name>_file`, is the
  # program's to check once the document is whole. The definitions a property refers to
  # stay where its references point.
  defp plain_schema(description, settings) do
    document = description.document["settings"]

    document
    |> Map.take(["$schema", "$id", "$defs", "definitions"])
    |> Map.merge(%{
      "type" => "object",
      "properties" => Map.take(document["properties"] || %{}, Map.keys(settings))
    })
  end

  # `term` with every binary in it, the keys of its maps too, copied, so that none is a
  # part of a larger binary.
  defp copy(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {copy(key), copy(value)} end)

  defp copy(list) when is_list(list), do: Enum.map(list, &copy/1)
  defp copy(binary) when is_binary(binary), do: :binary.copy(binary)
  defp copy(other), do: other

  # The settings check, in the budget's process.
  defp check(schema, settings) do
    # The answer leaves the budget's process, so a refusal is `%{valid: false}` alone.
    # JSV's errors stay in that process and end with it: they refer to the settings and
    # the schema, and the message of an error about a pattern, which `Schema.valid?/2`
    # does not make, would copy that pattern.
    with {:ok, root} <-
           schema
           |> without_casts()
           |> Schema.build(resolver: SettingsResolver, formats: RegexFormat.formats()),
         true <- Schema.valid?(settings, root) do
      :ok
    else
      _refused -> {:error, {:integration_settings_invalid, %{valid: false}}}
    end
  end

  # JSV builds a `jsv-cast` or `x-jsv-cast` keyword by loading the module it names, which
  # `atoms: false` and `cast: false` do not stop, so a settings schema loses both keys from
  # every object in it, at any depth. A `$ref` can point anywhere in the document, even into
  # a `const` or under `properties`, and JSV builds what it points at, so no object keeps
  # them: a setting named so loses its schema, and a value that holds one loses it.
  @casts ~w(jsv-cast x-jsv-cast)

  defp without_casts(map) when is_map(map),
    do: for({key, value} <- map, key not in @casts, into: %{}, do: {key, without_casts(value)})

  defp without_casts(list) when is_list(list), do: Enum.map(list, &without_casts/1)
  defp without_casts(other), do: other

  @doc """
  check_argument/2 checks the argument a connection of `description` stores:
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
