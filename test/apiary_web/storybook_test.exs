defmodule ApiaryWeb.StorybookTest do
  # The component storybook (docs/ui.md, Storybook) draws the real components with sample
  # data: a component that changes under a story would break it unseen, since no page
  # renders the story. This renders every variation of every story, and its code as the
  # storybook shows it, so that a story that raises fails here.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixStorybook.Rendering.{CodeRenderer, ComponentRenderer, RenderingContext}

  @backend ApiaryWeb.Storybook
  @themes [:qory, :"qory-dark"]

  defp stories do
    for entry <- @backend.leaves() do
      path = String.trim_leading(entry.path, "/")
      assert {:ok, story} = @backend.load_story(path), "#{path} does not load"
      {path, story}
    end
  end

  test "the storybook holds the stories" do
    paths = Enum.map(stories(), &elem(&1, 0))

    for path <- ~w(foundations/icons core/button lists/list_pattern policy/rule_mark
                   policy/rule_line policy/rule_list),
        do: assert(path in paths, "#{path} is not in the storybook")
  end

  test "every variation of every component story renders, and its code" do
    for {path, story} <- stories(), story.storybook_type() == :component do
      assert story.variations() != [], "#{path} has no variation"

      for variation <- story.variations() do
        context = RenderingContext.build(@backend, story, variation, %{})
        html = context |> ComponentRenderer.render() |> rendered_to_string()
        assert html =~ ~r/\S/, "#{path}, #{variation.id} renders nothing"
        assert context |> CodeRenderer.render() |> rendered_to_string() =~ ~r/\S/
      end
    end
  end

  test "every page story renders, in each theme and on each tab" do
    for {path, story} <- stories(), story.storybook_type() == :page do
      tabs =
        case story.navigation() do
          [] -> [nil]
          navigation -> Enum.map(navigation, &elem(&1, 0))
        end

      for tab <- tabs, theme <- @themes do
        html =
          %{__changed__: %{}, tab: tab, theme: theme} |> story.render() |> rendered_to_string()

        assert html =~ ~r/\S/, "#{path} renders nothing"
      end
    end
  end

  test "the Icons story draws the solid and the outline split" do
    {_path, story} = Enum.find(stories(), &(elem(&1, 0) == "foundations/icons"))
    html = %{__changed__: %{}, tab: nil, theme: :qory} |> story.render() |> rendered_to_string()

    # Solid: the nav as the shell draws it. Outline: 24 px outline at 18 px, glyphs micro.
    assert html =~ ~r/hero-squares-2x2-micro[^"]*size-4/

    assert html =~ ~r/hero-squares-2x2 [^"]*size-\[18px\]/
    assert html =~ "hero-magnifying-glass "
    assert html =~ "hero-no-symbol-micro"
    assert html =~ "hero-lock-closed-micro"
  end
end
