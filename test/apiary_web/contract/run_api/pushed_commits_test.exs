defmodule ApiaryWeb.Contract.RunApi.PushedCommitsTest do
  # `POST /v1/runs/<run_id>/pushed-commits`, a run's report of the commits it pushed, and
  # the member `pushed_commits` of `GET work-item`, which lists the commits the work item's
  # earlier runs reported (`Apiary.Runs.PushedCommit`). Not async: the stubs of the run
  # API are the whole node's (`ApiaryWeb.RunApiStubs`).
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures

  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Repo
  alias Apiary.Runs.{PushedCommit, Run}
  alias ApiaryWeb.RunApiStubs

  @moduletag needs: [:workflow_model, :factory, :secrets]

  # A stage of the software process (`Apiary.Processes`) other than the one the context's
  # run is for.
  @other_stage "st_p9w5cvh311"

  @a String.duplicate("a", 40)
  @b String.duplicate("b", 40)
  @c String.duplicate("c", 40)
  @d String.duplicate("d", 64)

  setup {Apiary.DataCase, :without_registry}

  setup do
    :ok = RunApiStubs.install()

    %{scope: scope} = sign_up_fixture()
    fixture = sealed_run_fixture(scope)
    dispatch_run = Repo.get!(DispatchRun, fixture.run.dispatch_run_id)

    work_item =
      Apiary.WorkItems.WorkItem
      |> Repo.get!(dispatch_run.work_item_id)
      |> Repo.preload(:workspace)

    # The fixture's run is a read run: it reads as write when the documents its claim
    # sent say so (`Apiary.Runs.Cancel.write_run?/2`).
    refute Apiary.Runs.Cancel.write_run?(work_item.workspace, fixture.run)
    write_access!(fixture.run, "write")

    %{
      scope: scope,
      run: Repo.get!(Run, fixture.run.id),
      key: fixture.secrets_key,
      dispatch_run: dispatch_run,
      work_item: work_item
    }
  end

  defp write_access!(run, access) do
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [run_documents: Jason.encode!(%{"access" => access})]
      )
  end

  defp read(ctx, path, opts \\ []) do
    {key, seed} = Keyword.get(opts, :key, ctx.key)
    run_id = Keyword.get(opts, :run_id, ctx.run.node_run_id)
    signed_get(build_conn(), key.key_id, seed, "/v1/runs/#{run_id}" <> path)
  end

  defp write(ctx, body, opts \\ []) do
    {key, seed} = Keyword.get(opts, :key, ctx.key)
    body = if is_binary(body), do: body, else: Jason.encode!(body)
    target = "/v1/runs/#{Keyword.get(opts, :run_id, ctx.run.node_run_id)}/pushed-commits"

    build_conn()
    |> Plug.Conn.assign(:raw_body, body)
    |> signed_post(key.key_id, seed, body,
      target: target,
      content_type: "application/json",
      delivery: nil
    )
  end

  defp repo(commit, path \\ "acme/shop"),
    do: %{"system" => "forge", "path" => path, "commit" => commit}

  defp report(repositories), do: %{"repositories" => repositories}

  # The run's rows, as the list has them: in the order of `sequence`.
  defp rows(run) do
    Repo.all(
      from c in PushedCommit,
        where: c.run_id == ^run.id,
        order_by: c.sequence,
        select: {c.sequence, c.system, c.path, c.commit}
    )
  end

  defp commits(run), do: Enum.map(rows(run), &elem(&1, 3))

  # Another run of the work item, registered by a claim, with the fields `attrs` of the
  # run and `dispatch` of its run of the queue. Its number is higher than the context's
  # run's, until `latest!/1` makes the context's run the later one.
  defp sibling(ctx, attrs \\ %{}, dispatch \\ %{}) do
    queued =
      Repo.insert!(
        struct!(
          %DispatchRun{
            organisation_id: ctx.dispatch_run.organisation_id,
            workspace_id: ctx.dispatch_run.workspace_id,
            work_item_id: ctx.work_item.id,
            run_id: Ecto.UUID.generate(),
            step: ctx.dispatch_run.step,
            take_in: ctx.dispatch_run.take_in,
            attempt: ctx.dispatch_run.attempt + 1 + System.unique_integer([:positive]),
            of: ctx.dispatch_run.of + 1 + System.unique_integer([:positive]),
            queued_at: Apiary.Dispatches.now()
          },
          dispatch
        )
      )

    Apiary.RunEventsFixtures.run_fixture(
      ctx.scope,
      Map.merge(
        %{
          dispatch_run_id: queued.id,
          state: "completed",
          started_at: DateTime.utc_now(),
          exited_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  # Makes the context's run the later one, so that its `GET work-item` lists the runs
  # that `sibling/3` made earlier.
  defp latest!(ctx) do
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [number: 2_000_000_000])

    %{ctx | run: Repo.get!(Run, ctx.run.id)}
  end

  defp record!(ctx, run, repositories) do
    assert :ok =
             PushedCommit.record(
               ctx.work_item,
               run,
               Enum.map(repositories, &%{system: "forge", path: &1.path, commit: &1.commit})
             )
  end

  defp listed(conn), do: json_response(conn, 200)["pushed_commits"]

  describe "POST pushed-commits" do
    test "adds each post's commits to the run's list, in the order sent", ctx do
      conn = write(ctx, report([repo(@a), repo(@b, "acme/docs")]))
      assert conn.status == 204
      assert conn.resp_body == ""
      assert signed_answer?(conn)

      assert write(ctx, report([repo(@c)])).status == 204

      assert [
               {1, "forge", "acme/shop", @a},
               {2, "forge", "acme/docs", @b},
               {3, "forge", "acme/shop", @c}
             ] = rows(ctx.run)

      assert [%{organisation_id: org, workspace_id: ws}] =
               Repo.all(from c in PushedCommit, where: c.sequence == 1)

      assert org == ctx.run.organisation_id and ws == ctx.run.workspace_id
    end

    test "takes a 64 character commit id", ctx do
      assert write(ctx, report([repo(@d)])).status == 204
      assert commits(ctx.run) == [@d]
    end

    test "a repeat is 204 and stores nothing; a commit for another path is stored", ctx do
      assert write(ctx, report([repo(@a), repo(@b)])).status == 204
      assert write(ctx, report([repo(@a), repo(@b)])).status == 204
      assert length(rows(ctx.run)) == 2

      # One new commit among old ones takes the next position; the same commit twice in
      # one body, and the same commit for another path, are each their own rows only once.
      assert write(ctx, report([repo(@b), repo(@c), repo(@c), repo(@b, "acme/docs")])).status ==
               204

      assert [
               {1, _, "acme/shop", @a},
               {2, _, "acme/shop", @b},
               {3, _, "acme/shop", @c},
               {4, _, "acme/docs", @b}
             ] = rows(ctx.run)
    end

    test "another gateway's run, an unknown run and a malformed id are the same 404", ctx do
      %{scope: scope} = sign_up_fixture()
      fixture = sealed_run_fixture(scope)
      write_access!(fixture.run, "write")
      other_key = fixture.secrets_key

      answers =
        for conn <- [
              write(ctx, report([repo(@a)]), key: other_key),
              write(ctx, report([repo(@a)]), run_id: fixture.run.node_run_id),
              write(ctx, report([repo(@a)]), run_id: Ecto.UUID.generate()),
              write(ctx, report([repo(@a)]), run_id: "not-a-run")
            ] do
          assert signed_answer?(conn)
          {conn.status, conn.resp_body}
        end

      assert Enum.uniq(answers) == [{404, ~s({"error":"not_found"})}]
      assert Repo.aggregate(PushedCommit, :count) == 0
    end

    test "a request signed with the wrong key is 401, unsigned", ctx do
      conn =
        write(ctx, report([repo(@a)]), key: {elem(ctx.key, 0), :crypto.strong_rand_bytes(32)})

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert get_resp_header(conn, "x-qory-signature-ed25519") == []
      assert Repo.aggregate(PushedCommit, :count) == 0
    end

    test "a run that is not a write run is 409 not_writable", ctx do
      for access <- ["read", "write-no-push"] do
        write_access!(ctx.run, access)
        conn = write(ctx, report([repo(@a)]))

        assert json_response(conn, 409) == %{
                 "error" => "not_writable",
                 "message" =>
                   "Record pushed commits only from a run with write access. This run has read access."
               }
      end

      assert Repo.aggregate(PushedCommit, :count) == 0
    end

    test "a run that has ended is 409 run_ended, and nothing is stored", ctx do
      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
          set: [state: "completed", exit_state: "completed", exited_at: DateTime.utc_now()]
        )

      conn = write(ctx, report([repo(@a)]))
      assert signed_answer?(conn)

      assert json_response(conn, 409) == %{
               "error" => "run_ended",
               "message" =>
                 "Start a new run to record pushed commits. This run ended, so it records no more commits."
             }

      assert rows(ctx.run) == []
    end

    test "a run whose run of the queue ended is 409 run_ended", ctx do
      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^ctx.dispatch_run.id),
          set: [state: :ended, end_cause: :run_ended]
        )

      assert %{"error" => "run_ended"} = json_response(write(ctx, report([repo(@a)])), 409)
      assert rows(ctx.run) == []
    end

    test "a refusal comes before the body is read", ctx do
      write_access!(ctx.run, "read")
      assert %{"error" => "not_writable"} = json_response(write(ctx, "not json"), 409)
    end

    test "a body outside the contract is 400 invalid_request with the member", ctx do
      too_many = report(for n <- 1..65, do: repo(@a, "acme/r#{n}"))
      at_limit = report(for n <- 1..64, do: repo(@a, "acme/r#{n}"))
      over_size = report([repo(@a, String.duplicate("p", 64 * 1024))])

      cases = [
        {"not json", "body"},
        {"[]", "body"},
        {%{}, "repositories"},
        {%{"repositories" => []}, "repositories"},
        {%{"repositories" => "x"}, "repositories"},
        {%{"repositories" => nil}, "repositories"},
        {%{"repositories" => [repo(@a)], "branch" => "main"}, "branch"},
        {report(["x"]), "repositories[0]"},
        {report([repo(@a), Map.delete(repo(@b), "system")]), "repositories[1].system"},
        {report([Map.delete(repo(@b), "path")]), "repositories[0].path"},
        {report([Map.delete(repo(@b), "commit")]), "repositories[0].commit"},
        {report([Map.put(repo(@b), "branch", "main")]), "repositories[0].branch"},
        {report([Map.put(repo(@b), "system", "")]), "repositories[0].system"},
        {report([Map.put(repo(@b), "path", 7)]), "repositories[0].path"},
        {report([repo(String.upcase(@a))]), "repositories[0].commit"},
        {report([repo(String.duplicate("a", 39))]), "repositories[0].commit"},
        {report([repo(String.duplicate("a", 41))]), "repositories[0].commit"},
        {report([repo(String.duplicate("g", 40))]), "repositories[0].commit"},
        {report([repo(String.duplicate("a", 63))]), "repositories[0].commit"},
        {too_many, "repositories"},
        {over_size, "body"}
      ]

      for {body, member} <- cases do
        conn = write(ctx, body)
        assert signed_answer?(conn)

        assert %{"error" => "invalid_request", "names" => [^member], "message" => message} =
                 json_response(conn, 400)

        assert message =~ "Send each repository with system, path and a full commit id"
      end

      assert rows(ctx.run) == []

      # The limit itself: 64 repositories.
      assert write(ctx, at_limit).status == 204
      assert length(rows(ctx.run)) == 64
    end

    test "a request while the cancel of a member is requested is kept, with its mark", ctx do
      assert write(ctx, report([repo(@a)])).status == 204

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [state: "running"])

      {:ok, _cancelled} = Apiary.Runs.cancel(ctx.scope, Repo.get!(Run, ctx.run.id))

      # The run's end is not recorded yet: the late report is stored.
      assert write(ctx, report([repo(@b)])).status == 204
      assert commits(ctx.run) == [@a, @b]

      later = sibling(ctx)

      assert [
               %{"commit" => @a, "cancelled" => true},
               %{"commit" => @b, "cancelled" => true}
             ] = PushedCommit.for_run(ctx.work_item, later) |> Enum.map(&stringify/1)

      # Once the run of the queue ended, it is refused.
      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^ctx.dispatch_run.id),
          set: [state: :ended, end_cause: :run_ended]
        )

      assert %{"error" => "run_ended"} = json_response(write(ctx, report([repo(@c)])), 409)
      assert commits(ctx.run) == [@a, @b]
    end

    test "is 404 where the instance does not have workflow_model", ctx do
      RunApiStubs.put(:flag, false)

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
          set: [features: Apiary.Features.recorded() -- ["workflow_model"]]
        )

      conn = write(ctx, report([repo(@a)]))
      assert conn.status == 404
      assert signed_answer?(conn)
      assert rows(ctx.run) == []
    end
  end

  defp stringify(entry), do: Map.new(entry, fn {key, value} -> {Atom.to_string(key), value} end)

  describe "GET work-item pushed_commits" do
    test "is [] for a work item with no earlier run's commits, and never null", ctx do
      assert %{"pushed_commits" => []} = json_response(read(ctx, "/work-item"), 200)

      # The run's own commits are left out.
      assert write(ctx, report([repo(@a)])).status == 204
      assert listed(read(ctx, "/work-item")) == []
    end

    test "a later run of the work item gets the earlier run's commits, with the mark", ctx do
      earlier = sibling(ctx)
      record!(ctx, earlier, [%{path: "acme/shop", commit: @a}, %{path: "acme/docs", commit: @b}])

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^earlier.id),
          set: [
            cancel_requested_at: DateTime.utc_now(),
            cancel_requested_by_id: ctx.scope.user.id
          ]
        )

      ctx = latest!(ctx)
      conn = read(ctx, "/work-item")
      assert signed_answer?(conn)

      assert [
               %{
                 "system" => "forge",
                 "path" => "acme/shop",
                 "commit" => @a,
                 "run_id" => run_id,
                 "cancelled" => true,
                 "at" => at
               },
               %{"path" => "acme/docs", "commit" => @b, "cancelled" => true}
             ] = listed(conn)

      assert run_id == earlier.node_run_id
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(at)

      # The members are in this order.
      assert %Jason.OrderedObject{values: values} =
               Jason.decode!(conn.resp_body, objects: :ordered_objects)

      assert {"pushed_commits", [%Jason.OrderedObject{values: members} | _]} =
               List.keyfind(values, "pushed_commits", 0)

      assert Enum.map(members, &elem(&1, 0)) == ~w(system path commit run_id cancelled at)
    end

    test "the mark is only a member's cancel: not a time limit, a release or a lost run", ctx do
      timeout =
        sibling(ctx, %{
          state: "cancelled",
          exit_state: "cancelled",
          exit_reason: "timeout"
        })

      released = sibling(ctx, %{state: "cancelled", released_at: DateTime.utc_now()})
      lost = sibling(ctx, %{state: "lost", lost_at: DateTime.utc_now()})
      person = sibling(ctx, %{cancel_requested_at: DateTime.utc_now()})

      for {run, commit} <- [{timeout, @a}, {released, @b}, {lost, @c}, {person, @d}] do
        record!(ctx, run, [%{path: "acme/shop", commit: commit}])
      end

      ctx = latest!(ctx)

      marks =
        for entry <- listed(read(ctx, "/work-item")), do: {entry["commit"], entry["cancelled"]}

      assert Enum.sort(marks) == Enum.sort([{@a, false}, {@b, false}, {@c, false}, {@d, true}])
      assert Repo.get!(Run, timeout.id).exit_reason == "timeout"
    end

    test "lists every earlier run's commits by run number, then in the order reported", ctx do
      first = sibling(ctx)
      second = sibling(ctx)

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^first.id), set: [number: 1_000_001])

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^second.id), set: [number: 1_000_002])

      # Reported in this order, to the second one first.
      record!(ctx, second, [%{path: "acme/shop", commit: @c}])
      record!(ctx, first, [%{path: "acme/shop", commit: @b}, %{path: "acme/shop", commit: @a}])
      record!(ctx, second, [%{path: "acme/shop", commit: @d}])

      ctx = latest!(ctx)
      assert for(e <- listed(read(ctx, "/work-item")), do: e["commit"]) == [@b, @a, @c, @d]
    end

    test "two reports with the same time stay in the order they were posted", ctx do
      earlier = sibling(ctx)
      record!(ctx, earlier, [%{path: "acme/shop", commit: @c}])
      record!(ctx, earlier, [%{path: "acme/shop", commit: @a}])
      record!(ctx, earlier, [%{path: "acme/shop", commit: @b}])

      same = ~U[2026-11-17 10:00:00.000000Z]
      {3, _rows} = Repo.update_all(PushedCommit, set: [at: same])

      ctx = latest!(ctx)
      entries = listed(read(ctx, "/work-item"))
      assert Enum.map(entries, & &1["commit"]) == [@c, @a, @b]
      assert Enum.uniq(Enum.map(entries, & &1["at"])) == ["2026-11-17T10:00:00Z"]
    end

    test "a commit of another stage's run is listed in a later run's list", ctx do
      assert ctx.dispatch_run.stage_id != @other_stage

      shape = sibling(ctx, %{}, %{stage_id: @other_stage})
      record!(ctx, shape, [%{path: "acme/shop", commit: @a}])

      ctx = latest!(ctx)
      assert [%{"commit" => @a, "cancelled" => false}] = listed(read(ctx, "/work-item"))
    end

    test "leaves out the commits of another work item's runs", ctx do
      other_item = Apiary.WorkItemsFixtures.work_item_fixture(ctx.scope)

      other_dispatch =
        Repo.insert!(%DispatchRun{
          organisation_id: ctx.dispatch_run.organisation_id,
          workspace_id: ctx.dispatch_run.workspace_id,
          work_item_id: other_item.id,
          run_id: Ecto.UUID.generate(),
          step: ctx.dispatch_run.step,
          take_in: 1,
          attempt: 1,
          of: 1,
          queued_at: Apiary.Dispatches.now()
        })

      stranger =
        Apiary.RunEventsFixtures.run_fixture(ctx.scope, %{
          dispatch_run_id: other_dispatch.id,
          state: "completed",
          started_at: DateTime.utc_now(),
          exited_at: DateTime.utc_now()
        })

      assert :ok =
               PushedCommit.record(other_item, stranger, [
                 %{system: "forge", path: "acme/shop", commit: @a}
               ])

      ctx = latest!(ctx)
      assert listed(read(ctx, "/work-item")) == []
    end
  end
end
