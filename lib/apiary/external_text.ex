defmodule Apiary.ExternalText do
  @moduledoc """
  A text an external system sent, through an adapter or an integration, as a page shows it:
  a collection's or an item's title, a name, an author, a release's name, a ticket's or a
  comment's body. What is stored, and what a run is given, stays as it was sent.

    * The invisible characters are dropped: the bidirectional embeddings, overrides and
      isolates, the marks LRM, RLM and ALM, the Mongolian vowel separator, the zero-width
      space, the soft hyphen, the word joiner and the invisible operators, the byte order
      mark, the interlinear annotation characters, and the line and paragraph separators.
      The join controls ZWNJ and ZWJ stay: a name in some scripts, and an emoji sequence,
      needs them.
    * A control character, C0, DEL or C1, is shown as U+FFFD, so a reader sees that one
      was there.
    * Bytes that are not UTF-8 text are shown as U+FFFD.

  `line/1` is a text of one line: a tab, a line feed and a carriage return are control
  characters there. `lines/1` is a text of several lines, a body: they stay. A page shows a
  line inside `<bdi>` (`ApiaryWeb.ExternalText.external_text/1`), so its direction does
  not run into the text around it.
  """

  # The set an explore result's text refuses (Apiary.WorkItems.WorkItem,
  # Apiary.Dispatches.Inputs).
  @invisible ~r/[\x{AD}\x{61C}\x{180E}\x{200B}\x{200E}\x{200F}\x{2028}\x{2029}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{2066}-\x{2069}\x{FEFF}\x{FFF9}-\x{FFFB}]/u
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
