defmodule ApiaryWeb.Contract.MachinesAnswerTest do
  # The claim answer's `machine`, from the entry of the run's workspace in the machines
  # file (`Apiary.Dispatches.MachinesFile`), as a node pool's starter receives it: absent
  # without a file or an entry or with an entry of a stack alone, present for an explore
  # run and a prebuild alike; each answer valid under the vendored
  # `claim-answer.schema.json`, so the module is tagged `:contract`. The run's documents
  # have the entry's workflow, the stack that resolves (`Apiary.Stacks`) and
  # `harness_hidden` for an explore run, and none of the three for a prebuild. Not async:
  # the file read at boot and the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1]
  import Apiary.DispatchedRunsFixtures, only: [handover_place_fixture: 1]
  import Apiary.NodesFixtures, only: [collection_fixture: 1]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Repo, Stacks}
  alias Apiary.Dispatches.MachinesFile
  alias Apiary.Runs.Target
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory
  @moduletag :tmp_dir
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

  setup %{tmp_dir: dir} do
    setting = Application.fetch_env(:apiary, :machines_file_setting)
    file = Application.fetch_env(:apiary, :machines_file)

    on_exit(fn ->
      restore(:machines_file_setting, setting)
      restore(:machines_file, file)
    end)

    Process.put(:now_time, {SignedRequest.now(), 0})
    %{scope: scope} = sign_up_fixture()

    scope
    |> handover_place_fixture()
    |> Map.merge(%{
      scope: scope,
      dir: dir,
      place: "#{scope.organisation.slug}/#{scope.workspace.slug}"
    })
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:apiary, key, value)
  defp restore(key, :error), do: Application.delete_env(:apiary, key)

  # Boots with a machines file of `workspaces`, its machine types small and large.
  defp machines!(ctx, workspaces) do
    path = Path.join(ctx.dir, "machines.json")
    File.write!(path, Jason.encode!(%{"machines" => ~w(small large), "workspaces" => workspaces}))
    Application.put_env(:apiary, :machines_file_setting, path)
    MachinesFile.boot!()
  end

  defp no_file! do
    Application.put_env(:apiary, :machines_file_setting, nil)
    nil = MachinesFile.boot!()
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
    test "without a file has no machine", ctx do
      no_file!()
      explore!(ctx)
      assert members(claim(ctx)) == @claim ++ @code
    end

    test "of a workspace with a machine and a stack has the machine", ctx do
      machines!(ctx, %{
        ctx.place => %{"machine" => "large", "stack" => @stack, "workflow" => "hello"}
      })

      explore!(ctx)
      claim = claim(ctx)
      assert members(claim) == @claim ++ ~w(machine) ++ @code
      assert Jason.decode!(claim)["machine"] == "large"
      documents = documents(claim)
      assert %{"stack" => "core", "workflow" => "hello", "harness_hidden" => false} = documents
      assert {:ok, _} = JSV.validate(documents, validator("run/v1/documents.schema.json"))
    end

    test "has the reference its target's level sets, shown to the organisation that saved it",
         ctx do
      machines!(ctx, %{ctx.place => %{"stack" => @stack, "workflow" => "hello"}})
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:target, target!(ctx), "hello"}, @reference)

      explore!(ctx)
      documents = documents(claim(ctx))

      assert %{"stack" => @reference, "workflow" => "hello", "harness_hidden" => false} =
               documents

      assert {:ok, _} = JSV.validate(documents, validator("run/v1/documents.schema.json"))
    end

    test "hides the harness of a reference another organisation saved", ctx do
      machines!(ctx, %{ctx.place => %{"stack" => @stack, "workflow" => "hello"}})
      %{scope: other} = sign_up_fixture()
      {:ok, _stack} = Stacks.put_stack(other, {:workspace, ctx.scope.workspace}, @reference)

      explore!(ctx)
      documents = documents(claim(ctx))

      assert %{"stack" => @reference, "workflow" => "hello", "harness_hidden" => true} =
               documents

      assert {:ok, _} = JSV.validate(documents, validator("run/v1/documents.schema.json"))
    end

    test "of a workspace with a machine alone has the machine", ctx do
      machines!(ctx, %{ctx.place => %{"machine" => "small"}})
      explore!(ctx)
      claim = claim(ctx)
      assert members(claim) == @claim ++ ~w(machine) ++ @code
      assert Jason.decode!(claim)["machine"] == "small"
      documents = documents(claim)
      refute Enum.any?(~w(stack workflow harness_hidden), &Map.has_key?(documents, &1))
      assert {:ok, _} = JSV.validate(documents, validator("run/v1/documents.schema.json"))
    end

    test "of a workspace with no workflow in the file has no stack, whatever its levels set",
         ctx do
      machines!(ctx, %{ctx.place => %{"machine" => "small"}})
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, @reference)

      explore!(ctx)
      documents = documents(claim(ctx))
      refute Enum.any?(~w(stack workflow harness_hidden), &Map.has_key?(documents, &1))
    end

    test "of a workspace with a stack alone has no machine", ctx do
      machines!(ctx, %{ctx.place => %{"stack" => @stack, "workflow" => "hello"}})
      explore!(ctx)
      assert members(claim(ctx)) == @claim ++ @code
    end

    test "of a workspace not in the file has no machine", ctx do
      other = "#{ctx.scope.organisation.slug}/other-#{System.unique_integer([:positive])}"

      machines!(ctx, %{
        other => %{"machine" => "small", "stack" => @stack, "workflow" => "hello"}
      })

      explore!(ctx)
      assert members(claim(ctx)) == @claim ++ @code
    end
  end

  describe "a prebuild" do
    test "of a workspace with a machine and a stack has the machine and no stack", ctx do
      machines!(ctx, %{
        ctx.place => %{"machine" => "small", "stack" => @stack, "workflow" => "hello"}
      })

      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, @reference)
      collection = collection_fixture(ctx.scope)

      {:ok, _run} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

      claim = claim(ctx)
      assert members(claim) == @claim ++ ~w(machine) ++ @code
      assert Jason.decode!(claim)["machine"] == "small"
      documents = documents(claim)
      refute Enum.any?(~w(stack workflow harness_hidden), &Map.has_key?(documents, &1))
      assert documents["inputs"] == %{"version" => 1, "environment_ref" => "env-1"}
    end
  end
end
