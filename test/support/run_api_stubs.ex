defmodule ApiaryWeb.RunApiStubs do
  @moduledoc """
  Stubs for the run API's tests (`ApiaryWeb.Contract.RunApi.Boundary`): `Artifacts`, a
  stand-in for `Apiary.Artifacts` with the shapes and errors of its `push/5`, `type/2`,
  `list/1`, `versions/1`, `newest/2`, `get_version!/1` and `open_file/1`, until it is
  merged; `Processes`, a declaration set by the test; and `Features`, the flag
  `workflow_model`. `install/1` sets them in the application's configuration until the
  test ends, so a test that uses them is not async. `Artifacts` is also set as the module
  `Apiary.Stages.Artifacts` reads, so the stage runner's reads (`Apiary.Stages`) see the
  same versions.

  Their state is the test process's: a request through `Phoenix.ConnTest` runs in that
  process. `put/2` sets a value:

    * `:flag`: whether `workflow_model` is on, true unless set;
    * `:declaration`: what `Processes.workflow_declaration/2` returns, nil unless set;
    * `:types`: the artifact types by name, `types/0` unless set;
    * `:push_error`: an error `Artifacts.push/5` returns in place of a version.

  `Artifacts.push/5` keeps each version, the files' contents among them, and the options
  it was given; `pushed/0` lists them, oldest first, and `stored/3` adds one as a push
  would, for any work item.
  """

  @boundary ApiaryWeb.Contract.RunApi.Boundary

  @doc """
  Sets the stubs in the application's configuration until the test ends, but for the
  ones named in `real` (`:artifacts`, `:processes` or `:features`), which stay the
  modules the boundary calls by default.
  """
  def install(real \\ []) do
    previous = Application.get_env(:apiary, @boundary)
    previous_stages = Application.get_env(:apiary, Apiary.Stages.Artifacts)

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

    unless :artifacts in real,
      do: Application.put_env(:apiary, Apiary.Stages.Artifacts, __MODULE__.Artifacts)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:apiary, @boundary, previous),
        else: Application.delete_env(:apiary, @boundary)

      if previous_stages,
        do: Application.put_env(:apiary, Apiary.Stages.Artifacts, previous_stages),
        else: Application.delete_env(:apiary, Apiary.Stages.Artifacts)
    end)

    :ok
  end

  @doc "Sets the stubs' value `key`."
  def put(key, value), do: Process.put({__MODULE__, key}, value)

  @doc "The stubs' value `key`, or `default`."
  def get(key, default \\ nil), do: Process.get({__MODULE__, key}, default)

  @doc """
  The artifact types the stubs have unless `:types` is set, each with `size_limit`, the
  bytes of all files of one version together, and `max_files`.
  """
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

  @doc """
  Stores a version of `type` for `work_item_id` with `files`, as a push stores one, in
  the shape of `Apiary.Artifacts.Version`: `public_id`, `number`, `writer`, `run_id`,
  `user_id`, `stage_id`, `note`, `inserted_at`, `artifact` and `files`.
  """
  def stored(work_item_id, type, files, opts \\ []) do
    versions = pushed()
    name = Keyword.get(opts, :name, "main")

    number =
      Enum.count(
        versions,
        &(&1.artifact.work_item_id == work_item_id and &1.artifact.type == type and
            &1.artifact.name == name)
      ) + 1

    run_id =
      case Keyword.get(opts, :actor) do
        {:run, %{id: id}} -> id
        _other -> nil
      end

    version = %{
      id: Ecto.UUID.generate(),
      public_id: Apiary.PublicId.generate("av"),
      number: number,
      writer: :run,
      run_id: run_id,
      user_id: nil,
      stage_id: Keyword.get(opts, :stage_id),
      note: Keyword.get(opts, :note),
      inserted_at: DateTime.utc_now(),
      artifact: %{work_item_id: work_item_id, type: type, name: name},
      opts: opts,
      files:
        Enum.map(files, fn file ->
          %{
            filename: file.filename,
            content_type: file.content_type,
            size: byte_size(file.binary),
            sha256: Base.encode16(:crypto.hash(:sha256, file.binary), case: :lower),
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
    @moduledoc "Artifacts kept in the test process, in the shapes of `Apiary.Artifacts`."
    alias ApiaryWeb.RunApiStubs

    def type(_workspace, name), do: Map.get(RunApiStubs.get(:types, RunApiStubs.types()), name)

    def push({:run, _run} = actor, work_item, type, files, opts) do
      case RunApiStubs.get(:push_error) || verdict_refusal(type, files) do
        nil -> {:ok, RunApiStubs.stored(work_item.id, type, files, [actor: actor] ++ opts)}
        error -> {:error, error}
      end
    end

    # The format check of the type `verdict`, as `Apiary.Artifacts.Format` makes it with
    # `priv/schemas/artifacts/verdict.schema.json`: one JSON document, `verdict` one of
    # the three values, `gaps` absent or a text of 1 to 20000 code points without the
    # characters the schema refuses (null is refused), no other member; else the
    # refusal `Apiary.Artifacts.push/5` returns.
    defp verdict_refusal("verdict", [%{binary: binary}]) do
      case Jason.decode(binary) do
        {:ok, %{"verdict" => verdict} = document}
        when verdict in ["passed", "changes-requested", "escalate"] ->
          if Map.keys(document) -- ["verdict", "gaps"] == [] and gaps?(document),
            do: nil,
            else: {:invalid, {:schema, 0}}

        {:ok, _document} ->
          {:invalid, {:schema, 0}}

        {:error, _reason} ->
          {:invalid, {:format, 0}}
      end
    end

    defp verdict_refusal(_type, _files), do: nil

    # The characters the schema refuses in `gaps`, as
    # `ApiaryWeb.Contract.RunApi.Body` refuses them.
    @refused_in_gaps ~r/[\x{0}-\x{8}\x{B}\x{C}\x{E}-\x{1F}\x{7F}-\x{9F}\x{AD}\x{61C}\x{180E}\x{200B}\x{200E}\x{200F}\x{2028}\x{2029}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{2066}-\x{2069}\x{FEFF}\x{FFF9}-\x{FFFB}]/u

    defp gaps?(document) do
      case Map.fetch(document, "gaps") do
        :error ->
          true

        {:ok, gaps} when is_binary(gaps) ->
          gaps != "" and length(String.codepoints(gaps)) <= 20_000 and
            not Regex.match?(@refused_in_gaps, gaps)

        {:ok, _not_text} ->
          false
      end
    end

    # The work item's artifacts by type and name, versions newest first.
    def list(work_item) do
      RunApiStubs.pushed()
      |> Enum.filter(&(&1.artifact.work_item_id == work_item.id))
      |> Enum.group_by(&{&1.artifact.type, &1.artifact.name})
      |> Enum.sort()
      |> Enum.map(fn {{type, name}, versions} ->
        %{type: type, name: name, versions: Enum.sort_by(versions, & &1.number, :desc)}
      end)
    end

    def versions(artifact), do: artifact.versions

    def get_version!(id) do
      Enum.find(RunApiStubs.pushed(), &(&1.public_id == id)) ||
        raise Ecto.NoResultsError, queryable: "artifact_versions"
    end

    def newest(work_item, type, name \\ "main") do
      RunApiStubs.pushed()
      |> Enum.filter(
        &(&1.artifact.work_item_id == work_item.id and &1.artifact.type == type and
            &1.artifact.name == name)
      )
      |> List.last()
    end

    def exists?(work_item, stage_id, type) do
      Enum.any?(
        RunApiStubs.pushed(),
        &(&1.artifact.work_item_id == work_item.id and &1.artifact.type == type and
            &1.stage_id == stage_id)
      )
    end

    def open_file(file), do: {:ok, [file.content]}
  end
end
