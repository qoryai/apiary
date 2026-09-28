defmodule ApiaryWeb.ReservedSlugsTest do
  @moduledoc """
  The reserved names held to the core's router (`ApiaryWeb.ReservedSlugsCase`). An
  edition's router, the core's routes with its own, is held in the edition's tests.
  """
  use ApiaryWeb.ReservedSlugsCase, async: true, router: ApiaryWeb.Router
end
