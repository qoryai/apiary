defmodule ApiaryPro.Mix.Tasks.Docs.AllTest do
  # The edition's feature in the build of the documentation (`Mix.Tasks.Docs.All`,
  # the core's `Mix.Tasks.Docs.AllTest`): the trees its documentation adds, and a passage
  # that names it beside a feature of the core's.
  use ExUnit.Case, async: true

  alias Mix.Tasks.Docs.All

  test "a second feature with documentation adds the trees it needs, and no more" do
    trees = All.trees([[:security], [:managed_organisations]])

    assert Enum.sort(trees) ==
             Enum.sort([
               [:observability],
               [:observability, :security],
               [:observability, :managed_organisations],
               [:observability, :security, :managed_organisations]
             ])
  end

  test "a passage that names security and managed_organisations needs both" do
    segments =
      All.split!(
        """
        Before.

          <!-- feature: security, managed_organisations -->
          Both.
          <!-- /feature -->
        After.
        """,
        "g.md"
      )

    refute All.join(segments, [:observability, :security]) =~ "Both."
    assert All.join(segments, Apiary.Features.all()) =~ "  Both."
  end
end
