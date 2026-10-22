defmodule Apiary.Dispatches.RunSettingsBudgetTest do
  # The limit of 1 MiB on the 201 to a run code's redemption, with run settings
  # (`Apiary.Dispatches.Handover`): the documents get what the rest of the 201 leaves, the
  # input gets what the rest of the documents leave and leaves out its oldest comments
  # first, the 201 carries the documents the claim stored, byte for byte, and a claim
  # whose documents cannot fit is refused with nothing written. Then an explore run's
  # documents with the feature `secrets` off. Not async: the tests set the limit and the
  # features in the application environment.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, ModelChoices, Repo}
  alias Apiary.Connections.ProviderModel
  alias Apiary.Dispatches.{DispatchRun, Handover}
  alias Apiary.Runs.{Run, RunCode}
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

  # A work item with 20 comments of 60,000 characters each, its run queued: the inputs
  # alone pass 768 KiB.
  defp queued!(ctx) do
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
    queued
  end

  # What the run's documents are made from, at a claim that registered the run, with the
  # registered run as `run` and its code as `run_code`.
  defp claimed!(ctx) do
    {:ok, %{registered: run, documents: documents, run_code: code}} =
      Dispatches.claim(ctx.key, Dispatches.now(), @body)

    documents |> Map.put(:run, run) |> Map.put(:run_code, code)
  end

  # The run's documents, encoded.
  defp answer(handed), do: handed |> DispatchAnswer.documents() |> Jason.encode!()

  # The 201 to the redemption of the run's code, as the enrolment endpoint writes it.
  defp redeemed_201(handed) do
    pair = Apiary.AccessKeysFixtures.ed25519_key_pair()
    request = run_code_request(handed.run_code, pair, DateTime.utc_now())
    {:ok, redeemed} = RunCode.redeem(request, relayed_by: bound_gateway(handed.run_code))

    Apiary.Contract.Enrolment.run_answer_body(%{
      run_id: redeemed.run_id,
      run_key: redeemed.run_key,
      documents: redeemed.documents,
      apiary_public_key: Apiary.SigningKey.apiary_public_key()
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

  describe "the 201's limit" do
    test "holds the run settings at their caps and the input at its limit within 1 MiB", ctx do
      provider_at_its_caps!(ctx.scope)
      queued!(ctx)
      handed = claimed!(ctx)

      settings = Jason.encode!(handed.run_settings)
      assert byte_size(settings) > 50_000
      assert length(Jason.decode!(settings)["provider_models"]) == 200
      assert omitted(handed) > 0

      # The 201 carries the documents the claim stored, and fits 1 MiB with the margin
      # left for a second server key.
      stored = Repo.get!(Run, handed.run.id).run_documents
      assert stored == answer(handed)
      body = redeemed_201(handed)
      assert Jason.decode!(body)["documents"] == Jason.decode!(stored)
      assert byte_size(body) <= @limit - 1_024
    end

    test "leaves out more of the oldest comments when the rest of the 201 takes more", ctx do
      provider_at_its_caps!(ctx.scope)
      queued!(ctx)
      put_limit(500_000)
      handed = claimed!(ctx)

      body = redeemed_201(handed)
      assert byte_size(body) <= 500_000 - 1_024
      inputs = Jason.decode!(body)["documents"]["inputs"]
      assert inputs["comments_omitted"] + length(inputs["comments"]) == 20
      assert List.last(inputs["comments"])["body"] =~ ~r/\A20 /

      # One comment more would not fit.
      one_more = byte_size(Jason.encode!(%{"body" => String.duplicate("x", 60_000)}))
      assert byte_size(body) + one_more > 500_000 - 1_024
    end

    @tag :capture_log
    test "refuses the claim, with nothing written, when the rest of the documents passes the limit",
         ctx do
      provider_at_its_caps!(ctx.scope)
      queued = queued!(ctx)
      put_limit(40_000)

      assert Dispatches.claim(ctx.key, Dispatches.now(), @body) == {:error, :unavailable}

      assert %DispatchRun{state: :waiting, end_cause: nil} = Repo.get!(DispatchRun, queued.id)
      assert Repo.aggregate(from(r in Run, where: r.dispatch_run_id == ^queued.id), :count) == 0
      assert Repo.aggregate(Apiary.Dispatches.Dispatch, :count) == 0
    end
  end

  describe "with the feature secrets off" do
    @tag with_features: [:observability, :security, :factory]
    test "the documents have no run settings, and the run keeps none, whatever the gateway's keys",
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

      handed = claimed!(ctx)
      assert handed.run_settings == nil
      refute answer(handed) =~ "run_settings"

      assert %Run{run_settings: nil, provider_connection_id: nil, provider_api: nil} =
               Repo.get!(Run, handed.run.id)
    end
  end
end
