defmodule Apiary.Kinds.PatternMemory do
  @moduledoc """
  PatternMemory estimates, from the source alone, the memory compiled regular expressions
  hold, before PCRE compiles them. A compiled pattern is memory outside the heap of the
  process that compiles it, so neither a `max_heap_size` nor a count of reductions sees
  it, and a few bytes of source can compile to tens of kilobytes: PCRE writes a group
  once for each count of a quantifier that repeats it, so `(?:a){8000}` compiles to
  about 64 KB.

  `estimate/2` is an upper bound, in bytes, for one source compiled with the given
  options. `schema/1` is an upper bound for every pattern JSV compiles while it builds a
  JSON Schema: each `pattern` and each key of a `patternProperties`, once for the build
  from the root and once more for each distinct reference whose target holds it. Both
  read the source and compile nothing. What they do not read exactly, they count high:
  an unknown construct at the most a pattern can take, an unresolved reference as the
  whole schema.
  """

  alias JSV.Resolver.Embedded

  # The bytes each item may take in PCRE's compiled code, at least what PCRE2 writes for
  # it in an 8-bit library with 2-byte links: a literal, 8 bytes and, under `:unicode`, 2
  # more for each byte past the first of its UTF-8, PCRE reading it as one character, or
  # else 8 for each of its bytes, PCRE reading each byte as a character; an escape; a
  # class, its base and each byte of its source; a group; an alternative; a quantifier on
  # a single item, which PCRE writes once with its counts; and each copy of a group a
  # quantifier repeats.
  @literal 8
  @escape 16
  @class 48
  @class_byte 4
  @group 16
  @alternative 12
  @quantifier 16
  @copy 12

  # What every compiled pattern holds besides its code, and the most its code takes: PCRE
  # refuses a pattern whose code passes 64 KiB ("regular expression is too large"), so a
  # pattern's code is counted at most at the cap. Each named group adds an entry, as long
  # as the longest name and 16 bytes more, to a name table outside that limit.
  # Measured on OTP 29 (PCRE2 10.47), compiled as JSV compiles a "pattern", the sources'
  # binaries left out: the smallest patterns hold 217 to 423 bytes, the largest code 63626
  # bytes, and one pattern of 1501 named groups, the longest name 128 bytes, 209461 bytes.
  # Over 84 families of patterns, each estimate is at least 1.04 times the greater of what
  # the compiled pattern holds read with the sources' binaries and without: 1.04 for 1000
  # escapes `\x{10FFFF}`, 1.3 at the cap. Compiled with no options, as
  # `Apiary.Kinds.RegexFormat` compiles a value, over 61 families, at least 1.19, for 1000
  # escapes `\x{ff}`.
  @fixed 1024
  @cap 81_920
  @name 16

  # A quantifier's count past this is one PCRE refuses ("number too big in {}
  # quantifier").
  @most_count 65_536

  @doc """
  estimate/2 is an upper bound on the bytes `source` holds once compiled with `options`
  (see the module's documentation). The weights are measured for the options JSV
  compiles a pattern with, `:unicode` and `:ucp` (Regex's `"u"`), and for none, as
  `Apiary.Kinds.RegexFormat` compiles a value; under any other option the code is
  counted at the cap. A pattern that may turn on extended mode, `(?x)`, or holds a
  callout, `(?C`, a verb, `(*`, or a group construct not read here, is counted at the cap
  as well.
  """
  @spec estimate(String.t(), [atom]) :: pos_integer
  def estimate(source, options \\ [:unicode, :ucp]) when is_binary(source) and is_list(options) do
    {code, acc} = code(source, :unicode in options)
    known? = Enum.all?(options, &(&1 in [:unicode, :ucp]))
    code = if acc.unknown or not known?, do: @cap, else: min(code, @cap)
    @fixed + code + acc.names * (acc.longest + @name)
  end

  ## A pattern

  defp code(source, unicode?),
    do: top(source, 0, %{unknown: false, names: 0, longest: 0, unicode: unicode?})

  # A ")" with no group open is one PCRE refuses; what follows is still counted.
  defp top(source, total, acc) do
    case seq(source, total, nil, acc) do
      {total, <<")", rest::binary>>, acc} -> top(rest, add(total, @literal), acc)
      {total, _rest, acc} -> {total, acc}
    end
  end

  # The code is counted up to the cap, past which the estimate is the cap anyway.
  defp add(a, b), do: min(a + b, @cap)

  # A sequence of items, up to a ")" (not taken) or the end. `last` is what a quantifier
  # that follows applies to: nil, {:single, cost} or {:group, cost}.
  defp seq(<<>>, total, _last, acc), do: {total, <<>>, acc}
  defp seq(<<")", _::binary>> = rest, total, _last, acc), do: {total, rest, acc}

  defp seq(<<"|", rest::binary>>, total, _last, acc),
    do: seq(rest, add(total, @alternative), nil, acc)

  # PCRE ignores an \E that ends no \Q.
  defp seq(<<"\\E", rest::binary>>, total, last, acc), do: seq(rest, total, last, acc)

  defp seq(<<"\\Q", rest::binary>>, total, last, acc) do
    {cost, rest} = quoted(rest, 0, acc.unicode)
    last = if cost > 0, do: {:single, @escape}, else: last
    seq(rest, add(total, cost), last, acc)
  end

  defp seq(<<"\\", rest::binary>>, total, _last, acc),
    do: seq(escape(rest), add(total, @escape), {:single, @escape}, acc)

  defp seq(<<"[", rest::binary>>, total, _last, acc) do
    {bytes, rest} = class(rest)
    cost = @class + @class_byte * bytes
    seq(rest, add(total, cost), {:single, cost}, acc)
  end

  defp seq(<<"(", rest::binary>>, total, last, acc), do: group(rest, total, last, acc)

  defp seq(<<c, _::binary>> = source, total, last, acc) when c in [?*, ?+, ??, ?{] do
    case quantifier(source) do
      {:ok, count, rest} when last != nil ->
        {total, last} = repeat(total, last, count)
        seq(lazy(rest), total, last, acc)

      {:ok, _count, rest} ->
        cost = @literal * (byte_size(source) - byte_size(rest))
        seq(rest, add(total, cost), nil, acc)

      :no ->
        <<_, rest::binary>> = source
        seq(rest, add(total, @literal), {:single, @literal}, acc)
    end
  end

  defp seq(<<c::utf8, rest::binary>>, total, _last, acc) do
    cost = literal(<<c::utf8>>, acc.unicode)
    seq(rest, add(total, cost), {:single, cost}, acc)
  end

  defp seq(<<_, rest::binary>>, total, _last, acc),
    do: seq(rest, add(total, @literal), {:single, @literal}, acc)

  defp literal(char, true), do: @literal + 2 * (byte_size(char) - 1)
  defp literal(char, false), do: @literal * byte_size(char)

  # A quantifier on a single item adds its counts; on a group, PCRE writes the group once
  # for each count. What a quantifier gives is counted as a group, should another follow.
  defp repeat(total, {:single, cost}, _count),
    do: {add(total, @quantifier), {:group, cost + @quantifier}}

  defp repeat(total, {:group, cost}, count) do
    copies = min(count * (cost + @copy), @cap)
    {add(max(total - cost, 0), copies), {:group, copies}}
  end

  # A lazy or possessive mark after a quantifier.
  defp lazy(<<c, rest::binary>>) when c in [??, ?+], do: rest
  defp lazy(rest), do: rest

  # The copies of a group a quantifier may write: two for *, + and ?; n for {n}, m for
  # {n,m} and {,m}, n + 1 for {n,}. Blanks inside the braces are read as PCRE2 reads them.
  defp quantifier(<<c, rest::binary>>) when c in [?*, ?+, ??], do: {:ok, 2, rest}

  defp quantifier(<<"{", rest::binary>>) do
    with {low, rest} <- number(blanks(rest)),
         {comma?, rest} <- comma(blanks(rest)),
         {high, rest} <- number(blanks(rest)),
         <<"}", rest::binary>> <- blanks(rest),
         true <- low != nil or high != nil do
      count =
        cond do
          not comma? -> low
          high == nil -> low + 1
          true -> max(high, low || 0)
        end

      {:ok, max(count, 1), rest}
    else
      _ -> :no
    end
  end

  defp blanks(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r, ?\f, ?\v], do: blanks(rest)
  defp blanks(rest), do: rest

  defp comma(<<",", rest::binary>>), do: {true, rest}
  defp comma(rest), do: {false, rest}

  defp number(<<d, _::binary>> = source) when d in ?0..?9, do: digits(source, 0)
  defp number(rest), do: {nil, rest}

  defp digits(<<d, rest::binary>>, n) when d in ?0..?9,
    do: digits(rest, min(n * 10 + d - ?0, @most_count))

  defp digits(rest, n), do: {n, rest}

  # The characters of \Q...\E, each a literal, up to \E or the end.
  defp quoted(<<"\\E", rest::binary>>, cost, _unicode?), do: {cost, rest}
  defp quoted(<<>>, cost, _unicode?), do: {cost, <<>>}

  defp quoted(<<c::utf8, rest::binary>>, cost, unicode?),
    do: quoted(rest, cost + literal(<<c::utf8>>, unicode?), unicode?)

  defp quoted(<<_, rest::binary>>, cost, unicode?), do: quoted(rest, cost + @literal, unicode?)

  # What an escape takes after its backslash.
  defp escape(<<c, "{", rest::binary>>) when c in [?p, ?P, ?x, ?o, ?N, ?g, ?k], do: upto(rest, ?})
  defp escape(<<c, "<", rest::binary>>) when c in [?g, ?k], do: upto(rest, ?>)
  defp escape(<<c, "'", rest::binary>>) when c in [?g, ?k], do: upto(rest, ?')
  defp escape(<<"c", _::utf8, rest::binary>>), do: rest
  defp escape(<<d, _::binary>> = source) when d in ?0..?9, do: elem(digits(source, 0), 1)
  defp escape(<<_::utf8, rest::binary>>), do: rest
  defp escape(<<_, rest::binary>>), do: rest
  defp escape(<<>>), do: <<>>

  defp upto(<<c, rest::binary>>, c), do: rest
  defp upto(<<_, rest::binary>>, c), do: upto(rest, c)
  defp upto(<<>>, _c), do: <<>>

  # A class after its "[": the bytes up to its "]", and what follows. PCRE first skips,
  # in any order, each "\E", each "\Q\E" and one "^"; a "]" after them is a literal.
  # [:name:], [.x.] and [=x=] end where PCRE2's check_posix_syntax ends them; \Q...\E and
  # escapes are taken whole. So the class ends where PCRE ends it.
  defp class(source) do
    rest = source |> class_start(false) |> class_body()
    bytes = byte_size(source) - byte_size(rest)

    case rest do
      <<"]", rest::binary>> -> {bytes, rest}
      rest -> {bytes, rest}
    end
  end

  defp class_start(<<"\\E", rest::binary>>, negated?), do: class_start(rest, negated?)
  defp class_start(<<"\\Q\\E", rest::binary>>, negated?), do: class_start(rest, negated?)
  defp class_start(<<"^", rest::binary>>, false), do: class_start(rest, true)
  defp class_start(<<"]", rest::binary>>, _negated?), do: rest
  defp class_start(rest, _negated?), do: rest

  defp class_body(<<"]", _::binary>> = rest), do: rest
  defp class_body(<<>>), do: <<>>

  defp class_body(<<"\\Q", rest::binary>>) do
    {_cost, rest} = quoted(rest, 0, true)
    class_body(rest)
  end

  defp class_body(<<"\\", rest::binary>>), do: class_body(escape(rest))

  defp class_body(<<"[", t, rest::binary>>) when t in [?:, ?., ?=] do
    case posix(rest, t) do
      {:ok, rest} -> class_body(rest)
      :no -> class_body(<<t, rest::binary>>)
    end
  end

  defp class_body(<<_, rest::binary>>), do: class_body(rest)

  defp posix(<<"\\", c, rest::binary>>, t) when c in [?], ?\\], do: posix(rest, t)
  defp posix(<<"[", t, _::binary>>, t), do: :no
  defp posix(<<"]", _::binary>>, _t), do: :no
  defp posix(<<t, "]", rest::binary>>, t), do: {:ok, rest}
  defp posix(<<_, rest::binary>>, t), do: posix(rest, t)
  defp posix(<<>>, _t), do: :no

  # A group after its "(". A comment, (?#...), up to the first ")", leaves what a
  # quantifier after it applies to as it was, and so does an option setting, (?i), which
  # PCRE writes as nothing. Options, (?i), or a call, such as (?R), give a quantifier
  # that follows the greater of what came before and a group.
  defp group(<<"?#", rest::binary>>, total, last, acc),
    do: seq(after_comment(rest), total, last, acc)

  defp group(<<"*", _::binary>> = rest, total, last, acc),
    do: body(rest, total, last, %{acc | unknown: true})

  defp group(<<"?", rest::binary>> = all, total, last, acc) do
    {letters, after_letters} = letters(rest, "")
    acc = if options?(letters), do: acc, else: %{acc | unknown: true}

    case after_letters do
      <<")", more::binary>> ->
        seq(more, add(total, @group), wider(last, {:group, @group}), acc)

      _ ->
        body(all, total, last, opener(rest, letters, after_letters, acc))
    end
  end

  defp group(rest, total, last, acc), do: body(rest, total, last, acc)

  # The group constructs read here: (?: (?= (?! (?<= (?<! (?> (?| (?( (?<name> (?P<name>
  # (?'name' (?P=name) (?P>name) (?&name) (?R) (?1) (?+1) (?-1), and options with a ":".
  # Any other, such as a callout (?C, is counted at the cap.
  defp opener(_rest, _letters, <<":", _::binary>>, acc), do: acc
  defp opener(<<"<", c, _::binary>>, _, _, acc) when c in [?=, ?!], do: acc
  defp opener(<<"<", rest::binary>>, _, _, acc), do: named(rest, ?>, acc)
  defp opener(<<"P<", rest::binary>>, _, _, acc), do: named(rest, ?>, acc)
  defp opener(<<"'", rest::binary>>, _, _, acc), do: named(rest, ?', acc)
  defp opener(<<"P", c, _::binary>>, _, _, acc) when c in [?=, ?>], do: acc
  defp opener(<<c, _::binary>>, _, _, acc) when c in [?:, ?=, ?!, ?>, ?|, ?(, ?&, ?+, ?-], do: acc
  defp opener(<<d, _::binary>>, _, _, acc) when d in ?0..?9, do: acc
  defp opener(_rest, _letters, _after, acc), do: %{acc | unknown: true}

  defp named(rest, close, acc) do
    case :binary.match(rest, <<close>>) do
      {at, _} -> %{acc | names: acc.names + 1, longest: max(acc.longest, at)}
      :nomatch -> acc
    end
  end

  defp body(rest, total, _last, acc) do
    {inner, rest, acc} = seq(rest, 0, nil, acc)

    rest =
      case rest do
        <<")", rest::binary>> -> rest
        rest -> rest
      end

    cost = add(inner, @group)
    seq(rest, add(total, cost), {:group, cost}, acc)
  end

  defp wider(nil, last), do: last
  defp wider({_, a}, {_, b}), do: {:group, max(a, b)}

  defp after_comment(<<")", rest::binary>>), do: rest
  defp after_comment(<<_, rest::binary>>), do: after_comment(rest)
  defp after_comment(<<>>), do: <<>>

  # Letters after "(?" read as options, or (?R): PCRE2's option letters but x, which may
  # turn on extended mode, where PCRE skips blanks and comments this reading counts.
  defp options?("R"), do: true

  defp options?(letters),
    do: for(<<c <- letters>>, reduce: true, do: (ok -> ok and c in ~c"imnrsJUaDSWPT^-"))

  defp letters(<<c, rest::binary>>, acc) when c in ?a..?z or c in ?A..?Z or c in [?-, ?^],
    do: letters(rest, acc <> <<c>>)

  defp letters(rest, acc), do: {acc, rest}

  ## A schema

  # The sources JSV's embedded meta-schemas compile, which a reference out of the schema
  # can reach. A build of the draft 2020-12 meta-schema compiles its 2 patterns once each.
  @meta_patterns (fn ->
                    collect = fn
                      collect, %{} = map ->
                        Enum.flat_map(map, fn
                          {"pattern", source} when is_binary(source) -> [source]
                          {"patternProperties", %{} = p} -> Map.keys(p) ++ collect.(collect, p)
                          {_key, value} -> collect.(collect, value)
                        end)

                      collect, list when is_list(list) ->
                        Enum.flat_map(list, &collect.(collect, &1))

                      _collect, _other ->
                        []
                    end

                    for url <- Embedded.embedded_normalized_ids(),
                        {:normal, schema} = Embedded.resolve(url, []),
                        source <- collect.(collect, schema),
                        do: source
                  end).()

  @doc """
  schema/1 is an upper bound on the bytes the patterns of `schema`, a decoded JSON
  Schema, hold once JSV has built it (see the module's documentation).

  JSV builds the schema from its root, and once more the target of each distinct
  reference: two spellings of one pointer, an anchor and a pointer to one place, or a
  pointer to a place inside another target each build it again. So the bound counts each
  `pattern` and each key of a `patternProperties`, anywhere in the schema, once, then
  adds, for each distinct `$ref` and `$dynamicRef`, the patterns of what it points at:

    * a pointer in the schema, `#/...`, its target;
    * an anchor, `#name`, every place that names it;
    * any other reference, or any reference in a schema with an `$id` below its root,
      the whole schema and twice the patterns of JSV's embedded meta-schemas;
    * a `$dynamicRef`, all of that and every place that names it.

  A pointer counts the place a JSON Pointer reads: one JSV reads elsewhere, or not at
  all, still counts at least as much as JSV builds.
  """
  @spec schema(term) :: non_neg_integer
  def schema(schema) do
    state = %{costs: %{}, anchors: %{}, refs: MapSet.new(), nested_id: false}
    {whole, state} = walk(schema, [], true, state)
    meta = 2 * (@meta_patterns |> Enum.map(&estimate/1) |> Enum.sum())

    Enum.reduce(state.refs, whole, fn ref, sum -> sum + reference(ref, state, whole + meta) end)
  end

  # The patterns a reference builds again. `whole` is the whole schema and the
  # meta-schemas, what an unresolved reference counts.
  defp reference({:dynamic, ref}, state, whole),
    do: whole + Map.get(state.anchors, String.trim_leading(ref, "#"), 0)

  defp reference(_ref, %{nested_id: true}, whole), do: whole
  defp reference(ref, state, _whole) when ref in ["#", "#/"], do: Map.fetch!(state.costs, [])

  # Each segment read as JSV reads it: "~1", then "~0", then percent-decoding. A segment
  # URI.decode/1 raises on, as an earlier Elixir may on a malformed "%", counts the whole
  # schema.
  defp reference("#/" <> pointer, state, whole) do
    path =
      pointer
      |> String.split("/")
      |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~") |> URI.decode()))
      |> Enum.reverse()

    Map.get(state.costs, path, whole)
  rescue
    ArgumentError -> whole
  end

  defp reference("#" <> name, state, whole), do: Map.get(state.anchors, name, whole)
  defp reference(_ref, _state, whole), do: whole

  # Reads the schema once: the patterns' bytes under each object and list, by its path
  # reversed (so the paths share their tails), each anchor's, the distinct references, and
  # whether an `$id` is below the root. Its work grows with the schema's bytes, and each
  # reference adds a lookup: measured on OTP 29, 4000 patterns of about 55 bytes, 270941
  # bytes of JSON, take 923843 reductions, and 1000 settings, each against a pattern,
  # 138772.
  defp walk(%{} = map, path, root?, state) do
    {sum, state} =
      Enum.reduce(map, {0, state}, fn {key, value}, {sum, state} ->
        state = noted(key, value, root?, state)
        {below, state} = walk(value, [key | path], false, state)
        {sum + patterns_at(key, value) + below, state}
      end)

    anchors =
      Enum.reduce(["$anchor", "$dynamicAnchor"], state.anchors, fn key, anchors ->
        case map do
          %{^key => name} when is_binary(name) -> Map.update(anchors, name, sum, &(&1 + sum))
          _ -> anchors
        end
      end)

    {sum, %{state | costs: Map.put(state.costs, path, sum), anchors: anchors}}
  end

  defp walk(list, path, _root?, state) when is_list(list) do
    {sum, state, _index} =
      Enum.reduce(list, {0, state, 0}, fn value, {sum, state, index} ->
        {below, state} = walk(value, [Integer.to_string(index) | path], false, state)
        {sum + below, state, index + 1}
      end)

    {sum, %{state | costs: Map.put(state.costs, path, sum)}}
  end

  defp walk(_scalar, _path, _root?, state), do: {0, state}

  defp patterns_at("pattern", source) when is_binary(source), do: estimate(source)

  defp patterns_at("patternProperties", %{} = properties),
    do: properties |> Map.keys() |> Enum.map(&estimate/1) |> Enum.sum()

  defp patterns_at(_key, _value), do: 0

  defp noted("$ref", ref, _root?, state) when is_binary(ref),
    do: %{state | refs: MapSet.put(state.refs, ref)}

  defp noted("$dynamicRef", ref, _root?, state) when is_binary(ref),
    do: %{state | refs: MapSet.put(state.refs, {:dynamic, ref})}

  defp noted("$id", _id, false, state), do: %{state | nested_id: true}
  defp noted(_key, _value, _root?, state), do: state
end
