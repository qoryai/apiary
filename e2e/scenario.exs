# The end to end job's scenario. It runs inside the test instance, `mix run` with the
# endpoint serving, so what it calls is what a page calls, in the same virtual machine
# that answers the gateway. run.sh starts it; see e2e/README.md.
#
# Each instance is set up as a person sets one up: with the set-up link its start logged,
# read from its log (`E2E_INSTANCE_LOG`, the file run.sh writes the instance's output to),
# never with a code asked of the instance in-process.
#
# With E2E_MAIL=none, the default, the instance has no mail, as a new install has none.
# It makes a workspace with an owner, set up with a password, a node and the node's access
# key: a fresh Ed25519 key, generated here, whose public key is added to the node the way
# the node's Generate a key adds one made in a browser, active as it is added. It puts the
# workspace in enforce with nothing allowed, writes the node's Forager file, with the
# server lines the key's page shows, and the key's secret in access-key-secret beside it,
# starts the session on the node, waits for the denied connection to arrive, allows its
# host the way the connection's row does, and then watches the run's record for the
# second policy applied event and the allowed connection. A member of the workspace,
# invited with a link the owner copies, then asks for observe, which is an owner's or an
# admin's, and is refused, and it checks that the session is still let through to the host
# and that the run's record shows no policy applied event after the refusal. Then it puts
# the workspace in observe, denies the host from the same row, and watches for the third
# policy applied event and the denied connection, refused by name under observe. It prints
# the timings and leaves with status 0 only when every assertion held. It never prints the
# secret: access-key-secret is the one place it goes.
#
# With E2E_MAIL=sink the instance sends its mail over SMTP to the job's sink
# (compose.yaml's `sink`), and the scenario checks the mailed way in: the set-up through
# the logged link, the owner's log-in link and a member's invitation, each read from the
# sink (`E2E_SINK_COMMAND`), and the member's sign-up with it. No node and no session.

