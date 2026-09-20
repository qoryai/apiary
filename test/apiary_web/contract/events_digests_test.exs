defmodule ApiaryWeb.Contract.EventsDigestsTest do
  @moduledoc """
  F1 and F2: every answer to a batch names the run configuration in force for the run's
  repository, and what the run reported is kept per batch and on the run.
  """
  use ApiaryWeb.ConnCase, async: true

  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.Policy
  alias Apiary.Repo
  alias Apiary.Runs
  alias Apiary.Runs.{Delivery, Projector, Repository, Run}
  alias ApiaryWeb.Contract.Configuration

  setup do
    %{scope: scope} = sign_up_fixture()
    %{access_key: key, secret: secret} = access_key_fixture(scope)

    # The repository of `first_events/1`'s labels, with a rule of its own.
    repository =
      Repo.insert!(%Repository{
        organisation_id: scope.organisation.id,
        hive_id: scope.hive.id,
        forge: "git.example.com",
        path: "acme/shop",
        first_seen_at: DateTime.utc_now()
      })

    {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
    {:ok, _} = Policy.allow(scope, repository, %{host: "mcp.example"})
    {:ok, %{digest: baseline}} = Policy.current_configuration(scope, nil)
    {:ok, %{digest: own}} = Policy.current_configuration(scope, repository)
    assert baseline != own

    %{
      scope: scope,
      key: key,
      secret: secret,
      repository: repository,
      baseline: baseline,
      own: own
    }
  end

  defp deliver(ctx, events, opts \\ []),
    do: signed_post(build_conn(), ctx.key.key_id, ctx.secret, events, opts)

  defp in_force(conn), do: get_resp_header(conn, "x-qory-run-configuration")

  defp run!(ctx, subject),
    do: Repo.one!(from r in Run, where: r.hive_id == ^ctx.scope.hive.id and r.run_id == ^subject)

  test "the ping of a run that reports nothing is answered the baseline's digest", ctx do
    {_subject, [ping, _started]} = first_events()
    conn = deliver(ctx, [ping])

    assert response(conn, 202) == ""
    assert in_force(conn) == [ctx.baseline]
    assert get_resp_header(conn, "x-qory-configuration") == [Configuration.digest(true)]
  end

  test "the ping of a run that holds a digest in force is answered that digest, no other", ctx do
    {_subject, [ping, _started]} = first_events()
    assert in_force(deliver(ctx, [ping], run_configuration: ctx.own)) == [ctx.own]

    {_subject, [ping, _started]} = first_events()
    stale = "sha256=" <> String.duplicate("0", 64)
    assert in_force(deliver(ctx, [ping], run_configuration: stale)) == [ctx.baseline]
  end

  test "the batch that starts the run is answered its repository's digest, before any projection",
       ctx do
    {_subject, [_ping, started]} = first_events()
    assert in_force(deliver(ctx, [started])) == [ctx.own]
  end

  test "once projected, the run's repository decides, and a change of policy changes the answer",
       ctx do
    {subject, [ping, started]} = first_events()
    deliver(ctx, [ping, started], run_configuration: ctx.own)
    {:ok, _run} = Projector.project(run!(ctx, subject))

    heartbeat =
      wire_event(subject, 3, "run.heartbeat", %{"elapsed_seconds" => 30, "interval_seconds" => 30})

    assert in_force(deliver(ctx, [heartbeat], run_configuration: ctx.own)) == [ctx.own]

    {:ok, _} = Policy.allow(ctx.scope, nil, %{host: "cdn.example"})
    {:ok, %{digest: next}} = Policy.current_configuration(ctx.scope, ctx.repository)
    assert next != ctx.own

    heartbeat =
      wire_event(subject, 4, "run.heartbeat", %{"elapsed_seconds" => 60, "interval_seconds" => 30})

    conn = deliver(ctx, [heartbeat], run_configuration: ctx.own)
    assert in_force(conn) == [next]

    # F2: the run is behind, and the header can say so.
    run = run!(ctx, subject)
    assert run.reported_run_configuration_digest == ctx.own
    assert %{in_force: ^next, reported: reported, drift: true} = Policy.digests(ctx.scope, run)
    assert reported == ctx.own

    heartbeat =
      wire_event(subject, 5, "run.heartbeat", %{"elapsed_seconds" => 90, "interval_seconds" => 30})

    deliver(ctx, [heartbeat], run_configuration: next)
    assert %{drift: false, reported: ^next} = Policy.digests(ctx.scope, run!(ctx, subject))
  end

  test "a repeated delivery is answered the digest as well", ctx do
    {_subject, [_ping, started]} = first_events()
    delivery = Ecto.UUID.generate()
    assert in_force(deliver(ctx, [started], delivery: delivery)) == [ctx.own]
    assert in_force(deliver(ctx, [started], delivery: delivery)) == [ctx.own]
  end

  test "F2: what the batch reported is kept on the delivery, and only a digest is", ctx do
    {subject, [ping, started]} = first_events()
    deliver(ctx, [ping], run_configuration: ctx.own)
    deliver(ctx, [started], run_configuration: "not a digest")
    deliver(ctx, [wire_event(subject, 3, "run.heartbeat", %{})])

    assert [ctx.own, nil, nil] ==
             Repo.all(
               from d in Delivery,
                 where: d.run_id == ^subject,
                 order_by: d.received_at,
                 select: d.run_configuration_digest
             )

    assert run!(ctx, subject).reported_run_configuration_digest == ctx.own
  end

  test "a 410 carries both digests, the run configuration's for the closed run's repository",
       ctx do
    {subject, [ping, started]} = first_events()
    deliver(ctx, [ping, started])
    {:ok, run} = Projector.project(run!(ctx, subject))
    {:ok, _run} = Runs.close_run(ctx.scope, run)

    conn =
      deliver(ctx, [wire_event(subject, 3, "run.heartbeat", %{})], run_configuration: ctx.own)

    assert response(conn, 410) == ""
    assert in_force(conn) == [ctx.own]
    assert get_resp_header(conn, "x-qory-configuration") == [Configuration.digest(true)]

    assert Repo.one!(
             from d in Delivery, where: d.status == 410, select: d.run_configuration_digest
           ) == ctx.own
  end

  test "a hive nobody has given a policy names no run configuration, and renders none", _ctx do
    %{scope: scope} = sign_up_fixture()
    %{access_key: key, secret: secret} = access_key_fixture(scope)
    {subject, [ping, started]} = first_events()
    reported = "sha256=" <> String.duplicate("a", 64)

    for events <- [[ping], [started]] do
      conn = signed_post(build_conn(), key.key_id, secret, events, run_configuration: reported)
      assert response(conn, 202) == ""
      assert in_force(conn) == []
      assert get_resp_header(conn, "x-qory-configuration") == [Configuration.digest(false)]
    end

    assert Repo.aggregate(
             from(c in Apiary.Policy.RunConfiguration, where: c.hive_id == ^scope.hive.id),
             :count
           ) == 0

    # The first change: the discovery digest of the hive's answers changes, which is what
    # sends a run in flight to fetch the document and find the run section.
    {:ok, _} = Policy.set_mode(scope, "enforce")

    conn =
      signed_post(build_conn(), key.key_id, secret, [wire_event(subject, 3, "run.heartbeat", %{})])

    assert get_resp_header(conn, "x-qory-configuration") == [Configuration.digest(true)]
    {:ok, %{digest: digest}} = Policy.current_configuration(scope, nil)
    assert in_force(conn) == [digest]
    assert Configuration.digest(true) != Configuration.digest(false)
  end

  test "a refusal carries no digest of a run configuration", ctx do
    conn = deliver(ctx, "not a batch")
    assert json_response(conn, 400)
    assert in_force(conn) == []
  end

  test "the answer reads and renders nothing once the baseline exists", ctx do
    {subject, [ping, started]} = first_events()
    deliver(ctx, [ping, started])
    {:ok, _run} = Projector.project(run!(ctx, subject))

    handler = "digest-queries-#{System.unique_integer()}"
    parent = self()

    :telemetry.attach(
      handler,
      [:apiary, :repo, :query],
      fn _event, _measurements, %{source: source, query: query}, _config ->
        if self() == parent and source == "run_configurations", do: send(parent, {:query, query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    deliver(ctx, [wire_event(subject, 3, "run.heartbeat", %{})], run_configuration: ctx.own)

    assert_received {:query, "SELECT" <> _}
    refute_received {:query, _}
  end
end
