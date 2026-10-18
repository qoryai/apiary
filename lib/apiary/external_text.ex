defmodule Apiary.ExternalText do
  @moduledoc """
  A text an external system sent, through an adapter or an integration, as a page shows it:
  a collection's or an item's title, a name, an author, a release's name, a ticket's or a
  comment's body. What is stored, and what a run is given, stays as it was sent.

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
  """

  # Wider than the set an explore result's text refuses (Apiary.WorkItems.WorkItem,
  # Apiary.Dispatches.Inputs): a page drops more than a text that is stored or given to a
  # run may hold, and those stay as sent.
  @invisible ~r/(?![\x{200C}\x{200D}])[\p{Cf}\x{2028}\x{2029}\x{34F}\x{17B4}\x{17B5}\x{180B}-\x{180D}\x{180F}]/u
  @control ~r/[\x{0}-\x{1F}\x{7F}-\x{9F}]/u
  @control_but_lines ~r/[\x{0}-\x{8}\x{B}\x{C}\x{E}-\x{1F}\x{7F}-\x{9F}]/u

  @doc "`text`, a text of one line an external system sent, as a page shows it; nil stays nil."
  @spec line(String.t() | nil) :: String.t() | nil
  def line(nil), do: nil
  def line(text) when is_binary(text), do: shown(text, @control)

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
