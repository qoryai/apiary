# The storybook (storybook/, phoenix_storybook) is compiled in this checkout only: an edition
# that runs these tests (its test_paths) has neither, so the test is defined here alone.
if Mix.Project.config()[:app] == :apiary do
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

      for path <- ~w(foundations/icons core/button lists/list_pattern lists/row_confirm
                     policy/rule_mark policy/rule_line policy/rule_list screens/shell
                     screens/settings screens/integrations screens/integration
                     screens/add_integration screens/run_setup screens/nodes screens/node
                     page/page_header page/page_tabs page/settings_page page/page_form
                     page/not_on_runs),
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
        for tab <- tabs(story), theme <- @themes do
          html =
            %{__changed__: %{}, tab: tab, theme: theme} |> story.render() |> rendered_to_string()

          assert html =~ ~r/\S/, "#{path} renders nothing"
        end
      end
    end

    test "every link between the screen mock-ups leads to a story and a tab it has" do
      stories = Map.new(stories())

      for {"screens/" <> _ = path, story} <- stories,
          tab <- tabs(story),
          theme <- @themes do
        html =
          %{__changed__: %{}, tab: tab, theme: theme} |> story.render() |> rendered_to_string()

        links = Regex.scan(~r{href="/dev/storybook/([^"?]+)(?:\?([^"]*))?"}, html)
        assert links != [], "#{path}, #{tab} links to no other screen"

        for [_link, to | query] <- links do
          params = query |> List.first("") |> String.replace("&amp;", "&") |> URI.decode_query()
          assert {:ok, target} = Map.fetch(stories, to), "#{path}, #{tab} links to #{to}"

          assert is_nil(params["tab"]) or params["tab"] in Enum.map(tabs(target), &to_string/1),
                 "#{path}, #{tab} links to #{to}, tab #{params["tab"]}"

          assert params["theme"] == to_string(theme), "#{path}, #{tab} drops the theme"
        end
      end
    end

    defp tabs(story) do
      case story.navigation() do
        [] -> [nil]
        navigation -> Enum.map(navigation, &elem(&1, 0))
      end
    end

    test "the Icons story draws the outline split beside the solid micro of before" do
      {_path, story} = Enum.find(stories(), &(elem(&1, 0) == "foundations/icons"))
      html = %{__changed__: %{}, tab: nil, theme: :qory} |> story.render() |> rendered_to_string()

      # Current: the nav as the shell draws it, 24 px outline at 18 px, glyphs micro.
      # Previous: every icon solid micro at 16 px.
      assert html =~ ~r/hero-squares-2x2 [^"]*size-\[18px\]/
      assert html =~ ~r/hero-squares-2x2-micro[^"]*size-4/
      assert html =~ "hero-magnifying-glass "
      assert html =~ "hero-no-symbol-micro"
      assert html =~ "hero-lock-closed-micro"
    end
  end
end
