defmodule Apiary.ModelKeys.AccountClaim do
  @moduledoc """
  The account id in the access token of a model key's sign-in, read by the rules of the
  gateway of Forager (`AccountClaim` in `gateway/internal/credential/credential.go`, with
  its tests in `account_test.go`), so that a run waits for a new sign-in exactly when its
  gateway would refuse the token. This is the one function that reads it: the claim, the
  page, the gate that seals a token to a run, the refresh and the device sign-in call it.

  `read/2` returns the string at `pointer`, a JSON pointer (RFC 6901), in the payload of
  the JWT `token`: `{:ok, claim}`, or `:error` for a token that has none. The payload is
  the second of three parts separated by dots, base64url with or without padding (the
  padding is trimmed, and a carriage return or line feed is skipped, as Go's decoder skips
  them), and at most 8,192 bytes once decoded. It must be one JSON object with each member
  name once. Each object on the pointer's way must have each member name once too; a
  member name twice elsewhere, a number out of range and invalid UTF-8 elsewhere do not
  count. The pointer reaches a string that is not empty, is valid UTF-8, neither starts
  nor ends with a space or a tab, and has no control character (U+0000 to U+001F, U+007F to
  U+009F) but a tab inside it, since a header value cannot have one.

  The signature is not checked, and that is safe: the answer only decides whether a run
  waits for a new sign-in. The gateway reads the claim again by the same rules before it
  sets the account header, and the model provider checks the token.

  Where Forager accepts a payload with invalid UTF-8 inside a string off the pointer's
  way, so does this module. In a member name, each invalid byte and each lone surrogate
  escape (`\\ud800`) is read as U+FFFD, as Forager's decoder reads it, so the names `\\xFF`
  and `\\xFE` are the same name, and so are `\\ud800` and `\\udc00`. In the claim they are
  refused, as the claim must be UTF-8.
  """

  @max_payload 8 * 1024

  @doc """
  The string at the JSON pointer `pointer` in the payload of the JWT `token`, as the
  moduledoc says. `:error` for a pointer that is no JSON pointer (it does not start with
  `/`), and for anything that is not a text.
  """
  @spec read(term, term) :: {:ok, String.t()} | :error
  def read(token, "/" <> pointer) when is_binary(token) do
    with [_header, payload, _signature] <- :binary.split(token, ".", [:global]),
         {:ok, json} <- decode(payload),
         :ok <- whole_object(json),
         {:ok, claim} <- step(ws(json), String.split(pointer, "/")) do
      checked(claim)
    else
      _none -> :error
    end
  end

  def read(_token, _pointer), do: :error

  ## The payload

  defp decode(payload) do
    enc = trim_padding(payload)

    cond do
      div(byte_size(enc) * 6, 8) > @max_payload ->
        :error

      # Go's decoder has no padding: a `=` that is not at the end of the payload, such as
      # one before a line feed, is an error, whatever is trimmed or skipped around it.
      :binary.match(enc, "=") != :nomatch ->
        :error

      true ->
        enc
        |> :binary.replace(["\r", "\n"], "", [:global])
        |> Base.url_decode64(padding: false)
    end
  end

  defp trim_padding(bin) do
    size = byte_size(bin)

    if size > 0 and :binary.last(bin) == ?=,
      do: trim_padding(binary_part(bin, 0, size - 1)),
      else: bin
  end

  # The payload is one object, each member name once, with nothing but white space after.
  defp whole_object(json) do
    json = ws(json)

    with <<?{, _rest::binary>> <- json,
         {:ok, members, rest} <- object(json),
         "" <- ws(rest),
         true <- unique?(members) do
      :ok
    else
      _no -> :error
    end
  end

  ## The way along the pointer

  defp step(value, []), do: string(value)

  defp step(<<?{, _rest::binary>> = value, [token | tokens]) do
    name = token |> String.replace("~1", "/") |> String.replace("~0", "~")

    with {:ok, members, _rest} <- object(value),
         true <- unique?(members),
         {_name, found} <- List.keyfind(members, name, 0) do
      step(found, tokens)
    else
      _missing -> :error
    end
  end

  defp step(<<?[, _rest::binary>> = value, [token | tokens]) do
    with {:ok, index} <- array_index(token),
         {:ok, elements, _rest} <- array(value),
         found when is_binary(found) <- Enum.at(elements, index) do
      step(found, tokens)
    else
      _missing -> :error
    end
  end

  defp step(_value, _tokens), do: :error

  # An index of a list, RFC 6901: 0, or decimal digits that do not start with 0, at most 9.
  defp array_index(token) do
    if token != "" and byte_size(token) <= 9 and String.match?(token, ~r/\A(0|[1-9][0-9]*)\z/),
      do: {:ok, String.to_integer(token)},
      else: :error
  end

  defp unique?(members) do
    names = Enum.map(members, &elem(&1, 0))
    length(names) == length(Enum.uniq(names))
  end

  ## The claim

  defp string(<<?", rest::binary>>) do
    with {:ok, raw, _rest} <- string_body(rest, 0),
         {:ok, text} <- unescape(raw, true) do
      {:ok, text}
    else
      _no -> :error
    end
  end

  defp string(_value), do: :error

  defp checked(claim) do
    cond do
      claim == "" -> :error
      String.starts_with?(claim, [" ", "\t"]) or String.ends_with?(claim, [" ", "\t"]) -> :error
      claim |> String.to_charlist() |> Enum.any?(&control?/1) -> :error
      true -> {:ok, claim}
    end
  end

  # A tab is allowed inside the claim; any other C0 control character, DEL and the C1
  # controls are not.
  defp control?(?\t), do: false
  defp control?(c), do: c < 0x20 or (c >= 0x7F and c <= 0x9F)

  ## JSON, syntax only

  defp ws(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: ws(rest)
  defp ws(rest), do: rest

  # The value at the start of `bin` (after white space): `{:ok, slice, rest}`, the slice
  # being exactly the value.
  defp value(bin) do
    bin = ws(bin)

    case scan(bin) do
      {:ok, rest} -> {:ok, binary_part(bin, 0, byte_size(bin) - byte_size(rest)), rest}
      :error -> :error
    end
  end

  defp scan(<<?{, _::binary>> = bin),
    do: with({:ok, _members, rest} <- object(bin), do: {:ok, rest})

  defp scan(<<?[, _::binary>> = bin),
    do: with({:ok, _elements, rest} <- array(bin), do: {:ok, rest})

  defp scan(<<?", rest::binary>>),
    do: with({:ok, _raw, rest} <- string_body(rest, 0), do: {:ok, rest})

  defp scan(<<"true", rest::binary>>), do: {:ok, rest}
  defp scan(<<"false", rest::binary>>), do: {:ok, rest}
  defp scan(<<"null", rest::binary>>), do: {:ok, rest}
  defp scan(bin), do: number(bin)

  # `{:ok, [{name, value_slice}], rest}` for the object at the start of `bin`.
  defp object(<<?{, rest::binary>>) do
    case ws(rest) do
      <<?}, rest::binary>> -> {:ok, [], rest}
      rest -> members(rest, [])
    end
  end

  defp members(<<?", rest::binary>>, acc) do
    with {:ok, raw, rest} <- string_body(rest, 0),
         {:ok, name} <- unescape(raw, false),
         <<?:, rest::binary>> <- ws(rest),
         {:ok, slice, rest} <- value(rest) do
      acc = [{name, slice} | acc]

      case ws(rest) do
        <<?,, rest::binary>> -> members(ws(rest), acc)
        <<?}, rest::binary>> -> {:ok, Enum.reverse(acc), rest}
        _no -> :error
      end
    else
      _no -> :error
    end
  end

  defp members(_bin, _acc), do: :error

  # `{:ok, [value_slice], rest}` for the list at the start of `bin`.
  defp array(<<?[, rest::binary>>) do
    case ws(rest) do
      <<?], rest::binary>> -> {:ok, [], rest}
      rest -> elements(rest, [])
    end
  end

  defp elements(bin, acc) do
    with {:ok, slice, rest} <- value(bin) do
      acc = [slice | acc]

      case ws(rest) do
        <<?,, rest::binary>> -> elements(rest, acc)
        <<?], rest::binary>> -> {:ok, Enum.reverse(acc), rest}
        _no -> :error
      end
    end
  end

  # The raw bytes of a string after its opening quote, up to the closing one: `{:ok, raw,
  # rest}`. A byte below 0x20 and a bad escape end it with `:error`; any other byte,
  # including one that is no UTF-8, stays.
  defp string_body(bin, length) do
    case bin do
      <<raw::binary-size(^length), ?", rest::binary>> ->
        {:ok, raw, rest}

      <<_::binary-size(^length), ?\\, e, _::binary>>
      when e in [?", ?\\, ?/, ?b, ?f, ?n, ?r, ?t] ->
        string_body(bin, length + 2)

      <<_::binary-size(^length), ?\\, ?u, h::binary-size(4), _::binary>> ->
        if hex?(h), do: string_body(bin, length + 6), else: :error

      <<_::binary-size(^length), c, _::binary>> when c >= 0x20 and c != ?\\ ->
        string_body(bin, length + 1)

      _no ->
        :error
    end
  end

  defp hex?(<<a, b, c, d>>),
    do: Enum.all?([a, b, c, d], &(&1 in ?0..?9 or &1 in ?a..?f or &1 in ?A..?F))

  # A number's syntax: `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`. Its size is
  # not read.
  defp number(<<?-, rest::binary>>), do: integer(rest)
  defp number(bin), do: integer(bin)

  defp integer(<<?0, rest::binary>>), do: fraction(rest)

  defp integer(<<c, _::binary>> = bin) when c in ?1..?9,
    do: bin |> digits() |> fraction()

  defp integer(_bin), do: :error

  defp fraction(<<?., c, _::binary>> = bin) when c in ?0..?9,
    do: bin |> binary_part(1, byte_size(bin) - 1) |> digits() |> exponent()

  defp fraction(<<?., _::binary>>), do: :error
  defp fraction(bin), do: exponent(bin)

  defp exponent(<<e, rest::binary>>) when e in [?e, ?E] do
    case rest do
      <<s, c, _::binary>> when s in [?+, ?-] and c in ?0..?9 ->
        rest |> binary_part(1, byte_size(rest) - 1) |> digits() |> done()

      <<c, _::binary>> when c in ?0..?9 ->
        rest |> digits() |> done()

      _no ->
        :error
    end
  end

  defp exponent(bin), do: done(bin)

  defp done(rest), do: {:ok, rest}

  defp digits(<<c, rest::binary>>) when c in ?0..?9, do: digits(rest)
  defp digits(rest), do: rest

  ## Strings

  # The text of the raw bytes of a JSON string: the escapes read. With `strict`, invalid
  # UTF-8 and a lone surrogate are an error (a claim must be UTF-8); without it, an invalid
  # byte and a lone surrogate escape are each one U+FFFD (a member name is only compared).
  defp unescape(raw, strict) do
    text = unescape_bytes(raw, strict, [])

    cond do
      text == :error -> :error
      strict and not String.valid?(text) -> :error
      true -> {:ok, text}
    end
  end

  defp unescape_bytes(<<>>, _strict, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp unescape_bytes(<<?\\, ?u, h::binary-size(4), rest::binary>>, strict, acc) do
    code = String.to_integer(h, 16)

    cond do
      code in 0xD800..0xDBFF ->
        case rest do
          <<?\\, ?u, l::binary-size(4), rest2::binary>> ->
            low = String.to_integer(l, 16)

            if low in 0xDC00..0xDFFF do
              point = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
              unescape_bytes(rest2, strict, [<<point::utf8>> | acc])
            else
              lone(rest, strict, acc)
            end

          _other ->
            lone(rest, strict, acc)
        end

      code in 0xDC00..0xDFFF ->
        lone(rest, strict, acc)

      true ->
        unescape_bytes(rest, strict, [<<code::utf8>> | acc])
    end
  end

  defp unescape_bytes(<<?\\, e, rest::binary>>, strict, acc) do
    char =
      case e do
        ?b -> ?\b
        ?f -> ?\f
        ?n -> ?\n
        ?r -> ?\r
        ?t -> ?\t
        other -> other
      end

    unescape_bytes(rest, strict, [<<char>> | acc])
  end

  defp unescape_bytes(<<c::utf8, rest::binary>>, strict, acc),
    do: unescape_bytes(rest, strict, [<<c::utf8>> | acc])

  # A byte that starts no UTF-8 character: one U+FFFD for each such byte in a member name,
  # as Go's decoder reads it, so two names that differ in invalid bytes only are the same
  # name; kept in a claim, where `unescape/2` then refuses it.
  defp unescape_bytes(<<c, rest::binary>>, true, acc),
    do: unescape_bytes(rest, true, [<<c>> | acc])

  defp unescape_bytes(<<_c, rest::binary>>, false, acc),
    do: unescape_bytes(rest, false, ["�" | acc])

  defp lone(_rest, true, _acc), do: :error
  defp lone(rest, false, acc), do: unescape_bytes(rest, false, ["�" | acc])
end
