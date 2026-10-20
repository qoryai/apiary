defmodule ApiaryWeb.WorkItemListComponentsTest do
  @moduledoc """
  The Work items list's parts (`ApiaryWeb.WorkItemListComponents`): the head, the stages
  strip in each of its attention lines and their plurals, the views, the search, the
  Filter and its tokens, the views' notes, a stage's band, a row in each status and its
  "you" form, the pager and the empty list. A row's ids and its link are Qory Apiary's,
  never the ticket's ref.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias ApiaryWeb.WorkItemListComponents, as: L

  @now ~U[2026-10-17 12:00:00Z]
  @dana %{name: "Dana", email: "dana@example.com", you: true}
  @priya %{name: "Priya", email: "priya@example.com", you: false}

  defp ago(seconds), do: DateTime.add(@now, -seconds, :second)

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
    html
    |> query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
  end

  defp attr(html, selector, name), do: html |> query(selector) |> LazyHTML.attribute(name)
  defp count(html, selector), do: html |> query(selector) |> Enum.count()

  test "the head: the line under the title, and Take in from the Backlog" do
    html =
      render_component(&L.work_items_head/1,
        workspace: "Main",
        backlog_path: "/8wonders/main/backlog"
      )

    assert text(html, "h1") == "Work items"
    assert html =~ "The tickets Main took in from the Backlog, by stage."
    assert text(html, "#work-items-take-in") == "Take in from the Backlog"
    assert attr(html, "#work-items-take-in", "href") == ["/8wonders/main/backlog"]
  end

  defp strip(extra) do
    render_component(
      &L.stages_strip/1,
      Keyword.merge(
        [
          counts: %{explore: 34, confirm: 15, shape: 8},
          paths: %{
            explore: "/8wonders/main/work?stage=explore",
            confirm: "/8wonders/main/work?stage=confirm",
            shape: "/8wonders/main/work?stage=shape"
          }
        ],
        extra
      )
    )
  end

  describe "stages_strip/1" do
    test "the three stages: name, count, what it is, and what needs a look" do
      html = strip(exploring: 26, waiting: %{count: 3, for: :you}, ready: 8)

      assert attr(html, "nav", "aria-label") == ["Stages"]
      assert texts(html, ".q-wl-st-name") == ["Explore", "Confirm", "Shape"]
      assert texts(html, ".q-wl-st-n") == ["34", "15", "8"]

      assert texts(html, ".q-wl-st-what") == [
               "Qory reads the ticket and the code",
               "A member confirms what Qory proposes",
               "The plan and its acceptance criteria"
             ]

      assert texts(html, ".q-wl-st-attn") == ["26 exploring", "3 wait for you", "8 ready"]

      assert attr(html, "#work-items-stages-confirm", "href") == [
               "/8wonders/main/work?stage=confirm"
             ]

      assert attr(html, "#work-items-stages-confirm .q-wi-mk", "class") == [
               "q-wi-mk q-wi-mk-wait"
             ]
    end

    test "Explore's line: how many explore, wait for answers and are without a result" do
      html = strip(exploring: 2, answers: 1234, no_result: 1)

      assert texts(html, "#work-items-stages-explore .q-wl-attn") == [
               "2 exploring",
               "1,234 wait for answers",
               "1 without a result"
             ]

      assert attr(html, "#work-items-stages-explore .q-wi-mk", "class") == [
               "q-wi-mk q-wi-mk-run",
               "q-wi-mk q-wi-mk-wait",
               "q-wi-mk q-wi-mk-err"
             ]

      for {answers, no_result, words} <- [
            {1, 0, ["1 waits for answers"]},
            {2, 0, ["2 wait for answers"]},
            {0, 1234, ["1,234 without a result"]},
            {0, 0, ["Nothing is exploring"]}
          ] do
        html = strip(answers: answers, no_result: no_result)

        assert texts(html, "#work-items-stages-explore .q-wl-st-attn > span") == words
      end
    end

    test "nothing to say: the words for none" do
      html = strip(counts: %{explore: 0, confirm: 0, shape: 0})

      assert texts(html, ".q-wl-st-attn") == [
               "Nothing is exploring",
               "Nothing waits",
               "Nothing yet"
             ]
    end

    test "Confirm's line, for whom and how many" do
      for {waiting, words, mark} <- [
            {%{count: 1, for: :you}, "1 waits for you", "wait"},
            {%{count: 3, for: :you}, "3 wait for you", "wait"},
            {%{count: 15, for: :member}, "15 wait for a member", "wait_other"},
            {%{count: 1, for: :member}, "1 waits for a member", "wait_other"},
            {%{count: 1, for: "Priya"}, "1 waits for Priya", "wait_other"},
            {%{count: 2, for: "Priya"}, "2 wait for Priya", "wait_other"},
            {%{count: 0, for: :you}, "Nothing waits", nil}
          ] do
        html = strip(waiting: waiting)
        assert text(html, "#work-items-stages-confirm .q-wl-st-attn") == words

        assert attr(html, "#work-items-stages-confirm .q-wi-mk", "class") ==
                 if(mark, do: ["q-wi-mk q-wi-mk-#{mark}"], else: [])
      end
    end
  end

  describe "the bar" do
    test "the views, the current one marked, with their counts" do
      html =
        render_component(&L.work_item_views/1,
          current: :you,
          counts: %{open: 57, you: 3, declined: 4, closed: 262},
          paths: %{
            open: "/8wonders/main/work",
            you: "/8wonders/main/work?view=you",
            declined: "/8wonders/main/work?view=declined",
            closed: "/8wonders/main/work?view=closed"
          }
        )

      assert attr(html, "nav", "aria-label") == ["Views"]
      assert texts(html, "a") == ["Open 57", "Waiting on you 3", "Declined 4", "Closed 262"]
      assert attr(html, "a[aria-current]", "id") == ["work-items-views-you"]
      assert attr(html, "#work-items-views-closed", "href") == ["/8wonders/main/work?view=closed"]
    end

    test "the search" do
      html = render_component(&L.work_item_search/1, value: "rounding")
      assert text(html, "label .sr-only") == "Search work items"
      assert attr(html, "input", "placeholder") == ["Search by title, number or ticket"]
      assert attr(html, "input", "value") == ["rounding"]
    end

    test "the Filter: Owner, the collections in their sources' words, and Updated" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <L.work_item_filter
          collection_label="Repository or queue"
          count={1}
          values={%{owner: "Priya"}}
        >
          <:owner>
            <p>owners</p>
          </:owner>
          <:collection>
            <p>repositories</p>
          </:collection>
          <:updated>
            <p>days</p>
          </:updated>
        </L.work_item_filter>
        """)

      assert text(html, ".q-fm-h") == "Filter by"
      assert texts(html, ".q-fm-label") == ["Owner", "Repository or queue", "Updated"]
      assert text(html, "#work-items-filter-value-owner") == "Priya"
      assert text(html, "#work-items-filter-button") =~ "Filter"
    end

    test "the tokens: each with its remove label, Clear, and how many match" do
      html =
        render_component(&L.work_item_tokens/1,
          collection_label: "Project",
          filters: [
            %{key: :owner, value: "Priya", patch: "/8wonders/main/work?collection=acme%2Fshop"},
            %{key: :collection, value: "acme/shop", patch: "/8wonders/main/work?owner=Priya"}
          ],
          clear: "/8wonders/main/work",
          match: 5
        )

      assert texts(html, ".q-tok") == ["Owner Priya", "Project acme/shop"]

      assert attr(html, ".q-tok-x", "aria-label") == [
               "Remove Owner: Priya",
               "Remove Project: acme/shop"
             ]

      assert text(html, ".q-tok-clear") == "Clear"
      assert text(html, "#work-items-tokens-match") == "5 work items match"

      one =
        render_component(&L.work_item_tokens/1,
          collection_label: "Project",
          filters: [%{key: :updated, value: "Last 7 days", patch: "/8wonders/main/work"}],
          match: 1
        )

      assert text(one, "#work-items-tokens-match") == "1 work item matches"
      assert attr(one, ".q-tok-x", "aria-label") == ["Remove Updated: Last 7 days"]
    end

    test "the views' notes" do
      assert render_component(&L.view_note/1, view: :you) =~
               "Work items that wait for you to confirm what Qory proposes. Oldest first."

      assert render_component(&L.view_note/1, view: :declined) =~
               "Work items a member declined. Their tickets stay in the Backlog, where Take in again brings one back."

      for view <- [:open, :closed],
          do: assert(render_component(&L.view_note/1, view: view) |> String.trim() == "")
    end
  end

  defp work_item(overrides \\ %{}) do
    Map.merge(
      %{
        number: 88,
        title: "Checkout totals are a cent off when a discount applies",
        external_ref: "123456#42",
        key: "#1204",
        status: :confirm,
        owner: @dana,
        ended_by: nil,
        updated_at: ago(2 * 86_400)
      },
      overrides
    )
  end

  defp row(w, extra \\ []) do
    render_component(
      &L.work_item_row/1,
      Keyword.merge(
        [
          id: "work-item-#{w.number}",
          work_item: w,
          integration: "GitHub",
          navigate: "/8wonders/main/work/#{w.number}",
          now: @now
        ],
        extra
      )
    )
  end

  describe "work_item_row/1" do
    test "its parts, the whole row a link to the work item" do
      html = row(work_item())

      assert attr(html, "li", "id") == ["work-item-88"]
      assert attr(html, "a", "href") == ["/8wonders/main/work/88"]
      assert text(html, ".q-wl-no") == "#88"

      assert text(html, ".q-wl-ttl > b") ==
               "Checkout totals are a cent off when a discount applies"

      assert text(html, ".q-wl-tk") == "G #1204"
      assert attr(html, ".q-wl-tk .q-bl-tile", "aria-label") == ["GitHub"]
      assert attr(html, ".q-wl-tk span[title]", "title") == ["#1204"]
      assert text(html, ".q-wl-nx") == "Waits for you to confirm"
      assert text(html, ".q-wl-sub") == "#88 · Waits for you to confirm"
      assert count(html, ".q-wl-row-hot") == 1
      assert attr(html, ".q-wl-own", "title") == []
      assert attr(html, ".q-wl-own", "aria-label") == ["Owner: dana@example.com"]
      assert attr(html, ".q-wl-own abbr", "data-tip") == ["dana@example.com (you)"]
      assert attr(html, ".q-wl-own abbr", "tabindex") == []
      assert attr(html, ".q-wl-own", "role") == ["img"]
      assert text(html, ".q-wl-upd") == "2 d"
    end

    test "its title and key as a page shows a text from an external system" do
      html = row(work_item(%{title: "Checkout \u202Etotals", key: "#12\u200B04"}))

      refute html =~ "\u202E"
      refute html =~ "\u200B"
      assert text(html, ".q-wl-ttl > b") == "Checkout totals"
      assert attr(html, ".q-wl-tk span[title]", "title") == ["#1204"]
    end

    test "a title with nothing left to show is no title: the row says its number" do
      html = row(work_item(%{title: "\u200B\u202E"}))

      assert text(html, ".q-wl-ttl > b") == "#88"
    end

    test "every status, with its you form" do
      for {overrides, words} <- [
            {%{status: :queued}, "Explore is queued"},
            {%{status: :running}, "Qory is exploring"},
            {%{status: :confirm}, "Waits for you to confirm"},
            {%{status: :confirm, owner: @priya}, "Waits for Priya to confirm"},
            {%{status: :shape}, "Ready for Shape"},
            {%{status: :declined, ended_by: @priya}, "Declined by Priya"},
            {%{status: :declined, ended_by: @dana}, "Declined by you"},
            {%{status: :closed, ended_by: @priya}, "Closed by Priya"},
            {%{status: :closed, ended_by: @dana}, "Closed by you"}
          ] do
        html = row(work_item(overrides))
        assert text(html, ".q-wl-nx") == words

        assert count(html, ".q-wl-row-hot") ==
                 if(words == "Waits for you to confirm", do: 1, else: 0)
      end
    end

    test "Explore's statuses: their words and marks, the reader's with the right to act" do
      run = %{id: "rn_01aa47c9", attempt: 2, of: 3}

      for {status, words, acts, others} <- [
            {:questions, "Waits for answers", "wait", "wait_other"},
            {:used_up, "Explore used its 3 runs", "wait", "wait_other"},
            {:no_result, "Explore ended without a result", "err", "err"},
            {:lost, "Explore's run was lost", "err", "err"},
            {:cancelled, "Explore's run was cancelled", "err", "err"}
          ] do
        w = work_item(%{status: status, run: run})

        for {can_act, mark} <- [{true, acts}, {false, others}] do
          html = row(w, can_act: can_act)
          assert text(html, ".q-wl-nx") == words
          assert attr(html, ".q-wl-row .q-wi-mk", "class") == ["q-wi-mk q-wi-mk-#{mark}"]
          assert count(html, ".q-wl-row-hot") == 0
        end
      end
    end

    test "another's work item: the owner's mark names them" do
      html = row(work_item(%{owner: @priya}))
      assert attr(html, ".q-wl-own", "aria-label") == ["Owner: priya@example.com"]
      assert attr(html, ".q-wl-own abbr", "data-tip") == ["priya@example.com"]
      assert text(html, ".q-wl-own abbr span[aria-hidden]") == "P"
    end

    test "what the ticket holds is escaped" do
      html = row(work_item(%{title: "<script>alert(1)</script>", key: "<x>#1"}))
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
      refute html =~ "<x>"
      assert html =~ "&lt;x&gt;#1"
    end

    test "without a key, the mark alone; the ticket's ref never, in any form" do
      html = row(work_item(%{key: nil}))
      assert text(html, ".q-wl-tk") == "G"
      assert count(html, ".q-wl-tk span[title]") == 0

      for w <- [work_item(), work_item(%{key: nil})] do
        html = row(w)
        refute html =~ "123456"
        refute html =~ "#42"
      end
    end

    test "no id or path holds the ticket's ref or its number there" do
      html = row(work_item())

      for node <- query(html, "*"),
          {name, value} <- node |> LazyHTML.attributes() |> List.first([]),
          name in ["id", "href"] or String.starts_with?(name, "phx-value-") do
        refute value =~ "acme/shop", "#{name}=#{value}"
        refute value =~ "1204", "#{name}=#{value}"
      end
    end
  end

  describe "stage_band/1" do
    defp band(extra) do
      assigns = %{extra: extra}

      rendered_to_string(~H"""
      <L.stage_band id="work-items-confirm" {@extra}>
        <li>row</li>
      </L.stage_band>
      """)
    end

    test "Fold, the name, the count, the line, what waits, and Show all" do
      html =
        band(
          stage: :confirm,
          count: 15,
          shown: 8,
          waiting: %{count: 3, for: :you},
          all_path: "/8wonders/main/work?stage=confirm"
        )

      assert attr(html, "#work-items-confirm-fold", "aria-label") == ["Fold Confirm"]
      assert attr(html, "#work-items-confirm-fold", "aria-expanded") == ["true"]

      assert attr(html, "#work-items-confirm-fold", "aria-controls") == [
               "work-items-confirm-rows"
             ]

      assert text(html, "h2") == "Confirm"
      assert text(html, ".q-band-n") == "15"
      assert text(html, ".q-wl-what") == "A member confirms what Qory proposes"
      assert text(html, ".q-wl-band-attn") == "3 wait for you"
      assert text(html, "#work-items-confirm-all") == "Show all 15 in Confirm"

      assert attr(html, "#work-items-confirm-all", "href") == [
               "/8wonders/main/work?stage=confirm"
             ]
    end

    test "filtered to one owner, one waits for them; every row shown: no Show all" do
      html = band(stage: :confirm, count: 1, shown: 1, waiting: %{count: 1, for: "Priya"})
      assert text(html, ".q-wl-band-attn") == "1 waits for Priya"
      assert count(html, "#work-items-confirm-all") == 0
    end

    test "Explore's band: how many wait for answers and how many are without a result" do
      html = band(stage: :explore, count: 40, shown: 8, answers: 3, no_result: 1)

      assert texts(html, ".q-wl-band-attn .q-wl-attn") == [
               "3 wait for answers",
               "1 without a result"
             ]
    end

    test "Explore says how many Qory explores; Shape's band says nothing" do
      explore = band(stage: :explore, count: 34, shown: 8, exploring: 26)
      assert text(explore, ".q-wl-band-attn") == "26 exploring"
      assert text(explore, "#work-items-confirm-fold") == ""
      assert attr(explore, "#work-items-confirm-fold", "aria-label") == ["Fold Explore"]

      shape = band(stage: :shape, count: 8, shown: 8)
      assert text(shape, ".q-wl-band-attn") == ""
    end
  end

  test "the pager of Closed" do
    html =
      render_component(&L.work_items_pager/1,
        first: 1,
        last: 50,
        total: 262,
        next: "/8wonders/main/work?view=closed&page=2"
      )

    assert text(html, ".q-pager-count") == "1–50 of 262"
    assert text(html, "#work-items-pager-previous") == "Previous"
    assert attr(html, "#work-items-pager-previous", "disabled") != []
    assert text(html, "#work-items-pager-next") == "Next"
  end

  test "the empty list: why, how a work item starts, and Open the Backlog" do
    html = render_component(&L.work_items_empty/1, backlog_path: "/8wonders/main/backlog")

    assert text(html, "h2") == "No work items yet"

    assert text(html, ".q-wl-empty") =~
             "A work item starts when someone takes in one of the Backlog's tickets. Qory then explores it and proposes how to build it."

    assert text(html, "#work-items-open-backlog") == "Open the Backlog"
    assert attr(html, "#work-items-open-backlog", "href") == ["/8wonders/main/backlog"]
  end

  test "in a general workspace, the stages and the empty list name no code" do
    # A general workspace reads the source texts; the tests above read the software
    # catalogue's, the default locale's.
    Gettext.with_locale(ApiaryWeb.Gettext, "en@general", fn ->
      assert texts(strip(exploring: 1), ".q-wl-st-what") |> hd() == "Qory reads the ticket"

      html = render_component(&L.work_items_empty/1, backlog_path: "/8wonders/main/backlog")

      assert text(html, ".q-wl-empty") =~
               "A work item starts when someone takes in one of the Backlog's tickets. Qory then explores it and proposes what to do."
    end)
  end

  describe "the words the sources share for their items" do
    # A page about many items names them by the word every source shares; "ticket" where
    # they differ or name none.
    @bug %{one: "bug", other: "bugs"}

    test "the head, the stages, the search, the notes and the empty list" do
      head =
        render_component(&L.work_items_head/1,
          workspace: "Main",
          backlog_path: "/8wonders/main/backlog",
          item_noun: @bug
        )

      assert head =~ "The bugs Main took in from the Backlog, by stage."

      assert texts(strip(item_noun: @bug), ".q-wl-st-what") |> hd() ==
               "Qory reads the bug and the code"

      assert text(band(stage: :explore, count: 2, shown: 2, item_noun: @bug), ".q-wl-what") ==
               "Qory reads the bug and the code"

      search = render_component(&L.work_item_search/1, item_noun: @bug)
      assert attr(search, "input", "placeholder") == ["Search by title, number or bug"]

      assert render_component(&L.view_note/1, view: :declined, item_noun: @bug) =~
               "Work items a member declined. Their bugs stay in the Backlog, where Take in again brings one back."

      empty =
        render_component(&L.work_items_empty/1,
          backlog_path: "/8wonders/main/backlog",
          item_noun: @bug
        )

      assert text(empty, ".q-wl-empty") =~
               "A work item starts when someone takes in one of the Backlog's bugs. Qory then explores it and proposes how to build it."
    end
  end
end
