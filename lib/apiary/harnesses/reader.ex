defmodule Apiary.Harnesses.Reader do
  @moduledoc """
  Reads the YAML files of qory's harness format, version 1: the harness section of a
  `qory.yaml` or `harness.yaml`, the modules and the `workflows` of a `qory-stack.yaml`,
  the `exports` of a root file, a factory's `process.yaml`, and a harness document as a
  settings row keeps it. Pure:
  bytes in, a value or a reason out. Of a harness section and a stack's modules it reads
  the source keys and nothing else; a stack's `workflows` it returns as written, and of
  a workflow it reads the access level alone (`workflow_access/2`). It splits no URL.

  ## Limits

  Every file is untrusted input, so each read applies these limits:

    * at most 64 KiB (65,536 bytes) per file, `:too_large`;
    * no control character but tab, line feed and carriage return, neither in the bytes
      nor in a text the file escapes, `:control_character`;
    * at most 16 nested mappings and sequences, `:too_deep`;
    * no anchor and no alias, `:alias`;
    * at most 30 million reductions and 64 MiB of heap for the parse, with 10 seconds of
      wall-clock time as a backstop, `:too_complex`. A reduction is the runtime's unit of
      a process's work. On OTP 29 the same parse repeated its count within 1.4 %, on an
      idle and on a busy machine. The reductions are read every 50 ms, and the parse
      may do up to about 5 million reductions between two reads on an idle machine. So
      a file whose parse does within about 5 million reductions of the budget may get
      a different answer on another read, and so may a read that runs past the
      backstop on a busy machine. Any other file gets the same answer on every read.

  The parser, yamerl, holds back its tokens while a flow collection could still turn out
  to be a key, and reverses that queue for each token it adds, so a long flow collection
  at the top level or in a block sequence costs time that grows with the square of its
  length. Both passes therefore run in another process under `Apiary.Kinds.Budget`,
  which kills the process when it passes a limit, and at once when the caller exits.

  The first pass reads the parser's tokens only, and stops at the first anchor, alias or
  collection that nests too deep. No node is built in that pass, so an alias never
  expands. The second pass builds the value with the YAML 1.2 core schema. It takes
  text, integers, floats, booleans and null, and refuses any other type, such as
  `!!binary` (`:unsupported_type`). It also refuses a file of more than one document
  (`:several_documents`), a key that is not text (`:key_not_text`), a key repeated in
  one mapping (`{:repeated_key, key}`), an infinite or not-a-number float
  (`:not_a_number`), and anything else the parser refuses or fails on (`:invalid_yaml`),
  unknown tags included.

  An empty file is a file with no value: `harness/1` and `exports/1` read it as `:none`.
  The `modules` of `exports` have no refusal: `exports/1` returns `:invalid` for them.

  ## A factory's process.yaml

  `template/1` checks a `process.yaml` against qory's `process.schema.json`, vendored under
  `priv/contract/harness/v1/` from the qory commit in the `.contract-ref` file beside it.
  One change to how the schema is built makes it read as qory reads it: each `minLength`
  and `maxLength` counts code points, not graphemes, as the Explore result's schema does.
  A `\\s` or `\\S` of a pattern reads every Unicode space, as qory's check of the file
  does.

  The schema takes an optional `artifact_types` list, whose entries are a name alone or a
  custom type's full definition. `template/1` returns the list as written, and nil when
  the key is absent. The schema has no list of standard types, so the caller checks what
  the list means for the workspaces made from the template.
  """

  alias Apiary.Kinds.{Budget, Schema}

  @max_bytes 65_536
  @max_depth 16

  # The parse's limits. Measured on OTP 29: a 64 KiB document of ordinary YAML does
  # 2.3 to 9.1 million reductions and needs 10 to 25 MiB of heap, counted as the budget
  # counts it; each slow input of the tests passes 30 million reductions within 3 s on
  # an idle machine. The reductions are read every 50 ms.
  @max_reductions 30_000_000
  @max_heap_words div(64 * 1024 * 1024, :erlang.system_info(:wordsize))
  @budget [
    reductions: @max_reductions,
    heap_words: @max_heap_words,
    ms: 10_000,
    poll_ms: 50
  ]

  # The control characters a file and its texts may not contain: C0 but tab, line feed
  # and carriage return, DEL, and C1.
  @control ~r/[\x{00}-\x{08}\x{0B}\x{0C}\x{0E}-\x{1F}\x{7F}-\x{9F}]/u

  # The machine's keys of a harness section (qory contracts/harness/v1/config.schema.json):
  # a section with these alone is not a document.
  @machine_keys ~w(runtime model effort tiers force update home links launch)

  @constr_options [
    detailed_constr: true,
    str_node_as_binary: true,
    keep_duplicate_keys: true,
    schema: :core,
    node_mods: []
  ]

  @typedoc "Why a file is refused."
  @type reason ::
          :too_large
          | :too_deep
          | :control_character
          | :too_complex
          | :unsupported_type
          | :alias
          | :several_documents
          | :key_not_text
          | {:repeated_key, String.t()}
          | :not_a_number
          | :invalid_yaml
          | :not_a_mapping
          | :invalid_harness
          | :invalid_stack
          | :invalid_exports
          | :invalid_template

  @typedoc """
  The `exports` of a root file: `dir`, nil for the root, one folder, or a map of the
  `"stacks"` and `"modules"` folders; `stacks`, the names of the stacks it exports; and
  `modules`, the names of the modules it exports, or `:invalid` for a value that is not a
  list of text.
  """
  @type exports :: %{
          dir: nil | String.t() | %{String.t() => String.t()},
          stacks: [String.t()],
          modules: [String.t()] | :invalid
        }

  @typedoc """
  A factory's `process.yaml`: its texts, the workspace type, the stack its workflows run
  on, `process`, the `qory.process/v1` document as written, and `artifact_types`, the
  artifact types its workspaces use as written, nil when the key is absent.
  """
  @type template :: %{
          name: String.t(),
          summary: String.t(),
          description: String.t(),
          type: String.t(),
          stack: String.t(),
          process: map,
          artifact_types: [map] | nil
        }

  # qory's process.schema.json, under the application's priv.
  @template_schema ["contract", "harness", "v1", "process.schema.json"]

  # The most characters of a type's name a refusal keeps: the most a name has. A name the
  # schema refuses can be as long as the file.
  @max_type_name 64

  @doc "The most bytes a file may have."
  @spec max_bytes() :: pos_integer
  def max_bytes, do: @max_bytes

  @doc false
  # max_reductions/0 is the most reductions a parse may do.
  @spec max_reductions() :: pos_integer
  def max_reductions, do: @max_reductions

  @doc "The deepest a file's mappings and sequences may nest."
  @spec max_depth() :: pos_integer
  def max_depth, do: @max_depth

  @doc "The machine's keys of a harness section: a section with these alone is no document."
  @spec machine_keys() :: [String.t()]
  def machine_keys, do: @machine_keys

  @doc false
  # control_character?/1 is whether `text` has a control character no file may contain.
  @spec control_character?(String.t()) :: boolean
  def control_character?(text) when is_binary(text), do: Regex.match?(@control, text)

  @doc """
  harness/1 is the harness section of a `qory.yaml` or `harness.yaml`: `{:ok, section}`,
  `:none` for a file with no `harness` section or one with the machine's keys alone, or
  `{:error, reason}`.
  """
  @spec harness(binary) :: {:ok, map} | :none | {:error, reason}
  def harness(bytes) when is_binary(bytes) do
    case parse(bytes) do
      {:ok, nil} -> :none
      {:ok, %{} = file} -> section(Map.get(file, "harness"))
      {:ok, _other} -> {:error, :not_a_mapping}
      {:error, reason} -> {:error, reason}
    end
  end

  defp section(nil), do: :none

  defp section(%{} = section) do
    if Enum.all?(Map.keys(section), &(&1 in @machine_keys)),
      do: :none,
      else: {:ok, section}
  end

  defp section(_other), do: {:error, :invalid_harness}

  @doc """
  document/1 is a harness document as a settings row keeps it, the contents of a
  harness section written in YAML: `{:ok, section}` or `{:error, reason}`.
  """
  @spec document(binary) :: {:ok, map} | {:error, reason}
  def document(bytes) when is_binary(bytes) do
    case parse(bytes) do
      {:ok, %{} = section} -> {:ok, section}
      {:ok, _other} -> {:error, :not_a_mapping}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  stack_modules/1 is the modules of a `qory-stack.yaml`, each a map as written: `{:ok,
  modules}` or `{:error, reason}`. A stack lists at least one module.
  """
  @spec stack_modules(binary) :: {:ok, [map]} | {:error, reason}
  def stack_modules(bytes) when is_binary(bytes) do
    with {:ok, %{modules: modules}} <- stack(bytes), do: {:ok, modules}
  end

  @doc """
  stack/1 is a `qory-stack.yaml`: `{:ok, %{modules: modules, workflows: workflows}}` or
  `{:error, reason}`. `modules` is as `stack_modules/1` reads it, and `workflows` is the
  file's `workflows` mapping as written, an empty map for none or for a value that is
  not a mapping.
  """
  @spec stack(binary) :: {:ok, %{modules: [map], workflows: map}} | {:error, reason}
  def stack(bytes) when is_binary(bytes) do
    with {:ok, file} <- parse(bytes) do
      case file do
        %{"modules" => [_ | _] = modules} ->
          if Enum.all?(modules, &is_map/1),
            do: {:ok, %{modules: modules, workflows: workflows(file)}},
            else: {:error, :invalid_stack}

        _other ->
          {:error, :invalid_stack}
      end
    end
  end

  defp workflows(%{"workflows" => %{} = workflows}), do: workflows
  defp workflows(_file), do: %{}

  @doc """
  workflow_access/2 is the access level a stack's `workflows` declare for the workflow
  `name`, `workflows.<name>.access`: `:write` for `write`, and `:read` for `read`, for
  any other value, and where the key or the workflow is absent.
  """
  @spec workflow_access(map, String.t()) :: :read | :write
  def workflow_access(workflows, name) when is_map(workflows) and is_binary(name) do
    case workflows do
      %{^name => %{"access" => "write"}} -> :write
      _read_or_none -> :read
    end
  end

  @doc """
  exports/1 is the `exports` section of a root `qory.yaml` or `harness.yaml`: `{:ok,
  exports}`, `:none` for a file without one, or `{:error, reason}`. `modules` does not fail
  the section, because a run reads none of it: `[]` for no value, and `:invalid` for a
  value that is not a list of text, such as `[1]`. The value is not converted to text:
  qory reads `0x10` as the name `"0x10"`, and this module as the integer 16.
  """
  @spec exports(binary) :: {:ok, exports} | :none | {:error, reason}
  def exports(bytes) when is_binary(bytes) do
    case parse(bytes) do
      {:ok, nil} -> :none
      {:ok, %{"exports" => %{} = exports}} -> exports_of(exports)
      {:ok, %{"exports" => nil}} -> :none
      {:ok, %{"exports" => _other}} -> {:error, :invalid_exports}
      {:ok, %{}} -> :none
      {:ok, _other} -> {:error, :not_a_mapping}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exports_of(exports) do
    dir = Map.get(exports, "dir")
    stacks = Map.get(exports, "stacks", [])

    if dir?(dir) and names?(stacks),
      do: {:ok, %{dir: dir, stacks: stacks, modules: module_names(exports["modules"])}},
      else: {:error, :invalid_exports}
  end

  defp names?(names), do: is_list(names) and Enum.all?(names, &is_binary/1)

  # `modules:` with no value lists no modules, as qory reads it.
  defp module_names(nil), do: []
  defp module_names(modules), do: if(names?(modules), do: modules, else: :invalid)

  defp dir?(nil), do: true
  defp dir?(dir) when is_binary(dir), do: dir != ""

  defp dir?(%{"stacks" => stacks, "modules" => modules} = dir)
       when map_size(dir) == 2 and is_binary(stacks) and is_binary(modules),
       do: stacks != "" and modules != ""

  defp dir?(_other), do: false

  @doc """
  stack_file/2 is the path of the `qory-stack.yaml` of the stack `name` in a source
  whose root file has `exports`, from the source's root.
  """
  @spec stack_file(exports, String.t()) :: String.t()
  def stack_file(%{dir: dir}, name) when is_binary(name) do
    stacks =
      case dir do
        nil -> "stacks"
        dir when is_binary(dir) -> Path.join(dir, "stacks")
        %{"stacks" => stacks} -> stacks
      end

    Path.join([stacks, name, "qory-stack.yaml"])
  end

  @doc """
  module_file/3 is the path of `file` in the folder of the module `name` in a source whose
  root file has `exports`, from the source's root, as qory resolves it: `modules/<name>`
  with no `dir`, `<dir>/modules/<name>` for a `dir` of one folder, and `<modules>/<name>`
  for a `dir` map. The folder is cleaned as qory cleans it: a `.` part goes, and a `..`
  part goes with the part before it.

  `{:ok, path}`, or one of:

    * `{:error, :invalid_name}` for a name that is not one path segment as qory's exports
      allow it: empty, or with a slash, a backslash, an `@` or a leading dot, such as `..`;
    * `{:error, :invalid_file}` for a `file` that is not a relative path inside the folder,
      with no `.` or `..` part;
    * `{:error, :invalid_dir}` for a `dir` that is absolute or leads outside the source.
  """
  @spec module_file(exports, String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_name | :invalid_file | :invalid_dir}
  def module_file(%{dir: dir}, name, file) when is_binary(name) and is_binary(file) do
    cond do
      not segment?(name) ->
        {:error, :invalid_name}

      not inside?(file) ->
        {:error, :invalid_file}

      true ->
        with {:ok, folder} <- modules_folder(dir), do: {:ok, Path.join(folder ++ [name, file])}
    end
  end

  # The parts of the folder of a source's modules, from its root.
  defp modules_folder(nil), do: {:ok, ["modules"]}
  defp modules_folder(dir) when is_binary(dir), do: cleaned(dir <> "/modules")
  defp modules_folder(%{"modules" => modules}), do: cleaned(modules)

  # A folder's parts as Go's `filepath.Clean` leaves them, or `:invalid_dir` where qory
  # refuses the folder: an absolute one, and one whose cleaned path starts with `..`.
  defp cleaned("/" <> _absolute), do: {:error, :invalid_dir}

  defp cleaned(folder) do
    folder
    |> String.split("/")
    |> Enum.reduce_while({:ok, []}, fn
      part, {:ok, parts} when part in ["", "."] -> {:cont, {:ok, parts}}
      "..", {:ok, []} -> {:halt, {:error, :invalid_dir}}
      "..", {:ok, [_part | parts]} -> {:cont, {:ok, parts}}
      part, {:ok, parts} -> {:cont, {:ok, [part | parts]}}
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      refused -> refused
    end
  end

  # One path segment as qory's exports allow a name (qory internal/exports, `segment`).
  defp segment?(name),
    do:
      name != "" and not String.contains?(name, ["/", "\\", "@"]) and
        not String.starts_with?(name, ".")

  defp inside?(file),
    do:
      file != "" and Path.type(file) == :relative and not String.contains?(file, "\\") and
        Enum.all?(String.split(file, "/"), &(&1 not in ["", ".", ".."]))

  @doc """
  template/1 is a factory's `process.yaml`, checked against qory's `process.schema.json`
  as the moduledoc says: `{:ok, template}` or `{:error, reason}`. A file the schema
  refuses, such as one with a key missing, a key of the wrong type or a key the schema
  does not define, is `:invalid_template`. Where the schema refuses an entry of
  `artifact_types` whose `name` is text, whatever else it refuses, it is
  `{:invalid_artifact_type, name}` for the first such entry, with the first
  #{@max_type_name} characters of the name. The schema checks `process` loosely; the
  caller checks it as a process, and checks what `artifact_types` means.
  """
  @spec template(binary) ::
          {:ok, template} | {:error, reason | {:invalid_artifact_type, String.t()}}
  def template(bytes) when is_binary(bytes) do
    with {:ok, file} <- parse(bytes) do
      case JSV.validate(file, template_root(), cast: false) do
        {:ok, _file} ->
          {:ok,
           %{
             name: file["name"],
             summary: file["summary"],
             description: file["description"],
             type: file["type"],
             stack: file["stack"],
             process: file["process"],
             artifact_types: file["artifact_types"]
           }}

        {:error, %JSV.ValidationError{errors: errors}} ->
          {:error, template_refusal(file, errors)}
      end
    end
  end

  # An error's path is in JSV's order, the last key first.
  defp template_refusal(%{"artifact_types" => listed}, errors) when is_list(listed) do
    refused =
      for %{data_path: path} <- errors,
          ["artifact_types", index | _rest] when is_integer(index) <- [Enum.reverse(path)],
          into: MapSet.new(),
          do: index

    listed
    |> Enum.with_index()
    |> Enum.find_value(:invalid_template, fn
      {%{"name" => name}, index} when is_binary(name) ->
        if index in refused,
          do: {:invalid_artifact_type, String.slice(name, 0, @max_type_name)}

      _entry ->
        nil
    end)
  end

  defp template_refusal(_file, _errors), do: :invalid_template

  defp template_root,
    do: Schema.file!(@template_schema, &Schema.code_point_lengths/1)

  @doc """
  parse/1 is the value of one YAML file under the limits of the moduledoc: `{:ok,
  value}`, nil for an empty file, or `{:error, reason}`. Mappings are maps with text
  keys.
  """
  @spec parse(binary) :: {:ok, term} | {:error, reason}
  def parse(bytes) when is_binary(bytes) do
    cond do
      byte_size(bytes) > @max_bytes -> {:error, :too_large}
      not String.valid?(bytes) -> {:error, :invalid_yaml}
      Regex.match?(@control, bytes) -> {:error, :control_character}
      true -> isolated(bytes)
    end
  end

  # Both passes in another process under the budget. A crash of the process is a
  # refusal, never a crash of the caller.
  defp isolated(bytes) do
    case Budget.run(fn -> read(bytes) end, @budget) do
      {:ok, result} -> result
      {:error, :crashed} -> {:error, :invalid_yaml}
      {:error, _reductions_heap_or_time} -> {:error, :too_complex}
    end
  end

  @doc false
  # read/1 is both passes of `parse/1` in the calling process, with no limit on their
  # work: for the tests that count its reductions. Any exception yamerl raises, such as
  # on a character it has no clause for, is a refusal.
  @spec read(binary) :: {:ok, term} | {:error, reason}
  def read(bytes) do
    with :ok <- scan(bytes), do: build(bytes)
  rescue
    _exception -> {:error, :invalid_yaml}
  end

  # The first pass: the parser's tokens alone, with no node built. A throw of this
  # module's tag leaves the parser, which catches only `yamerl_parsing_error` records.
  defp scan(bytes) do
    _parser = :yamerl_parser.string(bytes, token_fun: token_fun(0, 0))
    :ok
  catch
    {__MODULE__, reason} -> {:error, reason}
    {:yamerl_exception, _errors} -> {:error, :invalid_yaml}
  end

  defp token_fun(depth, documents), do: fn token -> {:ok, next(token, depth, documents)} end

  defp next(token, depth, documents) do
    case elem(token, 0) do
      :yamerl_anchor -> throw({__MODULE__, :alias})
      :yamerl_alias -> throw({__MODULE__, :alias})
      :yamerl_collection_start when depth >= @max_depth -> throw({__MODULE__, :too_deep})
      :yamerl_collection_start -> token_fun(depth + 1, documents)
      :yamerl_collection_end -> token_fun(depth - 1, documents)
      :yamerl_doc_start when documents >= 1 -> throw({__MODULE__, :several_documents})
      :yamerl_doc_start -> token_fun(depth, documents + 1)
      _other -> token_fun(depth, documents)
    end
  end

  # The second pass, after the first found no anchor, alias or deep nesting.
  defp build(bytes) do
    case :yamerl_constr.string(bytes, @constr_options) do
      [] -> {:ok, nil}
      [{:yamerl_doc, root}] -> {:ok, value(root, 0)}
      _several -> {:error, :several_documents}
    end
  catch
    {__MODULE__, reason} -> {:error, reason}
    {:yamerl_exception, _errors} -> {:error, :invalid_yaml}
  end

  # The value of a node at `depth` collections down. The parse's first pass counts the
  # collections it sees as tokens; a mapping of one pair inside a flow sequence, `[a: x]`,
  # has none, so the depth is counted again here.
  defp value({:yamerl_map, _module, _tag, _place, _pairs}, depth) when depth >= @max_depth,
    do: throw({__MODULE__, :too_deep})

  defp value({:yamerl_seq, _module, _tag, _place, _items, _count}, depth)
       when depth >= @max_depth,
       do: throw({__MODULE__, :too_deep})

  defp value({:yamerl_map, _module, _tag, _place, pairs}, depth),
    do: mapping(pairs, %{}, depth + 1)

  defp value({:yamerl_seq, _module, _tag, _place, items, _count}, depth),
    do: Enum.map(items, &value(&1, depth + 1))

  defp value({:yamerl_null, _module, _tag, _place}, _depth), do: nil

  defp value({:yamerl_float, _module, _tag, _place, float}, _depth) when is_float(float),
    do: float

  defp value({:yamerl_float, _module, _tag, _place, _infinite}, _depth),
    do: throw({__MODULE__, :not_a_number})

  defp value({:yamerl_str, _module, _tag, _place, text}, _depth) when is_binary(text),
    do: text!(text)

  defp value({:yamerl_int, _module, _tag, _place, integer}, _depth) when is_integer(integer),
    do: integer

  defp value({:yamerl_bool, _module, _tag, _place, boolean}, _depth) when is_boolean(boolean),
    do: boolean

  defp value(_node, _depth), do: throw({__MODULE__, :unsupported_type})

  # A text of the file, which a double-quoted scalar may write with escapes, such as
  # `"\0"`: valid UTF-8 with no control character the bytes may not have.
  defp text!(text) do
    cond do
      not String.valid?(text) -> throw({__MODULE__, :invalid_yaml})
      Regex.match?(@control, text) -> throw({__MODULE__, :control_character})
      true -> text
    end
  end

  defp mapping([], map, _depth), do: map

  defp mapping([{{:yamerl_str, _module, _tag, _place, key}, node} | pairs], map, depth)
       when is_binary(key) do
    key = text!(key)
    if Map.has_key?(map, key), do: throw({__MODULE__, {:repeated_key, key}})
    mapping(pairs, Map.put(map, key, value(node, depth)), depth)
  end

  defp mapping([_pair | _pairs], _map, _depth), do: throw({__MODULE__, :key_not_text})
end
