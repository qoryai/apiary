defmodule Apiary.WorkItems.TakeInModelChoiceTest do
  # The model choice a person sends with a take in, level 1 (`Apiary.WorkItems.take_in/3`
  # and `take_in_again/3`, `model_choice`): what is stored with the take in, what is
  # refused and then stores nothing, and the rule that a workspace lock holds against it.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, ModelChoices, Policy, WorkItems}
  alias Apiary.Adapters.Collection
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.ModelChoices.{Resolution, TakeInChoice}
  alias Apiary.Runs.Target
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  @model "claude-sonnet-5-5"

  setup do
    %{scope: scope} = sign_up_fixture()
    connection = ticket_connection_fixture(scope)
    ticket = backlog_ticket_fixture(scope, connection: connection)

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [
          %{value_id: "main", value: "sk-take-in-1"},
          %{value_id: "spare", value: "sk-take-in-2"}
        ]
      })

    %{scope: scope, connection: connection, ticket: ticket, provider: provider}
  end

  defp choice(provider, more \\ %{}),
    do:
      Map.merge(
        %{provider: provider.public_id, key: "spare", model: @model, effort: "high"},
        more
      )

  defp take_in(ctx, choice),
    do: WorkItems.take_in(ctx.scope, ctx.ticket.public_id, %{model_choice: choice})

  defp errors({:error, {:model_choice, %Ecto.Changeset{} = changeset}}), do: errors_on(changeset)

  defp nothing_taken! do
    assert Repo.aggregate(WorkItem, :count) == 0
    assert Repo.aggregate(DispatchRun, :count) == 0
    assert Repo.aggregate(TakeInChoice, :count) == 0
  end

  describe "a take in with a choice" do
    test "stores the choice with the take in, and the runs resolve from it", ctx do
      assert {:ok, %WorkItem{} = work_item} = take_in(ctx, choice(ctx.provider))

      assert %TakeInChoice{} = row = ModelChoices.take_in_choice(work_item.id, 1)
      assert row.provider_chosen
      assert row.connection_id == ctx.provider.id
      assert {row.value_id, row.model_id, row.effort} == {"spare", @model, "high"}
      assert row.organisation_id == ctx.scope.organisation.id
      assert row.workspace_id == ctx.scope.workspace.id
      assert row.created_by_id == ctx.scope.user.id

      assert {:ok, {:ok, %Resolution{level: 1, model_id: @model, value_id: "spare"}}} =
               ModelChoices.resolve(ctx.scope, :workspace, "explore", row)
    end

    test "stores a tier map beside the provider, or alone", ctx do
      tiers = %{"light" => %{"model" => "claude-haiku-5-5", "effort" => "low"}}

      assert {:ok, work_item} = take_in(ctx, choice(ctx.provider, %{tiers: tiers}))
      assert %TakeInChoice{tiers: ^tiers} = ModelChoices.take_in_choice(work_item.id, 1)

      other = backlog_ticket_fixture(ctx.scope, connection: ctx.connection)

      assert {:ok, tiers_only} =
               WorkItems.take_in(ctx.scope, other.public_id, %{
                 model_choice: %{tiers: %{"fast" => @model}}
               })

      assert %TakeInChoice{provider_chosen: false, connection_id: nil, tiers: stored} =
               ModelChoices.take_in_choice(tiers_only.id, 1)

      assert stored == %{"fast" => %{"model" => @model}}
    end

    test "takes a form's params under string keys", ctx do
      assert {:ok, work_item} =
               WorkItems.take_in(ctx.scope, ctx.ticket.public_id, %{
                 "first_instruction" => "Look at the basket first.",
                 "model_choice" => %{
                   "provider" => ctx.provider.public_id,
                   "key" => "",
                   "model" => "",
                   "effort" => ""
                 }
               })

      assert %TakeInChoice{provider_chosen: true, value_id: nil, model_id: nil} =
               ModelChoices.take_in_choice(work_item.id, 1)
    end

    test "stores none for a take in that sends none, or an empty form", ctx do
      assert {:ok, first} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      assert ModelChoices.take_in_choice(first.id, 1) == nil

      other = backlog_ticket_fixture(ctx.scope, connection: ctx.connection)

      assert {:ok, second} =
               WorkItems.take_in(ctx.scope, other.public_id, %{
                 model_choice: %{provider: "", key: "", model: "", effort: "", tiers: %{}}
               })

      assert ModelChoices.take_in_choice(second.id, 1) == nil
      assert Repo.aggregate(TakeInChoice, :count) == 0
    end

    test "is kept for each take in of a work item that is taken in again", ctx do
      assert {:ok, work_item} = take_in(ctx, choice(ctx.provider))

      Repo.update_all(from(r in DispatchRun, where: r.work_item_id == ^work_item.id),
        set: [state: :ended, end_cause: :run_ended]
      )

      assert {:ok, _} = WorkItems.decline(ctx.scope, work_item)

      assert {:ok, again} =
               WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id, %{
                 model_choice: choice(ctx.provider, %{model: "claude-haiku-5-5", effort: nil})
               })

      assert again.take_in == 2
      assert %TakeInChoice{model_id: @model} = ModelChoices.take_in_choice(work_item.id, 1)

      assert %TakeInChoice{model_id: "claude-haiku-5-5"} =
               ModelChoices.take_in_choice(work_item.id, 2)
    end
  end

  describe "a take in with a choice that is refused" do
    test "stores nothing, and names the field (T22, T23, T24)", ctx do
      for {more, field} <- [
            {%{key: "nope"}, :key},
            {%{model: "huge"}, :model},
            {%{effort: "nope"}, :effort}
          ] do
        assert %{} = errors = errors(take_in(ctx, choice(ctx.provider, more)))
        assert Map.has_key?(errors, field)
        nothing_taken!()
      end
    end

    test "for a provider that does not apply to the workspace (T19)", ctx do
      other = workspace_fixture(ctx.scope.organisation, "Other site")

      {:ok, elsewhere} =
        Connections.create_provider(ctx.scope, %{
          provider: "deepseek",
          applies_to: "selected",
          workspace_ids: [other.id],
          keys: [%{value_id: "main", value: "x"}]
        })

      assert %{provider: ["Choose another provider: DeepSeek is not used in this workspace."]} =
               errors(take_in(ctx, %{provider: elsewhere.public_id}))

      nothing_taken!()
    end

    test "for a provider that is not there", ctx do
      assert %{provider: ["is invalid"]} = errors(take_in(ctx, %{provider: "con_nothing"}))
      nothing_taken!()
    end

    @tag needs: :security
    test "for a deny rule of the work item's target, found inside the take in (T25)", ctx do
      collection = Repo.get!(Collection, ctx.ticket.collection_id)

      target =
        Repo.insert!(%Target{
          organisation_id: ctx.scope.organisation.id,
          workspace_id: ctx.scope.workspace.id,
          system: collection.target_system,
          path: collection.target_path,
          first_seen_at: DateTime.utc_now()
        })

      {:ok, _} = Policy.deny(ctx.scope, target, %{host: "api.anthropic.com"})

      assert %{provider: [message]} = errors(take_in(ctx, choice(ctx.provider)))

      assert message =~
               "change the deny rule api.anthropic.com in #{target.system}/#{target.path}. "

      nothing_taken!()

      assert {:ok, _} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
    end

    test "for an operator's chain, where no choice may be sent", ctx do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.OperatorChain)

      assert take_in(ctx, choice(ctx.provider)) == {:error, {:model_choice, :forbidden}}
      nothing_taken!()
    end
  end

  describe "a workspace lock holds against the take in's choice" do
    test "refuses a choice while the workspace's choice is locked (T26)", ctx do
      for place <- [:workspace, {:workspace, "explore"}] do
        {:ok, _} =
          ModelChoices.put_choice(ctx.scope, place, choice(ctx.provider, %{locked: true}))

        assert %{provider: [message]} = errors(take_in(ctx, choice(ctx.provider)))

        assert message ==
                 "Leave the model choice empty. #{ctx.scope.workspace.name}'s model choice is locked, and every run in the workspace uses it."

        assert %{provider: [^message]} = errors(take_in(ctx, %{tiers: %{"fast" => @model}}))
        nothing_taken!()

        {:ok, _} = ModelChoices.delete_choice(ctx.scope, place)
      end
    end

    test "lets a take in with no choice go on, and a choice once the lock is gone", ctx do
      {:ok, _} =
        ModelChoices.put_choice(ctx.scope, :workspace, choice(ctx.provider, %{locked: true}))

      assert {:ok, first} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
      assert ModelChoices.take_in_choice(first.id, 1) == nil

      other = backlog_ticket_fixture(ctx.scope, connection: ctx.connection)
      {:ok, _} = ModelChoices.unlock_choice(ctx.scope, :workspace)

      assert {:ok, second} =
               WorkItems.take_in(ctx.scope, other.public_id, %{model_choice: choice(ctx.provider)})

      assert %TakeInChoice{} = ModelChoices.take_in_choice(second.id, 1)
    end

    test "is not held by an unlocked choice, or a locked choice of a target", ctx do
      {:ok, _} = ModelChoices.put_choice(ctx.scope, :workspace, choice(ctx.provider))
      assert {:ok, _} = take_in(ctx, choice(ctx.provider))
    end

    test "holds at resolution over a choice stored before the lock", ctx do
      {:ok, work_item} =
        take_in(ctx, choice(ctx.provider, %{model: "claude-haiku-5-5", effort: nil}))

      row = ModelChoices.take_in_choice(work_item.id, 1)

      assert {:ok, {:ok, %Resolution{level: 1, model_id: "claude-haiku-5-5"}}} =
               ModelChoices.resolve(ctx.scope, :workspace, "explore", row)

      {:ok, _} =
        ModelChoices.put_choice(ctx.scope, :workspace, choice(ctx.provider, %{locked: true}))

      assert {:ok, {:ok, %Resolution{level: 5, model_id: @model}}} =
               ModelChoices.resolve(ctx.scope, :workspace, "explore", row)
    end
  end

  describe "a provider removed after the take in" do
    test "leaves the choice, which resolves as a provider removed", ctx do
      {:ok, work_item} = take_in(ctx, choice(ctx.provider))
      {:ok, _} = Connections.delete_provider(ctx.scope, ctx.provider)

      assert %TakeInChoice{provider_chosen: true, connection_id: nil} =
               row =
               ModelChoices.take_in_choice(work_item.id, 1)

      assert ModelChoices.resolve(ctx.scope, :workspace, "explore", row) ==
               {:ok, {:error, :provider_removed}}
    end
  end
end
