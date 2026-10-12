defmodule Apiary.Policy.Grammar do
  @moduledoc """
  The grammar of the contract's policy document (`policy.schema.json`), where a rule is
  checked before it is stored: a host and a path. The patterns are the schema's; the
  rendered document is validated against the schema again, whole, before it is stored
  (`Apiary.Policy.Schema`).

  `covers?/2` is Forager's `policy.Covers`. `matches?/2` matches a name as Forager's
  `policy.Match` does, by an identical entry or a `*.` suffix above it; an address it
  matches only in its one form, `a.b.c.d`, identical to an entry, and an address in any
  other form, IPv6 included, matches no entry.
  """

  # The schema's own patterns but for the anchors: `\A` and `\z`, since `$` would let a final
  # newline through. This, not the validation of the rendered document, is what keeps a
  # host or a path to the grammar.
  @host ~r/\A(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\z/
  @path ~r/\A\/[^*?#\s]*\*?\z/
  # The schema's `\s` is ECMAScript's, every Unicode space and U+2028 and U+2029 with it,
  # where this engine's `\s` without more is ASCII's: a path holds no separator and no
  # control character of any kind, or the schema would refuse the render later, without a
  # sentence.
  @blank ~r/[\p{Z}\p{C}]/u
  # A last label that is a number, as WHATWG's URL host parser reads one: digits, or `0x`
  # and hex digits (none at all included). A host that ends in one is an address.
  @number ~r/\A([0-9]+|0[xX][0-9a-fA-F]*)\z/
  # An address as the gateway takes one: four decimal parts, each 0 to 255, and no part
  # with a leading zero.
  @dotted_quad ~r/\A(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}\z/

  # A DNS name is at most 253 characters; a path and a list of paths are bounded so a
  # document stays far under what the gateway reads.
  @host_max 255
  @path_max 1024
  @paths_max 100

  def host_max, do: @host_max
  def path_max, do: @path_max
  def paths_max, do: @paths_max

  @doc """
  Whether `host` is a lower-case host name or a `*.` suffix, as `egress.allow` takes it. An
  entry that ends in a number (`ends_in_number?/1`) is an address, and is one only when it
  is `canonical_address?/1`: `10.0.0.12`, never `127.1`, `2130706433`, `0x7f.0.0.1`,
  `010.0.0.1` or `*.0.0.1`.
  """
  def host?(host) when is_binary(host) do
    String.valid?(host) and byte_size(host) <= @host_max and Regex.match?(@host, host) and
      (canonical_address?(host) or not ends_in_number?(host))
  end

  def host?(_host), do: false

  @doc """
  Whether `host` is in the schema's pattern, a lower-case name or a `*.` suffix, whatever
  its last label: what a rule stored before `host?/1` refused addresses in another form
  than `a.b.c.d` may hold. A requested removal names such a rule by it.
  """
  def in_pattern?(host) when is_binary(host) do
    String.valid?(host) and byte_size(host) <= @host_max and Regex.match?(@host, host)
  end

  def in_pattern?(_host), do: false

  @doc """
  Whether `host` ends in a number, as WHATWG's URL host parser asks it: its last label (a
  final empty one left out) is all ASCII digits, or `0x` and hex digits. Such a host is an
  address, whatever its other labels are.
  """
  def ends_in_number?(host) when is_binary(host) do
    labels = String.split(host, ".")

    labels =
      case Enum.reverse(labels) do
        ["" | [_ | _] = rest] -> Enum.reverse(rest)
        _other -> labels
      end

    Regex.match?(@number, List.last(labels))
  end

  def ends_in_number?(_host), do: false

  @doc "Whether `host` is an address in the one form an entry takes it: `a.b.c.d`, each 0 to 255, no leading zero."
  def canonical_address?(host) when is_binary(host), do: Regex.match?(@dotted_quad, host)
  def canonical_address?(_host), do: false

  @doc "Whether `path` is a path from the root, whole or up to a final `*`."
  def path?(path) when is_binary(path) do
    String.valid?(path) and byte_size(path) <= @path_max and Regex.match?(@path, path) and
      not Regex.match?(@blank, path)
  end

  def path?(_path), do: false

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

  @doc """
  Whether any entry of `allow` matches `host`, a host as a connection names it. An address
  (one that ends in a number, or an IPv6 address, bracketed or not) matches only an entry
  identical to it, and only in its one form, `a.b.c.d`: `127.1`, `0x7f.0.0.1`,
  `2130706433`, any IPv6 address and `::ffff:10.0.0.12` match no entry at all. A name
  matches an identical entry or a `*.` suffix above it.
  """
  def matches?(allow, host) when is_list(allow) and is_binary(host) do
    host = host |> String.downcase() |> String.trim_trailing(".")

    if address?(host),
      do: canonical_address?(host) and host in allow,
      else: Enum.any?(allow, &covers?(&1, host))
  end

  # An IPv6 address holds a `:`, bracketed or not; anything bracketed is taken for one.
  defp address?(host),
    do: ends_in_number?(host) or String.contains?(host, ":") or String.starts_with?(host, "[")

  @doc "Whether a path pattern matches a request's path: whole, or as a prefix up to a final `*`."
  def path_matches?(pattern, path) do
    if String.ends_with?(pattern, "*"),
      do: String.starts_with?(path, String.trim_trailing(pattern, "*")),
      else: pattern == path
  end
end
