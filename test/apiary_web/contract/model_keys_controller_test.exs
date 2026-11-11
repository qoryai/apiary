defmodule ApiaryWeb.Contract.ModelKeysControllerTest do
  # A gateway's report of the states of a run's model keys,
  # `POST /v1/runs/<run_id>/model-keys`, and its answer, the newest state of each key of
  # the run from every gateway; and each refusal. The run is one of a workspace's queue,
  # claimed with a model provider and attached by the gateway
  # (`Apiary.SealedRunsFixtures`). Not async, as the other contract tests of a pool: the
  # features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures

  alias Apiary.{ForagerSchemas, ModelKeys, Policy, Repo}
  alias Apiary.ModelKeys.State
  alias Apiary.Runs.Run
  alias Apiary.Secrets.Value
  alias ApiaryWeb.Contract.{RawBody, SignedRequest}

  @moduletag needs: [:factory, :secrets, :observability]

  setup do
    %{scope: scope} = sign_up_fixture()
    {:ok, _rule} = Policy.allow(scope, nil, %{host: "git.example"})
    ctx = scope |> sealed_run_fixture() |> Map.put(:scope, scope)

    value =
      Repo.one!(
        from v in Value, where: v.secret_id == ^ctx.provider.secret_id and v.value_id == "main"
      )

    Map.put(ctx, :value, value)
  end

  defp now_z(offset \\ 0) do
    (SignedRequest.now() + offset)
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end

  defp state(ctx, attrs \\ %{}) do
    %{
      "credential" => "#{ctx.provider.public_id}-1",
      "window" => "five_hour",
      "status" => "rejected",
      "resets_at" => now_z(3600),
      "utilization" => 100,
      "cooldown_until" => now_z(3600),
      "source" => "provider",
      "observed_at" => now_z(-1)
    }
    |> Map.merge(Map.new(attrs, fn {name, value} -> {to_string(name), value} end))
    |> Map.reject(fn {_name, value} -> is_nil(value) end)
  end

  defp report(ctx, keys, attrs \\ %{}) do
    %{"version" => 1, "run_id" => ctx.run.node_run_id, "time" => now_z(), "keys" => keys}
    |> Map.merge(Map.new(attrs, fn {name, value} -> {to_string(name), value} end))
    |> Jason.encode!()
  end

  defp post_report(ctx, body, opts \\ []) do
    {key, seed} = Keyword.get(opts, :key, ctx.secrets_key)
    run_id = Keyword.get(opts, :run_id, ctx.run.node_run_id)

    signed_post(build_conn(), key.key_id, seed, body,
      target: "/v1/runs/#{run_id}/model-keys",
      content_type: "application/json",
      delivery: nil
    )
  end

  defp rows, do: Repo.all(from s in State, order_by: [s.secret_value_id, s.window])

  describe "a report for a live run" do
    test "is stored by the key's row id and answered the run's keys' states", ctx do
      body = report(ctx, [state(ctx)])
      assert ForagerSchemas.validate("model-keys-report.schema.json", body) == :ok

      {conn, log} = with_log(fn -> post_report(ctx, body) end)

      assert conn.status == 200
      assert signed_answer?(conn)
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      assert ForagerSchemas.validate("model-keys-answer.schema.json", conn.resp_body) == :ok

      assert [%State{} = row] = rows()
      assert row.secret_value_id == ctx.value.id
      assert row.organisation_id == ctx.scope.organisation.id
      assert {row.window, row.status, row.utilization} == {"five_hour", "rejected", 100}
      assert DateTime.to_unix(row.cooldown_until) == SignedRequest.now() + 3600

      assert Jason.decode!(conn.resp_body) == %{
               "version" => 1,
               "keys" => [Jason.decode!(Jason.encode!(state(ctx)))]
             }

      refute log =~ model_key()
      refute log =~ body
    end

    test "is answered the states from every gateway, the newest per window", ctx do
      # A state another run's gateway reported for the same key.
      :ok =
        ModelKeys.record(
          [
            %{
              name: "other",
              secret_value_id: ctx.value.id,
              organisation_id: ctx.value.organisation_id
            }
          ],
          [
            %{
              credential: "other",
              window: "seven_day",
              status: "allowed_warning",
              utilization: 76,
              resets_at: ~U[2099-01-05 09:00:00Z],
              source: "provider",
              observed_at: DateTime.utc_now()
            }
          ],
          DateTime.utc_now()
        )

      conn = post_report(ctx, report(ctx, [state(ctx)]))
      assert conn.status == 200

      assert %{"keys" => [five, seven]} = Jason.decode!(conn.resp_body)
      assert five["window"] == "five_hour"

      assert seven == %{
               "credential" => "#{ctx.provider.public_id}-1",
               "window" => "seven_day",
               "status" => "allowed_warning",
               "resets_at" => "2099-01-05T09:00:00Z",
               "utilization" => 76,
               "source" => "provider",
               "observed_at" => seven["observed_at"]
             }

      # An empty report reads the states alone.
      conn = post_report(ctx, report(ctx, []))
      assert %{"keys" => [_, _]} = Jason.decode!(conn.resp_body)
    end

    test "replayed older is answered the newer state, which stays", ctx do
      newer = state(ctx, observed_at: now_z(-1))
      assert post_report(ctx, report(ctx, [newer])).status == 200

      older =
        state(ctx,
          status: "allowed",
          utilization: 50,
          cooldown_until: nil,
          observed_at: now_z(-60)
        )

      conn = post_report(ctx, report(ctx, [older]))
      assert conn.status == 200
      assert %{"keys" => [answered]} = Jason.decode!(conn.resp_body)
      assert {answered["status"], answered["utilization"]} == {"rejected", 100}
      assert [%State{status: "rejected", utilization: 100}] = rows()
    end

    test "holds a resets_at and a cooldown_until to 31 days after observed_at", ctx do
      observed = SignedRequest.now() - 1
      bound = DateTime.from_unix!(observed + 31 * 86_400)
      later = DateTime.to_iso8601(DateTime.add(bound, 1, :second))
      observed_z = observed |> DateTime.from_unix!() |> DateTime.to_iso8601()

      five = state(ctx, resets_at: later, cooldown_until: later, observed_at: observed_z)

      seven =
        state(ctx,
          window: "seven_day",
          status: "allowed",
          cooldown_until: nil,
          resets_at: DateTime.to_iso8601(bound),
          observed_at: observed_z
        )

      conn = post_report(ctx, report(ctx, [five, seven]))

      assert conn.status == 200

      assert [five, seven_row] = rows() |> Enum.sort_by(& &1.window)
      assert {five.window, seven_row.window} == {"five_hour", "seven_day"}
      assert DateTime.compare(five.resets_at, bound) == :eq
      assert DateTime.compare(five.cooldown_until, bound) == :eq
      assert DateTime.compare(seven_row.resets_at, bound) == :eq

      bound_z = DateTime.to_iso8601(bound)
      %{"keys" => answered} = Jason.decode!(conn.resp_body)
      five_answer = Enum.find(answered, &(&1["window"] == "five_hour"))
      assert {five_answer["resets_at"], five_answer["cooldown_until"]} == {bound_z, bound_z}
    end

    test "takes 66 entries, 6 keys of 11 windows", ctx do
      entries =
        for n <- 1..6, window <- State.windows() do
          state(ctx,
            credential: "#{ctx.provider.public_id}-#{n}",
            window: window,
            status: "allowed",
            cooldown_until: nil,
            resets_at: nil,
            utilization: nil
          )
        end

      assert length(entries) == 66
      conn = post_report(ctx, report(ctx, entries))
      assert conn.status == 200
      # The run has one key, so its 11 windows are stored.
      assert Enum.sort(Enum.map(rows(), & &1.window)) == Enum.sort(State.windows())
    end

    test "stores 66 entries for a run of 6 keys, 11 windows each" do
      %{scope: scope} = sign_up_fixture()
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "git.example"})

      six =
        sealed_run_fixture(scope,
          keys: for(n <- 1..6, do: %{value_id: "key-#{n}", value: "sk-ant-six-#{n}-0123456789"})
        )

      assert length(Repo.get!(Run, six.run.id).model_keys) == 6

      entries =
        for n <- 1..6, window <- State.windows() do
          state(six,
            credential: "#{six.provider.public_id}-#{n}",
            window: window,
            status: "allowed",
            cooldown_until: nil,
            resets_at: nil,
            utilization: nil
          )
        end

      conn = post_report(six, report(six, entries))
      assert conn.status == 200

      stored = Repo.all(from s in State, where: s.organisation_id == ^scope.organisation.id)
      assert length(stored) == 66
      assert stored |> Enum.map(& &1.secret_value_id) |> Enum.uniq() |> length() == 6
    end

    test "leaves out a window outside the contract's list, and takes the rest", ctx do
      body =
        report(ctx, [
          state(ctx),
          state(ctx, window: "seven_day_haiku"),
          state(ctx, window: "seven_day", status: "allowed", cooldown_until: nil)
        ])

      conn = post_report(ctx, body)
      assert conn.status == 200
      assert %{"keys" => keys} = Jason.decode!(conn.resp_body)
      assert Enum.map(keys, & &1["window"]) == ["five_hour", "seven_day"]
      assert Enum.map(rows(), & &1.window) == ["five_hour", "seven_day"]
    end

    test "leaves out a credential the run does not have", ctx do
      # Another provider of the same organisation, whose key no credential of the run is.
      {:ok, other} =
        Apiary.Connections.create_provider(ctx.scope, %{
          provider: "anthropic",
          keys: [%{value_id: "main", value: "sk-ant-fixture-other-0123456789"}]
        })

      body =
        report(ctx, [
          state(ctx, credential: other.public_id),
          state(ctx, credential: "registry"),
          state(ctx, credential: "model-9")
        ])

      conn = post_report(ctx, body)
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"version" => 1, "keys" => []}
      assert rows() == []
    end
  end

  describe "the refusals" do
    test "400 invalid_request for a body that fails the schema", ctx do
      good = Jason.decode!(report(ctx, [state(ctx)]))
      item = state(ctx)

      for {body, name} <- [
            {"not json", "body"},
            {Jason.encode!(Map.put(good, "version", 2)), "version"},
            {Jason.encode!(Map.put(good, "extra", true)), "body"},
            {Jason.encode!(Map.delete(good, "time")), "body"},
            {Jason.encode!(Map.put(good, "run_id", Ecto.UUID.generate())), "run_id"},
            {Jason.encode!(Map.put(good, "time", "yesterday")), "time"},
            {Jason.encode!(Map.put(good, "keys", %{})), "keys"},
            {report(ctx, [Map.put(item, "extra", 1)]), "keys"},
            {report(ctx, [Map.delete(item, "source")]), "keys"},
            {report(ctx, [Map.put(item, "credential", "Model")]), "keys.credential"},
            {report(ctx, [Map.put(item, "window", "5h")]), "keys.window"},
            {report(ctx, [Map.put(item, "status", "capped")]), "keys.status"},
            {report(ctx, [Map.put(item, "source", "guess")]), "keys.source"},
            {report(ctx, [Map.put(item, "utilization", 101)]), "keys.utilization"},
            {report(ctx, [Map.put(item, "utilization", 0.5)]), "keys.utilization"},
            {report(ctx, [Map.put(item, "resets_at", "soon")]), "keys.resets_at"},
            {report(ctx, [Map.delete(item, "cooldown_until")]), "keys.cooldown_until"},
            {report(ctx, [Map.put(item, "status", "allowed")]), "keys.cooldown_until"},
            {report(ctx, [state(ctx, status: "allowed_warning")]), "keys.cooldown_until"},
            {report(ctx, [], time: String.replace(now_z(), "Z", ".500Z")), "time"},
            {report(
               ctx,
               List.duplicate(
                 state(ctx,
                   status: "allowed",
                   cooldown_until: nil,
                   resets_at: nil,
                   utilization: nil
                 ),
                 67
               )
             ), "keys"},
            {report(ctx, [Map.put(item, "observed_at", now_z(600))]), "observed_at"},
            {String.replace(report(ctx, []), ~s("version":1), ~s("version":1,"version":1)),
             "body"}
          ] do
        conn = post_report(ctx, body)
        assert conn.status == 400, body
        assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_request", "names" => [name]}
        assert signed_answer?(conn)

        # The schema refuses each of these too; a run id other than the path's and an
        # observed_at ahead of the server's clock are the server's rules.
        if name not in ["body", "run_id", "observed_at"] do
          assert {:error, _} = ForagerSchemas.validate("model-keys-report.schema.json", body),
                 body
        end
      end

      assert rows() == []
    end

    test "400 invalid_request, names observed_at, for an observed_at over 300 s ahead",
         ctx do
      ahead = state(ctx, observed_at: now_z(400))
      conn = post_report(ctx, report(ctx, [state(ctx, window: "seven_day"), ahead]))

      assert conn.status == 400

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "invalid_request",
               "names" => ["observed_at"]
             }

      assert signed_answer?(conn)
      assert rows() == []

      # 301 s ahead is refused, and 300 s ahead is taken.
      conn = post_report(ctx, report(ctx, [state(ctx, observed_at: now_z(301))]))
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["names"] == ["observed_at"]
      assert rows() == []

      conn = post_report(ctx, report(ctx, [state(ctx, observed_at: now_z(300))]))
      assert conn.status == 200
    end

    test "413 for a body over 32 KiB, before the signature; 32 KiB is read", ctx do
      assert RawBody.max_bytes(:model_keys) == 32 * 1024

      conn = post_report(ctx, String.duplicate(" ", 32 * 1024 + 1))
      assert conn.status == 413

      conn = post_report(ctx, String.duplicate(" ", 32 * 1024))
      assert conn.status == 400
    end

    test "401, unsigned, for a time outside the window", ctx do
      conn = post_report(ctx, report(ctx, [state(ctx)], time: now_z(-301)))
      assert conn.status == 401
      assert unsigned_answer?(conn)
      assert rows() == []
    end

    test "404 for another organisation's run, either way", ctx do
      %{scope: other_scope} = sign_up_fixture()
      {:ok, _rule} = Policy.allow(other_scope, nil, %{host: "git.example"})
      other = sealed_run_fixture(other_scope)

      # This gateway's key, for the other organisation's run.
      body =
        report(ctx, [state(ctx, credential: "#{other.provider.public_id}-1")],
          run_id: other.run.node_run_id
        )

      conn = post_report(ctx, body, run_id: other.run.node_run_id)
      assert conn.status == 404
      assert signed_answer?(conn)

      # The other gateway's key, for this run, naming this run's credential.
      conn = post_report(ctx, report(ctx, [state(ctx)]), key: other.secrets_key)
      assert conn.status == 404
      assert rows() == []
    end

    test "404 for a run the server does not know", ctx do
      run_id = Ecto.UUID.generate()
      conn = post_report(ctx, report(ctx, [state(ctx)], run_id: run_id), run_id: run_id)
      assert conn.status == 404
      assert signed_answer?(conn)
    end

    test "404 for a key of the run's gateway that its run key does not list", ctx do
      %{access_key: other, pair: pair} =
        Apiary.AccessKeysFixtures.enrolled_key_fixture(ctx.scope, ctx.gateway, %{
          allow_secrets: true
        })

      conn = post_report(ctx, report(ctx, [state(ctx)]), key: {other, pair.secret})
      assert conn.status == 404
      assert rows() == []
    end

    test "410 for a run that has ended", ctx do
      {1, _} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [state: "completed"])

      conn = post_report(ctx, report(ctx, [state(ctx)]))
      assert conn.status == 410
      assert signed_answer?(conn)
      assert rows() == []
    end

    test "410 that stores a report up to 60 s after the run's exit, and none later", ctx do
      exited = fn seconds_ago ->
        Repo.delete_all(from(e in Apiary.Runs.Event, where: e.run_id == ^ctx.run.id))

        Apiary.RunEventsFixtures.event_fixture(ctx.run, 1, "run.exited", %{},
          received_at: DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
        )

        {1, _} =
          Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [state: "completed"])
      end

      exited.(61)
      conn = post_report(ctx, report(ctx, [state(ctx)]))
      assert conn.status == 410
      assert signed_answer?(conn)
      assert rows() == []

      exited.(59)
      conn = post_report(ctx, report(ctx, [state(ctx)]))
      assert conn.status == 410
      assert signed_answer?(conn)
      assert [%State{window: "five_hour", status: "rejected"}] = rows()
    end

    test "410 that stores a report up to 60 s after the server ended the run, before its exit",
         ctx do
      lost = fn seconds_ago ->
        Repo.delete_all(State)

        {1, _} =
          Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
            set: [
              state: "lost",
              lost_at: DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
            ]
          )
      end

      # No `dev.qory.run.exited` has come: the lost-run check ended the run.
      lost.(61)
      conn = post_report(ctx, report(ctx, [state(ctx)]))
      assert conn.status == 410
      assert rows() == []

      lost.(59)
      conn = post_report(ctx, report(ctx, [state(ctx)]))
      assert conn.status == 410
      assert signed_answer?(conn)
      assert [%State{window: "five_hour"}] = rows()
    end

    test "410 that reads a refusal's arrival, not the time the gateway gave it", ctx do
      future = ~U[2099-01-01 00:00:00.000000Z]

      refused = fn seconds_ago ->
        Repo.delete_all(State)
        Repo.delete_all(from(e in Apiary.Runs.Event, where: e.run_id == ^ctx.run.id))

        Apiary.RunEventsFixtures.event_fixture(ctx.run, 1, "run.refused", %{},
          time: future,
          received_at: DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
        )

        {1, _} =
          Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
            set: [state: "failed", refused_at: future]
          )
      end

      # The refusal is dated 2099 by the gateway's clock, and arrived 61 s ago.
      refused.(61)
      conn = post_report(ctx, report(ctx, [state(ctx)]))
      assert conn.status == 410
      assert rows() == []

      refused.(59)
      conn = post_report(ctx, report(ctx, [state(ctx)]))
      assert conn.status == 410
      assert [%State{window: "five_hour"}] = rows()
    end

    test "410 that a refusal sent after the exit leaves closed", ctx do
      Repo.delete_all(from(e in Apiary.Runs.Event, where: e.run_id == ^ctx.run.id))

      # The run exited 2 h ago; its gateway posts a refusal now.
      Apiary.RunEventsFixtures.event_fixture(ctx.run, 1, "run.exited", %{},
        received_at: DateTime.add(DateTime.utc_now(), -7200, :second)
      )

      Apiary.RunEventsFixtures.event_fixture(ctx.run, 2, "run.refused", %{},
        received_at: DateTime.utc_now()
      )

      {1, _} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [state: "completed"])

      conn = post_report(ctx, report(ctx, [state(ctx)]))
      assert conn.status == 410
      assert rows() == []
    end

    test "410 that a lost exit dated by the gateway in 2099 leaves closed", ctx do
      future = ~U[2099-01-01 00:00:00.000000Z]
      Repo.delete_all(from(e in Apiary.Runs.Event, where: e.run_id == ^ctx.run.id))

      # The exit has the state lost and the gateway's time 2099, so the fold sets both
      # `exited_at` and `lost_at` to that time; the server received it 61 s ago.
      Apiary.RunEventsFixtures.event_fixture(ctx.run, 1, "run.exited", %{"state" => "lost"},
        time: future,
        received_at: DateTime.add(DateTime.utc_now(), -61, :second)
      )

      {1, _} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
          set: [state: "lost", exited_at: future, lost_at: future]
        )

      conn = post_report(ctx, report(ctx, [state(ctx)]))
      assert conn.status == 410
      assert rows() == []
    end

    test "a report before the run's exit is stored and answered, and one after is 410", ctx do
      conn = post_report(ctx, report(ctx, [state(ctx)]))
      assert conn.status == 200
      assert [%State{window: "five_hour"}] = rows()

      Apiary.RunEventsFixtures.event_fixture(ctx.run, 1, "run.exited", %{},
        received_at: DateTime.add(DateTime.utc_now(), -120, :second)
      )

      seven = state(ctx, window: "seven_day", status: "allowed", cooldown_until: nil)
      conn = post_report(ctx, report(ctx, [seven]))
      assert conn.status == 410
      assert Enum.map(rows(), & &1.window) == ["five_hour"]
    end
  end
end
