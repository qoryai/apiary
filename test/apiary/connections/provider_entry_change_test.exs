defmodule Apiary.Connections.ProviderEntryChangeTest do
  # A model provider follows the catalogue entry of the running release
  # (`Apiary.Connections.provider/1`): one added from an entry with another digest is
  # read, edited and given to runs with the release's entry, its models and its limit
  # windows; only one whose saved settings no longer fit the entry is refused. Its
  # recorded digest stays as it was, and its row passes its integrity code.
  use Apiary.DataCase, async: true

  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, ModelChoices, Repo}
  alias Apiary.Connections.Connection
  alias Apiary.Kinds.{Coded, Providers}
  alias Apiary.Runs.{ProviderCredential, Run}

  @moduletag needs: [:factory, :secrets]

  @body ~s({"version":1,"time":"2026-10-18T12:00:00Z"})
  @old_sha256 String.duplicate("0", 64)
  @old_ref String.duplicate("1", 40)

  setup do
    %{scope: scope} = sign_up_fixture()

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "claude-subscription",
        keys: [%{value_id: "main", value: "sk-ant-oat01-entry-main-0123456789"}]
      })

    scope
    |> handover_place_fixture(allow_secrets: true)
    |> Map.merge(%{scope: scope, provider: provider})
  end

  # The provider's row with `changes`, written past the save's checks, and coded again as
  # a save codes it, so the row still passes its integrity code.
  defp recode!(%Connection{id: id}, changes) do
    Connection
    |> Repo.get!(id)
    |> Ecto.Changeset.change(changes)
    |> Coded.seal()
    |> Repo.update!()
  end

  # The provider as an earlier release added it, from an entry with another digest.
  defp from_old_entry!(provider),
    do: recode!(provider, description_sha256: @old_sha256, description_ref: @old_ref)

  defp handover!(ctx) do
    work_item = work_item_fixture(ctx.scope, %{})
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    walked_claim(ctx.key, Dispatches.now(), @body)
  end

  describe "a provider added from another entry" do
    test "is read with the release's entry, its models and its windows", ctx do
      provider = from_old_entry!(ctx.provider)
      {:ok, entry} = Providers.fetch("claude-subscription")
      assert entry.sha256 != @old_sha256

      assert Connections.intact?(provider)
      assert {:ok, ^entry} = Connections.provider(provider)
      assert Connections.provider_models(provider) == entry.models
      assert Connections.provider_models(provider) != []

      assert {:ok, %Connection{intact: true} = read} =
               Connections.get_provider(ctx.scope, provider.public_id)

      assert read.description_sha256 == @old_sha256
    end

    test "is edited, and keeps its recorded digest", ctx do
      provider = from_old_entry!(ctx.provider)

      assert {:ok, %Connection{name: "Team subscription"} = edited} =
               Connections.update_provider(ctx.scope, provider, %{name: "Team subscription"})

      assert %Connection{description_sha256: @old_sha256, description_ref: @old_ref} =
               reread = Repo.get!(Connection, edited.id)

      assert Connections.intact?(reread)
    end

    test "gives a run its run configuration, with the release's limit windows", ctx do
      pid = from_old_entry!(ctx.provider).public_id
      {:ok, _choice} = ModelChoices.put_choice(ctx.scope, :workspace, %{provider: pid})

      assert {:ok, %{registered: run}} = handover!(ctx)
      run = Repo.get!(Run, run.id)
      assert run.provider_api["use_up_to_windows"] == ~w(five_hour seven_day)

      assert {:ok, %{keys: [%{name: name}]} = credential} = ProviderCredential.for_run(run)
      assert name == "#{pid}-1"
      assert credential.hosts != []
    end
  end

  describe "a provider whose saved settings no longer fit the entry" do
    test "is refused when read, edited and given to a run", ctx do
      pid = ctx.provider.public_id
      {:ok, _choice} = ModelChoices.put_choice(ctx.scope, :workspace, %{provider: pid})
      assert {:ok, %{registered: run}} = handover!(ctx)
      run = Repo.get!(Run, run.id)

      provider = recode!(ctx.provider, settings: ~s({"region":"eu"}))

      assert Connections.intact?(provider)
      assert Connections.provider(provider) == {:error, :provider_changed}
      assert Connections.provider_models(provider) == []

      assert Connections.update_provider(ctx.scope, provider, %{name: "Other"}) ==
               {:error, :provider_changed}

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert ProviderCredential.for_run(run) == {:error, :unavailable}
             end) =~ "provider_changed"
    end
  end
end
