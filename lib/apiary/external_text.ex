defmodule Apiary.ExternalText do
  @moduledoc """
  A text an external system sent, through an adapter or an integration, or a run's report,
  as a page shows it: an item's title or body, a name, an author, a release's name, what a
  run says it is about, the signal a run's program ended on. What is stored, and what a
  run is given, stays as it was sent.

    * The invisible characters are dropped: every format character (Unicode's Cf), such
      as the bidirectional embeddings, overrides and isolates, the marks LRM, RLM and ALM,
      the zero-width space, the soft hyphen, the byte order mark and the tag characters;
      the line and paragraph separators; and the combining grapheme joiner, the Khmer
      inherent vowels and the Mongolian free variation selectors, which show nothing
      either. The join controls ZWNJ and ZWJ stay: a name in some scripts, and an emoji
      sequence, needs them. An emoji flag of a subdivision, made with tag characters, is
      shown as a plain black flag.
    * A control character, C0, DEL or C1, is shown as U+FFFD, so a reader sees that one
      was there.
    * Bytes that are not UTF-8 text are shown as U+FFFD.

  `line/1` is a text of one line: a tab, a line feed and a carriage return are control
  characters there. `lines/1` is a text of several lines, a body: they stay. A page shows a
  line inside `<bdi>` (`ApiaryWeb.ExternalText.external_text/1`), so its direction does
  not run into the text around it.

  `present/1` is a line a page shows only when there is something to see: nil where the
  line, once shown, is empty or only whitespace (every Unicode space separator, such as
  the no-break space and the spaces from U+2000 to U+200A, as `String.trim/1` trims
  them), so a page can tell a line with something to show from one without.
  `present_lines/1` is the same for a text of several lines, whose tabs and line breaks
  are whitespace too.

  `marked/1` is for a text a page shows because it was refused as malformed, such as a
  host refused for its form, and for a text that was sent but has nothing left to show
  once `present/1` or `present_lines/1` cleans it: what is wrong with it, or that it was
  there at all, is what the reader needs to see. So every character `line/1` drops or
  replaces, the join controls ZWNJ and ZWJ with them, and every byte that is not UTF-8
  text, is shown as U+FFFD instead. It is never visibly blank: an empty text, none, and
  one that is only whitespace once marked, are U+FFFD alone. `sent/1` is `present/1`,
  else `marked/1`, for a text that was sent. Every other text takes `line/1`, `lines/1`,
  `present/1` or `present_lines/1`.
  """

  # With the `factory` feature, which the documentation leaves out, the texts include a
  # collection's title and a ticket's and a comment's body.

  # Wider than the set an explore result's text refuses (Apiary.WorkItems.WorkItem,
  # Apiary.Dispatches.Inputs): a page drops more than a text that is stored or given to a
  # run may hold, and those stay as sent.
  @invisible ~r/(?![\x{200C}\x{200D}])[\p{Cf}\x{2028}\x{2029}\x{34F}\x{17B4}\x{17B5}\x{180B}-\x{180D}\x{180F}]/u
  @control ~r/[\x{0}-\x{1F}\x{7F}-\x{9F}]/u
  @control_but_lines ~r/[\x{0}-\x{8}\x{B}\x{C}\x{E}-\x{1F}\x{7F}-\x{9F}]/u
  # What `marked/1` shows as U+FFFD: every invisible character, the join controls too,
  # and every control character.
  @marked Regex.compile!(
            "[\\p{Cf}\\x{2028}\\x{2029}\\x{34F}\\x{17B4}\\x{17B5}\\x{180B}-\\x{180D}" <>
              "\\x{180F}\\x{0}-\\x{1F}\\x{7F}-\\x{9F}]",
            "u"
          )

  @doc "`text`, a text of one line an external system sent, as a page shows it; nil stays nil."
  @spec line(String.t() | nil) :: String.t() | nil
  def line(nil), do: nil
  def line(text) when is_binary(text), do: shown(text, @control)

  @doc """
  `text`, a text of one line an external system sent, as a page shows it (`line/1`), or
  nil where that is empty or only whitespace once trimmed; nil stays nil. What it returns
  is the line as `line/1` shows it, not trimmed.
  """
  @spec present(String.t() | nil) :: String.t() | nil
  def present(text), do: text |> line() |> unless_blank()

  @doc """
  `text`, a text of several lines an external system sent, as a page shows it
  (`lines/1`), or nil where that is empty or only whitespace once trimmed, as
  `present/1` has it for a line; nil stays nil. What it returns is not trimmed.
  """
  @spec present_lines(String.t() | nil) :: String.t() | nil
  def present_lines(text), do: text |> lines() |> unless_blank()

  @doc """
  `text`, a text of one line an external system sent, as a page shows it where it was
  sent: `present/1`, or `marked/1` where nothing is left of it once cleaned, so a text
  that was sent never reads as absent; nil for nil or an empty text.
  """
  @spec sent(String.t() | nil) :: String.t() | nil
  def sent(text) when is_binary(text) and text != "", do: present(text) || marked(text)
  def sent(_text), do: nil

  # nil for a text that is empty or only whitespace once trimmed, the one rule of
  # `present/1` and `present_lines/1`; any other text as it is.
  defp unless_blank(nil), do: nil
  defp unless_blank(text), do: if(String.trim(text) == "", do: nil, else: text)

  @doc """
  `text`, a text of one line a page shows because it was refused as malformed, or because
  it was sent and has nothing left to show once cleaned, with every invisible and control
  character, and every byte that is not UTF-8 text, as U+FFFD; U+FFFD alone for nil, an
  empty text, and one that is only whitespace once marked (`String.trim/1`), so it is
  never visibly blank.
  """
  @spec marked(String.t() | nil) :: String.t()
  def marked(nil), do: "\u{FFFD}"
  def marked(""), do: "\u{FFFD}"

  def marked(text) when is_binary(text) do
    shown = text |> String.replace_invalid() |> String.replace(@marked, "\u{FFFD}")
    if String.trim(shown) == "", do: "\u{FFFD}", else: shown
  end

  @doc "`text`, a text of several lines an external system sent, as a page shows it; nil stays nil."
  @spec lines(String.t() | nil) :: String.t() | nil
  def lines(nil), do: nil
  def lines(text) when is_binary(text), do: shown(text, @control_but_lines)

  defp shown(text, control) do
    text
    |> String.replace_invalid()
    |> String.replace(@invisible, "")
    |> String.replace(control, "\u{FFFD}")
  end
end
