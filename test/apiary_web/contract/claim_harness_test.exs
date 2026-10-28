defmodule ApiaryWeb.Contract.ClaimHarnessTest do
  # The claim answer as a node pool's starter receives it, with no `machine`, and the
  # harness members of the run's documents, from the run's harness walk
  # (`Apiary.Harnesses.WalkJob`): `target_version`, `workflow`, `harness_hidden` and,
  # for a walk whose document came from the stacks or is a test work item's built-in
  # one, `harness`. None of the four for a run with no workflow and for a prebuild. The run's `access` is the level its walk
  # resolved, and `read` for a run with no workflow and for a prebuild. Each answer and
  # each documents object is valid under the vendored schemas, so the module is tagged
  # `:contract`. Not async: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1]
  import Apiary.DispatchedRunsFixtures, only: [handover_place_fixture: 1, walk_resolved!: 2]
  import Apiary.NodesFixtures, only: [collection_fixture: 1]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Repo, Stacks, WorkItems}
  alias Apiary.Harnesses.{Builtin, Reader}
  alias Apiary.Policy.ComposedConfiguration
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

  # Stores the workspace's stack row for the workflow `hello`, with `harness`: the run's
  # one row with a workflow, so the run's walk is queued.
  defp workflow!(ctx, harness \\ @document) do
    {:ok, _stack} =
      Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace, "hello"}, harness)
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

  defp documents(claim), do: claim |> stored() |> Jason.decode!()

  # A work item's explore run, queued, its harness walk resolved with `walk`.
  defp explore!(ctx, walk, attrs \\ %{}) do
    work_item =
      work_item_fixture(ctx.scope, Map.merge(%{target_system: "tickets.example.com"}, attrs))

    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    walk_resolved!(run, walk)
    work_item
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
    test "whose target's harness file applies has its version and no harness", ctx do
      workflow!(ctx)
      explore!(ctx, origin: :file, target_version: @version)
      claim = claim(ctx)
      assert members(claim) == @claim ++ @code
      documents = documents(claim)

      assert Map.take(documents, @harness) == %{
               "target_version" => @version,
               "workflow" => "hello",
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
               "workflow" => "hello",
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
        target_system: nil,
        target_path: nil
      })

      documents = documents(claim(ctx))

      assert Map.take(documents, @harness) == %{
               "workflow" => "hello",
               "harness_hidden" => false,
               "harness" => %{"harness" => section()}
             }

      valid!(documents)
    end

    test "with a hidden harness has harness_hidden true", ctx do
      %{scope: other} = sign_up_fixture()

      {:ok, _stack} =
        Stacks.put_stack(other, {:workspace, ctx.scope.workspace, "hello"}, @document)

      explore!(ctx, origin: :setting, document: section(), harness_hidden: true)
      documents = documents(claim(ctx))
      assert %{"workflow" => "hello", "harness_hidden" => true} = documents
      valid!(documents)
    end

    test "with no workflow has none of the harness members, and no machine", ctx do
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, @document)

      explore!(ctx, [])
      claim = claim(ctx)
      assert members(claim) == @claim ++ @code
      documents = documents(claim)
      assert Map.take(documents, @harness) == %{}
      assert documents["access"] == "read"
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
      assert %{"access" => "write", "workflow" => "hello"} = documents
      valid!(documents)
    end

    test "is read where the walk resolved read", ctx do
      workflow!(ctx)
      explore!(ctx, origin: :setting, document: section(), target_version: @version)
      documents = documents(claim(ctx))
      assert %{"access" => "read", "workflow" => "hello"} = documents
      valid!(documents)
    end
  end

  describe "a test work item's explore run" do
    # The run the claim registered.
    defp registered(claim) do
      code = Jason.decode!(claim)["run_code"]
      [head, _fingerprint] = String.split(code, ".")
      Repo.get_by!(Apiary.Runs.Run, run_code_sha256: Apiary.AccessKeys.EnrolmentCode.hash(head))
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

        assert Map.take(documents, @harness) == %{
                 "workflow" => "hello",
                 "harness_hidden" => false,
                 "harness" => %{"harness" => Builtin.document()}
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
    test "of a workspace with a stack row with a workflow has no harness members", ctx do
      workflow!(ctx)
      collection = collection_fixture(ctx.scope)

      {:ok, _run} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

      claim = claim(ctx)
      assert members(claim) == @claim ++ @code
      documents = documents(claim)
      assert Map.take(documents, @harness) == %{}
      assert documents["access"] == "read"
      assert documents["inputs"] == %{"version" => 1, "environment_ref" => "env-1"}
    end
  end
end
