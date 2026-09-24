defmodule ApiaryWeb.Lingo do
  @moduledoc """
  The words a page is written in: the body's, never the engine's.

  The engine speaks of targets, systems, change requests and applying them; a body names
  them for one kind of factory. Every visible sentence goes through Gettext with its
  source text in engine words, and a body is a Gettext locale in GNU's
  `language@modifier` form: `en@software` is English in the software body's words
  (repository, forge, pull request, merge, workplace). A later `de@software` would be
  German for the same body. `docs/lingo.md` has the conventions.

  The body belongs to the hive, so the locale follows the scope: `locale_for/1` answers it
  and this module sets it for a request (as a plug, after the scope is fetched) and for a
  LiveView (as an `on_mount` hook, which every LiveView runs after its `live_session`
  hooks have loaded the scope). Every hive is of the software body today, and a page
  outside a hive (log-in, registration) reads the default body. The default locale of
  `ApiaryWeb.Gettext` is the same one, so a render outside both, such as a mail sent from
  a job or an error page, never falls back to the engine's English.
  """

  @behaviour Plug

  @default_locale "en@software"

  @doc "The locale of the default body, the software body."
  def default_locale, do: @default_locale

  @doc """
  The locale a scope's pages are rendered in: the body of its hive, in its language.

      iex> ApiaryWeb.Lingo.locale_for(nil)
      "en@software"
  """
  def locale_for(_scope), do: @default_locale

  @doc "Sets the scope's locale for the calling process; returns the locale."
  def put_locale(scope) do
    locale = locale_for(scope)
    Gettext.put_locale(ApiaryWeb.Gettext, locale)
    locale
  end

  @doc """
  Runs `fun` in the scope's locale and restores the previous one: for a render outside a
  request or a LiveView, such as a mail sent from a job about a hive.
  """
  def with_locale(scope, fun) when is_function(fun, 0),
    do: Gettext.with_locale(ApiaryWeb.Gettext, locale_for(scope), fun)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    put_locale(conn.assigns[:current_scope])
    conn
  end

  @doc false
  def on_mount(:default, _params, _session, socket) do
    put_locale(socket.assigns[:current_scope])
    {:cont, socket}
  end
end
