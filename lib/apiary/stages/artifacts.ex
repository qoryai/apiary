defmodule Apiary.Stages.Artifacts do
  # Artifacts is the one place the stage runner (`Apiary.Stages`) reaches a work item's
  # artifacts through: `push/5`, `list/1` and `exists?/3` of `Apiary.Artifacts`, and
  # `push_json/5`, `newest_of_run/3`, `read_json/1` and `stored_json/1`, which this module
  # adds.
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Apiary.Artifacts
  alias Apiary.Artifacts.{Artifact, ArtifactFile, Version}
  alias Apiary.Repo

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

  # newest_of_run/3 is the newest version of the artifact of `type` and `name` that the
  # run of the queue `run_id` pushed, with its files in the order of their names; nil for
  # none.
  @doc false
  @spec newest_of_run(Ecto.UUID.t(), String.t(), String.t()) :: Version.t() | nil
  def newest_of_run(run_id, type, name) do
    Repo.one(
      from v in Version,
        join: a in Artifact,
        on: a.id == v.artifact_id,
        where: v.run_id == ^run_id and a.type == ^type and a.name == ^name,
        order_by: [desc: v.number],
        limit: 1,
        preload: [files: ^from(f in ArtifactFile, order_by: f.filename)]
    )
  end

  # read_json/1 is the decoded JSON of a version's first file, nil when it cannot be read
  # or decoded.
  @doc false
  @spec read_json(map) :: map | nil
  def read_json(version) do
    case stored_json(version) do
      {:ok, decoded} -> decoded
      {:error, :store_unavailable} -> nil
    end
  end

  # stored_json/1 is the decoded JSON of a version's first file: `{:ok, map}`; `{:ok, nil}`
  # for a version with no file, or a file that is not a JSON object; and
  # `{:error, :store_unavailable}` when the store cannot open or read the file.
  @doc false
  @spec stored_json(map) :: {:ok, map | nil} | {:error, :store_unavailable}
  def stored_json(%{files: [file | _rest]}) do
    with {:ok, source} <- Artifacts.open_file(file),
         {:ok, text} <- read(source) do
      case Jason.decode(text) do
        {:ok, %{} = decoded} -> {:ok, decoded}
        _other -> {:ok, nil}
      end
    else
      _error -> {:error, :store_unavailable}
    end
  end

  def stored_json(_version), do: {:ok, nil}

  defp read(path) when is_binary(path), do: File.read(path)
  defp read(stream), do: {:ok, stream |> Enum.to_list() |> IO.iodata_to_binary()}
end
