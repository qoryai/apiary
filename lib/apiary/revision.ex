defmodule Apiary.Revision do
  @moduledoc """
  The commit the release was built from, which `GET /health` reports as `revision`.

  The image's build writes it to the file `REVISION` at the release's root, from the build
  argument `APIARY_REVISION`, and the release reads it once, at boot. A file and not an
  environment variable, so no setting can change what a running release says it is. A
  build without the argument (a local `docker build`, development and the tests) has no
  file, and the revision is `nil`.
  """

  @doc """
  Reads the revision from `path`, by default the release's `REVISION`, and keeps it for
  `get/0`. Called once, at boot.
  """
  @spec boot!(Path.t()) :: String.t() | nil
  def boot!(path \\ Path.join(:code.root_dir(), "REVISION")) do
    revision = read(path)
    Application.put_env(:apiary, :revision, revision)
    revision
  end

  @doc "The revision read at boot, or `nil` when the release has none."
  @spec get() :: String.t() | nil
  def get, do: Application.get_env(:apiary, :revision)

  # The file's first line; no file, or an empty one, is no revision.
  defp read(path) do
    case File.read(path) do
      {:ok, contents} ->
        case contents |> String.split("\n", parts: 2) |> hd() |> String.trim() do
          "" -> nil
          revision -> revision
        end

      {:error, _reason} ->
        nil
    end
  end
end
