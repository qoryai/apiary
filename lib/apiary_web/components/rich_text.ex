defmodule ApiaryWeb.RichText do
  @moduledoc """
  Whole translated sentences with marked-up parts (`docs/lingo.md`): a sentence is one
  msgid, and the parts of it that are marked up (a count in bold, a host in mono, a link,
  a clock) are its bindings.

      <.rich text={rich_gettext("Invitation sent to %{email}.", email: {:b, invitation.email})} />

  `rich_gettext/2`, `rich_pgettext/3` and `rich_ngettext/4` translate a sentence and split
  it at its bindings into rich text; `rich/1` renders rich text. A domain's catalogue may
  move the bindings wherever its sentence needs them. The bindings never pass through the
  sentence as text, so a binding that holds `%{...}` or any other mark stays what it is.
  They translate with the calling module's own backend, the one its
  `use Gettext, backend: ...` names, as `gettext/2` does, and so extract into its
  catalogues: the core's for a core module, an edition's for the edition's.

  Rich text is a binary, a list of rich text, or one of:

    * `{:b, rich}`, `{:b, rich, class}`: bold
    * `{:m, text}`, `{:m, text, class}`: monospace, a host or a target
    * `{:code, text}`, `{:code, text, class}`: a chip of code, a rule or a path
    * `{:bad, rich}`: in the denied hue
    * `{:bdi, rich}`: isolated (`<bdi>`), for words Forager gave, such as a run's
      title, so a bidirectional character in them reorders nothing of the sentence
    * `{:link, path, rich}`, `{:link, path, rich, class}`: a link that navigates
    * `{:href, url, rich}`, `{:href, url, rich, class}`: a link that loads a page
    * `{:term, word, standard}`: a word with its standard term on hover (`CoreComponents.term/1`)
    * `{:part, name}`: the `:part` slot of that name, for markup a template writes
    * anything already safe HTML: a rendered component or `{:safe, iodata}`
    * `nil`, which is nothing

  Everything else is interpolated, so everything is escaped.
  """
  use Phoenix.Component

  # `CoreComponents` writes its own sentences with this module, so `term/1` is called by
  # its full name: a call at render, no compile-time dependency.
  alias ApiaryWeb.CoreComponents

  @binding ~r/%\{(\w+)\}/

  ## Translating

  @doc """
  `gettext/2` whose bindings are rich text: the translated sentence is split at its
  bindings, and each is replaced by its part. `bindings` is a keyword list literal.

      rich_gettext("%{name} is already named here.", name: {:m, name})
      #=> [{:m, "db"}, " is already named here."]
  """
  defmacro rich_gettext(msgid, bindings \\ []) do
    quote do
      require Gettext.Macros

      ApiaryWeb.RichText.split(
        Gettext.Macros.gettext(unquote(msgid), unquote(placeholders(bindings))),
        unquote(bindings)
      )
    end
  end

  @doc "`pgettext/3` whose bindings are rich text, as `rich_gettext/2`."
  defmacro rich_pgettext(msgctxt, msgid, bindings \\ []) do
    quote do
      require Gettext.Macros

      ApiaryWeb.RichText.split(
        Gettext.Macros.pgettext(
          unquote(msgctxt),
          unquote(msgid),
          unquote(placeholders(bindings))
        ),
        unquote(bindings)
      )
    end
  end

  @doc """
  `ngettext/4` whose bindings are rich text, as `rich_gettext/2`. `%{count}` is the raw
  number; to show it formatted or marked up, give it its own binding:

      rich_ngettext("%{number} run", "%{number} runs", n, number: {:b, Format.number(n)})
  """
  defmacro rich_ngettext(msgid, msgid_plural, count, bindings \\ []) do
    quote do
      require Gettext.Macros

      ApiaryWeb.RichText.split(
        Gettext.Macros.ngettext(
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

  @doc """
  plain_text/2 is the words of rich text without its markup, for where only text goes,
  such as the `title` that shows a cut line whole. A `{:part, name}` is the text `parts`
  gives it (none without); a rendered component or safe HTML has no words here.

      "Handed to %{tool} by rule %{rule}"
      |> rich_gettext(tool: {:b, "files"}, rule: {:part, :rule})
      |> plain_text(%{rule: "files.example"})
      #=> "Handed to files by rule files.example"
  """
  @spec plain_text(term, %{optional(atom) => String.t()}) :: String.t()
  def plain_text(rich, parts \\ %{})
  def plain_text(nil, _parts), do: ""
  def plain_text(text, _parts) when is_binary(text), do: text
  def plain_text(number, _parts) when is_number(number), do: to_string(number)

  def plain_text(pieces, parts) when is_list(pieces),
    do: Enum.map_join(pieces, &plain_text(&1, parts))

  def plain_text({:part, name}, parts), do: Map.get(parts, name) || ""
  def plain_text({:term, word, _standard}, parts), do: plain_text(word, parts)

  def plain_text({link, _to, inner}, parts) when link in [:link, :href],
    do: plain_text(inner, parts)

  def plain_text({link, _to, inner, _class}, parts) when link in [:link, :href],
    do: plain_text(inner, parts)

  def plain_text({mark, inner}, parts) when mark in [:b, :m, :code, :bad, :bdi],
    do: plain_text(inner, parts)

  def plain_text({mark, inner, _class}, parts) when mark in [:b, :m, :code],
    do: plain_text(inner, parts)

  def plain_text(_html, _parts), do: ""

  ## Rendering

  @doc """
  Renders rich text. A `{:part, name}` in it is filled by the `:part` slot of that name,
  so a template can put its own markup in a sentence:

      <.rich text={rich_gettext("%{time} by a member", time: {:part, :time})}>
        <:part name={:time}><.clock at={@run.closed_at} id="closed-at" /></:part>
      </.rich>
  """
  attr :text, :any, required: true

  slot :part do
    attr :name, :atom, required: true
  end

  def rich(assigns) do
    ~H|<.piece :for={piece <- List.wrap(@text)} piece={piece} parts={@part} />|
  end

  attr :piece, :any, required: true
  attr :parts, :list, required: true

  defp piece(%{piece: nil} = assigns), do: ~H""

  defp piece(%{piece: pieces} = assigns) when is_list(pieces),
    do: ~H|<.piece :for={piece <- @piece} piece={piece} parts={@parts} />|

  defp piece(%{piece: {:b, inner}} = assigns) do
    assigns = assign(assigns, :inner, inner)
    ~H|<b><.piece piece={@inner} parts={@parts} /></b>|
  end

  defp piece(%{piece: {:b, inner, class}} = assigns) do
    assigns = assign(assigns, inner: inner, class: class)
    ~H|<b class={@class}><.piece piece={@inner} parts={@parts} /></b>|
  end

  defp piece(%{piece: {:m, inner}} = assigns),
    do: piece(%{assigns | piece: {:m, inner, "font-mono text-[12px]"}})

  defp piece(%{piece: {:m, inner, class}} = assigns) do
    assigns = assign(assigns, inner: inner, class: class)
    ~H|<span class={@class}><.piece piece={@inner} parts={@parts} /></span>|
  end

  defp piece(%{piece: {:code, inner}} = assigns),
    do: piece(%{assigns | piece: {:code, inner, "q-rule"}})

  defp piece(%{piece: {:code, inner, class}} = assigns) do
    assigns = assign(assigns, inner: inner, class: class)
    ~H|<code class={@class}><.piece piece={@inner} parts={@parts} /></code>|
  end

  defp piece(%{piece: {:bdi, inner}} = assigns) do
    assigns = assign(assigns, :inner, inner)
    ~H|<bdi><.piece piece={@inner} parts={@parts} /></bdi>|
  end

  defp piece(%{piece: {:bad, inner}} = assigns) do
    assigns = assign(assigns, :inner, inner)
    ~H|<span class="q-bad"><.piece piece={@inner} parts={@parts} /></span>|
  end

  defp piece(%{piece: {:link, navigate, inner}} = assigns),
    do: piece(%{assigns | piece: {:link, navigate, inner, "q-link"}})

  defp piece(%{piece: {:link, navigate, inner, class}} = assigns) do
    assigns = assign(assigns, navigate: navigate, inner: inner, class: class)

    ~H|<.link navigate={@navigate} class={@class}><.piece piece={@inner} parts={@parts} /></.link>|
  end

  defp piece(%{piece: {:href, href, inner}} = assigns),
    do: piece(%{assigns | piece: {:href, href, inner, "q-link"}})

  defp piece(%{piece: {:href, href, inner, class}} = assigns) do
    assigns = assign(assigns, href: href, inner: inner, class: class)
    ~H|<.link href={@href} class={@class}><.piece piece={@inner} parts={@parts} /></.link>|
  end

  defp piece(%{piece: {:term, word, standard}} = assigns) do
    assigns = assign(assigns, word: word, standard: standard)
    ~H|<CoreComponents.term word={@word} standard={@standard} class="q-tip-wide" />|
  end

  defp piece(%{piece: {:part, name}} = assigns) do
    assigns = assign(assigns, :slot, Enum.filter(assigns.parts, &(&1.name == name)))
    ~H|{render_slot(@slot)}|
  end

  # A binary, a number, a rendered component or safe HTML: interpolated, so escaped
  # unless it is already HTML.
  defp piece(assigns), do: ~H|{@piece}|
end
