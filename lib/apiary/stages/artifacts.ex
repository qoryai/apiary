defmodule Apiary.Stages.Artifacts do
  # Artifacts is the one place the stage runner (`Apiary.Stages`) reaches a work item's
  # artifacts through: `push/5`, `list/1` and `exists?/3` of `Apiary.Artifacts`, and two
  # steps of its own: `push_json/5` and `read_json/1`.
  @moduledoc false

  alias Apiary.Artifacts

  # push/5 stores a new version of the work item's artifact of `type`
  # (`Apiary.Artifacts.push/5`): `{:ok, version}` or a refusal.
  @doc false
  @spec push(term, struct, String.t(), [map], keyword) :: {:ok, map} | {:error, term}
  def push(actor, work_item, type, files, opts),
    do: Artifacts.push(actor, work_item, type, files, opts)

  # push_json/5 stores `document` as the one file of a new version of `type`, named
  # `<type>.json`.
  @doc false
  @spec push_json(term, struct, String.t(), map, keyword) :: {:ok, map} | {:error, term}
  def push_json(actor, work_item, type, document, opts) do
    file = %{
      filename: type <> ".json",
      content_type: "application/json",
      binary: Jason.encode!(document)
    }

    push(actor, work_item, type, [file], opts)
  end

  # list/1 is the work item's artifacts, each with its versions, newest first.
  @doc false
  @spec list(struct) :: [map]
  def list(work_item), do: Artifacts.list(work_item)

  # exists?/3 is the Exists check of an output of `type` made in `stage_id`.
  @doc false
  @spec exists?(struct, String.t(), String.t()) :: boolean
  def exists?(work_item, stage_id, type), do: Artifacts.exists?(work_item, stage_id, type)

  # read_json/1 is the decoded JSON of a version's first file, nil when it cannot be read
  # or decoded.
  @doc false
  @spec read_json(map) :: map | nil
  def read_json(%{files: [file | _rest]}) do
    with {:ok, source} <- Artifacts.open_file(file),
         {:ok, text} <- read(source),
         {:ok, %{} = decoded} <- Jason.decode(text) do
      decoded
    else
      _other -> nil
    end
  end

  def read_json(_version), do: nil

  defp read(path) when is_binary(path), do: File.read(path)
  defp read(stream), do: {:ok, stream |> Enum.to_list() |> IO.iodata_to_binary()}
end
