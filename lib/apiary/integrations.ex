defmodule Apiary.Integrations do
  @moduledoc """
  Integrations finds an integration's release for a workspace: it records the request,
  fetches the release's `description.json` in a job, and checks what it found, so that a
  page can show the integration before anyone adds it (`Apiary.Connections`).

  ## A request

  `request_release/2` takes a `source` (`Apiary.Integrations.Source`): a forge path with
  its `forge_kind` and an exact `version`, or an https URL of a `description.json` and no
  version. A forge release already found in the workspace, intact, is given back as it
  is: a release's files do not change under its version. Otherwise it records a
  `pending` release (`Apiary.Integrations.Release`) and enqueues
  `Apiary.Integrations.FetchJob`, in one transaction, with a `connection.write` entry in
  the audit trail.

  ## The fetch

  `fetch_release/2` reads the release's `description.json` and `checksums.txt` from where
  the integrations contract says they are, through `Apiary.Integrations.Fetch` and its
  guards, with the token the edition gives (`c:Apiary.Edition.release_token/2`; none in
  the core), then records the release `ready`, or `failed` with a code:

    * `fetch_failed`, for every failure to fetch, whatever it was: what failed is in the
      log, never on a page;
    * `integration_source_mismatch`, when what came is not what the source vouches for:
      `checksums.txt` lists no `description.json`, or another digest; the description's
      `program_version` is not the version asked for; or a release of the same source and
      version this workspace found before had another description;
    * `description_invalid` and `placeholder_conflict`, from
      `Apiary.Integrations.Description.parse/1`.

  Nothing of the release runs on the server: it is only read.

  ## Who

  Reading the releases is `connection.read`; asking for one is `connection.write`, and
  the job asks it again of the person who asked.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{Access, Audit, Edition, LogMetadata, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Integrations.{Description, Fetch, FetchJob, Release, Source}
  alias Apiary.Kinds.{CanonicalJSON, Coded}
  alias Apiary.Organisations.{Organisation, Workspace}

  @description_max 262_144
  @checksums_max 65_536

  @typedoc "Why a request is refused: the reasons of `Apiary.Access`, or a changeset."
  @type refusal :: Access.reason() | Ecto.Changeset.t()

  ## Reading

  @doc """
  get_release/2 is the scope's workspace's release with the id `id`: `{:ok, release}`,
  for a reader who may `connection.read`; else `{:error, reason}`, `:not_found` for one
  the workspace does not have, or one whose row is not as it was written, which is
  logged.
  """
  @spec get_release(Scope.t(), term) :: {:ok, Release.t()} | {:error, Access.reason()}
  def get_release(%Scope{} = scope, id) do
    with {:ok, workspace} <- workspace(scope),
         :ok <- Access.authorize(scope, :"connection.read", workspace),
         {:ok, uuid} <- Ecto.UUID.cast(id),
         %Release{} = release <- Repo.one(from r in releases(scope), where: r.id == ^uuid),
         true <- intact(release) do
      {:ok, release}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  description/1 is a ready release's description, read: `{:ok, description}`, or
  `{:error, :not_ready}`.
  """
  @spec description(Release.t()) :: {:ok, Description.t()} | {:error, :not_ready}
  def description(%Release{state: "ready", description: bytes}) when is_binary(bytes) do
    case Description.parse(bytes) do
      {:ok, description} -> {:ok, description}
      {:error, _reason} -> {:error, :not_ready}
    end
  end

  def description(%Release{}), do: {:error, :not_ready}

  @doc """
  intact/1 says whether `release` is as it was written (`Apiary.Integrations.Release.intact?/1`),
  and logs an error when it is not.
  """
  @spec intact(Release.t()) :: boolean
  def intact(%Release{} = release) do
    if Release.intact?(release) do
      true
    else
      Logger.error(
        "an integration release fails its integrity code release_id=#{release.id}",
        LogMetadata.metadata(release.organisation_id, release.workspace_id)
      )

      false
    end
  end

  defp releases(%Scope{organisation: %Organisation{id: org}, workspace: %Workspace{id: ws}}),
    do: from(r in Release, where: r.organisation_id == ^org and r.workspace_id == ^ws)

  defp workspace(%Scope{workspace: %Workspace{} = workspace}), do: {:ok, workspace}
  defp workspace(_scope), do: {:error, :not_found}

  ## Asking

  @doc """
  request_release/2 asks for a release of an integration (`connection.write`): `attrs`
  has `source`, `forge_kind` (a forge path off the public forges) and `version` (a forge
  path; none for a URL). `{:ok, release}`, pending with its fetch enqueued, or one found
  before; or `{:error, refusal}`, a changeset whose errors are on `source`, `forge_kind`
  or `version`.
  """
  @spec request_release(Scope.t(), map) :: {:ok, Release.t()} | {:error, refusal}
  def request_release(%Scope{} = scope, attrs) do
    with {:ok, workspace} <- workspace(scope),
         :ok <- Access.authorize(scope, :"connection.write", workspace),
         {:ok, %{source: source} = request} <- request_changeset(attrs) do
      version = Map.get(request, :version)

      case found(scope, source, version) do
        %Release{} = release -> {:ok, release}
        nil -> insert_request(scope, workspace, source, version)
      end
    end
  end

  @request_types %{source: :string, forge_kind: :string, version: :string}

  @doc """
  change_request/1 is the changeset of a request's `source`, `forge_kind` and `version`,
  for a form; its errors are the ones `request_release/2` gives.
  """
  @spec change_request(map) :: Ecto.Changeset.t()
  def change_request(attrs \\ %{}) do
    {%{}, @request_types}
    |> Ecto.Changeset.cast(attrs, Map.keys(@request_types))
    |> Ecto.Changeset.update_change(:source, &String.trim/1)
    |> Ecto.Changeset.update_change(:version, &String.trim/1)
    |> Ecto.Changeset.validate_required([:source])
    |> validate_source()
  end

  defp request_changeset(attrs) do
    changeset = change_request(attrs)

    if changeset.valid?,
      do: {:ok, Ecto.Changeset.apply_changes(changeset)},
      else: {:error, %{changeset | action: :insert}}
  end

  defp validate_source(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp validate_source(changeset) do
    source = Ecto.Changeset.get_field(changeset, :source)
    version = Ecto.Changeset.get_field(changeset, :version)

    case Source.parse(source, Ecto.Changeset.get_field(changeset, :forge_kind)) do
      {:ok, %Source{form: :forge} = parsed} ->
        changeset = Ecto.Changeset.put_change(changeset, :source, parsed)

        cond do
          is_nil(version) ->
            Ecto.Changeset.add_error(
              changeset,
              :version,
              dgettext_noop("errors", "can't be blank")
            )

          not Source.version?(version) ->
            Ecto.Changeset.add_error(
              changeset,
              :version,
              dgettext_noop("errors", "must be a version such as 1.4.0")
            )

          true ->
            changeset
        end

      {:ok, %Source{form: :url} = parsed} ->
        changeset = Ecto.Changeset.put_change(changeset, :source, parsed)

        if is_nil(version),
          do: changeset,
          else:
            Ecto.Changeset.add_error(
              changeset,
              :version,
              dgettext_noop("errors", "is read from the description at an address")
            )

      {:error, :forge_kind_required} ->
        Ecto.Changeset.add_error(
          changeset,
          :forge_kind,
          dgettext_noop("errors", "says which forge the server runs")
        )

      {:error, :forge_kind_invalid} ->
        Ecto.Changeset.add_error(
          changeset,
          :forge_kind,
          dgettext_noop("errors", "is not the forge this source is on")
        )

      {:error, :path_invalid} ->
        Ecto.Changeset.add_error(
          changeset,
          :source,
          dgettext_noop("errors", "must be owner/repo")
        )

      {:error, :source_invalid} ->
        Ecto.Changeset.add_error(
          changeset,
          :source,
          dgettext_noop(
            "errors",
            "must be a repository's path or an https address of a description.json"
          )
        )
    end
  end

  # A forge release found before, intact; a URL is fetched again each time, since its
  # files may be replaced.
  defp found(_scope, %Source{form: :url}, _version), do: nil

  defp found(scope, %Source{source: source}, version) do
    from(r in releases(scope),
      where: r.source == ^source and r.requested_version == ^version and r.state == "ready",
      order_by: [desc: r.inserted_at],
      limit: 1
    )
    |> Repo.one()
    |> case do
      %Release{} = release -> if intact(release), do: release
      nil -> nil
    end
  end

  defp insert_request(scope, workspace, %Source{} = source, version) do
    Repo.transact(fn ->
      changeset =
        %Release{
          id: Ecto.UUID.generate(),
          organisation_id: workspace.organisation_id,
          workspace_id: workspace.id,
          requested_by_id: scope.user && scope.user.id
        }
        |> Ecto.Changeset.change(
          source: source.source,
          forge_kind: source.forge_kind,
          requested_version: version,
          state: "pending"
        )
        |> Coded.seal()

      with {:ok, release} <- Repo.insert(changeset),
           {:ok, _job} <- Oban.insert(FetchJob.for_scope(scope, %{"release_id" => release.id})),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"connection.write", release, %{
               details: %{
                 change: "release_requested",
                 name: release.source,
                 source: release.source,
                 forge_kind: release.forge_kind,
                 version: release.requested_version
               }
             }) do
        {:ok, release}
      end
    end)
  end

  ## Fetching

  @doc """
  fetch_release/2 fetches the pending release with the id `release_id` of the scope's
  workspace (`connection.write`) and records what was found (see the module's
  documentation): `{:ok, release}`, ready or failed, or as it was when it is no longer
  pending; `{:error, reason}` from `Apiary.Access`, or `:not_found`.
  """
  @spec fetch_release(Scope.t(), term) :: {:ok, Release.t()} | {:error, Access.reason()}
  def fetch_release(%Scope{} = scope, release_id) do
    with {:ok, workspace} <- workspace(scope),
         :ok <- Access.authorize(scope, :"connection.write", workspace),
         %Release{} = release <- Repo.one(from r in releases(scope), where: r.id == ^release_id) do
      if release.state == "pending" and intact(release) do
        outcome = outcome(scope, release)
        record(scope, release, outcome)
      else
        {:ok, release}
      end
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  defp outcome(scope, %Release{} = release) do
    {:ok, source} = Source.parse(release.source, release.forge_kind)
    token = Edition.release_token(scope, source)

    get = fn file, max ->
      Fetch.get(Source.download_url(source, release.requested_version, file),
        token: token,
        max_bytes: max
      )
    end

    with {:ok, bytes} <- get.("description.json", @description_max),
         {:ok, checksums} <- get.("checksums.txt", @checksums_max),
         sha = CanonicalJSON.sha256(bytes),
         :ok <- listed(checksums, sha, release),
         {:ok, description} <- parse(bytes, release),
         :ok <- version(description, release),
         :ok <- same_as_before(scope, release, description, sha) do
      {:ready, bytes, sha, description}
    else
      {:error, :fetch_failed} -> {:failed, "fetch_failed"}
      {:failed, code} -> {:failed, code}
    end
  end

  defp listed(checksums, sha, release) do
    if checksum(checksums, "description.json") == sha,
      do: :ok,
      else: mismatch(release, "checksums.txt does not list the description.json fetched")
  end

  @doc """
  checksum/2 is the lowercase SHA-256 `checksums.txt` lists for `file`, in the format
  `sha256sum` writes, or nil.
  """
  @spec checksum(binary, String.t()) :: String.t() | nil
  def checksum(checksums, file) when is_binary(checksums) do
    checksums
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.find_value(fn line ->
      case Regex.run(~r/\A([0-9a-fA-F]{64}) [ *](.+)\z/, String.trim_trailing(line)) do
        [_, hash, ^file] -> String.downcase(hash)
        _ -> nil
      end
    end)
  end

  defp parse(bytes, release) do
    case Description.parse(bytes) do
      {:ok, description} ->
        {:ok, description}

      {:error, {code, details}} ->
        Logger.warning(
          "an integration release's description is refused release_id=#{release.id} " <>
            "code=#{code} details=#{inspect(details)}",
          LogMetadata.metadata(release.organisation_id, release.workspace_id)
        )

        {:failed, Atom.to_string(code)}
    end
  end

  defp version(%Description{program_version: version}, %Release{requested_version: nil} = release) do
    if Source.version?(version),
      do: :ok,
      else: mismatch(release, "program_version #{inspect(version)} is not an exact version")
  end

  defp version(%Description{program_version: version}, %Release{requested_version: version}),
    do: :ok

  defp version(%Description{program_version: version}, release),
    do: mismatch(release, "program_version #{inspect(version)} is not the version asked for")

  # A release of this source and version found before with another description: the
  # files under a version were replaced.
  defp same_as_before(scope, release, description, sha) do
    other =
      from(r in releases(scope),
        where:
          r.source == ^release.source and r.version == ^description.program_version and
            r.state == "ready" and r.description_sha256 != ^sha,
        select: r.id,
        limit: 1
      )
      |> Repo.one()

    if other,
      do: mismatch(release, "release #{other} of this version had another description"),
      else: :ok
  end

  defp mismatch(release, why) do
    Logger.warning(
      "an integration release does not match its source release_id=#{release.id} " <>
        "source=#{release.source}: #{why}",
      LogMetadata.metadata(release.organisation_id, release.workspace_id)
    )

    {:failed, "integration_source_mismatch"}
  end

  defp record(scope, %Release{id: id}, outcome) do
    Repo.transact(fn ->
      case Repo.one(from r in releases(scope), where: r.id == ^id, lock: "FOR UPDATE") do
        %Release{state: "pending"} = release ->
          changes =
            case outcome do
              {:ready, bytes, sha, description} ->
                [
                  state: "ready",
                  description: bytes,
                  description_sha256: sha,
                  name: description.name,
                  version: description.program_version
                ]

              {:failed, code} ->
                [state: "failed", failure: code]
            end

          release
          |> Ecto.Changeset.change([fetched_at: DateTime.utc_now()] ++ changes)
          |> Coded.seal()
          |> Repo.update()

        %Release{} = release ->
          {:ok, release}

        nil ->
          {:error, :not_found}
      end
    end)
  end
end
