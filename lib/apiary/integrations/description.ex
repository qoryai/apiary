defmodule Apiary.Integrations.Description do
  @moduledoc """
  Description reads an integration's `description.json` and checks it as the
  integrations contract says (`priv/contract/integration/description.schema.json`,
  vendored from the contract at the commit `.integration-contract-ref` names). The
  contract has two forms of a description. The program form, with a `program_version`,
  is what the `describe` command of an integration's program prints and the
  integration's release publishes. The data form, without a `program_version`, is a file of data that no program prints: its
  one role is `model_provider`, and no value of its settings has a member `writeOnly`.
  The contract's data descriptions of model providers are vendored under
  `priv/contract/integration/descriptions/`.

  `parse/1` refuses a document in which an object repeats a member, at any depth, the
  names compared once their escapes are read: Jason keeps the first value of a repeated
  name, and a reader that keeps the last would read another document. It then
  validates the decoded document with JSV against the vendored schema, its patterns read
  as the contract reads them (`Apiary.Kinds.Pattern`), once the document is within the
  limits below, and checks what the schema cannot:

    * every secret, a top-level property marked `writeOnly`, has a `<name>_file` beside
      it, and no secret is nested in another setting;
    * the credential role's `argument` compiles.

  A role other than `credential` is read as it is: the `source` and `model_provider`
  roles once the schema has checked their shapes, and, in the program form, a role the
  schema does not name whatever it holds, once its name matches the schema's pattern and
  its value is within the bounds. The schema refuses a data description with any role
  other than `model_provider`. A refusal is `{:error, {:description_invalid, problems}}`.

  A description of more than 262144 bytes (256 KiB), as `parse/1` is given it, is refused
  before it is decoded, `{:error, {:description_invalid, [:too_large]}}`: the schema's
  description bounds its raw bytes so, and only the bytes as they were sent can be
  measured, since an encoding of the decoded document writes its numbers and its
  whitespace otherwise.

  A description is refused before the schema when it holds a list of more than 1024
  entries, an object of more than 1024 members, more than 4096 values in all, a string of
  more than 16 KiB or more than 64 lists and objects nested in one another
  (`Apiary.Kinds.Bounds.within?/2`): `{:error, {:description_invalid, [{:schema,
  %{valid: false, limits: limits}}]}}`. The schema's keywords state three of these
  bounds, the entries of a list, the members of an object and the length of a string,
  this one in characters rather than bytes, and its description states the rest; a value
  past any of them is never given to JSV. Its `settings`, the schema `check_settings/2`
  builds from, is inside the description and so within the same limits.

  The description also bounds what a workspace stores for its connection:
  `check_settings/2` for the plain settings, and `check_argument/2` for the argument.
  """

  # The `source` role is the `factory` feature's, which the documentation leaves out. Of
  # it, four members are read out (`item_noun/1`, `items?/1`, `collection_noun/1`,
  # `access/1`): its words for one item and for many, `item_noun`, `one` and `other`, each
  # 1 to 32 characters: lower-case letters in words joined by single spaces or hyphens,
  # never a noun the schema keeps out (the `not` of `$defs.noun`); `items`, which, when
  # there, is `false`: the source reports collections and no items, and names no words for
  # them; its words for one collection and for many, `collection_noun`, `one` and `other`,
  # the same shape as `item_noun`'s, never such a noun either, beside `items: false` too;
  # and `access`, a prose line of 1 to 300 characters with no control characters, on how
  # to change, at the source, which collections the adapter reaches. The schema holds all
  # four to that.

  require Logger

  alias Apiary.Kinds.{
    Bounds,
    Budget,
    CanonicalJSON,
    Endpoint,
    Pattern,
    PatternMemory,
    RegexFormat,
    Schema,
    SettingsResolver
  }

  alias Apiary.Policy.Grammar

  @enforce_keys [:name, :title, :program_version, :document]
  defstruct name: nil,
            title: nil,
            about: nil,
            domains: nil,
            program_version: nil,
            roles: [],
            secrets: [],
            settings: [],
            item_noun: nil,
            items: true,
            collection_noun: nil,
            access: nil,
            document: nil

  @typedoc """
  A description, read: the integration's `name`, `title`, `about` (its `description`),
  `domains`, `program_version` (nil in the data form), every role it names, its secrets
  (each `name`, and `title`, the secret's title or else its name), the names of its plain
  settings, what its source role says (nil, and `items` true, without one), and the
  decoded document.
  """
  # Of the source role: its words for its items (`item_noun`, nil where it names none),
  # whether that source reports items (`items`, true without a source role), its words for
  # its collections (`collection_noun`, nil where it names none), and its line on how to
  # change which collections the adapter reaches (`access`, nil without a source role).
  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t(),
          about: String.t() | nil,
          domains: [String.t()] | nil,
          program_version: String.t() | nil,
          roles: [String.t()],
          secrets: [%{name: String.t(), title: String.t()}],
          settings: [String.t()],
          item_noun: item_noun | nil,
          items: boolean,
          collection_noun: collection_noun | nil,
          access: String.t() | nil,
          document: map
        }

  @typedoc "A source's words for one of its items and for many, as its description gives them."
  @type item_noun :: %{one: String.t(), other: String.t()}

  # A source's words for one collection and for many, as its description gives them.
  @typedoc false
  @type collection_noun :: %{one: String.t(), other: String.t()}

  @settings_max 65_536
  @max_bytes 262_144

  # The limits of a description, and of the plain settings checked against its schema,
  # before a schema is applied (see the module's documentation and `check_settings/2`).
  @limits [list: 1024, members: 1024, nodes: 4096, string: 16_384, depth: 64]
  @settings_limits [list: 1024, members: 1024, nodes: 4096, depth: 64]

  # The budget of the settings check, the build of the schema and the validation
  # (`Apiary.Kinds.Budget`): 5000000 reductions, 2097152 words of heap (16 MiB on a
  # 64-bit machine), and 10 s, a bound only on a check that runs away while it counts few
  # reductions. The reductions and the heap decide, and neither depends on the machine:
  # the same check does the same reductions on any machine running the same OTP release.
  # Measured, the binaries the process refers to counted with its heap: settings at the
  # limits above do 1486055 reductions, 3.4 times fewer than the budget, and pass within
  # 199216 words of heap; 1000 settings of 1000 properties, each against a pattern, 696940
  # reductions within 523394 words, 4 times fewer than the budget; 1000 settings of a
  # description of 257138 bytes, whose 1000 properties are each described in a string of
  # 215 bytes, 643064 reductions within 362281 words; the settings of the fixtures under
  # 7000 reductions. The slowest, the settings at the limits, took 527 ms
  # with 32 checks at once on one scheduler that a busy process shared. Every measured
  # attack passed the reductions or the heap within 320 ms. The budget is not larger:
  # backtracking patterns count about 17 million reductions a second where the rest of
  # the check counts about 100 million, so at 5000000 they take about 300 ms to stop,
  # while Connections holds the organisation's integrations lock
  # (`Apiary.Connections.lock/1`). So valid settings against an extreme schema are refused
  # by the cap, the same way on every run: a list of 1000 strings, each checked against
  # 200 alternative patterns, does 7857408 reductions. A compile for `"format": "regex"`
  # is charged in reductions (`Apiary.Kinds.RegexFormat`): the check of one such setting
  # of 15000 bytes does about 152000. These figures were measured before the patterns were
  # estimated (`@pattern_bytes`), which adds reductions: measured on OTP 29, the estimate
  # for 1000 settings, each against a pattern, did 138772, and the check of a setting of
  # 15000 bytes against `"format": "regex"`, with its estimate, 228189.
  @settings_budget [reductions: 5_000_000, heap_words: 2_097_152, ms: 10_000]

  # The most bytes the patterns of a settings check may hold once compiled, those of the
  # schema and the settings checked against `"format": "regex"`, by the estimates of
  # `Apiary.Kinds.PatternMemory`: 16 MiB, as much as the heap of the budget. Measured on
  # OTP 29: 1000 settings, each against `^[a-z0-9]{1,40}$`, are estimated at 1128000
  # bytes, 14.9 times fewer, and their compiled patterns hold about 219 bytes each; a
  # schema of 1950 patterns such as `(?:a){7900}b1` is estimated at 161740800 bytes, and
  # built, it took the node 126 MiB more memory.
  @pattern_bytes 16_777_216

  @doc """
  parse/1 reads and checks the bytes of a `description.json`: `{:ok, description}`, or
  `{:error, {code, details}}` (see the module's documentation).
  """
  @spec parse(binary) :: {:ok, t} | {:error, {atom, term}}
  def parse(bytes) when is_binary(bytes) do
    with :ok <- within_bytes(bytes),
         {:ok, document} <- decode(bytes),
         :ok <- schema(document),
         [] <- problems(document) do
      {:ok, read(document)}
    else
      {:error, reason} -> {:error, reason}
      problems when is_list(problems) -> {:error, {:description_invalid, problems}}
    end
  end

  @doc "max_bytes/0 is the most bytes of a description `parse/1` reads, 262144."
  @spec max_bytes() :: pos_integer
  def max_bytes, do: @max_bytes

  defp within_bytes(bytes) when byte_size(bytes) <= @max_bytes, do: :ok
  defp within_bytes(_bytes), do: {:error, {:description_invalid, [:too_large]}}

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
      item_noun: read_noun(get_in(document, ["roles", "source", "item_noun"])),
      items: get_in(document, ["roles", "source", "items"]) != false,
      collection_noun: read_noun(get_in(document, ["roles", "source", "collection_noun"])),
      access: get_in(document, ["roles", "source", "access"]),
      document: document
    }
  end

  defp read_noun(%{"one" => one, "other" => other}), do: %{one: one, other: other}
  defp read_noun(nil), do: nil

  @doc """
  item_noun/1 is the source role's words for one of its items and for many,
  `%{one: one, other: other}`, or nil when it names none, as for a description with no
  source role.
  """
  @spec item_noun(t) :: item_noun | nil
  def item_noun(%__MODULE__{item_noun: item_noun}), do: item_noun

  @doc """
  items?/1 says whether the source of `description` reports items: false when its source
  role says `items: false`; true otherwise.
  """
  @spec items?(t) :: boolean
  def items?(%__MODULE__{items: items}), do: items

  # collection_noun/1 is the source role's words for one of its collections and for many,
  # `%{one: one, other: other}`, or nil when it names none, as for a description with no
  # source role.
  @doc false
  @spec collection_noun(t) :: collection_noun | nil
  def collection_noun(%__MODULE__{collection_noun: collection_noun}), do: collection_noun

  @doc """
  access/1 is the source role's `access` line, how to change, at the source, what the
  adapter reaches, as the integration's words, or nil for a description with no source
  role.
  """
  @spec access(t) :: String.t() | nil
  def access(%__MODULE__{access: access}), do: access

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
      `settings`, else `integration_settings_invalid` with `%{valid: false}`, as for a
      schema that JSV cannot build: JSV's errors are not returned. Before that schema is
      applied, settings that hold a list of more than 1024 entries, an object of more
      than 1024 members, more than 4096 values in all or more than 64 lists and objects
      nested in one another are refused so, with `%{valid: false, limits: limits}`: the
      schema comes from the description and need bound none of them. For the same reason
      the schema is built and the settings validated in another process
      (`Apiary.Kinds.Budget`), within 5000000 reductions, the runtime's count of its
      work, and 2097152 words of heap (16 MiB on a 64-bit machine), the binaries the
      process refers to counted in it: a schema of a few references can make the work
      grow exponentially with their nesting. Settings whose check goes over that budget
      are refused as `integration_settings_invalid` with
      `%{valid: false, budget: :exceeded}`, and settings whose check fails with
      `%{valid: false, crashed: true}`. A compiled pattern is memory outside the heap,
      which that budget does not count, so before the schema is built the patterns it
      would compile are estimated (`Apiary.Kinds.PatternMemory.schema/1`), and so is each
      setting checked against `"format": "regex"` before it is compiled
      (`Apiary.Kinds.RegexFormat`): a check whose patterns would hold more than 16 MiB in
      all is refused the same way, as `%{valid: false, budget: :exceeded}`.

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

  # The settings check, in the budget's process. The patterns the build would compile are
  # estimated first, and a schema whose patterns would hold more than @pattern_bytes stops
  # the check before anything is compiled: `{:stopped, :patterns}`. What is left of
  # @pattern_bytes bounds the settings RegexFormat compiles, which stop the check the same
  # way. The answer leaves that process, so a refusal by the schema, or of a schema JSV
  # cannot build, is `%{valid: false}` alone: JSV's errors stay in the process and end
  # with it. They refer to the settings and the schema, and the message of an error about
  # a pattern, which `Schema.valid?/2` does not make, would copy that pattern. Settings
  # over the limits are never given to JSV.
  defp check(schema, settings) do
    schema = without_casts(schema)

    with :ok <- within_pattern_bytes(schema),
         {:ok, root} <-
           Schema.build(schema, resolver: SettingsResolver, formats: RegexFormat.formats()),
         {:limits, true} <- {:limits, Bounds.within?(settings, @settings_limits)},
         true <- valid?(settings, root) do
      :ok
    else
      {:stopped, reason} ->
        {:stopped, reason}

      {:limits, false} ->
        {:error,
         {:integration_settings_invalid, %{valid: false, limits: Map.new(@settings_limits)}}}

      _refused ->
        {:error, {:integration_settings_invalid, %{valid: false}}}
    end
  end

  defp within_budget(description, check) do
    case Budget.run(check, @settings_budget) do
      {:ok, {:stopped, reason}} -> stopped(description, reason)
      {:ok, result} -> result
      {:error, reason} -> stopped(description, reason)
    end
  end

  defp stopped(description, reason) do
    Logger.warning(
      "an integration's settings check was stopped name=#{description.name} " <>
        "program_version=#{description.program_version} reason=#{reason}"
    )

    {:error, {:integration_settings_invalid, budget_refusal(reason)}}
  end

  defp within_pattern_bytes(schema) do
    used = PatternMemory.schema(schema)

    if used <= @pattern_bytes,
      do: RegexFormat.pattern_bytes(used, @pattern_bytes),
      else: {:stopped, :patterns}
  end

  defp valid?(settings, root) do
    Schema.valid?(settings, root)
  catch
    :throw, {RegexFormat, :pattern_bytes} -> {:stopped, :patterns}
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

  defp budget_refusal(:crashed), do: %{valid: false, crashed: true}

  defp budget_refusal(over) when over in [:reductions, :heap, :time, :patterns],
    do: %{valid: false, budget: :exceeded}

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

  @doc """
  egress_hosts/2 is the hosts of `description`'s `egress_hosts`, the hosts that runs of
  the integration need to reach, for a connection with the plain settings `settings`:
  `{hosts, refused}`. Every host in `hosts` is exact (`Apiary.Policy.Grammar.exact_host?/1`),
  each once, in the order of the entries.

  A host entry is taken when it is exact; the schema at the pinned integrations commit
  refuses any other. A `{"setting": name}` entry is the host of that setting's address,
  or of the setting's `default` where `settings` has none. The address must pass the rule
  of `Apiary.Kinds.Endpoint`, and its host must be exact; otherwise the entry is left
  out, and `name` is in `refused`. A setting with no address and no `default` adds
  nothing to either list.
  """
  @spec egress_hosts(t, map) :: {[String.t()], [String.t()]}
  def egress_hosts(%__MODULE__{document: document}, settings) when is_map(settings) do
    read =
      for entry <- Map.get(document, "egress_hosts", []),
          do: egress_host(entry, document, settings)

    hosts = for {:ok, host} <- read, uniq: true, do: host
    refused = for {:refused, name} <- read, uniq: true, do: name
    {hosts, refused}
  end

  defp egress_host(host, _document, _settings) when is_binary(host) do
    if Grammar.exact_host?(host), do: {:ok, host}, else: :none
  end

  defp egress_host(%{"setting" => name}, document, settings) do
    address =
      case Map.fetch(settings, name) do
        {:ok, value} -> value
        :error -> setting_default(document, name)
      end

    with false <- is_nil(address),
         {:ok, host} <- Endpoint.host(address),
         true <- Grammar.exact_host?(host) do
      {:ok, host}
    else
      true -> :none
      _refused -> {:refused, name}
    end
  end

  defp egress_host(_entry, _document, _settings), do: :none

  # The `default` of the setting `name`, read only from a property schema that is an
  # object: JSON Schema also takes `true` or `false` as a property's schema.
  defp setting_default(document, name) do
    case get_in(document, ["settings", "properties"]) do
      %{^name => %{} = property} -> Map.get(property, "default")
      _other -> nil
    end
  end
end
