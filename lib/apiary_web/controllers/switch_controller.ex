defmodule ApiaryWeb.SwitchController do
  @moduledoc """
  Where the switcher's link to a workspace leads (`ApiaryWeb.Layouts`): the section the
  reader was on, in the workspace of the path, where they may open it there, else that
  workspace's overview. Not a page: a redirect.

      GET /:org/:workspace/switch/:section

  The switcher keeps the reader's section, but a section of a feature may be absent in
  another organisation or workspace, and only the destination's scope knows: the pipeline
  resolves it for a member and answers `404` for anybody else, and
  `ApiaryWeb.Layouts.switch_target/2` asks it.
  """
  use ApiaryWeb, :controller

  def show(conn, %{"section" => section}) do
    redirect(conn, to: ApiaryWeb.Layouts.switch_target(conn.assigns.current_scope, section))
  end
end
