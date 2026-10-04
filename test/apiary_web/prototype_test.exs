# The navigation prototype (storybook/prototype/) is compiled in this checkout only, as the
# storybook is: an edition that runs these tests has neither.
if Mix.Project.config()[:app] == :apiary do
  defmodule ApiaryWeb.PrototypeTest do
    # Every page and dialog of the navigation prototype renders for an owner, an admin and
    # a member, and every link it draws into the prototype leads to a page it has.
    use ExUnit.Case, async: true

    import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

    alias ApiaryWeb.Prototype
    alias ApiaryWeb.Prototype.Live

    @roles [:owner, :admin, :member]

    defp render(path, role) do
      assigns =
        path
        |> Live.at(role)
        |> Map.merge(%{__changed__: nil, flash: %{}, approved: MapSet.new()})

      assigns |> Live.render() |> rendered_to_string()
    end

    defp links(html) do
      ~r{href="(/dev/prototype[^"]*)"}
      |> Regex.scan(html, capture: :all_but_first)
      |> Enum.map(fn [href] -> String.replace(href, "&amp;", "&") end)
      |> Enum.uniq()
    end

    defp resolves?(href) do
      %URI{path: "/dev/prototype" <> rest, query: query} = URI.parse(href)
      params = if query, do: URI.decode_query(query), else: %{}
      Prototype.page(String.split(rest, "/", trim: true), params) != :not_found
    end

    test "every page renders for each role, and every link leads to a page" do
      for path <- Prototype.paths(), role <- @roles do
        html = render(path, role)
        refute html =~ "This page is not in the prototype", "#{path} as #{role} is not a page"

        for href <- links(html),
            do: assert(resolves?(href), "#{path} as #{role} links to #{href}, not a page")
      end
    end

    test "every page the prototype links to is among its pages" do
      reached =
        for path <- Prototype.paths(),
            role <- @roles,
            href <- links(render(path, role)),
            into: MapSet.new(),
            do: href |> URI.parse() |> Map.get(:path)

      listed = MapSet.new(Prototype.paths(), &(&1 |> URI.parse() |> Map.get(:path)))
      assert MapSet.subset?(reached, listed), inspect(MapSet.difference(reached, listed))
    end

    test "the pages name no edition and keep to the domain's words" do
      for path <- Prototype.paths() do
        text = path |> render(:admin) |> String.downcase()

        for word <- ["edition", "vault", "director", "llm", "scratchpad"],
            do: refute(text =~ word, "#{path} says #{word}")
      end
    end
  end
end
