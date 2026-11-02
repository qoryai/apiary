defmodule Apiary.Processes.Export do
  @moduledoc """
  Writes a workspace's process as a `process.yaml`, the file a factory's module has
  (`priv/contract/harness/v1/process.schema.json`), so that a person can commit it to a
  harness repository as a template. `Apiary.Processes.export/1` is the entry. It checks no
  access, as `Apiary.Processes.current/1` checks none, and it writes no audit entry.

  ## The keys

  `apiVersion`, `name`, `summary`, `description`, `type`, `stack`, `process` and
  `artifact_types`, in this order:

    * `name` is the workspace's name, at most 60 code points. A character of several code
      points that crosses the limit goes whole.
    * `summary` and `description` are the texts of the workspace type
      (`Apiary.Processes.type_texts/1`). A text that is missing, blank, or outside the
      rules of the schema and of `Apiary.Harnesses.Reader` is replaced by a line with the
      workspace's name. A stored text can pass a save and still be replaced here:
      `Apiary.Processes.TypeTemplates` counts words with `String.split/1`, which keeps
      no-break spaces inside a word, and it does not check for control characters.
    * `stack` is the stack the base of the workspace's harness choice extends
      (Apiary.Stacks.choice/1), else `Apiary.Organisations.Workspace.qory_stack/1`.
    * `process` is the current version's document. Each gate that lists people is written
      with `approvers: members`, because the list has user ids of this instance.
    * `artifact_types` lists each standard type the workspace shows, by name alone, less
      the types no workspace can hide, then each custom type's definition.

  ## The YAML

  Core has a YAML reader only, so this module writes block YAML, with one rule for the
  whole file: every string, a mapping's key included, is a double-quoted scalar, and every
  integer, boolean and null is plain. A mapping inside `process` or a `json_schema` has
  sorted keys, so two exports of one version are the same bytes. A `json_schema` is one
  line of flow JSON. An empty mapping is `{}` and an empty list is `[]`. A key whose written
  form is over 1,000 bytes is an explicit key, `? "key"` then `: value` in a block and
  `{? "key" : value}` in flow, because YAML limits an implicit key to 1,024 characters, and
  yaml.v3, qory's reader, then fails on the whole file.

  A double-quoted scalar here is also a JSON string. Its escapes are `\\"`, `\\\\`, `\\n`,
  `\\r`, `\\t` and `\\uXXXX`, which YAML 1.1 defines in section 5.6 and YAML 1.2 in
  section 5.7. `\\uXXXX` covers the code points these YAML versions do not allow in a
  file, or read as a line break: C0, DEL, C1, U+2028, U+2029, U+FEFF, U+FFFE and U+FFFF.
  Every other character is written as its UTF-8 bytes. A character above U+FFFF has no
  `\\u` escape, since a YAML reader does not join two surrogates into one character.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  alias Apiary.{Artifacts, Processes, Stacks}
  alias Apiary.Artifacts.Type
  alias Apiary.Harnesses.Reader
  alias Apiary.Organisations.Workspace
  alias Apiary.Processes.{TypeTemplate, TypeTemplates, Version}
  alias Apiary.Stacks.Stack

  @api_version "qory.dev/v1alpha1"

  # The most code points of `name`, as process.schema.json counts them.
  @name_limit 60

  # The most bytes of a key's written form, quotes and escapes included, on one line with
  # its value. An escape counts as written, so a key over this is explicit before its
  # characters reach YAML's limit of 1,024.
  @implicit_key_bytes 1_000

  @doc """
  file/1 is the bytes of the `process.yaml` of `workspace`, from its current version.
  """
  @spec file(%Workspace{}) :: binary
  def file(%Workspace{} = workspace) do
    %Version{document: document} = Processes.current(workspace)
    {summary, description} = texts(workspace)

    IO.iodata_to_binary(
      entries(
        [
          {"apiVersion", @api_version},
          {"name", name(workspace.name)},
          {"summary", summary},
          {"description", description},
          {"type", workspace.type},
          {"stack", stack(workspace)},
          {"process", without_people(document)},
          {"artifact_types", artifact_types(workspace)}
        ],
        0,
        ""
      )
    )
  end

  @doc """
  lists_people?/1 is whether a gate of `version` lists people, which the file writes as
  all members.
  """
  @spec lists_people?(Version.t()) :: boolean
  def lists_people?(%Version{document: document}),
    do: Enum.any?(document["stages"], &is_map(get_in(&1, ["gate", "approvers"])))

  ## The keys

  # Trimmed first as well: a name of spaces and then text would leave nothing.
  defp name(name), do: name |> String.trim() |> cut() |> String.trim()

  # At most `@name_limit` code points, of whole graphemes. A name whose first grapheme has
  # more than the limit is cut inside it, because the file needs a name.
  defp cut(name) do
    kept =
      name
      |> String.graphemes()
      |> Enum.reduce_while({[], 0}, fn grapheme, {kept, count} ->
        count = count + length(String.codepoints(grapheme))

        if count > @name_limit,
          do: {:halt, {kept, count}},
          else: {:cont, {[grapheme | kept], count}}
      end)
      |> elem(0)

    case kept do
      [] -> name |> String.codepoints() |> Enum.take(@name_limit) |> Enum.join()
      kept -> kept |> Enum.reverse() |> Enum.join()
    end
  end

  defp texts(%Workspace{} = workspace) do
    fallback = gettext("Exported from the workspace %{name}.", name: workspace.name)

    texts =
      case TypeTemplates.newest(workspace.type) do
        nil -> %{}
        version -> Processes.type_texts(version)
      end

    {text(texts[:summary], :summary, fallback), text(texts[:description], :description, fallback)}
  end

  defp text(value, text, fallback), do: if(fits?(value, text), do: value, else: fallback)

  defp fits?(nil, _text), do: false

  # The rules of process.schema.json, where `\S` excludes every Unicode space, as it does
  # in this regular expression, and the control characters of `Apiary.Harnesses.Reader`.
  defp fits?(value, text) do
    words = length(Regex.scan(~r/\S+/u, value))

    words > 0 and length(String.codepoints(value)) <= TypeTemplate.limits()[text] and
      (text != :description or words <= TypeTemplate.word_limit()) and
      not Reader.control_character?(value)
  end

  defp stack(%Workspace{} = workspace) do
    with %Stack{harness: harness} when is_binary(harness) <- Stacks.choice(workspace),
         {:ok, %{"extends" => %{"stack" => stack}}} when is_binary(stack) <-
           Reader.document(harness) do
      stack
    else
      _no_stack_name -> Workspace.qory_stack(workspace)
    end
  end

  defp without_people(%{"stages" => stages} = document),
    do: %{document | "stages" => Enum.map(stages, &stage_without_people/1)}

  defp stage_without_people(%{"gate" => %{"approvers" => %{}} = gate} = stage),
    do: %{stage | "gate" => %{gate | "approvers" => "members"}}

  defp stage_without_people(stage), do: stage

  defp artifact_types(%Workspace{} = workspace) do
    {standard, custom} = workspace |> Artifacts.all_types() |> Enum.split_with(& &1.standard)

    names =
      for %Type{shown: true, name: name} <- standard,
          name not in Type.always_on(),
          do: {:ordered, [{"name", name}]}

    names ++ Enum.map(custom, &custom_type/1)
  end

  defp custom_type(%Type{} = type) do
    definition = [
      {"name", type.name},
      {"base_view", Atom.to_string(type.base_view)},
      {"size_limit", type.size_limit},
      {"max_files", type.max_files}
    ]

    {:ordered,
     if(type.base_view == :structured,
       do: definition ++ [{"json_schema", {:flow, type.json_schema}}],
       else: definition
     )}
  end

  ## The YAML

  # The lines of a mapping's `pairs`, in their order, at `indent` spaces. `lead` starts the
  # first line in place of those spaces: the `- ` of a list's item.
  defp entries(pairs, indent, lead) do
    pad = String.duplicate(" ", indent)

    pairs
    |> Enum.with_index()
    |> Enum.map(fn {{key, value}, index} ->
      start = if(index == 0, do: lead, else: pad)
      written = string(key)

      if explicit?(written),
        do: [start, "? ", written, "\n", pad, ":", after_key(value, indent)],
        else: [start, written, ":", after_key(value, indent)]
    end)
  end

  defp after_key(value, indent) do
    if block?(value) do
      pad = String.duplicate(" ", indent + 2)
      ["\n", block(value, indent + 2, pad)]
    else
      [" ", flow(value), "\n"]
    end
  end

  defp block({:ordered, pairs}, indent, lead), do: entries(pairs, indent, lead)
  defp block(%{} = map, indent, lead), do: entries(Enum.sort(map), indent, lead)

  defp block(list, indent, lead) when is_list(list) do
    pad = String.duplicate(" ", indent)

    list
    |> Enum.with_index()
    |> Enum.map(fn {item, index} ->
      start = if(index == 0, do: lead, else: pad) <> "- "

      if block?(item),
        do: block(item, indent + 2, start),
        else: [start, flow(item), "\n"]
    end)
  end

  defp block?({:ordered, _pairs}), do: true
  defp block?(value) when is_map(value), do: map_size(value) > 0
  defp block?(value) when is_list(value), do: value != []
  defp block?(_value), do: false

  # One line: a value of `{:flow, value}`, an empty mapping or list, or a scalar.
  defp flow({:flow, value}), do: flow(value)

  defp flow(%{} = map) do
    pairs = for {key, value} <- Enum.sort(map), do: flow_pair(string(key), value)
    ["{", Enum.intersperse(pairs, ", "), "}"]
  end

  defp flow(list) when is_list(list),
    do: ["[", list |> Enum.map(&flow/1) |> Enum.intersperse(", "), "]"]

  defp flow(nil), do: "null"
  defp flow(value) when is_boolean(value), do: Atom.to_string(value)
  defp flow(value) when is_integer(value), do: Integer.to_string(value)
  defp flow(value) when is_float(value), do: Float.to_string(value)
  defp flow(value) when is_binary(value), do: string(value)

  defp flow_pair(written, value) do
    if explicit?(written),
      do: ["? ", written, " : ", flow(value)],
      else: [written, ": ", flow(value)]
  end

  defp explicit?(written), do: IO.iodata_length(written) > @implicit_key_bytes

  defp string(text), do: [?", for(<<char::utf8 <- text>>, do: character(char)), ?"]

  defp character(?"), do: "\\\""
  defp character(?\\), do: "\\\\"
  defp character(?\n), do: "\\n"
  defp character(?\r), do: "\\r"
  defp character(?\t), do: "\\t"

  defp character(char)
       when char < 0x20 or char in 0x7F..0x9F or
              char in [0x2028, 0x2029, 0xFEFF, 0xFFFE, 0xFFFF],
       do: ["\\u", char |> Integer.to_string(16) |> String.pad_leading(4, "0")]

  defp character(char), do: <<char::utf8>>
end
