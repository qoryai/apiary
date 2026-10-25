defmodule Apiary.Harnesses.Reader do
  @moduledoc """
  Reads the YAML files of qory's harness format, version 1: the harness section of a
  `qory.yaml` or `harness.yaml`, the modules of a `qory-stack.yaml`, the `exports` of a
  root file, and a harness document as a settings row keeps it. Pure: bytes in, a
  value or a reason out. It reads the source keys and nothing else, and it splits no
  URL.

  ## Limits

  Every file is untrusted input, so each read applies three limits before it builds a
  value:

    * at most 64 KiB (65,536 bytes) per file, `:too_large`;
    * at most 16 nested mappings and sequences, `:too_deep`;
    * no anchor and no alias, `:alias`.

  The first pass reads the parser's tokens only, and stops at the first anchor, alias or
  collection that nests too deep. No node is built in that pass, so an alias never
  expands. The second pass builds the value with the YAML 1.2 core schema. It also
  refuses a file of more than one document (`:several_documents`), a key that is not
  text (`:key_not_text`), a key repeated in one mapping (`{:repeated_key, key}`), an
  infinite or not-a-number float (`:not_a_number`), and anything else the parser refuses
  (`:invalid_yaml`), unknown tags included.

  An empty file is a file with no value: `harness/1` and `exports/1` read it as `:none`.
  """

  @max_bytes 65_536
  @max_depth 16

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

  @typedoc """
  The `exports` of a root file: `dir`, nil for the root, one folder, or a map of the
  `"stacks"` and `"modules"` folders; and `stacks`, the names of the stacks it exports.
  """
  @type exports :: %{
          dir: nil | String.t() | %{String.t() => String.t()},
          stacks: [String.t()]
        }

  @doc "The most bytes a file may have."
  @spec max_bytes() :: pos_integer
  def max_bytes, do: @max_bytes

  @doc "The deepest a file's mappings and sequences may nest."
  @spec max_depth() :: pos_integer
  def max_depth, do: @max_depth

  @doc "The machine's keys of a harness section: a section with these alone is no document."
  @spec machine_keys() :: [String.t()]
  def machine_keys, do: @machine_keys

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
    with {:ok, file} <- parse(bytes) do
      case file do
        %{"modules" => [_ | _] = modules} ->
          if Enum.all?(modules, &is_map/1),
            do: {:ok, modules},
            else: {:error, :invalid_stack}

        _other ->
          {:error, :invalid_stack}
      end
    end
  end

  @doc """
  exports/1 is the `exports` section of a root `qory.yaml` or `harness.yaml`: `{:ok,
  exports}`, `:none` for a file without one, or `{:error, reason}`.
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

    if dir?(dir) and is_list(stacks) and Enum.all?(stacks, &is_binary/1),
      do: {:ok, %{dir: dir, stacks: stacks}},
      else: {:error, :invalid_exports}
  end

  defp dir?(nil), do: true
  defp dir?(dir) when is_binary(dir), do: dir != ""

  defp dir?(%{"stacks" => stacks, "modules" => modules} = dir)
       when map_size(dir) == 2 and is_binary(stacks) and is_binary(modules),
       do: stacks != "" and modules != ""

  defp dir?(_other), do: false

  @doc """
  stack_file/2 is the path of the `qory-stack.yaml` of the stack `name` in a repository
  whose root file has `exports`, from the repository's root.
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
  parse/1 is the value of one YAML file under the limits of the moduledoc: `{:ok,
  value}`, nil for an empty file, or `{:error, reason}`. Mappings are maps with text
  keys.
  """
  @spec parse(binary) :: {:ok, term} | {:error, reason}
  def parse(bytes) when is_binary(bytes) do
    cond do
      byte_size(bytes) > @max_bytes -> {:error, :too_large}
      not String.valid?(bytes) -> {:error, :invalid_yaml}
      true -> with :ok <- scan(bytes), do: build(bytes)
    end
  end

  # The first pass: the parser's tokens alone, with no node built. A throw of this
  # module's tag leaves the parser, which catches only its own errors.
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
      [{:yamerl_doc, root}] -> {:ok, value(root)}
      _several -> {:error, :several_documents}
    end
  catch
    {__MODULE__, reason} -> {:error, reason}
    {:yamerl_exception, _errors} -> {:error, :invalid_yaml}
  end

  defp value({:yamerl_map, _module, _tag, _place, pairs}), do: mapping(pairs, %{})
  defp value({:yamerl_seq, _module, _tag, _place, items, _count}), do: Enum.map(items, &value/1)
  defp value({:yamerl_null, _module, _tag, _place}), do: nil
  defp value({:yamerl_float, _module, _tag, _place, float}) when is_float(float), do: float

  defp value({:yamerl_float, _module, _tag, _place, _infinite}),
    do: throw({__MODULE__, :not_a_number})

  defp value({_kind, _module, _tag, _place, value})
       when is_binary(value) or is_integer(value) or is_boolean(value),
       do: value

  defp value(_node), do: throw({__MODULE__, :invalid_yaml})

  defp mapping([], map), do: map

  defp mapping([{{:yamerl_str, _module, _tag, _place, key}, node} | pairs], map)
       when is_binary(key) do
    if Map.has_key?(map, key), do: throw({__MODULE__, {:repeated_key, key}})
    mapping(pairs, Map.put(map, key, value(node)))
  end

  defp mapping([_pair | _pairs], _map), do: throw({__MODULE__, :key_not_text})
end
