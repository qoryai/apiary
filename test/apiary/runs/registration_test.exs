defmodule Apiary.Runs.RegistrationTest do
  use Apiary.DataCase, async: true

  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Nodes
  alias Apiary.Nodes.Node
  alias Apiary.Policy
  alias Apiary.Policy.{Render, RunConfiguration, Serving}
  alias Apiary.Runs.{About, Batch, Ingest, Liveness, Projector, Registration, Run, Target}

  @no_policy ~s({"version":1})
  @nul <<0>>

  setup do
    %{scope: scope} = sign_up_fixture()
    %{access_key: key} = contract_key_fixture(scope)
    %{scope: scope, key: key}
  end

  # A registration's body, as Forager sends it, with `changes` merged in.
  defp body(run_id \\ Ecto.UUID.generate(), changes \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "run_id" => run_id,
        "labels" => %{"forge" => "git.example.com", "repository" => "acme/shop"},
        "about" => %{"kind" => "fix", "subjects" => [%{"type" => "issue", "ref" => "77"}]},
        "time" => now_z(),
        "forager_version" => "0.8.0",
        "contract_version" => 1,
        "interval_seconds" => 30,
        "events" => ["*"]
      },
      changes
    )
  end

  # Now, to the whole second, as the body's `time` is written.
  defp now_z(seconds \\ 0) do
    DateTime.utc_now()
    |> DateTime.add(seconds)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp register(key, body, instance_id \\ "i_one") do
    bytes = Jason.encode!(body)
    {:ok, registration} = Registration.parse(Jason.decode!(bytes))

    Registration.register(key, registration, %{
      body: bytes,
      contract_version: 1,
      instance_id: instance_id
    })
  end

  defp runs, do: Repo.all(Run)

  defp target_fixture(scope, system, path) do
    Repo.insert!(%Target{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      system: system,
      path: path,
      first_seen_at: DateTime.utc_now()
    })
  end

  defp batch!(events) do
    {:ok, batch} = events |> Jason.encode!() |> Batch.parse()
    batch
  end

  defp node_of(key), do: Repo.get!(Node, key.node_id)

  # Fills the key's node's one slot with a live run of another instance.
  defp fill(key),
    do: node_run_fixture(node_of(key), "i_full", state: "running", started_at: DateTime.utc_now())

  # A configuration of a target alone: the workspace is managed, and has no baseline to give
  # a run whose labels name no target, so its configuration cannot be read for one.
  defp unreadable(scope) do
    shop = target_fixture(scope, "git.example.com", "acme/shop")

    document =
      ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"observe","allow":[]}}})

    Repo.insert!(%RunConfiguration{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      target_id: shop.id,
      version: 1,
      document: document,
      digest: Render.digest(document),
      rendered_at: DateTime.utc_now()
    })
  end

  describe "parse/1" do
    test "reads every member of a body" do
      run_id = Ecto.UUID.generate()

      assert {:ok,
              %Registration{
                run_id: ^run_id,
                labels: %{"forge" => "git.example.com", "repository" => "acme/shop"},
                about: %{"kind" => "fix"},
                time: %DateTime{},
                forager_version: "0.8.0",
                contract_version: 1,
                interval_seconds: 30,
                events: ["*"]
              }} = Registration.parse(body(run_id))

      # `labels` and `about` may be left out: no labels, and nothing said.
      assert {:ok, %Registration{about: %{}, labels: %{}}} =
               body() |> Map.drop(["about", "labels"]) |> Registration.parse()
    end

    test "refuses a body that breaks a rule, naming the member" do
      long = String.duplicate("a", 257)
      many = Map.new(1..17, &{"l#{&1}", "v"})

      for {changes, member} <- [
            {%{"version" => 2}, "version"},
            {%{"run_id" => "not-a-uuid"}, "run_id"},
            {%{"run_id" => String.upcase(Ecto.UUID.generate())}, "run_id"},
            {%{"labels" => many}, "labels"},
            {%{"labels" => %{"Forge" => "git.example.com"}}, "labels"},
            {%{"labels" => %{"forge" => long}}, "labels"},
            # 129 characters of two bytes each: fewer than 256 characters, past 256 bytes.
            {%{"labels" => %{"forge" => String.duplicate("é", 129)}}, "labels"},
            {%{"labels" => %{"forge" => "git" <> @nul <> "example.com"}}, "labels"},
            {%{"labels" => %{"issue" => 77}}, "labels"},
            {%{"labels" => ["forge"]}, "labels"},
            {%{"labels" => nil}, "labels"},
            {%{"about" => %{"owner" => "me"}}, "about"},
            {%{"about" => "fix"}, "about"},
            {%{"about" => %{"kind" => "fix\n"}}, "about.kind"},
            {%{"about" => %{"kind" => "fix" <> @nul}}, "about.kind"},
            {%{"about" => %{"title" => ""}}, "about.title"},
            {%{"about" => %{"subjects" => []}}, "about.subjects"},
            {%{"about" => %{"subjects" => [%{"type" => "Issue", "ref" => "1"}]}},
             "about.subjects"},
            {%{"about" => %{"subjects" => [%{"type" => "issue", "ref" => "1", "x" => "y"}]}},
             "about.subjects"},
            {%{
               "about" => %{
                 "subjects" => [
                   %{"type" => "issue", "ref" => "1", "url" => "https://me:pw@example.com/1"}
                 ]
               }
             }, "about.subjects"},
            {%{
               "about" => %{
                 "subjects" => [
                   %{"type" => "issue", "ref" => "1"},
                   %{"type" => "issue", "ref" => "1"}
                 ]
               }
             }, "about.subjects"},
            {%{"about" => %{"details" => %{"a" => %{"b" => %{"c" => %{"d" => %{}}}}}}},
             "about.details"},
            {%{"about" => %{"details" => %{"a" => String.duplicate("x", 8200)}}},
             "about.details"},
            {%{"time" => "yesterday"}, "time"},
            {%{"time" => "2026-10-10T12:00:00.5Z"}, "time"},
            {%{"time" => "2026-10-10T12:00:00+00:00"}, "time"},
            {%{"time" => "2026-10-10 12:00:00Z"}, "time"},
            {%{"time" => "2026-02-30T12:00:00Z"}, "time"},
            {%{"time" => "2026-10-10T25:00:00Z"}, "time"},
            {%{"time" => 1_760_000_000}, "time"},
            {%{"forager_version" => ""}, "forager_version"},
            {%{"forager_version" => "0.8" <> @nul}, "forager_version"},
            {%{"contract_version" => 0}, "contract_version"},
            {%{"interval_seconds" => 0}, "interval_seconds"},
            {%{"interval_seconds" => 301}, "interval_seconds"},
            {%{"interval_seconds" => "30"}, "interval_seconds"},
            {%{"events" => [""]}, "events"},
            {%{"events" => "*"}, "events"},
            # A member the contract does not name: refused, its name not repeated.
            {%{"extra" => 1}, "body"}
          ] do
        assert Registration.parse(body(Ecto.UUID.generate(), changes)) ==
                 {:error, :invalid_request, member},
               inspect(changes)
      end

      for member <-
            ~w(version run_id time forager_version contract_version interval_seconds events) do
        assert Registration.parse(Map.delete(body(), member)) ==
                 {:error, :invalid_request, member},
               member
      end

      assert Registration.parse([body()]) == {:error, :invalid_request, "body"}
    end

    test "an about the contract allows parses, and the fold keeps it whole" do
      about = %{
        "kind" => "fix",
        "title" => "Fix the checkout",
        "subjects" => [
          %{"type" => "issue", "ref" => "77", "url" => "https://git.example.com/77"},
          %{"type" => "pull request", "ref" => "78", "title" => "The fix"}
        ],
        "details" => %{"attempt" => 2, "steps" => ["a", %{"b" => [1, nil, true]}]}
      }

      assert {:ok, %Registration{about: ^about}} =
               Registration.parse(body(Ecto.UUID.generate(), %{"about" => about}))

      assert About.read(about) == %{
               about_kind: about["kind"],
               about_title: about["title"],
               about_subjects: about["subjects"],
               about_details: about["details"]
             }
    end

    test "fresh?/2: the time within 300 seconds of the clock, either side" do
      {:ok, registration} = Registration.parse(body())
      time = registration.time

      assert Registration.fresh?(registration, time)
      assert Registration.fresh?(registration, DateTime.add(time, 300, :second))
      assert Registration.fresh?(registration, DateTime.add(time, -300, :second))
      refute Registration.fresh?(registration, DateTime.add(time, 301, :second))
      refute Registration.fresh?(registration, DateTime.add(time, -301, :second))
      assert Registration.max_skew_seconds() == 300
    end
  end

  describe "register/3" do
    test "creates the run pending, under the key, on its node and the claimed instance",
         %{key: key} do
      body = body()
      run_id = body["run_id"]

      assert {:ok, %{run: run, repeated: false, settings: @no_policy} = answer} =
               register(key, body)

      digest = Render.digest(@no_policy)
      assert answer.digest == digest
      assert answer.etag == ~s("#{digest}")
      assert answer.managed == false

      assert [%Run{} = stored] = runs()
      assert stored.id == run.id
      assert stored.run_id == run_id
      assert stored.state == "pending"
      assert stored.node_id == key.node_id
      assert stored.instance_id == "i_one"
      assert stored.access_key_id == key.id
      assert stored.registered_at
      assert stored.inserted_at == stored.registered_at
      assert stored.registration_labels == body["labels"]
      assert stored.registration_about == body["about"]
      assert stored.registration_interval_seconds == 30
      assert stored.registration_digest == :crypto.hash(:sha256, Jason.encode!(body))
      assert stored.registration_answer_digest == digest
      assert stored.labels == %{}
      assert Repo.get!(AccessKey, key.id).last_used_at
    end

    test "an instance beyond the node's limit stores nothing, and the refusal counts",
         %{key: key} do
      assert {:ok, _} = register(key, body(), "i_one")
      refused = body()

      assert register(key, refused, "i_two") == {:error, :instance_limit}
      refute Repo.exists?(from r in Run, where: r.run_id == ^refused["run_id"])

      node = node_of(key)
      assert node.instance_limit_refused == 1
      assert node.instance_limit_refused_at
    end

    test "a repeat of the same bytes under the same key is given its answer, admitted by nothing",
         %{key: key} do
      body = body()
      assert {:ok, %{run: run, repeated: false} = first} = register(key, body, "i_one")

      # The node's one slot is another instance's now: an admission would be refused.
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [state: "lost"])
      fill(key)

      assert {:ok, %{run: again, repeated: true} = second} = register(key, body, "i_one")
      assert again.id == run.id

      assert Map.take(second, [:settings, :digest, :etag, :managed]) ==
               Map.take(first, [:settings, :digest, :etag, :managed])

      assert Repo.aggregate(from(r in Run, where: r.run_id == ^body["run_id"]), :count) == 1
      assert node_of(key).instance_limit_refused == 0
    end

    test "the run id with any other bytes, or under another key, is used",
         %{scope: scope, key: key} do
      body = body()
      assert {:ok, _} = register(key, body)

      # Other labels; the same labels at another time; the same bytes under another key of
      # the same node, and under a key of another node.
      other_labels = Map.put(body, "labels", %{"forge" => "git.example.com"})
      later = Map.put(body, "time", now_z(1))
      %{access_key: same_node} = contract_key_fixture(scope, node: node_of(key))
      %{access_key: other_node} = contract_key_fixture(scope)

      assert register(key, other_labels) == {:error, :run_id_used}
      assert register(key, later) == {:error, :run_id_used}
      assert register(same_node, body) == {:error, :run_id_used}
      assert register(other_node, body, "i_other") == {:error, :run_id_used}
      assert length(runs()) == 1
    end

    test "a run its events created without a registration is used", %{key: key} do
      {subject, [ping, _started]} = first_events()
      meta = %{contract_version: 1, instance_id: "i_one"}
      assert {:ok, %{status: 202}} = Ingest.ingest(key, batch!([ping]), meta)

      assert register(key, body(subject)) == {:error, :run_id_used}
      assert [%Run{registered_at: nil}] = runs()
    end

    test "a run whose events retention pruned is gone, but to a repeat", %{key: key} do
      body = body()
      assert {:ok, %{run: run} = first} = register(key, body)

      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [state: "completed", events_pruned_at: DateTime.utc_now()]
      )

      assert register(key, Map.put(body, "labels", %{})) == {:error, :gone}
      assert {:ok, %{repeated: true, digest: digest}} = register(key, body)
      assert digest == first.digest
    end

    test "on a full node, a used run id is refused by the instance limit, and counted",
         %{key: key} do
      body = body()
      assert {:ok, %{run: run}} = register(key, body, "i_one")
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [state: "lost"])
      fill(key)

      assert register(key, Map.put(body, "labels", %{}), "i_one") == {:error, :instance_limit}
      assert node_of(key).instance_limit_refused == 1
      assert length(runs()) == 2

      # Admitted, the instance is refused for the run id alone.
      Repo.update_all(from(r in Run, where: r.instance_id == "i_full"), set: [state: "lost"])
      assert register(key, Map.put(body, "labels", %{}), "i_one") == {:error, :run_id_used}
    end

    test "on a full node, a pruned run is gone before the instance limit, which counts nothing",
         %{key: key} do
      body = body()
      assert {:ok, %{run: run}} = register(key, body, "i_one")

      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [state: "completed", events_pruned_at: DateTime.utc_now()]
      )

      fill(key)

      assert register(key, Map.put(body, "labels", %{}), "i_one") == {:error, :gone}
      assert node_of(key).instance_limit_refused == 0
    end

    @tag needs: :security
    test "a used run id is refused as used before a configuration that cannot be read",
         %{scope: scope, key: key} do
      # Readable for the target, unreadable for labels that name none.
      unreadable(scope)
      body = body()
      assert {:ok, %{managed: true}} = register(key, body)

      unreadable_labels = Map.put(body, "labels", %{"issue" => "77"})
      assert register(key, unreadable_labels) == {:error, :run_id_used}
      assert length(runs()) == 1
    end

    @tag needs: :security
    test "a managed workspace's run is given its stored configuration, by its labels",
         %{scope: scope, key: key} do
      shop = target_fixture(scope, "git.example.com", "acme/shop")
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
      {:ok, _} = Policy.allow(scope, shop, %{host: "mcp.example"})
      {:ok, baseline} = Policy.current_configuration(scope, nil)
      {:ok, own} = Policy.current_configuration(scope, shop)

      assert {:ok, %{settings: settings, digest: digest, etag: etag, managed: true}} =
               register(key, body())

      assert {settings, digest, etag} == {own.document, own.digest, ~s("#{own.digest}")}

      assert {:ok, %{settings: settings, digest: digest, managed: true}} =
               register(key, body(Ecto.UUID.generate(), %{"labels" => %{"issue" => "77"}}))

      assert {settings, digest} == {baseline.document, baseline.digest}
    end

    @tag needs: :security
    test "a repeat is given the answer it was given, though the policy changed since",
         %{scope: scope, key: key} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
      {:ok, first_version} = Policy.current_configuration(scope, nil)
      body = body()
      assert {:ok, %{digest: digest}} = register(key, body)
      assert digest == first_version.digest

      {:ok, _} = Policy.allow(scope, nil, %{host: "mcp.example"})
      {:ok, newer} = Policy.current_configuration(scope, nil)
      refute newer.digest == first_version.digest

      assert {:ok, %{repeated: true, settings: settings, digest: ^digest, managed: true}} =
               register(key, body)

      assert settings == first_version.document
    end

    @tag needs: :security
    test "a managed workspace whose configuration cannot be read stores nothing, never no policy",
         %{scope: scope, key: key} do
      unreadable(scope)
      assert Serving.managed?(key)

      body = body(Ecto.UUID.generate(), %{"labels" => %{"issue" => "77"}})
      assert register(key, body) == {:error, :unavailable}
      assert runs() == []
      assert node_of(key).instance_limit_refused == 0
    end

    @tag needs: :security
    test "on a full node, a configuration that cannot be read is refused by the instance limit",
         %{scope: scope, key: key} do
      unreadable(scope)
      fill(key)

      body = body(Ecto.UUID.generate(), %{"labels" => %{"issue" => "77"}})
      assert register(key, body, "i_one") == {:error, :instance_limit}
      assert node_of(key).instance_limit_refused == 1
      assert [%Run{instance_id: "i_full"}] = runs()
    end

    test "a workspace nobody has given a policy: no policy, and the run is created",
         %{key: key} do
      assert {:ok, %{settings: @no_policy, managed: false, run: %Run{}}} = register(key, body())
      assert length(runs()) == 1
    end

    test "the run's events land on its row: run.started moves it to running, the registration stays",
         %{key: key} do
      body = body()
      assert {:ok, %{run: run}} = register(key, body)
      {_subject, [_ping, started]} = first_events(body["run_id"])
      meta = %{contract_version: 1, instance_id: "i_one"}

      assert {:ok, %{status: 202, run: %Run{id: id}}} =
               Ingest.ingest(key, batch!([started]), meta)

      assert id == run.id

      assert [%Run{} = stored] = runs()
      assert stored.state == "running"
      assert stored.labels == %{"forge" => "git.example.com", "repository" => "acme/shop"}
      assert stored.registration_labels == body["labels"]
      assert stored.registration_about == body["about"]
      assert stored.registered_at == run.registered_at
    end

    test "a run that registered is not admitted again by its ping, whichever instance sends it",
         %{key: key} do
      body = body()
      assert {:ok, %{run: run}} = register(key, body, "i_one")
      {_subject, [ping, _started]} = first_events(body["run_id"])

      # Admitted again, another instance's ping would be refused: the node's one slot is
      # i_one's.
      for instance <- ["i_one", "i_two"] do
        meta = %{contract_version: 1, instance_id: instance, delivery_id: Ecto.UUID.generate()}
        assert {:ok, %{status: 202}} = Ingest.ingest(key, batch!([ping]), meta)
      end

      assert [%Run{instance_id: "i_one"} = stored] = runs()
      assert stored.id == run.id
      assert node_of(key).instance_limit_refused == 0
    end
  end

  describe "liveness" do
    defp alive?(run, at),
      do: Repo.exists?(Liveness.alive(from(r in Run, as: :run, where: r.id == ^run.id), at))

    # Whether another instance may start on the key's node at `at`: the instance limit's
    # count of the instances alive.
    defp slot_free?(key, at) do
      {:ok, answer} =
        Repo.transact(fn -> {:ok, Nodes.check_instance_limit(node_of(key), "i_next", at)} end)

      answer == :ok
    end

    test "a registered run is held to three of its own intervals, pending and running",
         %{key: key} do
      assert {:ok, %{run: run}} =
               register(key, body(Ecto.UUID.generate(), %{"interval_seconds" => 100}))

      at = &DateTime.add(run.registered_at, &1, :second)

      assert alive?(run, at.(120))
      assert alive?(run, at.(299))
      refute alive?(run, at.(301))
      refute slot_free?(key, at.(120))
      assert slot_free?(key, at.(301))

      # Started and not yet beating: from its first event's arrival, by the same interval.
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [state: "running", started_at: run.registered_at]
      )

      assert alive?(run, at.(120))
      refute alive?(run, at.(301))

      # Pending, the check marks it lost after three of its intervals, not before.
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [state: "pending"])
      assert Liveness.check(at.(120)) == []
      assert [%Run{state: "lost"}] = Liveness.check(at.(301))
    end

    test "a registered run's interval wins over its heartbeats'", %{key: key} do
      assert {:ok, %{run: run}} =
               register(key, body(Ecto.UUID.generate(), %{"interval_seconds" => 100}))

      beat = run.registered_at

      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [
          state: "running",
          started_at: beat,
          last_heartbeat_at: beat,
          heartbeat_interval_seconds: 30
        ]
      )

      assert alive?(run, DateTime.add(beat, 120, :second))
      assert alive?(run, DateTime.add(beat, 299, :second))
      refute alive?(run, DateTime.add(beat, 301, :second))
      refute slot_free?(key, DateTime.add(beat, 120, :second))
      assert slot_free?(key, DateTime.add(beat, 301, :second))
    end

    test "a run that did not register keeps 90 seconds", %{key: key} do
      run = node_run_fixture(node_of(key), "i_one")
      at = &DateTime.add(run.inserted_at, &1, :second)

      assert alive?(run, at.(89))
      refute alive?(run, at.(91))
      refute slot_free?(key, at.(89))
      assert slot_free?(key, at.(91))
    end

    test "a registered run that says 30 seconds is held to 90", %{key: key} do
      assert {:ok, %{run: run}} = register(key, body())
      assert alive?(run, DateTime.add(run.registered_at, 89, :second))
      refute alive?(run, DateTime.add(run.registered_at, 91, :second))
    end
  end

  describe "a rebuild" do
    test "keeps the registration's fields", %{key: key} do
      body = body()
      assert {:ok, %{run: run}} = register(key, body)
      {_subject, [_ping, started]} = first_events(body["run_id"])
      meta = %{contract_version: 1, instance_id: "i_one"}
      assert {:ok, _} = Ingest.ingest(key, batch!([started]), meta)

      assert {:ok, rebuilt} = Projector.rebuild(Repo.get!(Run, run.id))
      assert rebuilt.registration_labels == body["labels"]
      assert rebuilt.registration_about == body["about"]
      assert rebuilt.registration_interval_seconds == 30
      assert rebuilt.registered_at == run.registered_at
      assert rebuilt.registration_digest == run.registration_digest
      assert rebuilt.registration_answer_digest == run.registration_answer_digest
    end
  end

  describe "fetch/2, the reload" do
    test "a workspace that serves no run configuration is not found, never no policy",
         %{key: key} do
      body = body()
      assert {:ok, _} = register(key, body)

      assert Registration.fetch(key, body["run_id"]) == {:error, :not_found}
    end

    test "a run the key's workspace does not hold, or a malformed id, is not found",
         %{key: key} do
      assert Registration.fetch(key, Ecto.UUID.generate()) == {:error, :not_found}
      assert Registration.fetch(key, "not-a-uuid") == {:error, :not_found}
      assert Registration.fetch(key, nil) == {:error, :not_found}
    end

    @tag needs: :security
    test "is the configuration in force for the run's registration labels, for its own key alone",
         %{scope: scope, key: key} do
      shop = target_fixture(scope, "git.example.com", "acme/shop")
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
      body = body()
      assert {:ok, %{run: run}} = register(key, body)

      # A policy for the target after the run registered: the reload reads it.
      {:ok, _} = Policy.allow(scope, shop, %{host: "mcp.example"})
      {:ok, own} = Policy.current_configuration(scope, shop)

      assert Registration.fetch(key, body["run_id"]) ==
               {:ok,
                %{
                  settings: own.document,
                  digest: own.digest,
                  etag: ~s("#{own.digest}"),
                  managed: true
                }}

      # The scope of the key reads the same.
      assert {:ok, %{digest: digest}} =
               Registration.fetch(Apiary.Accounts.Scope.for_access_key(key), body["run_id"])

      assert digest == own.digest

      # Another key of the same node, a key of another node, and another workspace's key
      # find no such run.
      %{access_key: same_node} = contract_key_fixture(scope, node: node_of(key))
      %{access_key: other_node} = contract_key_fixture(scope)
      %{scope: other} = sign_up_fixture()
      {:ok, _} = Policy.allow(other, nil, %{host: "api.example"})
      %{access_key: other_workspace} = contract_key_fixture(other)

      for other_key <- [same_node, other_node, other_workspace] do
        assert Registration.fetch(other_key, run.run_id) == {:error, :not_found}
      end
    end

    @tag needs: :security
    test "a run that did not register is read by the labels its events gave it, for its key",
         %{scope: scope, key: key} do
      shop = target_fixture(scope, "git.example.com", "acme/shop")
      {:ok, _} = Policy.allow(scope, shop, %{host: "mcp.example"})
      {:ok, own} = Policy.current_configuration(scope, shop)
      {subject, events} = first_events()
      meta = %{contract_version: 1, instance_id: "i_one"}
      assert {:ok, _} = Ingest.ingest(key, batch!(events), meta)

      assert {:ok, %{digest: digest}} = Registration.fetch(key, subject)
      assert digest == own.digest

      %{access_key: same_node} = contract_key_fixture(scope, node: node_of(key))
      assert Registration.fetch(same_node, subject) == {:error, :not_found}
    end
  end

  describe "the target of a registered run" do
    @tag needs: :security
    test "is the one its registration's labels name, whatever its run.started names",
         %{scope: scope, key: key} do
      shop = target_fixture(scope, "git.example.com", "acme/shop")
      docs = target_fixture(scope, "git.example.com", "acme/docs")
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
      {:ok, _} = Policy.allow(scope, shop, %{host: "mcp.example"})
      {:ok, _} = Policy.allow(scope, docs, %{host: "docs.example"})
      {:ok, for_shop} = Policy.current_configuration(scope, shop)
      {:ok, for_docs} = Policy.current_configuration(scope, docs)

      body = body()
      assert {:ok, %{run: run, digest: digest}} = register(key, body)
      assert digest == for_shop.digest

      # A start whose labels name the other target: the run's row is assigned to it, and
      # the digests and the reload stay the registration's.
      {_subject, [_ping, started]} = first_events(body["run_id"])
      started = put_in(started, ["data", "labels", "repository"], "acme/docs")
      meta = %{contract_version: 1, instance_id: "i_one"}

      assert {:ok, %{status: 202, run_configuration_digest: events_digest}} =
               Ingest.ingest(key, batch!([started]), meta)

      assert events_digest == for_shop.digest
      assert Repo.get!(Run, run.id).target_id == docs.id

      beat =
        batch!([wire_event(body["run_id"], 3, "run.heartbeat", %{"interval_seconds" => 30})])

      assert Serving.digest_for(key, Repo.get!(Run, run.id), beat, for_docs.digest) ==
               for_shop.digest

      assert {:ok, %{digest: reloaded}} = Registration.fetch(key, body["run_id"])
      assert reloaded == for_shop.digest
    end

    @tag needs: :security
    test "names the digest by the registration, before anything reported; other runs as before",
         %{scope: scope, key: key} do
      shop = target_fixture(scope, "git.example.com", "acme/shop")
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
      {:ok, _} = Policy.allow(scope, shop, %{host: "mcp.example"})
      {:ok, baseline} = Policy.current_configuration(scope, nil)
      {:ok, own} = Policy.current_configuration(scope, shop)

      body = body()
      assert {:ok, %{run: run}} = register(key, body)
      assert run.target_id == nil

      heartbeat =
        batch!([wire_event(body["run_id"], 1, "run.heartbeat", %{"interval_seconds" => 30})])

      # The baseline's digest reported, as a run that started on it would: the registration
      # decides, by the run's row or, for a pruned run, by its subject.
      assert Serving.digest_for(key, run, heartbeat, baseline.digest) == own.digest
      assert Serving.digest_for(key, nil, heartbeat, baseline.digest) == own.digest

      # Labels that name no target: the baseline, whatever was reported.
      other = body(Ecto.UUID.generate(), %{"labels" => %{"issue" => "77"}})
      assert {:ok, %{run: unnamed}} = register(key, other)
      assert Serving.digest_for(key, unnamed, heartbeat, own.digest) == baseline.digest

      # A run that did not register keeps the reported digest in force, as before, and then
      # the target its row holds.
      {subject, [ping, started]} = first_events()
      meta = %{contract_version: 1, instance_id: "i_one"}
      assert {:ok, %{run: unregistered}} = Ingest.ingest(key, batch!([ping]), meta)
      beat = batch!([wire_event(subject, 3, "run.heartbeat", %{"interval_seconds" => 30})])
      assert Serving.digest_for(key, unregistered, beat, own.digest) == own.digest
      assert Serving.digest_for(key, unregistered, beat, nil) == baseline.digest

      assert {:ok, %{run: started_run}} = Ingest.ingest(key, batch!([started]), meta)
      started_run = Repo.get!(Run, started_run.id)
      assert started_run.target_id == shop.id
      assert Serving.digest_for(key, started_run, beat, baseline.digest) == own.digest
    end
  end
end
