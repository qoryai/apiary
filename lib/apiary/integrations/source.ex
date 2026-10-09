defmodule Apiary.Integrations.Source do
  @moduledoc """
  Source is where an integration's releases are, in the runner contract's two forms, and
  where each file of a release is downloaded from, by the integrations contract.

    * **A forge path**, `<host>/<path>` with no scheme, such as
      `github.com/qoryai/qory-github` or `gitlab.com/acme/tools/qory-webhook`, on one of
      the public forges, each with its `forge_kind`: `github.com` (`github`), `gitlab.com`
      (`gitlab`) and `codeberg.org` (`forgejo`). A forge path on any other host is
      refused: self-hosted forges are not supported. The kind is the host's, never one a
      person gives, so the kind a release records is always its host's. A path on GitHub
      and Codeberg is `<owner>/<repo>`; on GitLab it is the project's full path, its
      groups included.
    * **An https URL of a `description.json`**, the release's other files beside it, with
      no `forge_kind`, accepted while `INTEGRATION_URL_SOURCES` is on, as it is by default.

  The host of both is a lower-case DNS name with at least one dot whose last label starts
  with a letter: no IP address in any spelling, no port, no userinfo. `localhost` and the
  names under `.localhost`, `.local`, `.internal` and `.home.arpa` are refused. The
  patterns are the contract's, compiled with `:dollar_endonly` (`Apiary.Kinds.Pattern`).

  A **version** is `X.Y.Z` with no leading zeros. A file of version X.Y.Z is at:

    * GitHub, Forgejo: `https://<host>/<path>/releases/download/vX.Y.Z/<file>`;
    * GitLab: `https://gitlab.com/api/v4/projects/<project>/releases/vX.Y.Z/downloads/<file>`,
      the API's download route, `<project>` the path with each `/` written `%2F`
      (`acme%2Ftools%2Fqory-webhook`). Not the web route,
      `/<path>/-/releases/vX.Y.Z/downloads/<file>`: since GitLab 17.3.2 it answers a
      release link to another host with a page of HTML that asks the reader to follow
      it, not a redirect, where the API's route redirects;
    * a URL source: the URL's directory, `<dir>/<file>`, whatever the version.

  ## The operator's setting

  `INTEGRATION_URL_SOURCES` says whether a URL source is accepted: `true`, `1` or `yes`,
  the default, or `false`, `0` or `no` (`parse_url_sources/1`). It is read at boot
  (`boot!/0`), which stops on a value it refuses.
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

  @typedoc "An option of `parse/2`: a setting in place of the instance's."
  @type option :: {:url_sources, boolean}

  @host_part "(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?"
  @forge_pattern "^" <> @host_part <> "(?:/[A-Za-z0-9_-][A-Za-z0-9_.-]{0,99}){2,}$"
  @url_pattern "^https://" <>
                 @host_part <> "(?:/[A-Za-z0-9_-][A-Za-z0-9_.-]{0,99})*/description\\.json$"
  @version_pattern "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"

  @forge_kinds ~w(github gitlab forgejo)
  @public_forges %{
    "github.com" => "github",
    "gitlab.com" => "gitlab",
    "codeberg.org" => "forgejo"
  }

  @doc "forge_kinds/0 is the kinds of forge a source may be on."
  @spec forge_kinds() :: [String.t()]
  def forge_kinds, do: @forge_kinds

  @doc """
  public_forges/0 is the hosts a forge path may be on, the public forges, each of
  which implies its kind.
  """
  @spec public_forges() :: [String.t()]
  def public_forges, do: Map.keys(@public_forges)

  @doc """
  parse/2 checks `source` under the instance's setting, or the one `opts` gives
  (`:url_sources`): `{:ok, source}`, a forge path's kind its host's, or
  `{:error, reason}`: `:source_invalid` for a source of neither form or a refused host,
  `:forge_host_unlisted` for a forge path on a host other than `github.com`, `gitlab.com`
  and `codeberg.org`, `:url_sources_off` for a URL source while they are off, and
  `:path_invalid` for a GitHub or Codeberg path that is not `<owner>/<repo>`.
  """
  @spec parse(term, [option]) :: {:ok, t} | {:error, atom}
  def parse(source, opts \\ [])

  def parse(source, opts) when is_binary(source) do
    cond do
      byte_size(source) <= 2048 and Regex.match?(url_regex(), source) ->
        url(source, opts)

      byte_size(source) <= 512 and not String.ends_with?(source, ".git") and
          Regex.match?(forge_regex(), source) ->
        forge(source)

      true ->
        {:error, :source_invalid}
    end
  end

  def parse(_source, _opts), do: {:error, :source_invalid}

  defp url(source, opts) do
    if Keyword.get_lazy(opts, :url_sources, &url_sources?/0) do
      %URI{host: host} = URI.parse(source)

      with :ok <- refuse_name(host),
           do: {:ok, %__MODULE__{source: source, form: :url, host: host}}
    else
      {:error, :url_sources_off}
    end
  end

  defp forge(source) do
    [host, path] = String.split(source, "/", parts: 2)

    with :ok <- refuse_name(host),
         {:ok, kind} <- kind(host),
         :ok <- path_for(kind, path) do
      {:ok, %__MODULE__{source: source, form: :forge, forge_kind: kind, host: host, path: path}}
    end
  end

  defp kind(host) do
    case Map.fetch(@public_forges, host) do
      {:ok, kind} -> {:ok, kind}
      :error -> {:error, :forge_host_unlisted}
    end
  end

  defp path_for("gitlab", _path), do: :ok

  defp path_for(_kind, path) do
    case String.split(path, "/") do
      [_owner, _repo] -> :ok
      _other -> {:error, :path_invalid}
    end
  end

  defp refuse_name(host),
    do: if(Hosts.refused_name?(host), do: {:error, :source_invalid}, else: :ok)

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
    do:
      "https://#{host}/api/v4/projects/#{project_id(path)}/releases/v#{version}/downloads/#{file}"

  def download_url(%__MODULE__{forge_kind: kind, host: host, path: path}, version, file)
      when kind in ["github", "forgejo"],
      do: "https://#{host}/#{path}/releases/download/v#{version}/#{file}"

  # GitLab's API names a project by its full path, URL-encoded: a path's characters are
  # unreserved but for `/`, so only the slashes change.
  defp project_id(path), do: URI.encode(path, &URI.char_unreserved?/1)

  ## The operator's setting

  @doc """
  url_sources?/0 says whether a URL source is accepted (`INTEGRATION_URL_SOURCES`), as
  `boot!/0` fixed it.
  """
  @spec url_sources?() :: boolean
  def url_sources? do
    case Application.fetch_env(:apiary, :integration_url_sources) do
      {:ok, on?} ->
        on?

      :error ->
        :ok = boot!()
        Application.fetch_env!(:apiary, :integration_url_sources)
    end
  end

  @doc """
  parse_url_sources/1 reads a value of `INTEGRATION_URL_SOURCES`: `{:ok, true}` for
  `true`, `1` or `yes`, nil or a blank value; `{:ok, false}` for `false`, `0` or `no`;
  `{:error, reason}` for anything else. Any case.
  """
  @spec parse_url_sources(String.t() | nil) :: {:ok, boolean} | {:error, String.t()}
  def parse_url_sources(nil), do: {:ok, true}

  def parse_url_sources(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      on when on in ["", "true", "1", "yes"] -> {:ok, true}
      off when off in ["false", "0", "no"] -> {:ok, false}
      other -> {:error, "it is true or false, got: #{inspect(other)}"}
    end
  end

  @doc """
  boot!/0 reads `INTEGRATION_URL_SOURCES` as `config/runtime.exs` left it, checks it and
  fixes it for the life of the node. Called at boot; raises on a value
  `parse_url_sources/1` refuses, so the instance does not start.
  """
  @spec boot!() :: :ok
  def boot! do
    url_sources =
      case parse_url_sources(Application.get_env(:apiary, :integration_url_sources_setting)) do
        {:ok, on?} ->
          on?

        {:error, reason} ->
          raise ArgumentError, """
          environment variable INTEGRATION_URL_SOURCES is not valid: #{reason}.
          Leave it unset to accept an integration from an https address of its
          description.json, or turn that off with:
          INTEGRATION_URL_SOURCES=false
          """
      end

    Application.put_env(:apiary, :integration_url_sources, url_sources)
    :ok
  end

  defp forge_regex, do: Pattern.compile!(@forge_pattern)
  defp url_regex, do: Pattern.compile!(@url_pattern)
end
