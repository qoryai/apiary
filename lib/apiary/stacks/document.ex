defmodule Apiary.Stacks.Document do
  # A harness document as a stack row keeps it: the contents of the `harness` section of
  # qory's format, written in YAML, as the person wrote it. Read with
  # `Apiary.Harnesses.Reader`. Pure: nothing here touches the database or logs.
  #
  # ## The save rules
  #
  # `errors/1` checks a document in this order, and returns the first refusal:
  #
  #   1. The reader's limits: 64 KiB, 16 nested collections, no anchor or alias, one
  #      YAML document, a mapping at the top, and the reader's budget of work and heap
  #      for the read. A run's harness walk (`Apiary.Harnesses.Walk`) reads the document
  #      again with `check/1`, under the same budget, and takes the check and the
  #      section from that one read. A document whose read does within about 5 million
  #      reductions of the budget, the work of one 50 ms interval between two reads of
  #      the reductions, or whose read runs past the reader's backstop of 10 seconds,
  #      may get a different answer there than at the save.
  #   2. A key the run contract's harness section does not take, such as a machine key
  #      (`runtime`, `model`) or `git`, `env`, `worktree`, `exports` or `target`.
  #   3. The kind of document: one with `extends` has no `workflows`, and one without
  #      `extends` has `modules`. The run contract's schema refuses both too, in words
  #      that name neither key.
  #   4. A base given by name alone, `extends: {stack: <name>}` with neither `git` nor
  #      `path`.
  #   5. Each `git` address of the base and of the modules' sources: a whitespace or
  #      control character, user information, any address that does not start with
  #      `https://`, the scp form `<user>@<host>:<path>` included, a query or a
  #      fragment, and any other address that is not `https://`, a host, an optional
  #      port and an optional path, at most 2,560 characters, as a stack reference's
  #      address was before harness documents. An error shows an address without
  #      anything from its first `?` or `#`, and without anything before its last `@`
  #      but a scheme at its start: `https://user@host/r?q` shows as `https://host/r`.
  #      When a `?` or `#` comes before the last `@`, the error shows "the address"
  #      instead. So an error shows no user name, password or query, whatever the
  #      address's shape. Then each text `ref` of those sources (`ref_error/1`).
  #   6. The run contract's `harness_section` (`documents.schema.json` beside this file,
  #      vendored from the integrations contract at the commit in `.contract-ref`),
  #      validated with JSV: git sources and exports only, no `{path}` source, no module
  #      by name alone, no `link`. A bare `{git, ref}` source, the root of a remote
  #      source, is allowed. A document with `extends` extends that base and has no
  #      `workflows`; one without `extends` defines a stack: it lists at least one module
  #      and may contain `workflows`.
  @moduledoc false

  @behaviour JSV.Resolver

  alias Apiary.Harnesses.Reader

  @schema_path Path.join(__DIR__, "documents.schema.json")
  @external_resource @schema_path
  @schema @schema_path |> File.read!() |> Jason.decode!()
  @schema_id @schema["$id"]

  # The keys of the run contract's harness section.
  @keys ~w(name description extends modules bind extensions workflows)

  @typedoc "A changeset error on `harness`: a message and its values."
  @type error :: {String.t(), keyword}

  @doc false
  # errors/1 is the refusals of `text` under the save rules of the moduledoc: `[]`, or
  # one `{message, values}`.
  @spec errors(String.t()) :: [error]
  def errors(text) when is_binary(text) do
    case check(text) do
      {:ok, _section} -> []
      {:error, error} -> [error]
    end
  end

  @doc false
  # check/1 is `text` read once and checked under the save rules of the moduledoc:
  # `{:ok, section}`, the section that read, or `{:error, {message, values}}`, the first
  # refusal. A caller that needs the section uses it, and does not read `text` again.
  @spec check(String.t()) :: {:ok, map} | {:error, error}
  def check(text) when is_binary(text) do
    case Reader.document(text) do
      {:ok, section} ->
        with :ok <- keys(section),
             :ok <- kind(section),
             :ok <- base(section),
             :ok <- sources(section),
             :ok <- schema(section),
             do: {:ok, section}

      {:error, reason} ->
        {:error, unreadable(reason)}
    end
  catch
    {__MODULE__, error} -> {:error, error}
  end

  @doc false
  # unreadable/1 is the save check's words for a document the reader refuses
  # (`Apiary.Harnesses.Reader`), `{message, values}`.
  @spec unreadable(term) :: error
  def unreadable(:control_character),
    do: {"contains a control character, which a harness document may not", []}

  def unreadable(:too_complex),
    do:
      {"takes more work to read than a harness document may: " <>
         "write long lists as block lists, with one - item per line", []}

  def unreadable(:unsupported_type),
    do:
      {"uses a YAML type a harness document does not take, such as !!binary: " <>
         "write each value as text, a number, true, false or null", []}

  def unreadable(:too_large), do: {"is larger than %{limit} bytes", limit: Reader.max_bytes()}

  def unreadable(:too_deep),
    do: {"nests more than %{limit} mappings and lists", limit: Reader.max_depth()}

  def unreadable(:alias),
    do: {"uses a YAML anchor or alias, which a harness document may not", []}

  def unreadable(:several_documents), do: {"contains more than one YAML document", []}
  def unreadable(:key_not_text), do: {"has a key that is not text", []}
  def unreadable({:repeated_key, key}), do: {"repeats the key %{key}", key: key}
  def unreadable(:not_a_number), do: {"has a number that is infinite or not a number", []}
  def unreadable(:invalid_yaml), do: {"is not valid YAML", []}

  def unreadable(_not_a_mapping),
    do: {"is not a harness section: write its keys, such as extends, at the top level", []}

  defp keys(section) do
    case Enum.find(Map.keys(section) |> Enum.sort(), &(&1 not in @keys)) do
      nil ->
        :ok

      key ->
        refuse(
          "may not contain %{key}: a harness document takes name, description, extends, " <>
            "modules, bind, extensions and workflows",
          key: key
        )
    end
  end

  defp kind(%{"extends" => _base, "workflows" => _workflows}),
    do:
      refuse(
        "remove workflows or extends: " <>
          "a harness document that extends a stack takes that stack's workflows",
        []
      )

  defp kind(section)
       when not is_map_key(section, "extends") and not is_map_key(section, "modules"),
       do:
         refuse(
           "add extends or at least one module: " <>
             "a harness document extends a stack, or defines one with at least one module",
           []
         )

  defp kind(_section), do: :ok

  defp base(%{"extends" => %{"stack" => name} = base})
       when is_binary(name) and not is_map_key(base, "git") and not is_map_key(base, "path"),
       do:
         refuse(
           "give the base %{name} as a git source and an export: " <>
             "extends: {git: <https address>, ref: <ref>, stack: %{name}}",
           name: name
         )

  defp base(_section), do: :ok

  defp sources(section) do
    section
    |> addresses()
    |> Enum.each(&address/1)

    for ref <- refs(section), error = ref_error(ref), do: throw({__MODULE__, error})
    :ok
  end

  # The text `ref`s of the base and of the modules' sources, in order.
  defp refs(section) do
    base =
      case section do
        %{"extends" => %{"ref" => ref}} when is_binary(ref) -> [ref]
        _other -> []
      end

    modules =
      case section do
        %{"modules" => modules} when is_list(modules) ->
          for %{"source" => %{"ref" => ref}} when is_binary(ref) <- modules, do: ref

        _other ->
          []
      end

    base ++ modules
  end

  # Namespaces under `refs/` other than branches and tags that forges and code review
  # servers write, often for anyone who opens a pull request or uploads a change. git
  # resolves a short name under `refs/` first: `git fetch` takes `pull/1/head` as
  # `refs/pull/1/head`, and `changes/34/1234/2` as `refs/changes/34/1234/2`.
  @other_namespaces ~w(pull pull-requests merge-requests changes remotes notes keep-around
                       pipelines environments)

  @doc false
  # ref_error/1 is the refusal of `ref`, a harness source's version, nil for one that is
  # `HEAD`, a branch or tag name, `refs/heads/<name>`, `refs/tags/<name>` or a full
  # commit id. Refused: every other ref under `refs/`, such as `refs/pull/1/head`; a
  # short name whose first part is one of `@other_namespaces`, such as `pull/1/head`;
  # and a ref with an empty part, or a part that starts with `.`, such as `..`, so that
  # no path steps around those checks. People without write access to a repository can
  # change some of those refs. The save rules and the harness walk both call it.
  @spec ref_error(String.t()) :: error | nil
  def ref_error(ref) when is_binary(ref) do
    parts = String.split(ref, "/")

    allowed =
      not Enum.any?(parts, &(&1 == "" or String.starts_with?(&1, "."))) and
        case parts do
          ["refs", kind, _name | _rest] when kind in ["heads", "tags"] -> true
          ["refs" | _rest] -> false
          [first, _second | _rest] -> first not in @other_namespaces
          [_one] -> true
        end

    unless allowed do
      {"write the ref %{ref} as HEAD, a branch or tag name, refs/heads/<name>, " <>
         "refs/tags/<name> or a full commit id: people without write access can change " <>
         "other refs, such as a pull request's", ref: ref}
    end
  end

  # The `git` addresses of the base and of the modules' sources, in order, where the
  # document has them as text.
  defp addresses(section) do
    base =
      case section do
        %{"extends" => %{"git" => git}} when is_binary(git) -> [git]
        _other -> []
      end

    modules =
      case section do
        %{"modules" => modules} when is_list(modules) ->
          for %{"source" => %{"git" => git}} when is_binary(git) <- modules, do: git

        _other ->
          []
      end

    base ++ modules
  end

  @doc false
  # harness_sources/1 is the harness sources `text` refers to, in document order: the base
  # (`extends`), then the `source` of each module. Each is a map with the keys the
  # document writes among `git`, `ref` and one of `path`, `stack` and `module`, as text
  # and unchanged (`Apiary.Harnesses.source()`). An entry without text `git` and `ref`,
  # with more than one of the three narrowing keys, or with a narrowing key that is not
  # text, is left out. `[]` for nil, for text that does not read and for a document that
  # is not a mapping. The sources are read as written, not checked: `errors/1` checks.
  @spec harness_sources(String.t() | nil) :: [Apiary.Harnesses.source()]
  def harness_sources(text) when is_binary(text) do
    with {:ok, section} when is_map(section) <- Reader.document(text) do
      modules =
        case section do
          %{"modules" => modules} when is_list(modules) ->
            for %{"source" => source} <- modules, do: source

          _other ->
            []
        end

      [Map.get(section, "extends") | modules]
      |> Enum.flat_map(&harness_source/1)
    else
      _unreadable -> []
    end
  end

  def harness_sources(_not_text), do: []

  defp harness_source(%{"git" => git, "ref" => ref} = source)
       when is_binary(git) and is_binary(ref) do
    narrowing = Map.take(source, ["path", "stack", "module"])

    if map_size(narrowing) <= 1 and Enum.all?(narrowing, fn {_key, value} -> is_binary(value) end),
      do: [Map.merge(narrowing, %{"git" => git, "ref" => ref})],
      else: []
  end

  defp harness_source(_other), do: []

  # Any whitespace or control character: a git address has none.
  @space_or_control ~r/[\s\x{00}-\x{1F}\x{7F}-\x{9F}]/u

  # An address with a scheme whose authority has `@`: user information.
  @user_information ~r{\A[A-Za-z][A-Za-z0-9+.-]*://[^/?#]*@}

  # The https address a stack reference had before harness documents: `https://`, a
  # host, an optional port and an optional path, with no user information, no query and
  # no fragment. The host is a name, which may contain the percent-encodings `%80` to
  # `%FF` and `%25`, or an IPv6 address in brackets.
  @max_address 2560
  @dec_octet "(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
  @ipv4 "#{@dec_octet}\\.#{@dec_octet}\\.#{@dec_octet}\\.#{@dec_octet}"
  @h16 "[0-9A-Fa-f]{1,4}"
  @ls32 "(?:#{@h16}:#{@h16}|#{@ipv4})"
  # RFC 3986's IPv6address, its nine forms in its order.
  @ipv6 Enum.join(
          [
            "(?:#{@h16}:){6}#{@ls32}",
            "::(?:#{@h16}:){5}#{@ls32}",
            "(?:#{@h16})?::(?:#{@h16}:){4}#{@ls32}",
            "(?:(?:#{@h16}:){0,1}#{@h16})?::(?:#{@h16}:){3}#{@ls32}",
            "(?:(?:#{@h16}:){0,2}#{@h16})?::(?:#{@h16}:){2}#{@ls32}",
            "(?:(?:#{@h16}:){0,3}#{@h16})?::#{@h16}:#{@ls32}",
            "(?:(?:#{@h16}:){0,4}#{@h16})?::#{@ls32}",
            "(?:(?:#{@h16}:){0,5}#{@h16})?::#{@h16}",
            "(?:(?:#{@h16}:){0,6}#{@h16})?::"
          ],
          "|"
        )
  @host_name "(?:[A-Za-z0-9._~!$&'()*+,;=-]|%(?:[89A-Fa-f][0-9A-Fa-f]|25))+"
  @port "(?::(?:0{0,4}[1-9]|0{0,3}[1-9][0-9]|0{0,2}[1-9][0-9]{2}|0?[1-9][0-9]{3}|" <>
          "[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])?)?"
  @url_path "(?:/(?:[A-Za-z0-9._~!$&'()*+,;=:@/-]|%[0-9A-Fa-f]{2})*)?"
  # `:dollar_endonly` makes `$` match only at the end, not before a final newline.
  @https_address Regex.compile!(
                   "^https://(?:#{@host_name}|\\[(?:#{@ipv6})\\])#{@port}#{@url_path}$",
                   [:dollar_endonly]
                 )

  defp address(git) do
    cond do
      Regex.match?(@space_or_control, git) ->
        refuse(
          "write %{source} as an https address with no space or control character: " <>
            "Qory Apiary fetches harness sources over https only",
          source: shown(git)
        )

      Regex.match?(@user_information, git) ->
        refuse(
          "remove the user name and password from %{source}: " <>
            "a harness source address may not contain a credential",
          source: shown(git)
        )

      not String.starts_with?(git, "https://") ->
        refuse(
          "write %{source} as an https address: " <>
            "Qory Apiary fetches harness sources over https only",
          source: shown(git)
        )

      String.contains?(git, ["?", "#"]) ->
        refuse(
          "write %{source} with no query (?) and no fragment (#): a harness source " <>
            "address is https://, a host, an optional port and an optional path",
          source: shown(git)
        )

      String.length(git) > @max_address or not Regex.match?(@https_address, git) ->
        refuse(
          "write %{source} as https://, a host, an optional port and an optional path: " <>
            "Qory Apiary fetches harness sources over https only",
          source: shown(git)
        )

      true ->
        :ok
    end
  end

  @doc false
  # source_error/2 is the refusal of `source`, a remote source of a harness file or of a
  # `qory-stack.yaml`, which no save check reads, by the save rules of a document's
  # sources: its `git` address and its `ref` as step 5 checks them, then step 6's
  # definition of a base (`kind` `:base`, `harness_base`) or of a module's source
  # (`:module`, `harness_source`). nil, or one `{message, values}`.
  @spec source_error(map, :base | :module) :: error | nil
  def source_error(%{} = source, kind) when kind in [:base, :module] do
    case source do
      %{"git" => git} when is_binary(git) -> address(git)
      _other -> :ok
    end

    with %{"ref" => ref} when is_binary(ref) <- source,
         {_message, _values} = error <- ref_error(ref),
         do: throw({__MODULE__, error})

    schema(source, if(kind == :base, do: "harness_base", else: "harness_source"))
    nil
  catch
    {__MODULE__, error} -> error
  end

  @doc false
  # user_information?/1 is whether `git` is an address with a scheme whose authority has
  # `@`: a user name, and maybe a password.
  @spec user_information?(String.t()) :: boolean
  def user_information?(git) when is_binary(git), do: Regex.match?(@user_information, git)

  @doc false
  # shown/1 is `git` as an error shows it, whatever its shape, with no user name,
  # password or query: everything from its first `?` or `#` is left out, as a query may
  # contain a credential, and so is everything before its last `@`, but a scheme at its
  # start. When a `?` or `#` comes before the last `@`, the part after that `@` may be a
  # query or the host after a password that contains `?` or `#`, so the error shows "the
  # address" alone. Each control character and each whitespace but a space becomes
  # U+FFFD.
  @spec shown(String.t()) :: String.t()
  def shown(git) do
    cut =
      case :binary.match(git, ["?", "#"]) do
        {cut, 1} -> cut
        :nomatch -> byte_size(git)
      end

    shown =
      case :binary.matches(git, "@") do
        [] ->
          binary_part(git, 0, cut)

        ats ->
          {at, 1} = List.last(ats)

          if at < cut do
            scheme =
              case Regex.run(~r{\A[A-Za-z][A-Za-z0-9+.-]*://}, git) do
                [scheme] -> scheme
                nil -> ""
              end

            scheme <> binary_part(git, at + 1, cut - at - 1)
          else
            "the address"
          end
      end

    Regex.replace(~r/[^\S ]|[\x{00}-\x{1F}\x{7F}-\x{9F}]/u, shown, "\u{FFFD}")
  end

  @doc false
  # repository/1 is the repository path of a harness address, such as `acme/web-harness`
  # for `https://code.example.com/acme/web-harness.git`; else the address as `shown/1`
  # writes it, without `https://`. "" for a value that is no string.
  @spec repository(term) :: String.t()
  def repository(git) when is_binary(git) do
    with %URI{host: host, path: "/" <> _ = path} when is_binary(host) and host != "" <-
           URI.parse(git),
         trimmed when trimmed != "" <-
           path |> String.trim("/") |> String.replace_suffix(".git", "") do
      trimmed
    else
      _other -> git |> shown() |> String.replace_prefix("https://", "")
    end
  end

  def repository(_git), do: ""

  defp schema(section, definition \\ "harness_section") do
    case JSV.validate(section, root(definition), cast: false) do
      {:ok, _section} ->
        :ok

      {:error, error} ->
        %{details: [%{instanceLocation: place, errors: [%{message: rule} | _]} | _]} =
          JSV.normalize_error(error)

        refuse("does not follow the harness format at %{place}: %{rule}",
          place: place,
          rule: rule
        )
    end
  end

  defp refuse(message, values), do: throw({__MODULE__, {message, values}})

  # The validator of a definition of the run contract, the harness section or a source,
  # built once per node: a compiled pattern cannot be kept in a module attribute.
  defp root(definition) do
    case :persistent_term.get({__MODULE__, definition}, nil) do
      nil ->
        root =
          JSV.build!(%{"$ref" => @schema_id <> "#/$defs/" <> definition},
            resolver: __MODULE__,
            formats: true
          )

        :persistent_term.put({__MODULE__, definition}, root)
        root

      root ->
        root
    end
  end

  @impl JSV.Resolver
  def resolve(@schema_id, _opts), do: {:ok, @schema}
  def resolve(url, _opts), do: {:error, {:not_vendored, url}}
end
