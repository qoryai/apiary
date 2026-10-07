defmodule Apiary.Runs.ListingTest do
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Runs
  alias Apiary.Runs.{Filters, Projector}

  @now ~U[2026-09-20 14:00:00.000000Z]

  setup do
    %{scope: scope_fixture(), other: scope_fixture()}
  end

  # A run that started `ago` seconds before @now, with its labels, projected.
  defp started(scope, labels, ago, extra \\ []) do
    run = run_fixture(scope)
    time = DateTime.add(@now, -ago, :second)

    data =
      started_data(
        Map.merge(
          %{"labels" => labels},
          Map.new(Keyword.take(extra, [:runtime, :host]), fn {k, v} -> {to_string(k), v} end)
        )
      )

    event_fixture(run, 2, "run.started", data, time: time)

    for {egress, n} <- Enum.with_index(Keyword.get(extra, :egress, []), 3) do
      event_fixture(run, n, "run.egress", egress_data(egress),
        time: DateTime.add(time, n, :second)
      )
    end

    if exit = extra[:exit],
      do: event_fixture(run, 50, "run.exited", exit, time: DateTime.add(time, 60, :second))

    {:ok, run} = Projector.project(run)
    run
  end

  defp shop(system \\ "github.example"), do: %{"forge" => system, "repository" => "acme/shop"}
  defp parse(params), do: Filters.parse(params, :runs)
  defp ids(runs), do: Enum.map(runs, & &1.id)

  describe "Filters" do
    test "unknown values are dropped and the canonical query leaves the defaults out" do
      filters =
        parse(%{
          "group" => "colour",
          "state" => "failed,bogus,lost,failed",
          "system" => "github.example",
          "target" => "acme/shop",
          "task" => "none",
          "since" => "90d",
          "denials" => "yes",
          "sort" => "loudest",
          "per" => "30",
          "page" => "-3",
          "other" => "x"
        })

      assert filters.states == ["failed", "lost"]
      assert filters.target == {"github.example", "acme/shop"}
      assert filters.task == :none
      assert filters.since == "all"
      assert filters.sort == "newest"
      assert filters.per == 50
      refute filters.denials
      assert filters.page == 1

      assert Filters.to_params(filters) == %{
               "state" => "failed,lost",
               "system" => "github.example",
               "target" => "acme/shop",
               "task" => "none"
             }

      assert Filters.to_params(parse(%{})) == %{}
      assert Filters.to_params(parse(%{"since" => "all"})) == %{}
      refute Filters.any?(parse(%{"sort" => "oldest", "per" => "100", "page" => "2"}))
      assert Filters.any?(parse(%{"since" => "7d"}))
      assert Filters.any?(parse(%{"q" => "checkout"}))
      assert Filters.any?(parse(%{"node" => "build-01"}))
      # The access key is no filter of the runs: an old address's `key` is not read.
      refute Map.has_key?(%Filters{}, :key)
      assert Filters.to_params(parse(%{"key" => "ci-fleet"})) == %{}

      assert Filters.to_params(parse(%{"sort" => "longest", "per" => "100", "q" => " fix "})) ==
               %{"sort" => "longest", "per" => "100", "q" => "fix"}

      # Clearing keeps the order and the page size.
      assert Filters.clear(parse(%{"sort" => "oldest", "per" => "25", "state" => "failed"})) ==
               %{parse(%{}) | sort: "oldest", per: 25}
    end

    test "dates replace the range, are inclusive and are put in order" do
      filters = parse(%{"from" => "2026-09-16", "to" => "2026-09-14", "since" => "1h"})
      assert filters.since == nil
      assert {filters.from, filters.to} == {~D[2026-09-14], ~D[2026-09-16]}

      assert Filters.bounds(filters, @now) ==
               {~U[2026-09-14 00:00:00.000000Z], ~U[2026-09-17 00:00:00.000000Z]}

      assert Filters.range_label(filters) == "14 Sept 2026 to 16 Sept 2026"
      assert parse(%{"from" => "yesterday"}).since == "all"
      assert Filters.bounds(parse(%{}), @now) == {nil, nil}
    end

    test "a refused value is dropped and named, so the page can say so" do
      filters =
        parse(%{
          "runtime" => ["claude"],
          "host" => String.duplicate("a", 1025),
          "task" => "a\0b",
          "state" => "failed,bogus",
          "since" => "90d",
          "page" => "99999999999999999999",
          "from" => "2026-13-45",
          "q" => String.duplicate("q", 257),
          "per" => "7",
          "zzz" => "ignored"
        })

      assert %{filters | dropped: []} == %{parse(%{"state" => "failed"}) | dropped: []}
      assert Enum.sort(filters.dropped) == ~w(from host page per q runtime since state task)
      assert parse(%{"zzz" => "1"}).dropped == []
    end

    test "the states read as three families, and whole families are named as such" do
      assert Enum.map(Filters.families(), & &1.key) == ~w(alive ended_well ended_badly)

      assert Filters.families() |> Enum.flat_map(& &1.states) |> Enum.sort() ==
               Enum.sort(Apiary.Runs.Run.states())

      assert Filters.family_states("ended_badly") == ~w(failed timed_out lost closed)
      assert Filters.family_states("ended") == nil

      assert Filters.families_of(~w(failed timed_out lost closed)) == ["ended_badly"]
      assert Filters.families_of(~w(succeeded running pending)) == ~w(alive ended_well)
      assert Filters.families_of(Apiary.Runs.Run.states()) == ~w(alive ended_well ended_badly)
      assert Filters.families_of(~w(failed lost)) == nil
      assert Filters.families_of(~w(running succeeded)) == nil
      assert Filters.families_of(~w(running succeeded closed)) == nil
      assert Filters.families_of([]) == nil
    end

    test "a family heading in the State section fills its states in, and the URL never names it" do
      on = %{
        "_filter" => "state",
        "_target" => ["family_ended_badly"],
        "family_ended_badly" => "1",
        "state" => ["running"]
      }

      filters = Filters.change(parse(%{"state" => "running"}), on)
      assert filters.states == ~w(running failed timed_out lost closed)
      assert Filters.to_params(filters) == %{"state" => "running,failed,timed_out,lost,closed"}

      # The page's script has already ticked the family's boxes: the same result.
      ticked = %{on | "state" => ~w(running failed timed_out lost closed)}
      assert Filters.change(parse(%{"state" => "running"}), ticked) == filters

      off = %{
        "_filter" => "state",
        "_target" => ["family_ended_badly"],
        "state" => ~w(running failed timed_out lost closed)
      }

      assert Filters.change(filters, off).states == ["running"]

      # Unticking the last family leaves no state, and no `state=`.
      last = %{"_filter" => "state", "_target" => ["family_ended_well"], "state" => ["succeeded"]}
      assert Filters.to_params(Filters.change(parse(%{"state" => "succeeded"}), last)) == %{}

      for f <- [filters, Filters.change(filters, off)], {key, value} <- Filters.to_params(f) do
        refute key =~ "family"
        refute value =~ ~r/family|alive|ended/
      end
    end

    test "the sections that are on or off, the node and the range change the URL alone" do
      f = parse(%{"state" => "failed", "page" => "3"})

      assert Filters.to_params(Filters.change(f, %{"_filter" => "denials", "denials" => "1"})) ==
               %{"state" => "failed", "denials" => "1"}

      assert Filters.change(parse(%{"denials" => "1"}), %{"_filter" => "denials"}).denials ==
               false

      assert Filters.change(f, %{"_filter" => "node", "node" => "build-01"}).node == "build-01"

      assert Filters.change(f, %{"_filter" => "key", "key" => "ci-fleet"}) |> Filters.to_params() ==
               %{"state" => "failed"}

      assert Filters.change(f, %{"_filter" => "since", "since" => "all", "_target" => ["since"]})
             |> Filters.to_params() == %{"state" => "failed"}
    end

    test "what can be stored can be filtered by: 1024 bytes, and no control characters" do
      long = String.duplicate("h", 1024)
      assert parse(%{"host" => long}).host == long
      assert parse(%{"host" => long <> "h"}).host == nil

      for bad <- ["a\0", "a\nb", "\e[0m", "a\x7F", <<255>>] do
        assert %{task: nil, dropped: ["task"]} = parse(%{"task" => bad})
        assert %{q: nil, dropped: ["q"]} = parse(%{"q" => bad})
      end
    end

    test "a target is two parameters, so a system may hold a colon; a path alone is every system's" do
      filters = parse(%{"system" => "git.example:8443", "target" => "acme/shop:v2"})
      assert filters.target == {"git.example:8443", "acme/shop:v2"}

      assert Filters.to_params(filters) == %{
               "system" => "git.example:8443",
               "target" => "acme/shop:v2"
             }

      assert Filters.target_params("git.example:8443", "acme/shop") == %{
               "system" => "git.example:8443",
               "target" => "acme/shop"
             }

      assert Filters.target_params(nil, "acme/shop") == %{"target" => "acme/shop"}
      assert Filters.target_params(nil, nil) == %{"target" => "none"}

      assert parse(%{"target" => "none"}).target == :none
      assert parse(%{"target" => "acme/shop"}).target == {nil, "acme/shop"}
      assert Filters.to_params(parse(%{"target" => "acme/shop"})) == %{"target" => "acme/shop"}
      assert %{target: nil, dropped: ["target"]} = parse(%{"system" => "git.example"})

      # The section's one value reads back to the same pair, whatever it holds.
      value = Filters.target_value({"git.example:8443", ~s(we"ird/pa,th)})
      changed = Filters.change(parse(%{}), %{"_filter" => "target", "target" => value})
      assert changed.target == {"git.example:8443", ~s(we"ird/pa,th)}

      assert Filters.change(parse(%{}), %{"_filter" => "target", "target" => "none"}).target ==
               :none

      every = Filters.target_value({nil, "acme/shop"})

      assert Filters.change(parse(%{}), %{"_filter" => "target", "target" => every}).target ==
               {nil, "acme/shop"}
    end

    test "the workspace's connections are read over at most 90 days, the last fourteen unless set" do
      cx = &Filters.parse(&1, :connections)
      assert %{since: "14d", sort: "denied", dropped: []} = cx.(%{})
      assert Filters.to_params(cx.(%{})) == %{}
      assert %{since: "14d", dropped: ["since"]} = cx.(%{"since" => "all"})
      assert cx.(%{"since" => "90d"}).since == "90d"
      assert cx.(%{"sort" => "recent"}).sort == "recent"
      assert %{sort: "denied", dropped: ["sort"]} = cx.(%{"sort" => "newest"})

      assert {~U[2026-06-22 14:00:00.000000Z], nil} =
               Filters.bounds(cx.(%{"since" => "90d"}), @now)

      wide = cx.(%{"from" => "2020-01-01", "to" => "2026-09-20"})
      assert {wide.from, wide.to} == {~D[2026-06-23], ~D[2026-09-20]}
      assert cx.(%{"from" => "2026-01-01"}).to == ~D[2026-03-31]
      assert parse(%{"from" => "2020-01-01", "to" => "2026-09-20"}).from == ~D[2020-01-01]
    end
  end

  describe "the query" do
    defp query(text, params \\ %{}, opts \\ []),
      do: Filters.apply_query(parse(params), text, opts)

    test "qualifiers set their filters, the other words are the free text" do
      {f, []} =
        query(
          ~s(state:failed,lost repo:acme/shop task:"Fix the build" runtime:claude host:gpu-01 node:build-01 denied:yes checkout totals)
        )

      assert f.states == ~w(failed lost)
      assert f.target == {nil, "acme/shop"}
      assert f.task == "Fix the build"
      assert f.runtime == "claude"
      assert f.host == "gpu-01"
      assert f.node == "build-01"
      assert f.denials
      assert f.q == "checkout totals"
      assert f.page == 1
    end

    test "a qualifier replaces its filter and keeps the others; the free text is what is typed now" do
      {f, []} = query("state:running", %{"state" => "failed", "host" => "a", "q" => "old"})
      assert f.states == ["running"]
      assert f.host == "a"
      assert f.q == nil

      {f, []} = query("", %{"q" => "old", "task" => "t"})
      assert Filters.to_params(f) == %{"task" => "t"}
    end

    test "a state may be a family, words are folded, and the URL says the states" do
      {f, []} = query("state:ended-badly")
      assert f.states == ~w(failed timed_out lost closed)

      {f, []} = query("STATE:Timed-Out,alive")
      assert f.states == ~w(pending running timed_out)
      assert Filters.to_params(f) == %{"state" => "pending,running,timed_out"}
    end

    test "started: a preset, a day, from, up to, and two days" do
      range = fn text ->
        {f, []} = query("started:" <> text)
        {f.since, f.from, f.to}
      end

      assert range.("7d") == {"7d", nil, nil}
      assert range.("2026-09-01") == {nil, ~D[2026-09-01], ~D[2026-09-01]}
      assert range.(">=2026-09-01") == {nil, ~D[2026-09-01], nil}
      assert range.(">2026-09-01") == {nil, ~D[2026-09-02], nil}
      assert range.("<=2026-09-01") == {nil, nil, ~D[2026-09-01]}
      assert range.("<2026-09-01") == {nil, nil, ~D[2026-08-31]}
      assert range.("2026-09-01..2026-09-07") == {nil, ~D[2026-09-01], ~D[2026-09-07]}
      assert range.("2026-09-01..*") == {nil, ~D[2026-09-01], nil}

      # A date replaces a preset, and the other way round.
      {f, []} = Filters.apply_query(parse(%{"since" => "7d"}), "started:>=2026-09-01")
      assert Filters.to_params(f) == %{"from" => "2026-09-01"}
    end

    test "a known qualifier with a value it cannot read is refused and named; an unknown one is text" do
      {f, refused} =
        query("state:bogus started:>tomorrow denied:perhaps host:a\u0000b foo:bar ticket:#12")

      assert refused == ["state:bogus", "started:>tomorrow", "denied:perhaps", "host:a\u0000b"]
      assert f.q == "foo:bar ticket:#12"
      assert f.states == []

      # A qualifier with nothing after it does nothing.
      assert {%{states: []}, []} = query("state:")

      # Free text too long for a query is refused as a whole.
      {f, [refused]} = query(String.duplicate("x", 300))
      assert f.q == nil
      assert String.ends_with?(refused, "…")
    end

    test "repo: is resolved by the page, and none is the runs without a target" do
      resolve = fn "shop" -> {"github.example", "acme/shop"} end

      assert {%{target: {"github.example", "acme/shop"}}, []} =
               query("repo:shop", %{}, resolve: resolve)

      assert {%{target: :none}, []} = query("target:none")
      assert {%{target: {nil, "acme/shop"}}, []} = query("repository:acme/shop")
    end

    test "the connections read their own qualifiers" do
      cx = Filters.parse(%{}, :connections)

      {f, []} =
        Filters.apply_query(cx, "decision:denied tools:yes seen:24h host:registry.example cdn")

      assert f.decision == "denied"
      assert f.tools
      assert f.since == "24h"
      assert f.host == "registry.example"
      assert f.q == "cdn"

      # The runs list's qualifiers are text there, and the range is bounded.
      {f, []} = Filters.apply_query(cx, "state:failed")
      assert f.q == "state:failed"
      assert {_f, ["seen:all"]} = Filters.apply_query(cx, "seen:all")
    end

    test "tokens write the filters back as the query, a view's own left out" do
      f =
        parse(%{
          "state" => "failed,timed_out,lost,closed",
          "system" => "github.example",
          "target" => "acme/shop",
          "task" => "Fix the build",
          "from" => "2026-09-01",
          "denials" => "1",
          "q" => "free"
        })

      tokens = Filters.tokens(f)

      assert Enum.map(tokens, &{&1.key, &1.value}) == [
               {:target, "github.example/acme/shop"},
               {:state, "ended_badly"},
               {:task, ~s("Fix the build")},
               {:started, ">=2026-09-01"},
               {:denied, "yes"}
             ]

      assert Enum.all?(tokens, &(&1.without.page == 1))
      assert hd(tokens).without.target == nil
      assert hd(tokens).without.q == "free"

      assert Filters.tokens(f, except: [:state, :denied], target_text: fn {_s, p} -> p end)
             |> Enum.map(&{&1.key, &1.value}) == [
               {:target, "acme/shop"},
               {:task, ~s("Fix the build")},
               {:started, ">=2026-09-01"}
             ]

      # What a token says reads back to the same filter.
      for token <- tokens, token.key != :target do
        {again, []} = Filters.apply_query(token.without, "#{token.key}:#{token.value}")
        assert Filters.same?(again, %{f | q: nil})
      end
    end
  end

  describe "page_runs/3 and its filters" do
    test "reads the scope's workspace only, newest first, every run unless a range is set", %{
      scope: scope,
      other: other
    } do
      old = started(scope, shop(), 9 * 86_400)
      yesterday = started(scope, shop(), 86_400)
      recent = started(scope, shop(), 120)
      _theirs = started(other, shop(), 60)

      assert %{runs: runs, total: 3, page: 1, per: 50} = Runs.page_runs(scope, parse(%{}), @now)
      assert ids(runs) == [recent.id, yesterday.id, old.id]

      assert %{total: 2} = Runs.page_runs(scope, parse(%{"since" => "7d"}), @now)

      assert %{runs: [only]} =
               Runs.page_runs(scope, parse(%{"from" => "2026-09-11", "to" => "2026-09-11"}), @now)

      assert only.id == old.id
    end

    test "a run that has only pinged is placed by when its ping arrived", %{scope: scope} do
      pending = run_fixture(scope)
      assert %{runs: [run]} = Runs.page_runs(scope, parse(%{}))
      assert run.id == pending.id
    end

    test "state, target, task, runtime, host, node and denials", %{scope: scope} do
      node = Apiary.NodesFixtures.node_fixture(scope, %{name: "build-01"})

      a =
        started(scope, Map.put(shop(), "task", "checkout-tax"), 100,
          egress: [%{"decision" => "denied", "rule" => ""}]
        )

      b =
        started(scope, Map.put(shop("gitlab.example"), "task", "mirror-sync"), 200,
          host: "build-03"
        )

      c =
        started(scope, %{}, 300,
          runtime: "otherrt",
          exit: %{"state" => "failed", "exit_code" => 1}
        )

      Repo.update_all(from(r in Apiary.Runs.Run, where: r.id == ^a.id),
        set: [node_id: node.id]
      )

      by = fn params ->
        Runs.page_runs(scope, parse(params), @now).runs |> ids() |> Enum.sort()
      end

      assert by.(%{"state" => "failed"}) == [c.id]
      assert by.(%{"state" => "running,failed"}) == Enum.sort([a.id, b.id, c.id])
      assert by.(%{"system" => "github.example", "target" => "acme/shop"}) == [a.id]
      assert by.(%{"system" => "gitlab.example", "target" => "acme/shop"}) == [b.id]
      assert by.(%{"target" => "acme/shop"}) == Enum.sort([a.id, b.id])
      assert by.(%{"target" => "none"}) == [c.id]
      assert by.(%{"task" => "mirror-sync"}) == [b.id]
      assert by.(%{"task" => "none"}) == [c.id]
      assert by.(%{"runtime" => "otherrt"}) == [c.id]
      assert by.(%{"host" => "build-03"}) == [b.id]
      assert by.(%{"node" => "build-01"}) == [a.id]
      assert by.(%{"node" => node.public_id}) == [a.id]
      assert by.(%{"node" => "nobody"}) == []
      assert by.(%{"denials" => "1"}) == [a.id]
      assert by.(%{"system" => "github.example", "target" => "nothing/here"}) == []
    end

    test "the free text finds the start of a run's id, its task and its target, as text", %{
      scope: scope
    } do
      a = started(scope, Map.put(shop(), "task", "Fix checkout 100%"), 100)
      b = started(scope, Map.put(shop("gitlab.example"), "task", "mirror-sync"), 200)
      c = started(scope, %{"forge" => "git.example", "repository" => "data/etl"}, 300)

      by = fn q ->
        Runs.page_runs(scope, parse(%{"q" => q}), @now).runs |> ids() |> Enum.sort()
      end

      assert by.("CHECKOUT") == [a.id]
      assert by.("100%") == [a.id]
      assert by.("0%") == [a.id]
      assert by.("%") == [a.id]
      assert by.("gitlab.example/acme") == [b.id]
      assert by.("data/etl") == [c.id]
      assert by.(String.slice(b.run_id, 0, 8)) == [b.id]
      assert by.(String.upcase(String.slice(c.run_id, 0, 6))) == [c.id]
      assert by.("' OR 1=1 --") == []
    end

    test "the orders: newest, oldest, longest, most denials", %{scope: scope} do
      short =
        started(scope, shop(), 300,
          exit: %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1_000}
        )

      long =
        started(scope, shop(), 200,
          exit: %{"state" => "failed", "exit_code" => 1, "duration_ms" => 90_000}
        )

      denied =
        started(scope, shop(), 100,
          egress: [
            %{"decision" => "denied", "rule" => ""},
            %{"decision" => "denied", "rule" => "", "host" => "b.example"}
          ]
        )

      order = fn sort -> Runs.page_runs(scope, parse(%{"sort" => sort}), @now).runs |> ids() end

      assert order.("newest") == [denied.id, long.id, short.id]
      assert order.("oldest") == [short.id, long.id, denied.id]
      assert order.("longest") == [long.id, short.id, denied.id]
      assert order.("denials") == [denied.id, long.id, short.id]
    end

    test "pages of 25, 50 or 100 keep the total, and a page past the end is the last", %{
      scope: scope
    } do
      for _ <- 1..52, do: run_fixture(scope)

      assert %{runs: runs, total: 52, pages: 2, page: 1} = Runs.page_runs(scope, parse(%{}))
      assert length(runs) == 50
      assert %{runs: [_, _], page: 2} = Runs.page_runs(scope, parse(%{"page" => "2"}))
      assert %{runs: [_, _], page: 2} = Runs.page_runs(scope, parse(%{"page" => "9"}))
      assert %{pages: 3, per: 25} = Runs.page_runs(scope, parse(%{"per" => "25"}))
      assert %{pages: 1, runs: all} = Runs.page_runs(scope, parse(%{"per" => "100"}))
      assert length(all) == 52
    end

    test "jump to a date: the page of the first run started on or before that day", %{
      scope: scope
    } do
      # One run a day at noon, for sixty days back from @now's day.
      for day <- 0..59 do
        at = DateTime.new!(Date.add(~D[2026-09-20], -day), ~T[12:00:00.000000], "Etc/UTC")
        run_fixture(scope, %{state: "succeeded", started_at: at})
      end

      newest = parse(%{"per" => "25"})
      # 20 Sept to 14 Sept are the first seven runs: the eighth, 13 Sept, is on page 1.
      assert Runs.jump_page(scope, newest, ~D[2026-09-13], @now) == 1
      # 26 runs start after 25 Aug: the 27th is on page 2.
      assert Runs.jump_page(scope, newest, ~D[2026-08-25], @now) == 2
      assert Runs.jump_page(scope, newest, ~D[2026-10-01], @now) == 1
      assert Runs.jump_page(scope, newest, ~D[2020-01-01], @now) == 3

      oldest = parse(%{"per" => "25", "sort" => "oldest"})
      # Oldest first, the page of the first run on or after the day: 23 Jul is the first,
      # and 25 runs start before 17 Aug.
      assert Runs.jump_page(scope, oldest, ~D[2026-07-22], @now) == 1
      assert Runs.jump_page(scope, oldest, ~D[2026-08-16], @now) == 1
      assert Runs.jump_page(scope, oldest, ~D[2026-08-17], @now) == 2
      assert Runs.jump_page(scope, parse(%{"sort" => "longest"}), ~D[2026-08-16], @now) == 1
    end
  end

  describe "the page is read from its index" do
    test "page_runs orders and ranges by the expression index, without a sort", %{scope: scope} do
      %{organisation: organisation, workspace: workspace} = scope

      rows =
        for n <- 1..4000 do
          at = DateTime.add(@now, -n * 60, :second)

          %{
            id: Ecto.UUID.generate(),
            run_id: Ecto.UUID.generate(),
            organisation_id: organisation.id,
            workspace_id: workspace.id,
            state: "succeeded",
            # Every third run has only pinged: it is placed by inserted_at.
            started_at: if(rem(n, 3) == 0, do: nil, else: at),
            inserted_at: at,
            updated_at: at
          }
        end

      for chunk <- Enum.chunk_every(rows, 1000), do: Repo.insert_all(Apiary.Runs.Run, chunk)
      Repo.query!("ANALYZE runs")

      plan =
        Ecto.Adapters.SQL.explain(Repo, :all, Runs.page_runs_query(scope, parse(%{}), @now))

      assert plan =~ "runs_workspace_id_started_or_first_heard_index"
      refute plan =~ "Sort"

      # And it is the same page a sort would give.
      %{runs: runs} = Runs.page_runs(scope, parse(%{}), @now)
      assert length(runs) == 50
      times = Enum.map(runs, &(&1.started_at || &1.inserted_at))
      assert times == Enum.sort(times, {:desc, DateTime})
    end
  end

  describe "views, the rail and facets" do
    setup %{scope: scope, other: other} do
      runs = %{
        shop:
          started(scope, Map.put(shop(), "task", "checkout-tax"), 100,
            egress: [
              %{"decision" => "denied", "rule" => ""},
              %{"decision" => "denied", "rule" => "", "host" => "b.example"}
            ]
          ),
        shop_old:
          started(scope, Map.put(shop(), "task", "fix-cart"), 5000,
            exit: %{"state" => "succeeded", "exit_code" => 0}
          ),
        gitlab: started(scope, Map.put(shop("gitlab.example"), "task", "checkout-tax"), 50),
        api:
          started(scope, %{"forge" => "github.example", "repository" => "acme/api"}, 70,
            exit: %{"state" => "failed", "exit_code" => 1}
          ),
        plain: started(scope, %{}, 10)
      }

      started(other, shop(), 10)
      %{runs: runs}
    end

    test "the views count under the other filters, never the states or denials", %{scope: scope} do
      counts = %{all: 5, alive: 3, ended_badly: 1, with_denials: 1}
      assert Runs.view_counts(scope, parse(%{}), @now) == counts

      assert Runs.view_counts(scope, parse(%{"state" => "failed", "denials" => "1"}), @now) ==
               counts

      assert Runs.view_counts(scope, parse(%{"task" => "checkout-tax"}), @now) ==
               %{all: 2, alive: 2, ended_badly: 0, with_denials: 1}

      assert Runs.count_runs(scope) == 5
      assert Runs.count_runs(scope, parse(%{"state" => "failed"}), @now) == 1
    end

    test "the rail counts the targets under every filter but the target, pinned first", %{
      scope: scope
    } do
      filters = parse(%{"system" => "github.example", "target" => "acme/shop"})
      rail = Runs.target_counts(scope, filters, now: @now)

      assert rail.all == 5
      assert rail.unassigned == 1
      assert rail.pinned == []
      assert rail.more == 0

      assert rail.targets == [
               %{system: "github.example", path: "acme/shop", runs: 2},
               %{system: "github.example", path: "acme/api", runs: 1},
               %{system: "gitlab.example", path: "acme/shop", runs: 1}
             ]

      pinned =
        Runs.target_counts(scope, parse(%{"state" => "running"}),
          now: @now,
          pinned: [{"gitlab.example", "acme/shop"}, {"github.example", "acme/api"}],
          limit: 1
        )

      assert pinned.pinned == [
               %{system: "gitlab.example", path: "acme/shop", runs: 1},
               %{system: "github.example", path: "acme/api", runs: 0}
             ]

      assert pinned.targets == [%{system: "github.example", path: "acme/shop", runs: 1}]
      assert pinned.more == 0

      more = Runs.target_counts(scope, parse(%{}), now: @now, limit: 1)
      assert [%{path: "acme/shop", runs: 2}] = more.targets
      assert more.more == 2

      # A search lists every target that holds it, pinned or not, as text.
      found =
        Runs.target_counts(scope, parse(%{}),
          now: @now,
          narrow: "GITLAB",
          pinned: [{"gitlab.example", "acme/shop"}]
        )

      assert found.pinned == []
      assert found.targets == [%{system: "gitlab.example", path: "acme/shop", runs: 1}]
      assert Runs.target_counts(scope, parse(%{}), now: @now, narrow: "%").targets == []
    end

    test "a path on two systems is written with its system; repo: finds it", %{scope: scope} do
      assert Runs.shared_paths(scope) == MapSet.new(["acme/shop"])

      assert Runs.resolve_target(scope, "acme/api") == {"github.example", "acme/api"}
      assert Runs.resolve_target(scope, "ACME/API") == {"github.example", "acme/api"}
      assert Runs.resolve_target(scope, "acme/shop") == {nil, "acme/shop"}

      assert Runs.resolve_target(scope, "gitlab.example/acme/shop") ==
               {"gitlab.example", "acme/shop"}

      assert Runs.resolve_target(scope, "nothing/here") == {nil, "nothing/here"}
      assert Runs.resolve_target(scope_fixture(), "acme/api") == {nil, "acme/api"}
    end

    test "facets are counted from the data, each under the other filters", %{scope: scope} do
      facets = Runs.run_facets(scope, parse(%{"state" => "running"}), now: @now)

      assert facets.state.options == [
               {"running", "running", 3},
               {"succeeded", "succeeded", 1},
               {"failed", "failed", 1}
             ]

      assert facets.target == %{
               options: [
                 {"github.example/acme/shop",
                  Filters.target_value({"github.example", "acme/shop"}), 1},
                 {"gitlab.example/acme/shop",
                  Filters.target_value({"gitlab.example", "acme/shop"}), 1},
                 {"Unassigned", "none", 1}
               ],
               total: 3
             }

      assert facets.task.options == [{"checkout-tax", "checkout-tax", 2}, {"No task", "none", 1}]
      assert facets.runtime.options == [{"claude", "claude", 3}]
      assert facets.host == %{options: [{"dev-laptop", "dev-laptop", 3}], total: 1}
      assert facets.node == %{options: [], total: 0}
    end

    test "a facet holds the fifty most frequent values and the chosen one, more when asked, and narrows as text",
         %{scope: scope} do
      for n <- 1..55,
          do: run_fixture(scope, %{state: "running", task: "task-#{n}", started_at: @now})

      run_fixture(scope, %{state: "running", task: "100%_done", started_at: @now})
      run_fixture(scope, %{state: "running", task: "100x-done", started_at: @now})

      facets = Runs.run_facets(scope, parse(%{"task" => "task-55"}), now: @now)
      assert facets.task.total == 60
      assert length(facets.task.options) == 52
      assert {"task-55", "task-55", 1} == hd(facets.task.options)
      assert {"No task", "none", 2} == List.last(facets.task.options)

      more = Runs.run_facets(scope, parse(%{}), now: @now, limits: %{"task" => 100}).task
      assert length(more.options) == 60

      narrowed = fn q ->
        Runs.run_facets(scope, parse(%{}), now: @now, narrow: %{"task" => q}).task
      end

      assert Enum.map(narrowed.("TASK-5").options, &elem(&1, 0)) ==
               ~w(task-5 task-50 task-51 task-52 task-53 task-54 task-55)

      # The pattern's own characters are text: "%" and "_" find themselves only.
      assert narrowed.("%").options == [{"100%_done", "100%_done", 1}]
      assert narrowed.("0%_d").options == [{"100%_done", "100%_done", 1}]
      assert narrowed.("_").options == [{"100%_done", "100%_done", 1}]
      assert narrowed.("\\").options == []
      assert narrowed.("' OR 1=1 --").options == []
      assert narrowed.(<<0>>).total == 60
      assert Runs.like("50%_\\") == "%50\\%\\_\\\\%"
    end

    test "the nodes are a facet: one in use by its name, a deleted one by its id", %{
      scope: scope,
      runs: runs
    } do
      node = Apiary.NodesFixtures.node_fixture(scope, %{name: "build-01"})
      pool = Apiary.NodesFixtures.pool_fixture(scope, %{name: "spot-runners"})

      Repo.update_all(from(r in Apiary.Runs.Run, where: r.id in ^[runs.shop.id, runs.api.id]),
        set: [node_id: node.id]
      )

      Repo.update_all(from(r in Apiary.Runs.Run, where: r.id == ^runs.gitlab.id),
        set: [node_id: pool.id]
      )

      facets = fn params, opts ->
        Runs.run_facets(scope, parse(params), [now: @now] ++ opts).node
      end

      assert facets.(%{}, []) ==
               %{
                 options: [{"build-01", "build-01", 2}, {"spot-runners", "spot-runners", 1}],
                 total: 2
               }

      # Chosen by its id, as a node's page links, the node's own option is checked.
      assert {"build-01", node.public_id, 2} in facets.(%{"node" => node.public_id}, []).options

      # A value the data no longer offers still shows.
      assert hd(facets.(%{"node" => "gone"}, []).options) == {"gone", "gone", 0}

      assert facets.(%{}, narrow: %{"node" => "BUILD"}).options == [{"build-01", "build-01", 2}]

      assert facets.(%{}, narrow: %{"node" => "spot"}).options == [
               {"spot-runners", "spot-runners", 1}
             ]

      # A deleted node keeps its runs, offered by its id under its name, marked deleted.
      {:ok, _deleted} = Apiary.Nodes.delete_node(scope, node)

      assert {"build-01 (deleted)", node.public_id, 2} in facets.(%{}, []).options
    end

    test "matches?/4 tells whether a changed run belongs to the view", %{
      scope: scope,
      other: other,
      runs: runs
    } do
      assert Runs.matches?(scope, parse(%{"task" => "checkout-tax"}), runs.shop, @now)
      refute Runs.matches?(scope, parse(%{"task" => "fix-cart"}), runs.shop, @now)
      refute Runs.matches?(other, parse(%{}), runs.shop, @now)
    end
  end

  describe "the end of a run's log" do
    test "the last lines as plain text, read from the end of the chunks", %{scope: scope} do
      run = run_fixture(scope)

      chunks = [
        "\e]0;title\a\e[1;32m✓\e[0m first\r\n",
        "progress 10%\rprogress 100%\n\e[2Kdone\n",
        "tab\there\n\n\n"
      ]

      for {bytes, n} <- Enum.with_index(chunks, 2) do
        event_fixture(run, n, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64(bytes)})
      end

      {:ok, run} = Projector.project(run)

      assert Apiary.Runs.Record.log_tail(scope, run) ==
               ["✓ first", "progress 100%", "done", "tab\there"]

      assert Apiary.Runs.Record.log_tail(scope, run, 2) == ["done", "tab\there"]
      assert Apiary.Runs.Record.log_tail(other_scope(scope), run) == []
      assert Apiary.Runs.Record.log_tail(scope, run_fixture(scope)) == []
    end

    test "bytes that are not text are replaced, and control characters go" do
      assert Apiary.Runs.Record.plain_lines(<<"a", 255, "b\e[31mc\x07\x00d\n">>) == ["a�bcd"]
      assert Apiary.Runs.Record.plain_lines("") == []
    end
  end

  # A scope of another workspace of the same organisation.
  defp other_scope(scope) do
    %{scope | workspace: %{scope.workspace | id: Ecto.UUID.generate()}}
  end

  describe "get_run_by_run_id!/2" do
    test "by the subject, in the scope's workspace only; a malformed id is not found", %{
      scope: scope,
      other: other
    } do
      run = run_fixture(scope)
      assert Runs.get_run_by_run_id!(scope, run.run_id).id == run.id
      assert_raise Ecto.NoResultsError, fn -> Runs.get_run_by_run_id!(other, run.run_id) end
      assert_raise Ecto.NoResultsError, fn -> Runs.get_run_by_run_id!(scope, run.id) end
      assert_raise Ecto.NoResultsError, fn -> Runs.get_run_by_run_id!(scope, "not-a-uuid") end
    end
  end

  describe "the workspace's destinations" do
    setup %{scope: scope, other: other} do
      denied = %{
        "host" => "files.cdn.example",
        "decision" => "denied",
        "rule" => "",
        "outcome" => "refused"
      }

      registry = %{"host" => "registry.example", "rule" => "registry.example"}

      a =
        started(scope, Map.put(shop(), "task", "checkout-tax"), 1000,
          egress: [registry, denied, denied]
        )

      b =
        started(scope, shop("gitlab.example"), 500,
          egress: [
            registry,
            Map.merge(registry, %{"decision" => "denied", "outcome" => "refused"}),
            registry
          ]
        )

      started(other, shop(), 100, egress: [denied])
      %{a: a, b: b}
    end

    defp cx(params), do: Filters.parse(params, :connections)

    test "one row per destination across runs, denied first, the last attempt's reason", %{
      scope: scope
    } do
      assert %{rows: [cdn, registry], summary: summary, page: 1} =
               Runs.page_destinations(scope, cx(%{}), @now)

      assert %{
               host: "files.cdn.example",
               port: 443,
               path: "",
               runs: 1,
               attempts: 2,
               allowed: 0,
               denied: 2,
               last_decision: "denied",
               last_mode: "enforce"
             } = cdn

      assert %{
               host: "registry.example",
               runs: 2,
               attempts: 4,
               allowed: 3,
               denied: 1,
               last_decision: "allowed",
               last_rule: "registry.example"
             } = registry

      assert summary == %{destinations: 2, denied: 2, attempts: 6, runs: 2}
    end

    test "the page and its totals come from one pass; a page past the end is the last", %{
      scope: scope
    } do
      egress = for n <- 1..55, do: %{"host" => "h#{n}.example", "rule" => "*.example"}
      started(scope, shop(), 100, egress: egress)

      assert %{
               rows: rows,
               page: 1,
               pages: 2,
               summary: %{destinations: 57, denied: 2, attempts: 61}
             } =
               Runs.page_destinations(scope, cx(%{}), @now)

      assert length(rows) == 50

      for page <- ["2", "9"] do
        assert %{rows: rest, page: 2, pages: 2, summary: %{destinations: 57}} =
                 Runs.page_destinations(scope, cx(%{"page" => page}), @now)

        assert length(rest) == 7
      end

      assert %{
               rows: [],
               page: 1,
               pages: 1,
               summary: %{destinations: 0, denied: 0, attempts: 0, runs: 0}
             } =
               Runs.page_destinations(
                 scope,
                 cx(%{"host" => "nowhere.example", "page" => "3"}),
                 @now
               )
    end

    test "filters: decision, target, host and the range", %{scope: scope} do
      hosts = fn params ->
        Runs.page_destinations(scope, cx(params), @now).rows |> Enum.map(& &1.host)
      end

      assert hosts.(%{"decision" => "allowed"}) == ["registry.example"]
      assert hosts.(%{"decision" => "denied"}) == ["files.cdn.example", "registry.example"]

      assert hosts.(%{"system" => "gitlab.example", "target" => "acme/shop"}) == [
               "registry.example"
             ]

      assert hosts.(%{"host" => "files.cdn.example"}) == ["files.cdn.example"]
      assert hosts.(%{"since" => "90d"}) == ["files.cdn.example", "registry.example"]
      assert hosts.(%{"since" => "1h"}) == ["files.cdn.example", "registry.example"]
      assert hosts.(%{"from" => "2026-01-01", "to" => "2026-01-02"}) == []
    end

    test "a tool invocation is a destination with its tool and answer; tools=1 keeps those",
         %{scope: scope} do
      call = tool_invocation_data(%{})
      started(scope, shop(), 300, egress: [call, Map.put(call, "status", 404)])

      assert %{rows: rows} = Runs.page_destinations(scope, cx(%{}), @now)

      assert %{runs: 1, attempts: 2, last_tool: "files", last_status: 404} =
               Enum.find(rows, &(&1.host == "files.tools.internal"))

      assert %{last_tool: nil, last_status: nil} =
               Enum.find(rows, &(&1.host == "registry.example"))

      assert %Filters{tools: true} = filters = cx(%{"tools" => "1"})
      assert Filters.to_params(filters) == %{"tools" => "1"}
      assert Filters.any?(filters)
      assert %Filters{tools: false, dropped: ["tools"]} = cx(%{"tools" => "yes"})

      assert %{rows: [%{host: "files.tools.internal"}], summary: %{destinations: 1, runs: 1}} =
               Runs.page_destinations(scope, filters, @now)
    end

    test "across runs, the tool and the answer are those of the most recently seen run", %{
      scope: scope
    } do
      call = tool_invocation_data(%{})
      # Seen 300 seconds ago, answered 500; then 100 seconds ago, answered 201.
      started(scope, shop(), 300, egress: [Map.put(call, "status", 500)])
      started(scope, shop(), 100, egress: [Map.put(call, "status", 201)])

      assert %{rows: rows} = Runs.page_destinations(scope, cx(%{}), @now)

      assert %{runs: 2, attempts: 2, last_tool: "files", last_status: 201} =
               Enum.find(rows, &(&1.host == "files.tools.internal"))
    end

    test "tools=1 keeps a destination whole: its counts are those without the filter", %{
      scope: scope
    } do
      call = tool_invocation_data(%{})
      # One run's last attempt was handed to the tool, another's to the same destination
      # was not.
      started(scope, shop(), 300, egress: [Map.drop(call, ["tool", "status"])])
      started(scope, shop(), 200, egress: [call, call])

      find = fn filters ->
        %{rows: rows, summary: summary} = Runs.page_destinations(scope, cx(filters), @now)
        {Enum.find(rows, &(&1.host == "files.tools.internal")), summary}
      end

      {all, _} = find.(%{})
      {tools, summary} = find.(%{"tools" => "1"})

      assert %{runs: 2, attempts: 3} = all

      assert Map.take(tools, [:runs, :attempts, :allowed, :denied, :last_tool]) ==
               Map.take(all, [:runs, :attempts, :allowed, :denied, :last_tool])

      assert summary == %{destinations: 1, denied: 0, attempts: 3, runs: 2}
    end

    test "tools=1 keeps only tool invocations: a request a path rule refused is none", %{
      scope: scope
    } do
      call = tool_invocation_data(%{})

      refused =
        tool_invocation_data(%{
          "path" => "/media/acme/other/checkout.png",
          "path_rule" => "",
          "decision" => "denied",
          "outcome" => "refused"
        })
        |> Map.delete("status")

      started(scope, shop(), 300, egress: [call, refused])

      # The refused request keeps the tool whose host it was for.
      assert %{rows: rows} = Runs.page_destinations(scope, cx(%{}), @now)

      assert %{last_tool: "files", last_decision: "denied"} =
               Enum.find(rows, &(&1.path == "/media/acme/other/checkout.png"))

      assert %{rows: [%{path: "/media/acme/shop/checkout.png"}], summary: %{destinations: 1}} =
               Runs.page_destinations(scope, cx(%{"tools" => "1"}), @now)
    end

    test "tool_invocation?/2 is a request that names a tool and was allowed" do
      assert Runs.tool_invocation?("files", "allowed")
      refute Runs.tool_invocation?("files", "denied")
      refute Runs.tool_invocation?(nil, "allowed")
      refute Runs.tool_invocation?("", "allowed")
      refute Runs.tool_invocation?("files", nil)
    end

    test "the runs that reached a destination, the most recent first, paged", %{
      scope: scope,
      other: other,
      a: a,
      b: b
    } do
      assert %{runs: [first, second], total: 2} =
               Runs.destination_runs(scope, cx(%{}), {"registry.example", 443, ""}, now: @now)

      assert {first.run.id, first.allowed, first.denied} == {b.id, 2, 1}
      assert {second.run.id, second.allowed, second.denied} == {a.id, 1, 0}

      assert %{runs: [_one], total: 2} =
               Runs.destination_runs(scope, cx(%{}), {"registry.example", 443, ""},
                 now: @now,
                 limit: 1
               )

      assert %{runs: [], total: 0} =
               Runs.destination_runs(other, cx(%{}), {"registry.example", 443, ""}, now: @now)
    end

    test "the window is a token, seen:14d by default; taking it away leaves the widest" do
      default = cx(%{})
      assert [%{key: :started, value: "14d", without: wide}] = Filters.tokens(default)
      assert wide.since == "90d"
      assert Filters.to_params(wide) == %{"since" => "90d"}
      refute Filters.any_range?(default)
      assert Filters.any_range?(wide)

      # The widest window is said, and cannot be taken away.
      assert [%{key: :started, value: "90d", without: nil}] = Filters.tokens(wide)

      # The runs list's every run is no token.
      assert Filters.tokens(parse(%{})) == []
    end

    test "Denied first: the most denied attempts first, then the most recently seen", %{
      scope: scope
    } do
      denied = &%{"host" => &1, "decision" => "denied", "rule" => "", "outcome" => "refused"}
      # One attempt, seen last; five attempts, seen earlier; three, seen in between.
      started(scope, shop(), 50, egress: [denied.("once.example")])
      started(scope, shop(), 900, egress: List.duplicate(denied.("noisy.example"), 5))
      started(scope, shop(), 400, egress: List.duplicate(denied.("middle.example"), 3))

      hosts = Runs.page_destinations(scope, cx(%{}), @now).rows |> Enum.map(& &1.host)

      assert hosts == [
               "noisy.example",
               "middle.example",
               "files.cdn.example",
               "once.example",
               "registry.example"
             ]
    end

    test "the rail counts each target's destinations, as the views count", %{scope: scope} do
      rail =
        Runs.destination_target_counts(scope, cx(%{}),
          now: @now,
          pinned: [{"gitlab.example", "acme/shop"}]
        )

      assert rail.all == 2
      assert rail.pinned == [%{system: "gitlab.example", path: "acme/shop", runs: 1}]
      assert rail.targets == [%{system: "github.example", path: "acme/shop", runs: 2}]
    end

    test "facets of the page", %{scope: scope} do
      facets = Runs.destination_facets(scope, cx(%{}), now: @now)
      assert {"registry.example", "registry.example", 2} in facets.host.options

      # A target counts the destinations its runs reached, as the rail does.
      assert {"github.example/acme/shop", Filters.target_value({"github.example", "acme/shop"}),
              2} in facets.target.options

      narrowed =
        Runs.destination_facets(scope, cx(%{}),
          now: @now,
          narrow: %{"host" => "CDN", "target" => "gitlab"}
        )

      assert narrowed.host.options == [{"files.cdn.example", "files.cdn.example", 1}]
      assert [{"gitlab.example/acme/shop", _, 1}] = narrowed.target.options
    end
  end

  test "a change of a run is announced on the touched topic", %{scope: scope} do
    Runs.subscribe_touched(scope)
    run = run_fixture(scope)
    workspace_id = run.workspace_id
    Runs.broadcast_changed(run)
    assert_receive {:runs_touched, ^workspace_id}
  end
end
