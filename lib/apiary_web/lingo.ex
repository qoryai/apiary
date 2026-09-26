defmodule ApiaryWeb.Lingo do
  @moduledoc """
  The words a page is written in: the domain's, never the engine's.

  The engine speaks of targets, systems, change requests and applying them; a domain names
  them for one kind of work. Every visible sentence goes through Gettext with its
  source text in engine words, and a domain is a Gettext locale in GNU's
  `language@modifier` form: `en@software` is English in the software domain's words
  (repository, forge, pull request, merge, workspace). A later `de@software` would be
  German for the same domain: it holds only the sentences in the domain's words and falls
  back to the language's catalogue, `de`, for the rest (`ApiaryWeb.Gettext.Fallback`).
  `docs/lingo.md` has the conventions.

  The locale is built from two things, kept apart: the **language** is the person's
  preference (`Apiary.Accounts.Preferences`), the **domain** the workspace's
  (`Apiary.Lingo.Domain.for_workspace/1`). `locale_for/1` puts them together as
  `language@domain`:

  - a scope with a workspace: the user's language and the workspace's domain. Every page
    of a signed-in member has one, the user's own settings included: the scope carries
    the current workspace (`ApiaryWeb.UserAuth`'s `:load_organisation`);
  - a scope without a workspace (a user with no membership, on `/users/organisations`): the
    user's language and the default domain;
  - no user (log-in, registration): the default locale, `en@software`;
  - a language without a catalogue any more (`Apiary.Accounts.Preferences.languages/0`)
    reads English. A known language without a catalogue for the domain, such as
    `de@software`, is looked up down the chain (`de`, then the source text).

  This module sets the locale for a request (as a plug, after the scope is fetched) and
  for a LiveView (as an `on_mount` hook, which every LiveView runs after its
  `live_session` hooks have loaded the scope). The default locale of `ApiaryWeb.Gettext`
  is the same default, so a render outside both, such as an error page, never falls back
  to the engine's English. A mail is rendered for its recipient: `with_locale/3` takes
  the recipient's language and the domain of the workspace the mail is about.
  """

  @behaviour Plug

  alias Apiary.Accounts.{Preferences, Scope, User}
  alias Apiary.Lingo.Domain
  alias ApiaryWeb.Format
  alias Apiary.Organisations.Workspace

  @default_locale "en@software"

  @doc "The default locale: English, in the default domain's words."
  @spec default_locale() :: String.t()
  def default_locale, do: @default_locale

  @doc """
  The locale a scope's pages are rendered in: its user's language, in the words of its
  workspace's domain, or of the default domain outside a workspace.

      iex> ApiaryWeb.Lingo.locale_for(nil)
      "en@software"
  """
  @spec locale_for(Scope.t() | nil) :: String.t()
  def locale_for(scope), do: locale(Scope.language(scope), scope)

  @doc """
  The locale of a render for `recipient` about `scope`: the recipient's language, in the
  words of the scope's workspace's domain (the default domain without one). A mail is
  rendered for the person who reads it, whoever sends it.
  """
  @spec locale_for(Scope.t() | nil, %User{}) :: String.t()
  def locale_for(scope, %User{} = recipient),
    do: locale(Scope.language(Scope.for_user(recipient)), scope)

  # A language without a catalogue any more reads English, in the scope's domain.
  defp locale(language, scope) do
    language = if Preferences.language?(language), do: language, else: default_language()
    language <> "@" <> domain_of(scope).name()
  end

  defp domain_of(%Scope{workspace: %Workspace{} = workspace}),
    do: Domain.for_workspace(workspace)

  defp domain_of(_scope), do: Domain.default()

  defp default_language, do: Preferences.default_language()

  @doc """
  Sets the scope's locale, and its person's time zone for `ApiaryWeb.Format`, for the
  calling process; returns the locale.
  """
  @spec put_locale(Scope.t() | nil) :: String.t()
  def put_locale(scope) do
    locale = locale_for(scope)
    Gettext.put_locale(ApiaryWeb.Gettext, locale)
    Format.put_time_zone(Scope.time_zone(scope))
    locale
  end

  @doc """
  Runs `fun` in the scope's locale and its person's time zone, and restores the previous
  ones: for a render outside a request or a LiveView, such as a task started from a
  LiveView.
  """
  @spec with_locale(Scope.t() | nil, (-> result)) :: result when result: term
  def with_locale(scope, fun) when is_function(fun, 0) do
    Format.with_time_zone(Scope.time_zone(scope), fn ->
      Gettext.with_locale(ApiaryWeb.Gettext, locale_for(scope), fun)
    end)
  end

  @doc """
  Runs `fun` in the locale of a render for `recipient` about `scope` (`locale_for/2`) and
  in the recipient's time zone, and restores the previous ones: for a mail, in whatever
  process sends it. `scope` is nil for a mail about no workspace, such as a log-in link.
  """
  @spec with_locale(Scope.t() | nil, %User{}, (-> result)) :: result when result: term
  def with_locale(scope, %User{} = recipient, fun) when is_function(fun, 0) do
    Format.with_time_zone(Scope.time_zone(%Scope{user: recipient}), fn ->
      Gettext.with_locale(ApiaryWeb.Gettext, locale_for(scope, recipient), fun)
    end)
  end

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
