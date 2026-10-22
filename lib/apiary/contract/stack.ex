defmodule Apiary.Contract.Stack do
  @moduledoc """
  A run's `stack` as the run contract takes it (`documents.schema.json`): a stack name or
  a stack reference.

  A **name**, such as `software-standard`, is a lower-case letter, then up to 63
  lower-case letters, digits and hyphens. The machine looks the name up in its stacks
  file.

  A **reference** is the location of a stack, `<url>#<ref>:<path>`, at most 2,560
  characters. `url` is `https://`, a host, an optional port and an optional path, with no
  user information, no query and no fragment; the host is a name, which may contain the
  percent-encodings `%80` to `%FF` and `%25`, or an IPv6 address in brackets. `ref` is 1
  to 255 letters, digits and the characters `._/-`, starts with neither `-` nor `/`, does
  not end with `/`, and contains no `..` and no `//`. `path` is the folder of the stack at
  that ref: `.` for the root, or names of letters, digits and the characters `._-` joined
  by `/`, at most 255 characters, with no name that is `..`.

  `name_pattern/0`, `reference_pattern/0` and `reference_exclusions/0` are the contract's
  patterns, character for character. Pure functions; nothing here touches the database or
  logs.
  """

  @name_pattern "^[a-z][a-z0-9-]{0,63}$"
  @max_length 2560

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
  @host_name "(?:[A-Za-z0-9._~!$&'()*+,;=-]|%(?:[89A-Fa-f][0-9A-Fa-f]|25))+"
  @port "(?::(?:0{0,4}[1-9]|0{0,3}[1-9][0-9]|0{0,2}[1-9][0-9]{2}|0?[1-9][0-9]{3}|" <>
          "[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])?)?"
  @url_path "(?:/(?:[A-Za-z0-9._~!$&'()*+,;=:@/-]|%[0-9A-Fa-f]{2})*)?"
  @ref "[A-Za-z0-9._][A-Za-z0-9._-]*(?:/[A-Za-z0-9._-]+)*"
  @folder "(?:\\.|[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*)"
  @reference_pattern "^https://(?:#{@host_name}|\\[(?:#{@ipv6})\\])#{@port}#{@url_path}" <>
                       "##{@ref}:#{@folder}$"

  # What a reference must not match, beside its pattern: a ref of more than 255
  # characters, a ref with `..`, a path of more than 255 characters, a path with a name
  # that is `..`.
  @reference_exclusions [
    "#[^:]{256}",
    "#[^:]*\\.\\.",
    "#[^:]*:[^:]{256}",
    "#[^:]*:(?:.*/)?\\.\\.(?:/.*)?$"
  ]

  # `$` alone also matches before a final newline; `:dollar_endonly` holds the match to
  # the end.
  @name_regex Regex.compile!(@name_pattern, [:dollar_endonly])
  @reference_regex Regex.compile!(@reference_pattern, [:dollar_endonly])
  @exclusion_regexes Enum.map(@reference_exclusions, &Regex.compile!(&1, [:dollar_endonly]))

  @doc "The contract's pattern of a stack name."
  @spec name_pattern() :: String.t()
  def name_pattern, do: @name_pattern

  @doc "The contract's pattern of a stack reference."
  @spec reference_pattern() :: String.t()
  def reference_pattern, do: @reference_pattern

  @doc "The contract's patterns that a stack reference must not match, in its order."
  @spec reference_exclusions() :: [String.t()]
  def reference_exclusions, do: @reference_exclusions

  @doc "The longest a stack reference may be, in characters."
  @spec max_length() :: pos_integer
  def max_length, do: @max_length

  @doc "name?/1 is whether `value` is a stack name."
  @spec name?(term) :: boolean
  def name?(value), do: is_binary(value) and Regex.match?(@name_regex, value)

  @doc "reference?/1 is whether `value` is a stack reference."
  @spec reference?(term) :: boolean
  def reference?(value) do
    is_binary(value) and Regex.match?(@reference_regex, value) and
      String.length(value) <= @max_length and
      not Enum.any?(@exclusion_regexes, &Regex.match?(&1, value))
  end

  @doc "valid?/1 is whether `value` is a stack name or a stack reference."
  @spec valid?(term) :: boolean
  def valid?(value), do: name?(value) or reference?(value)
end
