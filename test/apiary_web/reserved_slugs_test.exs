defmodule ApiaryWeb.ReservedSlugsTest do
  @moduledoc """
  The reserved names are held to the router: a top-level path the instance serves, or a
  page of an organisation, that `ApiaryWeb.ReservedSlugs` does not name could be taken by
  an organisation or a workspace as its slug, and hide the page or be hidden by it.
  """
  use ExUnit.Case, async: true

  alias ApiaryWeb.ReservedSlugs

  defp segments(path), do: path |> String.split("/", trim: true)

  defp literal?(segment), do: not String.starts_with?(segment, [":", "*"])

  test "every first segment the router, the endpoint and the static files use is reserved" do
    routes = for %{path: path} <- ApiaryWeb.Router.__routes__(), do: segments(path)

    sockets =
      for {path, _module, _opts} <- ApiaryWeb.Endpoint.__sockets__(), do: segments(path)

    # The development routes are compiled only where `:dev_routes` is set, and the static
    # files and the documentation are served before the router.
    first =
      for([first | _] <- routes ++ sockets, literal?(first), do: first) ++
        ApiaryWeb.static_paths() ++ ["dev", "docs"]

    missing = first |> Enum.uniq() |> Enum.reject(&(&1 in ReservedSlugs.organisation()))
    assert missing == [], "reserve these in ApiaryWeb.ReservedSlugs.organisation/0"
  end

  test "every page of an organisation is a reserved workspace slug" do
    pages =
      for %{path: path} <- ApiaryWeb.Router.__routes__(),
          [":org", page | _] <- [segments(path)],
          literal?(page),
          uniq: true,
          do: page

    assert "members" in pages
    assert "settings" in pages

    missing = Enum.reject(pages, &(&1 in ReservedSlugs.workspace()))
    assert missing == [], "reserve these in ApiaryWeb.ReservedSlugs.workspace/0"
  end

  test "the organisation's and the workspace's pages are under their slugs, and nowhere else" do
    workspace_pages =
      for %{path: path} <- ApiaryWeb.Router.__routes__(),
          [first | _] = segments(path) ++ [nil],
          first in [":org"],
          do: path

    assert "/:org/:workspace" in workspace_pages
    assert "/:org/:workspace/runs/:run_id" in workspace_pages
    assert "/:org/:workspace/policy/targets" in workspace_pages
    assert "/:org/members" in workspace_pages
    assert "/:org/settings" in workspace_pages

    for %{path: path} <- ApiaryWeb.Router.__routes__() do
      refute String.starts_with?(path, "/workspace"), path
      refute path in ["/no-workspace", "/organisations/switch"], path
    end
  end

  test "the lists hold no name twice" do
    for list <- [ReservedSlugs.organisation(), ReservedSlugs.workspace()] do
      assert list == Enum.uniq(list)
    end
  end
end
