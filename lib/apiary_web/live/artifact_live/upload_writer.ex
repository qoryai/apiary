defmodule ApiaryWeb.ArtifactLive.UploadWriter do
  # The upload writer of Add a version (`ApiaryWeb.ArtifactLive.New`): it writes a file's
  # chunks to a temporary file, as LiveView's default writer does, where the page lets the
  # file in, else it writes nothing.
  #
  # LiveView starts a writer for each file as the browser begins to send it, and caps the
  # bytes of each file at the size the browser gave for it. The page lets a file in only
  # while the sizes of all its files come to at most the chosen type's size limit and
  # there are at most its most files (`fits: true`); with `fits: false`, `init/1` returns
  # `{:error, :too_large}` and LiveView ends that file's upload before a byte is written.
  # So the files of one Add version take at most the chosen type's size limit in the
  # temporary folder.
  #
  # The module reference leaves out this module of the `workflow_model` feature.
  @moduledoc false

  @behaviour Phoenix.LiveView.UploadWriter

  @impl true
  def init(opts) do
    if Keyword.fetch!(opts, :fits) do
      with {:ok, path} <- Plug.Upload.random_file("artifact_upload"),
           {:ok, file} <- File.open(path, [:binary, :write]),
           do: {:ok, %{path: path, file: file}}
    else
      {:error, :too_large}
    end
  end

  @impl true
  def meta(state), do: %{path: state.path}

  @impl true
  def write_chunk(data, state) do
    case :file.write(state.file, data) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  def close(state, _reason) do
    case File.close(state.file) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end
end
