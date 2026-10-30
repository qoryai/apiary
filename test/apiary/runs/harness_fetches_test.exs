defmodule Apiary.Runs.HarnessFetchesTest do
  # The workspace's harness fetches (`Apiary.Runs.harness_fetches/3`): the hosts runs
  # reached on the stack channel, with the source of each from the run's harness record.
  # They are no destination: the destinations' reads stay on the session channel.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Apiary.SealedRunsFixtures

  alias Apiary.Harnesses.RunHarness
  alias Apiary.Lingo.Domain.Definition
  alias Apiary.Runs
  alias Apiary.Runs.{Filters, Projector}

  @moduletag needs: :factory
  setup {Apiary.DataCase, :without_registry}

  defp fx(params \\ %{}), do: Filters.parse(params, :connections)

  defp egress(run, events, from \\ 20) do
    for {event, n} <- Enum.with_index(events, from) do
      event_fixture(run, n, "run.egress", egress_data(event), time: DateTime.utc_now())
    end

    {:ok, run} = Projector.project(run)
    run
  end

  defp fetched_hosts(scope, params),
    do: scope |> Runs.harness_fetches(fx(params)) |> Map.fetch!(:rows) |> Enum.map(& &1.host)

  defp stack(host, extra \\ %{}), do: Map.merge(%{"host" => host, "channel" => "stack"}, extra)

  defp walk(run, changes) do
    RunHarness
    |> Repo.get_by!(dispatch_run_id: run.dispatch_run_id)
    |> Ecto.Changeset.change(changes)
    |> Repo.update!()
  end

  setup do
    %{scope: scope} = ctx = sign_up_fixture() |> then(&Map.put(&1, :scope, &1.scope))
    run = sealed_run_fixture(scope).run

    walk(run, %{
      pins: [
        %{"git" => "https://code.example/acme/tools.git", "ref" => "main", "at" => "x"},
        %{"git" => Definition.qory_harness().git, "ref" => "main", "at" => "y"}
      ]
    })

    Map.put(ctx, :run, run)
  end

  test "one row per host with its counts and its sources from the run's record", ctx do
    egress(ctx.run, [
      stack("code.example"),
      stack("code.example"),
      stack("github.com"),
      stack("other.example", %{"decision" => "denied", "rule" => nil}),
      %{"host" => "session.example"}
    ])

    %{rows: rows, total: 3} = Runs.harness_fetches(ctx.scope, fx())
    by_host = Map.new(rows, &{&1.host, &1})

    assert Map.keys(by_host) |> Enum.sort() == ~w(code.example github.com other.example)
    assert %{runs: 1, attempts: 2, allowed: 2, denied: 0} = by_host["code.example"]
    assert by_host["code.example"].sources == [{:repository, "acme/tools"}]
    assert by_host["github.com"].sources == [:qory]
    assert by_host["other.example"].sources == [:none]
    assert %{denied: 1} = by_host["other.example"]
  end

  test "a host no pin matches says the walk is not read yet or failed, else not a source", ctx do
    egress(ctx.run, [stack("other.example"), stack("code.example")])

    sources = fn ->
      ctx.scope
      |> Runs.harness_fetches(fx())
      |> Map.fetch!(:rows)
      |> Map.new(&{&1.host, &1.sources})
    end

    walk(ctx.run, %{state: :resolved, origin: :none, failure: nil})

    assert %{"other.example" => [:none], "code.example" => [{:repository, "acme/tools"}]} =
             sources.()

    walk(ctx.run, %{state: :pending, origin: nil, failure: nil})

    assert %{"other.example" => [:pending], "code.example" => [{:repository, "acme/tools"}]} =
             sources.()

    walk(ctx.run, %{state: :failed, origin: nil, failure: "invalid"})

    assert %{"other.example" => [:failed], "code.example" => [{:repository, "acme/tools"}]} =
             sources.()
  end

  test "a hidden harness shows no source, a run with no record has none recorded", ctx do
    walk(ctx.run, %{harness_hidden: true})
    egress(ctx.run, [stack("code.example")])
    assert %{rows: [%{sources: [:hidden]}]} = Runs.harness_fetches(ctx.scope, fx())

    Repo.delete_all(from h in RunHarness, where: h.dispatch_run_id == ^ctx.run.dispatch_run_id)
    assert %{rows: [%{sources: [:unrecorded]}]} = Runs.harness_fetches(ctx.scope, fx())
  end

  test "the filters of the destinations narrow them; another workspace's runs are none", ctx do
    egress(ctx.run, [
      stack("code.example", %{"decision" => "denied", "rule" => nil}),
      stack("github.com")
    ])

    assert ["code.example"] = fetched_hosts(ctx.scope, %{"host" => "code.example"})
    assert ["code.example"] = fetched_hosts(ctx.scope, %{"decision" => "denied"})
    assert ["github.com"] = fetched_hosts(ctx.scope, %{"q" => "github"})

    assert Runs.harness_fetches(scope_fixture(), fx()) == %{rows: [], total: 0}
  end

  test "cuts the rows at the limit, most recently seen first, and counts every host", ctx do
    for n <- 1..5 do
      event_fixture(ctx.run, 20 + n, "run.egress", egress_data(stack("h#{n}.example")),
        time: DateTime.add(DateTime.utc_now(), n, :second)
      )
    end

    {:ok, _run} = Projector.project(ctx.run)

    assert %{rows: [%{host: "h5.example"}, %{host: "h4.example"}], total: 5} =
             Runs.harness_fetches(ctx.scope, fx(), DateTime.utc_now(), limit: 2)

    assert %{rows: rows, total: 5} = Runs.harness_fetches(ctx.scope, fx())
    assert length(rows) == 5
  end

  test "a harness fetch is no destination: no row, count, view or facet reads it", ctx do
    egress(ctx.run, [stack("fetch.example"), %{"host" => "session.example"}])

    assert [%{host: "session.example"}] = Runs.page_destinations(ctx.scope, fx()).rows
    assert %{all: 1} = Runs.destination_views(ctx.scope, fx())

    hosts = Runs.destination_facets(ctx.scope, fx()).host.options |> Enum.map(&elem(&1, 1))
    assert hosts == ["session.example"]

    assert %{runs: [], total: 0} =
             Runs.destination_runs(ctx.scope, fx(), {"fetch.example", 443, ""})

    assert [] = Runs.destination_targets(ctx.scope, fx(), {"fetch.example", 443, ""})
  end
end
