defmodule ApiaryWeb.NotFound do
  @moduledoc """
  NotFound is raised by a page whose organisation or workspace, named in its path, the
  caller cannot see, and is rendered as the `404` of a path that does not exist. Not
  *forbidden*: a slug does not tell whether it exists (decisions 0070 and 0073).
  """
  defexception message: "not found", plug_status: 404
end
