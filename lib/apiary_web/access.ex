defmodule ApiaryWeb.Access do
  @moduledoc """
  The web side of `Apiary.Access` for a page: `on_mount({ApiaryWeb.Access, action})` lets
  the page mount only for a reader who may take `action` on the workspace of the page's
  path, or on the organisation for an organisation's page without one, and answers as a
  path that does not exist otherwise (`ApiaryWeb.NotFound`), as a slug the reader cannot
  see does. The page's own links and buttons ask `Apiary.Access.can?/3` with the same
  actions.

  It follows the path scope's hook, which has loaded the organisation and the workspace,
  and `ApiaryWeb.Features`'s gate, which has already answered for a feature that is off.

  The organisation's Activity page (`audit.read`) is the one page of the core's a member
  is refused here, and its test shows it; an edition's page is refused the same way for
  the action it asks. Every member may read what the other pages ask, so no signed-in
  reader of a workspace is refused by them, nor by the run page's terminal tab
  (`run.read_log`) or the log endpoint's refusal. Their end-to-end tests land with the
  first role that is refused one of these; until then the answers are in
  `Apiary.Access`'s table.

  A reader (`Apiary.Access.reader/1`), who reads the organisation through the edition's
  reach with no membership there, in a role that holds no change, reads everything and
  changes nothing: a page that refuses them a change says so with `reads_only/1`, rather
  than the level it would take. One the edition lets in with a role that changes
  something is told what a refusal says to anyone else.

  A page that refuses anyone else a change, or offers them no way to make it, says who may
  with `who_may/3`: the core's sentence names the levels that may, and the edition may
  say it in its own words.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  @doc """
  reads_only/1 is the sentence a page says to the reader of `scope`
  (`Apiary.Access.reader/1`) when it refuses them a change: the edition's words for how
  they read it (`c:ApiaryWeb.Edition.reader_sentence/2`), or that they read it and change
  nothing.
  """
  @spec reads_only(Apiary.Accounts.Scope.t()) :: String.t()
  def reads_only(scope) do
    ApiaryWeb.Edition.reader_sentence(:refused, scope) ||
      gettext("You can read this organisation, and change nothing here.")
  end

  @doc """
  who_may/3 is the sentence a page says to a person of `scope` who is refused an action
  or offered no way to take it, of who may take it: the edition's words
  (`c:ApiaryWeb.Edition.who_may_sentence/2`), or `default`, the core's, which names the
  levels that may, such as "Only owners and admins add nodes.". `about` is the action, or
  the page's subject the edition's callback names.
  """
  @spec who_may(Apiary.Accounts.Scope.t(), atom, String.t()) :: String.t()
  def who_may(scope, about, default), do: who_may(ApiaryWeb.Edition, scope, about, default)

  @doc false
  # The same, asked of `edition`, a module of `ApiaryWeb.Edition`'s callbacks: the
  # configured edition, or a test's.
  @spec who_may(module, Apiary.Accounts.Scope.t(), atom, String.t()) :: String.t()
  def who_may(edition, scope, about, default) when is_atom(about) and is_binary(default),
    do: edition.who_may_sentence(about, scope) || default

  @doc false
  def on_mount(action, _params, _session, socket) do
    scope = socket.assigns.current_scope

    if Apiary.Access.can?(scope, action, scope.workspace || scope.organisation),
      do: {:cont, socket},
      else: raise(ApiaryWeb.NotFound)
  end
end
