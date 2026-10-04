defmodule Apiary.Integrations.Source do
  @moduledoc """
  Source is where an integration's releases are, in the runner contract's two forms, and
  where each file of a release is downloaded from, by the integrations contract.

    * **A forge path**, `<host>/<path>` with no scheme, such as
      `github.com/qoryai/qory-github`, `gitlab.com/acme/tools/qory-webhook` or
      `git.example.com/acme/qory-internal-api`, with its `forge_kind`, `github`, `gitlab` or
      `forgejo` (Forgejo and Gitea). The kind is implied on `github.com`, `gitlab.com` and
      `codeberg.org`, where it may be left out and may not differ, and required on any
      other host. A path on GitHub and Forgejo is `<owner>/<repo>`; on GitLab it is the
      project's full path, its groups included.
    * **An https URL of a `description.json`**, the release's other files beside it, with
      no `forge_kind`.

  The host of both is a lower-case DNS name with at least one dot whose last label starts
  with a letter: no IP address in any spelling, no port, no userinfo. `localhost` and the
  names under `.localhost`, `.local`, `.internal` and `.home.arpa` are refused. The
  patterns are the contract's, compiled with `:dollar_endonly` (`Apiary.Kinds.Pattern`).

  A **version** is `X.Y.Z` with no leading zeros. A file of version X.Y.Z is at:

    * GitHub, Forgejo: `https://<host>/<path>/releases/download/vX.Y.Z/<file>`;
    * GitLab: `https://<host>/<path>/-/releases/vX.Y.Z/downloads/<file>`;
    * a URL source: the URL's directory, `<dir>/<file>`, whatever the version.

  The source's **owner**, the part of it a person can check, is shown beside the
  publisher a description names: `<host>/<owner>` on a forge (the group path on GitLab),
  the host of a URL.
  """

  alias Apiary.Kinds.{Hosts, Pattern}

  @enforce_keys [:source, :form, :host]
  defstruct source: nil, form: nil, forge_kind: nil, host: nil, path: nil

  @typedoc "A source, parsed: its form, its forge's kind, its host, and its path on the forge."
  @type t :: %__MODULE__{
          source: String.t(),
          form: :forge | :url,
          forge_kind: String.t() | nil,
          host: String.t(),
          path: String.t() | nil
        }

  @host_part "(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?"
  @forge_pattern "^" <> @host_part <> "(?:/[A-Za-z0-9_-][A-Za-z0-9_.-]{0,99}){2,}$"
  @url_pattern "^https://" <>
                 @host_part <> "(?:/[A-Za-z0-9_-][A-Za-z0-9_.-]{0,99})*/description\\.json$"
  @version_pattern "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"

  @forge_kinds ~w(github gitlab forgejo)
  @implied %{"github.com" => "github", "gitlab.com" => "gitlab", "codeberg.org" => "forgejo"}

  @doc "forge_kinds/0 is the kinds of forge a source may be on."
  @spec forge_kinds() :: [String.t()]
  def forge_kinds, do: @forge_kinds

  @doc """
  public_forge_hosts/0 is the hosts whose forge kind is implied: the public forges, the
  only hosts a release token is ever sent to (`Apiary.Integrations.Fetch`).
  """
  @spec public_forge_hosts() :: [String.t()]
  def public_forge_hosts, do: Map.keys(@implied)

  @doc """
  parse/2 checks `source` with `forge_kind`, nil or empty when none was given:
  `{:ok, source}`, the kind filled in where the host implies it, or `{:error, reason}`:
  `:source_invalid` for a source of neither form or a refused host, `:forge_kind_required`,
  `:forge_kind_invalid` for a kind unknown, other than the one the host implies, or given
  with a URL source, and `:path_invalid` for a GitHub or Forgejo path that is not
  `<owner>/<repo>`.
  """
  @spec parse(term, term) :: {:ok, t} | {:error, atom}
  def parse(source, forge_kind) when is_binary(source) do
    forge_kind = if forge_kind in [nil, ""], do: nil, else: forge_kind

    cond do
      byte_size(source) <= 2048 and Regex.match?(url_regex(), source) ->
        url(source, forge_kind)

      byte_size(source) <= 512 and not String.ends_with?(source, ".git") and
          Regex.match?(forge_regex(), source) ->
        forge(source, forge_kind)

      true ->
        {:error, :source_invalid}
    end
  end

  def parse(_source, _forge_kind), do: {:error, :source_invalid}

  defp url(source, nil) do
    %URI{host: host} = URI.parse(source)
    refuse_name(%__MODULE__{source: source, form: :url, host: host})
  end

  defp url(_source, _forge_kind), do: {:error, :forge_kind_invalid}

  defp forge(source, forge_kind) do
    [host, path] = String.split(source, "/", parts: 2)

    with {:ok, kind} <- kind(host, forge_kind),
         :ok <- path_for(kind, path) do
      refuse_name(%__MODULE__{
        source: source,
        form: :forge,
        forge_kind: kind,
        host: host,
        path: path
      })
    end
  end

  defp kind(host, forge_kind) do
    case {Map.fetch(@implied, host), forge_kind} do
      {{:ok, implied}, nil} -> {:ok, implied}
      {{:ok, implied}, implied} -> {:ok, implied}
      {{:ok, _implied}, _other} -> {:error, :forge_kind_invalid}
      {:error, nil} -> {:error, :forge_kind_required}
      {:error, kind} when kind in @forge_kinds -> {:ok, kind}
      {:error, _kind} -> {:error, :forge_kind_invalid}
    end
  end

  defp path_for("gitlab", _path), do: :ok

  defp path_for(_kind, path) do
    case String.split(path, "/") do
      [_owner, _repo] -> :ok
      _other -> {:error, :path_invalid}
    end
  end

  defp refuse_name(%__MODULE__{host: host} = source) do
    if Hosts.refused_name?(host), do: {:error, :source_invalid}, else: {:ok, source}
  end

  @doc "version?/1 says whether `version` is an exact version, `X.Y.Z`, no leading zeros."
  @spec version?(term) :: boolean
  def version?(version) when is_binary(version) and byte_size(version) <= 64,
    do: Regex.match?(Pattern.compile!(@version_pattern), version)

  def version?(_version), do: false

  @doc """
  download_url/3 is where the file `file` of version `version` of `source` is: see the
  module's documentation. A URL source has one release, at its URL, whatever the version.
  """
  @spec download_url(t, String.t() | nil, String.t()) :: String.t()
  def download_url(%__MODULE__{form: :url, source: source}, _version, file),
    do: Path.dirname(source) <> "/" <> file

  def download_url(%__MODULE__{forge_kind: "gitlab", host: host, path: path}, version, file),
    do: "https://#{host}/#{path}/-/releases/v#{version}/downloads/#{file}"

  def download_url(%__MODULE__{forge_kind: kind, host: host, path: path}, version, file)
      when kind in ["github", "forgejo"],
      do: "https://#{host}/#{path}/releases/download/v#{version}/#{file}"

  @doc """
  owner/1 is what a person can check of `source`: `<host>/<owner>` on a forge, the group
  path on GitLab, and the host of a URL.
  """
  @spec owner(t) :: String.t()
  def owner(%__MODULE__{form: :url, host: host}), do: host

  def owner(%__MODULE__{forge_kind: "gitlab", host: host, path: path}) do
    groups = path |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")
    host <> "/" <> groups
  end

  def owner(%__MODULE__{host: host, path: path}),
    do: host <> "/" <> (path |> String.split("/") |> hd())

  @doc """
  public_forge?/1 says whether `source` is on a public forge, whose host implies its kind:
  `github.com`, `gitlab.com` or `codeberg.org`. Any other host is self-hosted.
  """
  @spec public_forge?(t) :: boolean
  def public_forge?(%__MODULE__{form: :forge, host: host}), do: Map.has_key?(@implied, host)
  def public_forge?(%__MODULE__{}), do: false

  defp forge_regex, do: Pattern.compile!(@forge_pattern)
  defp url_regex, do: Pattern.compile!(@url_pattern)
end
