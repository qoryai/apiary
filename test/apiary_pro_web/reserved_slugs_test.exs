defmodule ApiaryProWeb.ReservedSlugsTest do
  @moduledoc """
  The reserved names held to the edition's router (`ApiaryWeb.ReservedSlugsCase`): the core's
  routes with the edition's pages, whose first segments and organisation pages the core's lists,
  with the edition's, reserve too.
  """
  use ApiaryWeb.ReservedSlugsCase, async: true, router: ApiaryProWeb.Router

  # Beside the core's names, the edition reserves its pages of an organisation, its former paths
  # and other reserved top-level names (`ApiaryProWeb.Edition.reserved_slugs/0`);
  # the core's, such as `admin` and `new`, are not the edition's to list.
  test "the edition's pages, its former paths and the other top-level names are reserved" do
    for name <- ~w(organisations workspace support signup www) do
      assert name in ReservedSlugs.organisation(), name
    end

    for page <- ~w(clients instance policy-requests workspaces policy) do
      assert page in ReservedSlugs.workspace(), page
    end
  end

  # A workspace name is refused only where an organisation-level page has the path.
  test "a name that no page of an organisation has is no reserved workspace name" do
    for name <- ~w(access audit billing grants invitations keys) do
      refute name in ReservedSlugs.workspace(), name
    end
  end
end
