defmodule ApiaryWeb.Contract.MachinesAnswerTest do
  # The claim answer's `machine` and the handover answer's `stack` and `workflow`, from the
  # entry of the run's workspace in the machines file (`Apiary.Dispatches.MachinesFile`),
  # as a node pool's starter receives them: absent without a file or an entry, each part
  # of an entry alone, for an explore run, within the handover answer's limit, and for a
  # prebuild and for a run handed a run code, whose handover answers have neither `stack`
  # nor `workflow`; each answer valid under the vendored `claim-answer.schema.json` or
  # `handover-answer.schema.json`, whose `run_settings` refers to Forager's schemas, so the
  # module is tagged `:contract`. Not async: the file read at boot and the features are the
  # whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1]
  import Apiary.DispatchedRunsFixtures, only: [handover_place_fixture: 1]
  import Apiary.NodesFixtures, only: [collection_fixture: 1]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Repo}
  alias Apiary.Dispatches.{Handover, MachinesFile}
  alias Apiary.Sources.Comment
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

  @commit "0123456789abcdef0123456789abcdef01234567"
  @stack %{
    "url" => "https://forge.example.com/acme/stacks",
    "commit" => @commit,
    "path" => "examples/hello"
  }

  setup %{tmp_dir: dir} do
    setting = Application.fetch_env(:apiary, :machines_file_setting)
    file = Application.fetch_env(:apiary, :machines_file)
    limit = Application.fetch_env(:apiary, Handover)

    on_exit(fn ->
      restore(:machines_file_setting, setting)
      restore(:machines_file, file)
      restore(Handover, limit)
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
      contract_version: "3"
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

  # The claim answer, then the handover answer, of the oldest run the pool may take: both
  # 200, signed, each valid under its vendored schema. `handover` is the handover's body
  # beside `version`.
  defp claim_and_hand_over(ctx, handover \\ %{}) do
    claim = signed(ctx, "/v1/pools/claim", %{"version" => 1, "wait_seconds" => 0})
    assert claim.status == 200
    assert signed_answer?(claim)
    dispatch_id = Jason.decode!(claim.resp_body)["dispatch_id"]

    assert signed(ctx, "/v1/dispatches/#{dispatch_id}/dispatched", %{"version" => 1}).status ==
             204

    handover =
      signed(ctx, "/v1/dispatches/#{dispatch_id}/handover", Map.put(handover, "version", 1))

    assert handover.status == 200
    assert signed_answer?(handover)

    for {body, schema} <- [{claim, "claim-answer"}, {handover, "handover-answer"}] do
      assert {:ok, _} =
               body.resp_body
               |> Jason.decode!()
               |> JSV.validate(validator("provisioner/v1/#{schema}.schema.json")),
             schema
    end

    {claim.resp_body, handover.resp_body}
  end

  defp explore!(ctx) do
    work_item = work_item_fixture(ctx.scope)
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

  defp run_settings, do: if(Apiary.Features.on?(:secrets), do: ~w(run_settings), else: [])

  @claim ~w(version revision dispatch_id run_id pool_id lease_until step access target work_item)
  @handover ~w(version revision run_id run_key step domain access target work_item)

  describe "an explore run" do
    test "without a file has neither machine nor stack nor workflow", ctx do
      no_file!()
      explore!(ctx)
      {claim, handover} = claim_and_hand_over(ctx)

      assert members(claim) == @claim
      assert members(handover) == @handover ++ run_settings() ++ ~w(inputs)
    end

    test "of a workspace with a machine and a stack has machine, stack and workflow", ctx do
      machines!(ctx, %{
        ctx.place => %{"machine" => "large", "stack" => @stack, "workflow" => "hello"}
      })

      explore!(ctx)
      {claim, handover} = claim_and_hand_over(ctx)

      assert members(claim) == @claim ++ ~w(machine)
      assert Jason.decode!(claim)["machine"] == "large"

      assert members(handover) == @handover ++ run_settings() ++ ~w(stack workflow inputs)
      answer = Jason.decode!(handover)
      assert {answer["stack"], answer["workflow"]} == {@stack, "hello"}

      stack = Jason.decode!(handover, objects: :ordered_objects)["stack"]
      assert Enum.map(stack.values, &elem(&1, 0)) == ~w(url commit path)
    end

    test "handed a run code has machine, and an answer of five members without stack or workflow",
         ctx do
      machines!(ctx, %{
        ctx.place => %{"machine" => "large", "stack" => @stack, "workflow" => "hello"}
      })

      explore!(ctx)
      {claim, handover} = claim_and_hand_over(ctx, %{"run_code" => true})

      assert members(claim) == @claim ++ ~w(machine)
      assert members(handover) == ~w(version revision run_id run_code step)
    end

    test "of a workspace with a machine alone has machine, and neither stack nor workflow",
         ctx do
      machines!(ctx, %{ctx.place => %{"machine" => "small"}})
      explore!(ctx)
      {claim, handover} = claim_and_hand_over(ctx)

      assert members(claim) == @claim ++ ~w(machine)
      assert Jason.decode!(claim)["machine"] == "small"
      assert members(handover) == @handover ++ run_settings() ++ ~w(inputs)
    end

    test "of a workspace with a stack alone has stack and workflow, and no machine", ctx do
      machines!(ctx, %{ctx.place => %{"stack" => @stack, "workflow" => "hello"}})
      explore!(ctx)
      {claim, handover} = claim_and_hand_over(ctx)

      assert members(claim) == @claim
      assert members(handover) == @handover ++ run_settings() ++ ~w(stack workflow inputs)
      assert Jason.decode!(handover)["stack"] == @stack
    end

    test "of a workspace not in the file has neither machine nor stack nor workflow", ctx do
      other = "#{ctx.scope.organisation.slug}/other-#{System.unique_integer([:positive])}"

      machines!(ctx, %{
        other => %{"machine" => "small", "stack" => @stack, "workflow" => "hello"}
      })

      explore!(ctx)
      {claim, handover} = claim_and_hand_over(ctx)

      assert members(claim) == @claim
      assert members(handover) == @handover ++ run_settings() ++ ~w(inputs)
    end

    # The comments are smaller than the stack, so an answer measured without the stack
    # passes the limit: 450 comments of 500 bytes, of which the input keeps the newest.
    test "keeps the handover answer within its limit with the stack at its caps", ctx do
      url = "https://forge.example.com/" <> String.duplicate("u", 2048 - 26)
      folder = String.duplicate("d/", 127) <> "e"
      stack = %{"url" => url, "commit" => @commit, "path" => folder}
      machines!(ctx, %{ctx.place => %{"stack" => stack, "workflow" => "hello"}})
      Application.put_env(:apiary, Handover, answer_limit: 200_000)

      work_item = explore!(ctx)
      at = DateTime.utc_now(:second)

      for n <- 1..450 do
        Repo.insert!(%Comment{
          organisation_id: work_item.organisation_id,
          item_id: work_item.item_id,
          external_ref: "c#{n}",
          url: "https://forge.example.com/acme/shop/issues/12#c#{n}",
          author_name: "Avery Example",
          author_kind: :person,
          body: String.pad_trailing("#{n} ", 500, "x"),
          body_format: "markdown",
          source_created_at: DateTime.add(at, n, :second),
          source_updated_at: DateTime.add(at, n, :second)
        })
      end

      {_claim, handover} = claim_and_hand_over(ctx)

      assert byte_size(handover) <= 200_000
      answer = Jason.decode!(handover)
      assert answer["stack"] == stack
      comments = answer["inputs"]["comments"]
      assert answer["inputs"]["comments_omitted"] > 0
      assert List.last(comments)["body"] =~ ~r/\A450 /

      # The input is cut no further than it must be: the room the budget keeps for the
      # longest run key, plus one comment and its comma, would pass the limit. The comment
      # left out next is older, so no longer, than the longest comment kept.
      key_room = 2048 - byte_size(answer["run_key"])
      comment = comments |> Enum.map(&byte_size(Jason.encode!(&1))) |> Enum.max()
      assert byte_size(handover) + key_room + comment + 1 > 200_000
    end
  end

  describe "a prebuild" do
    test "of a workspace with a machine and a stack has machine, and neither stack nor workflow",
         ctx do
      machines!(ctx, %{
        ctx.place => %{"machine" => "small", "stack" => @stack, "workflow" => "hello"}
      })

      collection = collection_fixture(ctx.scope)

      {:ok, _run} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

      {claim, handover} = claim_and_hand_over(ctx)

      assert members(claim) ==
               ~w(version revision dispatch_id run_id pool_id lease_until step access target machine)

      assert members(handover) ==
               ~w(version revision run_id run_key step domain access target inputs)

      assert Jason.decode!(claim)["machine"] == "small"
      answer = Jason.decode!(handover)
      assert answer["step"] == "prebuild"

      assert answer["inputs"] == %{"version" => 1, "environment_ref" => "env-1"}
    end
  end
end
