defmodule Apiary.Integrations.Description do
  @moduledoc """
  Description reads an integration's `description.json`, what its program's `describe`
  prints and its release publishes, and checks it as the integrations contract says
  (`priv/contract/integration/description.schema.json`, vendored from qoryai/integrations
  at the commit in `.integration-contract-ref`).

  `parse/1` validates the bytes with JSV against the vendored schema, its patterns read as
  the contract reads them (`Apiary.Kinds.Pattern`), then checks what the schema cannot:

    * every secret, a top-level property marked `writeOnly`, has a `title` that is not
      only white space, a `<name>_file` beside it, is listed by a role, and carries an
      `x-secret-name` only of the contract's grammar, used by no other secret; no setting
      but a secret carries one, and no secret is nested in another setting;
    * every name a role lists in `settings` is a top-level setting, never a secret's
      `<name>_file`, and its `required` is a subset of its `settings`;
    * no host of the credential role's `hosts` is covered by the tool role's `serves`, or
      the other way round, and the tool's `mcp` URL is https, with no userinfo, port or
      fragment, on a host its `serves` covers;
    * every `argument` compiles;
    * no tool `placeholders` name is one a placeholder may not take
      (`Apiary.Kinds.Placeholders`): `placeholder_conflict`.

  A refusal is `{:error, {:description_invalid, problems}}` or
  `{:error, {:placeholder_conflict, names}}`.

  **Publisher.** `publisher` is required, as the contract defines it: a `name`, and a
  `url` that may be absent. Nothing verifies it: a page shows it beside the source's
  owner (`Apiary.Integrations.Source.owner/1`), and never instead of it. For a URL source
  it is the one name the page has beside the host.

  The description also bounds what a workspace stores for its connection:
  `check_settings/2` for the plain settings, and `check_argument/2` for the argument.
  """

  alias Apiary.Kinds.{CanonicalJSON, Hosts, Pattern, Placeholders, Schema}

  @enforce_keys [:name, :title, :program_version, :document]
  defstruct name: nil,
            title: nil,
            about: nil,
            publisher: nil,
            domains: nil,
            program_version: nil,
            roles: [],
            ways: [],
            secrets: [],
            settings: [],
            document: nil

  @typedoc """
  A description, read: the integration's `name`, `title`, `about` (its `description`),
  `publisher` (a map with `name` and maybe `url`), `domains`, `program_version`,
  every role it names, the `ways` it offers (`credential` and `tool`, the roles the runner
  starts; a connection is used in `credential` alone, `Apiary.Connections`), its secrets
  (each `name`, `title` and `secret_name`, its `x-secret-name`), the names of its plain
  settings, and the decoded document.
  """
  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t(),
          about: String.t() | nil,
          publisher: %{required(String.t()) => String.t()},
          domains: [String.t()] | nil,
          program_version: String.t(),
          roles: [String.t()],
          ways: [String.t()],
          secrets: [%{name: String.t(), title: String.t(), secret_name: String.t() | nil}],
          settings: [String.t()],
          document: map
        }

  @ways ~w(credential tool)
  @secret_name ~r/\A[A-Z][A-Z0-9_]{0,127}\z/
  @settings_max 65_536

  @doc """
  ways/0 is the roles the runner starts, the ways a description may offer: `credential` and
  `tool`.
  """
  @spec ways() :: [String.t()]
  def ways, do: @ways

  @doc """
  parse/1 reads and checks the bytes of a `description.json`: `{:ok, description}`, or
  `{:error, {code, details}}` (see the module's documentation).
  """
  @spec parse(binary) :: {:ok, t} | {:error, {atom, term}}
  def parse(bytes) when is_binary(bytes) do
    with {:ok, document} <- decode(bytes),
         :ok <- schema(document),
         [] <- problems(document),
         [] <- placeholder_conflicts(document) do
      {:ok, read(document)}
    else
      {:error, reason} ->
        {:error, reason}

      [{:placeholder_conflict, _} | _] = conflicts ->
        {:error, {:placeholder_conflict, Enum.map(conflicts, &elem(&1, 1))}}

      problems when is_list(problems) ->
        {:error, {:description_invalid, problems}}
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

  defp known_roles(document),
    do: for({role, body} <- document["roles"], role in @ways, do: {role, body})

  defp problems(document) do
    properties = properties(document)
    secrets = secret_names(document)
    roles = known_roles(document)
    listed = roles |> Enum.flat_map(fn {_role, body} -> body["settings"] end) |> MapSet.new()

    secret_problems =
      for name <- secrets,
          problem <- [
            if(not titled?(properties[name]), do: {:secret_without_title, name}),
            if(not Map.has_key?(properties, name <> "_file"), do: {:secret_without_file, name}),
            if(name not in listed, do: {:secret_not_listed, name})
          ],
          problem,
          do: problem

    secret_name_problems =
      Enum.concat([
        for(
          {name, %{"x-secret-name" => _}} <- properties,
          name not in secrets,
          do: {:secret_name_on_plain, name}
        ),
        for(
          {name, %{"x-secret-name" => value}} <- properties,
          name in secrets,
          not (is_binary(value) and Regex.match?(@secret_name, value)),
          do: {:secret_name_invalid, name}
        ),
        duplicates(for {_name, %{"x-secret-name" => value}} <- properties, do: value)
        |> Enum.map(&{:secret_name_twice, &1})
      ])

    nested =
      for {name, property} <- properties, nested_secret?(property), do: {:secret_nested, name}

    role_problems =
      for {role, body} <- roles,
          problem <- role_problems(role, body, properties, secrets),
          do: problem

    secret_problems ++ secret_name_problems ++ nested ++ role_problems ++ host_problems(document)
  end

  defp titled?(%{"title" => title}) when is_binary(title), do: String.trim(title) != ""
  defp titled?(_property), do: false

  defp duplicates(values),
    do: values |> Enum.frequencies() |> Enum.filter(&(elem(&1, 1) > 1)) |> Enum.map(&elem(&1, 0))

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

  defp role_problems(role, body, properties, secrets) do
    settings = body["settings"]
    required = body["required"] || []
    files = Enum.map(secrets, &(&1 <> "_file"))

    Enum.concat([
      for(
        name <- settings,
        not Map.has_key?(properties, name),
        do: {:role_setting_unknown, role, name}
      ),
      for(name <- settings, name in files, do: {:role_lists_file, role, name}),
      for(name <- required, name not in settings, do: {:role_requires_unlisted, role, name}),
      for(
        pattern <- List.wrap(body["argument"]),
        match?({:error, _}, Pattern.compile(pattern)),
        do: {:argument_invalid, role}
      )
    ])
  end

  defp host_problems(document) do
    hosts = get_in(document, ["roles", "credential", "hosts"]) || []
    tool = get_in(document, ["roles", "tool"])
    serves = (tool && tool["serves"]) || []

    overlaps =
      for host <- hosts,
          serve <- serves,
          Hosts.overlap?(host, serve),
          do: {:hosts_overlap, host, serve}

    overlaps ++ mcp_problems(tool, serves)
  end

  defp mcp_problems(%{"mcp" => mcp}, serves) when is_binary(mcp) do
    case URI.parse(mcp) do
      %URI{scheme: "https", host: host, userinfo: nil, fragment: nil, port: 443} = uri
      when is_binary(host) and host != "" ->
        explicit_port? = String.match?(mcp, ~r{\Ahttps://[^/]*:})

        cond do
          explicit_port? ->
            [{:mcp_invalid, mcp}]

          not Enum.any?(serves, &(&1 == host or Hosts.covers?(&1, host))) ->
            [{:mcp_not_served, uri.host}]

          true ->
            []
        end

      _other ->
        [{:mcp_invalid, mcp}]
    end
  end

  defp mcp_problems(_tool, _serves), do: []

  defp placeholder_conflicts(document) do
    names = get_in(document, ["roles", "tool", "placeholders"]) || []
    for name <- Placeholders.conflicts(names), do: {:placeholder_conflict, name}
  end

  defp read(document) do
    properties = properties(document)
    secrets = secret_names(document) |> Enum.sort()
    files = Enum.map(secrets, &(&1 <> "_file"))

    %__MODULE__{
      name: document["name"],
      title: document["title"],
      about: document["description"],
      publisher: document["publisher"],
      domains: document["domains"],
      program_version: document["program_version"],
      roles: document["roles"] |> Map.keys() |> Enum.sort(),
      ways: Enum.filter(@ways, &Map.has_key?(document["roles"], &1)),
      secrets:
        for name <- secrets do
          %{
            name: name,
            title: properties[name]["title"],
            secret_name: properties[name]["x-secret-name"]
          }
        end,
      settings:
        properties |> Map.keys() |> Enum.reject(&(&1 in secrets or &1 in files)) |> Enum.sort(),
      document: document
    }
  end

  @doc """
  check_settings/2 checks `settings`, a workspace's plain settings for a connection of
  `description`, before they are stored:

    * a secret, which a connection links to a stored secret and never holds as a
      setting, a secret's `<name>_file`, a path on the node that a server never sends,
      and a name no role of the description lists are refused,
      `integration_settings_not_allowed`;
    * the settings must be valid against the description's `settings` schema without its
      secrets, `integration_settings_invalid`;
    * their canonical JSON is at most 65536 bytes, `integration_settings_too_large`.

  `:ok`, or `{:error, {code, names_or_errors}}`.
  """
  @spec check_settings(t, term) :: :ok | {:error, {atom, term}}
  def check_settings(%__MODULE__{} = description, settings) when is_map(settings) do
    secrets = Enum.map(description.secrets, & &1.name)
    files = Enum.map(secrets, &(&1 <> "_file"))

    listed =
      description.document
      |> known_roles()
      |> Enum.flat_map(fn {_role, body} -> body["settings"] end)

    refused =
      for {name, _value} <- settings,
          name in secrets or name in files or name not in listed,
          do: name

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

  defp plain_schema(description, settings) do
    secrets = Enum.map(description.secrets, & &1.name)

    schema =
      Map.update(description.document["settings"], "properties", %{}, &Map.drop(&1, secrets))

    with {:ok, root} <- Schema.build(schema),
         :ok <- Schema.validate(settings, root) do
      :ok
    else
      {:error, errors} -> {:error, {:integration_settings_invalid, errors}}
    end
  end

  @doc """
  check_argument/2 checks the argument a connection of `description` is started with:
  nil, or matched whole by every role of the description that has an `argument` pattern.
  `:ok`, or `{:error, {:integration_argument_not_allowed, roles}}`.
  """
  @spec check_argument(t, String.t() | nil) :: :ok | {:error, {atom, [String.t()]}}
  def check_argument(%__MODULE__{}, nil), do: :ok

  def check_argument(%__MODULE__{document: document}, argument) when is_binary(argument) do
    refusing =
      for {role, %{"argument" => pattern}} <- known_roles(document),
          not Pattern.whole_match?(pattern, argument),
          do: role

    if refusing == [], do: :ok, else: {:error, {:integration_argument_not_allowed, refusing}}
  end

  @doc "hosts/1 is every host pattern of `description`'s credential `hosts` and tool `serves`."
  @spec hosts(t) :: [String.t()]
  def hosts(%__MODULE__{document: document}) do
    (get_in(document, ["roles", "credential", "hosts"]) || []) ++
      (get_in(document, ["roles", "tool", "serves"]) || [])
  end
end
