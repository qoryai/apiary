defmodule Mix.Tasks.Docs.AllTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Docs.All

  doctest All

  describe "trees/1" do
    test "nothing that needs a feature is one tree" do
      assert All.trees([]) == [[:observability]]
    end

    # Security's tree is a separate one: every feature the documentation differs by is
    # more, the core's opt-in `secrets` among them.
    test "security's documentation and the module reference are a tree each" do
      every = Apiary.Features.documented()

      assert All.trees([[:security], every]) ==
               Enum.uniq([[:observability], [:observability, :security], every])
    end

    # A feature listed with `docs: false` is in no tree and names none, so the trees are
    # the same as without it.
    test "a feature the documentation does not differ by is in no tree" do
      every = Apiary.Features.documented()
      assert every != Apiary.Features.all()

      for needs <- [[], [[:security]], [[:security], every]] do
        trees = All.trees(needs)
        assert Enum.all?(List.flatten(trees), &(&1 in every)), inspect(needs)
      end

      assert All.trees([[:security], every]) |> Enum.map(&ApiaryWeb.DocsController.tree_name/1) ==
               Enum.uniq(["observability", "observability+security", "all"])
    end
  end

  describe "split!/2 and join/2" do
    @guide """
    Before.

    <!-- feature: security -->
    About the policy.
    <!-- /feature -->

    After.
    """

    test "a tree with the feature keeps the passage, without the marker lines" do
      text = @guide |> All.split!("g.md") |> All.join([:observability, :security])
      assert text == "Before.\n\nAbout the policy.\n\nAfter.\n"
    end

    test "a tree without it leaves the passage out" do
      text = @guide |> All.split!("g.md") |> All.join([:observability])
      assert text == "Before.\n\n\nAfter.\n"
    end

    test "a passage that names two features needs both" do
      segments =
        All.split!(
          "  <!-- feature: observability, security -->\n  Both.\n  <!-- /feature -->\n",
          "g.md"
        )

      assert All.join(segments, [:observability, :security]) =~ "  Both."
      refute All.join(segments, [:observability]) =~ "Both."
      refute All.join(segments, [:security]) =~ "Both."
    end

    test "a text without markers is unchanged" do
      assert "a\n\nb\n" |> All.split!("g.md") |> All.join([:observability]) == "a\n\nb\n"
    end

    test "a marker that is not closed, nested or unknown stops the build, naming the line" do
      assert_raise Mix.Error, "g.md:2: a feature marker never closed", fn ->
        All.split!("a\n<!-- feature: security -->\nb\n", "g.md")
      end

      assert_raise Mix.Error, "g.md:2: a feature marker inside another", fn ->
        All.split!(
          "<!-- feature: security -->\n<!-- feature: observability -->\n",
          "g.md"
        )
      end

      assert_raise Mix.Error, "g.md:1: <!-- /feature --> without a marker to close", fn ->
        All.split!("<!-- /feature -->\n", "g.md")
      end

      assert_raise Mix.Error,
                   ~s(g.md:1: "secruity" is not a feature the documentation differs by),
                   fn ->
                     All.split!("<!-- feature: secruity -->\n<!-- /feature -->\n", "g.md")
                   end

      # A feature listed with `docs: false` marks no passage.
      [undocumented | _] = Apiary.Features.all() -- Apiary.Features.documented()

      assert_raise Mix.Error,
                   ~s(g.md:1: "#{undocumented}" is not a feature the documentation differs by),
                   fn ->
                     All.split!("<!-- feature: #{undocumented} -->\n<!-- /feature -->\n", "g.md")
                   end
    end
  end
end
