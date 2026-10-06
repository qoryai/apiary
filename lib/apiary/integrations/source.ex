defmodule Apiary.Integrations.Source do
  @moduledoc """
  Source is where an integration's releases are, in the runner contract's two forms, and
  where each file of a release is downloaded from, by the integrations contract.

    * **A forge path**, `<host>/<path>` with no scheme, such as
      `github.com/qoryai/qory-github`, `gitlab.com/acme/tools/qory-webhook` or
      `git.example.com/acme/shop`, with its `forge_kind`, `github`, `gitlab` or `forgejo`
      (Forgejo and Gitea). The forge is a public one, `github.com`, `gitlab.com` or
      `codeberg.org`, or one the operator lists with its kind in
      `INTEGRATION_FORGE_HOSTS`, a self-hosted or enterprise forge; a forge path on any
      other host is refused. The host implies the kind, which may be left out and may not
      differ, so the kind a release records is always its host's, the one a run
      configuration has to give off the public forges. A path on GitHub and Forgejo is
      `<owner>/<repo>`; on GitLab it is the project's full path, its groups included.
    * **An https URL of a `description.json`**, the release's other files beside it, with
      no `forge_kind`, accepted while `INTEGRATION_URL_SOURCES` is on, as it is by default.

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

  ## The operator's settings

  Both are read at boot (`boot!/0`), which stops on a value it refuses:

    * `INTEGRATION_FORGE_HOSTS`, the operator's forges: entries `<kind>:<host>` separated
      by commas, such as
      `github:github.example.com,gitlab:gitlab.example.com,forgejo:git.example.com`,
      none when unset (`parse_forge_hosts/1`);
    * `INTEGRATION_URL_SOURCES`, whether a URL source is accepted: `true`, `1` or `yes`,
      the default, or `false`, `0` or `no` (`parse_url_sources/1`).
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

  @typedoc "The operator's forges: each host, with its kind."
  @type forge_hosts :: %{String.t() => String.t()}

  @typedoc "An option of `parse/3`: a setting in place of the instance's."
  @type option :: {:forge_hosts, forge_hosts} | {:url_sources, boolean}

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
  public_forge_hosts/0 is the public forges' hosts, whose kind is implied whatever the
  operator lists.
  """
  @spec public_forge_hosts() :: [String.t()]
  def public_forge_hosts, do: Map.keys(@implied)

  @doc """
  parse/3 checks `source` with `forge_kind`, nil or empty when none was given, under the
  instance's settings, or the ones `opts` gives (`:forge_hosts`, `:url_sources`):
  `{:ok, source}`, the kind filled in from the host, or `{:error, reason}`:
  `:source_invalid` for a source of neither form or a refused host,
  `:forge_host_unlisted` for a forge path on a host neither public nor listed,
  `:url_sources_off` for a URL source while they are off, `:forge_kind_invalid` for a
  kind other than the host's, or given with a URL source, and `:path_invalid` for a
  GitHub or Forgejo path that is not `<owner>/<repo>`.
  """
  @spec parse(term, term, [option]) :: {:ok, t} | {:error, atom}
  def parse(source, forge_kind, opts \\ [])

  def parse(source, forge_kind, opts) when is_binary(source) do
    forge_kind = if forge_kind in [nil, ""], do: nil, else: forge_kind

    cond do
      byte_size(source) <= 2048 and Regex.match?(url_regex(), source) ->
        url(source, forge_kind, opts)

      byte_size(source) <= 512 and not String.ends_with?(source, ".git") and
          Regex.match?(forge_regex(), source) ->
        forge(source, forge_kind, opts)

      true ->
        {:error, :source_invalid}
    end
  end

  def parse(_source, _forge_kind, _opts), do: {:error, :source_invalid}

  defp url(source, forge_kind, opts) do
    cond do
      not Keyword.get_lazy(opts, :url_sources, &url_sources?/0) ->
        {:error, :url_sources_off}

      not is_nil(forge_kind) ->
        {:error, :forge_kind_invalid}

      true ->
        %URI{host: host} = URI.parse(source)

        with :ok <- refuse_name(host),
             do: {:ok, %__MODULE__{source: source, form: :url, host: host}}
    end
  end

  defp forge(source, forge_kind, opts) do
    [host, path] = String.split(source, "/", parts: 2)

    with :ok <- refuse_name(host),
         {:ok, kind} <- kind(host, forge_kind, opts),
         :ok <- path_for(kind, path) do
      {:ok, %__MODULE__{source: source, form: :forge, forge_kind: kind, host: host, path: path}}
    end
  end

  # The host's kind is the one recorded, whatever was typed: a run configuration gives it
  # off the public forges, and it has to be the forge's.
  defp kind(host, forge_kind, opts) do
    forges = Map.merge(Keyword.get_lazy(opts, :forge_hosts, &forge_hosts/0), @implied)

    case {Map.fetch(forges, host), forge_kind} do
      {{:ok, kind}, nil} -> {:ok, kind}
      {{:ok, kind}, kind} -> {:ok, kind}
      {{:ok, _kind}, _other} -> {:error, :forge_kind_invalid}
      {:error, _forge_kind} -> {:error, :forge_host_unlisted}
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

  ## The operator's settings

  @doc """
  forge_hosts/0 is the operator's forges, each host with its kind
  (`INTEGRATION_FORGE_HOSTS`), as `boot!/0` fixed them.
  """
  @spec forge_hosts() :: forge_hosts
  def forge_hosts, do: setting(:integration_forge_hosts)

  @doc """
  url_sources?/0 says whether a URL source is accepted (`INTEGRATION_URL_SOURCES`), as
  `boot!/0` fixed it.
  """
  @spec url_sources?() :: boolean
  def url_sources?, do: setting(:integration_url_sources)

  defp setting(key) do
    case Application.fetch_env(:apiary, key) do
      {:ok, value} ->
        value

      :error ->
        :ok = boot!()
        Application.fetch_env!(:apiary, key)
    end
  end

  @doc """
  parse_forge_hosts/1 reads a value of `INTEGRATION_FORGE_HOSTS`: `{:ok, forges}`, each
  host with its kind, none for nil or a blank value; `{:error, reason}` for an entry that
  is not `<kind>:<host>`, a kind of `forge_kinds/0` and an exact host name, for a public
  forge's host, and for a host listed with two kinds. Any case.
  """
  @spec parse_forge_hosts(String.t() | nil) :: {:ok, forge_hosts} | {:error, String.t()}
  def parse_forge_hosts(nil), do: {:ok, %{}}

  def parse_forge_hosts(setting) when is_binary(setting) do
    setting
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, %{}}, fn entry, {:ok, forges} ->
      with {:ok, host, kind} <- forge_host(entry),
           :ok <- one_kind(forges, host, kind) do
        {:cont, {:ok, Map.put(forges, host, kind)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp forge_host(entry) do
    with [kind, host] <- entry |> String.split(":", parts: 2) |> Enum.map(&String.trim/1),
         true <- kind in @forge_kinds,
         true <- Hosts.exact?(host) and not Hosts.refused_name?(host) do
      # A public forge listed would be let resolve to a private address, and could be
      # given another kind than its own.
      if Map.has_key?(@implied, host),
        do: {:error, "#{inspect(host)} is a public forge, known without being listed"},
        else: {:ok, host, kind}
    else
      _other ->
        {:error,
         "#{inspect(entry)} is not a kind (github, gitlab or forgejo), a colon and a host name"}
    end
  end

  defp one_kind(forges, host, kind) do
    case Map.fetch(forges, host) do
      {:ok, other} when other != kind ->
        {:error, "#{inspect(host)} is listed as #{other} and as #{kind}"}

      _same_or_none ->
        :ok
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
  boot!/0 reads `INTEGRATION_FORGE_HOSTS` and `INTEGRATION_URL_SOURCES` as
  `config/runtime.exs` left them, checks them and fixes them for the life of the node.
  Called at boot; raises on a value `parse_forge_hosts/1` or `parse_url_sources/1`
  refuses, so the instance does not start.
  """
  @spec boot!() :: :ok
  def boot! do
    forges =
      case parse_forge_hosts(Application.get_env(:apiary, :integration_forge_hosts_setting)) do
        {:ok, forges} ->
          forges

        {:error, reason} ->
          raise ArgumentError, """
          environment variable INTEGRATION_FORGE_HOSTS is not valid: #{reason}.
          Leave it unset for no forge beside github.com, gitlab.com and codeberg.org, or
          list yours, each as its kind and its host, separated by commas, for example:
          INTEGRATION_FORGE_HOSTS=github:github.example.com,gitlab:gitlab.example.com,forgejo:git.example.com
          """
      end

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

    Application.put_env(:apiary, :integration_forge_hosts, forges)
    Application.put_env(:apiary, :integration_url_sources, url_sources)
    :ok
  end

  defp forge_regex, do: Pattern.compile!(@forge_pattern)
  defp url_regex, do: Pattern.compile!(@url_pattern)
end
