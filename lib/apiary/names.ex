defmodule Apiary.Names do
  @moduledoc """
  The characters a name or a label a person types may hold, where other people read it:
  a workspace's name, a node's, a pool's, a gateway's and an adapter's, an access key's
  label, a service connection's name and a secret's note.

  None may be a control character (C0, DEL, C1) or a bidirectional control (the
  embeddings, overrides and isolates, U+202A to U+202E and U+2066 to U+2069, and the
  marks LRM, RLM and ALM), which would make the name, or the text around it, read
  otherwise than it is. The join controls ZWNJ and ZWJ stay allowed: a name in some
  scripts, and an emoji sequence, needs them. An organisation's name keeps stricter rules
  (`Apiary.Organisations.Organisation.validate_name/2`).
  """
  use Gettext, backend: ApiaryWeb.Gettext
  import Ecto.Changeset

  @refused ~r/[\p{Cc}\x{061C}\x{200E}\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u

  @doc """
  validate_characters/2 refuses a `field` of `changeset` that is not UTF-8 text (`must be
  UTF-8 text`) or that holds a control character or a bidirectional control (`must not
  contain control characters`).
  """
  @spec validate_characters(Ecto.Changeset.t(), atom) :: Ecto.Changeset.t()
  def validate_characters(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        not String.valid?(value) ->
          [{field, dgettext_noop("errors", "must be UTF-8 text")}]

        Regex.match?(@refused, value) ->
          [{field, dgettext_noop("errors", "must not contain control characters")}]

        true ->
          []
      end
    end)
  end
end
