defmodule Apiary.Dispatches.RunSettingsTest do
  # The run settings of an explore run a claim registers (`Apiary.Dispatches.RunSettings`):
  # what the model choices resolve to, the API of the provider the run uses, the causes
  # that end the run, and what the run keeps. The races with a provider's change are
  # `run_settings_races_test.exs`; the answer's 1 MiB limit and the features off are
  # `run_settings_budget_test.exs`.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, ModelChoices, Repo}
  alias Apiary.Connections.Connection
  alias Apiary.Dispatches.{Dispatch, DispatchRun, RunSettings}
  alias Apiary.Kinds.{Coded, Providers, Runtimes}
  alias Apiary.ModelChoices.{ModelChoice, Resolution}
  alias Apiary.Runs.{Projector, Run, Target}

  @moduletag needs: :factory

  # The catalogue's runtime, read from the list rather than named here.
  @runtime hd(Apiary.Kinds.Runtimes.list()).name

  @body ~s({"version":1,"time":"2026-10-18T12:00:00Z"})
  @key "sk-ant-run-settings-0123456789"
  @efforts ~w(low medium high xhigh max)
  @messages %{
    "format" => "anthropic-messages",
    "endpoint" => "https://api.anthropic.com",
    "auth" => %{"scheme" => "header", "header" => "x-api-key"}
  }

  setup do
    %{scope: scope} = sign_up_fixture()

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: @key}, %{value_id: "spare", value: "sk-ant-spare"}]
      })

    scope
    |> handover_place_fixture(allow_secrets: true)
    |> Map.merge(%{scope: scope, provider: provider})
  end

  # A fresh work item's explore run, queued and claimed: `{:ok, documents}`, what the run's
  # documents are made from with the registered run as `run`, or `{:error, :gone}` when the
  # claim ended the run, or the claim's error; the run of the queue; and the dispatch the
  # claim wrote, nil for none.
  defp handover!(ctx, attrs \\ %{}) do
    work_item = work_item_fixture(ctx.scope, attrs)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

    answer =
      case Dispatches.claim(ctx.key, Dispatches.now(), @body) do
        {:ok, %{registered: run, documents: documents}} -> {:ok, Map.put(documents, :run, run)}
        {:ok, :none} -> {:error, :gone}
        {:error, _reason} = error -> error
      end

    dispatch = Repo.one(from d in Dispatch, where: d.dispatch_run_id == ^queued.id)
    {answer, queued, dispatch}
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

  defp settings(%{run_settings: settings}), do: settings |> Jason.encode!() |> Jason.decode!()

  defp choose!(scope, place, attrs) do
    {:ok, choice} = ModelChoices.put_choice(scope, place, attrs)
    choice
  end

  defp models(efforts) do
    for id <- ~w(claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5 claude-fable-5-1),
        do: %{"id" => id, "effort" => efforts}
  end

  # The run of the queue and its dispatch ended with `cause`, with the outcome error, and
  # no run registered.
  defp ended!(queued, dispatch, cause) do
    assert %DispatchRun{state: :ended, end_cause: ^cause, result_outcome: :error} =
             Repo.get!(DispatchRun, queued.id)

    assert %Dispatch{end_cause: ^cause, handed_over_at: nil} = Repo.get!(Dispatch, dispatch.id)
    assert Repo.aggregate(from(r in Run, where: r.dispatch_run_id == ^queued.id), :count) == 0
  end

  describe "a claim with no choice at any level" do
    test "registers the run through a gateway key without the stored-secrets flag", ctx do
      Apiary.AccessKeysFixtures.node_key_fixture(ctx.scope, ctx.gateway)

      {{:ok, handed}, _queued, _dispatch} = handover!(ctx)
      assert settings(handed) == %{"runtime" => @runtime}
    end

    test "sends the runtime alone, and the run keeps no provider", ctx do
      {{:ok, handed}, _queued, _dispatch} = handover!(ctx)

      assert settings(handed) == %{"runtime" => @runtime}

      assert %Run{
               run_settings: %{"runtime" => @runtime},
               provider_connection_id: nil,
               provider_secret_id: nil,
               provider_value_id: nil,
               provider_chain: nil,
               provider_api: nil
             } = Repo.get!(Run, handed.run.id)
    end
  end

  describe "a claim with a choice" do
    test "of a run with no target reads the workspace and organisation levels alone", ctx do
      scope = with_domain(ctx.scope, "general")
      target = Repo.insert!(target(scope, "acme/shop"))

      choose!(scope, :organisation, %{
        provider: ctx.provider.public_id,
        model: "claude-opus-5-5",
        effort: "high"
      })

      choose!(scope, :workspace, %{tiers: %{"fast" => "claude-haiku-5-5"}})

      # Levels 2 and 3 belong to a target: a run without one reads neither.
      choose!(scope, target, %{
        provider: ctx.provider.public_id,
        model: "claude-sonnet-5-5",
        tiers: %{"fast" => "claude-sonnet-5-5"}
      })

      {{:ok, handed}, _queued, _dispatch} =
        handover!(ctx, %{target_system: nil, target_path: nil})

      assert handed.target == nil

      assert settings(handed) == %{
               "runtime" => @runtime,
               "model" => "claude-opus-5-5",
               "effort" => "high",
               "provider_models" => models(@efforts),
               "tiers" => %{"fast" => "claude-haiku-5-5"}
             }

      ordered = handed.run_settings |> Jason.encode!() |> Jason.decode!(objects: :ordered_objects)

      assert Enum.map(ordered.values, &elem(&1, 0)) ==
               ~w(runtime model effort provider_models tiers)
    end

    test "of a run with a target reads the target's level first", ctx do
      target = Repo.insert!(target(ctx.scope, "acme/shop"))

      choose!(ctx.scope, :workspace, %{provider: ctx.provider.public_id, model: "claude-opus-5-5"})

      choose!(ctx.scope, target, %{
        provider: ctx.provider.public_id,
        key: "spare",
        model: "claude-sonnet-5-5"
      })

      {{:ok, handed}, _queued, _dispatch} = handover!(ctx)

      assert %{"model" => "claude-sonnet-5-5"} = settings(handed)
      assert %Run{provider_value_id: "spare"} = Repo.get!(Run, handed.run.id)
    end

    test "keeps the provider and the API the run uses on the run", ctx do
      %{provider: provider} = ctx
      choose!(ctx.scope, :workspace, %{provider: provider.public_id})

      {{:ok, handed}, _queued, _dispatch} = handover!(ctx)

      provider_id = provider.id
      secret_id = provider.secret_id

      assert %Run{
               provider_connection_id: ^provider_id,
               provider_secret_id: ^secret_id,
               provider_value_id: "main",
               provider_chain: "organisation",
               provider_api: @messages
             } = run = Repo.get!(Run, handed.run.id)

      assert run.run_settings == settings(handed)

      # No effort chosen: none is sent, and the runtime uses its default.
      assert settings(handed) == %{
               "runtime" => @runtime,
               "model" => "claude-opus-5-5",
               "provider_models" => models(@efforts)
             }
    end

    test "has no endpoint, no key, no secret id and no value id", ctx do
      %{provider: provider} = ctx
      choose!(ctx.scope, :workspace, %{provider: provider.public_id, key: "spare"})

      {result, log} = with_log(fn -> handover!(ctx) end)
      {{:ok, handed}, _queued, _dispatch} = result
      refute log =~ "sk-ant"

      for encoded <- [
            Jason.encode!(handed.run_settings),
            Jason.encode!(Repo.get!(Run, handed.run.id).run_settings)
          ] do
        refute encoded =~ "endpoint"
        refute encoded =~ "anthropic.com"
        refute encoded =~ @key
        refute encoded =~ "sk-ant-spare"
        refute encoded =~ provider.secret_id
        refute encoded =~ "spare"
      end

      assert %Run{provider_api: api} = Repo.get!(Run, handed.run.id)
      refute Jason.encode!(api) =~ "sk-ant"
    end

    test "lists the description's models, then each chosen model it does not list", ctx do
      choose!(ctx.scope, :workspace, %{
        provider: ctx.provider.public_id,
        model: "acme-large",
        tiers: %{
          "light" => "claude-haiku-5-5",
          "fast" => "acme-small",
          "thinking" => "acme-large"
        }
      })

      {{:ok, handed}, _queued, _dispatch} = handover!(ctx)

      assert settings(handed) == %{
               "runtime" => @runtime,
               "model" => "acme-large",
               "provider_models" =>
                 models(@efforts) ++ [%{"id" => "acme-large"}, %{"id" => "acme-small"}],
               "tiers" => %{
                 "light" => "claude-haiku-5-5",
                 "fast" => "acme-small",
                 "thinking" => "acme-large"
               }
             }
    end
  end

  describe "a claim ends the run" do
    test "secrets_not_allowed for a provider and a gateway key without the stored-secrets flag",
         ctx do
      choose!(ctx.scope, :workspace, %{provider: ctx.provider.public_id})

      # A second active key of the gateway, made in a browser, without the flag: the run
      # key lists both, and either may attach the run.
      Apiary.AccessKeysFixtures.node_key_fixture(ctx.scope, ctx.gateway)

      {answer, queued, dispatch} = handover!(ctx)
      assert answer == {:error, :gone}
      ended!(queued, dispatch, :secrets_not_allowed)
    end

    test "model_gone for an effort the chosen model does not offer", ctx do
      # Past the save, which refuses each: choices stored before the description changed.
      for {{model, effort}, n} <-
            Enum.with_index([{"claude-opus-5-5", "turbo"}, {"acme-large", "low"}]) do
        Repo.delete_all(ModelChoice)

        Repo.insert!(%ModelChoice{
          organisation_id: ctx.scope.organisation.id,
          workspace_id: ctx.scope.workspace.id,
          connection_id: ctx.provider.id,
          model_id: model,
          effort: effort
        })

        {answer, queued, dispatch} = handover!(ctx, %{external_ref: "acme/shop##{30 + n}"})
        assert answer == {:error, :gone}, model
        ended!(queued, dispatch, :model_gone)
      end
    end

    test "model_gone where no model resolves, for a provider whose description lists none",
         ctx do
      {:ok, litellm} =
        Connections.create_provider(ctx.scope, %{
          provider: "litellm",
          settings: %{"address" => "https://litellm.example.com"},
          keys: [%{value_id: "main", value: "sk-team"}]
        })

      choose!(ctx.scope, :workspace, %{provider: litellm.public_id})

      {answer, queued, dispatch} = handover!(ctx)
      assert answer == {:error, :gone}
      ended!(queued, dispatch, :model_gone)
    end

    test "never for a model the description does not list", ctx do
      choose!(ctx.scope, :workspace, %{provider: ctx.provider.public_id, model: "acme-large"})

      {{:ok, handed}, _queued, _dispatch} = handover!(ctx)

      assert %{"model" => "acme-large", "provider_models" => listed} = settings(handed)
      assert List.last(listed) == %{"id" => "acme-large"}
    end

    test "provider_gone for a setting endpoint that fails the endpoint rule", ctx do
      {:ok, litellm} =
        Connections.create_provider(ctx.scope, %{
          provider: "litellm",
          settings: %{"address" => "https://litellm.example.com"},
          keys: [%{value_id: "main", value: "sk-team"}]
        })

      choose!(ctx.scope, :workspace, %{provider: litellm.public_id, model: "team-large"})

      # Past the save, which refuses each: an address stored before the rule refused it.
      for {address, n} <-
            Enum.with_index(["https://127.0.0.1:4000", "http://litellm.example.com"]) do
        recode!(litellm, settings: Jason.encode!(%{"address" => address}))

        {answer, queued, dispatch} = handover!(ctx, %{external_ref: "acme/shop##{20 + n}"})
        assert answer == {:error, :gone}, address
        ended!(queued, dispatch, :provider_gone)
      end
    end

    test "provider_gone for a provider that no longer applies to the workspace", ctx do
      choose!(ctx.scope, :workspace, %{provider: ctx.provider.public_id})
      recode!(ctx.provider, applies_to: "selected")

      {answer, queued, dispatch} = handover!(ctx)
      assert answer == {:error, :gone}
      ended!(queued, dispatch, :provider_gone)
    end

    test "provider_gone for a provider row that fails its integrity code", ctx do
      {:ok, litellm} =
        Connections.create_provider(ctx.scope, %{
          provider: "litellm",
          settings: %{"address" => "https://litellm.example.com"},
          keys: [%{value_id: "main", value: "sk-team"}]
        })

      choose!(ctx.scope, :workspace, %{provider: litellm.public_id, model: "team-large"})

      # An address the endpoint rule takes, written without a new code: the run must not
      # be registered with it.
      {1, _rows} =
        Repo.update_all(from(c in Connection, where: c.id == ^litellm.id),
          set: [settings: ~s({"address":"https://elsewhere.example.com"})]
        )

      {result, log} = with_log(fn -> handover!(ctx) end)
      {answer, queued, dispatch} = result
      assert answer == {:error, :gone}
      ended!(queued, dispatch, :provider_gone)
      assert log =~ "the model provider #{litellm.public_id} fails its integrity code"
      refute log =~ "elsewhere.example.com"
    end

    test "never for a deny rule that covers the provider's host", ctx do
      choose!(ctx.scope, :workspace, %{provider: ctx.provider.public_id})
      {:ok, rule} = Apiary.Policy.deny(ctx.scope, nil, %{host: "*.anthropic.com"})
      {:ok, _} = Apiary.Policy.lock(ctx.scope, rule)

      {{:ok, handed}, _queued, _dispatch} = handover!(ctx)
      assert %{"model" => "claude-opus-5-5"} = settings(handed)
    end
  end

  describe "a setting endpoint" do
    setup ctx do
      {:ok, litellm} =
        Connections.create_provider(ctx.scope, %{
          provider: "litellm",
          settings: %{"address" => "https://litellm.example.com/team"},
          keys: [%{value_id: "main", value: "sk-team"}]
        })

      choose!(ctx.scope, :workspace, %{provider: litellm.public_id, model: "team-large"})
      %{litellm: litellm}
    end

    test "is resolved to the address the provider has", ctx do
      {{:ok, handed}, _queued, _dispatch} = handover!(ctx)

      # The description lists no model: the chosen one alone.
      assert %{"model" => "team-large", "provider_models" => [%{"id" => "team-large"}]} =
               settings(handed)

      assert %Run{
               provider_api: %{
                 "format" => "anthropic-messages",
                 "endpoint" => "https://litellm.example.com/team",
                 "auth" => %{"scheme" => "bearer"}
               }
             } = Repo.get!(Run, handed.run.id)
    end

    test "is written once: a later change of the address or a rebuild keeps the run's", ctx do
      {{:ok, handed}, _queued, _dispatch} = handover!(ctx)
      run = Repo.get!(Run, handed.run.id)

      {:ok, _litellm} =
        Connections.update_provider(ctx.scope, ctx.litellm, %{
          settings: %{"address" => "https://models.example.com"}
        })

      assert {:ok, _rebuilt} = Projector.rebuild(run)

      assert %Run{provider_api: %{"endpoint" => "https://litellm.example.com/team"}} =
               kept = Repo.get!(Run, run.id)

      assert {kept.run_settings, kept.provider_api, kept.provider_value_id} ==
               {run.run_settings, run.provider_api, run.provider_value_id}

      # The next run takes the address as it is now.
      {{:ok, next}, _queued, _dispatch} = handover!(ctx, %{external_ref: "acme/shop#13"})

      assert %Run{provider_api: %{"endpoint" => "https://models.example.com"}} =
               Repo.get!(Run, next.run.id)
    end
  end

  describe "a deletion of the provider" do
    test "is refused while a pending or running run uses it, which it names beside the choices",
         ctx do
      choose!(ctx.scope, :workspace, %{provider: ctx.provider.public_id})
      {{:ok, handed}, _queued, _dispatch} = handover!(ctx)
      run = Repo.get!(Run, handed.run.id)
      assert run.state == "pending"

      assert {:error, {:provider_in_use, %{places: [%{level: 5}], runs: [public_id]}}} =
               Connections.delete_provider(ctx.scope, ctx.provider)

      assert public_id == run.public_id

      {:ok, _choice} = ModelChoices.delete_choice(ctx.scope, :workspace)

      for state <- Run.alive_states() do
        {1, _rows} = Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [state: state])

        assert Connections.delete_provider(ctx.scope, ctx.provider) ==
                 {:error, {:provider_in_use, %{places: [], runs: [run.public_id]}}}
      end

      # Once the run ended, the provider goes; the run keeps what it was registered
      # with, and its links to the deleted rows are cleared.
      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [state: "completed"])

      assert {:ok, _deleted} = Connections.delete_provider(ctx.scope, ctx.provider)

      assert %Run{
               provider_connection_id: nil,
               provider_secret_id: nil,
               provider_value_id: "main",
               provider_api: @messages,
               run_settings: %{"model" => "claude-opus-5-5"}
             } = Repo.get!(Run, run.id)
    end

    test "keeps refusing with the choices alone while no run uses it", ctx do
      choose!(ctx.scope, :workspace, %{provider: ctx.provider.public_id})

      assert {:error, {:model_in_use, [%{level: 5}]}} =
               Connections.delete_provider(ctx.scope, ctx.provider)
    end
  end

  describe "a client on the operator's chain" do
    setup ctx do
      %{scope: operator} = sign_up_fixture()
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ServesAcrossWithChain)

      Apiary.EditionStubs.ServesAcross.put([
        {operator.organisation.id, ctx.scope.organisation.id}
      ])

      Apiary.EditionStubs.ServesAcrossWithChain.writer(true)

      {:ok, theirs} =
        Connections.create_provider(operator, %{
          provider: "anthropic",
          chain: "operator",
          keys: [%{value_id: "main", value: @key}]
        })

      {:ok, _choice} =
        ModelChoices.put_choice(
          operator,
          :organisation,
          %{provider: theirs.public_id, key: "main", model: "claude-haiku-5-5"},
          "operator"
        )

      # The client's choice at its workspace, which the operator's chain does not read.
      choose!(ctx.scope, :workspace, %{provider: ctx.provider.public_id, model: "claude-opus-5-5"})

      %{operator: operator, theirs: theirs}
    end

    # What `build/1` makes of the settings a claim of a fresh work item holds.
    defp built!(ctx) do
      work_item = work_item_fixture(ctx.scope)
      {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
      assert {:ok, built} = queued |> RunSettings.hold() |> RunSettings.build()
      built
    end

    test "reads the organisation's chain while the edition answers organisation", ctx do
      built = built!(ctx)

      assert built.stored["model"] == "claude-opus-5-5"

      assert %{provider_connection_id: id, provider_chain: "organisation"} = built.columns
      assert id == ctx.provider.id
    end

    test "uses the operator's choice and provider, not the client's", ctx do
      Apiary.EditionStubs.ServesAcrossWithChain.chain("operator")
      built = built!(ctx)

      assert built.stored["model"] == "claude-haiku-5-5"

      assert %{
               provider_connection_id: id,
               provider_secret_id: secret_id,
               provider_value_id: "main",
               provider_chain: "operator"
             } = built.columns

      assert {id, secret_id} == {ctx.theirs.id, ctx.theirs.secret_id}
    end

    test "has the runtime alone where the edition names no operator", ctx do
      Apiary.EditionStubs.ServesAcrossWithChain.chain("operator")
      Apiary.EditionStubs.ServesAcrossWithChain.operator(nil)
      built = built!(ctx)

      assert built.stored == %{"runtime" => @runtime}
      assert built.columns == %{}
    end

    test "has the runtime alone where the operator has no choice", ctx do
      Apiary.EditionStubs.ServesAcrossWithChain.chain("operator")
      assert {:ok, _choice} = ModelChoices.delete_choice(ctx.operator, :organisation, "operator")
      built = built!(ctx)

      assert built.stored == %{"runtime" => @runtime}
      assert built.columns == %{}
    end

    test "ends the run as provider_gone when the operator's provider fails its code", ctx do
      Apiary.EditionStubs.ServesAcrossWithChain.chain("operator")

      Repo.update_all(from(c in Connection, where: c.id == ^ctx.theirs.id),
        set: [name: "Tampered"]
      )

      work_item = work_item_fixture(ctx.scope)
      {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

      {result, _log} = with_log(fn -> queued |> RunSettings.hold() |> RunSettings.build() end)
      assert result == {:end, :provider_gone}
    end
  end

  describe "form/5" do
    setup ctx do
      {:ok, loaded} = Connections.get_provider(ctx.scope, ctx.provider.public_id)
      {:ok, runtime} = Runtimes.fetch(@runtime)
      {:ok, description} = Providers.fetch("anthropic")

      resolution = %Resolution{
        connection_id: loaded.id,
        value_id: "main",
        model_id: "claude-opus-5-5",
        effort: "max",
        level: 5
      }

      %{loaded: loaded, runtime: runtime, description: description, resolution: resolution}
    end

    test "gives a provider with two APIs the API of the runtime's format", ctx do
      chat = %{
        "format" => "openai-chat",
        "endpoint" => "https://chat.example.com/v1",
        "auth" => %{"scheme" => "bearer"}
      }

      messages = Map.put(@messages, "key_prefixes", ["sk-ant-"])
      two = %{ctx.description | apis: [chat, messages]}

      assert {:ok, %{columns: %{provider_api: ^messages}, stored: stored}} =
               RunSettings.form(
                 ctx.resolution,
                 ctx.loaded,
                 {:ok, two},
                 ctx.runtime,
                 ctx.scope.workspace.id
               )

      refute Map.has_key?(stored, "endpoint")
    end

    test "ends runtime_unserved for a provider with no API the runtime speaks", ctx do
      chat = %{
        "format" => "openai-chat",
        "endpoint" => "https://chat.example.com/v1",
        "auth" => %{"scheme" => "bearer"}
      }

      basic = %{@messages | "auth" => %{"scheme" => "basic", "username" => "team"}}

      for apis <- [[chat], [basic]] do
        assert RunSettings.form(
                 ctx.resolution,
                 ctx.loaded,
                 {:ok, %{ctx.description | apis: apis}},
                 ctx.runtime,
                 ctx.scope.workspace.id
               ) == {:end, :runtime_unserved}
      end
    end

    test "ends provider_gone for a description the catalogue changed", ctx do
      for changed <- [{:error, :provider_changed}, {:error, :provider_unknown}] do
        assert RunSettings.form(
                 ctx.resolution,
                 ctx.loaded,
                 changed,
                 ctx.runtime,
                 ctx.scope.workspace.id
               ) == {:end, :provider_gone}
      end
    end

    test "ends key_gone for a key the provider no longer has", ctx do
      assert RunSettings.form(
               %{ctx.resolution | value_id: "gone"},
               ctx.loaded,
               {:ok, ctx.description},
               ctx.runtime,
               ctx.scope.workspace.id
             ) == {:end, :key_gone}
    end

    test "ends model_gone for an effort the runtime's list no longer has", ctx do
      runtime = %{ctx.runtime | effort_values: ~w(low medium high)}

      assert RunSettings.form(
               ctx.resolution,
               ctx.loaded,
               {:ok, ctx.description},
               runtime,
               ctx.scope.workspace.id
             ) == {:end, :model_gone}

      assert {:ok, %{stored: %{"effort" => "high", "provider_models" => [first | _]}}} =
               RunSettings.form(
                 %{ctx.resolution | effort: "high"},
                 ctx.loaded,
                 {:ok, ctx.description},
                 runtime,
                 ctx.scope.workspace.id
               )

      assert first == %{"id" => "claude-opus-5-5", "effort" => ~w(low medium high)}
    end

    test "lists each chosen model the description does not list once, after its models",
         ctx do
      resolution = %{
        ctx.resolution
        | model_id: "acme-large",
          effort: nil,
          tiers: %{
            "light" => %{"model" => "claude-haiku-5-5"},
            "fast" => %{"model" => "acme-small"},
            "thinking" => %{"model" => "acme-large"}
          }
      }

      assert {:ok, %{stored: %{"provider_models" => listed}}} =
               RunSettings.form(
                 resolution,
                 ctx.loaded,
                 {:ok, ctx.description},
                 ctx.runtime,
                 ctx.scope.workspace.id
               )

      assert Enum.map(listed, & &1["id"]) ==
               Enum.map(ctx.description.models, & &1["id"]) ++ ["acme-large", "acme-small"]

      # A description with no models: the chosen ones alone.
      assert {:ok, %{stored: %{"provider_models" => listed}}} =
               RunSettings.form(
                 resolution,
                 ctx.loaded,
                 {:ok, %{ctx.description | models: []}},
                 ctx.runtime,
                 ctx.scope.workspace.id
               )

      assert listed == [
               %{"id" => "acme-large"},
               %{"id" => "claude-haiku-5-5"},
               %{"id" => "acme-small"}
             ]

      # And no model at all: nothing to run on.
      assert RunSettings.form(
               %{resolution | model_id: nil},
               ctx.loaded,
               {:ok, ctx.description},
               ctx.runtime,
               ctx.scope.workspace.id
             ) == {:end, :model_gone}
    end
  end

  defp target(scope, path) do
    %Target{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      system: "forge.example.com",
      path: path,
      first_seen_at: DateTime.utc_now()
    }
  end
end