defmodule E2E do
  import Ecto.Query

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Audit
  alias Apiary.Nodes
  alias Apiary.Organisations
  alias Apiary.Policy
  alias Apiary.Repo
  alias Apiary.Runs
  alias Apiary.Runs.{Connection, Event, Run}

  @policy_applied "dev.qory.run.policy_applied"
  @egress "dev.qory.run.egress"
  @poll_ms 50

  # What the instance's start logs: the set-up link, and, with no mail, that no mail is set.
  @set_up_line ~r{^Set up Qory Apiary at (\S+)\.$}
  @no_mail_line "No mail is set: invitations and password links are copied by hand. Set mail in Instance settings › Mail."

  def main do
    # A line per request is the instance's log, not this job's. What its start logged, the
    # set-up link among it, is in the log already.
    Logger.configure(level: :warning)

    case System.get_env("E2E_MAIL", "none") do
      "none" -> live_reload()
      "sink" -> mailed()
      other -> fail("E2E_MAIL is none or sink, not #{inspect(other)}")
    end
  end

  defp live_reload do
    host = env!("E2E_UPSTREAM_HOST")
    forager_file = env!("E2E_FORAGER_FILE")
    forager_tail = File.read!(env!("E2E_FORAGER_TAIL"))
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

    # The test instance has no SMTP_RELAY, so no mail (`Apiary.Mail`), and its start said
    # so: the owner signs in with a password, and the member's invitation is a link the
    # owner copies.
    step("an instance without mail, set up with its logged link")

    unless Apiary.Mail.source() == :none,
      do: fail("the instance has mail; E2E_MAIL=none has none")

    unless logged?(@no_mail_line),
      do: fail("the instance's start did not say that no mail is set")

    step("a workspace, its owner, a node and its access key")
    scope = owner_scope()
    {:ok, "enforce"} = Policy.set_mode(scope, "enforce")
    true = Policy.managed?(scope)
    {:ok, node} = Nodes.create_node(scope, %{"kind" => "node", "name" => "build-01"})
    {public_key, secret} = new_key()

    {:ok, access_key} =
      AccessKeys.add_access_key(scope, node, %{
        "public_key" => public_key,
        "label" => "e2e",
        "allow_secrets" => false
      })

    :active = AccessKey.status(access_key)
    write_secret(Path.dirname(forager_file), secret)

    # The key's server lines: the server's address, the key's id and the server's pin, each
    # indented as it sits under `server:`, and `server:` itself moved under `gateway:`, where
    # qory reads it.
    server = AccessKeys.server_lines(ApiaryWeb.Endpoint.url())

    gateway_section =
      Enum.map_join(
        ["server:", server.url, AccessKeys.key_line(access_key) | server.public_key],
        &("  " <> &1 <> "\n")
      )

    File.write!(forager_file, "gateway:\n" <> gateway_section <> forager_tail)

    say(
      "workspace in enforce, nothing allowed; node #{node.name}, key #{access_key.key_id}, fingerprint #{AccessKey.fingerprint(access_key)}, active; server #{ApiaryWeb.Endpoint.url()}, pinned #{Apiary.SigningKey.fingerprint()}"
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

  # A fresh Ed25519 key, as a browser's Generate a key makes one: the public key in
  # base64url without padding, as the node's page receives it, and the secret, `qak_`
  # and the key's 32-byte seed in base64url without padding (Forager's accesskey
  # package, which qory reads it with).
  defp new_key do
    {public_key, seed} = :crypto.generate_key(:eddsa, :ed25519)

    {Base.url_encode64(public_key, padding: false),
     "qak_" <> Base.url_encode64(seed, padding: false)}
  end

  # access-key-secret beside the Forager file, as qory reads it: one line, in a regular
  # file of mode 0600, in a directory of mode 0700. The file is made anew, and its mode
  # set before the secret is written into it.
  defp write_secret(dir, secret) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    path = Path.join(dir, "access-key-secret")
    _ = File.rm(path)

    File.open!(path, [:write, :exclusive], fn io ->
      File.chmod!(path, 0o600)
      IO.binwrite(io, [secret, ?\n])
    end)

    :ok
  end

  # The workspace's first owner, made the way a person makes one: the set-up link the
  # instance's start logged, read from its log and followed, on its fresh database, which
  # makes the instance's own organisation. Anyone else would need an invitation from it.
  # Without mail the owner then signs in with the password the set-up was given, with the
  # call the log-in form's post makes.
  defp owner_scope do
    email = "owner@e2e.test"
    password = new_password()
    set_up_with_logged_link(email, password)

    case Apiary.Accounts.get_user_by_email_and_password(email, password) do
      %Apiary.Accounts.User{} = user ->
        %Scope{workspace: %{}} = scope = Organisations.load_scope(Scope.for_user(user))
        scope

      nil ->
        fail("the owner cannot sign in with the password given at the set-up")
    end
  end

  # A member of the owner's workspace, joined the way a person joins without mail: an
  # invitation from the workspace, whose link the owner copies, and a sign-up with it and a
  # password of the member's own.
  defp member_scope(%Scope{workspace: %{id: workspace_id}} = owner) do
    email = "member@e2e.test"
    password = new_password()

    url =
      case Organisations.invite_member(owner, %{"email" => email}, &invitation_url/1) do
        {:ok, _invitation, {:link, url}} -> url
        other -> fail("the invitation was not a link to copy: #{inspect(other)}")
      end

    {:ok, %{user: user}} =
      Organisations.sign_up_user(
        %{email: email, password: password, password_confirmation: password},
        token_in(url, "/invitations/")
      )

    %Scope{workspace: %{id: ^workspace_id}, membership: %{level: :member}} =
      scope = Organisations.load_scope(Scope.for_user(user))

    scope
  end

  # The instance with mail, through the job's SMTP sink: the set-up with its logged link,
  # the owner's log-in link, which confirms the address, as it must be before anyone
  # sends an invitation by mail, and a member's invitation, each read from the sink as it
  # arrived there.
  defp mailed do
    step("an instance with mail through the sink, set up with its logged link")

    unless Apiary.Mail.source() == :env,
      do: fail("the instance has no mail; E2E_MAIL=sink sets it")

    if logged?(@no_mail_line), do: fail("the instance's start said that no mail is set")

    owner_email = "owner@e2e.test"
    owner = set_up_with_logged_link(owner_email, new_password())

    step("the owner's log-in link, mailed")

    {:ok, _email} =
      Apiary.Accounts.deliver_login_instructions(
        owner,
        &"#{ApiaryWeb.Endpoint.url()}/users/log-in/#{&1}"
      )

    log_in_url = mailed_url(owner_email, "/users/log-in/")

    # The first link log-in confirms the address, and removes the password set before it.
    owner =
      case Apiary.Accounts.login_user_by_magic_link(token_in(log_in_url, "/users/log-in/")) do
        {:ok, {user, _tokens}, :password_removed} -> user
        other -> fail("the log-in link did not confirm the owner as it should: #{inspect(other)}")
      end

    unless owner.confirmed_at, do: fail("the log-in link did not confirm the owner's address")
    say("the log-in link came through the sink; the owner's address is confirmed")

    step("a member's invitation, mailed")

    %Scope{workspace: %{id: workspace_id}} =
      scope = Organisations.load_scope(Scope.for_user(owner))

    member_email = "member@e2e.test"

    case Organisations.invite_member(scope, %{"email" => member_email}, &invitation_url/1) do
      {:ok, _invitation} -> :ok
      other -> fail("the invitation was not mailed: #{inspect(other)}")
    end

    invitation = mailed_url(member_email, "/invitations/")

    {:ok, %{user: member}} =
      Organisations.sign_up_user(%{email: member_email}, token_in(invitation, "/invitations/"))

    case Organisations.load_scope(Scope.for_user(member)) do
      %Scope{workspace: %{id: ^workspace_id}, membership: %{level: :member}} -> :ok
      other -> fail("the member did not join the owner's workspace: #{inspect(other)}")
    end

    say("the invitation came through the sink; the member joined the owner's workspace")
    IO.puts("E2E PASS  mail=sink set_up=logged_link log_in_link=mailed invitation=mailed")
  end

  # The set-up link the instance's start logged, followed: its page offers the form, the
  # set-up is the one the form's submit makes (`Apiary.Setup.set_up/3`, a password
  # required), and the page then says the instance is set up. The link is never printed.
  defp set_up_with_logged_link(email, password) do
    link = logged_set_up_link()
    endpoint = ApiaryWeb.Endpoint.url()

    unless String.starts_with?(link, endpoint <> "/setup/"),
      do: fail("the logged set-up link is not on the instance's address, #{endpoint}")

    code = token_in(link, "/setup/")
    form = Req.get!(link, retry: false, redirect: false)

    unless form.status == 200 and form.body =~ "Set up Qory Apiary",
      do: fail("the logged set-up link did not open the set-up form (status #{form.status})")

    user =
      case Apiary.Setup.set_up(
             code,
             %{
               "email" => email,
               "password" => password,
               "password_confirmation" => password,
               "organisation_name" => "E2E"
             },
             password: :required
           ) do
        {:ok, %{user: user}} -> user
        other -> fail("the set-up with the logged link failed: #{inspect(other)}")
      end

    done = Req.get!(link, retry: false, redirect: false)

    unless done.status == 200 and done.body =~ "This Qory Apiary is already set up.",
      do: fail("the set-up link still offers the form once used")

    say("set up with the link from the instance's log; the link now says it is set up")
    user
  end

  # The set-up link in the instance's log, waited for: the start logs it before the
  # endpoint serves, and the log reaches its file a moment later.
  defp logged_set_up_link do
    deadline = System.monotonic_time(:millisecond) + 30_000
    find_set_up_link(deadline)
  end

  defp find_set_up_link(deadline) do
    case Enum.find_value(log_messages(), &match_set_up_line/1) do
      nil ->
        if System.monotonic_time(:millisecond) > deadline,
          do: fail("no set-up link in the instance's log"),
          else: Process.sleep(@poll_ms) && find_set_up_link(deadline)

      link ->
        link
    end
  end

  defp match_set_up_line(message) do
    case Regex.run(@set_up_line, message) do
      [_line, link] -> link
      nil -> nil
    end
  end

  # Whether the instance's start logged `message`, asked once the set-up link, which the
  # start logs after the rest, has reached the log.
  defp logged?(message) do
    _link = logged_set_up_link()
    message in log_messages()
  end

  # The messages of the instance's log, `E2E_INSTANCE_LOG`: one JSON object per line in
  # production, its message under "message"; any other line, this scenario's own, as it
  # is.
  defp log_messages do
    env!("E2E_INSTANCE_LOG")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case JSON.decode(line) do
        {:ok, %{"message" => message}} when is_binary(message) -> message
        _other -> line
      end
    end)
  end

  # The link in the newest message the sink holds for `to`, whose path starts with
  # `prefix`, waited for: the sink's API, asked inside its own container
  # (`E2E_SINK_COMMAND`, with the API's path appended), since it publishes no port.
  defp mailed_url(to, prefix) do
    endpoint = ApiaryWeb.Endpoint.url()
    pattern = ~r{#{Regex.escape(endpoint <> prefix)}[A-Za-z0-9_-]+}

    await("a message to #{to} with a link to #{prefix}…", 30_000, nil, fn ->
      with %{"messages" => messages} <- sink("messages"),
           %{"ID" => id} <-
             Enum.find(messages, fn message ->
               Enum.any?(message["To"] || [], &(&1["Address"] == to))
             end),
           %{"Text" => text} <- sink("message/" <> id),
           [url] <- Regex.run(pattern, text) do
        url
      else
        _none -> nil
      end
    end)
  end

  defp sink(path) do
    case System.cmd("sh", ["-c", env!("E2E_SINK_COMMAND") <> path], stderr_to_stdout: true) do
      {body, 0} ->
        case JSON.decode(body) do
          {:ok, decoded} -> decoded
          {:error, _reason} -> nil
        end

      {_output, _status} ->
        nil
    end
  end

  defp invitation_url(token), do: "#{ApiaryWeb.Endpoint.url()}/invitations/#{token}"

  # The token at the end of a link's path, after `prefix`.
  defp token_in(url, prefix) do
    path = URI.parse(url).path || ""
    token = String.replace_prefix(path, prefix, "")

    if String.starts_with?(path, prefix) and token =~ ~r/^[A-Za-z0-9_-]+$/,
      do: token,
      else: fail("not a link to #{prefix}…")
  end

  # A password of the job's own, never printed: 24 characters, within the 12 to 72 a
  # password takes.
  defp new_password, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

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
