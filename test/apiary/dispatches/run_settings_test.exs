defmodule Apiary.Dispatches.RunSettingsTest do
  # The run settings of an explore run a claim registers (`Apiary.Dispatches.RunSettings`):
  # what the model choices resolve to, the API of the provider the run uses, the causes
  # that end the run, and what the run keeps. The races with a provider's change are
  # `run_settings_races_test.exs`; the answer's 1 MiB limit is
  # `run_settings_budget_test.exs`; the order of the levels and the features off are
  # `run_settings_defaults_test.exs`.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Apiary.DispatchedRunsFixtures
  import Apiary.ModelChoicesFixtures, only: [every_tier: 1]
  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, ModelChoices, Repo, Stacks}
  alias Apiary.Connections.Connection
  alias Apiary.Dispatches.{Dispatch, DispatchRun, RunSettings}
  alias Apiary.Kinds.{Coded, Providers, Runtimes}
  alias Apiary.ModelChoices.{ModelChoice, Resolution}
  alias Apiary.Runs.{ModelKey, Projector, Run, Target}
  alias Apiary.Secrets.Value

  @moduletag needs: :factory

  # The catalogue's runtime, read from the list rather than named here.
  @runtime hd(Apiary.Kinds.Runtimes.list()).name

  @body ~s({"version":1,"time":"2026-10-18T12:00:00Z"})
  @harness "extends: {git: https://code.example.com/team/stacks, ref: main, path: core}\n"
  @workflow "explore-a-ticket"
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
      case Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now(), @body) do
        {:ok, %{registered: run, documents: documents}} -> {:ok, Map.put(documents, :run, run)}
        {:ok, :none} -> {:error, :gone}
        {:error, _reason} = error -> error
      end

    dispatch = Repo.one(from d in Dispatch, where: d.dispatch_run_id == ^queued.id)
    {answer, queued, dispatch}
  end

  # A fresh work item's explore run, queued, with no model providers, as a run queued
  # before runs kept them: the claim's filter passes it whatever its keys.
  defp queued_without_providers!(scope, attrs \\ %{}) do
    work_item = work_item_fixture(scope, attrs)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    providers!(queued, [])
  end

  # The run of the queue with `ids` as its model providers, written past the queue.
  defp providers!(%DispatchRun{id: id}, ids) do
    {1, _rows} =
      Repo.update_all(from(r in DispatchRun, where: r.id == ^id), set: [model_provider_ids: ids])

    Repo.get!(DispatchRun, id)
  end

  defp provider_ids(%DispatchRun{id: id}), do: Repo.get!(DispatchRun, id).model_provider_ids

  # A second Anthropic provider of the organisation, named `name`, with one key.
  defp other_provider!(scope, name) do
    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        name: name,
        keys: [%{value_id: "main", value: "sk-ant-#{String.downcase(name)}-0123456789"}]
      })

    provider
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

  # The value ids of the keys a run keeps, in its order.
  defp value_ids(%Run{} = run) do
    by_id = Map.new(Repo.all(Value), &{&1.id, &1.value_id})
    for %{secret_value_id: id} <- stored_keys(run), do: by_id[id]
  end

  # What the run keeps for a key's entry of the run configuration (`kept/1`), with every
  # field `attrs` does not set at its value for none.
  defp key(attrs),
    do:
      Map.merge(
        %{
          default_credential: false,
          resets_at: nil,
          schedule_resets_at: nil,
          cooldown_until: nil,
          use_up_to_percent: nil
        },
        Map.new(attrs)
      )

  # A key row's row id, credential name and what the claim wrote for the run
  # configuration.
  defp kept(%ModelKey{} = key),
    do:
      Map.take(
        key,
        ~w(secret_value_id name default_credential pause_for_s resets_at schedule_resets_at cooldown_until
           use_up_to_percent)a
      )

  defp value!(provider, value_id), do: key_value!(provider, value_id)
  defp state!(provider, value_id, attrs), do: key_state!(provider, value_id, attrs)

  defp choose!(scope, place, attrs) do
    {:ok, choice} = Apiary.ModelChoicesFixtures.put_choice(scope, place, attrs)
    choice
  end

  # A tier map with `entry` on every tier.
  defp all_tiers(entry), do: Map.new(Resolution.tiers(), &{&1, entry})

  # A fallback of `provider` with `tiers`, on the runtime named `runtime`.
  defp fallback(provider, tiers, runtime \\ @runtime),
    do: %{provider: provider.public_id, runtime: runtime, tiers: tiers}

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

    assert Repo.aggregate(
             from(r in Apiary.RunEventsFixtures.registered_runs(),
               where: r.dispatch_run_id == ^queued.id
             ),
             :count
           ) == 0
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

      assert %Run{run_settings: %{"runtime" => @runtime}, provider_connection_id: nil} =
               Repo.get!(Run, handed.run.id)

      assert stored_keys(handed.run) == []
    end
  end

  describe "a claim with a choice" do
    # Changed: the tiers sat on a workspace choice with no provider; now one choice sets all.
    test "of a run with no target reads the workspace and organisation levels alone", ctx do
      scope = with_domain(ctx.scope, "example")
      target = Repo.insert!(target(scope, "acme/shop"))
      thinking = List.last(Resolution.tiers())
      # The run's model and effort are those of the thinking tier.
      haiku_tiers =
        Map.put(every_tier("claude-haiku-5-5"), thinking, %{
          "model" => "claude-haiku-5-5",
          "effort" => "low"
        })

      choose!(scope, :organisation, %{
        provider: ctx.provider.public_id,
        model: "claude-opus-5-5",
        effort: "high",
        tiers: every_tier("claude-opus-5-5")
      })

      # The workspace's choice (level 5) comes before the organisation's default (level 6).
      choose!(scope, :workspace, %{
        provider: ctx.provider.public_id,
        model: "claude-haiku-5-5",
        effort: "low",
        tiers: haiku_tiers
      })

      # Levels 2 and 3 belong to a target: a run without one reads neither.
      choose!(scope, target, %{
        provider: ctx.provider.public_id,
        model: "claude-sonnet-5-5",
        tiers: every_tier("claude-sonnet-5-5")
      })

      {{:ok, handed}, _queued, _dispatch} =
        handover!(ctx, %{target_system: nil, target_path: nil})

      assert handed.target == nil

      assert settings(handed) == %{
               "runtime" => @runtime,
               "model" => "claude-haiku-5-5",
               "effort" => "low",
               "provider_models" => models(@efforts),
               "tiers" =>
                 Map.new(Resolution.tiers(), &{&1, "claude-haiku-5-5"})
                 |> Map.put(thinking, haiku_tiers[thinking])
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
        model: "claude-sonnet-5-5"
      })

      {{:ok, handed}, _queued, _dispatch} = handover!(ctx)

      assert %{"model" => "claude-sonnet-5-5"} = settings(handed)
      assert value_ids(Repo.get!(Run, handed.run.id)) == ["main", "spare"]
    end

    test "keeps the provider and the API the run uses on the run", ctx do
      %{provider: provider} = ctx
      choose!(ctx.scope, :workspace, %{provider: provider.public_id})

      {{:ok, handed}, _queued, _dispatch} = handover!(ctx)

      provider_id = provider.id
      secret_id = provider.secret_id

      assert %Run{provider_connection_id: ^provider_id} = run = Repo.get!(Run, handed.run.id)

      assert [_, _] = keys = stored_keys(run)

      for key <- keys do
        assert %ModelKey{
                 connection_id: ^provider_id,
                 secret_id: ^secret_id,
                 chain: "organisation",
                 api: @messages
               } = key
      end

      # The default key first, then the other by the order they were added.
      assert value_ids(run) == ["main", "spare"]

      assert run.run_settings == settings(handed)

      # No effort chosen: none is sent, and the runtime uses its default.
      assert settings(handed) == %{
               "runtime" => @runtime,
               "model" => "claude-opus-5-5",
               "provider_models" => models(@efforts),
               "tiers" => Map.new(Resolution.tiers(), &{&1, "claude-opus-5-5"})
             }
    end

    test "has no endpoint, no key, no secret id and no value id", ctx do
      %{provider: provider} = ctx
      choose!(ctx.scope, :workspace, %{provider: provider.public_id})

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

      assert [_ | _] = keys = stored_keys(handed.run)
      for %{api: api} <- keys, do: refute(Jason.encode!(api) =~ "sk-ant")
    end

    test "lists the description's models, then each chosen model it does not list", ctx do
      # A tier takes a model of the provider's suggestions that its description does not
      # list.
      [light, middle, thinking] = Resolution.tiers()

      tiers = %{
        light => "claude-haiku-5-5",
        middle => "claude-sonnet-4-6",
        thinking => "claude-opus-4-8"
      }

      choose!(ctx.scope, :workspace, %{provider: ctx.provider.public_id, tiers: tiers})

      {{:ok, handed}, _queued, _dispatch} = handover!(ctx)

      # The run's model is the thinking tier's, listed first of the models the description
      # does not list.
      assert settings(handed) == %{
               "runtime" => @runtime,
               "model" => "claude-opus-4-8",
               "provider_models" =>
                 models(@efforts) ++
                   [%{"id" => "claude-opus-4-8"}, %{"id" => "claude-sonnet-4-6"}],
               "tiers" => tiers
             }
    end

    # Changed: a tier model no list has went with the provider; now it is left out.
    test "lists the description's models, then the chosen model it does not list, and leaves out a tier model of no list",
         ctx do
      [_light, middle, _thinking] = Resolution.tiers()

      choice =
        choose!(ctx.scope, :workspace, %{provider: ctx.provider.public_id, model: "acme-large"})

      # Tiers a save refuses, written past its checks: no thinking tier, and a model of no
      # list.
      choice
      |> Ecto.Changeset.change(tiers: %{"light" => "claude-haiku-5-5", middle => "acme-small"})
      |> Repo.update!()

      {{:ok, handed}, _queued, _dispatch} = handover!(ctx)

      # `acme-small` is in neither the description nor the suggestions of Anthropic.
      assert settings(handed) == %{
               "runtime" => @runtime,
               "model" => "acme-large",
               "provider_models" => models(@efforts) ++ [%{"id" => "acme-large"}],
               "tiers" => %{"light" => "claude-haiku-5-5"}
             }
    end

    test "keeps an OpenRouter thinking model that only the suggestions list, and runs on it",
         ctx do
      {:ok, router} =
        Connections.create_provider(ctx.scope, %{
          provider: "openrouter",
          keys: [%{value_id: "main", value: "sk-or-run-settings-0123456789"}]
        })

      # A model of `priv/models/suggestions.json` that the description does not list.
      gemini = "google/gemini-3.1-pro-preview"
      described = Enum.map(Connections.provider_models(router), & &1["id"])
      refute gemini in described
      assert gemini in ModelChoices.resolution_provider(router).suggested

      choose!(ctx.scope, :workspace, %{provider: router.public_id, tiers: every_tier(gemini)})

      {{:ok, handed}, _queued, _dispatch} = handover!(ctx)

      assert settings(handed) == %{
               "runtime" => @runtime,
               "model" => gemini,
               "provider_models" =>
                 for(id <- described, do: %{"id" => id, "effort" => @efforts}) ++
                   [%{"id" => gemini}],
               "tiers" => Map.new(Resolution.tiers(), &{&1, gemini})
             }

      assert %Run{provider_connection_id: router_id} = Repo.get!(Run, handed.run.id)
      assert router_id == router.id
    end

    test "sends the thinking tier's model and effort as the run's", ctx do
      [_light, middle, _thinking] = Resolution.tiers()

      choose!(ctx.scope, :workspace, %{
        provider: ctx.provider.public_id,
        tiers: %{
          "thinking" => %{"model" => "claude-opus-5-5", "effort" => "max"},
          middle => "claude-sonnet-5-5",
          "light" => "claude-haiku-5-5"
        }
      })

      {{:ok, handed}, _queued, _dispatch} = handover!(ctx)

      assert %{
               "model" => "claude-opus-5-5",
               "effort" => "max",
               "tiers" => %{
                 "thinking" => %{"model" => "claude-opus-5-5", "effort" => "max"},
                 "light" => "claude-haiku-5-5"
               }
             } = settings(handed)
    end
  end

  describe "the model keys of a claim" do
    test "are every key of the provider, sent in tie order, each named by its place, with its resets",
         ctx do
      pid = ctx.provider.public_id
      choose!(ctx.scope, :workspace, %{provider: pid})

      # The default key has a known reset; the other has none, so it is the default model
      # provider credential. The run configuration sends them in tie order, the default
      # key first.
      reset = in_seconds(7200)
      state!(ctx.provider, "main", resets_at: reset)

      {:ok, _setting} =
        put_key_setting(ctx.scope, value!(ctx.provider, "spare"), %{pause_seconds: 300})

      {{:ok, handed}, _queued, _dispatch} = handover!(ctx)
      run = Repo.get!(Run, handed.run.id)

      assert Enum.map(stored_keys(run), &kept/1) == [
               key(
                 secret_value_id: value!(ctx.provider, "main").id,
                 name: "#{pid}-1",
                 pause_for_s: 60,
                 resets_at: reset
               ),
               key(
                 secret_value_id: value!(ctx.provider, "spare").id,
                 name: "#{pid}-2",
                 default_credential: true,
                 pause_for_s: 300
               )
             ]

      assert {:ok, %{name: default_name}} = Apiary.Runs.ProviderCredential.for_run(run)
      assert default_name == "#{pid}-2"

      # No key value, value id or key's row id in the documents' run settings.
      encoded = Jason.encode!(handed.run_settings)
      refute encoded =~ value!(ctx.provider, "spare").id
      refute encoded =~ "sk-ant"
    end

    test "keep the Pause for of the claim after the key's setting changes", ctx do
      choose!(ctx.scope, :workspace, %{provider: ctx.provider.public_id})
      spare = value!(ctx.provider, "spare")
      {:ok, _setting} = put_key_setting(ctx.scope, spare, %{pause_seconds: 300})

      {{:ok, handed}, _queued, _dispatch} = handover!(ctx)
      run = Repo.get!(Run, handed.run.id)

      # A member sets the key's Pause for to 15 minutes after the claim.
      {:ok, _setting} = put_key_setting(ctx.scope, spare, %{pause_seconds: 900})

      assert [%ModelKey{pause_for_s: 300}] =
               Enum.filter(stored_keys(run), &(&1.secret_value_id == spare.id))

      assert {:ok, credential} = Apiary.Runs.ProviderCredential.for_run(run)
      assert %{entry: entry} = Enum.find(credential.keys, &(&1.secret_value_id == spare.id))
      assert entry["pause_for_s"] == 300
    end

    test "send a key in cooldown after the free keys, never as the default model provider credential",
         ctx do
      pid = ctx.provider.public_id
      choose!(ctx.scope, :workspace, %{provider: pid})
      until = in_seconds(3600)
      state!(ctx.provider, "main", until: until)

      {{:ok, handed}, _queued, _dispatch} = handover!(ctx)
      [default, cooling] = Enum.map(stored_keys(handed.run), &kept/1)

      assert default ==
               key(
                 secret_value_id: value!(ctx.provider, "spare").id,
                 name: "#{pid}-1",
                 default_credential: true,
                 pause_for_s: 60
               )

      assert cooling ==
               key(
                 secret_value_id: value!(ctx.provider, "main").id,
                 name: "#{pid}-2",
                 pause_for_s: 60,
                 resets_at: until,
                 cooldown_until: until
               )
    end

    test "are at most 6, the free keys first", ctx do
      {:ok, many} =
        Connections.create_provider(ctx.scope, %{
          provider: "anthropic",
          keys: for(n <- 1..8, do: %{value_id: "key-#{n}", value: "sk-ant-many-#{n}"})
        })

      choose!(ctx.scope, :workspace, %{provider: many.public_id})
      state!(many, "key-1", until: in_seconds(600))
      state!(many, "key-2", until: in_seconds(300))

      {{:ok, handed}, _queued, _dispatch} = handover!(ctx)
      run = Repo.get!(Run, handed.run.id)

      assert value_ids(run) == ~w(key-3 key-4 key-5 key-6 key-7 key-8)

      assert Enum.map(stored_keys(run), & &1.name) ==
               for(n <- 1..6, do: "#{many.public_id}-#{n}")
    end

    test "come from the first fallback with a free key, with its runtime and tiers, while every key of the provider is in cooldown",
         ctx do
      {:ok, cooling} =
        Connections.create_provider(ctx.scope, %{
          provider: "anthropic",
          name: "Cooling keys",
          keys: [%{value_id: "main", value: "sk-ant-cooling-0123456789"}]
        })

      {:ok, free} =
        Connections.create_provider(ctx.scope, %{
          provider: "anthropic",
          name: "Free keys",
          keys: [%{value_id: "main", value: "sk-ant-free-0123456789"}]
        })

      choose!(ctx.scope, :workspace, %{
        provider: ctx.provider.public_id,
        model: "claude-opus-5-5",
        fallbacks: [
          fallback(cooling, all_tiers(%{"model" => "claude-opus-5-5", "effort" => "max"})),
          fallback(free, all_tiers(%{"model" => "claude-sonnet-5-5", "effort" => "high"}))
        ]
      })

      for {provider, key} <- [{ctx.provider, "main"}, {ctx.provider, "spare"}, {cooling, "main"}],
          do: state!(provider, key, until: in_seconds(3600))

      {{:ok, handed}, queued, _dispatch} = handover!(ctx)

      assert queued.model_provider_ids == [ctx.provider.id, cooling.id, free.id]

      assert %{
               "runtime" => @runtime,
               "model" => "claude-sonnet-5-5",
               "effort" => "high",
               "tiers" => tiers
             } = settings(handed)

      # The fallback's tiers, its thinking tier as the run's model and effort.
      assert tiers == all_tiers(%{"model" => "claude-sonnet-5-5", "effort" => "high"})

      free_id = free.id

      assert %Run{provider_connection_id: ^free_id} = run = Repo.get!(Run, handed.run.id)
      assert [%ModelKey{name: name} = key] = stored_keys(run)

      assert name == "#{free.public_id}-1"
      assert key.secret_value_id == value!(free, "main").id
      assert key.pause_for_s == 60
    end

    test "come from a fallback on another runtime, with that runtime, an API it takes and the fallback's tiers",
         ctx do
      release = Runtimes.list() |> Enum.find(&(&1.name == "claude"))

      # A runtime that takes only a bearer key: the API of the choice's provider, with its
      # x-api-key header, is not one it takes; OpenRouter's is.
      bearer = %{
        release
        | name: release.name <> "-bearer",
          title: release.title <> " bearer",
          model_keys: Enum.filter(release.model_keys, &(&1["auth"] == %{"scheme" => "bearer"}))
      }

      :ok = Runtimes.put_test_list([release, bearer])
      {:ok, anthropic} = Providers.fetch("anthropic")
      assert {:error, _refusal} = Providers.api(anthropic, bearer)

      {:ok, router} =
        Connections.create_provider(ctx.scope, %{
          provider: "openrouter",
          keys: [%{value_id: "main", value: "sk-or-fallback-0123456789"}]
        })

      tiers = %{
        "light" => "anthropic/claude-haiku-5.5",
        "balanced" => "anthropic/claude-sonnet-5.5",
        "thinking" => %{"model" => "anthropic/claude-opus-5.5", "effort" => "high"}
      }

      choose!(ctx.scope, :workspace, %{
        provider: ctx.provider.public_id,
        runtime: release.name,
        tiers: all_tiers("claude-opus-5-5"),
        fallbacks: [fallback(router, tiers, bearer.name)]
      })

      # While a key of the choice's provider is free, the run uses it on its runtime.
      {{:ok, handed}, _queued, _dispatch} = handover!(ctx)
      assert %{"runtime" => runtime, "model" => "claude-opus-5-5"} = settings(handed)
      assert runtime == release.name

      # With every key in cooldown, the run takes the fallback.
      for key <- ["main", "spare"], do: state!(ctx.provider, key, until: in_seconds(3600))
      {{:ok, handed}, queued, _dispatch} = handover!(ctx, %{external_ref: "acme/shop#14"})

      assert queued.model_provider_ids == [ctx.provider.id, router.id]

      assert %{
               "runtime" => runtime,
               "model" => "anthropic/claude-opus-5.5",
               "effort" => "high",
               "tiers" => sent
             } = settings(handed)

      assert runtime == bearer.name
      assert sent == tiers

      run = Repo.get!(Run, handed.run.id)
      assert run.provider_connection_id == router.id
      assert run.run_settings["runtime"] == bearer.name

      # The API of the run's keys is the fallback provider's, on the fallback's runtime.
      assert [%ModelKey{default_credential: true, api: api} | _rest] = stored_keys(run)
      assert api["format"] in Runtimes.formats(bearer)
      assert api["auth"] == %{"scheme" => "bearer"}
      assert api["endpoint"] == "https://openrouter.ai/api"
    end

    test "leave the run waiting while every key of the provider and its fallbacks is in cooldown",
         ctx do
      # A run with no providers, as one queued before runs kept them: the claim's filter
      # passes it, and the claim's check of the keys leaves it waiting.
      choose!(ctx.scope, :workspace, %{provider: ctx.provider.public_id})
      for key <- ["main", "spare"], do: state!(ctx.provider, key, until: in_seconds(3600))
      queued = queued_without_providers!(ctx.scope)

      assert {:ok, :none} =
               Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now(), @body)

      assert %DispatchRun{state: :waiting} = Repo.get!(DispatchRun, queued.id)

      assert Repo.aggregate(from(d in Dispatch, where: d.dispatch_run_id == ^queued.id), :count) ==
               0

      # Once a key's cooldown ends, the next claim takes the run on that key.
      state!(ctx.provider, "spare", until: in_seconds(-1))

      assert {:ok, %{registered: run}} =
               Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now(), @body)

      assert run.dispatch_run_id == queued.id
      assert value_ids(Repo.get!(Run, run.id)) == ["spare", "main"]
    end

    test "leave a run that waits for its keys unclaimed by the next claims", ctx do
      choose!(ctx.scope, :workspace, %{provider: ctx.provider.public_id})
      until = in_seconds(3600)
      for key <- ["main", "spare"], do: state!(ctx.provider, key, until: until)
      queued = queued_without_providers!(ctx.scope)

      handler = "run-settings-claims-#{System.unique_integer()}"
      parent = self()

      :telemetry.attach(
        handler,
        [:apiary, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == parent and meta.source == "dispatches" and
               String.starts_with?(meta.query, "INSERT"),
             do: send(parent, :dispatch_inserted)
        end,
        nil
      )

      try do
        for _claim <- 1..3 do
          assert {:ok, :none} =
                   Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now(), @body)
        end
      after
        :telemetry.detach(handler)
      end

      # The first claim takes the run and leaves it waiting for the provider; the next two
      # pass it by.
      assert_received :dispatch_inserted
      refute_received :dispatch_inserted

      waiting = Repo.get!(DispatchRun, queued.id)
      assert %DispatchRun{state: :waiting} = waiting
      assert waiting.model_provider_ids == [ctx.provider.id]
      assert waiting.updated_at == queued.updated_at
      assert {:cooldown, name, at} = Apiary.Runs.Waiting.reason(waiting)
      assert name == ctx.provider.name
      assert DateTime.compare(at, until) == :eq
    end

    test "end the run for its cause before leaving it waiting for its keys", ctx do
      # A run with no providers, so the claim's filter passes it, as in the test above.
      choose!(ctx.scope, :workspace, %{provider: ctx.provider.public_id})
      for key <- ["main", "spare"], do: state!(ctx.provider, key, until: in_seconds(3600))
      queued = queued_without_providers!(ctx.scope)

      # A second active key of the gateway, without the stored-secrets flag.
      Apiary.AccessKeysFixtures.node_key_fixture(ctx.scope, ctx.gateway)

      assert {:ok, :none} =
               Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now(), @body)

      dispatch = Repo.one!(from d in Dispatch, where: d.dispatch_run_id == ^queued.id)
      ended!(queued, dispatch, :secrets_not_allowed)
    end

    test "are never built with a default model provider credential in cooldown", ctx do
      choose!(ctx.scope, :workspace, %{provider: ctx.provider.public_id})

      for {cooled, n} <- Enum.with_index([[], ["main"], ["spare"]]) do
        for key <- ["main", "spare"], do: state!(ctx.provider, key, until: in_seconds(-1))
        for key <- cooled, do: state!(ctx.provider, key, until: in_seconds(3600))

        {{:ok, handed}, _queued, _dispatch} =
          handover!(ctx, %{external_ref: "acme/shop##{50 + n}"})

        [default | _rest] = stored_keys(handed.run)

        assert default.cooldown_until == nil, inspect(cooled)
      end
    end
  end

  describe "the keys of a claim under a workflow's override" do
    # The run's workflow, from the workspace's stack row, and a provider for the override.
    setup ctx do
      {:ok, _stack} =
        Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace, @workflow}, @harness)

      %{override: other_provider!(ctx.scope, "Override keys")}
    end

    defp override!(ctx, provider, tiers) do
      choose!(ctx.scope, {:workspace, @workflow}, %{provider: provider.public_id, tiers: tiers})
    end

    # What a claim at this moment builds for a fresh run of the queue, without the claim.
    defp built!(ctx) do
      work_item = work_item_fixture(ctx.scope, %{external_ref: "acme/shop##{unique()}"})
      {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
      {queued, RunSettings.build(RunSettings.hold(queued), Dispatches.now())}
    end

    defp unique, do: System.unique_integer([:positive])

    test "use the override's provider and tiers while one of its keys is free", ctx do
      override!(ctx, ctx.override, all_tiers("claude-sonnet-5-5"))

      choose!(ctx.scope, :workspace, %{
        provider: ctx.provider.public_id,
        tiers: all_tiers("claude-opus-5-5")
      })

      {{:ok, handed}, queued, _dispatch} = handover!(ctx)

      assert queued.model_provider_ids == [ctx.override.id, ctx.provider.id]
      assert Repo.get!(Run, handed.run.id).provider_connection_id == ctx.override.id

      assert %{"model" => "claude-sonnet-5-5", "tiers" => tiers} = settings(handed)
      assert tiers == all_tiers("claude-sonnet-5-5")
    end

    test "fall to the workspace default, with its provider and tiers, while every key of the override is in cooldown",
         ctx do
      override!(ctx, ctx.override, all_tiers("claude-sonnet-5-5"))
      [_light, middle, _thinking] = Resolution.tiers()

      choose!(ctx.scope, :workspace, %{
        provider: ctx.provider.public_id,
        tiers: %{
          "thinking" => %{"model" => "claude-opus-5-5", "effort" => "high"},
          middle => "claude-sonnet-5-5",
          "light" => "claude-haiku-5-5"
        }
      })

      state!(ctx.override, "main", until: in_seconds(3600))

      {{:ok, handed}, queued, _dispatch} = handover!(ctx)

      # The queue keeps the override's provider, then the default's, for the claim's filter.
      assert queued.model_provider_ids == [ctx.override.id, ctx.provider.id]

      run = Repo.get!(Run, handed.run.id)
      assert run.provider_connection_id == ctx.provider.id
      assert value_ids(run) == ["main", "spare"]

      assert %{"model" => "claude-opus-5-5", "effort" => "high", "tiers" => tiers} =
               settings(handed)

      assert tiers == %{
               "thinking" => %{"model" => "claude-opus-5-5", "effort" => "high"},
               middle => "claude-sonnet-5-5",
               "light" => "claude-haiku-5-5"
             }
    end

    test "fall to the default's fallbacks, not the override's stored ones, while the default cools too",
         ctx do
      free = other_provider!(ctx.scope, "Free keys")
      unread = other_provider!(ctx.scope, "Unread keys")

      # An override stored with a fallback, past the save: it is not read.
      override = override!(ctx, ctx.override, all_tiers("claude-sonnet-5-5"))

      Repo.insert!(%Apiary.ModelChoices.Fallback{
        organisation_id: ctx.scope.organisation.id,
        model_choice_id: override.id,
        connection_id: unread.id,
        position: 0,
        runtime: @runtime,
        tiers: all_tiers("claude-opus-5-5")
      })

      choose!(ctx.scope, :workspace, %{
        provider: ctx.provider.public_id,
        tiers: all_tiers("claude-opus-5-5"),
        fallbacks: [
          fallback(free, all_tiers(%{"model" => "claude-haiku-5-5", "effort" => "low"}))
        ]
      })

      for {provider, key} <- [
            {ctx.override, "main"},
            {ctx.provider, "main"},
            {ctx.provider, "spare"}
          ],
          do: state!(provider, key, until: in_seconds(3600))

      {{:ok, handed}, queued, _dispatch} = handover!(ctx)

      assert queued.model_provider_ids == [ctx.override.id, ctx.provider.id, free.id]
      assert Repo.get!(Run, handed.run.id).provider_connection_id == free.id

      assert %{"model" => "claude-haiku-5-5", "effort" => "low", "tiers" => tiers} =
               settings(handed)

      assert tiers == all_tiers(%{"model" => "claude-haiku-5-5", "effort" => "low"})
    end

    test "leave the run waiting for the override's and the default's providers", ctx do
      override!(ctx, ctx.override, all_tiers("claude-sonnet-5-5"))

      choose!(ctx.scope, :workspace, %{
        provider: ctx.provider.public_id,
        tiers: all_tiers("claude-opus-5-5")
      })

      for {provider, key} <- [
            {ctx.override, "main"},
            {ctx.provider, "main"},
            {ctx.provider, "spare"}
          ],
          do: state!(provider, key, until: in_seconds(3600))

      assert {_queued, {:cooling, _built, ids}} = built!(ctx)
      assert ids == [ctx.override.id, ctx.provider.id]
    end

    test "wait for a provider once where the override and the default share it, then take the default's fallback",
         ctx do
      free = other_provider!(ctx.scope, "Free keys")
      override!(ctx, ctx.provider, all_tiers("claude-sonnet-5-5"))

      choose!(ctx.scope, :workspace, %{
        provider: ctx.provider.public_id,
        tiers: all_tiers("claude-opus-5-5"),
        fallbacks: [fallback(free, all_tiers("claude-haiku-5-5"))]
      })

      for key <- ["main", "spare"], do: state!(ctx.provider, key, until: in_seconds(3600))
      state!(free, "main", until: in_seconds(3600))

      assert {queued, {:cooling, _built, ids}} = built!(ctx)
      assert ids == [ctx.provider.id, free.id]
      assert queued.model_provider_ids == [ctx.provider.id, free.id]

      # With the fallback's key free, the run takes the fallback.
      state!(free, "main", until: in_seconds(-1))
      assert {_queued, {:ok, %{columns: columns, stored: stored}}} = built!(ctx)
      assert columns.provider_connection_id == free.id
      assert stored["tiers"] == all_tiers("claude-haiku-5-5")
    end

    test "take the next fallback after one that names the override's provider, whose keys are in cooldown",
         ctx do
      free = other_provider!(ctx.scope, "Free keys")
      override!(ctx, ctx.override, all_tiers("claude-sonnet-5-5"))

      choose!(ctx.scope, :workspace, %{
        provider: ctx.provider.public_id,
        tiers: all_tiers("claude-opus-5-5"),
        fallbacks: [
          fallback(ctx.override, all_tiers("claude-opus-5-5")),
          fallback(free, all_tiers("claude-haiku-5-5"))
        ]
      })

      for {provider, key} <- [
            {ctx.override, "main"},
            {ctx.provider, "main"},
            {ctx.provider, "spare"}
          ],
          do: state!(provider, key, until: in_seconds(3600))

      assert {queued, {:ok, %{columns: columns, stored: stored}}} = built!(ctx)
      assert queued.model_provider_ids == [ctx.override.id, ctx.provider.id, free.id]
      assert columns.provider_connection_id == free.id
      assert stored["model"] == "claude-haiku-5-5"

      state!(free, "main", until: in_seconds(3600))
      assert {_queued, {:cooling, _built, ids}} = built!(ctx)
      assert ids == [ctx.override.id, ctx.provider.id, free.id]
    end

    test "never fall to the default while a lock of the workspace beats the override", ctx do
      override!(ctx, ctx.override, all_tiers("claude-sonnet-5-5"))

      locked =
        choose!(ctx.scope, :workspace, %{
          provider: ctx.provider.public_id,
          tiers: all_tiers("claude-opus-5-5")
        })

      Repo.update!(Ecto.Changeset.change(locked, locked: true))

      {{:ok, handed}, queued, _dispatch} = handover!(ctx)

      assert queued.model_provider_ids == [ctx.provider.id]
      assert Repo.get!(Run, handed.run.id).provider_connection_id == ctx.provider.id
      assert %{"model" => "claude-opus-5-5"} = settings(handed)

      # With every key of the locked provider in cooldown, the run waits for it alone: the
      # override's provider, whose key is free, is not taken.
      for key <- ["main", "spare"], do: state!(ctx.provider, key, until: in_seconds(3600))

      provider_id = ctx.provider.id
      assert {queued, {:cooling, _built, [^provider_id]}} = built!(ctx)
      assert queued.model_provider_ids == [provider_id]
    end
  end

  describe "the model providers of a waiting run" do
    # A run queued on the provider while every key of it is in cooldown for 7 days.
    setup ctx do
      choose!(ctx.scope, :workspace, %{provider: ctx.provider.public_id})
      cooling!(ctx.provider, in_seconds(7 * 86_400))
      work_item = work_item_fixture(ctx.scope)
      {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
      assert queued.model_provider_ids == [ctx.provider.id]
      assert {:ok, :none} = walked_claim(ctx.key, Dispatches.now(), @body)
      %{queued: queued}
    end

    test "follow a switch of the choice to another provider, and the run is claimed first",
         ctx do
      other = other_provider!(ctx.scope, "Spare keys")
      choose!(ctx.scope, :workspace, %{provider: other.public_id})
      assert provider_ids(ctx.queued) == [other.id]

      # A newer run waits behind it.
      newer = work_item_fixture(ctx.scope, %{external_ref: "acme/shop#13"})
      {:ok, _newer} = Repo.transact(fn -> Dispatches.queue(newer, 1) end)

      assert {:ok, %{registered: run}} = walked_claim(ctx.key, Dispatches.now(), @body)
      assert run.dispatch_run_id == ctx.queued.id
      assert Repo.get!(Run, run.id).provider_connection_id == other.id
    end

    test "follow a fallback added to the choice", ctx do
      other = other_provider!(ctx.scope, "Spare keys")

      choose!(ctx.scope, :workspace, %{
        provider: ctx.provider.public_id,
        fallbacks: [
          fallback(other, all_tiers(%{"model" => "claude-opus-5-5", "effort" => "high"}))
        ]
      })

      assert provider_ids(ctx.queued) == [ctx.provider.id, other.id]

      assert {:ok, %{registered: run}} = walked_claim(ctx.key, Dispatches.now(), @body)
      assert run.dispatch_run_id == ctx.queued.id
      assert Repo.get!(Run, run.id).provider_connection_id == other.id
    end

    test "follow a choice removed, and the run is claimed", ctx do
      {:ok, _choice} = ModelChoices.delete_choice(ctx.scope, :workspace)
      assert provider_ids(ctx.queued) == []

      assert {:ok, %{registered: run}} = walked_claim(ctx.key, Dispatches.now(), @body)
      assert run.dispatch_run_id == ctx.queued.id
    end

    test "are set again when a provider is added, changed or deleted", ctx do
      stale = other_provider!(ctx.scope, "Stale keys")

      providers!(ctx.queued, [stale.id])
      _added = other_provider!(ctx.scope, "Added keys")
      assert provider_ids(ctx.queued) == [ctx.provider.id]

      providers!(ctx.queued, [stale.id])
      {:ok, _changed} = Connections.update_provider(ctx.scope, stale, %{name: "Renamed keys"})
      assert provider_ids(ctx.queued) == [ctx.provider.id]

      providers!(ctx.queued, [stale.id])
      {:ok, _deleted} = Connections.delete_provider(ctx.scope, stale)
      assert provider_ids(ctx.queued) == [ctx.provider.id]
    end

    test "leave a newer run free to be claimed after the oldest run waits again", ctx do
      # The oldest run passes the claim's filter, and the claim's check of the keys leaves
      # it waiting for the provider.
      providers!(ctx.queued, [])
      assert {:ok, :none} = walked_claim(ctx.key, Dispatches.now(), @body)
      assert provider_ids(ctx.queued) == [ctx.provider.id]

      # A newer run, of another target whose choice has a provider with a free key.
      other = other_provider!(ctx.scope, "Spare keys")
      target = Repo.insert!(target(ctx.scope, "acme/storefront"))
      choose!(ctx.scope, target, %{provider: other.public_id})

      newer =
        work_item_fixture(ctx.scope, %{
          external_ref: "acme/storefront#1",
          target_path: "acme/storefront"
        })

      {:ok, newer} = Repo.transact(fn -> Dispatches.queue(newer, 1) end)
      assert newer.model_provider_ids == [other.id]

      assert {:ok, %{registered: run}} = walked_claim(ctx.key, Dispatches.now(), @body)
      assert run.dispatch_run_id == newer.id
      assert %DispatchRun{state: :waiting} = Repo.get!(DispatchRun, ctx.queued.id)
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

      # The target's level, where a choice may map no tier: no thinking tier, and no
      # default model.
      target = Repo.insert!(target(ctx.scope, "acme/shop"))
      choose!(ctx.scope, target, %{provider: litellm.public_id})

      {answer, queued, dispatch} = handover!(ctx)
      assert answer == {:error, :gone}
      ended!(queued, dispatch, :model_gone)
    end

    test "model_gone for a thinking entry that does not go with the provider", ctx do
      # Past the save, which refuses each: a model in no list, and an effort it lacks.
      for {thinking, n} <-
            Enum.with_index([
              "acme-large",
              %{"model" => "claude-opus-5-5", "effort" => "turbo"}
            ]) do
        Repo.delete_all(ModelChoice)

        Repo.insert!(%ModelChoice{
          organisation_id: ctx.scope.organisation.id,
          workspace_id: ctx.scope.workspace.id,
          connection_id: ctx.provider.id,
          model_id: "claude-opus-5-5",
          effort: "high",
          tiers: %{"thinking" => thinking, "light" => "claude-haiku-5-5"}
        })

        {answer, queued, dispatch} = handover!(ctx, %{external_ref: "acme/shop##{40 + n}"})
        assert answer == {:error, :gone}, inspect(thinking)
        ended!(queued, dispatch, :model_gone)
      end
    end

    test "never for a model the description does not list", ctx do
      # The target's level, where a choice may map no tier, so the run takes its model.
      target = Repo.insert!(target(ctx.scope, "acme/shop"))
      choose!(ctx.scope, target, %{provider: ctx.provider.public_id, model: "acme-large"})

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

      assert [
               %ModelKey{
                 api: %{
                   "format" => "anthropic-messages",
                   "endpoint" => "https://litellm.example.com/team",
                   "auth" => %{"scheme" => "bearer"}
                 }
               }
             ] = stored_keys(handed.run)
    end

    test "is written once: a later change of the address or a rebuild keeps the run's", ctx do
      {{:ok, handed}, _queued, _dispatch} = handover!(ctx)
      run = Repo.get!(Run, handed.run.id)
      keys = stored_keys(run)

      {:ok, _litellm} =
        Connections.update_provider(ctx.scope, ctx.litellm, %{
          settings: %{"address" => "https://models.example.com"}
        })

      assert {:ok, _rebuilt} = Projector.rebuild(run)

      assert [%ModelKey{api: %{"endpoint" => "https://litellm.example.com/team"}}] =
               stored_keys(run)

      assert {Repo.get!(Run, run.id).run_settings, stored_keys(run)} == {run.run_settings, keys}

      # The next run takes the address as it is now.
      {{:ok, next}, _queued, _dispatch} = handover!(ctx, %{external_ref: "acme/shop#13"})

      assert [%ModelKey{api: %{"endpoint" => "https://models.example.com"}}] =
               stored_keys(next.run)
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

      assert %Run{provider_connection_id: nil, run_settings: %{"model" => "claude-opus-5-5"}} =
               Repo.get!(Run, run.id)

      assert [%ModelKey{name: name} | _] = keys = stored_keys(run)

      for key <- keys,
          do: assert(%ModelKey{connection_id: nil, secret_id: nil, api: @messages} = key)

      assert name == "#{ctx.provider.public_id}-1"
    end

    test "keeps refusing with the choices alone while no run uses it", ctx do
      choose!(ctx.scope, :workspace, %{provider: ctx.provider.public_id})

      assert {:error, {:model_in_use, [%{level: 5}]}} =
               Connections.delete_provider(ctx.scope, ctx.provider)
    end
  end

  describe "form/5" do
    setup ctx do
      {:ok, loaded} = Connections.get_provider(ctx.scope, ctx.provider.public_id)
      {:ok, runtime} = Runtimes.fetch(@runtime)
      {:ok, description} = Providers.fetch("anthropic")

      resolution = %Resolution{
        connection_id: loaded.id,
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

    test "ends key_gone for a provider with no key", ctx do
      no_key = %{ctx.loaded | secret: %{ctx.loaded.secret | values: []}}

      assert RunSettings.form(
               ctx.resolution,
               no_key,
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
            "balanced" => %{"model" => "acme-small"},
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
