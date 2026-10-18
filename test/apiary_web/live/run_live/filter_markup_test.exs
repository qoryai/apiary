defmodule ApiaryWeb.RunLive.FilterMarkupTest do
  # The Runs page's Filter menu sections, which `ApiaryWeb.RunComponents.filter_options/1`
  # draws, render the markup they rendered before the Backlog gave that component an
  # optional tile: test/fixtures/markup/runs_filter_sections.html holds the sections'
  # HTML as it was, for a workspace with two runs, a target's id as `tg_ID`, and since
  # then with an option's words in `<bdi>`, as a host or a name may be a text an
  # external system sent. A caller that passes no tile gets no other new element,
  # attribute or text.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.RunListFixtures

  setup :register_and_log_in_user

  @sections ~w(target state runtime host node since)
  @before Path.expand("../../../fixtures/markup/runs_filter_sections.html", __DIR__)

  test "the Filter menu's sections render as they did before the tile", %{
    conn: conn,
    scope: scope
  } do
    started_run(scope, shop(),
      about: %{"title" => "fix-cart"},
      ago: 300,
      host: "build-02",
      egress: [%{"decision" => "denied", "rule" => ""}],
      exit: %{"state" => "failed", "exit_code" => 1}
    )

    started_run(scope, shop("gitlab.example"), about: %{"title" => "mirror-sync"}, ago: 100)

    {:ok, view, _html} = live(conn, workspace_path(scope, "/runs"))
    render_async(view)
    document = view |> render() |> LazyHTML.from_fragment()

    rendered =
      Enum.map_join(@sections, fn key ->
        document
        |> LazyHTML.query("#runs-filter-section-#{key}")
        |> LazyHTML.to_html()
        |> Kernel.<>("\n")
      end)

    # Every section is there, with its options.
    for key <- @sections, do: assert(rendered =~ ~s(id="runs-filter-section-#{key}"))
    assert rendered =~ "build-02"

    assert Regex.replace(~r/tg_[0-9a-z]{16}/, rendered, "tg_ID") == File.read!(@before)
  end
end
