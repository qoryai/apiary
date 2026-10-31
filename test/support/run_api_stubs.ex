defmodule ApiaryWeb.RunApiStubs do
  @moduledoc """
  Stubs of the workflow model's modules the run API calls through
  `ApiaryWeb.Contract.RunApi.Boundary`: `Features`, `Processes`, `Artifacts` and `Stages`,
  with the names and return shapes of the workflow model's shared API. `install/0` sets
  them in the application's configuration until the test ends, so a test that uses them is
  not async.

  Their state is the test process's: a request through `Phoenix.ConnTest` runs in that
  process. `put/2` sets a value:

    * `:flag`: whether `workflow_model` is on, true unless set;
    * `:declaration`: what `Processes.workflow_declaration/2` returns, nil unless set;
    * `:types`: the artifact types by name, `types/0` unless set;
    * `:push_error`: an error `Artifacts.push/5` returns in place of a version;
    * `:status`, `:inputs`: what `Stages.status/1` and `Stages.inputs/1` return.

  `Artifacts.push/5` keeps each version, its files' contents among them; `pushed/0` lists
  them, oldest first, and `stored/3` adds one as a push would, for any work item.
  """

  @doc "Sets the stubs in the application's configuration until the test ends."
  def install do
    previous = Application.get_env(:apiary, ApiaryWeb.Contract.RunApi.Boundary)

    Application.put_env(:apiary, ApiaryWeb.Contract.RunApi.Boundary,
      artifacts: __MODULE__.Artifacts,
      processes: __MODULE__.Processes,
      stages: __MODULE__.Stages,
      features: __MODULE__.Features
    )

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:apiary, ApiaryWeb.Contract.RunApi.Boundary, previous),
        else: Application.delete_env(:apiary, ApiaryWeb.Contract.RunApi.Boundary)
    end)

    :ok
  end

  @doc "Sets the stubs' value `key`."
  def put(key, value), do: Process.put({__MODULE__, key}, value)

  @doc "The stubs' value `key`, or `default`."
  def get(key, default \\ nil), do: Process.get({__MODULE__, key}, default)

  @doc "The artifact types the stubs have unless `:types` is set."
  def types do
    %{
      "proposal" => %{name: "proposal", base_view: :structured, size_limit: 1000, max_files: 1},
      "screenshot" => %{name: "screenshot", base_view: :image, size_limit: 16, max_files: 2},
      "demo-video" => %{name: "demo-video", base_view: :video, size_limit: 1000, max_files: 1},
      "explainer" => %{name: "explainer", base_view: :document, size_limit: 1000, max_files: 1},
      "verdict" => %{name: "verdict", base_view: :structured, size_limit: 64_000, max_files: 1},
      "questions" => %{name: "questions", base_view: :structured, size_limit: 1000, max_files: 1}
    }
  end

  @doc "Every version pushed, oldest first."
  def pushed, do: get(:versions, [])

  @doc "Stores a version of `type` for `work_item_id` with `files`, as a push stores one."
  def stored(work_item_id, type, files, opts \\ []) do
    versions = pushed()
    name = Keyword.get(opts, :name, "main")

    number =
      Enum.count(
        versions,
        &(&1.work_item_id == work_item_id and &1.type == type and &1.name == name)
      ) +
        1

    version = %{
      id: Apiary.PublicId.generate("av"),
      number: number,
      type: type,
      name: name,
      work_item_id: work_item_id,
      actor: Keyword.get(opts, :actor),
      stage_id: Keyword.get(opts, :stage_id),
      note: Keyword.get(opts, :note),
      writer: :run,
      run_id: nil,
      inserted_at: DateTime.utc_now(),
      approvals: [],
      files:
        Enum.map(files, fn file ->
          %{
            filename: file.filename,
            content_type: file.content_type,
            size: byte_size(file.binary),
            sha256: :crypto.hash(:sha256, file.binary),
            content: file.binary
          }
        end)
    }

    put(:versions, versions ++ [version])
    version
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
    @moduledoc "Artifacts kept in the test process."
    alias ApiaryWeb.RunApiStubs

    def type(_workspace, name), do: Map.get(RunApiStubs.get(:types, RunApiStubs.types()), name)

    def push({:run, _run} = actor, work_item, type, files, opts) do
      case RunApiStubs.get(:push_error) do
        nil -> {:ok, RunApiStubs.stored(work_item.id, type, files, [actor: actor] ++ opts)}
        error -> {:error, error}
      end
    end

    def list(work_item) do
      RunApiStubs.pushed()
      |> Enum.filter(&(&1.work_item_id == work_item.id))
      |> Enum.group_by(&{&1.type, &1.name})
      |> Enum.map(fn {{type, name}, versions} ->
        %{type: type, name: name, versions: versions}
      end)
    end

    def versions(artifact), do: artifact.versions

    def get_version!(id) do
      Enum.find(RunApiStubs.pushed(), &(&1.id == id)) || raise Ecto.NoResultsError
    end

    def newest(work_item, type) do
      RunApiStubs.pushed()
      |> Enum.filter(&(&1.work_item_id == work_item.id and &1.type == type))
      |> List.last()
    end

    def open_file(file), do: {:ok, [file.content]}
  end

  defmodule Stages do
    @moduledoc "The stage's status, its inputs and the artifact index, from the stubs."
    alias ApiaryWeb.RunApiStubs

    def status(_work_item) do
      RunApiStubs.get(:status, %{
        stage: %{"id" => "st_explore00000", "name" => "Explore"},
        round: 1,
        rounds: 3,
        state: :running,
        gaps: nil,
        outputs: [%{type: "proposal", required: true, version: nil, check: :missing}],
        inputs: [],
        escalation: nil,
        gate: %{approvable?: false, approvals: []}
      })
    end

    def inputs(_work_item), do: RunApiStubs.get(:inputs, [])

    def artifact_index(work_item) do
      for artifact <- Artifacts.list(work_item) do
        %{
          type: artifact.type,
          name: artifact.name,
          stage_id: nil,
          approved_version: nil,
          changed_after_approval: false,
          versions: artifact.versions
        }
      end
    end
  end
end
