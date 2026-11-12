defmodule ApiaryProWeb.Trail do
  @moduledoc """
  The breadcrumb a page shows, as its tests read it: the words of each segment but the
  organisation's switcher, in order. On a page of a level's settings the frame writes the level and the
  section, and the page only what follows them, so a test that reads the whole trail
  finds a segment written twice.
  """

  import Phoenix.LiveViewTest, only: [render: 1]

  @doc """
  crumbs/1 is the words of each segment of the breadcrumb of `page` (its view or its HTML)
  but the organisation's switcher, in order.
  """
  @spec crumbs(struct | String.t()) :: [String.t()]
  def crumbs(page) do
    page
    |> segments()
    |> Enum.reject(&(&1 |> LazyHTML.query("#organisation-menu-button") |> Enum.any?()))
    |> Enum.map(fn segment ->
      segment
      |> LazyHTML.query("a, [aria-current=page]")
      |> Enum.take(1)
      |> Enum.map_join(&LazyHTML.text/1)
      |> words()
    end)
  end

  @doc """
  up/1 is the page's parent that a phone's bar keeps, a link back with its chevron, as
  `{words, href}`; nil where the bar keeps none.
  """
  @spec up(struct | String.t()) :: {String.t(), String.t() | nil} | nil
  def up(page) do
    case page |> segments() |> LazyHTML.filter(".q-trail-up") |> Enum.to_list() do
      [segment] ->
        link = LazyHTML.query(segment, "a:has(.q-trail-back)")
        {link |> LazyHTML.text() |> words(), link |> LazyHTML.attribute("href") |> List.first()}

      [] ->
        nil
    end
  end

  defp segments(%Phoenix.LiveViewTest.View{} = view), do: view |> render() |> segments()

  defp segments(html) when is_binary(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#breadcrumb ol.q-trail > li")
  end

  defp words(text), do: text |> String.split() |> Enum.join(" ")
end
