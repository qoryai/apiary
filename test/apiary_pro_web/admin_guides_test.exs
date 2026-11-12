defmodule ApiaryProWeb.AdminGuidesTest do
  @moduledoc """
  The guides only instance admins read at `/docs/admin` (`ApiaryWeb.DocsController.admin_guides/0`):
  The edition adds the Instance admins guide, `admin.md`, to the core's `install.md` and
  `hosting-checklist.md`.
  """
  use ExUnit.Case, async: true

  test "the Instance admins guide is served to instance admins only" do
    guides = ApiaryWeb.DocsController.admin_guides()

    assert "admin.md" in guides
    assert "install.md" in guides
    assert "hosting-checklist.md" in guides
    assert ApiaryProWeb.Edition.admin_guides() == ["admin.md"]
  end
end
