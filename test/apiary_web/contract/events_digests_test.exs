defmodule ApiaryWeb.Contract.EventsDigestsTest do
  @moduledoc """
  Every answer to a batch names the run configuration in force for the run's target, and
  what the run reported is kept per batch and on the run.
  """
  use ApiaryWeb.ConnCase, async: true

  # The security policy: left out of a run without the security feature.
  @moduletag needs: :security

  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.Policy
  alias Apiary.Repo
  alias Apiary.Runs.{Delivery, Projector, Target, Run}
  alias ApiaryWeb.Contract.Configuration

  setup do
    %{scope: scope} = sign_up_fixture()
    %{access_key: key, secret: secret} = contract_key_fixture(scope)

    # The target of `first_events/1`'s labels, with a rule of its own.
    target =
      Repo.insert!(%Target{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        system: "git.example.com",
        path: "acme/shop",
        first_seen_at: DateTime.utc_now()
      })

    {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
    {:ok, _} = Policy.allow(scope, target, %{host: "mcp.example"})
    {:ok, %{digest: baseline}} = Policy.current_configuration(scope, nil)
    {:ok, %{digest: own}} = Policy.current_configuration(scope, target)
    assert baseline != own

    %{
      scope: scope,
      key: key,
      secret: secret,
      target: target,
      baseline: baseline,
      own: own
    }
  end

  defp deliver(ctx, events, opts \\ []),
    do: signed_post(build_conn(), ctx.key.key_id, ctx.secret, events, opts)

  defp in_force(conn), do: get_resp_header(conn, "x-qory-run-configuration")

  # A heartbeat of a run whose start has not arrived: nothing names its target.
  defp beat(subject \\ Ecto.UUID.generate(), sequence \\ 3),
    do: wire_event(subject, sequence, "run.heartbeat", %{})

  defp run!(ctx, subject),
    do:
      Repo.one!(
        from r in Run, where: r.workspace_id == ^ctx.scope.workspace.id and r.run_id == ^subject
      )

  test "a batch that names no target, of a run that reports nothing, is answered the baseline's digest",
       ctx do
    conn = deliver(ctx, [beat()])

    assert response(conn, 202) == ""
    assert in_force(conn) == [ctx.baseline]
    assert get_resp_header(conn, "x-qory-configuration") == [Configuration.digest(ctx.key)]
  end

  test "a batch that names no target, of a run that holds a digest in force, is answered that digest, no other",
       ctx do
    assert in_force(deliver(ctx, [beat()], run_configuration: ctx.own)) == [ctx.own]

    stale = "sha256=" <> String.duplicate("0", 64)
    assert in_force(deliver(ctx, [beat()], run_configuration: stale)) == [ctx.baseline]
  end

  test "the batch that starts the run is answered its target's digest, before any projection",
       ctx do
    {_subject, [started]} = first_events()
    assert in_force(deliver(ctx, [started])) == [ctx.own]
  end

  test "the start's labels name the target by the key's domain without reading a workspace",
       ctx do
    {_subject, [started]} = first_events()
    handler = "digest-workspaces-#{System.unique_integer()}"
    parent = self()

    :telemetry.attach(
      handler,
      [:apiary, :repo, :query],
      fn _event, _measurements, %{source: source}, _config ->
        if self() == parent and source == "workspaces", do: send(parent, :workspaces)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert in_force(deliver(ctx, [started])) == [ctx.own]
    refute_received :workspaces
  end

  test "once projected, the run's target decides, and a change of policy changes the answer",
       ctx do
    {subject, batch} = first_events()
    deliver(ctx, batch, run_configuration: ctx.own)
    {:ok, _run} = Projector.project(run!(ctx, subject))

    heartbeat =
      wire_event(subject, 3, "run.heartbeat", %{"elapsed_seconds" => 30, "interval_seconds" => 30})

    assert in_force(deliver(ctx, [heartbeat], run_configuration: ctx.own)) == [ctx.own]

    {:ok, _} = Policy.allow(ctx.scope, nil, %{host: "cdn.example"})
    {:ok, %{digest: next}} = Policy.current_configuration(ctx.scope, ctx.target)
    assert next != ctx.own

    heartbeat =
      wire_event(subject, 4, "run.heartbeat", %{"elapsed_seconds" => 60, "interval_seconds" => 30})

    conn = deliver(ctx, [heartbeat], run_configuration: ctx.own)
    assert in_force(conn) == [next]

    # The run is behind, and the header can say so.
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
    {_subject, [started]} = first_events()
    delivery = Ecto.UUID.generate()
    assert in_force(deliver(ctx, [started], delivery: delivery)) == [ctx.own]
    assert in_force(deliver(ctx, [started], delivery: delivery)) == [ctx.own]
  end

  test "what the batch reported is kept on the delivery, and only a digest is", ctx do
    {subject, [started]} = first_events()
    deliver(ctx, [beat(subject, 3)], run_configuration: ctx.own)
    deliver(ctx, [started], run_configuration: "not a digest")
    deliver(ctx, [beat(subject, 4)])

    assert [ctx.own, nil, nil] ==
             Repo.all(
               from d in Delivery,
                 where: d.run_id == ^subject,
                 order_by: d.received_at,
                 select: d.run_configuration_digest
             )

    assert run!(ctx, subject).reported_run_configuration_digest == ctx.own
  end

  test "a 410 carries both digests, the run configuration's for the pruned run's target",
       ctx do
    {subject, batch} = first_events()
    deliver(ctx, batch)
    {:ok, run} = Projector.project(run!(ctx, subject))

    # The mark `Apiary.Retention` sets once it has deleted the run's events.
    Repo.update_all(from(r in Run, where: r.id == ^run.id),
      set: [events_pruned_at: DateTime.utc_now()]
    )

    conn =
      deliver(ctx, [wire_event(subject, 3, "run.heartbeat", %{})], run_configuration: ctx.own)

    assert response(conn, 410) == ""
    assert in_force(conn) == [ctx.own]

    assert get_resp_header(conn, "x-qory-configuration") == [Configuration.digest(ctx.key)]

    assert Repo.one!(
             from d in Delivery, where: d.status == 410, select: d.run_configuration_digest
           ) == ctx.own
  end

  test "a workspace nobody has given a policy names no run configuration, and renders none",
       _ctx do
    %{scope: scope} = sign_up_fixture()
    %{access_key: key, secret: secret} = contract_key_fixture(scope)
    {subject, [started]} = first_events()
    reported = "sha256=" <> String.duplicate("a", 64)

    for events <- [[beat(subject, 3)], [started]] do
      conn = signed_post(build_conn(), key.key_id, secret, events, run_configuration: reported)
      assert response(conn, 202) == ""
      assert in_force(conn) == []
      assert get_resp_header(conn, "x-qory-configuration") == [Configuration.digest(key)]
    end

    assert Repo.aggregate(
             from(c in Apiary.Policy.RunConfiguration,
               where: c.workspace_id == ^scope.workspace.id
             ),
             :count
           ) == 0

    # The first change: the answers name a run configuration, a digest the run does not
    # hold, which is what sends a run in flight to reload it; discovery's stays.
    {:ok, _} = Policy.set_mode(scope, "enforce")

    conn = signed_post(build_conn(), key.key_id, secret, [beat(subject, 4)])

    assert get_resp_header(conn, "x-qory-configuration") == [Configuration.digest(key)]
    {:ok, %{digest: digest}} = Policy.current_configuration(scope, nil)
    assert in_force(conn) == [digest]
  end

  test "a refusal carries no digest of a run configuration", ctx do
    conn = deliver(ctx, "not a batch")
    assert json_response(conn, 400)
    assert in_force(conn) == []
  end

  test "the answer reads and renders nothing once the baseline exists", ctx do
    {subject, batch} = first_events()
    deliver(ctx, batch)
    {:ok, _run} = Projector.project(run!(ctx, subject))

    handler = "digest-queries-#{System.unique_integer()}"
    parent = self()

    :telemetry.attach(
      handler,
      [:apiary, :repo, :query],
      fn _event, _measurements, %{source: source, query: query}, _config ->
        # The workspaces too: the key's workspace, whose domain names a run's target, is
        # read with the key and never again.
        if self() == parent and source in ["run_configurations", "workspaces"],
          do: send(parent, {:query, source, query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    deliver(ctx, [wire_event(subject, 3, "run.heartbeat", %{})], run_configuration: ctx.own)

    # Whether the workspace serves a policy, then the digest in force: one read each.
    assert_received {:query, "run_configurations", "SELECT TRUE" <> _}
    assert_received {:query, "run_configurations", "SELECT r0." <> _}
    refute_received {:query, _source, _query}
  end
end
