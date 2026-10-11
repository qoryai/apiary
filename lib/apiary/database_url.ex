defmodule Apiary.DatabaseUrl do
  @moduledoc """
  The repository's connection options from `DATABASE_URL` and `DATABASE_PASSWORD`, read in
  production by `config/runtime.exs`.

  `DATABASE_URL` takes libpq's `sslmode` and `sslrootcert`, as managed Postgres services
  print them, so a pasted URL connects with TLS as it says:

  | `sslmode` | The connection |
  |---|---|
  | none | Not encrypted, unless Ecto's own `ssl=true` asks for TLS, checked against the system's CAs. |
  | `disable` | Not encrypted. |
  | `verify-full` | Encrypted; the server's certificate and host name are checked, against the system's CAs, or against the file `sslrootcert=/path/to/ca.pem` names. `sslrootcert=system` is the system's CAs. |
  | `require` | Encrypted; the server's certificate is not checked, with or without `sslrootcert`, where libpq checks it against an `sslrootcert` file. Said once at boot, as a warning (`boot/0`). |

  Any other `sslmode` (`prefer`, `allow`, `verify-ca` among them) stops the boot, and so
  does an `sslrootcert` file that cannot be read under `verify-full`. Outside `verify-full`
  `sslrootcert` is not read, also without an `sslmode`, where libpq takes
  `sslrootcert=system` as `verify-full`. When the URL names an `sslmode`, it alone decides: `sslmode`,
  `sslrootcert` and Ecto's `ssl` are taken out of the URL before Ecto reads it, and the
  `sslmode` becomes the repository's `ssl:` option.

  `DATABASE_PASSWORD` is the password when the URL carries none (an empty one counts as
  none, as with libpq). It is passed as it is, so it needs no percent-encoding; a password
  in the URL does.
  """

  require Logger

  @unchecked "The database connection is encrypted, and the server's certificate is not checked (sslmode=require)."

  @doc """
  The options for `config :apiary, Apiary.Repo` from `url` and `password` (`nil` when
  `DATABASE_PASSWORD` is not set): `url:`, without `sslmode` and `sslrootcert`, and
  `ssl:` and `password:` when they apply. Raises with the message for the person when the
  URL asks for what Qory does not take.
  """
  @spec repo_options(String.t(), String.t() | nil) :: keyword()
  def repo_options(url, password) when is_binary(url) do
    uri = URI.parse(url)
    {query, params} = split_query(uri.query)

    {ssl, query} =
      case Map.fetch(params, "sslmode") do
        :error -> {[], query}
        {:ok, mode} -> {[ssl: ssl(mode, Map.get(params, "sslrootcert"))], drop(query, ["ssl"])}
      end

    {userinfo, has_password?} = userinfo(uri.userinfo)

    password =
      if not has_password? and password not in [nil, ""], do: [password: password], else: []

    url =
      if query == raw_parts(uri.query) and userinfo == uri.userinfo,
        do: url,
        else: URI.to_string(%{uri | query: join(query), userinfo: userinfo})

    [url: url] ++ ssl ++ password
  end

  @doc """
  Logs, once, that the database connection is not checked, when the repository's options
  say `sslmode=require`. The application calls it as it starts.
  """
  @spec boot() :: :ok
  def boot, do: warn_unchecked(Application.get_env(:apiary, Apiary.Repo, []))

  @doc false
  @spec warn_unchecked(keyword()) :: :ok
  def warn_unchecked(repo_options) do
    ssl = repo_options[:ssl]
    if is_list(ssl) and ssl[:verify] == :verify_none, do: Logger.warning(@unchecked)
    :ok
  end

  # `true` is Postgrex's own secure defaults: the system's CAs, the certificate and the
  # host name checked. A list is merged over those defaults.
  defp ssl("disable", _rootcert), do: false
  defp ssl("require", _rootcert), do: [verify: :verify_none]
  defp ssl("verify-full", rootcert) when rootcert in [nil, "system"], do: true

  defp ssl("verify-full", path) do
    case File.read(path) do
      {:ok, _} ->
        [cacertfile: path]

      {:error, _} ->
        raise """
        environment variable DATABASE_URL names sslrootcert=#{path}, which cannot be read.
        """
    end
  end

  defp ssl(mode, _rootcert) do
    raise """
    environment variable DATABASE_URL asks sslmode=#{mode}, which Qory does not take.
    Use sslmode=verify-full, which checks the server's certificate, or sslmode=require, which encrypts without checking it.
    """
  end

  # The query's parts as written, without sslmode and sslrootcert, and the values of
  # those two, decoded as Ecto decodes a query. The last of a repeated key wins, as in libpq.
  defp split_query(query) do
    parts = raw_parts(query)

    params =
      parts
      |> Enum.map(&decode/1)
      |> Enum.filter(fn {key, _value} -> key in ["sslmode", "sslrootcert"] end)
      |> Map.new()

    {drop(parts, ["sslmode", "sslrootcert"]), params}
  end

  defp raw_parts(nil), do: []
  defp raw_parts(query), do: String.split(query, "&")

  defp drop(parts, keys), do: Enum.reject(parts, &(elem(decode(&1), 0) in keys))

  defp decode(part) do
    case String.split(part, "=", parts: 2) do
      [key, value] -> {URI.decode_www_form(key), URI.decode_www_form(value)}
      [key] -> {URI.decode_www_form(key), ""}
    end
  end

  defp join([]), do: nil
  defp join(parts), do: Enum.join(parts, "&")

  # A URL's empty password (`USER:@HOST`) is none: taken out, so DATABASE_PASSWORD applies.
  defp userinfo(nil), do: {nil, false}

  defp userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user, ""] -> {user, false}
      [_user, _password] -> {userinfo, true}
      [_user] -> {userinfo, false}
    end
  end
end
