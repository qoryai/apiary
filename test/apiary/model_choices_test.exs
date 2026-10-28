defmodule Apiary.ModelChoicesTest do
  # The model choice at six levels: what each write stores and leaves in the trail, who
  # may write where, every refusal of a save, and what resolves for a run. The resolution
  # itself is `test/apiary/model_choices/resolution_test.exs`.
  use Apiary.DataCase, async: true

  import Apiary.ConnectionsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, Deletion, ModelChoices, Policy}
  alias Apiary.Audit.Entry
  alias Apiary.Kinds.{Providers, Runtimes}
  alias Apiary.ModelChoices.{ModelChoice, Resolution}
  alias Apiary.Organisations.Workspace

  @moduletag needs: :factory

  # The catalogue's runtime, read from the list rather than named here.
  @runtime hd(Apiary.Kinds.Runtimes.list()).name

  @key "sk-choice-test-0123456789"
  @model "claude-sonnet-5-5"

  setup do
    %{scope: scope} = sign_up_fixture()

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: @key}, %{value_id: "spare", value: "sk-spare"}]
      })

    %{scope: scope, provider: provider, target: target!(scope, "acme/shop")}
  end

  defp attrs(provider, more \\ %{}),
    do:
      Map.merge(
        %{provider: provider.public_id, key: "spare", model: @model, effort: "high"},
        more
      )

  defp trail(id),
    do:
      Repo.all(
        from e in Entry,
          where: e.subject_id == ^id,
          order_by: [asc: e.inserted_at, asc: e.id]
      )

  defp errors(result) do
    assert {:error, %Ecto.Changeset{} = changeset} = result
    errors_on(changeset)
  end

  defp second_workspace(scope), do: workspace_fixture(scope.organisation, "Other site")

  describe "a write at each place" do
    test "stores one choice at each of the five places", ctx do
      %{scope: scope, provider: provider, target: target} = ctx

      places = [
        {:organisation, 6, :"provider.write"},
        {:workspace, 5, :"model_choice.write"},
        {{:workspace, "hello"}, 4, :"model_choice.write"},
        {target, 3, :"model_choice.write"},
        {{target, "hello"}, 2, :"model_choice.write"}
      ]

      for {place, level, action} <- places do
        assert {:ok, %ModelChoice{} = choice} =
                 ModelChoices.put_choice(scope, place, attrs(provider))

        assert ModelChoice.level(choice) == level
        assert choice.connection_id == provider.id
        assert {choice.value_id, choice.model_id, choice.effort} == {"spare", @model, "high"}
        assert choice.chain == "organisation"
        refute choice.locked

        assert [entry] = trail(choice.id)
        assert entry.action == to_string(action)
        assert entry.subject_kind == "model_choice"
        assert entry.details["change"] == "choice_set"
        assert entry.details["level"] == level
        assert entry.after["provider"] == provider.public_id
        assert entry.after["key"] == "spare"
        assert entry.before == nil
        refute inspect(entry, limit: :infinity) =~ @key
      end

      assert Repo.aggregate(ModelChoice, :count) == 5
      assert {:ok, choices} = ModelChoices.list_choices(scope)
      assert length(choices) == 5
    end

    test "names the place in the entry", %{scope: scope, provider: provider, target: target} do
      {:ok, workspace_choice} = ModelChoices.put_choice(scope, :workspace, attrs(provider))
      {:ok, workflow_choice} = ModelChoices.put_choice(scope, {target, "hello"}, attrs(provider))
      {:ok, default} = ModelChoices.put_choice(scope, :organisation, attrs(provider))

      assert [%{details: %{"name" => name}}] = trail(workspace_choice.id)
      assert name == scope.workspace.name

      assert [%{details: details}] = trail(workflow_choice.id)
      assert details["name"] == "github.example/acme/shop"
      assert details["workflow"] == "hello"
      assert details["target_id"] == target.id

      assert [%{details: %{"name" => org_name}}] = trail(default.id)
      assert org_name == scope.organisation.name
    end

    test "changes the choice it has, with what it was and what it is", ctx do
      %{scope: scope, provider: provider} = ctx
      {:ok, first} = ModelChoices.put_choice(scope, :workspace, attrs(provider))

      assert {:ok, changed} =
               ModelChoices.put_choice(scope, :workspace, attrs(provider, %{effort: "low"}))

      assert changed.id == first.id
      assert changed.effort == "low"
      assert Repo.aggregate(ModelChoice, :count) == 1

      assert [_set, entry] = trail(first.id)
      assert entry.details["change"] == "choice_changed"
      assert entry.before["effort"] == "high"
      assert entry.after["effort"] == "low"
    end

    test "leaves no entry for a save that changes nothing", ctx do
      %{scope: scope, provider: provider} = ctx
      {:ok, first} = ModelChoices.put_choice(scope, :workspace, attrs(provider))
      assert {:ok, same} = ModelChoices.put_choice(scope, :workspace, attrs(provider))
      assert same.id == first.id
      assert length(trail(first.id)) == 1
    end

    test "replaces what the place had, a field left out is cleared", ctx do
      %{scope: scope, provider: provider} = ctx
      {:ok, _first} = ModelChoices.put_choice(scope, :workspace, attrs(provider))

      assert {:ok, choice} =
               ModelChoices.put_choice(scope, :workspace, %{provider: provider.public_id})

      assert {choice.value_id, choice.model_id, choice.effort, choice.tiers} ==
               {nil, nil, nil, nil}
    end

    test "stores a tier map beside the provider, or alone", %{scope: scope, provider: provider} do
      tiers = %{
        "light" => "claude-haiku-5-5",
        "fast" => %{"model" => @model, "effort" => "low"},
        "thinking" => %{"model" => "claude-opus-5-5"}
      }

      assert {:ok, with_provider} =
               ModelChoices.put_choice(scope, :workspace, attrs(provider, %{tiers: tiers}))

      # A tier given as a model id alone is stored as an object of that model.
      stored = Map.put(tiers, "light", %{"model" => "claude-haiku-5-5"})
      assert with_provider.tiers == stored

      assert {:ok, alone} = ModelChoices.put_choice(scope, :organisation, %{tiers: tiers})
      assert alone.connection_id == nil
      assert alone.tiers == stored
    end

    test "takes the params of a form, under string keys", %{scope: scope, provider: provider} do
      assert {:ok, choice} =
               ModelChoices.put_choice(scope, :workspace, %{
                 "provider" => provider.public_id,
                 "key" => "main",
                 "model" => @model,
                 "effort" => "",
                 "tiers" => %{"fast" => %{"model" => @model}}
               })

      assert {choice.value_id, choice.effort, choice.tiers} ==
               {"main", nil, %{"fast" => %{"model" => @model}}}
    end

    test "removes a choice, and finds none to remove twice", %{scope: scope, provider: provider} do
      {:ok, choice} = ModelChoices.put_choice(scope, :workspace, attrs(provider))
      assert {:ok, %ModelChoice{id: id}} = ModelChoices.delete_choice(scope, :workspace)
      assert id == choice.id
      refute Repo.get(ModelChoice, id)
      assert ModelChoices.delete_choice(scope, :workspace) == {:error, :not_found}

      assert [_set, entry] = trail(id)
      assert entry.details["change"] == "choice_removed"
      assert entry.before["model"] == @model
    end

    test "refuses a workflow that is no workflow name, and a workflow at the default", ctx do
      %{scope: scope, provider: provider} = ctx

      for name <- ["Hello", "hello_world", "-hello", "", "a" <> String.duplicate("b", 64)] do
        assert ModelChoices.put_choice(scope, {:workspace, name}, attrs(provider)) ==
                 {:error, :not_found}
      end

      assert ModelChoices.put_choice(scope, {:organisation, "hello"}, attrs(provider)) ==
               {:error, :not_found}

      assert Repo.aggregate(ModelChoice, :count) == 0
    end
  end

  describe "a lock" do
    test "is set with the save at levels 4 and 5, kept by a later save, and removed", ctx do
      %{scope: scope, provider: provider} = ctx

      for place <- [:workspace, {:workspace, "hello"}] do
        assert {:ok, %{locked: true} = locked} =
                 ModelChoices.put_choice(scope, place, attrs(provider, %{locked: true}))

        assert {:ok, %{locked: true}} = ModelChoices.put_choice(scope, place, attrs(provider))

        assert {:ok, %{locked: false}} = ModelChoices.unlock_choice(scope, place)
        assert {:ok, %{locked: false}} = ModelChoices.unlock_choice(scope, place)
        assert {:ok, %{locked: true}} = ModelChoices.lock_choice(scope, place)

        changes = Enum.map(trail(locked.id), & &1.details["change"])
        assert changes == ["choice_set", "choice_unlocked", "choice_locked"]
      end
    end

    test "is not for the other levels", %{scope: scope, provider: provider, target: target} do
      for place <- [:organisation, target, {target, "hello"}] do
        assert {:ok, %{locked: false}} =
                 ModelChoices.put_choice(scope, place, attrs(provider, %{locked: true}))

        assert ModelChoices.lock_choice(scope, place) == {:error, :not_found}
      end
    end

    test "needs a choice to lock", %{scope: scope} do
      assert ModelChoices.lock_choice(scope, :workspace) == {:error, :not_found}
    end
  end

  describe "who may write" do
    test "an owner and an admin write at every place, a member at none", ctx do
      %{scope: scope, provider: provider, target: target} = ctx
      %{scope: admin} = member_fixture(scope, :admin)
      %{scope: member} = member_fixture(scope)
      places = [:organisation, :workspace, {:workspace, "hello"}, target, {target, "hello"}]

      for place <- places do
        assert {:error, :forbidden} = ModelChoices.put_choice(member, place, attrs(provider))
        assert {:ok, _} = ModelChoices.put_choice(admin, place, attrs(provider))
        assert {:ok, _} = ModelChoices.put_choice(scope, place, attrs(provider, %{effort: "low"}))
        assert {:error, :forbidden} = ModelChoices.delete_choice(member, place)
      end

      assert {:error, :forbidden} = ModelChoices.lock_choice(member, :workspace)
      assert Repo.aggregate(ModelChoice, :count) == 5
    end

    test "a member reads the choices and what they resolve to", ctx do
      %{scope: scope, provider: provider, target: target} = ctx
      %{scope: member} = member_fixture(scope)
      {:ok, _} = ModelChoices.put_choice(scope, :workspace, attrs(provider))

      assert {:ok, [%ModelChoice{}]} = ModelChoices.list_choices(member)
      assert {:ok, {:ok, %Resolution{}}} = ModelChoices.resolve(member, target, "hello")
    end

    test "a target of another workspace is not found", ctx do
      %{scope: scope, provider: provider} = ctx
      other = second_workspace(scope)

      stranger =
        Repo.insert!(%Apiary.Runs.Target{
          organisation_id: scope.organisation.id,
          workspace_id: other.id,
          system: "github.example",
          path: "acme/other",
          first_seen_at: DateTime.utc_now()
        })

      assert ModelChoices.put_choice(scope, stranger, attrs(provider)) == {:error, :not_found}
      assert ModelChoices.resolve(scope, stranger, "hello") == {:error, :not_found}
    end

    test "a provider of another organisation is invalid", ctx do
      %{scope: scope} = ctx
      %{scope: foreign} = sign_up_fixture()

      {:ok, theirs} =
        Connections.create_provider(foreign, %{
          provider: "anthropic",
          keys: [%{value_id: "main", value: "x"}]
        })

      assert errors(ModelChoices.put_choice(scope, :workspace, %{provider: theirs.public_id})) ==
               %{provider: ["is invalid"]}

      assert errors(ModelChoices.put_choice(scope, :workspace, %{provider: "con_nothing"})) ==
               %{provider: ["is invalid"]}
    end
  end

  describe "a save is refused" do
    test "for a provider that does not apply to the workspace (T19)", ctx do
      %{scope: scope} = ctx
      other = second_workspace(scope)

      {:ok, elsewhere} =
        Connections.create_provider(scope, %{
          provider: "deepseek",
          applies_to: "selected",
          workspace_ids: [other.id],
          keys: [%{value_id: "main", value: "x"}]
        })

      assert errors(ModelChoices.put_choice(scope, :workspace, %{provider: elsewhere.public_id})) ==
               %{provider: ["Choose another provider: DeepSeek is not used in this workspace."]}

      # The organisation's default has no workspace to apply to.
      assert {:ok, _} =
               ModelChoices.put_choice(scope, :organisation, %{provider: elsewhere.public_id})

      assert {:ok, _} =
               ModelChoices.put_choice(second_scope(scope, other), :workspace, %{
                 provider: elsewhere.public_id
               })
    end

    test "at the organisation's default, for a provider whose keys are a workspace's secret",
         ctx do
      %{scope: scope, provider: shared} = ctx

      {:ok, workspace_only} =
        Connections.create_provider(
          scope,
          %{provider: "deepseek", keys: [%{value_id: "main", value: "x"}]},
          :workspace
        )

      assert errors(
               ModelChoices.put_choice(scope, :organisation, %{provider: workspace_only.public_id})
             ) ==
               %{
                 provider: [
                   "To share this provider, add it again with “Available to every workspace in #{scope.organisation.name}” on. Its key is a secret of #{scope.workspace.name}."
                 ]
               }

      assert {:ok, []} = ModelChoices.list_choices(scope)

      # The workspace's choice may name it, and the default a provider of the
      # organisation's secret.
      assert {:ok, _} =
               ModelChoices.put_choice(scope, :workspace, %{provider: workspace_only.public_id})

      assert {:ok, _} =
               ModelChoices.put_choice(scope, :organisation, %{provider: shared.public_id})
    end

    test "for a provider whose key the runtime has no variable for (T21)" do
      {:ok, runtime} = Runtimes.fetch(@runtime)
      {:ok, anthropic} = Providers.fetch("anthropic")
      auth = %{"scheme" => "basic", "username" => "runner"}
      basic = %{anthropic | apis: Enum.map(anthropic.apis, &%{&1 | "auth" => auth})}

      assert {:error, {message, bindings}} = ModelChoices.serves(basic, runtime, "Team models")

      assert message ==
               "Choose another provider for %{runtime}. %{runtime} has no environment variable for %{provider}'s key with the same authentication."

      assert bindings == [runtime: runtime.title, provider: "Team models"]
    end

    test "for a provider of a bearer key, which the runtime reads from its variable", %{
      scope: scope
    } do
      {:ok, router} =
        Connections.create_provider(scope, %{
          provider: "openrouter",
          keys: [%{value_id: "main", value: "x"}]
        })

      assert {:ok, _choice} =
               ModelChoices.put_choice(scope, :workspace, %{provider: router.public_id})
    end

    test "for a provider that serves no format the runtime sends (T20)" do
      {:ok, runtime} = Runtimes.fetch(@runtime)
      {:ok, anthropic} = Providers.fetch("anthropic")

      other_format = %{
        anthropic
        | apis: Enum.map(anthropic.apis, &%{&1 | "format" => "openai-chat"})
      }

      assert {:error, {message, bindings}} =
               ModelChoices.serves(other_format, runtime, "Team models")

      assert message ==
               "Choose another provider for %{runtime}. %{provider} serves no request format that %{runtime} sends."

      assert bindings == [runtime: runtime.title, provider: "Team models"]
      assert ModelChoices.serves(anthropic, runtime) == :ok
    end

    test "for a key that is not one of the provider's (T22)", %{scope: scope, provider: provider} do
      assert errors(ModelChoices.put_choice(scope, :workspace, attrs(provider, %{key: "nope"}))) ==
               %{key: ["Choose one of Anthropic API key's keys: nope is not one of them."]}
    end

    test "for an effort the model has not, of the description or any other id (T23, T24)",
         ctx do
      %{scope: scope, provider: provider} = ctx

      assert errors(
               ModelChoices.put_choice(scope, :workspace, attrs(provider, %{effort: "turbo"}))
             ) ==
               %{
                 effort: [
                   "Choose one of #{@model}'s effort values: low, medium, high, xhigh, max."
                 ]
               }

      assert errors(
               ModelChoices.put_choice(scope, :workspace, attrs(provider, %{model: "acme-large"}))
             ) ==
               %{
                 effort: [
                   "Leave the effort empty: acme-large has no effort values to choose from."
                 ]
               }

      # A model the description does not list is taken by its id, with no effort.
      assert {:ok, %ModelChoice{model_id: "acme-large", effort: nil}} =
               ModelChoices.put_choice(
                 scope,
                 :workspace,
                 attrs(provider, %{model: "acme-large", effort: nil})
               )
    end

    test "for a tier that is not light, fast or thinking (T15), or a tier effort its model has not",
         ctx do
      %{scope: scope, provider: provider} = ctx

      assert errors(
               ModelChoices.put_choice(
                 scope,
                 :workspace,
                 attrs(provider, %{tiers: %{"huge" => @model}})
               )
             ) ==
               %{tiers: ["Use light, fast or thinking: huge is not a tier."]}

      assert errors(
               ModelChoices.put_choice(
                 scope,
                 :workspace,
                 attrs(provider, %{
                   tiers: %{"fast" => %{"model" => "acme-small", "effort" => "low"}}
                 })
               )
             ) == %{
               tiers: ["Leave the effort empty: acme-small has no effort values to choose from."]
             }

      assert errors(
               ModelChoices.put_choice(
                 scope,
                 :workspace,
                 attrs(provider, %{tiers: %{"fast" => %{"model" => @model, "effort" => "nope"}}})
               )
             ) == %{
               tiers: ["Choose one of #{@model}'s effort values: low, medium, high, xhigh, max."]
             }

      assert {:ok, %ModelChoice{tiers: %{"fast" => %{"model" => "acme-small"}}}} =
               ModelChoices.put_choice(
                 scope,
                 :workspace,
                 attrs(provider, %{tiers: %{"fast" => "acme-small"}})
               )
    end

    test "for a model id, an effort or a tier entry that breaks its rule (T13, T14)", ctx do
      %{scope: scope, provider: provider} = ctx

      model_rule =
        "Use 1 to 200 ASCII letters, digits and punctuation with no space, starting with a letter or a digit."

      effort_rule =
        "Use 1 to 32 lower-case letters, digits and hyphens, starting with a letter, such as high."

      for {more, field, message} <- [
            {%{model: " m"}, :model, model_rule},
            {%{model: String.duplicate("m", 201)}, :model, model_rule},
            {%{effort: "High"}, :effort, effort_rule},
            {%{effort: String.duplicate("e", 33)}, :effort, effort_rule},
            {%{tiers: %{"fast" => "a b"}}, :tiers, model_rule},
            {%{tiers: %{"fast" => %{"effort" => "low"}}}, :tiers, model_rule},
            {%{tiers: %{"fast" => %{"model" => "m", "effort" => "High"}}}, :tiers, effort_rule},
            {%{tiers: %{"fast" => %{"model" => "m", "other" => "x"}}}, :tiers, model_rule}
          ] do
        assert message in Map.fetch!(
                 errors(ModelChoices.put_choice(scope, :workspace, attrs(provider, more))),
                 field
               ),
               inspect(more)
      end
    end

    test "for a key or a model without a provider, an effort without a model, or nothing", ctx do
      %{scope: scope, provider: provider} = ctx

      assert %{provider: ["can't be blank"]} =
               errors(ModelChoices.put_choice(scope, :workspace, %{key: "main"}))

      assert %{provider: ["can't be blank"]} =
               errors(ModelChoices.put_choice(scope, :workspace, %{model: @model}))

      assert %{provider: ["can't be blank"]} =
               errors(ModelChoices.put_choice(scope, :workspace, %{}))

      assert %{model: ["can't be blank"]} =
               errors(
                 ModelChoices.put_choice(scope, :workspace, %{
                   provider: provider.public_id,
                   effort: "low"
                 })
               )

      assert Repo.aggregate(ModelChoice, :count) == 0
    end
  end

  describe "a deny rule" do
    test "that covers a host of the provider refuses no save", ctx do
      %{scope: scope, provider: provider, target: target} = ctx

      {:ok, rule} = Policy.deny(scope, nil, %{host: "*.anthropic.com"})
      {:ok, _} = Policy.lock(scope, rule)

      # An exact deny of the provider's host is refused at save (Apiary.Policy.check_deny/3).
      assert {:error, %Policy.Error{reason: :integration_host}} =
               Policy.deny(scope, target, %{host: "api.anthropic.com"})

      assert {:ok, _} = ModelChoices.put_choice(scope, :workspace, attrs(provider))
      assert {:ok, _} = ModelChoices.put_choice(scope, {target, "hello"}, attrs(provider))
      assert {:ok, _} = ModelChoices.put_choice(scope, target, attrs(provider))
      assert {:ok, _} = ModelChoices.put_choice(scope, :organisation, attrs(provider))
    end
  end

  describe "resolve/3" do
    test "leaves out a tier whose effort its model has not", ctx do
      %{scope: scope, provider: provider} = ctx

      {:ok, choice} =
        ModelChoices.put_choice(
          scope,
          :workspace,
          attrs(provider, %{
            tiers: %{"fast" => %{"model" => @model, "effort" => "low"}, "light" => "acme-small"}
          })
        )

      assert {:ok, {:ok, %Resolution{tiers: tiers}}} =
               ModelChoices.resolve(scope, :workspace, "hello")

      assert tiers == %{
               "fast" => %{"model" => @model, "effort" => "low"},
               "light" => %{"model" => "acme-small"}
             }

      # Rows a save refuses: an effort the description's model has not, and an effort with
      # a model the description does not list.
      choice
      |> Ecto.Changeset.change(
        tiers: %{
          "fast" => %{"model" => @model, "effort" => "turbo"},
          "light" => %{"model" => "acme-small", "effort" => "low"}
        }
      )
      |> Repo.update!()

      assert {:ok, {:ok, %Resolution{tiers: tiers}}} =
               ModelChoices.resolve(scope, :workspace, "hello")

      assert tiers == %{}
    end

    test "reads the choices of the workspace's chain for a target", ctx do
      %{scope: scope, provider: provider, target: target} = ctx

      {:ok, _} =
        ModelChoices.put_choice(
          scope,
          :organisation,
          attrs(provider, %{model: "claude-haiku-5-5", effort: nil})
        )

      {:ok, _} = ModelChoices.put_choice(scope, :workspace, attrs(provider))

      assert {:ok, {:ok, %Resolution{level: 5, model_id: @model, effort: "high"}}} =
               ModelChoices.resolve(scope, target, "hello")

      {:ok, _} =
        ModelChoices.put_choice(
          scope,
          {target, "hello"},
          attrs(provider, %{model: "claude-opus-5-5", effort: "max"})
        )

      assert {:ok, {:ok, %Resolution{level: 2, model_id: "claude-opus-5-5", effort: "max"}}} =
               ModelChoices.resolve(scope, target, "hello")
    end

    test "resolves a run with no target from the workspace and the organisation, and refuses nothing",
         ctx do
      %{scope: scope, provider: provider} = ctx

      assert ModelChoices.resolve(scope, :workspace, "hello") == {:ok, :none}

      {:ok, _} =
        ModelChoices.put_choice(
          scope,
          :organisation,
          attrs(provider, %{model: "claude-haiku-5-5"})
        )

      assert {:ok, {:ok, %Resolution{level: 6, model_id: "claude-haiku-5-5"}}} =
               ModelChoices.resolve(scope, :workspace, "hello")

      {:ok, _} = ModelChoices.put_choice(scope, {:workspace, "hello"}, attrs(provider))

      assert {:ok, {:ok, %Resolution{level: 4, model_id: @model}}} =
               ModelChoices.resolve(scope, :workspace, "hello")
    end

    test "a workspace lock holds over a target's choice", ctx do
      %{scope: scope, provider: provider, target: target} = ctx

      {:ok, _} =
        ModelChoices.put_choice(
          scope,
          :workspace,
          attrs(provider, %{model: "claude-haiku-5-5", locked: true})
        )

      {:ok, _} = ModelChoices.put_choice(scope, {target, "hello"}, attrs(provider))

      assert {:ok, {:ok, %Resolution{level: 5, model_id: "claude-haiku-5-5"}}} =
               ModelChoices.resolve(scope, target, "hello")
    end

    test "leaves out the choices of another workspace", ctx do
      %{scope: scope, provider: provider, target: target} = ctx
      other = second_workspace(scope)
      {:ok, _} = ModelChoices.put_choice(second_scope(scope, other), :workspace, attrs(provider))

      assert ModelChoices.resolve(scope, target, "hello") == {:ok, :none}
    end

    test "reads the chain the edition answers for the organisation", ctx do
      %{scope: scope, provider: provider} = ctx

      {:ok, %ModelChoice{}} = ModelChoices.put_choice(scope, :workspace, attrs(provider))

      assert Apiary.Edition.model_choice_chain(scope.organisation.id) == "organisation"

      # The operator's chain is the rows of the operator's organisation; the organisation's
      # rows are kept and unused while the edition answers "operator".
      %{scope: operator} = sign_up_fixture()
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ServesAcrossWithChain)
      Apiary.EditionStubs.ServesAcross.put([{operator.organisation.id, scope.organisation.id}])
      Apiary.EditionStubs.ServesAcrossWithChain.writer(true)

      {:ok, theirs} =
        Connections.create_provider(operator, %{
          provider: "anthropic",
          chain: "operator",
          keys: [%{value_id: "main", value: @key}]
        })

      {:ok, %ModelChoice{chain: "operator"}} =
        ModelChoices.put_choice(
          operator,
          :organisation,
          %{provider: theirs.public_id, key: "main", model: "claude-haiku-5-5"},
          "operator"
        )

      assert {:ok, {:ok, %Resolution{model_id: @model}}} =
               ModelChoices.resolve(scope, :workspace, "hello")

      Apiary.EditionStubs.ServesAcrossWithChain.chain("operator")

      assert {:ok, {:ok, %Resolution{level: 6, model_id: "claude-haiku-5-5"}}} =
               ModelChoices.resolve(scope, :workspace, "hello")

      # The edition names no operator: the chain has no choice, and the run no provider.
      Apiary.EditionStubs.ServesAcrossWithChain.operator(nil)
      assert ModelChoices.resolve(scope, :workspace, "hello") == {:ok, :none}
    end

    test "refuses a workflow that is no workflow name", %{scope: scope} do
      assert ModelChoices.resolve(scope, :workspace, "Hello") == {:error, :not_found}
    end
  end

  describe "in a workspace whose domain has no repository" do
    test "the levels of a target hold, and no text of the module names a repository", ctx do
      %{scope: scope, provider: provider, target: target} = ctx
      scope = with_domain(scope, "example")
      {:ok, choice} = ModelChoices.put_choice(scope, {target, "hello"}, attrs(provider))
      {:ok, _} = ModelChoices.put_choice(scope, target, attrs(provider, %{effort: "low"}))

      assert {:ok, {:ok, %Resolution{level: 2}}} = ModelChoices.resolve(scope, target, "hello")

      [entry] = trail(choice.id)
      assert entry.details["name"] == "github.example/acme/shop"
      refute inspect(entry, limit: :infinity) =~ ~r/repositor/i

      for path <- ["lib/apiary/model_choices.ex" | Path.wildcard("lib/apiary/model_choices/*.ex")] do
        refute File.read!(path) =~ ~r/repositor/i, path
      end
    end
  end

  describe "a purge" do
    test "of a workspace takes its choices, not the organisation's default", ctx do
      %{scope: scope, provider: provider} = ctx
      other = second_workspace(scope)
      other_scope = second_scope(scope, other)
      {:ok, _} = ModelChoices.put_choice(scope, :organisation, attrs(provider))
      {:ok, _} = ModelChoices.put_choice(scope, :workspace, attrs(provider))
      {:ok, _} = ModelChoices.put_choice(other_scope, :workspace, attrs(provider))

      {:ok, _} = Deletion.delete_workspace(scope, other.id, other.slug)

      Repo.update_all(from(w in Workspace, where: w.id == ^other.id),
        set: [purge_after: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      assert {:ok, :purged} =
               Deletion.purge_workspace(
                 Apiary.Accounts.Scope.for_instance(
                   scope.organisation,
                   Repo.get!(Workspace, other.id)
                 )
               )

      assert Repo.aggregate(ModelChoice, :count) == 2
      refute Repo.exists?(from c in ModelChoice, where: c.workspace_id == ^other.id)
    end

    test "of an organisation takes every choice and the providers they use", ctx do
      %{scope: scope, provider: provider} = ctx
      {:ok, _} = ModelChoices.put_choice(scope, :organisation, attrs(provider))
      {:ok, _} = ModelChoices.put_choice(scope, :workspace, attrs(provider))

      assert {:ok, :purged} = Deletion.purge_now(scope.organisation, scope.user)
      assert Repo.aggregate(ModelChoice, :count) == 0
    end
  end

  # The scope of the same owner in another workspace of the organisation.
  defp second_scope(scope, %Workspace{} = workspace),
    do: workspace_scope(scope.user, workspace)
end
