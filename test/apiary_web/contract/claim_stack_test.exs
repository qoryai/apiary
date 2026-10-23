defmodule ApiaryWeb.Contract.ClaimStackTest do
  # The claim answer as a node pool's starter receives it, with no `machine`, and the
  # run's documents: for an explore run, the workflow of the one stack row with a
  # workflow at the run's places, the stack that resolves (`Apiary.Stacks`) and
  # `harness_hidden`; none of the three with no such row, with two, and for a prebuild.
  # Each answer is valid under the vendored `claim-answer.schema.json`, so the module is
  # tagged `:contract`. Not async: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1]
  import Apiary.DispatchedRunsFixtures, only: [handover_place_fixture: 1]
  import Apiary.NodesFixtures, only: [collection_fixture: 1]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Repo, Stacks}
  alias Apiary.Runs.Target
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

  @stack "core"
  @reference "https://code.example.com/team/stacks#main:core"

  setup do
    Process.put(:now_time, {SignedRequest.now(), 0})
    %{scope: scope} = sign_up_fixture()

    scope
    |> handover_place_fixture()
    |> Map.put(:scope, scope)
  end

  # Stores the workspace's stack row for the workflow `hello`, with `stack`.
  defp workflow!(ctx, stack \\ @stack) do
    {:ok, _stack} = Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace, "hello"}, stack)
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

  # The documents the claim stored on the run it registered, decoded.
  defp documents(claim) do
    code = Jason.decode!(claim)["run_code"]
    [head, _fingerprint] = String.split(code, ".")
    hash = Apiary.AccessKeys.EnrolmentCode.hash(head)
    run = Repo.get_by!(Apiary.Runs.Run, run_code_sha256: hash)
    Jason.decode!(run.run_documents)
  end

  # The target row of the work items `explore!/1` queues: tickets.example.com, acme/shop.
  defp target!(ctx) do
    Repo.insert!(%Target{
      organisation_id: ctx.scope.organisation.id,
      workspace_id: ctx.scope.workspace.id,
      system: "tickets.example.com",
      path: "acme/shop",
      first_seen_at: DateTime.utc_now()
    })
  end

  defp explore!(ctx) do
    work_item = work_item_fixture(ctx.scope, %{target_system: "tickets.example.com"})
    {:ok, _run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    work_item
  end

  # The members of a JSON object, in their order.
  defp members(json),
    do:
      json
      |> Jason.decode!(objects: :ordered_objects)
      |> Map.get(:values)
      |> Enum.map(&elem(&1, 0))

  @claim ~w(version revision dispatch_id pool_id lease_until)
  @code ~w(run_code gateway_url max_lifetime_minutes)

  describe "an explore run" do
    test "with one stack row with a workflow has that workflow and its stack, and no machine",
         ctx do
      workflow!(ctx)
      explore!(ctx)
      claim = claim(ctx)
      assert members(claim) == @claim ++ @code
      documents = documents(claim)
      assert %{"stack" => "core", "workflow" => "hello", "harness_hidden" => false} = documents
      assert {:ok, _} = JSV.validate(documents, validator("run/v1/documents.schema.json"))
    end

    test "has the reference its target's level sets, shown to the organisation that saved it",
         ctx do
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:target, target!(ctx), "hello"}, @reference)

      explore!(ctx)
      documents = documents(claim(ctx))

      assert %{"stack" => @reference, "workflow" => "hello", "harness_hidden" => false} =
               documents

      assert {:ok, _} = JSV.validate(documents, validator("run/v1/documents.schema.json"))
    end

    test "hides the harness of a reference another organisation saved", ctx do
      %{scope: other} = sign_up_fixture()

      {:ok, _stack} =
        Stacks.put_stack(other, {:workspace, ctx.scope.workspace, "hello"}, @reference)

      explore!(ctx)
      documents = documents(claim(ctx))

      assert %{"stack" => @reference, "workflow" => "hello", "harness_hidden" => true} =
               documents

      assert {:ok, _} = JSV.validate(documents, validator("run/v1/documents.schema.json"))
    end

    test "with no stack row with a workflow has no stack, whatever its levels set, and no machine",
         ctx do
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, @reference)
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:organisation, ctx.scope.organisation}, "x")

      explore!(ctx)
      claim = claim(ctx)
      assert members(claim) == @claim ++ @code
      documents = documents(claim)
      refute Enum.any?(~w(stack workflow harness_hidden), &Map.has_key?(documents, &1))
      assert {:ok, _} = JSV.validate(documents, validator("run/v1/documents.schema.json"))
    end

    test "with two stack rows with a workflow has no stack", ctx do
      workflow!(ctx)
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:target, target!(ctx), "review"}, @stack)

      explore!(ctx)
      claim = claim(ctx)
      assert members(claim) == @claim ++ @code
      documents = documents(claim)
      refute Enum.any?(~w(stack workflow harness_hidden), &Map.has_key?(documents, &1))
    end
  end

  describe "a prebuild" do
    test "of a workspace with a stack row with a workflow has no machine and no stack", ctx do
      workflow!(ctx, @reference)
      collection = collection_fixture(ctx.scope)

      {:ok, _run} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

      claim = claim(ctx)
      assert members(claim) == @claim ++ @code
      documents = documents(claim)
      refute Enum.any?(~w(stack workflow harness_hidden), &Map.has_key?(documents, &1))
      assert documents["inputs"] == %{"version" => 1, "environment_ref" => "env-1"}
    end
  end
end
