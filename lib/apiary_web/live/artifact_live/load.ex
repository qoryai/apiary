defmodule ApiaryWeb.ArtifactLive.Load do
  # What the artifact pages read (`ApiaryWeb.ArtifactLive.Show`, `ApiaryWeb.ArtifactLive.New`):
  # a work item by its number for a reader who may read it, a version of one of its
  # artifacts, a type, and the content of the files a view shows.
  #
  # The module reference leaves out this module of the `workflow_model` feature.
  @moduledoc false

  use Gettext, backend: ApiaryWeb.Gettext

  alias Apiary.{Access, Artifacts, Processes, PublicId, WorkItems}
  alias Apiary.Artifacts.{Type, Version}
  alias ApiaryWeb.ArtifactLive.Markdown

  # The most bytes of a structured file the view decodes: the largest a structured type
  # takes (`Apiary.Artifacts.Type`).
  @max_json 1_048_576

  # work_item/2 is the work item of the scope's workspace numbered `number`, for a reader
  # who may read it, or nil.
  @doc false
  @spec work_item(Apiary.Accounts.Scope.t(), term) :: Apiary.WorkItems.WorkItem.t() | nil
  def work_item(scope, number) do
    with %{} = work_item <- WorkItems.get_by_number(scope, number),
         true <- Access.can?(scope, :"work_item.read", work_item) do
      work_item
    else
      _not -> nil
    end
  end

  # version/2 is the version `version_id` (`av_…`) of one of `work_item`'s artifacts,
  # with its artifact, files, user and run; nil for any other id.
  @doc false
  @spec version(Apiary.WorkItems.WorkItem.t(), term) :: Version.t() | nil
  def version(work_item, version_id) do
    with true <- PublicId.valid?(Version.prefix(), version_id),
         %Version{artifact: artifact} = version <- get_version(version_id),
         true <- artifact.work_item_id == work_item.id,
         true <- artifact.workspace_id == work_item.workspace_id do
      version
    else
      _not -> nil
    end
  end

  defp get_version(version_id) do
    Artifacts.get_version!(version_id)
  rescue
    Ecto.NoResultsError -> nil
  end

  # type/2 is the type of `name` in the work item's workspace; a type no longer there is
  # shown as a file, a download.
  @doc false
  @spec type(Apiary.WorkItems.WorkItem.t(), String.t()) :: Type.t()
  def type(work_item, name) do
    workspace = %Apiary.Organisations.Workspace{
      id: work_item.workspace_id,
      organisation_id: work_item.organisation_id
    }

    Artifacts.type(workspace, name) ||
      %Type{name: name, base_view: :file, size_limit: 0, max_files: 1}
  end

  # stage_name/2 is the name of the stage `stage_id` in the work item's process version,
  # the id itself where the version has no such stage, nil for none.
  @doc false
  @spec stage_name(Apiary.WorkItems.WorkItem.t(), String.t() | nil) :: String.t() | nil
  def stage_name(_work_item, nil), do: nil

  def stage_name(work_item, stage_id) do
    case Processes.stage(Processes.version_for(work_item), stage_id) do
      %{"name" => name} when is_binary(name) -> name
      _none -> stage_id
    end
  end

  # content/3 is what a view shows of the version's files, by filename: for a document,
  # the file `shown` only, the first file where it is nil or no file's name, as
  # `{:markdown, rendered}`, the file's text as `Markdown.render/1` returns it, for a file
  # of at most `Markdown.max_bytes/0` bytes whose render stays within the budget, else
  # `:too_large`; for a structured type,
  # every file as `{:json, value}`, or `:unreadable`. Nothing for other views. The page
  # reads it on its connected mount, and again for each document file the reader opens
  # (`ApiaryWeb.ArtifactLive.Show`): rendering a document costs up to 64 MiB of heap and
  # seconds, so a page renders one at a time.
  @doc false
  @spec content(Type.t(), Version.t(), String.t() | nil) :: map
  def content(type, version, shown \\ nil)

  def content(%Type{base_view: :document}, %Version{files: files}, shown) do
    case Enum.find(files, &(&1.filename == shown)) || List.first(files) do
      nil ->
        %{}

      file ->
        case read(file, Markdown.max_bytes()) do
          {:ok, text} -> %{file.filename => markdown(text)}
          :error -> %{file.filename => :too_large}
        end
    end
  end

  def content(%Type{base_view: :structured}, %Version{files: files}, _shown) do
    Map.new(files, fn file ->
      with {:ok, bytes} <- read(file, @max_json),
           {:ok, value} <- Jason.decode(bytes) do
        {file.filename, {:json, value}}
      else
        _not -> {file.filename, :unreadable}
      end
    end)
  end

  def content(_type, _version, _shown), do: %{}

  defp markdown(text) do
    case Markdown.render(text) do
      :too_large -> :too_large
      rendered -> {:markdown, rendered}
    end
  end

  # The file's bytes, where it has at most `limit` of them. The recorded size is checked
  # first, and no more than `limit` + 1 bytes are read, so a larger file never reaches the
  # page's process.
  defp read(%{size: size}, limit) when size > limit, do: :error

  defp read(file, limit) do
    case Artifacts.open_file(file) do
      {:ok, path} when is_binary(path) ->
        case File.open(path, [:read, :binary], &IO.binread(&1, limit + 1)) do
          {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= limit -> {:ok, bytes}
          {:ok, :eof} -> {:ok, ""}
          _other -> :error
        end

      {:ok, stream} ->
        bytes =
          Enum.reduce_while(stream, [], fn chunk, acc ->
            acc = [acc | chunk]
            if IO.iodata_length(acc) > limit, do: {:halt, :too_large}, else: {:cont, acc}
          end)

        if bytes == :too_large, do: :error, else: {:ok, IO.iodata_to_binary(bytes)}

      _error ->
        :error
    end
  end

  # base_view/1 is a base view in words, for a type's line.
  @doc false
  @spec base_view(Type.base_view()) :: String.t()
  def base_view(:document), do: gettext("Document")
  def base_view(:image), do: gettext("Image")
  def base_view(:video), do: gettext("Video")
  def base_view(:file), do: gettext("File")
  def base_view(:structured), do: gettext("Structured")
end
