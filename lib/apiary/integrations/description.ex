defmodule Apiary.Integrations.Description do
  @moduledoc """
  Description reads an integration's `description.json`, what its program's `describe`
  prints and its release publishes, and checks it as the integrations contract says
  (`priv/contract/integration/description.schema.json`, vendored from the contract at the
  commit `.integration-contract-ref` names for it).

  `parse/1` refuses a document in which an object repeats a member, at any depth, the
  names compared once their escapes are read: Jason keeps the first value of a repeated
  name, and a reader that keeps the last would read another document. It then
  validates the bytes with JSV against the vendored schema, its patterns read as the
  contract reads them (`Apiary.Kinds.Pattern`), once the decoded document is within the
  limits below, and checks what the schema cannot:

    * every secret, a top-level property marked `writeOnly`, has a `<name>_file` beside
      it, and no secret is nested in another setting;
    * the credential role's `argument` compiles.

  A role other than `credential` is read as it is and never refused. A refusal is
  `{:error, {:description_invalid, problems}}`.

  The schema bounds no list, and its `settings` and `roles` take objects of any members.
  So a description is refused before the schema when it holds a list of more than 1024
  entries, an object of more than 1024 members, more than 4096 values in all, a string of
  more than 16 KiB or more than 64 lists and objects nested in one another
  (`Apiary.Kinds.Bounds.within?/2`).

  The description also bounds what a workspace stores for its connection:
  `check_settings/2` for the plain settings, and `check_argument/2` for the argument.
  """

  require Logger

  alias Apiary.Kinds.{Budget, CanonicalJSON, Pattern, Schema}

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

  # The budget of the settings check, the build of the schema and the validation
  # (`Apiary.Kinds.Budget`): 100 ms and 2097152 words of heap, 16 MiB on a 64-bit machine.
  # Measured in two runs of 50 checks each, idle and with every scheduler busy: settings
  # at the limits above took 13.5 ms to 18.5 ms at the median and at most 24 ms; 1000
  # settings of 1000 properties 4.7 ms to 5.7 ms at the median and at most 22 ms, with
  # 439685 words of heap, the most of any measured; the settings of the fixtures under
  # 2 ms. Connections checks settings while it holds the organisation's integrations lock
  # (`Apiary.Connections.lock/1`), which keeps the budget small.
  @settings_budget [ms: 100, heap_words: 2_097_152]

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

  # The bytes are decoded twice: once keeping every member of each object in order, to
  # find a name held twice, then as maps, which keep only one value of a name, for the
  # rest of the checks.
  defp decode(bytes) do
    case Jason.decode(bytes, objects: :ordered_objects) do
      {:ok, %Jason.OrderedObject{} = ordered} ->
        if repeats_member?([ordered]),
          do: {:error, {:description_invalid, [:member_repeated]}},
          else: {:ok, Jason.decode!(bytes)}

      {:ok, _other} ->
        {:error, {:description_invalid, [:not_an_object]}}

      {:error, _error} ->
        {:error, {:description_invalid, [:not_json]}}
    end
  end

  # Whether an object of the ordered decode, at any depth, holds a member name twice. The
  # values still to read are kept in a list and each function calls the next last, so
  # nesting of any depth runs in constant stack.
  defp repeats_member?([]), do: false

  defp repeats_member?([%Jason.OrderedObject{values: members} | rest]),
    do: members_repeat?(members, %{}, rest)

  defp repeats_member?([list | rest]) when is_list(list), do: repeats_member?(list ++ rest)
  defp repeats_member?([_scalar | rest]), do: repeats_member?(rest)

  defp members_repeat?([], _seen, rest), do: repeats_member?(rest)

  defp members_repeat?([{name, value} | members], seen, rest) do
    if is_map_key(seen, name),
      do: true,
      else: members_repeat?(members, Map.put(seen, name, true), [value | rest])
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
    * each setting must be valid against its property's schema in the description's
      `settings`, `integration_settings_invalid`; before that schema is applied, settings
      that hold a list of more than 1024 entries, an object of more than 1024 members,
      more than 4096 values in all or more than 64 lists and objects nested in one
      another are refused so: the schema comes from the description and need bound none
      of them. For the same reason the schema is built and the settings validated in
      another process, within 100 ms and 16 MiB of heap: a schema of a few references
      can make the work grow exponentially with their nesting. Settings whose check
      goes over that budget, or fails, are refused as `integration_settings_invalid`.

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

    check = fn ->
      with {:ok, root} <- Schema.build(schema),
           do: Schema.validate(settings, root, @settings_limits)
    end

    case Budget.run(check, @settings_budget) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, errors}} ->
        {:error, {:integration_settings_invalid, errors}}

      {:error, reason} ->
        Logger.warning(
          "an integration's settings check was stopped name=#{description.name} " <>
            "program_version=#{description.program_version} reason=#{reason}"
        )

        {:error, {:integration_settings_invalid, budget_refusal(reason)}}
    end
  end

  defp budget_refusal(:crashed), do: %{valid: false, crashed: true}
  defp budget_refusal(over) when over in [:time, :heap], do: %{valid: false, budget: :exceeded}

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
