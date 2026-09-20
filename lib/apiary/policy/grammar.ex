defmodule Apiary.Policy.Grammar do
  @moduledoc """
  The grammar of the contract's policy document (`policy.schema.json`), where a rule is
  checked before it is stored: a host, a path, a credential's name and its argument. The
  patterns are the schema's own; the rendered document is validated against the schema
  again, whole, before it is stored (`Apiary.Policy.Schema`).

  `covers?/2` and `matches?/2` are the runner's `policy.Covers` and `policy.Match`.
  """

  @host ~r/\A(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\z/
  @path ~r/\A\/[^*?#\s]*\*?\z/
  @name ~r/\A[a-z0-9][a-z0-9_.-]{0,63}\z/

  # A DNS name is at most 253 characters; a path and a list of paths are bounded so a
  # document stays far under what a runner reads.
  @host_max 255
  @path_max 1024
  @paths_max 100
  @argument_max 256

  def host_max, do: @host_max
  def path_max, do: @path_max
  def paths_max, do: @paths_max
  def argument_max, do: @argument_max

  @doc "Whether `host` is a lower-case host name or a `*.` suffix, as `egress.allow` takes it."
  def host?(host) when is_binary(host) do
    String.valid?(host) and byte_size(host) <= @host_max and Regex.match?(@host, host)
  end

  def host?(_host), do: false

  @doc "Whether `path` is a path from the root, whole or up to a final `*`."
  def path?(path) when is_binary(path) do
    String.valid?(path) and byte_size(path) <= @path_max and Regex.match?(@path, path)
  end

  def path?(_path), do: false

  @doc "Whether `name` can name a credential."
  def credential_name?(name) when is_binary(name),
    do: String.valid?(name) and Regex.match?(@name, name)

  def credential_name?(_name), do: false

  @doc "Whether `argument` is one a credential may be asked with: 1 to 256 characters, none of control."
  def argument?(argument) when is_binary(argument) do
    String.valid?(argument) and String.length(argument) in 1..@argument_max and
      not Regex.match?(~r/[[:cntrl:]]/u, argument)
  end

  def argument?(_argument), do: false

  @doc "Whether the entry is a `*.` suffix."
  def wildcard?("*." <> _suffix), do: true
  def wildcard?(_host), do: false

  @doc """
  Whether an entry covers another: the same entry, or a `*.` suffix above it. `*.example`
  covers `api.example` and `*.api.example`, and not `example`.
  """
  def covers?(entry, entry), do: true

  def covers?("*." <> suffix, other) do
    other |> String.trim_leading("*.") |> String.ends_with?("." <> suffix)
  end

  def covers?(_entry, _other), do: false

  @doc "Whether any entry of `allow` covers `entry`, a host or a `*.` suffix."
  def covers_any?(allow, entry), do: Enum.any?(allow, &covers?(&1, entry))

  @doc "Whether any entry of `allow` matches `host`, a host as a connection names it."
  def matches?(allow, host) when is_list(allow) and is_binary(host) do
    host = host |> String.downcase() |> String.trim_trailing(".")

    # An IP literal matches only an identical entry, never a suffix.
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _address} -> host in allow
      {:error, _reason} -> Enum.any?(allow, &covers?(&1, host))
    end
  end

  @doc "Whether a path pattern matches a request's path: whole, or as a prefix up to a final `*`."
  def path_matches?(pattern, path) do
    if String.ends_with?(pattern, "*"),
      do: String.starts_with?(path, String.trim_trailing(pattern, "*")),
      else: pattern == path
  end
end
