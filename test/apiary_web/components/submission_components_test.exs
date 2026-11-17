defmodule ApiaryWeb.SubmissionComponentsTest do
  # The Submissions frame and the Submission block (`ApiaryWeb.SubmissionComponents`),
  # drawn from the rows `Apiary.Submissions` returns: the words, the links, the badges and
  # the escaping of every stored string.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ApiaryWeb.SubmissionComponents

  @repo "https://git.example.com/northwind/storefront"
  @now ~U[2026-11-17 15:00:00Z]

  defp commit(hex, step, extra \\ %{}) do
    Map.merge(
      %{
        commit: hex,
        short: binary_part(hex, 0, 7),
        url: "#{@repo}/commit/#{hex}",
        step: step,
        head: false
      },
      extra
    )
  end

  defp hex(char), do: String.duplicate(char, 40)

  defp repository(overrides \\ %{}) do
    head = hex("a")

    Map.merge(
      %{
        system: "git.example.com",
        path: "northwind/storefront",
        commit: head,
        short: "aaaaaaa",
        url: "#{@repo}/commit/#{head}",
        base: %{
          commit: hex("9"),
          short: "9999999",
          url: "#{@repo}/commit/#{hex("9")}",
          line: {:head, 4}
        },
        commits: [
          commit(hex("4"), {:change, "d-2", "Show the dates at checkout"}),
          commit(hex("7"), {:fix, "f1"}),
          commit(head, {:fix, "f2"}, %{head: true})
        ],
        count: 3,
        draft: {:draft, %{number: 34, url: "#{@repo}/pulls/34", title: "Show delivery dates"}}
      },
      overrides
    )
  end

  defp row(overrides \\ %{}) do
    Map.merge(
      %{
        id: "av_one",
        number: 2,
        run: 5,
        run_id: "rn_five",
        workspace_id: "w",
        stage_id: "st_build",
        at: ~U[2026-11-17 14:30:00Z],
        approved: true,
        ref: "qory/wi_qk5p97dt9vdq39a2",
        repositories: [repository()],
        path: "/northwind/storefront/runs/5"
      },
      overrides
    )
  end

  defp frame(rows, names \\ %{"git.example.com" => "GitHub"}) do
    render_component(&SubmissionComponents.frame/1,
      id: "frame",
      rows: rows,
      names: names,
      stage_names: %{"st_build" => "Build"},
      now: @now
    )
  end

  defp block(row, names \\ %{"git.example.com" => "GitHub"}) do
    render_component(&SubmissionComponents.block/1,
      id: "block",
      row: row,
      type: "submission",
      names: names
    )
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp texts(html, selector),
    do: html |> doc() |> LazyHTML.query(selector) |> Enum.map(&LazyHTML.text/1)

  defp count(html, selector), do: html |> doc() |> LazyHTML.query(selector) |> Enum.count()
  defp text(html), do: html |> doc() |> LazyHTML.text() |> String.replace(~r/\s+/, " ")

  describe "the Submissions frame" do
    test "has the heading, the caption and a row for each submission, newest first" do
      older = row(%{id: "av_old", number: 1, run: 4, approved: false, path: nil})
      html = frame([row(), older])

      assert texts(html, "h2") == ["Submissions"]
      assert text(html) =~ "Newest first"
      assert count(html, "#frame-av_one") == 1
      assert count(html, "#frame-av_old") == 1
    end

    test "a row has its run, its stage, the time its run ended and the Approved badge" do
      html = frame([row()])

      assert text(html) =~ "Run 5"
      assert text(html) =~ "Build · Today, 14:30"
      assert texts(html, ".badge") |> Enum.map(&String.trim/1) |> Enum.member?("Approved")
      assert html =~ ~s(href="/northwind/storefront/runs/5")
    end

    test "a row not approved has no badge, and a row with no run page address has no link" do
      html = frame([row(%{approved: false, path: nil})])

      refute text(html) =~ "Approved"
      refute html =~ "/runs/5"
      assert text(html) =~ "Run 5"
    end

    test "a row with no run number says a run" do
      assert text(frame([row(%{run: nil, path: nil})])) =~ "A run"
    end

    test "a submission with one change and two fixes shows the base, the change with its text, both fixes and Head" do
      html = frame([row()])

      assert texts(html, "#frame-av_one-r0-base") |> hd() |> squash() ==
               "9999999 Base: the head of Run 4"

      assert texts(html, "#frame-av_one-r0-c0") |> hd() |> squash() ==
               "4444444 d-2 · Show the dates at checkout"

      assert texts(html, "#frame-av_one-r0-c1") |> hd() |> squash() ==
               "7777777 Fix of review finding f1"

      assert texts(html, "#frame-av_one-r0-c2") |> hd() |> squash() ==
               "aaaaaaa Fix of review finding f2 Head"

      assert count(html, "#frame-av_one-r0-commits .badge") == 1
      refute html |> doc() |> LazyHTML.query("#frame-av_one-r0-c0 .badge") |> Enum.any?()
      assert text(html) =~ "3 commits"
    end

    test "the labels and the fold are the software domain's words" do
      html = frame([row()])

      assert texts(html, "dt") |> Enum.map(&String.trim/1) == ["Branch", "Commits", "Draft"]
      assert text(html) =~ "qory/wi_qk5p97dt9vdq39a2 · aaaaaaa"
    end

    test "the commits of the first row are open and the others closed" do
      html = frame([row(), row(%{id: "av_old", approved: false})])

      assert html |> doc() |> LazyHTML.query("#frame-av_one-r0-fold[open]") |> Enum.count() == 1
      assert html |> doc() |> LazyHTML.query("#frame-av_old-r0-fold[open]") |> Enum.count() == 0
    end

    test "a base that no earlier submission ended at says where the branch starts" do
      base = %{commit: hex("3"), short: "3333333", url: nil, line: :start}
      html = frame([row(%{repositories: [repository(%{base: base})]})])

      assert text(html) =~ "3333333 Base: where the branch starts"
    end

    test "one commit is counted in the singular" do
      one = repository(%{commits: [commit(hex("a"), {:fix, "f2"}, %{head: true})], count: 1})
      assert text(frame([row(%{repositories: [one]})])) =~ "1 commit"
      refute text(frame([row(%{repositories: [one]})])) =~ "1 commits"
    end

    test "a commit with no address shows its short id with no link" do
      commits = [
        commit(hex("4"), {:fix, "f1"}, %{url: nil}),
        commit(hex("a"), nil, %{head: true})
      ]

      html = frame([row(%{repositories: [repository(%{commits: commits, count: 2})]})])

      assert count(html, "#frame-av_one-r0-c0 a") == 0
      assert texts(html, "#frame-av_one-r0-c0 span.font-mono") == ["4444444"]
      assert count(html, "#frame-av_one-r0-c1 a") == 1
    end

    test "a commit with a step the list has no words for shows its short id alone" do
      commits = [commit(hex("a"), nil, %{head: true})]
      html = frame([row(%{repositories: [repository(%{commits: commits, count: 1})]})])

      assert texts(html, "#frame-av_one-r0-c0") |> hd() |> squash() == "aaaaaaa Head"
    end

    test "a change with no text in the plan shows its id" do
      commits = [commit(hex("a"), {:change, "d-2", nil}, %{head: true})]
      html = frame([row(%{repositories: [repository(%{commits: commits, count: 1})]})])

      assert texts(html, "#frame-av_one-r0-c0") |> hd() |> squash() == "aaaaaaa d-2 Head"
    end
  end

  describe "a base that may be a head the list does not show" do
    test "shows the commit alone, with no words" do
      base = %{
        commit: hex("3"),
        short: "3333333",
        url: "#{@repo}/commit/#{hex("3")}",
        line: :unknown
      }

      html = frame([row(%{repositories: [repository(%{base: base})]})])

      assert texts(html, "#frame-av_one-r0-base") |> hd() |> squash() == "3333333"
      refute text(html) =~ "Base:"
    end
  end

  describe "links" do
    test "open in a new tab and carry rel" do
      html = frame([row()])

      links =
        html |> doc() |> LazyHTML.query("#frame-av_one-r0-commits a, #frame-av_one-r0-draft a")

      assert Enum.count(links) == 5

      for link <- links do
        assert LazyHTML.attribute(link, "target") == ["_blank"]
        assert LazyHTML.attribute(link, "rel") == ["noopener noreferrer nofollow"]
      end
    end

    test "the path and the run line break inside a long word" do
      html = frame([row(%{repositories: [repository(), repository(%{path: "a"})]})])

      assert count(html, "#frame-av_one-r0-path.min-w-0") == 1
      assert html =~ "[overflow-wrap:anywhere]"
    end
  end

  describe "the draft" do
    test "has its number beside its system's mark, with the title, as a link" do
      html = frame([row()])

      assert texts(html, "#frame-av_one-r0-draft") |> hd() |> squash() ==
               "G #34 “Show delivery dates”"

      assert html =~ ~s(aria-label="GitHub")
      assert html =~ ~s(href="#{@repo}/pulls/34")
    end

    test "has the system's own name for a mark where no integration draws it" do
      html = frame([row()], %{})

      assert html =~ ~s(aria-label="git.example.com")
      assert text(html) =~ "#34"
    end

    test "has no link where the submission has no address for it" do
      draft = {:draft, %{number: 34, url: nil, title: "Show delivery dates"}}
      html = frame([row(%{repositories: [repository(%{draft: draft})]})])

      assert count(html, "#frame-av_one-r0-draft a") == 0
      assert text(html) =~ "#34 “Show delivery dates”"
    end

    test "has its number alone where the title is empty" do
      for title <- [nil, "", "   "] do
        draft = {:draft, %{number: 34, url: "#{@repo}/pulls/34", title: title}}
        html = frame([row(%{repositories: [repository(%{draft: draft})]})])

        assert texts(html, "#frame-av_one-r0-draft a") |> hd() |> squash() == "#34"
      end
    end

    test "a submission that sent none says so, and has no Draft line" do
      html = frame([row(%{repositories: [repository(%{draft: :none})]})])

      assert text(html) =~ "The run sent no draft to the destination."
      refute text(html) =~ "Draft"
    end

    test "a submission that records neither has no Draft line and no sentence" do
      html = frame([row(%{repositories: [repository(%{draft: nil})]})])

      refute text(html) =~ "Draft"
      refute text(html) =~ "sent no draft"
    end
  end

  describe "a submission with no list of commits" do
    test "has the branch and the draft and no Commits line" do
      repository = repository(%{base: nil, commits: [], count: 0})
      html = frame([row(%{repositories: [repository]})])

      assert texts(html, "dt") |> Enum.map(&String.trim/1) == ["Branch", "Draft"]
      assert count(html, "details details") == 0
      assert text(html) =~ "qory/wi_qk5p97dt9vdq39a2 · aaaaaaa"
    end

    test "has the row and nothing else where it has no repository" do
      html = frame([row(%{repositories: []})])

      assert text(html) =~ "Run 5"
      assert count(html, "dl") == 0
    end

    test "has the head alone where the row has no branch" do
      html = frame([row(%{ref: nil})])

      assert texts(html, "#frame-av_one-r0-branch") |> hd() |> squash() == "aaaaaaa"
    end
  end

  describe "several repositories" do
    test "each has its path above its lines" do
      other = repository(%{path: "northwind/basket"})
      html = frame([row(%{repositories: [repository(), other]})])

      assert texts(html, "#frame-av_one-r0-path") |> Enum.map(&String.trim/1) == [
               "northwind/storefront"
             ]

      assert texts(html, "#frame-av_one-r1-path") |> Enum.map(&String.trim/1) == [
               "northwind/basket"
             ]
    end

    test "one repository has no path line" do
      assert count(frame([row()]), "#frame-av_one-r0-path") == 0
    end
  end

  describe "many commits" do
    test "show the lines that were kept and count them all" do
      commits = for n <- 1..100, do: commit(hex(Integer.to_string(rem(n, 10))), {:fix, "f#{n}"})
      kept = List.update_at(commits, 99, &%{&1 | head: true})
      html = frame([row(%{repositories: [repository(%{commits: kept, count: 150})]})])

      assert count(html, "#frame-av_one-r0-fold li") == 101
      assert text(html) =~ "150 commits"

      assert texts(html, "#frame-av_one-r0-c99") |> hd() |> squash() =~
               "Fix of review finding f100 Head"
    end
  end

  describe "escaping" do
    @evil ~s|<script>alert("x")</script> & "q" 'a'|

    test "every stored string is text, never markup" do
      commits = [
        commit(hex("4"), {:change, @evil, @evil}),
        commit(hex("7"), {:fix, @evil}),
        commit(hex("a"), nil, %{head: true})
      ]

      repository =
        repository(%{
          path: @evil,
          system: @evil,
          commits: commits,
          count: 3,
          draft: {:draft, %{number: 34, url: nil, title: @evil}}
        })

      html =
        frame([row(%{ref: @evil, repositories: [repository, repository(%{path: @evil})]})], %{
          @evil => @evil
        })

      refute html =~ "<script"
      assert html =~ "&lt;script&gt;"
      assert text(html) =~ @evil
    end

    test "a stored string with control or invisible characters is shown as an external text is" do
      row = row(%{ref: "qory/wi_\u0007x\u202Ey"})
      html = frame([row])

      assert text(html) =~ "qory/wi_\u{FFFD}xy"
      refute html =~ "\u202E"
    end

    test "a link is rendered with the stored address as an attribute value, escaped" do
      url = ~s|https://git.example.com/x"onmouseover="alert(1)|
      commits = [commit(hex("a"), nil, %{head: true, url: url})]
      html = frame([row(%{repositories: [repository(%{commits: commits, count: 1})]})])

      refute html =~ ~s|onmouseover="alert(1)"|
      assert html =~ "&quot;onmouseover=&quot;"
    end
  end

  describe "the Submission block" do
    test "has the heading of the type and the version, the badge and the row's lines" do
      html = block(row())

      assert texts(html, "#block-row > div") |> hd() |> squash() == "Submission v2 Approved"
      assert text(html) =~ "Base: the head of Run 4"
      assert text(html) =~ "d-2 · Show the dates at checkout"
      assert text(html) =~ "3 commits"
      assert text(html) =~ "#34 “Show delivery dates”"
      assert html |> doc() |> LazyHTML.query("#block-row-r0-fold[open]") |> Enum.count() == 1
    end

    test "names a type with hyphens in words" do
      html =
        render_component(&SubmissionComponents.block/1,
          id: "block",
          row: row(%{approved: false}),
          type: "code-change",
          names: %{}
        )

      assert text(html) =~ "Code change v2"
    end

    test "a version not approved has no badge, and a run with no draft says so" do
      html = block(row(%{approved: false, repositories: [repository(%{draft: :none})]}))

      refute text(html) =~ "Approved"
      assert text(html) =~ "The run sent no draft to the destination."
    end
  end

  defp squash(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()
end
