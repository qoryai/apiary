defmodule ApiaryWeb.RunLive.ShortcutsPopoverCssTest do
  @moduledoc """
  The layout of the shortcuts popover on a run's Timeline tab and of the policy page's list
  of keys, read from `app.css` and the pages. The popover is a `div` of class `q-keys` with
  a heading above a `dl` of keys, in the lane row. The policy page's list of keys is a `dl`
  of class `q-keylist`, a grid of two columns with no box.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures

  alias Mix.Tasks.Apiary.Demo

  @css Path.expand("../../../../assets/css/app.css", __DIR__)

  # Every rule without a nested block, also inside a media query: its selectors, split at
  # the top-level commas, and its declarations, with the comments removed.
  defp rules do
    @css
    |> File.read!()
    |> String.replace(~r{/\*.*?\*/}s, "")
    |> then(&Regex.scan(~r/([^{}]+)\{([^{}]*)\}/, &1, capture: :all_but_first))
    |> Enum.map(fn [selectors, body] ->
      {selectors |> String.split(~r/,(?![^(]*\))/) |> Enum.map(&String.trim/1), body}
    end)
  end

  # The part of a selector after its last combinator: the element the rule styles.
  defp subject(selector) do
    [_, last] = Regex.run(~r/(?:^|[\s>+~])([^\s>+~]+)$/, selector)
    last
  end

  # A subject that can match the element of this class.
  defp styles?(selector, class) do
    subject(selector) =~ ~r/\.#{class}(?![\w-])/
  end

  defp popover?(selector), do: styles?(selector, "q-keys")

  # Declarations that draw a box or size one: border and radius, background, shadow,
  # outline, padding, margin, width and max-width.
  defp box?(body) do
    body =~
      ~r/(^|[\s;])(border|background|box-shadow|outline|padding|margin|max-width|width)[\w-]*\s*:/
  end

  # The declarations of every rule with exactly this selector, one after another.
  defp declarations(selector) do
    case for {selectors, body} <- rules(), selector in selectors, do: body do
      [] -> flunk("expected a rule for #{selector}, found none")
      bodies -> Enum.join(bodies, "\n")
    end
  end

  test "popover?/1 counts every selector that can match the popover div" do
    assert popover?(".q-keys")
    assert popover?("div.q-keys")
    assert popover?(".dropdown > .q-keys")
    assert popover?(".dropdown-content.q-keys:focus")
    refute popover?(".q-keys dl")
    refute popover?(".q-keys-x")
    refute popover?(".q-keylist")
  end

  test "the popover is never a grid, so its heading and its list of keys stack" do
    bodies = for {selectors, body} <- rules(), Enum.any?(selectors, &popover?/1), do: body

    assert bodies != []

    for body <- bodies,
        do: refute(body =~ ~r/display:\s*(grid|inline-grid|flex|inline-flex)/, body)
  end

  test "the policy page's list of keys is a grid with no box" do
    list = declarations(".q-keylist")
    assert list =~ "display: grid;"
    assert list =~ "grid-template-columns: auto minmax(0, 1fr);"

    bodies =
      for {selectors, body} <- rules(),
          Enum.any?(selectors, &styles?(&1, "q-keylist")),
          do: body

    assert bodies != []
    for body <- bodies, do: refute(box?(body), body)
  end

  test "box?/1 counts every declaration that draws or sizes a box" do
    for declaration <- [
          "border: 1px solid;",
          "border-radius: 10px;",
          "background-color: white;",
          "box-shadow: none;",
          "outline: 1px solid;",
          "padding: 12px 14px;",
          "margin-top: 6px;",
          "width: 17rem;",
          "max-width: 26rem;"
        ],
        do: assert(box?(declaration), declaration)

    for declaration <- ["gap: 8px 14px;", "color: red;", "white-space: nowrap;"],
        do: refute(box?(declaration), declaration)
  end

  test "each key and its description share a line, inside the popover" do
    box = declarations(".dropdown > .q-keys")
    assert box =~ "width: max-content;"
    assert box =~ ~r/max-width: min\(\d+rem, calc\(100vw - \d+rem\)\);/

    list = declarations(".q-keys dl")
    assert list =~ "display: grid;"
    assert list =~ "grid-template-columns: auto minmax(0, 1fr);"

    assert declarations(".q-keys dt") =~ "white-space: nowrap;"
  end

  # The page of a run replayed from the demo recording with subagents, so its Timeline tab
  # has the lane row and the popover.
  defp run_page(conn, scope) do
    %{access_key: access_key} = access_key_fixture(scope)

    file =
      Enum.find(
        Demo.files(),
        &(&1 |> Path.dirname() |> Path.basename() == "session-with-subagents")
      )

    {:ok, run} = Demo.replay(access_key, file)

    {:ok, lv, _html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

    lv
  end

  describe "the popover's right edge is the lane row's right edge" do
    setup :register_and_log_in_user

    test "wherever the lane row wraps the ? button", %{conn: conn, scope: scope} do
      # The row wraps, so the button can sit near the left of the screen. The popover is
      # placed from the row, not from the button, and so stays on the screen.
      assert declarations(".q-tl-bar") =~ "position: relative;"
      assert declarations(".q-tl-bar > .dropdown") =~ "position: static;"

      lv = run_page(conn, scope)

      # `dropdown-end` puts the popover's right edge at its containing block's right edge:
      # the lane row, its nearest positioned ancestor.
      assert has_element?(lv, ".q-tl-bar > .dropdown.dropdown-end > .q-keys[role='note']")
    end
  end

  describe "the popover and the policy page's list of keys have separate classes" do
    setup :register_and_log_in_user

    test "the popover is a div of class q-keys, and the run page has no q-keylist", %{
      conn: conn,
      scope: scope
    } do
      lv = run_page(conn, scope)

      assert has_element?(lv, "div.dropdown-content.q-keys > dl")
      refute has_element?(lv, ".q-keylist")
    end

    # The policy page: left out of a run without the security feature.
    @tag needs: :security
    test "the policy page's list is a dl of class q-keylist, without q-keys", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/policy")

      assert has_element?(lv, "section#policy-keys > dl.q-keylist", "This list")
      refute has_element?(lv, "#policy-page .q-keys")
    end
  end
end
