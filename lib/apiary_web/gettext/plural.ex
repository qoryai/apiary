defmodule ApiaryWeb.Gettext.Plural do
  @moduledoc """
  Plural forms for locales that carry a domain, such as `en@software`.

  A domain is a locale variant in GNU's `language@modifier` form (see `ApiaryWeb.Lingo`).
  `Gettext.Plural` knows languages and `language_TERRITORY` pairs but not a modifier, so
  it would raise for `en@software`. The plural rules are the language's, whatever the
  domain, so this module drops the modifier and asks `Gettext.Plural`. A catalogue's own
  `Plural-Forms` header still wins, as it does there.
  """

  @behaviour Gettext.Plural

  @impl true
  def init(%{locale: locale} = context),
    do: Gettext.Plural.init(%{context | locale: language(locale)})

  @impl true
  def nplurals(plural_info), do: Gettext.Plural.nplurals(plural_info)

  @impl true
  def plural(plural_info, count), do: Gettext.Plural.plural(plural_info, count)

  @impl true
  def plural_forms_header(locale), do: Gettext.Plural.plural_forms_header(language(locale))

  defp language(locale), do: locale |> String.split("@", parts: 2) |> hd()
end
