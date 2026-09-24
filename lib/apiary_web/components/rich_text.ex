defmodule ApiaryWeb.RichText do
  @moduledoc """
  Whole translated sentences as rich text (`ApiaryWeb.PolicyComponents.rich/1`): a
  sentence is one msgid, and the parts of it that are marked up (a host in mono, a word
  in bold, a chip) are its bindings.

      rich_gettext("%{name} is already named here.", name: {:m, name})
      #=> [{:m, "db"}, " is already named here."]

  A binding may be a binary or any rich text. The msgid is extracted like any other
  (`docs/lingo.md`), and a body's catalogue may move the bindings where its sentence
  needs them.
  """

  @binding ~r/%\{(\w+)\}/

  @doc """
  `gettext/2` whose bindings are rich text: the translated sentence is split at its
  bindings, and each is replaced by its part. `bindings` is a keyword list literal.
  """
  defmacro rich_gettext(msgid, bindings \\ []) do
    quote do
      require Gettext.Macros

      ApiaryWeb.RichText.split(
        Gettext.Macros.gettext_with_backend(
          ApiaryWeb.Gettext,
          unquote(msgid),
          unquote(placeholders(bindings))
        ),
        unquote(bindings)
      )
    end
  end

  @doc "`pgettext/3` whose bindings are rich text, as `rich_gettext/2`."
  defmacro rich_pgettext(msgctxt, msgid, bindings \\ []) do
    quote do
      require Gettext.Macros

      ApiaryWeb.RichText.split(
        Gettext.Macros.pgettext_with_backend(
          ApiaryWeb.Gettext,
          unquote(msgctxt),
          unquote(msgid),
          unquote(placeholders(bindings))
        ),
        unquote(bindings)
      )
    end
  end

  @doc """
  `ngettext/4` whose bindings other than `count` are rich text, as `rich_gettext/2`.
  `%{count}` is the raw number.
  """
  defmacro rich_ngettext(msgid, msgid_plural, count, bindings \\ []) do
    quote do
      require Gettext.Macros

      ApiaryWeb.RichText.split(
        Gettext.Macros.ngettext_with_backend(
          ApiaryWeb.Gettext,
          unquote(msgid),
          unquote(msgid_plural),
          unquote(count),
          unquote(placeholders(bindings))
        ),
        unquote(bindings)
      )
    end
  end

  # Each binding stands for itself, so gettext leaves `%{key}` in the sentence for
  # `split/2` to replace.
  defp placeholders(bindings) when is_list(bindings) do
    for {key, _value} <- bindings, is_atom(key), do: {key, "%{#{key}}"}
  end

  defp placeholders(bindings),
    do:
      raise(
        ArgumentError,
        "rich text bindings must be a keyword list literal, got: #{Macro.to_string(bindings)}"
      )

  @doc """
  Splits a sentence at its `%{key}` bindings into rich text, each binding replaced by its
  part in `bindings`. A key with no part stays as it is written.
  """
  def split(sentence, bindings) when is_binary(sentence) do
    @binding
    |> Regex.split(sentence, include_captures: true, trim: true)
    |> Enum.map(fn piece ->
      case Regex.run(@binding, piece) do
        [^piece, key] -> part(bindings, key, piece)
        _ -> piece
      end
    end)
  end

  defp part(bindings, key, piece) do
    Enum.find_value(bindings, piece, fn {k, v} -> if Atom.to_string(k) == key, do: v end)
  end
end
