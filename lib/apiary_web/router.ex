defmodule ApiaryWeb.Router do
  @moduledoc """
  The core's router: the core's routes (`ApiaryWeb.Routes`) and nothing else. It is the
  router the endpoint dispatches to when no edition names its own
  (`ApiaryWeb.Edition.router/0`), and the one the core's `~p` are verified against, since
  every edition's router holds its routes.
  """
  use ApiaryWeb, :router

  import ApiaryWeb.Routes

  pipelines()
  public_routes()
  account_routes()
  visitor_routes()
  organisation_routes()
end
