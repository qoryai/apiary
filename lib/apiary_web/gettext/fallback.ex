defmodule ApiaryWeb.Gettext.Fallback do
  @moduledoc """
  The fallback chain of a Gettext backend: a message a locale's catalogue lacks is looked
  up in the next locale of `chain/1`, and only the last one falls back to the source text.

  A domain's catalogue (`de@software`) holds only the sentences it says in its own words;
  every other sentence is the language's and lives once in the language's catalogue
  (`de`), shared by every domain. So `de@software` falls back to `de`, and
  `de_AT@software` to `de_AT`, then `de`. English needs no language catalogue: its source
  text is already English, and `en@software` translates every sentence with an engine word
  (`ApiaryWeb.LingoCatalogueTest`), so none of them reaches the page in engine words.

  `use ApiaryWeb.Gettext.Fallback` after `use Gettext.Backend` overrides the backend's
  `handle_missing_translation/5` and `handle_missing_plural_translation/7`.
  """

  @doc """
  The locales a message is looked up in after `locale`, nearest first: the locale without
  its `@modifier`, then without its territory.

      iex> ApiaryWeb.Gettext.Fallback.chain("de_AT@software")
      ["de_AT", "de"]

      iex> ApiaryWeb.Gettext.Fallback.chain("de@software")
      ["de"]

      iex> ApiaryWeb.Gettext.Fallback.chain("de")
      []
  """
  @spec chain(String.t()) :: [String.t()]
  def chain(locale) do
    language = locale |> String.split("@", parts: 2) |> hd()
    bare = language |> String.split("_", parts: 2) |> hd()
    Enum.uniq([language, bare]) -- [locale]
  end

  @doc "The next locale to look a message up in after `locale`, or `nil` at the end."
  @spec next(String.t()) :: String.t() | nil
  def next(locale), do: locale |> chain() |> List.first()

  defmacro __using__(_opts) do
    quote do
      @impl Gettext.Backend
      def handle_missing_translation(locale, domain, msgctxt, msgid, bindings) do
        case ApiaryWeb.Gettext.Fallback.next(locale) do
          nil -> super(locale, domain, msgctxt, msgid, bindings)
          next -> lgettext(next, domain, msgctxt, msgid, bindings)
        end
      end

      @impl Gettext.Backend
      def handle_missing_plural_translation(locale, domain, msgctxt, msgid, plural, n, bindings) do
        case ApiaryWeb.Gettext.Fallback.next(locale) do
          nil -> super(locale, domain, msgctxt, msgid, plural, n, bindings)
          next -> lngettext(next, domain, msgctxt, msgid, plural, n, bindings)
        end
      end
    end
  end
end
