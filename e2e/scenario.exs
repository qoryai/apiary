# The end to end job's scenario. It runs inside the test instance, `mix run` with the
# endpoint serving, so what it calls is what a page calls, in the same virtual machine
# that answers the runner. run.sh starts it; see e2e/README.md.
#
# It makes a workspace with an owner and an access key, puts the workspace in enforce with
# nothing allowed, writes the node's runner file, starts the session on the node, waits
# for the denied connection to arrive, allows its host the way the connection's row does,
# and then watches the run's record for the second policy applied event and the allowed
# connection. A member of the workspace then asks for observe, which is an owner's or an
# admin's, and is refused, and it checks that the session is still let through to the host
# and that the run's record shows no policy applied event after the refusal. Then it puts
# the workspace in observe, denies the host from the same row, and watches for the third
# policy applied event and the denied connection, refused by name under observe. It prints
# the timings and leaves with status 0 only when every assertion held. It never prints the
# secret: the runner file is the one place it goes.

defmodule E2E do
  import Ecto.Query

  alias Apiary.AccessKeys
  alias Apiary.Accounts.Scope
  alias Apiary.Audit
  alias Apiary.Organisations
  alias Apiary.Policy
  alias Apiary.Repo
  alias Apiary.Runs
  alias Apiary.Runs.{Connection, Event, Run}

  @policy_applied "dev.qory.run.policy_applied"
  @egress "dev.qory.run.egress"
  @poll_ms 50

  def main do
    host = env!("E2E_UPSTREAM_HOST")
    runner_file = env!("E2E_RUNNER_FILE")
    runner_tail = File.read!(env!("E2E_RUNNER_TAIL"))
    prepare = env!("E2E_PREPARE_COMMAND")
    session = env!("E2E_SESSION_COMMAND")
    session_log = env!("E2E_SESSION_LOG")
    budget_ms = String.to_integer(System.get_env("E2E_BUDGET_SECONDS", "35")) * 1000
    # `E2E_LEVEL` says `target` or `workspace`, as the popover's level does.
    level =
      case System.get_env("E2E_LEVEL", "target") do
        "target" -> :target
        "workspace" -> :workspace
      end

    # A line per request is the instance's log, not this job's.
    Logger.configure(level: :warning)

    step("a workspace, its owner and an access key")
    scope = owner_scope()
    {:ok, "enforce"} = Policy.set_mode(scope, "enforce")
    true = Policy.managed?(scope)
    {:ok, access_key, secret} = AccessKeys.create_access_key(scope, %{label: "e2e node"})

    File.write!(runner_file, "")
    File.chmod!(runner_file, 0o600)

    File.write!(
      runner_file,
      AccessKeys.server_block(access_key, secret, ApiaryWeb.Endpoint.url()) <> runner_tail
    )

    say(
      "workspace in enforce, nothing allowed; key #{access_key.key_id}; server #{ApiaryWeb.Endpoint.url()}"
    )

    step("the node")

    case System.cmd("sh", ["-c", prepare], stderr_to_stdout: true) do
      {output, 0} -> output |> String.trim() |> String.split("\n") |> Enum.each(&say/1)
      {output, status} -> fail("the node was not made ready (status #{status}):\n#{output}")
    end

    step("the session, behind the wall on the node")
    started = System.monotonic_time(:millisecond)

    session_task =
      Task.async(fn ->
        {_, status} =
          System.cmd("sh", ["-c", session],
            into: File.stream!(session_log),
            stderr_to_stdout: true
          )

        status
      end)

    connection =
      await("a denied connection to #{host} in the record", 180_000, session_task, fn ->
        Repo.one(
          from c in Connection,
            where: c.workspace_id == ^scope.workspace.id and c.host == ^host and c.denied > 0,
            limit: 1
        )
      end)

    run = Repo.get!(Run, connection.run_id)
    [first] = applied(run)

    say(
      "run #{run.run_id}, wall #{inspect(run.wall)}, target #{run.target_system}/#{run.target_path}"
    )

    say(
      "first policy applied: sequence #{first.sequence}, run configuration #{short(first.data["run_configuration"])}"
    )

    say(
      "denied: #{connection.method} #{host}:#{connection.port}, #{connection.denied} so far (#{since(started)} after the session was started)"
    )

    true = first.data["mode"] == "enforce"
    before_digest = first.data["run_configuration"]

    {:ok, %{digest: ^before_digest}} =
      Policy.current_configuration(scope, holder(scope, run, level))

    step("allow, as the connection's row does")
    # The two calls of the row's popover: ApiaryWeb.RunLive.Show and
    # ApiaryWeb.ConnectionLive.Index both fetch the connection by its id and hand it to
    # rule_from_connection/4 with the level the person chose.
    allow_wall = DateTime.utc_now()
    t0 = System.monotonic_time(:millisecond)
    {:ok, row} = Runs.fetch_connection(scope, connection.id)
    {:ok, rule} = Policy.rule_from_connection(scope, row, :allow, level)
    t_written = System.monotonic_time(:millisecond)

    {:ok, %{digest: new_digest, version: version}} =
      Policy.current_configuration(scope, holder(scope, Repo.get!(Run, run.id), level))

    true = new_digest != before_digest

    say(
      "rule #{rule.action} #{rule.host} at the #{level}'s level, written in #{t_written - t0} ms; version #{version}, digest #{short(new_digest)}"
    )

    second =
      await(
        "a second policy applied event with the new digest",
        budget_ms + 30_000,
        session_task,
        fn ->
          Enum.find(
            applied(run),
            &(&1.sequence > first.sequence and &1.data["run_configuration"] == new_digest)
          )
        end
      )

    t_applied = System.monotonic_time(:millisecond)

    allowed =
      await("an allowed connection to #{host} after it", budget_ms + 30_000, session_task, fn ->
        allowed_connection(run, host, second.sequence)
      end)

    t_allowed = System.monotonic_time(:millisecond)
    to_applied = t_applied - t0

    # A member changes the rules, not the mode: the mode decides what runs are denied, and
    # is an owner's or an admin's. A member of the workspace asks for observe and is refused
    # under the workspace's lock. What the run shows of it: the session is still let through
    # to the host on its next connections, the run's record has no policy applied event
    # after the refusal, and the configuration in force, the mode and the audit trail are
    # as they were.
    #
    # The watch lasts until the second allowed connection after the refusal, and at least
    # twice this run's own allow -> policy applied time. The session tries every few
    # seconds and a batch is cut a second after its first event, so the first allowed
    # connection after the refusal may have been on its way before it, and the second can
    # be stored sooner than a change would take to come back as a policy applied event.
    step("a member asks for observe, and is refused")
    member = member_scope(scope)
    member_entries = trail(member)
    before_refusal = last_sequence(run)
    t_refused = System.monotonic_time(:millisecond)
    refused = Policy.set_mode(member, "observe")

    kept =
      await(
        "two allowed connections to #{host} after the refusal",
        budget_ms + 30_000,
        session_task,
        fn ->
          case allowed_connections(run, host, before_refusal, 2) do
            [_, second_allowed] -> second_allowed
            _ -> nil
          end
        end
      )

    kept_after = since(t_refused)
    Process.sleep(max(t_refused + 2 * to_applied - System.monotonic_time(:millisecond), 0))
    quiet = Enum.filter(applied(run), &(&1.sequence > before_refusal))

    {:ok, %{digest: refused_digest, version: refused_version}} =
      Policy.current_configuration(scope, holder(scope, Repo.get!(Run, run.id), level))

    refused_mode = Policy.get_mode(scope)
    refused_entries = trail(member) - member_entries

    say(
      "refused: #{inspect(refused)}; #{length(quiet)} policy applied events after sequence #{before_refusal}, watched for #{since(t_refused)}; second allowed connection since at sequence #{kept.sequence}, seen #{kept_after} after the refusal; version #{refused_version}, mode #{refused_mode}, #{refused_entries} audit entries by the member"
    )

    # The second thing the console promises: a deny holds in either mode. The workspace
    # goes to observe, the host is denied from the same row, and the same session, which
    # kept asking, is refused by name.
    step("observe, then deny as the connection's row does")
    {:ok, "observe"} = Policy.set_mode(scope, "observe")
    deny_wall = DateTime.utc_now()
    t1 = System.monotonic_time(:millisecond)
    {:ok, row} = Runs.fetch_connection(scope, connection.id)
    {:ok, deny_rule} = Policy.rule_from_connection(scope, row, :deny, level)

    {:ok, %{digest: deny_digest, version: deny_version}} =
      Policy.current_configuration(scope, holder(scope, Repo.get!(Run, run.id), level))

    true = deny_digest != new_digest

    say(
      "workspace in observe; rule #{deny_rule.action} #{deny_rule.host} at the #{level}'s level; version #{deny_version}, digest #{short(deny_digest)}"
    )

    third =
      await(
        "a third policy applied event with the deny digest",
        budget_ms + 30_000,
        session_task,
        fn ->
          Enum.find(
            applied(run),
            &(&1.sequence > second.sequence and &1.data["run_configuration"] == deny_digest)
          )
        end
      )

    t_deny_applied = System.monotonic_time(:millisecond)

    denied =
      await("a denied connection to #{host} after it", budget_ms + 30_000, session_task, fn ->
        Repo.one(
          from e in Event,
            where:
              e.run_id == ^run.id and e.type == @egress and e.sequence > ^third.sequence and
                fragment("?->>'host' = ?", e.data, ^host) and
                fragment("?->>'decision' = 'denied'", e.data),
            order_by: e.sequence,
            limit: 1
        )
      end)

    t_denied = System.monotonic_time(:millisecond)

    step("the rest of the record")
    status = Task.await(session_task, 120_000)

    run =
      await("the run's exit in the record", 30_000, nil, fn ->
        case Repo.get!(Run, run.id) do
          %Run{exited_at: %DateTime{}} = run -> run
          _ -> nil
        end
      end)

    digests = Policy.digests(scope, run)
    denied_between = denied_between(run, host, second.sequence, third.sequence)
    allowed_after = allowed_after(run, host, third.sequence)
    applied_count = length(applied(run))

    say(
      "the session left with status #{status}; the run is #{run.state}, exit code #{inspect(run.exit_code)}, #{run.event_count} events"
    )

    say(
      "policy applied events: #{applied_count}; connections to #{host} denied between the allow and the deny: #{denied_between}; allowed after the deny: #{allowed_after}"
    )

    say(
      "digests: in force #{short(digests.in_force)}, applied #{short(digests.applied)}, reported #{short(digests.reported)}, drift #{digests.drift}"
    )

    to_allowed = t_allowed - t0
    deny_to_applied = t_deny_applied - t1
    deny_to_denied = t_denied - t1

    IO.puts("""

    == result
    allow -> second policy applied, seen stored here   #{seconds(to_applied)}
    allow -> allowed connection, seen stored here      #{seconds(to_allowed)}   (budget #{div(budget_ms, 1000)} s)
    by the node's clock, for comparison:
      allow -> second policy applied                   #{seconds(DateTime.diff(second.time, allow_wall, :millisecond))}
      allow -> allowed connection                      #{seconds(DateTime.diff(allowed.time, allow_wall, :millisecond))}
    second policy applied: sequence #{second.sequence}, source #{second.data["source"]}, allow #{inspect(second.data["allow"])}
    allowed connection:    sequence #{allowed.sequence}, #{allowed.data["method"]} #{allowed.data["host"]}:#{allowed.data["port"]}, rule #{inspect(allowed.data["rule"])}
    deny  -> third policy applied, seen stored here    #{seconds(deny_to_applied)}
    deny  -> denied connection, seen stored here       #{seconds(deny_to_denied)}   (budget #{div(budget_ms, 1000)} s)
    by the node's clock, for comparison:
      deny -> third policy applied                     #{seconds(DateTime.diff(third.time, deny_wall, :millisecond))}
      deny -> denied connection                        #{seconds(DateTime.diff(denied.time, deny_wall, :millisecond))}
    third policy applied:  sequence #{third.sequence}, mode #{inspect(third.data["mode"])}, allow #{inspect(third.data["allow"])}, deny #{inspect(third.data["deny"])}
    denied connection:     sequence #{denied.sequence}, #{denied.data["method"]} #{denied.data["host"]}:#{denied.data["port"]}, mode #{inspect(denied.data["mode"])}, rule #{inspect(denied.data["rule"])}
    """)

    failures =
      [
        {second.data["run_configuration"] == new_digest,
         "the second policy applied names the new digest"},
        {host in (second.data["allow"] || []), "the second policy applied allows #{host}"},
        {to_allowed < budget_ms, "allow to allowed connection under #{div(budget_ms, 1000)} s"},
        {match?({:error, %Policy.Error{reason: :forbidden}}, refused),
         "the member's observe was refused as forbidden"},
        {quiet == [], "no policy applied event in the run's record after the refusal"},
        {refused_digest == new_digest and refused_version == version and
           refused_mode == "enforce",
         "the configuration in force and the mode are as they were before the refusal"},
        {refused_entries == 0, "the refusal wrote no audit entry"},
        {run.wall == "docker", "the run was behind the docker wall"},
        {denied_between == 0,
         "no connection to #{host} was denied between the allow reload and the deny"},
        {third.data["mode"] == "observe", "the third policy applied is under observe"},
        {host in (third.data["deny"] || []), "the third policy applied denies #{host}"},
        {host not in (third.data["allow"] || []),
         "the third policy applied no longer allows #{host}"},
        {denied.data["mode"] == "observe" and denied.data["rule"] == host,
         "the denied connection was refused under observe by the rule #{host}"},
        {deny_to_denied < budget_ms, "deny to denied connection under #{div(budget_ms, 1000)} s"},
        {allowed_after == 0, "no connection to #{host} was allowed after the deny reload"},
        {status == 0 and run.exit_code == 0,
         "the session reached the host, was then refused, and left with 0"},
        {digests.applied == digests.in_force and not digests.drift,
         "the run ends on the digest in force, without drift"}
      ]
      |> Enum.reject(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    case failures do
      [] ->
        IO.puts(
          "E2E PASS  allow_to_applied_ms=#{to_applied} allow_to_allowed_ms=#{to_allowed} deny_to_applied_ms=#{deny_to_applied} deny_to_denied_ms=#{deny_to_denied}"
        )

      failures ->
        Enum.each(failures, &IO.puts("E2E FAIL  not true: #{&1}"))
        System.halt(1)
    end
  end

  # The workspace's first owner, made the way sign-up makes one: the instance's first
  # sign-up, on its fresh database, which every edition offers whatever its settings say,
  # and makes the instance's own organisation. Anyone else would
  # need an invitation from it. The owner then signs in with the emailed link, which is
  # what confirms an account, as it must be before it invites anyone.
  defp owner_scope do
    {:ok, %{user: user}} =
      Organisations.sign_up_user(%{email: "owner@e2e.test", organisation_name: "E2E"})

    parent = self()

    {:ok, _email} =
      Apiary.Accounts.deliver_login_instructions(user, fn token ->
        send(parent, {:login_token, token})
        "#{ApiaryWeb.Endpoint.url()}/users/log-in/#{token}"
      end)

    token =
      receive do
        {:login_token, token} -> token
      after
        0 -> fail("the log-in link was not sent")
      end

    {:ok, {user, _tokens}} = Apiary.Accounts.login_user_by_magic_link(token)

    %Scope{workspace: %{}} = scope = Organisations.load_scope(Scope.for_user(user))
    scope
  end

  # A member of the owner's workspace, joined the way a person joins: an invitation sent
  # from the workspace, and a sign-up with its token. The email goes to the log.
  defp member_scope(%Scope{workspace: %{id: workspace_id}} = owner) do
    email = "member@e2e.test"
    parent = self()

    {:ok, _invitation} =
      Organisations.invite_member(owner, %{"email" => email}, fn token ->
        send(parent, {:invitation_token, token})
        "#{ApiaryWeb.Endpoint.url()}/invitations/#{token}"
      end)

    token =
      receive do
        {:invitation_token, token} -> token
      after
        0 -> fail("the invitation was not sent")
      end

    {:ok, %{user: user}} = Organisations.sign_up_user(%{email: email}, token)

    %Scope{workspace: %{id: ^workspace_id}, membership: %{level: :member}} =
      scope = Organisations.load_scope(Scope.for_user(user))

    scope
  end

  # The audit entries a person wrote in the scope's organisation.
  defp trail(%Scope{user: %{id: user_id}, organisation: %{id: organisation_id}}) do
    Repo.aggregate(
      from(e in Audit.Entry,
        where: e.organisation_id == ^organisation_id and e.actor_id == ^user_id
      ),
      :count
    )
  end

  defp last_sequence(%Run{id: id}),
    do: Repo.aggregate(from(e in Event, where: e.run_id == ^id), :max, :sequence)

  defp allowed_connection(run, host, sequence) do
    case allowed_connections(run, host, sequence, 1) do
      [event] -> event
      [] -> nil
    end
  end

  # The first `count` allowed, connected egress events to `host` after `sequence`.
  defp allowed_connections(%Run{id: id}, host, sequence, count) do
    Repo.all(
      from e in Event,
        where:
          e.run_id == ^id and e.type == @egress and e.sequence > ^sequence and
            fragment("?->>'host' = ?", e.data, ^host) and
            fragment("?->>'decision' = 'allowed'", e.data) and
            fragment("?->>'outcome' = 'connected'", e.data),
        order_by: e.sequence,
        limit: ^count
    )
  end

  defp holder(_scope, _run, :workspace), do: nil

  defp holder(scope, %Run{target_id: id}, :target) when is_binary(id) do
    {:ok, target} = Policy.get_target(scope, id)
    target
  end

  defp applied(%Run{id: id}) do
    Repo.all(
      from e in Event, where: e.run_id == ^id and e.type == @policy_applied, order_by: e.sequence
    )
  end

  defp denied_between(%Run{id: id}, host, from_sequence, to_sequence) do
    Repo.aggregate(
      from(e in Event,
        where:
          e.run_id == ^id and e.type == @egress and e.sequence > ^from_sequence and
            e.sequence < ^to_sequence and
            fragment("?->>'host' = ?", e.data, ^host) and
            fragment("?->>'decision' = 'denied'", e.data)
      ),
      :count
    )
  end

  defp allowed_after(%Run{id: id}, host, sequence) do
    Repo.aggregate(
      from(e in Event,
        where:
          e.run_id == ^id and e.type == @egress and e.sequence > ^sequence and
            fragment("?->>'host' = ?", e.data, ^host) and
            fragment("?->>'decision' = 'allowed'", e.data)
      ),
      :count
    )
  end

  # Polls until `fun` answers something. A session that has already left cannot bring
  # what is waited for, so its end is the end of the wait, a second later.
  defp await(what, timeout_ms, session_task, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(what, deadline, session_task, fun, nil)
  end

  defp poll(what, deadline, session_task, fun, gone_at) do
    now = System.monotonic_time(:millisecond)

    gone_at =
      gone_at || (session_task && !Process.alive?(session_task.pid) && now)

    case fun.() do
      nil ->
        cond do
          now > deadline ->
            fail("timed out waiting for #{what}")

          gone_at && now - gone_at > 3_000 ->
            fail("the session left before #{what} arrived")

          true ->
            Process.sleep(@poll_ms) && poll(what, deadline, session_task, fun, gone_at || nil)
        end

      found ->
        found
    end
  end

  defp fail(message) do
    IO.puts("E2E FAIL  #{message}")
    System.halt(1)
  end

  defp env!(name), do: System.get_env(name) || fail("#{name} is not set; run.sh sets it")
  defp step(text), do: IO.puts("\n== #{text}")
  defp say(text), do: IO.puts("   #{text}")
  defp short(nil), do: "none"
  defp short(digest), do: String.slice(digest, 0, 19) <> "…"
  defp seconds(ms), do: :io_lib.format("~6.2f s", [ms / 1000]) |> IO.iodata_to_binary()
  defp since(t), do: seconds(System.monotonic_time(:millisecond) - t) |> String.trim()
end

E2E.main()
