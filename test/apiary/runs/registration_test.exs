defmodule Apiary.Runs.RegistrationTest do
  use Apiary.DataCase, async: true

  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Nodes.Node
  alias Apiary.Policy
  alias Apiary.Policy.{Render, RunConfiguration, Serving}
  alias Apiary.Runs.{Batch, Ingest, Liveness, Projector, Registration, Run, Target}

  @no_policy ~s({"version":1})

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
        "time" => DateTime.to_iso8601(DateTime.utc_now()),
        "forager_version" => "0.8.0",
        "contract_version" => 1,
        "interval_seconds" => 30,
        "events" => ["*"]
      },
      changes
    )
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

  defp limit_one(key), do: Repo.get!(Node, key.node_id)

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

      # `about` left out says nothing; a member the body does not name is ignored.
      assert {:ok, %Registration{about: %{}, labels: %{}}} =
               body()
               |> Map.delete("about")
               |> Map.merge(%{"labels" => %{}, "extra" => 1})
               |> Registration.parse()
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
            {%{"labels" => %{"issue" => 77}}, "labels"},
            {%{"labels" => ["forge"]}, "labels"},
            {%{"about" => %{"owner" => "me"}}, "about"},
            {%{"about" => "fix"}, "about"},
            {%{"about" => %{"kind" => "fix\n"}}, "about.kind"},
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
            {%{"forager_version" => ""}, "forager_version"},
            {%{"contract_version" => 0}, "contract_version"},
            {%{"interval_seconds" => 0}, "interval_seconds"},
            {%{"interval_seconds" => 301}, "interval_seconds"},
            {%{"interval_seconds" => "30"}, "interval_seconds"},
            {%{"events" => [""]}, "events"},
            {%{"events" => "*"}, "events"}
          ] do
        assert Registration.parse(body(Ecto.UUID.generate(), changes)) ==
                 {:error, :invalid_request, member},
               inspect(changes)
      end

      assert Registration.parse(Map.delete(body(), "labels")) ==
               {:error, :invalid_request, "labels"}

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

      assert Apiary.Runs.About.read(about) == %{
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
    test "creates the run pending, on the key's node and the claimed instance, with its registration",
         %{key: key} do
      body = body()
      run_id = body["run_id"]

      assert {:ok,
              %{run: run, repeated: false, settings: @no_policy, digest: digest, managed: false}} =
               register(key, body)

      assert digest == Render.digest(@no_policy)
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
      assert stored.registration_digest == :crypto.hash(:sha256, Jason.encode!(body))
      assert stored.labels == %{}
      assert Repo.get!(AccessKey, key.id).last_used_at
    end

    test "an instance beyond the node's limit stores nothing, and the refusal counts",
         %{key: key} do
      assert {:ok, _} = register(key, body(), "i_one")
      refused = body()

      assert register(key, refused, "i_two") == {:error, :instance_limit}
      refute Repo.exists?(from r in Run, where: r.run_id == ^refused["run_id"])

      node = limit_one(key)
      assert node.instance_limit_refused == 1
      assert node.instance_limit_refused_at
    end

    test "a repeat of the same bytes from the same node is answered again, and admitted by nothing",
         %{key: key} do
      body = body()
      assert {:ok, %{run: run, repeated: false} = first} = register(key, body, "i_one")

      # The node's one slot is another instance's now: an admission would be refused.
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [state: "lost"])
      node_run_fixture(limit_one(key), "i_two", state: "running", started_at: DateTime.utc_now())

      assert {:ok, %{run: again, repeated: true} = second} = register(key, body, "i_one")
      assert again.id == run.id

      assert Map.take(second, [:settings, :digest, :managed]) ==
               Map.take(first, [:settings, :digest, :managed])

      assert Repo.aggregate(from(r in Run, where: r.run_id == ^body["run_id"]), :count) == 1
      assert limit_one(key).instance_limit_refused == 0
    end

    test "the run id with any other bytes, or from another node, is used", %{
      scope: scope,
      key: key
    } do
      body = body()
      assert {:ok, _} = register(key, body)

      # Other labels; the same labels at another time; another node's key, the same bytes.
      other_labels = Map.put(body, "labels", %{"forge" => "git.example.com"})
      later = Map.put(body, "time", DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 1)))
      %{access_key: other_key} = contract_key_fixture(scope)

      assert register(key, other_labels) == {:error, :run_id_used}
      assert register(key, later) == {:error, :run_id_used}
      assert register(other_key, body) == {:error, :run_id_used}
      assert length(runs()) == 1
    end

    test "a run its events created without a registration is used", %{key: key} do
      {subject, [ping, _started]} = first_events()
      meta = %{contract_version: 1, instance_id: "i_one"}
      assert {:ok, %{status: 202}} = Ingest.ingest(key, batch!([ping]), meta)

      assert register(key, body(subject)) == {:error, :run_id_used}
      assert [%Run{registered_at: nil}] = runs()
    end

    test "a run whose events retention pruned is gone", %{key: key} do
      body = body()
      assert {:ok, %{run: run}} = register(key, body)

      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [state: "completed", events_pruned_at: DateTime.utc_now()]
      )

      assert register(key, body) == {:error, :gone}
      assert register(key, Map.put(body, "labels", %{})) == {:error, :gone}
    end

    @tag needs: :security
    test "a managed workspace's run is given its stored configuration, by its labels",
         %{scope: scope, key: key} do
      shop = target_fixture(scope, "git.example.com", "acme/shop")
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
      {:ok, _} = Policy.allow(scope, shop, %{host: "mcp.example"})
      {:ok, baseline} = Policy.current_configuration(scope, nil)
      {:ok, own} = Policy.current_configuration(scope, shop)

      assert {:ok, %{settings: settings, digest: digest, managed: true}} = register(key, body())
      assert {settings, digest} == {own.document, own.digest}

      assert {:ok, %{settings: settings, digest: digest, managed: true}} =
               register(key, body(Ecto.UUID.generate(), %{"labels" => %{"issue" => "77"}}))

      assert {settings, digest} == {baseline.document, baseline.digest}
    end

    @tag needs: :security
    test "a managed workspace whose configuration cannot be read stores nothing, never no policy",
         %{scope: scope, key: key} do
      # A configuration of a target alone: the workspace is managed, and has no baseline to
      # give a run whose labels name no target.
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

      assert Serving.managed?(key)

      body = body(Ecto.UUID.generate(), %{"labels" => %{"issue" => "77"}})
      assert register(key, body) == {:error, :unavailable}
      assert runs() == []
      assert limit_one(key).instance_limit_refused == 0
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
      assert limit_one(key).instance_limit_refused == 0
    end

    test "a registered run with no events is alive for three default intervals from its registration",
         %{key: key} do
      assert {:ok, %{run: run}} = register(key, body())

      alive? = fn at ->
        Repo.exists?(Liveness.alive(from(r in Run, as: :run, where: r.id == ^run.id), at))
      end

      assert alive?.(DateTime.add(run.registered_at, 89, :second))
      refute alive?.(DateTime.add(run.registered_at, 91, :second))
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
      assert rebuilt.registered_at == run.registered_at
      assert rebuilt.registration_digest == run.registration_digest
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
    test "is the configuration in force for the run's registration labels, for its own node alone",
         %{scope: scope, key: key} do
      shop = target_fixture(scope, "git.example.com", "acme/shop")
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
      body = body()
      assert {:ok, %{run: run}} = register(key, body)

      # A policy for the target after the run registered: the reload reads it.
      {:ok, _} = Policy.allow(scope, shop, %{host: "mcp.example"})
      {:ok, own} = Policy.current_configuration(scope, shop)

      assert Registration.fetch(key, body["run_id"]) ==
               {:ok, %{settings: own.document, digest: own.digest, managed: true}}

      # The scope of the key reads the same.
      assert {:ok, %{digest: digest}} =
               Registration.fetch(Apiary.Accounts.Scope.for_access_key(key), body["run_id"])

      assert digest == own.digest

      # Another node of the workspace, and another workspace's key, find no such run.
      %{access_key: other_node} = contract_key_fixture(scope)
      %{scope: other} = sign_up_fixture()
      {:ok, _} = Policy.allow(other, nil, %{host: "api.example"})
      %{access_key: other_workspace} = contract_key_fixture(other)

      assert Registration.fetch(other_node, run.run_id) == {:error, :not_found}
      assert Registration.fetch(other_workspace, run.run_id) == {:error, :not_found}
    end

    @tag needs: :security
    test "a run that did not register is read by the labels its events gave it",
         %{scope: scope, key: key} do
      shop = target_fixture(scope, "git.example.com", "acme/shop")
      {:ok, _} = Policy.allow(scope, shop, %{host: "mcp.example"})
      {:ok, own} = Policy.current_configuration(scope, shop)
      {subject, events} = first_events()
      meta = %{contract_version: 1, instance_id: "i_one"}
      assert {:ok, _} = Ingest.ingest(key, batch!(events), meta)

      assert {:ok, %{digest: digest}} = Registration.fetch(key, subject)
      assert digest == own.digest
    end
  end

  describe "Serving.digest_for/4" do
    @tag needs: :security
    test "names a registered run's target by its registration labels, before anything reported",
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

      # A run that did not register keeps the reported digest in force, as before.
      {subject, [ping, _started]} = first_events()
      meta = %{contract_version: 1, instance_id: "i_one"}
      assert {:ok, %{run: unregistered}} = Ingest.ingest(key, batch!([ping]), meta)
      beat = batch!([wire_event(subject, 2, "run.heartbeat", %{"interval_seconds" => 30})])
      assert Serving.digest_for(key, unregistered, beat, own.digest) == own.digest
      assert Serving.digest_for(key, unregistered, beat, nil) == baseline.digest
    end
  end
end
