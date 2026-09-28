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
  (`run.read_log`), the access keys page's refusal of a key action, or the log endpoint's
  refusal. Their end-to-end tests land with the first role that is refused one of these;
  until then the answers are in `Apiary.Access`'s table.

  A reader (`Apiary.Access.reader/1`), who reads the organisation through the edition's
  reach with no membership there, reads everything and changes nothing: a page that
  refuses them a change says so with `reads_only/1`, rather than the level it would take.
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

  @doc false
  def on_mount(action, _params, _session, socket) do
    scope = socket.assigns.current_scope

    if Apiary.Access.can?(scope, action, scope.workspace || scope.organisation),
      do: {:cont, socket},
      else: raise(ApiaryWeb.NotFound)
  end
end
