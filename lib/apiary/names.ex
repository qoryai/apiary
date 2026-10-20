defmodule Apiary.Names do
  @moduledoc """
  The characters a name or a label a person types may hold, where other people read it:
  a workspace's name, a node's, a pool's, a gateway's and an adapter's, an access key's
  label, a service connection's name and a secret's note.

  None may be a control character (C0, DEL, C1), a format character (category Cf: the
  bidirectional controls, the zero-width space, the byte order mark, the soft hyphen, tag
  characters and the like) or the line or paragraph separator (U+2028, U+2029), which
  would hide part of the name, or make it, or the text around it, read otherwise than it
  is. The join controls ZWNJ and ZWJ stay allowed: a name in some scripts, and an emoji
  sequence, needs them. An organisation's name refuses the same control and format
  characters, and keeps more rules (`Apiary.Organisations.Organisation.validate_name/2`).
  """
  use Gettext, backend: ApiaryWeb.Gettext
  import Ecto.Changeset

  @refused ~r/(?![\x{200C}\x{200D}])[\p{Cc}\p{Cf}\x{2028}\x{2029}]/u
  # The same, but for tab and line feed: a text of several lines.
  @refused_in_lines ~r/(?![\x{9}\x{A}\x{200C}\x{200D}])[\p{Cc}\p{Cf}\x{2028}\x{2029}]/u

  @doc """
  validate_characters/3 refuses a `field` of `changeset` that is not UTF-8 text (`must be
  UTF-8 text`) or that holds a control character, a format character but ZWNJ and ZWJ, or
  a line or paragraph separator (`must not contain control characters`).

  With `lines: true`, for a text of several lines a person writes, tab and line feed are
  allowed too; every other character above stays refused, the carriage return among
  them, which the caller turns into a line feed first where it takes one.
  """
  @spec validate_characters(Ecto.Changeset.t(), atom, keyword) :: Ecto.Changeset.t()
  def validate_characters(changeset, field, opts \\ []) do
    refused = if Keyword.get(opts, :lines, false), do: @refused_in_lines, else: @refused

    validate_change(changeset, field, fn ^field, value ->
      cond do
        not String.valid?(value) ->
          [{field, dgettext_noop("errors", "must be UTF-8 text")}]

        Regex.match?(refused, value) ->
          [{field, dgettext_noop("errors", "must not contain control characters")}]

        true ->
          []
      end
    end)
  end
end
