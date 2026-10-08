defmodule ApiaryWeb.RunLive.ShowAboutTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Runs.Projector
  alias ApiaryWeb.RunPageComponents

  setup :register_and_log_in_user

  @ticket %{
    "type" => "ticket",
    "ref" => "ENG-17",
    "url" => "https://tracker.example.com/browse/ENG-17",
    "title" => "Login redirects to a blank page"
  }
  @pull_request %{
    "type" => "pull request",
    "ref" => "#412",
    "url" => "https://git.example.com/acme/shop/pull/412"
  }
  @incident %{"type" => "incident", "ref" => "INC-5"}

  defp started(scope, about) do
    run = run_fixture(scope)
    events_fixture(run, [{1, "run.started", started_data(%{"about" => about})}])
    {:ok, run} = Projector.project(run)
    run
  end

  defp page(conn, scope, run, tab \\ "") do
    {:ok, lv, html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}" <> tab)

    {lv, html}
  end

  defp texts(lv, selector) do
    lv
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  describe "the header's line" do
    test "under the title: the kind, then each subject, a link out when it has a url", %{
      conn: conn,
      scope: scope
    } do
      run =
        started(scope, %{
          "kind" => "Implementation",
          "title" => "Fix the login redirect",
          "subjects" => [@pull_request, @ticket, @incident]
        })

      {lv, _html} = page(conn, scope, run)

      # between the h1 and the meta line
      assert has_element?(lv, ".q-run-head > h1#run-title + p#run-about + .q-run-sub")
      assert has_element?(lv, "#run-about > #run-about-kind", "Implementation")

      pr = ~s(#run-about a[href="https://git.example.com/acme/shop/pull/412"])
      assert has_element?(lv, pr, "pull request #412")
      assert has_element?(lv, pr <> ~s([target="_blank"][rel="noopener noreferrer nofollow"]))
      assert has_element?(lv, pr <> " .sr-only", "(opens in a new tab)")
      # the tooltip is the subject's title and its url's host, or the host alone
      assert has_element?(lv, pr <> ~s([title="git.example.com"]))

      assert has_element?(
               lv,
               ~s(#run-about a[href="https://tracker.example.com/browse/ENG-17"][title="Login redirects to a blank page · tracker.example.com"]),
               "ticket ENG-17"
             )

      # no url: text, not a link
      assert has_element?(lv, "#run-about > span > span", "incident INC-5")
      refute has_element?(lv, "#run-about a", "incident INC-5")

      assert lv
             |> render()
             |> LazyHTML.from_document()
             |> LazyHTML.query("#run-about a")
             |> Enum.count() == 2

      refute has_element?(lv, "#run-about-more")
    end

    test "isolates a subject's words, and its tooltip names the url's own host", %{
      conn: conn,
      scope: scope
    } do
      # A right-to-left override in the ref and a host-like title: neither may pass for
      # where the link leads.
      ref = "ENG-17\u202Emoc.elpmaxe.live"

      subject = %{
        "type" => "ticket",
        "ref" => ref,
        "url" => "https://tracker.example.com/browse/ENG-17",
        "title" => "login.example.org"
      }

      {lv, _html} = page(conn, scope, started(scope, %{"subjects" => [subject]}), "/details")

      link = ~s(a[href="https://tracker.example.com/browse/ENG-17"])
      tip = "login.example.org · tracker.example.com"

      for place <- ["#run-about", "#run-about-facts"] do
        assert has_element?(lv, "#{place} #{link}[title=\"#{tip}\"]")
        assert has_element?(lv, "#{place} #{link} bdi", ref)
        assert has_element?(lv, "#{place} #{link} bdi", "ticket")
      end

      assert has_element?(lv, "#run-about-facts .q-rail-sub > bdi", "login.example.org")

      # No url that may be a link: text, with its title and no host.
      plain = %{subject | "url" => "javascript:alert(1)"}
      {lv, _html} = page(conn, scope, started(scope, %{"subjects" => [plain]}))
      refute has_element?(lv, "#run-about a")
      assert has_element?(lv, ~s(#run-about span[title="login.example.org"] bdi), ref)
    end

    test "shows three subjects, then how many more, as text", %{conn: conn, scope: scope} do
      subjects =
        for n <- 1..5,
            do: %{
              "type" => "pull request",
              "ref" => "##{n}",
              "url" => "https://git.example.com/pull/#{n}"
            }

      run = started(scope, %{"subjects" => subjects})
      {lv, _html} = page(conn, scope, run)

      refute has_element?(lv, "#run-about-kind")

      for n <- 1..3 do
        assert has_element?(
                 lv,
                 ~s(#run-about a[href="https://git.example.com/pull/#{n}"]),
                 "pull request ##{n}"
               )
      end

      assert lv
             |> render()
             |> LazyHTML.from_document()
             |> LazyHTML.query("#run-about a")
             |> Enum.count() == 3

      assert has_element?(lv, "#run-about > #run-about-more", "+2 more")
      refute has_element?(lv, "#run-about-more a")

      # all five are in the rail's About
      assert lv
             |> render()
             |> LazyHTML.from_document()
             |> LazyHTML.query("#run-about-facts a")
             |> Enum.count() == 5
    end

    test "is there for a kind alone, and not for a title alone or no about", %{
      conn: conn,
      scope: scope
    } do
      {lv, _html} = page(conn, scope, started(scope, %{"kind" => "Audit"}))
      assert has_element?(lv, "#run-about", "Audit")
      refute has_element?(lv, "#run-about a")

      {lv, _html} = page(conn, scope, started(scope, %{"title" => "Nightly audit"}))
      refute has_element?(lv, "#run-about")

      {lv, _html} = page(conn, scope, started(scope, nil))
      refute has_element?(lv, "#run-about")
    end

    test "a url that may not be a link is text, and a ref or title is escaped", %{
      conn: conn,
      scope: scope
    } do
      run = run_fixture(scope)

      # Stored as if the fold had let them through: the page checks again.
      {:ok, run} =
        run
        |> Ecto.Changeset.change(
          about_kind: "<i>Review</i>",
          about_subjects: [
            %{"type" => "pull request", "ref" => "<b>#415</b>", "url" => "javascript:alert(1)"},
            %{"type" => "ticket", "ref" => "ENG-1", "url" => "/runs"},
            %{
              "type" => "ticket",
              "ref" => "ENG-8",
              "url" => "https://user@tracker.example.com/x"
            },
            %{
              "type" => "ticket",
              "ref" => "ENG-9",
              "url" => "https://user:secret@tracker.example.com/x"
            },
            %{
              "type" => "ticket",
              "ref" => "ENG-2",
              "url" => "https://tracker.example.com/browse/ENG-2",
              "title" => "<script>alert(1)</script>"
            }
          ]
        )
        |> Apiary.Repo.update()

      {lv, html} = page(conn, scope, run)

      refute html =~ "javascript:"
      refute has_element?(lv, ~s(#run-about a[href="/runs"]))
      assert has_element?(lv, "#run-about", "pull request <b>#415</b>")
      assert has_element?(lv, "#run-about", "ticket ENG-1")
      # a url with a user name or password is not a link either, in the header or the rail
      refute html =~ "tracker.example.com/x"
      assert has_element?(lv, "#run-about-facts > dd > span", "ticket ENG-8")
      assert has_element?(lv, "#run-about-facts > dd > span", "ticket ENG-9")
      assert html =~ "&lt;b&gt;#415&lt;/b&gt;"
      assert html =~ "&lt;i&gt;Review&lt;/i&gt;"
      refute html =~ "<b>#415"
      refute html =~ "<script>alert"
      refute html =~ "<i>Review"
    end
  end

  describe "the rail's About" do
    test "is the first section: the kind, each subject with its title, then the details", %{
      conn: conn,
      scope: scope
    } do
      run =
        started(scope, %{
          "kind" => "Implementation",
          "title" => "Fix the login redirect",
          "subjects" => [@ticket, @pull_request, @incident],
          "details" => %{
            "branch" => "qory/eng-17",
            "attempt" => 2,
            "dry_run" => false,
            "steps" => ["plan", "edit", "test"],
            "ticket" => %{
              "priority" => "high",
              "estimate" => %{"points" => 3, "confidence" => "medium"}
            },
            "empty" => %{},
            "nothing" => nil
          }
        })

      for tab <- ["", "/details"] do
        {lv, _html} = page(conn, scope, run, tab)

        assert has_element?(
                 lv,
                 ~s(#run-details > h2.q-rail-title + section#run-about-section[aria-labelledby="rail-about"]) <>
                   " + section[aria-labelledby=rail-run]"
               )

        assert has_element?(lv, "#run-about-section > h3#rail-about", "About")
        assert texts(lv, "#run-about-facts > dt") == ["Kind", "Subjects"]
        assert has_element?(lv, "#run-about-facts > dd", "Implementation")
        # the title is the h1, not a row here
        refute has_element?(lv, "#run-about-section", "Fix the login redirect")

        # one value a subject, its title muted under it, whole in its tooltip
        assert lv
               |> render()
               |> LazyHTML.from_document()
               |> LazyHTML.query("#run-about-facts > dd.q-rail-subj")
               |> Enum.count() == 3

        assert has_element?(
                 lv,
                 ~s(#run-about-facts > dd > a[href="https://tracker.example.com/browse/ENG-17"][target="_blank"]),
                 "ticket ENG-17"
               )

        assert has_element?(
                 lv,
                 ~s(#run-about-facts > dd > .q-rail-sub[title="Login redirects to a blank page"]),
                 "Login redirects to a blank page"
               )

        assert has_element?(lv, "#run-about-facts > dd > span", "incident INC-5")
        refute has_element?(lv, "#run-about-facts a", "incident INC-5")

        # keys sorted; an object one level in is dotted keys; deeper, and arrays, JSON
        assert texts(lv, "#run-about-details > dt") == [
                 "attempt",
                 "branch",
                 "dry_run",
                 "empty",
                 "nothing",
                 "steps",
                 "ticket.estimate",
                 "ticket.priority"
               ]

        assert texts(lv, "#run-about-details > dd") == [
                 "2",
                 "qory/eng-17",
                 "false",
                 "{}",
                 "null",
                 ~s(["plan","edit","test"]),
                 ~s({"confidence":"medium","points":3}),
                 "high"
               ]

        # a dotted key may break before its dot
        assert has_element?(lv, "#run-about-details > dt > wbr")
        assert has_element?(lv, "#run-about-details.q-rail-kv-mono.q-rail-about-details")

        # a value wraps, never cut: text at its spaces, compact JSON anywhere
        assert texts(lv, "#run-about-details > dd.q-rail-json") ==
                 [
                   "2",
                   "false",
                   "{}",
                   "null",
                   ~s(["plan","edit","test"]),
                   ~s({"confidence":"medium","points":3})
                 ]

        assert texts(lv, "#run-about-details > dd:not(.q-rail-json)") == ["qory/eng-17", "high"]
      end
    end

    test "is there for any of a kind, subjects or details, and not for a title alone", %{
      conn: conn,
      scope: scope
    } do
      {lv, _html} =
        page(conn, scope, started(scope, %{"details" => %{"schedule" => "0 2 * * *"}}))

      assert has_element?(lv, "#run-about-section")
      refute has_element?(lv, "#run-about-facts")
      assert texts(lv, "#run-about-details > dd") == ["0 2 * * *"]

      {lv, _html} = page(conn, scope, started(scope, %{"subjects" => [@incident]}))
      assert texts(lv, "#run-about-facts > dt") == ["Subjects"]
      refute has_element?(lv, "#run-about-details")

      {lv, _html} = page(conn, scope, started(scope, %{"kind" => "Audit"}))
      assert texts(lv, "#run-about-facts > dt") == ["Kind"]

      {lv, _html} = page(conn, scope, started(scope, %{"title" => "Nightly audit"}))
      refute has_element?(lv, "#run-about-section")

      assert has_element?(
               lv,
               "#run-details > h2.q-rail-title + section[aria-labelledby=rail-run]"
             )

      {lv, _html} = page(conn, scope, started(scope, nil))
      refute has_element?(lv, "#run-about-section")
    end

    test "escapes keys, values and subjects", %{conn: conn, scope: scope} do
      run =
        started(scope, %{
          "subjects" => [%{"type" => "ticket", "ref" => "<b>ENG-3</b>", "title" => "<i>t</i>"}],
          "details" => %{
            "<em>k</em>" => "<script>alert(1)</script>",
            "o" => %{"<u>x</u>" => "<s>y</s>"}
          }
        })

      {lv, html} = page(conn, scope, run, "/details")

      for raw <- ["<b>ENG-3", "<i>t</i>", "<em>k", "<script>alert", "<u>x", "<s>y"],
          do: refute(html =~ raw, raw)

      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert has_element?(lv, "#run-about-details > dd", "<s>y</s>")
      assert texts(lv, "#run-about-details > dt") == ["<em>k</em>", "o.<u>x</u>"]
    end
  end

  test "a detail's value wraps in the rail and is never cut; a subject's title is one line" do
    css = File.read!(Path.expand("../../../../assets/css/app.css", __DIR__))

    rule = fn selector ->
      [rule] = Regex.run(~r/#{Regex.escape(selector)} \{([^}]*)\}/, css, capture: :all_but_first)
      rule
    end

    value = rule.(".q-rail-kv-mono.q-rail-about-details dd")

    for declaration <- [
          "overflow: visible;",
          "white-space: normal;",
          "overflow-wrap: break-word;"
        ],
        do: assert(value =~ declaration)

    refute value =~ "ellipsis"

    assert rule.(".q-rail-kv-mono.q-rail-about-details dd.q-rail-json") =~
             "overflow-wrap: anywhere;"

    assert rule.(".q-rail-sub") =~ "text-overflow: ellipsis;"
  end

  describe "the details as rows" do
    test "flatten one level into dotted keys; the rest is compact JSON" do
      assert RunPageComponents.about_details(nil) == []
      assert RunPageComponents.about_details(%{}) == []

      assert RunPageComponents.about_details(%{
               "b" => %{"z" => [1, %{"k" => "v"}], "a" => %{"deep" => %{"deeper" => true}}},
               "a" => "text",
               "n" => 1.5
             }) == [
               {"a", "text", :text},
               {"b.a", ~s({"deep":{"deeper":true}}), :json},
               {"b.z", ~s([1,{"k":"v"}]), :json},
               {"n", "1.5", :json}
             ]
    end
  end

  test "another workspace's run shows none of it", %{conn: conn, scope: scope} do
    theirs = started(scope_fixture(), %{"kind" => "Implementation", "subjects" => [@ticket]})
    {_lv, html} = page(conn, scope, theirs)
    refute html =~ "ENG-17"
  end
end
