defmodule ApiaryWeb.Access do
  @moduledoc """
  The web side of `Apiary.Access` for a page: `on_mount({ApiaryWeb.Access, action})` lets
  the page mount only for a reader who may take `action` on the workspace of the page's
  path, and answers as a path that does not exist otherwise (`ApiaryWeb.NotFound`), as a
  slug the reader cannot see does. The page's own links and buttons ask
  `Apiary.Access.can?/3` with the same actions.

  It follows the path scope's hook, which has loaded the organisation and the workspace,
  and `ApiaryWeb.Features`'s gate, which has already answered for a feature that is off.

  Today every member may read what the pages ask, so no signed-in reader of a workspace is
  refused here, nor by the run page's terminal tab (`run.read_log`), the access keys
  page's refusal of a key action, or the log endpoint's refusal. Their end-to-end tests
  land with the first role that is refused one of these; until then the hook is tested
  on its own, and the answers in `Apiary.Access`'s table.
  """

  @doc false
  def on_mount(action, _params, _session, socket) do
    scope = socket.assigns.current_scope

    if Apiary.Access.can?(scope, action, scope.workspace),
      do: {:cont, socket},
      else: raise(ApiaryWeb.NotFound)
  end
end
