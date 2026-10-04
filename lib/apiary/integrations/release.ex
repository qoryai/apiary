defmodule Apiary.Integrations.Release do
  @moduledoc """
  A release of an integration a workspace asked for (`Apiary.Integrations`): its `source`
  and `forge_kind` (`Apiary.Integrations.Source`), the version asked for (none for a URL
  source, whose one release is whatever its URL serves), and what the fetch found.

  `state` is `pending` until the fetch ends, then `ready`, with the release's
  `description.json` byte for byte (`description`), its SHA-256 (`description_sha256`),
  the integration's `name` and `version` as it says, and its publisher's name and URL
  (`publisher_name`, `publisher_url`, the URL nil when it names none), shown beside the
  source's owner and never verified, or `failed`, with `failure`, a
  code: `fetch_failed`, `description_invalid`, `placeholder_conflict` or
  `integration_source_mismatch`.

  The row carries an integrity code over its source, its state and what the fetch found,
  the description by its digest (`Apiary.Kinds.Coded`); a reader checks the code, and that
  the description's bytes have that digest, before it trusts them.
  """
  use Ecto.Schema

  @typedoc "A release of an integration."
  @type t :: %__MODULE__{}

  @states ~w(pending ready failed)
  @failures ~w(fetch_failed description_invalid placeholder_conflict integration_source_mismatch)

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "integration_releases" do
    field :source, :string
    field :forge_kind, :string
    field :requested_version, :string
    field :state, :string, default: "pending"
    field :failure, :string
    field :name, :string
    field :version, :string
    field :publisher_name, :string
    field :publisher_url, :string
    field :description, :string, redact: true
    field :description_sha256, :string
    field :fetched_at, :utc_datetime_usec
    field :integrity_key_id, :string
    field :integrity_code, :binary, redact: true
    field :integrity_version, :integer

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :requested_by, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The states a release is in."
  def states, do: @states

  @doc "The codes a failed fetch records."
  def failures, do: @failures

  @doc false
  def integrity_kind, do: "integration_release"
  @doc false
  def integrity_version, do: 1
  @doc false
  def integrity_versions, do: [1]

  @doc false
  def integrity_fields(%__MODULE__{} = release, 1) do
    [
      id: release.id,
      organisation_id: release.organisation_id,
      workspace_id: release.workspace_id,
      source: release.source,
      forge_kind: release.forge_kind,
      requested_version: release.requested_version,
      state: release.state,
      failure: release.failure,
      name: release.name,
      version: release.version,
      publisher_name: release.publisher_name,
      publisher_url: release.publisher_url,
      description_sha256: release.description_sha256
    ]
  end

  @doc """
  intact?/1 says whether `release` is as it was written: its code verifies, and a ready
  release's description has the digest it was coded with.
  """
  @spec intact?(t) :: boolean
  def intact?(%__MODULE__{} = release) do
    Apiary.Kinds.Coded.verify(release) == :ok and
      (release.state != "ready" or
         Apiary.Kinds.CanonicalJSON.sha256(release.description) == release.description_sha256)
  end
end
