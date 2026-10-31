defmodule ApiaryWeb.RunApiStubs do
  @moduledoc """
  Stubs for the run API's tests (`ApiaryWeb.Contract.RunApi.Boundary`): `Artifacts`, the
  real `Apiary.Artifacts` with a record of each push and a refusal a test sets;
  `Processes`, a declaration set by the test; and `Features`, the flag `workflow_model`.
  `install/1` sets them in the application's configuration until the test ends, so a
  test that uses them is not async.

  `Apiary.Stages` calls `Apiary.Artifacts` through `Apiary.Stages.Artifacts`, with no stub:
  a version these tests read through the stage runner is a row in the real tables, with
  its files in the real store. A test sets `:artifacts_dir` to a folder of its run.

  Their state is the test process's: a request through `Phoenix.ConnTest` runs in that
  process. `put/2` sets a value:

    * `:flag`: whether `workflow_model` is on, true unless set;
    * `:declaration`: what `Processes.workflow_declaration/2` returns, nil unless set;
    * `:push_error`: an error `Artifacts.push/5` returns in place of a push.

  `Artifacts.push/5` records each version it stored, with the options it was given and
  the files' contents; `pushed/0` lists them, oldest first.
  """

  @boundary ApiaryWeb.Contract.RunApi.Boundary

  @doc """
  Sets the stubs in the application's configuration until the test ends, but for the
  ones named in `real` (`:artifacts`, `:processes` or `:features`), which stay the
  modules the boundary calls by default.
  """
  def install(real \\ []) do
    previous = Application.get_env(:apiary, @boundary)

    stubs =
      Keyword.drop(
        [
          artifacts: __MODULE__.Artifacts,
          processes: __MODULE__.Processes,
          features: __MODULE__.Features
        ],
        real
      )

    Application.put_env(:apiary, @boundary, stubs)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:apiary, @boundary, previous),
        else: Application.delete_env(:apiary, @boundary)
    end)

    :ok
  end

  @doc "Sets the stubs' value `key`."
  def put(key, value), do: Process.put({__MODULE__, key}, value)

  @doc "The stubs' value `key`, or `default`."
  def get(key, default \\ nil), do: Process.get({__MODULE__, key}, default)

  @doc """
  Every version pushed through the boundary, oldest first: the fields of
  `Apiary.Artifacts.Version` as a map, with `opts`, the options of the push and its
  actor, and each file with its `content`.
  """
  def pushed, do: get(:versions, [])

  @doc false
  def record(version, opts) do
    files =
      Enum.map(version.files, fn file ->
        {:ok, path} = Apiary.Artifacts.open_file(file)
        file |> Map.from_struct() |> Map.put(:content, File.read!(path))
      end)

    entry = version |> Map.from_struct() |> Map.merge(%{opts: opts, files: files})
    put(:versions, pushed() ++ [entry])
  end

  defmodule Features do
    @moduledoc "The feature `workflow_model`, on unless the stubs' `:flag` is false."
    def all, do: [:workflow_model]
    def on?(:workflow_model), do: ApiaryWeb.RunApiStubs.get(:flag, true)
  end

  defmodule Processes do
    @moduledoc "A workflow's declaration: the stubs' `:declaration`, the name recorded."
    def workflow_declaration(_workspace, name) do
      ApiaryWeb.RunApiStubs.put(:declared, name)
      ApiaryWeb.RunApiStubs.get(:declaration)
    end
  end

  defmodule Artifacts do
    @moduledoc """
    `Apiary.Artifacts`, with `push/5` recorded, or refused with the stubs' `:push_error`.
    """
    alias ApiaryWeb.RunApiStubs

    defdelegate type(workspace, name), to: Apiary.Artifacts
    defdelegate get_version!(id), to: Apiary.Artifacts
    defdelegate newest(work_item, type, name), to: Apiary.Artifacts
    defdelegate open_file(file), to: Apiary.Artifacts

    def push(actor, work_item, type, files, opts) do
      case RunApiStubs.get(:push_error) do
        nil ->
          with {:ok, version} <- Apiary.Artifacts.push(actor, work_item, type, files, opts) do
            RunApiStubs.record(version, [actor: actor] ++ opts)
            {:ok, version}
          end

        error ->
          {:error, error}
      end
    end
  end
end
