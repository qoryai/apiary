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
  #      YAML document, a mapping at the top.
  #   2. A key the run contract's harness section does not take, such as a machine key
  #      (`runtime`, `model`) or `git`, `env`, `worktree`, `exports` or `target`.
  #   3. A base given by name alone, `extends: {stack: <name>}` with neither `git` nor
  #      `path`.
  #   4. Each `git` address of the base and of the modules' sources: user information
  #      (the error shows the address without it), the scp form `<user>@<host>:<path>`,
  #      and any address that does not start with `https://`.
  #   5. The run contract's `harness_section` (`documents.schema.json` beside this file,
  #      vendored from the integrations contract at the commit in `.contract-ref`),
  #      validated with JSV: git sources and exports only, no `{path}` source, no module
  #      by name alone, no `link`. A bare `{git, ref}` source, the root of a remote
  #      source, is allowed.
  #
  # ## The run's stack
  #
  # The run contract pinned at test/fixtures/contract/run/v1 still takes a run's `stack`,
  # a stack reference `<url>#<ref>:<path>`, and not the document. `reference/1` is the
  # reference of a document that is a base and nothing else, `extends: {git, ref}` with
  # an optional `path`, and nil for any other document.
  @moduledoc false

  @behaviour JSV.Resolver

  alias Apiary.Contract
  alias Apiary.Harnesses.Reader

  @schema_path Path.join(__DIR__, "documents.schema.json")
  @external_resource @schema_path
  @schema @schema_path |> File.read!() |> Jason.decode!()
  @schema_id @schema["$id"]

  # The keys of the run contract's harness section.
  @keys ~w(name description extends modules bind extensions)

  @typedoc "A changeset error on `harness`: a message and its values."
  @type error :: {String.t(), keyword}

  @doc false
  # errors/1 is the refusals of `text` under the save rules of the moduledoc: `[]`, or
  # one `{message, values}`.
  @spec errors(String.t()) :: [error]
  def errors(text) when is_binary(text) do
    case Reader.document(text) do
      {:ok, section} ->
        with :ok <- keys(section),
             :ok <- base(section),
             :ok <- sources(section),
             :ok <- schema(section),
             do: []

      {:error, reason} ->
        [unreadable(reason)]
    end
  catch
    {__MODULE__, error} -> [error]
  end

  defp unreadable(:too_large), do: {"is larger than %{limit} bytes", limit: Reader.max_bytes()}

  defp unreadable(:too_deep),
    do: {"nests more than %{limit} mappings and lists", limit: Reader.max_depth()}

  defp unreadable(:alias),
    do: {"uses a YAML anchor or alias, which a harness document may not", []}

  defp unreadable(:several_documents), do: {"contains more than one YAML document", []}
  defp unreadable(:key_not_text), do: {"has a key that is not text", []}
  defp unreadable({:repeated_key, key}), do: {"repeats the key %{key}", key: key}
  defp unreadable(:not_a_number), do: {"has a number that is infinite or not a number", []}
  defp unreadable(:invalid_yaml), do: {"is not valid YAML", []}

  defp unreadable(_not_a_mapping),
    do: {"is not a harness section: write its keys, such as extends, at the top level", []}

  defp keys(section) do
    case Enum.find(Map.keys(section) |> Enum.sort(), &(&1 not in @keys)) do
      nil ->
        :ok

      key ->
        refuse(
          "may not contain %{key}: a harness document takes name, description, extends, " <>
            "modules, bind and extensions",
          key: key
        )
    end
  end

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

  defp address(git) do
    cond do
      user_information?(git) ->
        refuse(
          "remove the user name and password from %{source}: " <>
            "a harness source address may not contain a credential",
          source: without_user_information(git)
        )

      not String.starts_with?(git, "https://") ->
        refuse(
          "write %{source} as an https address: " <>
            "Qory Apiary fetches harness sources over https only",
          source: git
        )

      true ->
        :ok
    end
  end

  # An address with a scheme whose authority has `@`: user information.
  @user_information ~r{\A([A-Za-z][A-Za-z0-9+.-]*://)[^/?#]*@}

  defp user_information?(git), do: Regex.match?(@user_information, git)
  defp without_user_information(git), do: Regex.replace(@user_information, git, "\\1")

  defp schema(section) do
    case JSV.validate(section, root(), cast: false) do
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

  # The validator of the run contract's harness section, built once per node: a compiled
  # pattern cannot be kept in a module attribute.
  defp root do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        root =
          JSV.build!(%{"$ref" => @schema_id <> "#/$defs/harness_section"},
            resolver: __MODULE__,
            formats: true
          )

        :persistent_term.put(__MODULE__, root)
        root

      root ->
        root
    end
  end

  @impl JSV.Resolver
  def resolve(@schema_id, _opts), do: {:ok, @schema}
  def resolve(url, _opts), do: {:error, {:not_vendored, url}}

  @doc false
  # reference/1 is the stack reference of `text` for a run's `stack`: the document's
  # base, `<git>#<ref>:<path>` with `.` for the root, when the document is that base
  # and nothing else and the reference is valid under the run contract; nil otherwise.
  @spec reference(String.t() | nil) :: String.t() | nil
  def reference(text) when is_binary(text) do
    with {:ok, %{"extends" => %{"git" => git, "ref" => ref} = base} = section}
         when map_size(section) == 1 and is_binary(git) and is_binary(ref) <-
           Reader.document(text),
         [] <- Map.keys(base) -- ["git", "ref", "path"],
         path when is_binary(path) <- Map.get(base, "path", "."),
         reference = "#{git}##{ref}:#{path}",
         true <- Contract.Stack.reference?(reference) do
      reference
    else
      _other -> nil
    end
  end

  def reference(nil), do: nil
end
