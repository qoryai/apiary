defmodule ApiaryWeb.WorkItemLive.Show do
  # One work item, by its number in the workspace: its ticket and its thread (`:ticket`,
  # `:thread`).
  #
  # It answers as a path that does not exist until its page is built here. The feature is
  # hidden from the documentation, so the module is too.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory

  @impl true
  def mount(_params, _session, _socket), do: raise(ApiaryWeb.NotFound)

  @impl true
  def render(assigns), do: ~H""

  ## People's comments on the Thread (`ApiaryWeb.WorkItemLive.Comments`)
  #
  # The page keeps `:work_item` and `:current_scope`, puts the comments' assigns at mount
  # (`Comments.mount/1`), reads `Apiary.WorkItems.thread/3` and
  # `Apiary.WorkItems.count_comments/2` again when it hears its work item changed, keeping
  # `:deleting_comment` through `Comments.still_asking/2`, and draws each comment of the
  # Thread with `Comments.comment_line/1` and the composer with `Comments.composer/1`.

  @comment_events ApiaryWeb.WorkItemLive.Comments.events()

  @impl true
  def handle_event(event, params, socket) when event in @comment_events,
    do: ApiaryWeb.WorkItemLive.Comments.handle_event(event, params, socket)
end
