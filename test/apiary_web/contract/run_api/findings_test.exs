defmodule ApiaryWeb.Contract.RunApi.FindingsTest do
  # `GET` and `POST /v1/runs/<run_id>/findings`, a run's reads and writes of the findings of
  # its work item (`Apiary.Findings`). Not async: the stubs of the run API are the whole
  # node's (`ApiaryWeb.RunApiStubs`).
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures

  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Findings
  alias Apiary.Findings.Finding
  alias Apiary.Repo
  alias Apiary.Runs.{Run, Target}
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.Contract.RunApi.FindingsBody
  alias ApiaryWeb.RunApiStubs

  @moduletag needs: [:workflow_model, :factory, :secrets]

  @fixtures Path.expand("../../../fixtures/contract/run/v1/fixtures", __DIR__)
  @roots [Path.expand("../../../fixtures/contract", __DIR__)]
  @base String.duplicate("a", 40)

  setup {Apiary.DataCase, :without_registry}

  setup do
    :ok = RunApiStubs.install()
    %{scope: scope} = sign_up_fixture()
    fixture = sealed_run_fixture(scope)
    dispatch_run = Repo.get!(DispatchRun, fixture.run.dispatch_run_id)

    work_item =
      WorkItem |> Repo.get!(dispatch_run.work_item_id) |> Repo.preload(:workspace)

    target = Target.dispatched(dispatch_run.id)

    %{
      scope: scope,
      run: Repo.get!(Run, fixture.run.id),
      key: fixture.secrets_key,
      dispatch_run: dispatch_run,
      work_item: work_item,
      target: Jason.decode!(Jason.encode!(Target.document(target)))
    }
  end

  defp read(ctx, opts \\ []) do
    {key, seed} = Keyword.get(opts, :key, ctx.key)
    run_id = Keyword.get(opts, :run_id, ctx.run.node_run_id)
    signed_get(build_conn(), key.key_id, seed, "/v1/runs/#{run_id}/findings")
  end

  defp write(ctx, body, opts \\ []) do
    {key, seed} = ctx.key
    body = if is_binary(body), do: body, else: Jason.encode!(body)
    target = "/v1/runs/#{Keyword.get(opts, :run_id, ctx.run.node_run_id)}/findings"

    # `ApiaryWeb.Contract.RawBody` reads the body: nothing is assigned by hand.
    signed_post(build_conn(), key.key_id, seed, body,
      target: target,
      content_type: "application/json",
      delivery: nil
    )
  end

  defp raise_event(ctx, ref, attrs \\ %{}) do
    Map.merge(
      %{
        "kind" => "raise",
        "by" => "code-reviewer",
        "ref" => ref,
        "target" => ctx.target,
        "stage" => "build",
        "source" => %{"kind" => "reviewer", "name" => "code-reviewer"},
        "severity" => "blocking",
        "place" => %{"quote" => "total = price + tax", "file" => "src/cart.go", "line" => 4},
        "point" => "The discount is applied after the tax",
        "problem" => "The tax is charged on the full price.",
        "fix" => "Subtract the discount first.",
        "proof" => "An order of 100.00 totals 110.00."
      },
      attrs
    )
  end

  defp event(kind, id, attrs \\ %{}),
    do:
      Map.merge(
        %{"kind" => kind, "by" => "suite", "id" => id, "reason" => "Why."},
        attrs
      )

  defp valid!(schema, document) do
    root =
      JSV.build!(%{"$ref" => "https://qory.dev/contracts/run/v1/#{schema}.schema.json"},
        resolver: {Apiary.ExploreInputsSchema, @roots},
        formats: true
      )

    assert {:ok, _document} = JSV.validate(document, root)
    document
  end

  defp end_run!(ctx) do
    {1, _rows} =
      Repo.update_all(from(d in DispatchRun, where: d.id == ^ctx.dispatch_run.id),
        set: [state: :ended, end_cause: :run_ended]
      )
  end

  # The run as a run of Build, the stage that the raises of `raise_event/3` are for.
  defp at_build!(ctx) do
    {1, _} =
      Repo.update_all(from(d in DispatchRun, where: d.id == ^ctx.dispatch_run.id),
        set: [stage_id: "st_6ns22c4pav"]
      )

    :ok
  end

  # A blocking finding that Verify owns, written as a run of Verify writes it: its id.
  defp verify_finding!(ctx) do
    events = [
      %{
        kind: "raise",
        by: "verifier",
        ref: "v1",
        target_id: Target.dispatched_id(ctx.work_item.workspace_id, ctx.dispatch_run.id),
        stage_id: "st_m1mqbeywdg",
        source_kind: "reviewer",
        source_name: "verifier",
        severity: "blocking",
        place: %{"quote" => "total = price + tax", "file" => "src/cart.go", "line" => 4},
        point: "The total is not shown",
        problem: "The cart page has no total.",
        fix: "Show the total under the items.",
        proof: "The cart page of an order of two items shows no total.",
        version: nil,
        reason: nil
      }
    ]

    {:ok, %{created: [{"v1", id}]}} =
      Findings.post(
        Repo.get!(WorkItem, ctx.work_item.id),
        %{run_id: ctx.run.id, dispatch_run_id: ctx.dispatch_run.id},
        %{bases: [], events: events}
      )

    id
  end

  # The 400 of an event for a stage other than the run's: the contract's refusal
  # `invalid_request`, with the member and the message that the refusal allows.
  defp other_stage!(conn, member, message) do
    assert json_response(conn, 400) ==
             Map.merge(refusal_fixture("invalid-request"), %{
               "names" => [member],
               "message" => message
             })
  end

  @raise_other_stage "Raise the finding for the run's stage. " <>
                       "A run raises findings only for the stage that started it."
  @finding_other_stage "Close or repeat only a finding of the run's stage. " <>
                         "Another stage owns this finding, and its re-check closes it."

  describe "POST findings" do
    setup :at_build!

    test "writes the raises and the base, and answers with the ids and the counts", ctx do
      conn =
        write(ctx, %{
          "bases" => [%{"target" => ctx.target, "base" => @base}],
          "events" => [
            raise_event(ctx, "r1"),
            raise_event(ctx, "r2", %{"severity" => "non-blocking"})
          ]
        })

      assert %{
               "created" => [%{"ref" => "r1", "id" => "f1"}, %{"ref" => "r2", "id" => "f2"}],
               "open_blocking" => [%{"stage" => "build", "count" => 1}]
             } = valid!("findings-post-answer", json_response(conn, 200))

      conn = write(ctx, %{"events" => [event("close_fixed", "f1")]})

      assert %{"created" => [], "open_blocking" => [%{"stage" => "build", "count" => 0} | _]} =
               json_response(conn, 200)

      finding = Repo.get_by!(Finding, number: 1)
      assert finding.state == "fixed"
      assert finding.work_item_id == ctx.work_item.id
      [raised, _closed] = Repo.preload(finding, :events).events
      assert raised.run_id == ctx.run.id and raised.actor_name == "code-reviewer"
    end

    test "a second base of the target is refused", ctx do
      body = %{"events" => [raise_event(ctx, "r1")]}
      base = &Map.put(body, "bases", [%{"target" => ctx.target, "base" => &1}])

      assert json_response(write(ctx, base.(@base)), 200)
      conn = write(ctx, base.(String.duplicate("b", 40)))

      assert json_response(conn, 409) == refusal_fixture("base-changed")
    end

    test "an unknown id and a finding of another take in are not found", ctx do
      assert json_response(write(ctx, %{"events" => [raise_event(ctx, "r1")]}), 200)

      assert json_response(write(ctx, %{"events" => [event("repeat", "f7")]}), 404) ==
               refusal_fixture("not-found")

      {1, _} = Repo.update_all(Finding, set: [take_in: 0])
      assert json_response(write(ctx, %{"events" => [event("repeat", "f1")]}), 404)

      assert json_response(
               write(ctx, %{"events" => [event("repeat", "f1")]}, run_id: uuid()),
               404
             )
    end

    test "a target other than the run's, and a stage the process has none of, are refused",
         ctx do
      other = %{"collection" => "another-collection"}

      for {body, member} <- [
            {%{"events" => [raise_event(ctx, "r1", %{"target" => other})]}, "events[0].target"},
            {%{"events" => [raise_event(ctx, "r1", %{"stage" => "no-such-stage"})]},
             "events[0].stage"},
            {%{
               "bases" => [%{"target" => other, "base" => @base}],
               "events" => [raise_event(ctx, "r1")]
             }, "bases[0].target"}
          ] do
        assert json_response(write(ctx, body), 400) == %{
                 "error" => "invalid_request",
                 "names" => [member]
               }
      end

      assert Repo.aggregate(Finding, :count) == 0
    end

    test "a run that ended writes nothing", ctx do
      end_run!(ctx)

      assert json_response(write(ctx, %{"events" => [raise_event(ctx, "r1")]}), 404) ==
               refusal_fixture("not-found")

      assert Repo.aggregate(Finding, :count) == 0
    end

    test "a cancel that a member requested does not refuse the batch", ctx do
      {1, _} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
          set: [cancel_requested_at: DateTime.utc_now()]
        )

      assert json_response(write(ctx, %{"events" => [raise_event(ctx, "r1")]}), 200)
    end

    test "a body over 8 MiB is refused before it is read", ctx do
      body =
        Jason.encode!(%{"events" => [], "pad" => String.duplicate("a", FindingsBody.max_bytes())})

      assert json_response(write(ctx, body), 413)["error"] == "payload_too_large"
    end

    test "a raise for a stage other than the run's is refused", ctx do
      conn = write(ctx, %{"events" => [raise_event(ctx, "r1", %{"stage" => "verify"})]})
      other_stage!(conn, "events[0].stage", @raise_other_stage)
      assert Repo.aggregate(Finding, :count) == 0
    end

    test "a close of a finding that another stage owns is refused, the batch with it", ctx do
      id = verify_finding!(ctx)

      for kind <- ["close_fixed", "close_dismissed"] do
        conn = write(ctx, %{"events" => [raise_event(ctx, "r1"), event(kind, id)]})
        other_stage!(conn, "events[1].id", @finding_other_stage)
      end

      assert [%Finding{state: "open", stage_id: "st_m1mqbeywdg"}] = Repo.all(Finding)
    end

    test "a repeat of a finding that another stage owns is refused", ctx do
      id = verify_finding!(ctx)
      conn = write(ctx, %{"events" => [event("repeat", id)]})
      other_stage!(conn, "events[0].id", @finding_other_stage)
      assert [%Finding{events: [_raised]}] = Finding |> Repo.all() |> Repo.preload(:events)
    end

    test "a reply to a finding that another stage owns is kept", ctx do
      id = verify_finding!(ctx)

      assert json_response(write(ctx, %{"events" => [event("reply_disputed", id)]}), 200)
      assert [%Finding{disputed: true, state: "open"}] = Repo.all(Finding)
    end

    test "a batch is written whole or not at all", ctx do
      assert json_response(
               write(ctx, %{"events" => [raise_event(ctx, "r1"), event("repeat", "f9")]}),
               404
             )

      assert Repo.aggregate(Finding, :count) == 0
    end
  end

  describe "GET findings" do
    setup :at_build!

    test "an empty work item has no findings and no base", ctx do
      assert valid!("findings", json_response(read(ctx), 200)) == %{
               "bases" => [],
               "findings" => []
             }
    end

    test "shows the findings with their events, open ones first, and the base", ctx do
      write(ctx, %{
        "bases" => [%{"target" => ctx.target, "base" => @base}],
        "events" => [raise_event(ctx, "r1"), raise_event(ctx, "r2")]
      })

      assert verify_finding!(ctx) == "f3"

      write(ctx, %{
        "events" => [
          event("reply_fixed", "f1", %{"by" => "implement-changes", "version" => @base}),
          event("close_fixed", "f1")
        ]
      })

      work_item = Repo.get!(WorkItem, ctx.work_item.id)
      :ok = Findings.accept_open(work_item, "st_m1mqbeywdg", ctx.scope.user.id)

      assert %{"bases" => [base], "findings" => [f2, f1, f3]} =
               valid!("findings", json_response(read(ctx), 200))

      assert base == %{"target" => ctx.target, "base" => @base}
      assert {f2["id"], f2["state"]} == {"f2", "open"}
      assert {f1["id"], f1["state"]} == {"f1", "fixed"}
      assert {f3["id"], f3["state"]} == {"f3", "accepted"}
      assert Enum.map(f1["events"], & &1["kind"]) == ~w(raised replied_fixed closed_fixed)
      assert Enum.at(f1["events"], 1)["version"] == @base
      assert f1["stage"] == "build"
      assert List.last(f3["events"])["actor"] == %{"kind" => "person"}

      assert f3["place"] == %{
               "quote" => "total = price + tax",
               "file" => "src/cart.go",
               "line" => 4
             }
    end

    test "a run of another gateway and an unknown run get not found", ctx do
      assert json_response(read(ctx, run_id: uuid()), 404) == refusal_fixture("not-found")
    end
  end

  describe "the body" do
    # The contract's fixtures: the bodies the schema takes, and those it refuses.
    test "every findings-post fixture is read", _ctx do
      for path <- Path.wildcard(Path.join([@fixtures, "findings-post", "*.json"])) do
        assert {:ok, %{events: [_ | _]}} = FindingsBody.post(File.read!(path)), path
      end
    end

    test "every invalid fixture, and every one that only the check refuses, is refused", _ctx do
      refused =
        Path.wildcard(Path.join([@fixtures, "invalid", "findings-post-*.json"]))
        |> Enum.reject(&(Path.basename(&1) =~ "findings-post-answer"))

      checked =
        Enum.map(
          ~w(findings-post-ref-twice findings-post-bases-target-twice),
          &Path.join([@fixtures, "check", &1 <> ".json"])
        )

      assert length(refused) > 15

      for path <- refused ++ checked do
        assert {:error, :invalid_request, member} = FindingsBody.post(File.read!(path)), path
        assert is_binary(member)
      end
    end

    test "an undefined member is ignored unless must_understand lists it", _ctx do
      for path <- Path.wildcard(Path.join([@fixtures, "closed", "findings-post-event*.json"])) do
        assert {:ok, _body} = FindingsBody.post(File.read!(path))
      end

      body = fn pointers ->
        Jason.encode!(%{
          "must_understand" => pointers,
          "events" => [%{"kind" => "repeat", "by" => "suite", "id" => "f1", "later" => 1}]
        })
      end

      assert {:ok, _body} = FindingsBody.post(body.(["/events"]))

      assert {:error, :invalid_request, "must_understand"} =
               FindingsBody.post(body.(["/events/0/later"]))
    end

    test "the first member that fails is named by its path", _ctx do
      base = %{
        "kind" => "raise",
        "by" => "code-reviewer",
        "ref" => "r1",
        "target" => %{"collection" => "R_1"},
        "stage" => "build",
        "source" => %{"kind" => "reviewer", "name" => "code-reviewer"},
        "severity" => "blocking",
        "place" => %{"quote" => "a"},
        "point" => "P",
        "problem" => "P",
        "fix" => "F",
        "proof" => "P"
      }

      refused = fn event ->
        {:error, :invalid_request, member} =
          FindingsBody.post(Jason.encode!(%{"events" => [event]}))

        member
      end

      assert refused.(Map.put(base, "point", "two\nlines")) == "events[0].point"
      assert refused.(put_in(base, ["place", "version"], "a b")) == "events[0].place.version"
      assert refused.(put_in(base, ["place", "line"], 3)) == "events[0].place.file"
      assert refused.(Map.put(base, "stage", "Build")) == "events[0].stage"

      assert refused.(put_in(base, ["target", "address"], %{"system" => "forge"})) ==
               "events[0].target"

      assert FindingsBody.post("[]") == {:error, :invalid_request, "body"}
      assert {:ok, _body} = FindingsBody.post(Jason.encode!(%{"events" => [base]}))
    end

    test "two bases of one collection are refused, whatever their addresses", _ctx do
      event = %{"kind" => "repeat", "by" => "suite", "id" => "f1"}

      body = fn second ->
        Jason.encode!(%{
          "bases" => [
            %{"target" => %{"collection" => "R_1"}, "base" => @base},
            %{"target" => second, "base" => @base}
          ],
          "events" => [event]
        })
      end

      address = %{"system" => "code.example.com", "path" => "acme/shop"}

      assert FindingsBody.post(body.(%{"collection" => "R_1", "address" => address})) ==
               {:error, :invalid_request, "bases[1].target"}

      assert {:ok, %{bases: [_, _]}} = FindingsBody.post(body.(%{"collection" => "R_2"}))
    end
  end

  describe "POST verdict" do
    @build "st_6ns22c4pav"

    # The run and its work item at Build.
    setup ctx do
      {1, _} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^ctx.dispatch_run.id),
          set: [stage_id: @build]
        )

      {1, _} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^ctx.work_item.id),
          set: [stage_id: @build, stage_state: :running]
        )

      :ok
    end

    defp verdict(ctx, verdict) do
      {key, seed} = ctx.key
      target = "/v1/runs/#{ctx.run.node_run_id}/verdict"

      signed_post(build_conn(), key.key_id, seed, Jason.encode!(%{"verdict" => verdict}),
        target: target,
        content_type: "application/json",
        delivery: nil
      )
    end

    test "passed is refused while the stage owns an open blocking finding", ctx do
      assert json_response(write(ctx, %{"events" => [raise_event(ctx, "r1")]}), 200)
      assert verify_finding!(ctx) == "f2"

      # For one open blocking finding, then for two; the finding Verify owns is in neither.
      conn = verdict(ctx, "passed")
      assert json_response(conn, 409) == refusal_fixture("open-blocking-findings-one")

      assert json_response(write(ctx, %{"events" => [raise_event(ctx, "r2")]}), 200)

      refusal = refusal_fixture("open-blocking-findings")
      swap = &String.replace(&1, "f2", "f3")

      assert json_response(verdict(ctx, "passed"), 409) == %{
               refusal
               | "findings" => Enum.map(refusal["findings"], swap),
                 "message" => swap.(refusal["message"])
             }

      assert verdicts(ctx) == []
    end

    test "passed is refused for a push of the artifact verdict too", ctx do
      assert json_response(write(ctx, %{"events" => [raise_event(ctx, "r1")]}), 200)
      {key, seed} = ctx.key

      body = %{
        "type" => "verdict",
        "files" => [
          %{
            "filename" => "verdict.json",
            "content_type" => "application/json",
            "content_base64" => Base.encode64(Jason.encode!(%{"verdict" => "passed"}))
          }
        ]
      }

      conn =
        signed_post(build_conn(), key.key_id, seed, Jason.encode!(body),
          target: "/v1/runs/#{ctx.run.node_run_id}/artifacts",
          content_type: "application/json",
          delivery: nil
        )

      assert json_response(conn, 409) == refusal_fixture("open-blocking-findings-one")
    end

    test "a verdict other than passed is stored, and passed once none is open", ctx do
      assert json_response(write(ctx, %{"events" => [raise_event(ctx, "r1")]}), 200)
      # With no points.
      assert json_response(verdict(ctx, "changes-requested"), 201)
      assert json_response(write(ctx, %{"events" => [event("close_fixed", "f1")]}), 200)
      assert json_response(verdict(ctx, "passed"), 201)
      assert length(verdicts(ctx)) == 2
    end

    defp verdicts(ctx) do
      for artifact <- Apiary.Artifacts.list(ctx.work_item),
          artifact.type == "verdict",
          version <- artifact.versions,
          do: version.number
    end
  end

  # A refusal as the contract's fixture has it, without `from`, which the gateway adds.
  defp refusal_fixture(name) do
    [@fixtures, "findings-refusal", name <> ".json"]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
    |> Map.delete("from")
  end

  defp uuid, do: Ecto.UUID.generate()
end
