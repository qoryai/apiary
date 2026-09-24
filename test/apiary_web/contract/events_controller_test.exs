defmodule ApiaryWeb.Contract.EventsControllerTest do
  use ApiaryWeb.ConnCase, async: false
  # Not async: a test here changes the global log level, which would race async modules.

  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.AccessKeys
  alias Apiary.Repo
  alias Apiary.Runs
  alias Apiary.Runs.{Delivery, Event, Run}
  alias ApiaryWeb.Contract.Configuration

  @unauthorized %{"error" => "unauthorized"}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{access_key: key, secret: secret} = access_key_fixture(scope)
    %{scope: scope, key: key, secret: secret}
  end

  # An object nested `depth` levels deep, itself included.
  defp nested(1), do: %{"leaf" => true}
  defp nested(depth), do: %{"in" => nested(depth - 1)}

  defp run!(scope, subject) do
    Repo.one!(from r in Run, where: r.hive_id == ^scope.hive.id and r.run_id == ^subject)
  end

  defp events(run),
    do: Repo.all(from e in Event, where: e.run_id == ^run.id, order_by: e.sequence)

  describe "a valid delivery" do
    test "is answered 202 with the digest of discovery, and creates the run in the key's hive",
         %{conn: conn, scope: scope, key: key, secret: secret} do
      {subject, batch} = first_events()
      conn = signed_post(conn, key.key_id, secret, batch)

      assert response(conn, 202) == ""
      assert get_resp_header(conn, "x-qory-configuration") == [Configuration.digest()]

      run = run!(scope, subject)
      assert run.organisation_id == scope.organisation.id
      assert run.access_key_id == key.id
      assert run.event_count == 2
      assert run.last_event_at
      assert run.contract_version == 1

      assert [%Event{sequence: 1, type: "ai.qory.ping"}, %Event{sequence: 2} = started] =
               events(run)

      # Stored as received.
      assert started.data == Enum.at(batch, 1)["data"]
      assert started.time == ~U[2026-09-16 12:00:00.000000Z]
    end

    test "the ping alone is answered 202 and the versions are recorded on the key",
         %{conn: conn, scope: scope, key: key, secret: secret} do
      {subject, [ping, _]} = first_events()
      conn = signed_post(conn, key.key_id, secret, [ping], user_agent: "qory-runner/0.4.1")
      assert response(conn, 202)

      key = AccessKeys.get_access_key!(scope, key.id)
      assert key.last_used_at
      assert key.last_runner_version == "0.4.1"
      assert key.last_contract_version == 1
      assert key.last_heartbeat_at == nil

      # The projector has read the ping; the run has not started.
      run = run!(scope, subject)
      assert run.state == "pending"
    end

    test "a heartbeat is recorded on the key by the server's clock, not the runner's",
         %{scope: scope, key: key, secret: secret} do
      subject = Ecto.UUID.generate()
      beat = %{"elapsed_seconds" => 30, "interval_seconds" => 30}
      # A runner whose clock is a century ahead does not pin the key's heartbeat.
      future = wire_event(subject, 1, "run.heartbeat", beat, time: "2126-01-01T00:00:00Z")

      before = DateTime.utc_now()
      assert build_conn() |> signed_post(key.key_id, secret, [future]) |> response(202)
      first = AccessKeys.get_access_key!(scope, key.id).last_heartbeat_at

      assert DateTime.compare(first, before) != :lt
      assert DateTime.diff(first, before) < 60

      # The same heartbeat delivered again is not a new heartbeat.
      assert build_conn() |> signed_post(key.key_id, secret, [future]) |> response(202)
      assert AccessKeys.get_access_key!(scope, key.id).last_heartbeat_at == first

      # A new one moves it on.
      next = wire_event(subject, 2, "run.heartbeat", beat, time: "1999-01-01T00:00:00Z")
      assert build_conn() |> signed_post(key.key_id, secret, [next]) |> response(202)

      assert DateTime.compare(AccessKeys.get_access_key!(scope, key.id).last_heartbeat_at, first) !=
               :lt
    end

    test "a delivery that names no version leaves the versions the key has recorded",
         %{scope: scope, key: key, secret: secret} do
      {subject, [ping, _]} = first_events()
      assert build_conn() |> signed_post(key.key_id, secret, [ping]) |> response(202)

      beat = wire_event(subject, 2, "run.heartbeat", %{"elapsed_seconds" => 30})

      assert build_conn()
             |> signed_post(key.key_id, secret, [beat],
               contract_version: nil,
               user_agent: "curl/8"
             )
             |> response(202)

      key = AccessKeys.get_access_key!(scope, key.id)
      assert key.last_runner_version == "0.4.0"
      assert key.last_contract_version == 1
    end

    test "a repeated delivery does not touch the key", %{scope: scope, key: key, secret: secret} do
      {_subject, batch} = first_events()
      delivery = Ecto.UUID.generate()

      assert build_conn()
             |> signed_post(key.key_id, secret, batch, delivery: delivery)
             |> response(202)

      used = AccessKeys.get_access_key!(scope, key.id).last_used_at

      assert build_conn()
             |> signed_post(key.key_id, secret, batch,
               delivery: delivery,
               user_agent: "qory-runner/9.9.9"
             )
             |> response(202)

      key = AccessKeys.get_access_key!(scope, key.id)
      assert key.last_used_at == used
      assert key.last_runner_version == "0.4.0"
    end

    test "either secret verifies during a rotation", %{scope: scope, key: key, secret: old} do
      {:ok, _key, new} = AccessKeys.rotate_access_key(scope, key)

      for secret <- [old, new] do
        {_subject, batch} = first_events()
        assert build_conn() |> signed_post(key.key_id, secret, batch) |> response(202)
      end
    end

    test "sent again, byte for byte, is answered 202 and stores nothing twice",
         %{scope: scope, key: key, secret: secret} do
      {subject, batch} = first_events()
      body = Jason.encode!(batch)
      delivery = Ecto.UUID.generate()

      for _ <- 1..2 do
        assert build_conn()
               |> signed_post(key.key_id, secret, body, delivery: delivery)
               |> response(202)
      end

      run = run!(scope, subject)
      assert run.event_count == 2
      assert length(events(run)) == 2

      assert [%Delivery{event_count: 2, inserted_count: 2, status: 202, run_id: ^subject}] =
               Repo.all(from d in Delivery, where: d.access_key_id == ^key.id)
    end

    test "the same events under a new delivery id are deduplicated on their ids",
         %{scope: scope, key: key, secret: secret} do
      {subject, batch} = first_events()

      for _ <- 1..2 do
        assert build_conn() |> signed_post(key.key_id, secret, batch) |> response(202)
      end

      assert run!(scope, subject).event_count == 2

      assert [2, 0] ==
               Repo.all(
                 from d in Delivery,
                   where: d.access_key_id == ^key.id,
                   order_by: [desc: d.inserted_count],
                   select: d.inserted_count
               )
    end

    test "events arrive in any order and are read back by sequence",
         %{scope: scope, key: key, secret: secret} do
      {subject, [ping, started]} = first_events()
      assert build_conn() |> signed_post(key.key_id, secret, [started]) |> response(202)
      assert build_conn() |> signed_post(key.key_id, secret, [ping]) |> response(202)

      assert [1, 2] == scope |> run!(subject) |> events() |> Enum.map(& &1.sequence)
    end

    test "a type the apiary does not know is kept", %{scope: scope, key: key, secret: secret} do
      subject = Ecto.UUID.generate()
      event = wire_event(subject, 1, "session.something_new", %{"anything" => [1, %{"a" => nil}]})
      assert build_conn() |> signed_post(key.key_id, secret, [event]) |> response(202)

      assert [%Event{type: "ai.qory.session.something_new", data: data}] =
               scope |> run!(subject) |> events()

      assert data == %{"anything" => [1, %{"a" => nil}]}
    end

    test "without X-Qory-Contract-Version and X-Qory-Delivery: a plain client of the contract",
         %{scope: scope, key: key, secret: secret} do
      subject = Ecto.UUID.generate()
      beat = wire_event(subject, 1, "run.heartbeat", %{"elapsed_seconds" => 30})

      conn =
        signed_post(build_conn(), key.key_id, secret, [beat],
          contract_version: nil,
          delivery: nil
        )

      assert response(conn, 202)
      assert run!(scope, subject).contract_version == nil
      assert Repo.aggregate(from(d in Delivery, where: d.access_key_id == ^key.id), :count) == 1
    end

    test "the run configuration digest the runner holds is kept when it has the shape",
         %{scope: scope, key: key, secret: secret} do
      {subject, [ping, started]} = first_events()
      digest = "sha256=" <> String.duplicate("ab", 32)

      assert build_conn()
             |> signed_post(key.key_id, secret, [ping], run_configuration: digest)
             |> response(202)

      assert run!(scope, subject).reported_run_configuration_digest == digest

      assert build_conn()
             |> signed_post(key.key_id, secret, [started], run_configuration: "sha256=nonsense")
             |> response(202)

      assert run!(scope, subject).reported_run_configuration_digest == digest
    end

    test "a NUL in the data, which Postgres cannot hold, is replaced and not a 500",
         %{scope: scope, key: key, secret: secret} do
      subject = Ecto.UUID.generate()
      event = wire_event(subject, 1, "session.prompt_submitted", %{"prompt" => "a\u0000b"})
      assert build_conn() |> signed_post(key.key_id, secret, [event]) |> response(202)
      assert [%Event{data: %{"prompt" => "a�b"}}] = scope |> run!(subject) |> events()
    end
  end

  describe "tenancy" do
    test "a subject that exists under another hive is simply another run there",
         %{scope: scope, key: key, secret: secret} do
      %{scope: other} = sign_up_fixture()
      %{access_key: other_key, secret: other_secret} = access_key_fixture(other)
      {subject, [ping, _]} = first_events()
      # The same subject, other events: ids are unique within a hive.
      other_ping = wire_event(subject, 1, "ping", ping["data"])

      assert build_conn() |> signed_post(key.key_id, secret, [ping]) |> response(202)

      assert build_conn()
             |> signed_post(other_key.key_id, other_secret, [other_ping])
             |> response(202)

      assert run!(scope, subject).id != run!(other, subject).id
      assert run!(other, subject).organisation_id == other.organisation.id
      assert length(events(run!(scope, subject))) == 1
      assert length(events(run!(other, subject))) == 1

      # And the run of one hive is not reachable from the other's scope.
      assert_raise Ecto.NoResultsError, fn -> Runs.get_run!(other, run!(scope, subject).id) end
    end

    test "even the same event ids are another hive's own", %{
      scope: scope,
      key: key,
      secret: secret
    } do
      %{scope: other} = sign_up_fixture()
      %{access_key: other_key, secret: other_secret} = access_key_fixture(other)
      {subject, batch} = first_events()

      assert build_conn() |> signed_post(key.key_id, secret, batch) |> response(202)
      assert build_conn() |> signed_post(other_key.key_id, other_secret, batch) |> response(202)

      assert run!(scope, subject).event_count == 2
      assert run!(other, subject).event_count == 2
    end
  end

  describe "collisions" do
    test "an event whose id exists under a different run is dropped, not an error",
         %{scope: scope, key: key, secret: secret} do
      {subject, [ping, _]} = first_events()
      assert build_conn() |> signed_post(key.key_id, secret, [ping]) |> response(202)

      other = Ecto.UUID.generate()
      thief = wire_event(other, 1, "ping", ping["data"], id: ping["id"])

      fine =
        wire_event(other, 2, "run.heartbeat", %{"elapsed_seconds" => 1, "interval_seconds" => 30})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert build_conn() |> signed_post(key.key_id, secret, [thief, fine]) |> response(202)
        end)

      assert log =~ "1 event(s) that collide"
      refute log =~ ping["id"]

      assert [%Event{sequence: 2}] = scope |> run!(other) |> events()
      assert run!(scope, other).event_count == 1
      assert [%Event{sequence: 1}] = scope |> run!(subject) |> events()
    end

    test "a sequence that exists with another id is dropped, not an error",
         %{scope: scope, key: key, secret: secret} do
      {subject, [ping, _]} = first_events()
      assert build_conn() |> signed_post(key.key_id, secret, [ping]) |> response(202)

      usurper = wire_event(subject, 1, "run.exited", %{"state" => "failed"})

      ExUnit.CaptureLog.capture_log(fn ->
        assert build_conn() |> signed_post(key.key_id, secret, [usurper]) |> response(202)
      end)

      assert [%Event{type: "ai.qory.ping"}] = scope |> run!(subject) |> events()
    end
  end

  describe "a closed run" do
    test "is answered 410 with the digest; the delivery is recorded and nothing else",
         %{scope: scope, key: key, secret: secret} do
      {subject, [ping, started]} = first_events()
      assert build_conn() |> signed_post(key.key_id, secret, [ping]) |> response(202)
      {:ok, _run} = Runs.close_run(scope, run!(scope, subject))

      conn = signed_post(build_conn(), key.key_id, secret, [started])
      assert response(conn, 410) == ""
      assert get_resp_header(conn, "x-qory-configuration") == [Configuration.digest()]

      run = run!(scope, subject)
      assert run.state == "closed"
      assert run.event_count == 1
      assert length(events(run)) == 1

      assert [202, 410] ==
               Repo.all(
                 from d in Delivery,
                   where: d.access_key_id == ^key.id,
                   order_by: d.status,
                   select: d.status
               )
    end
  end

  describe "refusals, in order" do
    test "a body over 2 MiB is 413 before the signature is looked at", %{conn: conn, key: key} do
      body = String.duplicate("x", ApiaryWeb.Contract.RawBody.max_bytes() + 1)
      conn = signed_post(conn, key.key_id, "not the secret", body)
      assert json_response(conn, 413) == %{"error" => "payload_too_large"}
    end

    test "a body of exactly 2 MiB is read and verified", %{conn: conn, key: key, secret: secret} do
      body = String.duplicate(" ", ApiaryWeb.Contract.RawBody.max_bytes())
      conn = signed_post(conn, key.key_id, secret, body)
      assert json_response(conn, 400) == %{"error" => "invalid_batch"}
    end

    test "a bad signature is 401 before the content type is looked at", %{conn: conn, key: key} do
      {_subject, batch} = first_events()
      conn = signed_post(conn, key.key_id, "not the secret", batch, content_type: "text/plain")
      assert json_response(conn, 401) == @unauthorized
    end

    test "another content type is 415, whatever the body", %{key: key, secret: secret} do
      {_subject, batch} = first_events()

      for content_type <- ["application/json", "text/plain", "application/x-www-form-urlencoded"] do
        conn = signed_post(build_conn(), key.key_id, secret, batch, content_type: content_type)
        assert json_response(conn, 415) == %{"error" => "unsupported_media_type"}
      end
    end

    test "the content type is read without its case or parameters", %{key: key, secret: secret} do
      {_subject, batch} = first_events()

      conn =
        signed_post(build_conn(), key.key_id, secret, batch,
          content_type: "Application/CloudEvents-Batch+JSON; charset=utf-8"
        )

      assert response(conn, 202)
    end

    test "every revision of v1 is accepted, a later one than the server knows too",
         %{key: key, secret: secret} do
      for version <- ["1", "2", "3"] do
        {_subject, batch} = first_events()
        conn = signed_post(build_conn(), key.key_id, secret, batch, contract_version: version)
        assert response(conn, 202)
      end
    end

    test "an unsupported contract version is 400 and says what is served",
         %{scope: scope, key: key, secret: secret} do
      {subject, batch} = first_events()

      for version <- ["0", "-1", "one", "1.0"] do
        conn = signed_post(build_conn(), key.key_id, secret, batch, contract_version: version)

        assert json_response(conn, 400) == %{
                 "error" => "unsupported_contract_version",
                 "supported" => [1]
               }
      end

      refute Repo.exists?(
               from r in Run, where: r.hive_id == ^scope.hive.id and r.run_id == ^subject
             )
    end

    test "a body that is not a batch is 400 and echoes nothing", %{key: key, secret: secret} do
      subject = Ecto.UUID.generate()
      good = wire_event(subject, 1, "ping")

      bodies = [
        "",
        "not json",
        "{}",
        "[]",
        "[1]",
        Jason.encode!(good),
        Jason.encode!([Map.delete(good, "id")]),
        Jason.encode!([%{good | "id" => "not-a-uuid"}]),
        Jason.encode!([%{good | "id" => String.upcase(good["id"])}]),
        Jason.encode!([%{good | "subject" => "not-a-uuid"}]),
        Jason.encode!([%{good | "type" => "com.example.other"}]),
        Jason.encode!([%{good | "type" => "ai.qory.a\u0000b"}]),
        Jason.encode!([%{good | "sequence" => "1"}]),
        Jason.encode!([%{good | "sequence" => 1}]),
        # The contract numbers from 0000000001.
        Jason.encode!([%{good | "sequence" => "0000000000"}]),
        # Times Postgres has no timestamp for, or that no run has seen.
        Jason.encode!([%{good | "time" => "1969-12-31T23:59:59Z"}]),
        Jason.encode!([%{good | "time" => "-0001-01-01T00:00:00Z"}]),
        Jason.encode!([%{good | "time" => "10000-01-01T00:00:00Z"}]),
        # data nested deeper than 64 levels
        Jason.encode!([%{good | "data" => nested(65)}]),
        # more events than a batch may hold
        Jason.encode!(for(n <- 1..1001, do: wire_event(subject, n, "run.log"))),
        Jason.encode!([%{good | "source" => "urn:qory:run:" <> Ecto.UUID.generate()}]),
        Jason.encode!([%{good | "time" => "yesterday"}]),
        Jason.encode!([%{good | "data" => []}]),
        Jason.encode!([Map.delete(good, "data")]),
        # Two subjects in one batch.
        Jason.encode!([good, wire_event(Ecto.UUID.generate(), 2, "ping")])
      ]

      for body <- bodies do
        conn = signed_post(build_conn(), key.key_id, secret, body)
        assert json_response(conn, 400) == %{"error" => "invalid_batch"}
      end

      assert Repo.aggregate(Run, :count) == 0
    end

    test "the limits themselves are accepted: 1000 events, data 64 levels deep, the years 1970 and 9999",
         %{scope: scope, key: key, secret: secret} do
      subject = Ecto.UUID.generate()

      events =
        [
          wire_event(subject, 1, "session.tool_started", nested(64),
            time: "1970-01-01T00:00:00Z"
          ),
          wire_event(subject, 2, "session.ended", %{}, time: "9999-12-31T23:59:59.999999Z")
        ] ++
          for(
            n <- 3..1000,
            do: wire_event(subject, n, "session.notification", %{"kind" => "idle"})
          )

      # Out of order on the wire; stored in one go all the same.
      assert build_conn()
             |> signed_post(key.key_id, secret, Enum.reverse(events))
             |> response(202)

      run = run!(scope, subject)
      assert run.event_count == 1000
      assert [%Event{sequence: 1, data: data} | _] = events(run)
      assert data == nested(64)
    end

    test "the encoded path is the events endpoint too: nothing is parsed before the signature",
         %{key: key, secret: secret} do
      for path <- ["/v1/%65vents", "/%761/events"] do
        conn =
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> put_req_header("x-qory-access-key", key.key_id)
          |> put_req_header("x-qory-signature-256", "sha256=" <> String.duplicate("0", 64))
          |> post(path, "{not json")

        assert json_response(conn, 401) == @unauthorized

        body = "[not a batch"

        conn =
          build_conn()
          |> put_req_header("content-type", content_type())
          |> put_req_header("x-qory-access-key", key.key_id)
          |> put_req_header("x-qory-signature-256", Apiary.Contract.Signature.sign(secret, body))
          |> post(path, body)

        assert json_response(conn, 400) == %{"error" => "invalid_batch"}
      end
    end

    test "other methods are not served", %{conn: conn} do
      assert conn |> get("/v1/events") |> response(404)
    end
  end

  describe "the signature" do
    test "is checked before anything is parsed: invalid JSON is 401 unsigned and 400 signed",
         %{key: key, secret: secret} do
      body = "[{\"id\": "

      conn =
        signed_post(build_conn(), key.key_id, secret, body,
          signature: "sha256=" <> String.duplicate("0", 64)
        )

      assert json_response(conn, 401) == @unauthorized

      conn = signed_post(build_conn(), key.key_id, secret, body)
      assert json_response(conn, 400) == %{"error" => "invalid_batch"}
    end

    test "a body changed after signing is refused", %{scope: scope, key: key, secret: secret} do
      {subject, batch} = first_events()
      body = Jason.encode!(batch)
      signature = Apiary.Contract.Signature.sign(secret, body)
      tampered = String.replace(body, "dev-laptop", "dev-laptoq")

      conn = signed_post(build_conn(), key.key_id, secret, tampered, signature: signature)
      assert json_response(conn, 401) == @unauthorized

      refute Repo.exists?(
               from r in Run, where: r.hive_id == ^scope.hive.id and r.run_id == ^subject
             )
    end

    test "every failure is the same 401", %{scope: scope, key: key, secret: secret} do
      {_subject, batch} = first_events()
      body = Jason.encode!(batch)
      good = Apiary.Contract.Signature.sign(secret, body)
      %{access_key: revoked, secret: revoked_secret} = access_key_fixture(scope)
      {:ok, _} = AccessKeys.revoke_access_key(scope, revoked)

      attempts = [
        # an unknown key, a key of the wrong shape, one that is not UTF-8
        {"ak_0000000000000000", secret, []},
        {"ak_SHOUTING00000000", secret, []},
        {"ak_" <> <<255>> <> "00000000000000", secret, []},
        # a revoked key, on the ping as on anything else
        {revoked.key_id, revoked_secret, []},
        # the signature: another secret, no prefix, upper case, empty
        {key.key_id, "another secret", []},
        {key.key_id, secret, [signature: String.replace_prefix(good, "sha256=", "")]},
        {key.key_id, secret, [signature: String.upcase(good)]},
        {key.key_id, secret, [signature: ""]},
        # a header sent twice
        {key.key_id, secret, [headers: [{"x-qory-signature-256", good}]]},
        {key.key_id, secret, [headers: [{"x-qory-access-key", key.key_id}]]},
        {key.key_id, secret, [headers: [{"x-qory-timestamp", "1"}, {"x-qory-timestamp", "1"}]]}
      ]

      for {key_id, secret, opts} <- attempts do
        conn = signed_post(build_conn(), key_id, secret, body, opts)
        assert json_response(conn, 401) == @unauthorized
      end

      assert Repo.aggregate(Run, :count) == 0
    end

    test "a timestamp on a POST is ignored, whatever it says", %{key: key, secret: secret} do
      {_subject, batch} = first_events()

      conn =
        signed_post(build_conn(), key.key_id, secret, batch, headers: [{"x-qory-timestamp", "1"}])

      assert response(conn, 202)
    end

    test "a signed GET of the events endpoint's pipeline still needs its timestamp",
         %{key: key, secret: secret} do
      # The POST rules are for a POST only: the discovery GET signed over an empty
      # body, as a POST would be, is refused.
      conn =
        build_conn()
        |> put_req_header("x-qory-access-key", key.key_id)
        |> put_req_header("x-qory-signature-256", Apiary.Contract.Signature.sign(secret, ""))
        |> get("/.well-known/qory-configuration")

      assert json_response(conn, 401) == @unauthorized
    end
  end

  describe "secrets stay out of the logs and the rows" do
    @tag capture_log: true
    test "a whole delivery at debug level", %{scope: scope, key: key, secret: secret} do
      {subject, batch} = first_events()
      body = Jason.encode!(batch)
      signature = Apiary.Contract.Signature.sign(secret, body)
      "sha256=" <> hex = signature
      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert build_conn() |> signed_post(key.key_id, secret, body) |> response(202)
          # and a refused one
          assert build_conn()
                 |> signed_post(key.key_id, secret, body <> " ", signature: signature)
                 |> response(401)
        end)

      Logger.configure(level: level)

      assert log =~ "POST /v1/events"
      refute log =~ secret
      refute log =~ hex
      run = run!(scope, subject)

      rows =
        [run, Repo.all(Delivery), AccessKeys.get_access_key!(scope, key.id)]
        |> inspect(limit: :infinity, printable_limit: :infinity)

      refute rows =~ secret
      refute rows =~ hex

      for table <- ~w(runs events deliveries log_chunks connections targets) do
        %{rows: rows} = Repo.query!("SELECT row_to_json(t)::text FROM #{table} t", [], log: false)
        text = Enum.join(List.flatten(rows), "\n")
        refute text =~ secret
        refute text =~ hex
      end
    end
  end
end
