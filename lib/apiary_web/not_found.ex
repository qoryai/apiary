defmodule ApiaryWeb.NotFound do
  @moduledoc """
  NotFound is raised by a page whose organisation or workspace, named in its path, the
  caller cannot see, and is rendered as the `404` of a path that does not exist. Not
  *forbidden*: a slug does not tell whether it exists.

  With `page`, a page under an organisation the caller reaches, the `404` is that page
  inside the app's layout (`ApiaryWeb.DeadEnd`), such as `:new_workspace`, which New
  workspace raises for a person who may not create one.
  """
  defexception message: "not found", plug_status: 404, page: nil
end
