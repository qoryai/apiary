defmodule Apiary.Dispatches.UseUpToClaimTest do
  # A claim of an explore run whose model provider has limit windows
  # (`Apiary.Dispatches.RunSettings`): each key keeps its Use up to percentage, and a key
  # whose window is at that percentage goes after the free keys, with the window's reset
  # as its `cooldown_until`; the run keeps the provider's limit windows once, in
  # `provider_api`, from the catalogue entry at the claim.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.DispatchedRunsFixtures
  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, ModelChoices, ModelKeys, Repo}
  alias Apiary.Runs.{ProviderCredential, Run}
  alias Apiary.Secrets.Value

  @moduletag needs: [:factory, :secrets]

  @body ~s({"version":1,"time":"2026-10-18T12:00:00Z"})

  setup do
    %{scope: scope} = sign_up_fixture()

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "claude-subscription",
        keys: [
          %{value_id: "main", value: "sk-ant-oat01-claim-main-0123456789"},
          %{value_id: "spare", value: "sk-ant-oat01-claim-spare-0123456789"}
        ]
      })

    scope
    |> handover_place_fixture(allow_secrets: true)
    |> Map.merge(%{scope: scope, provider: provider})
  end

  defp handover!(ctx) do
    work_item = work_item_fixture(ctx.scope, %{})
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

    {:ok, %{registered: run}} =
      Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now(), @body)

    Repo.get!(Run, run.id)
  end

  defp value!(provider, value_id) do
    Repo.one!(
      from v in Value, where: v.secret_id == ^provider.secret_id and v.value_id == ^value_id
    )
  end

  defp state!(value, attrs) do
    ModelKeys.record(
      [
        %{
          name: "k",
          secret_value_id: value.id,
          organisation_id: value.organisation_id,
          copy_set_at: value.value_set_at,
          copy_kept: true
        }
      ],
      [
        Map.merge(
          %{
            credential: "k",
            window: "five_hour",
            status: "allowed",
            resets_at: nil,
            utilization: nil,
            cooldown_until: nil,
            source: "provider",
            observed_at: DateTime.utc_now()
          },
          Map.new(attrs)
        )
      ],
      DateTime.utc_now()
    )
  end

  test "keeps each key's percentage, and a key at it in cooldown until the window resets",
       ctx do
    pid = ctx.provider.public_id
    {:ok, _choice} = ModelChoices.put_choice(ctx.scope, :workspace, %{provider: pid})
    main = value!(ctx.provider, "main")
    spare = value!(ctx.provider, "spare")
    reset = in_seconds(3600)

    {:ok, _} = put_key_setting(ctx.scope, main, %{"use_up_to_percent" => 90})
    {:ok, _} = put_key_setting(ctx.scope, spare, %{"use_up_to_percent" => 80})
    state!(main, utilization: 91, resets_at: reset)
    state!(spare, utilization: 79, resets_at: in_seconds(1800))

    run = handover!(ctx)
    time = DateTime.to_iso8601(reset)

    assert [
             %{"id" => spare_id, "start" => true, "use_up_to_percent" => 80} = first,
             %{
               "id" => main_id,
               "use_up_to_percent" => 90,
               "cooldown_until" => ^time,
               "resets_at" => ^time
             }
           ] = run.model_keys

    assert {spare_id, main_id} == {spare.id, main.id}
    refute Map.has_key?(first, "cooldown_until")
    refute Enum.any?(run.model_keys, &Map.has_key?(&1, "use_up_to_windows"))
    assert run.provider_api["use_up_to_windows"] == ~w(five_hour seven_day)

    assert {:ok, %{keys: keys}} = ProviderCredential.for_run(run)
    entries = Enum.map(keys, &Jason.decode!(Jason.encode!(&1.entry)))

    assert Enum.map(entries, & &1["use_up_to_windows"]) == [
             ~w(five_hour seven_day),
             ~w(five_hour seven_day)
           ]

    assert Enum.map(entries, & &1["use_up_to_percent"]) == [80, 90]
  end
end
