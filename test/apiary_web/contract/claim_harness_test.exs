defmodule ApiaryWeb.Contract.ClaimHarnessTest do
  # The claim answer as a node pool's starter receives it, with no `machine`, and the
  # harness members of the run's documents, from the run's harness walk
  # (`Apiary.Harnesses.WalkJob`): `target_version`, `workflow`, `harness_hidden` and,
  # for a walk whose document came from the stacks or is a test work item's built-in
  # one, `harness`. None of the four for a prebuild, and for a run with no workflow only
  # where its walk is a row from before such runs ended at the queue: a run with no
  # workflow ends when it is queued, and no claim takes it. The run's `access` is the
  # level its walk resolved, and `read` for a prebuild and for such a row. Each answer and
  # each documents object is valid under the vendored schemas, so the module is tagged
  # `:contract`. Not async: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1]
  import Apiary.DispatchedRunsFixtures, only: [handover_place_fixture: 1, walk_resolved!: 2]
  import Apiary.NodesFixtures, only: [collection_fixture: 1]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Repo, Stacks, TimeLimits, WorkItems}
  alias Apiary.Harnesses.{Builtin, Reader}
  alias Apiary.Nodes.Node
  alias Apiary.Policy.ComposedConfiguration
  alias Apiary.Processes.Version
  alias Apiary.QoryHarnessFixture
  alias Apiary.Runs.RunCredential
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory
  @moduletag :contract

  @vendored Path.expand("../../fixtures/contract", __DIR__)
  @base "https://qory.dev/contracts/"

  # The vendored schemas by their URL under the contracts' base, and Forager's from its
  # contract directory (`Apiary.ContractFixtures.contract_dir/0`). Nothing is fetched.
  defmodule Resolver do
    @moduledoc false
    @behaviour JSV.Resolver

    @base "https://qory.dev/contracts/"

    @impl JSV.Resolver
    def resolve(@base <> path, roots) do
      Enum.find_value(roots, {:error, {:not_vendored, path}}, fn root ->
        file = Path.expand(path, root)

        with true <- String.starts_with?(file, root <> "/"),
             {:ok, body} <- File.read(file),
             {:ok, schema} <- Jason.decode(body) do
          {:ok, schema}
        else
          _ -> nil
        end
      end)
    end

    def resolve(url, _roots), do: {:error, {:not_vendored, url}}
  end

  @document "extends: {git: https://code.example.com/team/stacks, ref: main, path: core}\n"
  @version "0123456789abcdef0123456789abcdef01234567"

  setup do
    Process.put(:now_time, {SignedRequest.now(), 0})
    %{scope: scope} = sign_up_fixture()

    scope
    |> handover_place_fixture()
    |> Map.put(:scope, scope)
  end

  # Stores the workspace's stack row for the workflow `explore-a-ticket`, with `harness`:
  # the workflow of the run's stage entry.
  defp workflow!(ctx, harness \\ @document) do
    {:ok, _stack} =
      Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace, "explore-a-ticket"}, harness)
  end

  # A request's time, one second earlier for each request the test sends, so no two
  # requests are one signed body.
  defp now_time do
    {base, sent} = Process.get(:now_time)
    Process.put(:now_time, {base, sent + 1})
    (base - sent - 1) |> DateTime.from_unix!() |> DateTime.to_iso8601()
  end

  defp signed(ctx, target, body) do
    signed_post(build_conn(), ctx.key.key_id, ctx.seed, Map.put(body, "time", now_time()),
      target: target,
      content_type: "application/json",
      delivery: nil,
      contract_version: "1"
    )
  end

  defp validator(path) do
    forager =
      case Apiary.ContractFixtures.contract_dir() do
        nil -> []
        dir -> [Path.expand("../..", dir)]
      end

    JSV.build!(%{"$ref" => @base <> path},
      resolver: {Resolver, [@vendored | forager]},
      formats: true
    )
  end

  # The claim answer of the oldest run the pool may take: 200, signed, valid under the
  # vendored schema.
  defp claim(ctx) do
    :ok = Apiary.DispatchedRunsFixtures.walks_resolved!()
    claim = signed(ctx, "/v1/pools/claim", %{"version" => 1, "wait_seconds" => 0})
    assert claim.status == 200
    assert signed_answer?(claim)

    assert {:ok, _} =
             claim.resp_body
             |> Jason.decode!()
             |> JSV.validate(validator("provisioner/v1/claim-answer.schema.json"))

    claim.resp_body
  end

  # The documents the claim stored on the run it registered, as stored.
  defp stored(claim) do
    code = Jason.decode!(claim)["run_code"]
    [head, _fingerprint] = String.split(code, ".")
    hash = Apiary.AccessKeys.EnrolmentCode.hash(head)
    Repo.get_by!(Apiary.Runs.Run, run_code_sha256: hash).run_documents
  end

  # The SHA-256 of the run code of the run the claim registered.
  defp code_hash(claim) do
    [head, _fingerprint] = String.split(Jason.decode!(claim)["run_code"], ".")
    Apiary.AccessKeys.EnrolmentCode.hash(head)
  end

  # The documents the claim stored, each checked against the run contract's schema.
  defp documents(claim) do
    documents = claim |> stored() |> Jason.decode!()
    valid!(documents)
    documents
  end

  # A work item's explore run, queued, its harness walk resolved with `walk`.
  defp explore!(ctx, walk, attrs \\ %{}) do
    work_item =
      work_item_fixture(ctx.scope, Map.merge(%{target_system: "tickets.example.com"}, attrs))

    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    walk_resolved!(run, walk)
    work_item
  end

  # Saves the instance's largest prebuilt image, `gb` GB, nil for no limit, as Instance
  # settings › Configuration saves it (`Apiary.InstanceConfig`).
  defp largest_prebuilt_image!(gb) do
    Repo.insert_all(
      Apiary.InstanceConfig.Row,
      [%{id: true, prebuilt_image_max_gb: gb, updated_at: DateTime.utc_now()}],
      on_conflict: {:replace, [:prebuilt_image_max_gb]},
      conflict_target: :id
    )
  end

  defp section do
    {:ok, section} = Reader.document(@document)
    section
  end

  defp valid!(documents),
    do: assert({:ok, _} = JSV.validate(documents, validator("run/v1/documents.schema.json")))

  # The members of a JSON object, in their order.
  defp members(json),
    do:
      json
      |> Jason.decode!(objects: :ordered_objects)
      |> Map.get(:values)
      |> Enum.map(&elem(&1, 0))

  @claim ~w(version revision dispatch_id pool_id lease_until)
  @code ~w(run_code gateway_url max_lifetime_minutes)

  @harness ~w(target_version workflow harness_hidden harness)

  describe "an explore run" do
    test "has the step workflow, its work item as subject, and the trigger take_in", ctx do
      workflow!(ctx)
      work_item = explore!(ctx, origin: :file, target_version: @version)
      documents = documents(claim(ctx))

      assert documents["step"] == "workflow"

      assert documents["subject"] == %{
               "kind" => "work_item",
               "id" => work_item.public_id,
               "url" => Apiary.WorkItems.stable_url(work_item),
               "title" => work_item.title
             }

      assert documents["trigger"] == "take_in"
      refute Map.has_key?(documents, "work_item")
    end

    test "leaves out of its subject a title the contract's draft_title refuses", ctx do
      workflow!(ctx)
      title = String.duplicate("a", 300)
      work_item = explore!(ctx, [origin: :file, target_version: @version], %{title: title})
      assert work_item.title == title
      documents = documents(claim(ctx))

      assert documents["subject"] == %{
               "kind" => "work_item",
               "id" => work_item.public_id,
               "url" => Apiary.WorkItems.stable_url(work_item)
             }
    end

    # A later round, a retry or a return to the first stage is a later attempt of the take
    # in: the run that take in starts is attempt 1 alone.
    test "has no trigger at a later attempt of its take in", ctx do
      workflow!(ctx)
      work_item = explore!(ctx, origin: :file, target_version: @version)

      {1, _rows} =
        Repo.update_all(
          from(r in Apiary.Dispatches.DispatchRun, where: r.work_item_id == ^work_item.id),
          set: [attempt: 2]
        )

      documents = documents(claim(ctx))
      assert documents["step"] == "workflow"
      refute Map.has_key?(documents, "trigger")
      valid!(documents)
    end

    # A requeue after a missing image is the same run of the take in, one attempt later.
    test "keeps the trigger on the run that requeues it after a missing image", ctx do
      workflow!(ctx)
      work_item = explore!(ctx, origin: :file, target_version: @version)
      first = Repo.get_by!(Apiary.Dispatches.DispatchRun, work_item_id: work_item.id)

      first =
        first
        |> Ecto.Changeset.change(state: :ended, end_cause: :run_ended)
        |> Repo.update!()

      {:ok, requeued} = Repo.transact(fn -> Dispatches.requeue_for_image(first) end)
      assert %{attempt: 2, image_requeue: true, explore: true} = requeued
      walk_resolved!(requeued, origin: :file, target_version: @version)

      documents = documents(claim(ctx))
      assert documents["trigger"] == "take_in"
      assert documents["subject"]["id"] == work_item.public_id

      # A run after a later round of the same take in is not a requeue: no trigger.
      {1, _rows} =
        Repo.update_all(
          from(r in Apiary.Dispatches.DispatchRun, where: r.id == ^requeued.id),
          set: [image_requeue: false]
        )

      refute Dispatches.take_in_run?(Repo.get!(Apiary.Dispatches.DispatchRun, requeued.id))
    end

    # A run that paused and continues is the same run of the take in, one attempt later. A
    # continuation at a later round of a shared loop has none, in
    # Apiary.Stages.SharedRunTest.
    test "keeps the trigger on the run that continues it after a pause", ctx do
      workflow!(ctx)
      work_item = explore!(ctx, origin: :file, target_version: @version)
      first = Repo.get_by!(Apiary.Dispatches.DispatchRun, work_item_id: work_item.id)

      {:ok, continuation} =
        Repo.transact(fn ->
          first
          |> Ecto.Changeset.change(state: :ended, end_cause: :run_ended)
          |> Repo.update!()
          |> Dispatches.requeue_for_pause(nil, nil)
        end)

      assert %{attempt: 2, image_requeue: false, explore: true} = continuation
      assert continuation.continues_id == first.id
      walk_resolved!(continuation, origin: :file, target_version: @version)

      documents = documents(claim(ctx))
      assert documents["trigger"] == "take_in"
      assert documents["subject"]["id"] == work_item.public_id
    end

    # The run's kind in what it is about is its workflow, which the run page shows.
    test "registers its workflow as its kind: explore-a-ticket in a software factory", ctx do
      workflow!(ctx)
      work_item = explore!(ctx, origin: :file, target_version: @version)

      about =
        Repo.get_by!(Apiary.Runs.Run, run_code_sha256: code_hash(claim(ctx))).registration_about

      assert about == %{
               "kind" => "explore-a-ticket",
               "subjects" => [%{"type" => "work_item", "ref" => work_item.public_id}]
             }
    end

    test "registers its workflow as its kind: draft-reply for a first stage Triage", ctx do
      stage = %{
        "id" => "st_r79kph11eg",
        "name" => "Triage",
        "inputs" => [],
        "sequence" => [%{"workflow" => "draft-reply"}],
        "outputs" => [],
        "gate" => %{"kind" => "person", "approvers" => "members"}
      }

      document = %{"schema" => "qory.process/v1", "machine" => "default", "stages" => [stage]}
      {:ok, _version} = Apiary.Processes.save(ctx.scope, ctx.scope.workspace, document)
      explore!(ctx, origin: :file, target_version: @version)
      claim = claim(ctx)
      about = Repo.get_by!(Apiary.Runs.Run, run_code_sha256: code_hash(claim)).registration_about

      assert about["kind"] == "draft-reply"
      assert documents(claim)["workflow"] == "draft-reply"
    end

    test "leaves out of its subject a title with a line break, a format character or spaces alone",
         ctx do
      workflow!(ctx)

      for title <- ["The basket\nempties", "The basket\u200Bempties", "   "] do
        work_item = explore!(ctx, origin: :file, target_version: @version)

        {1, _rows} =
          Repo.update_all(from(w in Apiary.WorkItems.WorkItem, where: w.id == ^work_item.id),
            set: [title: title]
          )

        documents = documents(claim(ctx))
        refute Map.has_key?(documents["subject"], "title"), inspect(title)
        assert documents["subject"]["id"] == work_item.public_id
        valid!(documents)
      end
    end

    test "whose target's harness file applies has its version and no harness", ctx do
      workflow!(ctx)
      explore!(ctx, origin: :file, target_version: @version)
      claim = claim(ctx)
      assert members(claim) == @claim ++ @code
      documents = documents(claim)

      assert Map.take(documents, @harness) == %{
               "target_version" => @version,
               "workflow" => "explore-a-ticket",
               "harness_hidden" => false
             }

      assert documents["access"] == "read"
      valid!(documents)
    end

    test "whose stacks' document applies has it as harness, after its target's version",
         ctx do
      workflow!(ctx)
      explore!(ctx, origin: :setting, document: section(), target_version: @version)
      stored = stored(claim(ctx))
      documents = Jason.decode!(stored)

      assert Map.take(documents, @harness) == %{
               "target_version" => @version,
               "workflow" => "explore-a-ticket",
               "harness_hidden" => false,
               "harness" => %{"harness" => section()}
             }

      assert stored |> members() |> Enum.filter(&(&1 in @harness)) == @harness

      valid!(documents)
    end

    test "with no target has the stacks' document and no target version", ctx do
      ctx = %{ctx | scope: with_domain(ctx.scope, "example")}
      workflow!(ctx)

      explore!(ctx, [origin: :setting, document: section()], %{
        target_collection_external_ref: nil,
        target_system: nil,
        target_path: nil
      })

      documents = documents(claim(ctx))

      assert Map.take(documents, @harness) == %{
               "workflow" => "explore-a-ticket",
               "harness_hidden" => false,
               "harness" => %{"harness" => section()}
             }

      valid!(documents)
    end

    test "with a hidden harness has harness_hidden true", ctx do
      %{scope: other} = sign_up_fixture()

      {:ok, _stack} =
        Stacks.put_stack(other, {:workspace, ctx.scope.workspace, "explore-a-ticket"}, @document)

      explore!(ctx, origin: :setting, document: section(), harness_hidden: true)
      documents = documents(claim(ctx))
      assert %{"workflow" => "explore-a-ticket", "harness_hidden" => true} = documents
      valid!(documents)
    end

    test "has no largest_prebuilt_image_bytes, whatever the instance's largest prebuilt image",
         ctx do
      largest_prebuilt_image!(20)
      workflow!(ctx)
      explore!(ctx, origin: :file, target_version: @version)
      refute Map.has_key?(documents(claim(ctx)), "largest_prebuilt_image_bytes")
    end

    # Without the workflow model, a run of a workspace with no Harness page row with a
    # workflow walks the first workflow of the first stage of the process's current version.
    @tag with_features: Apiary.Features.all() -- [:workflow_model]
    test "with no Harness page row has the process's first workflow", ctx do
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, @document)
      first = Apiary.Stages.first_workflow(Apiary.Processes.current(ctx.scope.workspace))
      assert is_binary(first)
      explore!(ctx, origin: :setting, document: section(), target_version: @version)
      claim = claim(ctx)
      assert members(claim) == @claim ++ @code
      documents = documents(claim)

      assert %{"step" => "workflow", "workflow" => ^first, "access" => "read"} = documents
      valid!(documents)
    end
  end

  describe "the run's access" do
    test "is write where the walk resolved write", ctx do
      workflow!(ctx)

      explore!(ctx,
        origin: :setting,
        document: section(),
        target_version: @version,
        access_level: :write
      )

      documents = documents(claim(ctx))
      assert %{"access" => "write", "workflow" => "explore-a-ticket"} = documents
      valid!(documents)
    end

    test "is read where the walk resolved read", ctx do
      workflow!(ctx)
      explore!(ctx, origin: :setting, document: section(), target_version: @version)
      documents = documents(claim(ctx))
      assert %{"access" => "read", "workflow" => "explore-a-ticket"} = documents
      valid!(documents)
    end
  end

  describe "a run's submit step" do
    @describetag needs: [:factory, :workflow_model]

    # The workspace's process: one stage whose sequence runs `explore-a-ticket`, with
    # `submit` in its version's template record, as a version saved before Qory Apiary
    # stopped keeping it. The runs queued after it are of this version.
    defp process!(ctx) do
      workflow!(ctx)
      entry = %{"workflow" => "explore-a-ticket"}

      stage = %{
        "id" => "st_r79kph11eg",
        "name" => "Explore",
        "inputs" => [],
        "sequence" => [entry],
        "outputs" => [],
        "gate" => %{"kind" => "person", "approvers" => "members"}
      }

      document = %{"schema" => "qory.process/v1", "machine" => "default", "stages" => [stage]}
      {:ok, version} = Apiary.Processes.save(ctx.scope, ctx.scope.workspace, document)

      template =
        (version.template || %{})
        |> Map.put_new("commit", @version)
        |> Map.put("submit", %{"type" => "code-change", "send" => "end_of_run"})

      {1, _rows} =
        Repo.update_all(from(v in Version, where: v.id == ^version.id), set: [template: template])

      version
    end

    # A work item's explore run whose walk resolved `access`, from the stacks' document.
    defp walked!(ctx, access) do
      explore!(ctx,
        origin: :setting,
        document: section(),
        target_version: @version,
        access_level: access
      )
    end

    test "is absent from a write run, where its version's template record has submit", ctx do
      process!(ctx)
      walked!(ctx, :write)
      documents = documents(claim(ctx))

      assert %{"access" => "write", "workflow" => "explore-a-ticket"} = documents
      refute Map.has_key?(documents, "submit")
      refute Map.has_key?(documents, "submit_module")
      valid!(documents)
    end
  end

  describe "a run's deliver" do
    @describetag needs: [:factory, :workflow_model]

    # A structured type of the record whose `deliver` has `send`.
    defp delivered_type(name, send) do
      %{
        "name" => name,
        "base_view" => "structured",
        "deliver" => %{"send" => send},
        "json_schema" => %{"type" => "object"}
      }
    end

    # The workspace's process, as `process!/1` saves it, with `types` as the
    # `artifact_types` of its version's template record.
    defp delivering!(ctx, types), do: ctx |> process!() |> retyped!(types)

    defp retyped!(version, types) do
      template = version |> Repo.reload!() |> Map.fetch!(:template)

      {1, _rows} =
        Repo.update_all(from(v in Version, where: v.id == ^version.id),
          set: [template: template |> Map.delete("submit") |> Map.put("artifact_types", types)]
        )

      version
    end

    test "lists the delivered types of the process version on a write run", ctx do
      delivering!(ctx, [
        delivered_type("pull-request", "end_of_run"),
        %{"name" => "notes", "base_view" => "structured"},
        delivered_type("reply", "after_gate")
      ])

      walked!(ctx, :write)
      documents = documents(claim(ctx))

      assert %{"access" => "write", "workflow" => "explore-a-ticket"} = documents

      assert documents["deliver"] == [
               %{"type" => "pull-request", "send" => "end_of_run"},
               %{"type" => "reply", "send" => "after_gate"}
             ]
    end

    test "is absent from a read run, and from a write run of a process that delivers none",
         ctx do
      version = delivering!(ctx, [delivered_type("pull-request", "end_of_run")])
      walked!(ctx, :read)
      documents = documents(claim(ctx))
      assert documents["access"] == "read"
      refute Map.has_key?(documents, "deliver")

      retyped!(version, [%{"name" => "notes", "base_view" => "structured"}])
      walked!(ctx, :write)
      documents = documents(claim(ctx))
      assert documents["access"] == "write"
      refute Map.has_key?(documents, "deliver")
    end

    test "is absent from a write run with no target", ctx do
      ctx = %{ctx | scope: with_domain(ctx.scope, "example")}
      delivering!(ctx, [delivered_type("pull-request", "end_of_run")])

      explore!(ctx, [origin: :setting, document: section(), access_level: :write], %{
        target_collection_external_ref: nil,
        target_system: nil,
        target_path: nil
      })

      documents = documents(claim(ctx))
      assert documents["workflow"] == "explore-a-ticket"
      refute Map.has_key?(documents, "target")
      refute Map.has_key?(documents, "deliver")
    end

    # A process that lists a type twice fails the check of its types, so no process version
    # that passed it gets documents that fail the documents check. A claim of a run of a
    # record written past that check is refused, 503, and issues no run code.
    test "fails the documents check only for a record that fails the check of types",
         ctx do
      twice = [
        delivered_type("pull-request", "end_of_run"),
        delivered_type("pull-request", "after_gate")
      ]

      assert {:error, refusals} =
               Apiary.Artifacts.TemplateTypes.check(%{artifact_types: twice, process: nil})

      assert {:invalid, "pull-request", :repeated} in refusals

      delivering!(ctx, twice)
      walked!(ctx, :write)

      log =
        capture_log(fn ->
          :ok = Apiary.DispatchedRunsFixtures.walks_resolved!()
          claim = signed(ctx, "/v1/pools/claim", %{"version" => 1, "wait_seconds" => 0})
          assert claim.status == 503
        end)

      assert log =~
               ~s|the run's documents fail their check: List each deliver type once: "pull-request" appears twice.|

      refute Repo.exists?(from r in Apiary.Runs.Run, where: not is_nil(r.run_code_sha256))
    end
  end

  describe "a run of a stage" do
    @describetag needs: [:factory, :workflow_model]

    @build "st_6ns22c4pav"

    # The workspace's process: one stage, Build, with `sequence` and `extra`, whose first
    # workflow, plan-the-build, has a stack row. The runs queued after it are of this
    # version.
    defp build!(ctx, sequence, extra) do
      {:ok, _stack} =
        Stacks.put_stack(
          ctx.scope,
          {:workspace, ctx.scope.workspace, "plan-the-build"},
          @document
        )

      stage =
        Map.merge(
          %{
            "id" => @build,
            "name" => "Build",
            "inputs" => [],
            "sequence" => sequence,
            "outputs" => [],
            "gate" => %{"kind" => "person", "approvers" => "members"}
          },
          extra
        )

      document = %{"schema" => "qory.process/v1", "machine" => "default", "stages" => [stage]}
      {:ok, _version} = Apiary.Processes.save(ctx.scope, ctx.scope.workspace, document)
    end

    # plan-the-build, then a loop of implement-changes and review-changes, with `review`
    # merged into the review-changes entry.
    defp build_loop(review) do
      [
        %{"workflow" => "plan-the-build"},
        %{
          "loop" => %{
            "rounds" => 3,
            "body" => [
              %{"workflow" => "implement-changes"},
              Map.merge(%{"workflow" => "review-changes"}, review)
            ]
          }
        }
      ]
    end

    # The levels that the stack file the walk of `work_item`'s run read declares for each
    # workflow, as the walk records them (`workflow_levels`).
    defp table!(work_item, levels) do
      {1, _rows} =
        Repo.update_all(
          from(h in Apiary.Harnesses.RunHarness,
            join: r in Apiary.Dispatches.DispatchRun,
            on: r.id == h.dispatch_run_id,
            where: r.work_item_id == ^work_item.id
          ),
          set: [workflow_levels: levels]
        )
    end

    # The run of the queue of `work_item`, its run record and its sessions.
    defp claimed(work_item) do
      run = Repo.get_by!(Apiary.Dispatches.DispatchRun, work_item_id: work_item.id)

      sessions =
        Repo.all(
          from s in Apiary.Stages.Session,
            where: s.dispatch_run_id == ^run.id,
            order_by: s.sequence
        )

      {Repo.get_by!(Apiary.Runs.Run, dispatch_run_id: run.id), sessions}
    end

    # The members of the documents from `run_settings` to `workflow`.
    defp around_settings(json) do
      json
      |> members()
      |> Enum.drop_while(&(&1 != "run_settings"))
      |> Enum.take_while(&(&1 != "workflow"))
    end

    test "with shared_run, of a write run, has the first session's limit, shared_run and type_settings, and the claim keeps each entry's settings and the first session",
         ctx do
      build!(
        ctx,
        [
          %{"workflow" => "plan-the-build", "first_attempt" => true},
          %{
            "loop" => %{
              "rounds" => 3,
              "body" => [%{"workflow" => "implement-changes"}, %{"workflow" => "review-changes"}]
            }
          }
        ],
        %{"shared_run" => true}
      )

      {:ok, _limit} = TimeLimits.put_limit(ctx.scope, :workspace, "plan-the-build", 45)
      {:ok, _limit} = TimeLimits.put_limit(ctx.scope, :workspace, "review-changes", 90)
      work_item = walked!(ctx, :write)
      json = claim(ctx) |> stored()
      documents = Jason.decode!(json)
      valid!(documents)

      assert %{
               "workflow" => "plan-the-build",
               "time_limit_minutes" => 45,
               "shared_run" => true,
               "type_settings" => %{"full_suite" => true}
             } = documents

      refute Map.has_key?(documents, "full_suite")
      refute Map.has_key?(documents["run_settings"], "time_limit_minutes")

      assert around_settings(json) ==
               ~w(run_settings time_limit_minutes shared_run type_settings)

      {run, sessions} = claimed(work_item)

      # No model choice: each entry runs on the default runtime.
      assert run.session_settings == %{
               "0" => %{
                 "workflow" => "plan-the-build",
                 "time_limit_minutes" => 45,
                 "type_settings" => %{"full_suite" => true},
                 "model_choice" => %{"runtime" => "claude"}
               },
               "1.0" => %{
                 "workflow" => "implement-changes",
                 "time_limit_minutes" => 180,
                 "type_settings" => %{"full_suite" => true},
                 "model_choice" => %{"runtime" => "claude"}
               },
               "1.1" => %{
                 "workflow" => "review-changes",
                 "time_limit_minutes" => 90,
                 "type_settings" => %{"full_suite" => true},
                 "model_choice" => %{"runtime" => "claude"}
               }
             }

      assert [%{sequence: 1, workflow: "plan-the-build", stage_entry: 0, forager_session: nil}] =
               sessions
    end

    test "without shared_run has no shared_run, type_settings with full_suite false, and the claim keeps nothing for sessions",
         ctx do
      build!(ctx, [%{"workflow" => "plan-the-build"}], %{})
      work_item = walked!(ctx, :read)
      json = claim(ctx) |> stored()
      documents = Jason.decode!(json)
      valid!(documents)

      assert %{
               "workflow" => "plan-the-build",
               "time_limit_minutes" => 180,
               "type_settings" => %{"full_suite" => false}
             } = documents

      refute Map.has_key?(documents, "shared_run")
      refute Map.has_key?(documents, "full_suite")
      assert around_settings(json) == ~w(run_settings time_limit_minutes type_settings)

      assert {%{session_settings: nil}, []} = claimed(work_item)
    end

    test "without shared_run has full_suite for an entry with first_attempt of a write run",
         ctx do
      build!(ctx, [%{"workflow" => "plan-the-build", "first_attempt" => true}], %{})
      walked!(ctx, :write)
      documents = documents(claim(ctx))

      assert %{"access" => "write", "type_settings" => %{"full_suite" => true}} = documents
      refute Map.has_key?(documents, "shared_run")
      refute Map.has_key?(documents, "full_suite")
    end

    # A run of the example domain has no type settings: its documents have neither
    # type_settings nor full_suite, where a software factory's run would run the full suite.
    test "of a workspace of another domain has no type_settings and no full_suite", ctx do
      ctx = %{ctx | scope: with_domain(ctx.scope, "example")}

      build!(
        ctx,
        [
          %{"workflow" => "plan-the-build", "first_attempt" => true},
          %{"loop" => %{"rounds" => 3, "body" => [%{"workflow" => "implement-changes"}]}}
        ],
        %{"shared_run" => true}
      )

      work_item = walked!(ctx, :write)
      documents = documents(claim(ctx))

      assert %{"domain" => "example", "access" => "write", "shared_run" => true} = documents
      refute Map.has_key?(documents, "type_settings")
      refute Map.has_key?(documents, "full_suite")

      {run, _sessions} = claimed(work_item)

      for {_place, settings} <- run.session_settings do
        assert settings["type_settings"] == nil
        refute Map.has_key?(settings, "full_suite")
      end
    end

    test "with shared_run ends before it starts where the run's harness sets write-no-push beside write",
         ctx do
      build!(
        ctx,
        [%{"workflow" => "plan-the-build"}, %{"workflow" => "implement-changes"}],
        %{"shared_run" => true}
      )

      # The run's harness, read by its walk after the save, sets implement-changes to
      # write-no-push.
      work_item = walked!(ctx, :write)
      table!(work_item, %{"plan-the-build" => :write, "implement-changes" => :write_no_push})
      :ok = Apiary.DispatchedRunsFixtures.walks_resolved!()

      # The claim ends the run and finds no other: no run to hand over.
      claim = signed(ctx, "/v1/pools/claim", %{"version" => 1, "wait_seconds" => 0})
      assert claim.status == 204

      assert %Apiary.Dispatches.DispatchRun{
               state: :ended,
               end_cause: :shared_access_differs,
               result_outcome: :error
             } = Repo.get_by!(Apiary.Dispatches.DispatchRun, work_item_id: work_item.id)

      assert {_run, []} = claimed(work_item)
      work_item = Repo.get!(WorkItems.WorkItem, work_item.id)
      assert work_item.stage_state == :escalated

      assert [%{points: [%{"text" => text, "fix" => fix}]}] =
               Repo.all(
                 from e in Apiary.Stages.Escalation, where: e.work_item_id == ^work_item.id
               )

      assert text ==
               "The run stopped: it did not start, because the workflows of Build mix access levels that cannot share one run. implement-changes runs with write-no-push access, because its harness sets write-no-push."

      assert fix ==
               "Move implement-changes to a separate stage in Workspace settings › Workflows, or ask whoever keeps the harness to give it write access, then run the round again."
    end

    # A guard against a rule that lets every mix share one run: the old rule refused this
    # stage too.
    test "with shared_run ends before it starts where the harness sets write-no-push beside a read entry",
         ctx do
      build!(
        ctx,
        [
          %{"workflow" => "plan-the-build", "access" => "read"},
          %{"workflow" => "implement-changes"}
        ],
        %{"shared_run" => true}
      )

      work_item = walked!(ctx, :write)
      table!(work_item, %{"plan-the-build" => :write, "implement-changes" => :write_no_push})
      :ok = Apiary.DispatchedRunsFixtures.walks_resolved!()
      claim = signed(ctx, "/v1/pools/claim", %{"version" => 1, "wait_seconds" => 0})
      assert claim.status == 204

      assert %Apiary.Dispatches.DispatchRun{state: :ended, end_cause: :shared_access_differs} =
               Repo.get_by!(Apiary.Dispatches.DispatchRun, work_item_id: work_item.id)
    end

    test "with shared_run starts a loop that writes in implement-changes and reads in review-changes, at write, with no access per session",
         ctx do
      build!(ctx, build_loop(%{"access" => "read"}), %{"shared_run" => true})
      work_item = walked!(ctx, :write)
      json = claim(ctx) |> stored()
      documents = Jason.decode!(json)
      valid!(documents)

      # One access level for the run, at its top level; none for a session.
      assert %{"access" => "write", "shared_run" => true} = documents
      assert json |> String.split(~s("access":)) |> length() == 2

      assert {%{session_settings: %{"1.1" => %{"workflow" => "review-changes"} = review}}, _} =
               claimed(work_item)

      refute Map.has_key?(review, "access")
    end

    test "with shared_run starts at write where the run's harness sets review-changes to read",
         ctx do
      build!(ctx, build_loop(%{}), %{"shared_run" => true})
      work_item = walked!(ctx, :write)

      table!(work_item, %{
        "plan-the-build" => :write,
        "implement-changes" => :write,
        "review-changes" => :read
      })

      assert %{"access" => "write", "shared_run" => true} = documents(claim(ctx))
    end

    # Explore follows the rule of any stage (`Apiary.Stages.session_flags/2`).
    test "of Explore, whose entry is a loop, has full_suite with write access", ctx do
      workflow!(ctx)

      stage = %{
        "id" => "st_r79kph11eg",
        "name" => "Explore",
        "inputs" => [],
        "sequence" => [
          %{"loop" => %{"rounds" => 3, "body" => [%{"workflow" => "explore-a-ticket"}]}}
        ],
        "outputs" => [],
        "gate" => %{"kind" => "person", "approvers" => "members"}
      }

      document = %{"schema" => "qory.process/v1", "machine" => "default", "stages" => [stage]}
      {:ok, _version} = Apiary.Processes.save(ctx.scope, ctx.scope.workspace, document)
      work_item = walked!(ctx, :write)
      documents = documents(claim(ctx))

      assert %{
               "access" => "write",
               "workflow" => "explore-a-ticket",
               "type_settings" => %{"full_suite" => true}
             } = documents

      assert %Apiary.Dispatches.DispatchRun{explore: true} =
               Repo.get_by!(Apiary.Dispatches.DispatchRun, work_item_id: work_item.id)
    end

    # Explore is the first stage. Its run shares one run and runs the full suite after
    # each session of its loop, as a later stage's would.
    test "of a shared first stage whose entry is a loop, has full_suite with write access",
         ctx do
      build!(
        ctx,
        [
          %{
            "loop" => %{
              "rounds" => 2,
              "body" => [%{"workflow" => "plan-the-build"}, %{"workflow" => "implement-changes"}]
            }
          }
        ],
        %{"shared_run" => true}
      )

      work_item = walked!(ctx, :write)
      documents = documents(claim(ctx))

      assert %{
               "access" => "write",
               "workflow" => "plan-the-build",
               "shared_run" => true,
               "type_settings" => %{"full_suite" => true}
             } = documents

      {run, _sessions} = claimed(work_item)

      assert %{
               "0.0" => %{"type_settings" => %{"full_suite" => true}},
               "0.1" => %{"type_settings" => %{"full_suite" => true}}
             } = run.session_settings

      assert %Apiary.Dispatches.DispatchRun{explore: true} =
               Repo.get_by!(Apiary.Dispatches.DispatchRun, work_item_id: work_item.id)
    end

    test "of a run that reads or does not push has full_suite false, as does every session",
         ctx do
      build!(
        ctx,
        [
          %{"workflow" => "plan-the-build", "first_attempt" => true},
          %{"loop" => %{"rounds" => 3, "body" => [%{"workflow" => "implement-changes"}]}}
        ],
        %{"shared_run" => true}
      )

      work_item = walked!(ctx, :write_no_push)
      table!(work_item, %{"implement-changes" => :write_no_push})
      documents = documents(claim(ctx))

      assert %{
               "access" => "write-no-push",
               "shared_run" => true,
               "type_settings" => %{"full_suite" => false}
             } = documents

      refute Map.has_key?(documents, "full_suite")
      {run, _sessions} = claimed(work_item)

      assert %{
               "0" => %{"type_settings" => %{"full_suite" => false}},
               "1.0" => %{"type_settings" => %{"full_suite" => false}}
             } = run.session_settings
    end
  end

  describe "a test work item's explore run" do
    # The run the claim registered.
    defp registered(claim) do
      code = Jason.decode!(claim)["run_code"]
      [head, _fingerprint] = String.split(code, ".")
      Repo.get_by!(Apiary.Runs.Run, run_code_sha256: Apiary.AccessKeys.EnrolmentCode.hash(head))
    end

    # The run's kind is the workflow its walk resolved, which its documents have, not the
    # workflow of its stage entry.
    test "registers the walk's workflow hello as its kind, not its stage entry's", ctx do
      {:ok, work_item} = WorkItems.take_in_test(ctx.scope, "Hello! Where are you running?")

      run = Repo.get_by!(Apiary.Dispatches.DispatchRun, work_item_id: work_item.id)
      assert is_binary(run.workflow) and run.workflow != Builtin.workflow()

      claim = claim(ctx)
      assert documents(claim)["workflow"] == "hello"
      assert registered(claim).registration_about["kind"] == "hello"
    end

    test "has the built-in harness and workflow, no target and no access, in a software and an example workspace",
         ctx do
      for domain <- ["software", "example"] do
        %{scope: scope} = sign_up_fixture()
        scope = with_domain(scope, domain)
        ctx = Map.merge(ctx, handover_place_fixture(scope)) |> Map.put(:scope, scope)

        # The workspace's level for `hello`, which a test work item's run does not read.
        workflow!(ctx)
        {:ok, _work_item} = WorkItems.take_in_test(scope, "Hello! Where are you running?")

        claim = claim(ctx)
        documents = documents(claim)

        # The built-in harness at the commit of qory's main when the claim read it.
        resolved =
          put_in(Builtin.document(), ["extends", "ref"], QoryHarnessFixture.builtin_commit())

        assert Map.take(documents, @harness) == %{
                 "workflow" => "hello",
                 "harness_hidden" => false,
                 "harness" => %{"harness" => resolved}
               }

        refute Map.has_key?(documents, "access")
        refute Map.has_key?(documents, "target")
        assert documents["domain"] == domain
        valid!(documents)

        # No token for the source: no work credential, and its host for the stack proxy
        # alone.
        run = registered(claim)
        assert {:ok, members} = ComposedConfiguration.members(run)
        assert members.stack_hosts == ["github.com"]
        assert members.work == nil
        refute Repo.exists?(from c in RunCredential, where: c.run_id == ^run.id)
      end
    end
  end

  describe "a prebuild" do
    # A claim takes a prebuild only on an instance with a registry.
    @describetag needs: [:factory, :registry]

    # The claim of a prebuild of `collection` for `env-1`: its documents.
    defp prebuild_documents(ctx, collection) do
      {:ok, _run} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

      claim = claim(ctx)
      assert members(claim) == @claim ++ @code
      documents(claim)
    end

    test "of a workspace with a stack row with a workflow has no harness members", ctx do
      workflow!(ctx)
      documents = prebuild_documents(ctx, collection_fixture(ctx.scope))
      assert Map.take(documents, @harness) == %{}
      assert documents["access"] == "read"
      assert documents["inputs"] == %{"version" => 1, "environment_ref" => "env-1"}
    end

    test "has no submit and no submit_module, where its collection's adapter has targets",
         ctx do
      workflow!(ctx)
      collection = collection_fixture(ctx.scope)

      {1, _rows} =
        Repo.update_all(from(n in Node, where: n.id == ^collection.adapter_id),
          set: [targets: true]
        )

      documents = prebuild_documents(ctx, collection)
      refute Map.has_key?(documents, "submit")
      refute Map.has_key?(documents, "submit_module")
    end

    test "has its destinations in the registry under the organisation's place, valid", ctx do
      collection = collection_fixture(ctx.scope)
      documents = prebuild_documents(ctx, collection)

      target =
        Repo.get_by!(Apiary.Runs.Target,
          workspace_id: ctx.scope.workspace.id,
          system: collection.target_system,
          path: collection.target_path
        )

      place =
        Enum.join(
          [
            Apiary.Registry.service(),
            Apiary.InstanceConfig.registry_instance(),
            Apiary.Registry.Names.organisation(ctx.scope.organisation.id)
          ],
          "/"
        )

      assert documents["image_destination"] ==
               "#{place}/targets/#{Apiary.Registry.Names.target(target.public_id)}"

      assert documents["environment_destination"] =~ ~r"\A#{place}/environments/[0-9a-f]{16}\z"
      refute Map.has_key?(documents, "environment_image")
    end

    test "is sent the organisation's environment image for its key, where a record has one",
         ctx do
      first = prebuild_documents(ctx, collection_fixture(ctx.scope))
      image = first["environment_destination"] <> "@sha256:" <> String.duplicate("5", 64)

      {1, _rows} =
        Repo.update_all(from(r in Apiary.Environments.Record, where: r.pool_id == ^ctx.pool.id),
          set: [
            image: image,
            size: 1_048_576,
            commit: String.duplicate("4e1c9b0a", 5),
            built_at: DateTime.utc_now(),
            reported_ref: "env-1",
            built_ref: "env-1"
          ]
        )

      # Another target of the workspace, built from the same environment on the same pool:
      # the same environment image's name.
      second = prebuild_documents(ctx, collection_fixture(ctx.scope))
      assert second["environment_image"] == image
      refute Map.has_key?(second, "environment_destination")
      refute second["image_destination"] == first["image_destination"]
    end

    test "has largest_prebuilt_image_bytes, the instance's largest prebuilt image in bytes, after its destinations",
         ctx do
      largest_prebuilt_image!(20)

      {:ok, _run} =
        Repo.transact(fn ->
          Dispatches.queue_prebuild(collection_fixture(ctx.scope), ctx.pool, "env-1")
        end)

      claim = claim(ctx)
      documents = documents(claim)

      assert documents["largest_prebuilt_image_bytes"] == 20_000_000_000

      assert claim |> stored() |> members() |> Enum.take(-3) ==
               ~w(environment_destination largest_prebuilt_image_bytes inputs)
    end

    test "has no largest_prebuilt_image_bytes where the instance has no largest prebuilt image",
         ctx do
      largest_prebuilt_image!(nil)
      documents = prebuild_documents(ctx, collection_fixture(ctx.scope))
      refute Map.has_key?(documents, "largest_prebuilt_image_bytes")
      assert is_binary(documents["image_destination"])
    end

    test "makes its target where its workspace has none, for the target image's name", ctx do
      collection = collection_fixture(ctx.scope)

      Repo.delete_all(
        from t in Apiary.Runs.Target,
          where: t.workspace_id == ^ctx.scope.workspace.id,
          where: t.system == ^collection.target_system and t.path == ^collection.target_path
      )

      documents = prebuild_documents(ctx, collection)

      target =
        Repo.get_by!(Apiary.Runs.Target,
          workspace_id: ctx.scope.workspace.id,
          system: collection.target_system,
          path: collection.target_path
        )

      assert String.ends_with?(
               documents["image_destination"],
               "/targets/#{Apiary.Registry.Names.target(target.public_id)}"
             )
    end
  end

  describe "every claim of a run of the step workflow" do
    # The run contract requires `workflow` for every run of the step `workflow`. A run
    # with a workflow, from a stack row, from the process's first stage or from the
    # built-in harness, is claimed with documents valid under the vendored schema. A run
    # with none ends when it is queued (`Apiary.Harnesses.WalkJob.queue/2`), and no claim
    # takes it.
    @tag with_features: Apiary.Features.all() -- [:workflow_model]
    test "has documents with a workflow, valid; a run with no workflow is not claimed",
         _ctx do
      # Each case in the workspace of a new sign-up, with a node pool of that workspace, so
      # each claim takes that case's run.
      fresh = fn ->
        %{scope: scope} = sign_up_fixture()
        scope |> handover_place_fixture() |> Map.put(:scope, scope)
      end

      cases = [
        fn ctx ->
          workflow!(ctx)
          explore!(ctx, origin: :setting, document: section(), target_version: @version)
        end,
        fn ctx ->
          {:ok, _stack} =
            Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, @document)

          explore!(ctx, origin: :setting, document: section(), target_version: @version)
        end,
        fn ctx -> WorkItems.take_in_test(ctx.scope, "Hello! Where are you running?") end
      ]

      for queue <- cases do
        ctx = fresh.()
        queue.(ctx)
        documents = documents(claim(ctx))
        assert %{"step" => "workflow", "workflow" => workflow} = documents
        assert is_binary(workflow)
      end

      # Two stack rows with a workflow: the run has none.
      ctx = fresh.()

      for workflow <- ["triage", "review"] do
        {:ok, _row} =
          Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace, workflow}, nil)
      end

      work_item = work_item_fixture(ctx.scope, %{target_system: "tickets.example.com"})
      {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
      :ok = Apiary.DispatchedRunsFixtures.walks_resolved!()

      claim = signed(ctx, "/v1/pools/claim", %{"version" => 1, "wait_seconds" => 0})
      assert claim.status == 204

      assert %Apiary.Dispatches.DispatchRun{state: :ended, end_cause: :harness_unresolved} =
               Repo.get!(Apiary.Dispatches.DispatchRun, run.id)
    end
  end
end
