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
          "page" => "-3",
          "other" => "x"
        })

      assert filters.group == "target"
      assert filters.states == ["failed", "lost"]
      assert filters.target == {"github.example", "acme/shop"}
      assert filters.task == :none
      assert filters.since == "7d"
      refute filters.denials
      assert filters.page == 1

      assert Filters.to_params(filters) == %{
               "state" => "failed,lost",
               "system" => "github.example",
               "target" => "acme/shop",
               "task" => "none"
             }

      assert Filters.to_params(parse(%{})) == %{}
      refute Filters.any?(parse(%{"group" => "task", "page" => "2"}))
      assert Filters.any?(parse(%{"since" => "all"}))
    end

    test "dates replace the range, are inclusive and are put in order" do
      filters = parse(%{"from" => "2026-09-16", "to" => "2026-09-14", "since" => "1h"})
      assert filters.since == nil
      assert {filters.from, filters.to} == {~D[2026-09-14], ~D[2026-09-16]}

      assert Filters.bounds(filters, @now) ==
               {~U[2026-09-14 00:00:00.000000Z], ~U[2026-09-17 00:00:00.000000Z]}

      assert Filters.range_label(filters) == "14 Sep 2026 to 16 Sep 2026"
      assert parse(%{"from" => "yesterday"}).since == "7d"
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
          "zzz" => "ignored"
        })

      assert %{filters | dropped: []} == %{parse(%{"state" => "failed"}) | dropped: []}
      assert Enum.sort(filters.dropped) == ~w(from host page runtime since state task)
      assert parse(%{"zzz" => "1"}).dropped == []
    end

    test "the state's former name in a shared link is read as the state, and canonicalised" do
      filters = parse(%{"state" => "exited,failed,succeeded"})

      assert filters.states == ["succeeded", "failed"]
      assert filters.dropped == []
      assert Filters.to_params(filters) == %{"state" => "succeeded,failed"}
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

    test "a family heading in the State menu fills its states in, and the URL never names it" do
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

    test "what can be stored can be filtered by: 1024 bytes, and no control characters" do
      long = String.duplicate("h", 1024)
      assert parse(%{"host" => long}).host == long
      assert parse(%{"host" => long <> "h"}).host == nil

      for bad <- ["a\0", "a\nb", "\e[0m", "a\x7F", <<255>>] do
        assert %{task: nil, dropped: ["task"]} = parse(%{"task" => bad})
      end
    end

    test "a target is two parameters, so a system may hold a colon" do
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

      assert Filters.target_params(nil, nil) == %{"target" => "none"}

      assert parse(%{"target" => "none"}).target == :none
      assert %{target: nil, dropped: ["target"]} = parse(%{"target" => "acme/shop"})
      assert %{target: nil, dropped: ["target"]} = parse(%{"system" => "git.example"})

      # The menu's one value reads back to the same pair, whatever it holds.
      value = Filters.target_value({"git.example:8443", ~s(we"ird/pa,th)})
      changed = Filters.change(parse(%{}), %{"_filter" => "target", "target" => value})
      assert changed.target == {"git.example:8443", ~s(we"ird/pa,th)}

      assert Filters.change(parse(%{}), %{"_filter" => "target", "target" => "none"}).target ==
               :none
    end

    test "the hive's connections are read over at most 90 days" do
      cx = &Filters.parse(&1, :connections)
      assert %{since: "7d", dropped: ["since"]} = cx.(%{"since" => "all"})
      assert cx.(%{"since" => "90d"}).since == "90d"

      assert {~U[2026-06-22 14:00:00.000000Z], nil} =
               Filters.bounds(cx.(%{"since" => "90d"}), @now)

      wide = cx.(%{"from" => "2020-01-01", "to" => "2026-09-20"})
      assert {wide.from, wide.to} == {~D[2026-06-23], ~D[2026-09-20]}
      assert cx.(%{"from" => "2026-01-01"}).to == ~D[2026-03-31]
      assert parse(%{"from" => "2020-01-01", "to" => "2026-09-20"}).from == ~D[2020-01-01]
    end
  end

  describe "page_runs/3 and its filters" do
    test "reads the scope's hive only, newest first, within the range", %{
      scope: scope,
      other: other
    } do
      old = started(scope, shop(), 9 * 86_400)
      yesterday = started(scope, shop(), 86_400)
      recent = started(scope, shop(), 120)
      _theirs = started(other, shop(), 60)

      assert %{runs: runs, total: 2, page: 1} = Runs.page_runs(scope, parse(%{}), @now)
      assert ids(runs) == [recent.id, yesterday.id]

      assert %{total: 3} = Runs.page_runs(scope, parse(%{"since" => "all"}), @now)

      assert %{runs: [only]} =
               Runs.page_runs(scope, parse(%{"from" => "2026-09-11", "to" => "2026-09-11"}), @now)

      assert only.id == old.id
    end

    test "a run that has only pinged is placed by when its ping arrived", %{scope: scope} do
      pending = run_fixture(scope)
      assert %{runs: [run]} = Runs.page_runs(scope, parse(%{}))
      assert run.id == pending.id
    end

    test "state, target, task, runtime, host and denials", %{scope: scope} do
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

      by = fn params ->
        Runs.page_runs(scope, parse(params), @now).runs |> ids() |> Enum.sort()
      end

      assert by.(%{"state" => "failed"}) == [c.id]
      assert by.(%{"state" => "running,failed"}) == Enum.sort([a.id, b.id, c.id])
      assert by.(%{"system" => "github.example", "target" => "acme/shop"}) == [a.id]
      assert by.(%{"system" => "gitlab.example", "target" => "acme/shop"}) == [b.id]
      assert by.(%{"target" => "none"}) == [c.id]
      assert by.(%{"task" => "mirror-sync"}) == [b.id]
      assert by.(%{"task" => "none"}) == [c.id]
      assert by.(%{"runtime" => "otherrt"}) == [c.id]
      assert by.(%{"host" => "build-03"}) == [b.id]
      assert by.(%{"denials" => "1"}) == [a.id]
      assert by.(%{"system" => "github.example", "target" => "nothing/here"}) == []
    end

    test "pages of fifty keep the total, and a page past the end is the last", %{scope: scope} do
      for _ <- 1..52, do: run_fixture(scope)

      assert %{runs: runs, total: 52, pages: 2, page: 1} = Runs.page_runs(scope, parse(%{}))
      assert length(runs) == 50
      assert %{runs: [_, _], page: 2} = Runs.page_runs(scope, parse(%{"page" => "2"}))
      assert %{runs: [_, _], page: 2} = Runs.page_runs(scope, parse(%{"page" => "9"}))
    end
  end

  describe "the page is read from its index" do
    test "page_runs orders and ranges by the expression index, without a sort", %{scope: scope} do
      %{organisation: organisation, hive: hive} = scope

      rows =
        for n <- 1..4000 do
          at = DateTime.add(@now, -n * 60, :second)

          %{
            id: Ecto.UUID.generate(),
            run_id: Ecto.UUID.generate(),
            organisation_id: organisation.id,
            hive_id: hive.id,
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

      assert plan =~ "runs_hive_id_started_or_first_heard_index"
      refute plan =~ "Sort"

      # And it is the same page a sort would give.
      %{runs: runs} = Runs.page_runs(scope, parse(%{}), @now)
      assert length(runs) == 50
      times = Enum.map(runs, &(&1.started_at || &1.inserted_at))
      assert times == Enum.sort(times, {:desc, DateTime})
    end
  end

  describe "groups, summary and facets" do
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
        plain: started(scope, %{}, 10)
      }

      started(other, shop(), 10)
      %{runs: runs}
    end

    test "two systems with one path are two groups, the unassigned group is last", %{
      scope: scope,
      runs: runs
    } do
      filters = parse(%{})
      page = Runs.page_runs(scope, filters, @now)
      groups = Runs.group_runs(page.runs, "target")

      assert Enum.map(groups, & &1.key) == [
               {"gitlab.example", "acme/shop"},
               {"github.example", "acme/shop"},
               :none
             ]

      assert Enum.map(groups, & &1.kind) == [:target, :target, :unassigned]
      assert ids(Enum.at(groups, 1).runs) == [runs.shop.id, runs.shop_old.id]

      keys = Enum.map(groups, & &1.key)
      facts = Runs.group_facts(scope, filters, keys, @now)

      # Only the groups asked for are counted.
      assert Map.keys(Runs.group_facts(scope, filters, [:none], @now)) == [:none]
      assert Runs.group_facts(scope, filters, [], @now) == %{}
      assert facts[{"github.example", "acme/shop"}] == %{runs: 2, alive: 1, denials: 2}
      assert facts[{"gitlab.example", "acme/shop"}] == %{runs: 1, alive: 1, denials: 0}
      assert facts[:none] == %{runs: 1, alive: 1, denials: 0}
    end

    test "grouped by task, one task spans targets", %{scope: scope, runs: runs} do
      filters = parse(%{"group" => "task"})
      groups = Runs.group_runs(Runs.page_runs(scope, filters, @now).runs, "task")

      assert Enum.map(groups, & &1.key) == ["checkout-tax", "fix-cart", :none]
      assert ids(hd(groups).runs) == [runs.gitlab.id, runs.shop.id]

      assert Runs.group_facts(scope, filters, ["checkout-tax"], @now)["checkout-tax"] == %{
               runs: 2,
               alive: 2,
               denials: 2,
               targets: 2
             }

      assert [%{kind: :none, runs: all}] =
               Runs.group_runs(Runs.page_runs(scope, filters, @now).runs, "none")

      assert length(all) == 4
    end

    test "the summary counts what the filters return, and what they hide", %{scope: scope} do
      assert Runs.summarise_runs(scope, parse(%{}), @now) ==
               %{
                 runs: 4,
                 targets: 2,
                 tasks: 2,
                 alive: 3,
                 ended_well: 1,
                 ended_badly: 0,
                 with_denials: 1,
                 hive_runs: 4
               }

      assert %{runs: 1, hive_runs: 4} =
               Runs.summarise_runs(scope, parse(%{"state" => "succeeded"}), @now)
    end

    test "facets are counted from the data, each under the other filters", %{scope: scope} do
      facets = Runs.run_facets(scope, parse(%{"state" => "running"}), now: @now)

      assert facets.state.options == [{"running", "running", 3}, {"succeeded", "succeeded", 1}]

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
    end

    test "a facet holds the fifty most frequent values and the chosen one, and narrows as text",
         %{scope: scope} do
      for n <- 1..55,
          do: run_fixture(scope, %{state: "running", task: "task-#{n}", started_at: @now})

      run_fixture(scope, %{state: "running", task: "100%_done", started_at: @now})
      run_fixture(scope, %{state: "running", task: "100x-done", started_at: @now})

      facets = Runs.run_facets(scope, parse(%{"task" => "task-55"}), now: @now)
      assert facets.task.total == 60
      assert length(facets.task.options) == 52
      assert {"task-55", "task-55", 1} == hd(facets.task.options)
      assert {"No task", "none", 1} == List.last(facets.task.options)

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

  describe "get_run_by_run_id!/2" do
    test "by the subject, in the scope's hive only; a malformed id is not found", %{
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

  describe "the hive's destinations" do
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

    test "facets of the page", %{scope: scope} do
      facets = Runs.destination_facets(scope, cx(%{}), now: @now)
      assert {"registry.example", "registry.example", 2} in facets.host.options

      assert {"github.example/acme/shop", Filters.target_value({"github.example", "acme/shop"}),
              1} in facets.target.options

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
    hive_id = run.hive_id
    Runs.broadcast_changed(run)
    assert_receive {:runs_touched, ^hive_id}
  end
end
