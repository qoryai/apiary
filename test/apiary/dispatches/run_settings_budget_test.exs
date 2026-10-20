defmodule Apiary.Dispatches.RunSettingsBudgetTest do
  # The handover answer's limit of 1 MiB with run settings (`Apiary.Dispatches.Handover`):
  # the input gets what the rest of the answer leaves and leaves out its oldest comments
  # first, and a handover whose answer cannot fit is refused with nothing written. Then an
  # explore run's answer with the feature `secrets` off. Not async: the tests set the
  # answer's limit and the features in the application environment.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, ModelChoices, Repo}
  alias Apiary.Connections.ProviderModel
  alias Apiary.Dispatches.{DispatchRun, Handover}
  alias Apiary.Runs.Run
  alias Apiary.Sources.Comment
  alias ApiaryWeb.Contract.DispatchAnswer

  @moduletag needs: :factory

  @body ~s({"version":1,"time":"2026-10-18T12:00:00Z"})
  @limit 1_048_576
  @efforts ~w(low medium high xhigh max)

  setup do
    %{scope: scope} = sign_up_fixture()
    Map.put(handover_place_fixture(scope, allow_secrets: true), :scope, scope)
  end

  # The anthropic provider with 200 models, the most a provider has, each id 200
  # characters, the most a model id has, each with every effort value of the runtime;
  # chosen for the workspace with an effort and the three tiers.
  defp provider_at_its_caps!(scope) do
    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: "sk-ant-budget-0123456789"}]
      })

    now = DateTime.utc_now()
    ids = for n <- 1..196, do: String.pad_trailing("team-#{n}-", 200, "x")

    Repo.insert_all(
      ProviderModel,
      for {id, n} <- Enum.with_index(ids, 4) do
        %{
          id: Ecto.UUID.generate(),
          organisation_id: provider.organisation_id,
          connection_id: provider.id,
          model_id: id,
          title: "Team #{n}",
          effort: @efforts,
          position: n,
          is_default: false,
          inserted_at: now,
          updated_at: now
        }
      end
    )

    [light, fast, thinking | _rest] = ids

    {:ok, _choice} =
      ModelChoices.put_choice(scope, :workspace, %{
        provider: provider.public_id,
        model: List.last(ids),
        effort: "max",
        tiers: %{
          "light" => %{"model" => light, "effort" => "low"},
          "fast" => %{"model" => fast, "effort" => "medium"},
          "thinking" => %{"model" => thinking, "effort" => "xhigh"}
        }
      })

    provider
  end

  # A work item with 20 comments of 60,000 characters each, its run queued, claimed and
  # said started: the inputs alone pass 768 KiB.
  defp claimed!(ctx) do
    work_item = work_item_fixture(ctx.scope)
    at = DateTime.utc_now(:second)
    text = String.duplicate("x", 60_000)

    for n <- 1..20 do
      Repo.insert!(%Comment{
        organisation_id: work_item.organisation_id,
        item_id: work_item.item_id,
        external_ref: "c#{n}",
        url: "https://forge.example.com/acme/shop/issues/12#c#{n}",
        author_name: "Avery Example",
        author_kind: :person,
        body: "#{n} " <> text,
        body_format: "markdown",
        source_created_at: DateTime.add(at, n, :second),
        source_updated_at: DateTime.add(at, n, :second)
      })
    end

    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    %{dispatch: dispatch} = dispatched!(ctx.key)
    {queued, dispatch}
  end

  # The answer as the controller encodes it (`ApiaryWeb.Contract.HandoverController`).
  defp answer(handed) do
    DispatchAnswer.handover_body(%{
      revision: 3,
      run_id: handed.run.node_run_id,
      run_key: handed.run_key,
      step: handed.dispatch_run.step,
      domain: handed.domain,
      target: handed.target,
      work_item: handed.work_item,
      run_settings: handed.run_settings,
      inputs: handed.inputs
    })
  end

  defp omitted(handed), do: Jason.decode!(Jason.encode!(handed.inputs))["comments_omitted"]

  defp put_limit(bytes) do
    previous = Application.get_env(:apiary, Handover)
    Application.put_env(:apiary, Handover, answer_limit: bytes)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:apiary, Handover, previous),
        else: Application.delete_env(:apiary, Handover)
    end)
  end

  describe "the answer's limit" do
    test "holds the run settings at their caps and the input at its limit within 1 MiB", ctx do
      provider_at_its_caps!(ctx.scope)
      {_queued, dispatch} = claimed!(ctx)

      assert {:ok, handed} = Dispatches.handover(ctx.key, dispatch.public_id, %{body: @body})

      settings = Jason.encode!(handed.run_settings)
      assert byte_size(settings) > 50_000
      assert length(Jason.decode!(settings)["provider_models"]) == 200
      assert omitted(handed) > 0
      assert byte_size(answer(handed)) <= @limit
    end

    test "leaves out more of the oldest comments when the rest of the answer takes more",
         ctx do
      provider_at_its_caps!(ctx.scope)
      {_queued, dispatch} = claimed!(ctx)
      put_limit(500_000)

      assert {:ok, handed} = Dispatches.handover(ctx.key, dispatch.public_id, %{body: @body})

      body = answer(handed)
      assert byte_size(body) <= 500_000
      inputs = Jason.decode!(body)["inputs"]
      assert inputs["comments_omitted"] + length(inputs["comments"]) == 20
      assert List.last(inputs["comments"])["body"] =~ ~r/\A20 /

      # One comment more would not fit.
      one_more = byte_size(Jason.encode!(%{"body" => String.duplicate("x", 60_000)}))
      assert byte_size(body) + one_more > 500_000
    end

    @tag :capture_log
    test "refuses the handover, with nothing written, when the rest of the answer passes the limit",
         ctx do
      provider_at_its_caps!(ctx.scope)
      {queued, dispatch} = claimed!(ctx)
      put_limit(40_000)

      assert Dispatches.handover(ctx.key, dispatch.public_id, %{body: @body}) ==
               {:error, :unavailable}

      assert %DispatchRun{state: :claimed, end_cause: nil} = Repo.get!(DispatchRun, queued.id)
      assert Repo.aggregate(from(r in Run, where: r.dispatch_run_id == ^queued.id), :count) == 0
    end
  end

  describe "with the feature secrets off" do
    @tag with_features: [:observability, :security, :factory]
    test "the answer has no run settings, and the run keeps none, whatever the gateway's keys",
         ctx do
      off = Application.get_env(:apiary, :features)

      # The provider and the choice are made with every feature on, as on an instance that
      # turned `secrets` off later.
      Application.put_env(:apiary, :features, Apiary.Features.all())

      {:ok, provider} =
        Connections.create_provider(ctx.scope, %{
          provider: "anthropic",
          keys: [%{value_id: "main", value: "sk-ant-off-0123456789"}]
        })

      {:ok, _choice} =
        ModelChoices.put_choice(ctx.scope, :workspace, %{provider: provider.public_id})

      Application.put_env(:apiary, :features, off)

      # A second key of the gateway, without the stored-secrets flag: no credential is
      # written with `secrets` off, so the run does not end `secrets_not_allowed`.
      Apiary.AccessKeysFixtures.node_key_fixture(ctx.scope, ctx.gateway)

      work_item = work_item_fixture(ctx.scope)
      {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
      %{dispatch: dispatch} = dispatched!(ctx.key)

      assert {:ok, handed} = Dispatches.handover(ctx.key, dispatch.public_id, %{body: @body})
      assert handed.run_settings == nil
      refute answer(handed) =~ "run_settings"

      assert %Run{run_settings: nil, provider_connection_id: nil, provider_api: nil} =
               Repo.get!(Run, handed.run.id)
    end
  end
end
