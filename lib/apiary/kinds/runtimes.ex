defmodule Apiary.Kinds.Runtimes do
  @moduledoc """
  Runtimes is the catalogue of the runtimes a workspace can set up: the Forager contract's
  `contracts/forager/v1/runtimes.json`, vendored byte for byte as
  `priv/contract/runtimes.json` at the commit in `.forager-contract-ref`. Forager
  generates it from its built-in descriptors, in name order; per runtime it has its
  `name`, such as `claude`, a `title`, its `reserves`, its `denies`, its
  `credential_files`, its `declares` (each with its `id`, `title`, the variable `name` it
  sets, its `hosts`, its `auth`, as the contract's `auth.schema.json` has it, and its
  `paths`, which may be absent), its `one_of` groups (each with `id`, `required` and
  `of`), and its `model`, when it has one: the model API formats it sends, where a run's
  model id, effort and endpoint go, the effort values it accepts, and the variables it
  reads a model key from (`keys`). The loader keeps `model` as it is and reads its
  `keys`, its run's effort values and its endpoint's variable into the fields of
  `Apiary.Kinds.Runtime`; a `model` without a list of `formats`, or with a key that has
  no `format`, `auth` and `variable`, fails the compile. A test compares the file with
  Forager's contract directory.

  The catalogue is read when the application is compiled: a runtime is added by a
  release. Every list of a runtime is read with `Map.fetch!/2`, since Forager always
  writes them, so a key the contract renames fails the compile instead of reading as an
  empty list.

  A runtime connection (`Apiary.Connections`) names its runtime by `name`. It offers
  none of the runtime's declarations and stores no secret: by Forager's contract, the
  run's model key comes from a model provider, and a runtime connection holds none.
  """

  @path Path.join([__DIR__, "..", "..", "..", "priv", "contract", "runtimes.json"])
  @external_resource @path

  alias Apiary.Kinds.Runtime

  @runtimes (fn ->
               %{"version" => 1, "runtimes" => runtimes} =
                 @path |> File.read!() |> Jason.decode!()

               # A key without its three members raises a CaseClauseError here, which
               # stops the compile.
               key = fn key ->
                 case key do
                   %{"format" => format, "auth" => %{} = auth, "variable" => variable}
                   when is_binary(format) and is_binary(variable) ->
                     %{"format" => format, "auth" => auth, "variable" => variable}
                 end
               end

               for runtime <- runtimes do
                 model =
                   case Map.get(runtime, "model") do
                     nil -> nil
                     %{"formats" => formats} = model when is_list(formats) -> model
                   end

                 %Runtime{
                   name: Map.fetch!(runtime, "name"),
                   title: Map.fetch!(runtime, "title"),
                   reserves: Map.fetch!(runtime, "reserves"),
                   denies: Map.fetch!(runtime, "denies"),
                   credential_files: Map.fetch!(runtime, "credential_files"),
                   declares: Map.fetch!(runtime, "declares"),
                   one_of: Map.fetch!(runtime, "one_of"),
                   model: model,
                   model_keys: Enum.map(get_in(model || %{}, ["keys"]) || [], key),
                   effort_values: get_in(model || %{}, ["effort", "run", "values"]) || [],
                   endpoint_variable: get_in(model || %{}, ["endpoint", "variable"])
                 }
               end
             end).()

  # Whether the build has `put_test_list/1`: set in `config/test.exs` only, so a
  # development or release build has neither the function nor the lookup behind it.
  @test_seam Application.compile_env(:apiary, [__MODULE__, :test_seam], false)

  @doc "list/0 is every runtime of the catalogue, in its order."
  @spec list() :: [Runtime.t()]
  if @test_seam do
    def list, do: test_list() || @runtimes
  else
    def list, do: @runtimes
  end

  @doc "fetch/1 is the runtime named `name`: `{:ok, runtime}`, or `:error`."
  @spec fetch(term) :: {:ok, Runtime.t()} | :error
  def fetch(name) do
    case Enum.find(list(), &(&1.name == name)) do
      %Runtime{} = runtime -> {:ok, runtime}
      nil -> :error
    end
  end

  @doc """
  formats/1 is the model API formats a runtime sends, from its `model`: `[]` for a
  runtime without a `model`.
  """
  @spec formats(Runtime.t()) :: [String.t()]
  def formats(%Runtime{model: %{"formats" => formats}}), do: formats
  def formats(%Runtime{}), do: []

  @doc "hosts/1 is every host a runtime's declarations set a value on, each once."
  @spec hosts(Runtime.t()) :: [String.t()]
  def hosts(%Runtime{declares: declares}),
    do: declares |> Enum.flat_map(&Map.get(&1, "hosts", [])) |> Enum.uniq()

  if @test_seam do
    # The key of the list a test puts in its process (`put_test_list/1`), and the flag
    # that any test has put one.
    @test_list {__MODULE__, :test_list}
    @stubbed {__MODULE__, :stubbed}

    # put_test_list/1 makes `runtimes` the catalogue that `list/0` and `fetch/1` answer in
    # this process and in the processes it starts, such as a LiveView of a test, until the
    # process ends. For tests that need a catalogue of another size than the release's.
    @doc false
    @spec put_test_list([Runtime.t()]) :: :ok
    def put_test_list(runtimes) when is_list(runtimes) do
      unless :persistent_term.get(@stubbed, false), do: :persistent_term.put(@stubbed, true)
      Process.put(@test_list, runtimes)
      :ok
    end

    # The list a test put in this process, or in the nearest of its callers that put one;
    # nil where no test ever put one.
    defp test_list do
      if :persistent_term.get(@stubbed, false) do
        Enum.find_value([self() | Process.get(:"$callers", [])], fn
          pid when pid == self() -> Process.get(@test_list)
          pid -> caller_list(pid)
        end)
      end
    end

    defp caller_list(pid) when is_pid(pid) do
      case Process.info(pid, {:dictionary, @test_list}) do
        {{:dictionary, @test_list}, list} when is_list(list) -> list
        _unset_or_gone -> nil
      end
    end

    defp caller_list(_name), do: nil
  end

  @doc """
  variables/0 is every variable a runtime of the catalogue declares, reserves or reads a
  model key from (`model_keys`): the names no other connection may take for a placeholder
  (`Apiary.Kinds.Placeholders`).
  """
  @spec variables() :: [String.t()]
  def variables do
    list()
    |> Enum.flat_map(fn runtime ->
      Enum.flat_map(runtime.declares, &List.wrap(&1["name"])) ++
        runtime.reserves ++ Enum.map(runtime.model_keys, & &1["variable"])
    end)
    |> Enum.uniq()
  end
end
