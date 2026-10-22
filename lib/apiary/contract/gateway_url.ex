defmodule Apiary.Contract.GatewayUrl do
  @moduledoc """
  A gateway's address as the contracts take it: the `gateway_url` of a run key (Forager's
  `run-key.schema.json`) and of a claim answer (the provisioner contract's
  `claim-answer.schema.json`), which have one pattern and one length.

  The address is `https://`, then a host, then an optional port, and nothing after them,
  at most 300 characters. The host is DNS labels joined by dots, each 1 to 63 letters,
  digits and hyphens that starts and ends with a letter or a digit, which covers a dotted
  IPv4 address and a name with no dot, or an IPv6 address in brackets as RFC 3986 writes
  one. User information, percent-encodings, an underscore and a trailing dot are refused.
  A port is a colon and a number from 1 to 65535 with no leading zero.

  `pattern/0` is the contracts' pattern, character for character. Pure functions; nothing
  here touches the database or logs.
  """

  @max_length 300

  @label "[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
  @name "#{@label}(?:\\.#{@label})*"
  @dec_octet "(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
  @ipv4 "#{@dec_octet}\\.#{@dec_octet}\\.#{@dec_octet}\\.#{@dec_octet}"
  @h16 "[0-9A-Fa-f]{1,4}"
  @ls32 "(?:#{@h16}:#{@h16}|#{@ipv4})"
  # RFC 3986's IPv6address, its nine forms in its order.
  @ipv6 Enum.join(
          [
            "(?:#{@h16}:){6}#{@ls32}",
            "::(?:#{@h16}:){5}#{@ls32}",
            "(?:#{@h16})?::(?:#{@h16}:){4}#{@ls32}",
            "(?:(?:#{@h16}:){0,1}#{@h16})?::(?:#{@h16}:){3}#{@ls32}",
            "(?:(?:#{@h16}:){0,2}#{@h16})?::(?:#{@h16}:){2}#{@ls32}",
            "(?:(?:#{@h16}:){0,3}#{@h16})?::#{@h16}:#{@ls32}",
            "(?:(?:#{@h16}:){0,4}#{@h16})?::#{@ls32}",
            "(?:(?:#{@h16}:){0,5}#{@h16})?::#{@h16}",
            "(?:(?:#{@h16}:){0,6}#{@h16})?::"
          ],
          "|"
        )
  @port "(?::(?:[1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5]))?"
  @pattern "^https://(?:#{@name}|\\[(?:#{@ipv6})\\])#{@port}$"

  # `$` alone also matches before a final newline; `\z` holds the match to the end.
  @regex Regex.compile!(@pattern <> "\\z")

  @doc "The longest a gateway's address may be, in characters."
  @spec max_length() :: pos_integer
  def max_length, do: @max_length

  @doc "The contracts' pattern of a gateway's address."
  @spec pattern() :: String.t()
  def pattern, do: @pattern

  @doc """
  shape?/1 is whether `url` has the pattern's shape, whatever its length: a gateway's
  form checks the length apart (`Apiary.Nodes.Node`), so that its error says the address
  is too long.
  """
  @spec shape?(term) :: boolean
  def shape?(url), do: is_binary(url) and Regex.match?(@regex, url)

  @doc "valid?/1 is whether `url` is a gateway's address the contracts take."
  @spec valid?(term) :: boolean
  def valid?(url), do: shape?(url) and String.length(url) <= @max_length
end
