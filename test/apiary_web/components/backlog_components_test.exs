defmodule ApiaryWeb.BacklogComponentsTest do
  @moduledoc """
  The Backlog's parts (`ApiaryWeb.BacklogComponents`): a ticket's row in each state of its
  work item, who filed it, the integration's tile, the compact time, and one ticket over
  the list and as a page. Every value a ticket holds is escaped, and the texts that wait
  for a later step are not drawn.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias ApiaryWeb.BacklogComponents
  alias ApiaryWeb.Format

  @now ~U[2026-10-16 12:00:00Z]

  defp ago(seconds), do: DateTime.add(@now, -seconds, :second)

  defp ticket(overrides \\ %{}) do
    Map.merge(
      %{
        ref: "acme/shop#1231",
        number: 1231,
        title: "Discount codes are case-sensitive at checkout",
        repository: "acme/shop",
        filer: %{name: "Lea", kind: :person},
        comment_count: 3,
        filed_at: ago(2 * 86_400),
        updated_at: ago(180),
        state: :open,
        state_reason: nil,
        work_item: nil,
        url: "https://example.com/acme/shop/issues/1231",
        labels: ["bug", "checkout"]
      },
      overrides
    )
  end

  defp row(ticket, extra \\ []) do
    assigns =
      Keyword.merge(
        [
          id: "ticket-1231",
          ticket: ticket,
          integration: "GitHub",
          patch: "/acme/shop/backlog?ticket=acme%2Fshop%231231",
          now: @now,
          take_in: "take_in",
          take_in_again: "take_in_again"
        ],
        extra
      )

    render_component(&BacklogComponents.ticket_row/1, assigns)
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp query(html, selector), do: html |> doc() |> LazyHTML.query(selector)

  defp text(html, selector) do
    html
    |> query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp texts(html, selector) do
    html |> query(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp attr(html, selector, name), do: html |> query(selector) |> LazyHTML.attribute(name)

  defp count(html, selector), do: html |> query(selector) |> Enum.count()

  # The texts that are not drawn yet: the Take in notes wait for the adapter's label and
  # comment, a closed work item's note has no approved words, Qory files no tickets yet,
  # and the full ticket's side has no approved name.
  @not_drawn [
    "Qory adds its label",
    "Take in again makes work item",
    "Qory puts its label back",
    "closed in Qory",
    "Filed by Qory",
    "Qory",
    "About the ticket"
  ]

  defp refute_not_drawn(html) do
    for words <- @not_drawn, do: refute(html =~ words, "drew #{inspect(words)}")
  end

  describe "ticket_row/1" do
    test "an open ticket: its parts, and Take in" do
      html = row(ticket())

      assert attr(html, "li#ticket-1231", "class") == ["q-bl-row"]
      assert count(html, "[aria-current]") == 0

      assert attr(html, ".q-bl-mk", "role") == ["img"]
      assert attr(html, ".q-bl-mk", "aria-label") == ["GitHub"]
      assert text(html, ".q-bl-mk") == "G"
      assert text(html, ".q-bl-no") == "#1231"

      assert text(html, "a.q-bl-t") == "Discount codes are case-sensitive at checkout"
      assert attr(html, "a.q-bl-t", "href") == ["/acme/shop/backlog?ticket=acme%2Fshop%231231"]
      assert attr(html, "a.q-bl-t", "data-phx-link") == ["patch"]
      assert count(html, ".q-bl-w") == 0

      assert text(html, ".q-bl-rp") == "acme/shop"
      assert attr(html, ".q-bl-rp", "title") == ["acme/shop"]
      assert attr(html, ".q-bl-by", "title") == ["Filed by Lea"]
      assert text(html, ".q-bl-by") == "Lea"
      assert text(html, ".q-bl-cm") == "3"
      assert text(html, ".q-bl-upd") == "3 min"
      assert attr(html, ".q-bl-upd time", "title") == ["3 minutes ago"]

      assert text(html, ".q-bl-sub") == "acme/shop#1231 · by Lea · 3 min"

      [take] = html |> query(".q-bl-act button") |> Enum.to_list()
      assert LazyHTML.text(take) =~ "Take in"
      refute LazyHTML.text(take) =~ "again"
      assert LazyHTML.attribute(take, "type") == ["button"]
      assert LazyHTML.attribute(take, "phx-click") == ["take_in"]
      assert LazyHTML.attribute(take, "phx-value-ref") == ["acme/shop#1231"]
      assert count(html, ".q-bl-wi") == 0

      refute_not_drawn(html)
    end

    test "the open ticket is marked as the current one" do
      html = row(ticket(), selected: true)
      assert attr(html, "a.q-bl-t", "aria-current") == ["true"]
      assert attr(html, "li#ticket-1231", "aria-current") == []
      assert count(html, "[aria-current]") == 1
    end

    test "taken in: the work item's number links its page, and no action" do
      work_item = %{number: 341, state: :exploring, path: "/acme/shop/work/341"}
      html = row(ticket(%{work_item: work_item}))

      assert text(html, "a.q-bl-wi") == "#341"
      assert attr(html, "a.q-bl-wi", "href") == ["/acme/shop/work/341"]
      assert attr(html, "a.q-bl-wi", "title") == ["Taken in: work item #341"]
      assert attr(html, "a.q-bl-wi", "class") == ["q-bl-wi"]
      assert count(html, ".q-bl-act button") == 0
      assert count(html, ".q-bl-w") == 0
    end

    test "taken in, without a page to link: the number, with its title" do
      work_item = %{number: 341, state: :exploring, path: nil}
      html = row(ticket(%{work_item: work_item}))

      assert count(html, "a.q-bl-wi") == 0
      assert text(html, "span.q-bl-wi") == "#341"
      assert attr(html, "span.q-bl-wi", "title") == ["Taken in: work item #341"]
    end

    test "declined: who declined it, its work item, and Take in again" do
      work_item = %{number: 79, state: :declined, path: "/acme/shop/work/79", declined_by: "Dana"}
      html = row(ticket(%{work_item: work_item}))

      assert text(html, ".q-bl-w") == "Declined by Dana"
      assert text(html, ".q-bl-sub") == "acme/shop#1231 · by Lea · 3 min · Declined by Dana"

      assert text(html, "a.q-bl-wi") == "#79"
      assert attr(html, "a.q-bl-wi", "class") == ["q-bl-wi q-bl-wi-declined"]
      assert attr(html, "a.q-bl-wi", "title") == ["Work item #79, declined by Dana"]

      [again] = html |> query(".q-bl-act button") |> Enum.to_list()
      assert LazyHTML.text(again) =~ "Take in again"
      assert [class] = LazyHTML.attribute(again, "class")
      assert "q-bl-again" in String.split(class)
      assert LazyHTML.attribute(again, "title") == ["Brings back work item #79"]
      assert LazyHTML.attribute(again, "phx-click") == ["take_in_again"]
      assert LazyHTML.attribute(again, "phx-value-ref") == ["acme/shop#1231"]
    end

    for state <- [:undone, :closed] do
      test "a #{state} work item: Take in again in place of Take in" do
        work_item = %{number: 86, state: unquote(state), path: "/acme/shop/work/86"}
        html = row(ticket(%{work_item: work_item}))

        [again] = html |> query(".q-bl-act button") |> Enum.to_list()
        assert LazyHTML.text(again) =~ "Take in again"
        assert LazyHTML.attribute(again, "title") == ["Brings back work item #86"]
        assert [class] = LazyHTML.attribute(again, "class")
        refute "q-bl-again" in String.split(class)
        assert count(html, ".q-bl-wi") == 0
        assert count(html, ".q-bl-w") == 0
      end
    end

    test "closed at the source: the integration's word, and no action" do
      html = row(ticket(%{state: :closed, state_reason: "Not planned"}))

      assert text(html, ".q-bl-w") == "Not planned"
      assert text(html, ".q-bl-sub") == "acme/shop#1231 · by Lea · 3 min · Not planned"
      assert count(html, ".q-bl-act button") == 0
      assert count(html, ".q-bl-wi") == 0
    end

    test "closed at the source with a work item: its link, and no action" do
      work_item = %{number: 69, state: :closed, path: "/acme/shop/work/69"}
      html = row(ticket(%{state: :closed, work_item: work_item}))

      assert count(html, ".q-bl-w") == 0
      assert attr(html, "a.q-bl-wi", "title") == ["Taken in: work item #69"]
      assert count(html, ".q-bl-act button") == 0

      undone = %{work_item | state: :undone}
      html = row(ticket(%{state: :closed, work_item: undone}))
      assert count(html, ".q-bl-wi") == 0
      assert count(html, ".q-bl-act button") == 0
    end

    test "a bot filer: its name, a neutral tile, no kind word" do
      html = row(ticket(%{filer: %{name: "deps-bot", kind: :bot}}))

      assert attr(html, ".q-bl-by", "title") == ["Filed by deps-bot"]
      assert text(html, ".q-bl-by .q-bl-bot-av") == "d"
      assert attr(html, ".q-bl-by .q-bl-bot-av", "aria-hidden") == ["true"]
      assert text(html, ".q-bl-by") == "d deps-bot"
      assert count(html, ".q-bl-by .q-bl-by-i") == 0
      assert text(html, ".q-bl-sub") == "acme/shop#1231 · by deps-bot · 3 min"
      words = html |> text("li") |> String.replace("deps-bot", "")
      refute words =~ ~r/automation|person|\bbot\b/i
    end

    test "no comments: the column is empty" do
      html = row(ticket(%{comment_count: 0}))
      assert text(html, ".q-bl-cm") == ""
      assert count(html, ".q-bl-cm span") == 0
    end

    test "markup in what the source sent prints as text" do
      markup = "<b onmouseover=\"alert(1)\">x</b>"
      work_item = %{number: 79, state: :declined, path: nil, declined_by: markup}

      html =
        row(
          ticket(%{
            title: markup,
            repository: markup,
            ref: markup,
            filer: %{name: markup, kind: :bot},
            work_item: work_item
          })
        )

      assert count(html, "b") == 0
      assert html =~ "&lt;b onmouseover=&quot;alert(1)&quot;&gt;x&lt;/b&gt;"
      assert text(html, "a.q-bl-t") == markup
      assert attr(html, ".q-bl-rp", "title") == [markup]

      html = row(ticket(%{state: :closed, state_reason: markup}))
      assert count(html, "b") == 0
      assert text(html, ".q-bl-w") == markup
    end
  end

  describe "filer/1" do
    test "a person: the person mark and the name" do
      html = render_component(&BacklogComponents.filer/1, name: "Lea", kind: :person)

      assert attr(html, ".q-bl-filer .q-bl-by-i", "class") == [
               "hero-user-circle-micro q-bl-by-i size-3"
             ]

      assert count(html, ".q-bl-bot-av") == 0
      assert text(html, ".q-bl-filer") == "Lea"
    end

    test "a bot: a tile with its first letter, and the name" do
      html = render_component(&BacklogComponents.filer/1, name: "release-bot", kind: :bot)

      assert text(html, ".q-bl-bot-av") == "r"
      assert count(html, ".q-bl-by-i") == 0
      assert text(html, ".q-bl-filer") == "r release-bot"
    end
  end

  test "integration_tile/1: the first letter, and the name for a screen reader" do
    html = render_component(&BacklogComponents.integration_tile/1, name: "GitHub")

    assert attr(html, ".q-bl-tile", "role") == ["img"]
    assert attr(html, ".q-bl-tile", "aria-label") == ["GitHub"]
    assert attr(html, ".q-bl-tile span", "aria-hidden") == ["true"]
    assert text(html, ".q-bl-tile") == "G"
  end

  describe "compact_time/1" do
    defp compact(at, now \\ @now) do
      html = render_component(&BacklogComponents.compact_time/1, at: at, now: now)
      {text(html, "time"), attr(html, "time", "title"), attr(html, "time", "datetime")}
    end

    test "now, minutes, hours, Yesterday, days; time_ago's words in the title" do
      for {seconds, words} <- [
            {0, "now"},
            {59, "now"},
            {60, "1 min"},
            {180, "3 min"},
            {59 * 60 + 59, "59 min"},
            {5 * 3600, "5 h"},
            {11 * 3600, "11 h"},
            {19 * 3600, "Yesterday"},
            {9 * 86_400, "9 d"},
            {40 * 86_400, "40 d"}
          ] do
        at = ago(seconds)
        assert {^words, [title], [datetime]} = compact(at)
        assert title == Format.time_ago(at, @now)
        assert datetime == DateTime.to_iso8601(at)
      end
    end

    test "the reader's days: under an hour is minutes, even across midnight" do
      now = ~U[2026-10-16 00:10:00Z]
      assert {"20 min", _, _} = compact(~U[2026-10-15 23:50:00Z], now)
      assert {"Yesterday", ["Yesterday, 22:50"], _} = compact(~U[2026-10-15 22:50:00Z], now)
      assert {"2 d", _, _} = compact(~U[2026-10-14 23:59:00Z], now)
    end

    test "a time ahead of now is no time ago" do
      assert {"now", _, _} = compact(DateTime.add(@now, 7200, :second))
    end
  end

  describe "ticket/1" do
    defp comments do
      [
        %{id: "c1", author: "Sam", at: ago(27 * 3600), body: "Same on the mobile web."},
        %{id: "c2", author: "Mirek", at: ago(20 * 3600), body: "Fine to take in."},
        %{id: "c3", author: "Lea", at: ago(180), body: "Added a screenshot."}
      ]
    end

    defp list_frame(ticket, comments) do
      assigns = %{ticket: ticket, comments: comments, now: @now}

      rendered_to_string(~H"""
      <BacklogComponents.ticket
        id="tk"
        ticket={@ticket}
        integration="GitHub"
        comments={@comments}
        now={@now}
        full_path="/acme/shop/backlog/tkt_01"
        close_patch="/acme/shop/backlog"
      >
        <:take_in>
          <section id="block">the block</section>
        </:take_in>
        <:rendered_body>
          <p id="text">the text</p>
        </:rendered_body>
        <:rendered_comment :let={comment}>
          <p class="said">{comment.body}</p>
        </:rendered_comment>
      </BacklogComponents.ticket>
      """)
    end

    defp full_frame(ticket, comments) do
      assigns = %{ticket: ticket, comments: comments, now: @now}

      rendered_to_string(~H"""
      <BacklogComponents.ticket
        id="tk"
        frame={:full}
        ticket={@ticket}
        integration="GitHub"
        comments={@comments}
        now={@now}
        back_path="/acme/shop/backlog"
      >
        <:take_in>
          <section id="block">the block</section>
        </:take_in>
        <:rendered_body>
          <p id="text">the text</p>
        </:rendered_body>
        <:rendered_comment :let={comment}>
          <p class="said">{comment.body}</p>
        </:rendered_comment>
      </BacklogComponents.ticket>
      """)
    end

    test "over the list (the panel, the dialog and the sheet): one dialog named Ticket" do
      html = list_frame(ticket(), comments())

      # The page's CSS makes it the panel from 1280 px, the dialog from 768 to 1279 and
      # the sheet below 768: the markup is the same at every width.
      assert count(html, "[role=dialog]") == 1
      assert count(html, "aside") == 0
      assert attr(html, "div#tk", "role") == ["dialog"]
      assert attr(html, "div#tk", "aria-label") == ["Ticket"]
      assert attr(html, "div#tk", "class") == ["q-bl-prev"]
      assert count(html, "article, h1") == 0

      [scrim] = attr(html, "#tk-scrim", "phx-click")
      assert scrim =~ "patch"
      assert scrim =~ "/acme/shop/backlog"
      assert attr(html, "#tk-scrim", "aria-hidden") == ["true"]
    end

    test "over the list: the head, its three actions, the title and the meta line" do
      html = list_frame(ticket(), comments())

      assert attr(html, ".q-bl-tb .q-bl-src", "aria-label") == ["GitHub"]
      assert text(html, ".q-bl-tb .q-bl-key") == "acme/shop#1231"

      assert attr(html, "a#tk-full", "href") == ["/acme/shop/backlog/tkt_01"]
      assert attr(html, "a#tk-full", "data-phx-link") == ["redirect"]
      assert attr(html, "a#tk-full", "aria-label") == ["Open the full ticket"]
      assert attr(html, "a#tk-full", "title") == ["Open the full ticket"]

      assert attr(html, "a#tk-out", "href") == ["https://example.com/acme/shop/issues/1231"]
      assert attr(html, "a#tk-out", "target") == ["_blank"]
      assert attr(html, "a#tk-out", "rel") == ["noopener noreferrer nofollow"]
      assert attr(html, "a#tk-out", "title") == ["Open on GitHub"]
      assert text(html, "a#tk-out") == "Open on GitHub (opens in a new tab)"

      assert attr(html, "a#tk-close", "href") == ["/acme/shop/backlog"]
      assert attr(html, "a#tk-close", "data-phx-link") == ["patch"]
      assert attr(html, "a#tk-close", "aria-label") == ["Close the ticket"]
      assert attr(html, "a#tk-close", "title") == ["Close"]

      assert text(html, "h2#tk-title") == "Discount codes are case-sensitive at checkout"
      assert text(html, ".q-bl-meta") == "Lea filed this 2 days ago · updated 3 minutes ago"
    end

    test "over the list: Repository and Labels, the block, the text, the comments" do
      html = list_frame(ticket(), comments())

      assert texts(html, "#tk-facts dt") == ["Repository", "Labels"]
      assert text(html, "#tk-facts .q-bl-repo") == "acme/shop"
      assert text(html, "#tk-facts .q-bl-lb") == "bug, checkout"
      refute text(html, "#tk-facts") =~ "Filed by"

      assert text(html, "div#tk > #block") == "the block"
      assert text(html, "#tk-text > #text") == "the text"

      assert text(html, "#tk-comments h3") == "3 comments"
      assert attr(html, "#tk-comments", "aria-labelledby") == ["tk-comments-h"]

      assert [sam, mirek, lea] = html |> query("#tk-comments .q-bl-cmt") |> Enum.to_list()
      assert LazyHTML.attribute(sam, "id") == ["tk-comment-c1"]
      assert sam |> LazyHTML.query("b") |> LazyHTML.text() == "Sam"
      assert sam |> LazyHTML.query(".avatar") |> LazyHTML.text() |> String.trim() == "S"

      assert sam |> LazyHTML.query(".q-bl-when") |> LazyHTML.text() ==
               Format.time_ago(ago(27 * 3600), @now)

      assert sam |> LazyHTML.query(".q-bl-txt .said") |> LazyHTML.text() |> String.trim() ==
               "Same on the mobile web."

      assert mirek |> LazyHTML.query(".q-bl-txt") |> LazyHTML.text() |> String.trim() ==
               "Fine to take in."

      assert lea |> LazyHTML.query(".q-bl-when") |> LazyHTML.text() == "3 minutes ago"

      refute_not_drawn(html)
    end

    test "the full ticket: a page with the back link, the text left, the facts right" do
      html = full_frame(ticket(), comments())

      assert count(html, "aside, [role=dialog], #tk-scrim, #tk-close, #tk-full") == 0
      assert attr(html, "article#tk", "aria-labelledby") == ["tk-title"]

      assert text(html, "a#tk-back") == "Backlog"
      assert attr(html, "a#tk-back", "href") == ["/acme/shop/backlog"]

      assert attr(html, ".q-bl-tk-head .q-bl-src", "aria-label") == ["GitHub"]
      assert text(html, ".q-bl-tk-head .q-bl-key") == "G acme/shop#1231"
      assert text(html, "h1#tk-title") == "Discount codes are case-sensitive at checkout"
      assert text(html, ".q-bl-meta") == "Lea filed this 2 days ago · updated 3 minutes ago"

      assert text(html, ".q-bl-tk-main #tk-text > #text") == "the text"
      assert text(html, ".q-bl-tk-main #tk-comments h3") == "3 comments"

      assert texts(html, ".q-bl-tk-side #tk-facts dt") == ["Repository", "Labels", "Filed by"]
      assert texts(html, ".q-bl-tk-side #tk-facts dd") == ["acme/shop", "bug, checkout", "Lea"]
      assert text(html, ".q-bl-tk-side a#tk-out") == "Open on GitHub (opens in a new tab)"
      assert attr(html, "a#tk-out", "href") == ["https://example.com/acme/shop/issues/1231"]
      assert attr(html, "a#tk-out", "target") == ["_blank"]
      assert text(html, ".q-bl-tk-side > #block") == "the block"

      refute_not_drawn(html)
    end

    test "without labels or comments: no Labels fact and no thread" do
      for html <- [
            list_frame(ticket(%{labels: []}), []),
            full_frame(ticket(%{labels: []}), [])
          ] do
        refute text(html, "#tk-facts") =~ "Labels"
        assert count(html, ".q-bl-lb, #tk-comments, .q-bl-cmt") == 0
        refute html =~ "comment"
      end
    end

    test "the meta line's times in lower case, mid-sentence" do
      just_now = ticket(%{filed_at: ago(20), updated_at: ago(5)})

      for html <- [list_frame(just_now, []), full_frame(just_now, [])] do
        assert text(html, ".q-bl-meta") == "Lea filed this just now · updated just now"
      end

      filed_at = ago(30 * 3600)
      yesterday = ticket(%{filed_at: filed_at, updated_at: ago(5)})
      filed_ago = Format.time_ago(filed_at, @now, case: :inline)
      assert filed_ago =~ ~r/\Ayesterday, /

      for html <- [list_frame(yesterday, []), full_frame(yesterday, [])] do
        assert text(html, ".q-bl-meta") == "Lea filed this #{filed_ago} · updated just now"
      end
    end

    test "one comment: its count in the singular" do
      [first | _] = comments()
      assert text(list_frame(ticket(), [first]), "#tk-comments h3") == "1 comment"
    end

    test "a link out only for a url that may be one" do
      for url <- [
            nil,
            "",
            "javascript:alert(1)",
            "data:text/html,x",
            "/acme/shop/issues/1",
            "//example.com/x",
            "https://user:secret@example.com/x"
          ],
          html <- [list_frame(ticket(%{url: url}), []), full_frame(ticket(%{url: url}), [])] do
        assert count(html, "#tk-out") == 0, "drew a link out for #{inspect(url)}"
        refute html =~ "Open on GitHub"
      end
    end

    test "a link out only for a url the core's https rule allows" do
      for url <- [
            "https://xn--gthub-n4a.com/acme/shop/issues/1",
            "http://example.com/acme/shop/issues/1",
            "https://[::1]/x",
            "https://example.com:99999/x",
            "https://1.1/",
            "https://ex%61mple.com/x",
            "https://user@example.com/x",
            :x
          ],
          html <- [list_frame(ticket(%{url: url}), []), full_frame(ticket(%{url: url}), [])] do
        assert count(html, "#tk-out") == 0, "drew a link out for #{inspect(url)}"
        refute html =~ "Open on GitHub"
      end

      url = "https://github.com/acme/shop/issues/1"

      for html <- [list_frame(ticket(%{url: url}), []), full_frame(ticket(%{url: url}), [])] do
        assert attr(html, "a#tk-out", "href") == [url]
        assert html =~ "Open on GitHub"
      end
    end

    test "without slots: no block and no text" do
      assigns = %{ticket: ticket(), now: @now}

      html =
        rendered_to_string(~H"""
        <BacklogComponents.ticket id="tk" ticket={@ticket} integration="GitHub" now={@now} />
        """)

      assert text(html, "#tk-text") == ""
      assert count(html, "section, #tk-scrim, #tk-close, #tk-full") == 0
      refute_not_drawn(html)
    end

    test "a bot filer in the meta line and the facts" do
      bot = ticket(%{filer: %{name: "deps-bot", kind: :bot}})

      assert text(list_frame(bot, []), ".q-bl-meta") =~ "deps-bot filed this 2 days ago"
      assert text(full_frame(bot, []), "#tk-facts dd") =~ "deps-bot"
    end

    test "markup in what the source sent prints as text" do
      markup = "<img src=x onerror=\"alert(1)\">"

      t =
        ticket(%{
          ref: markup,
          title: markup,
          repository: markup,
          labels: [markup, "bug"],
          filer: %{name: markup, kind: :person}
        })

      comment = %{id: "c1", author: markup, at: ago(60), body: "plain"}

      for html <- [list_frame(t, [comment]), full_frame(t, [comment])] do
        assert count(html, "img") == 0
        assert html =~ "&lt;img src=x onerror=&quot;alert(1)&quot;&gt;"
        assert text(html, "#tk-title") == markup
        assert text(html, ".q-bl-lb, .q-bl-tk-side dd") =~ markup <> ", bug"
        assert text(html, ".q-bl-cmt b") == markup
      end
    end
  end
end
