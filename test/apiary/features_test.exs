defmodule Apiary.FeaturesTest do
  use ExUnit.Case, async: true

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Features
  alias Apiary.Organisations.{Organisation, Workspace}

  describe "parse/1, the value of QORY_FEATURES" do
    test "unset, empty or blank is every feature but the opt-in ones" do
      for value <- [nil, "", "  ", " , "] do
        assert Features.parse(value, registry: nil) == {:ok, Features.all() -- Features.opt_in()}
      end
    end

    test "a list is taken in the order of all/0, with spaces and repeats forgiven" do
      assert Features.parse("security, observability,security") ==
               {:ok, [:observability, :security]}

      assert Features.parse("observability") == {:ok, [:observability]}
    end

    test "an unknown name is refused, naming it and not the features there are" do
      assert {:error, reason} = Features.parse("observability,dispatch")
      assert reason =~ "unknown feature dispatch; the Install guide at /docs lists the features"
      refute reason =~ "security"

      assert {:error, reason} = Features.parse("Observability,records")
      assert reason =~ "unknown features Observability, records"
    end

    test "a feature without the features it needs is refused, observability aside" do
      for feature <- Features.all(),
          need = Enum.find(Features.needs(feature), &(&1 != :observability)) do
        assert {:error, reason} = Features.parse(to_string(feature))
        assert reason == "#{feature} needs #{need}, which is left out"
      end
    end

    test "observability is on whatever the value leaves out" do
      default = Features.all() -- Features.opt_in()
      assert Features.parse("all-observability", registry: nil) == {:ok, default}

      every = Enum.join(Features.all(), ",")
      assert Features.parse("all-" <> every) == {:ok, [:observability]}

      assert Features.parse("security") == {:ok, [:observability, :security]}

      for feature <- Features.all(), Features.needs(feature) in [[], [:observability]] do
        assert {:ok, features} = Features.parse(to_string(feature))
        assert features == Enum.uniq([:observability, feature])
      end
    end

    test "all is every feature but the opt-in ones, and all- those but the ones it names" do
      default = Features.all() -- Features.opt_in()
      assert Features.parse("all", registry: nil) == {:ok, default}
      assert Features.parse(" all ", registry: nil) == {:ok, default}

      # A feature nothing else needs can be left out on its own; one another needs takes
      # that one with it.
      leaf = Enum.find(default -- [:observability], &(not needed?(&1, default)))
      assert Features.parse("all-#{leaf}", registry: nil) == {:ok, default -- [leaf]}

      all_but_the_record = Enum.join(Features.all() -- [:observability], ", ")
      assert Features.parse("all-" <> all_but_the_record) == {:ok, [:observability]}
    end

    test "all- is refused for a name that is no feature, for none, and for leaving out a need" do
      assert {:error, reason} = Features.parse("all-dispatch")
      assert reason =~ "unknown feature dispatch; the Install guide"

      assert {:error, reason} = Features.parse("all-security-observability")
      assert reason =~ "unknown feature security-observability; the Install guide"

      for value <- ["all-", "all-,"] do
        assert {:error, reason} = Features.parse(value)
        assert reason =~ ~s(unknown feature ""; the Install guide)
      end

      assert {:error, reason} = Features.parse("all-security")
      assert reason == "secrets needs security, which is left out"
    end

    test "registry is opt-in: on with all where QORY_REGISTRY is set, else where a list has it" do
      assert Features.opt_in() -- Enum.map(Apiary.Edition.features(), &elem(&1, 0)) ==
               [:registry]

      default = Features.all() -- Features.opt_in()

      for value <- [nil, "", "  ", "all", "all-path_rules"] do
        assert {:ok, features} = Features.parse(value, registry: "registry.example.com")
        assert :registry in features, inspect(value)
        assert features -- [:registry] == elem(Features.parse(value, registry: nil), 1)

        for setting <- [nil, "", "  "] do
          assert {:ok, features} = Features.parse(value, registry: setting)
          refute :registry in features, inspect({value, setting})
        end
      end

      # A malformed address turns it on too, so the registry's check at boot stops the boot
      # with its fix (`Apiary.Registry.boot!/0`).
      assert Features.parse("all", registry: "https://registry.example.com") ==
               {:ok, Features.all() -- (Features.opt_in() -- [:registry])}

      # A list keeps it off unless it names it, whether QORY_REGISTRY is set or not.
      assert Features.parse("observability,security", registry: "registry.example.com") ==
               {:ok, [:observability, :security]}

      assert Features.parse("observability,security,registry", registry: nil) ==
               {:ok, [:observability, :security, :registry]}

      assert Features.parse("all-registry", registry: "registry.example.com") == {:ok, default}

      assert Features.parse("all-security,secrets,path_rules,factory,workflow_model",
               registry: "registry.example.com"
             ) == {:error, "registry needs security, which is left out"}

      # Without the option, the setting is the instance's, as config/runtime.exs keeps it.
      setting = Application.get_env(:apiary, :registry_setting)
      assert Features.parse("all") == Features.parse("all", registry: setting)
      assert Features.parse(nil) == Features.parse(nil, registry: setting)
    end

    test "secrets is on by default and needs security: off where a list leaves it out" do
      refute :secrets in Features.opt_in()
      assert Features.needs(:secrets) == [:security]

      for value <- [nil, "", "  ", "all", "all-path_rules"] do
        assert {:ok, features} = Features.parse(value, registry: nil)
        assert :secrets in features, inspect(value)
      end

      assert Features.parse("observability,security") == {:ok, [:observability, :security]}

      assert Features.parse("observability,security,secrets") ==
               {:ok, [:observability, :security, :secrets]}

      assert Features.parse("secrets, security, observability") ==
               {:ok, [:observability, :security, :secrets]}

      assert Features.parse("all-secrets", registry: nil) ==
               {:error, "factory needs secrets, which is left out"}
    end

    test "path_rules is on by default and needs security: off where a list leaves it out" do
      refute :path_rules in Features.opt_in()
      assert Features.needs(:path_rules) == [:security]

      for value <- [nil, "", "  ", "all", "all-workflow_model"] do
        assert {:ok, features} = Features.parse(value, registry: nil)
        assert :path_rules in features, inspect(value)
      end

      for value <- ["all-path_rules", "observability,security"] do
        assert {:ok, features} = Features.parse(value, registry: nil)
        refute :path_rules in features, inspect(value)
      end

      assert Features.parse("observability,security,path_rules") ==
               {:ok, [:observability, :security, :path_rules]}

      assert Features.parse("path_rules,secrets,security,observability") ==
               {:ok, [:observability, :security, :secrets, :path_rules]}

      assert Features.parse("observability,path_rules") ==
               {:error, "path_rules needs security, which is left out"}
    end

    test "workflow_model is on by default and needs factory and what it needs: off where a list leaves it out" do
      refute :workflow_model in Features.opt_in()
      assert Features.needs(:workflow_model) == [:observability, :security, :secrets, :factory]
      assert :workflow_model in Features.documented()

      for value <- [nil, "", "all", "all-path_rules"] do
        assert {:ok, features} = Features.parse(value, registry: nil)
        assert :workflow_model in features, inspect(value)
      end

      for value <- ["all-workflow_model", "observability,security,secrets,factory"] do
        assert {:ok, features} = Features.parse(value, registry: nil)
        refute :workflow_model in features, inspect(value)
      end

      assert Features.parse("observability,security,secrets,factory,workflow_model") ==
               {:ok, [:observability, :security, :secrets, :factory, :workflow_model]}

      assert Features.parse("observability,security,secrets,workflow_model") ==
               {:error, "workflow_model needs factory, which is left out"}
    end

    test "factory is on by default and needs observability, security and secrets: off where a list leaves it out" do
      refute :factory in Features.opt_in()
      assert Features.needs(:factory) == [:observability, :security, :secrets]

      for value <- [nil, "", "  ", "all", "all-path_rules"] do
        assert {:ok, features} = Features.parse(value, registry: nil)
        assert :factory in features, inspect(value)
      end

      for value <- ["all-factory,workflow_model", "observability,security"] do
        assert {:ok, features} = Features.parse(value, registry: nil)
        refute :factory in features, inspect(value)
      end

      assert Features.parse("all-factory", registry: nil) ==
               {:error, "workflow_model needs factory, which is left out"}

      assert Features.parse("observability,security,secrets,factory") ==
               {:ok, [:observability, :security, :secrets, :factory]}

      assert Features.parse("factory,path_rules,secrets,security,observability") ==
               {:ok, [:observability, :security, :secrets, :path_rules, :factory]}

      assert Features.parse("observability,security,factory") ==
               {:error, "factory needs secrets, which is left out"}

      assert Features.parse("observability,factory") ==
               {:error, "factory needs security, which is left out"}

      assert Features.parse("security,factory") ==
               {:error, "factory needs secrets, which is left out"}
    end

    test "secrets named without security is refused" do
      assert Features.parse("observability,secrets") ==
               {:error, "secrets needs security, which is left out"}

      assert Features.parse("secrets") == {:error, "secrets needs security, which is left out"}
    end

    test "instance_mail, a name the list once took, is accepted and ignored" do
      refute :instance_mail in Features.all()

      assert Features.parse("observability,instance_mail") == {:ok, [:observability]}
      assert Features.parse(" instance_mail , observability ") == {:ok, [:observability]}
      assert Features.parse("instance_mail") == {:ok, [:observability]}
      assert Features.parse("all-instance_mail") == Features.parse("all")
      assert Features.parse("all-path_rules,instance_mail") == Features.parse("all-path_rules")

      assert {:error, reason} = Features.parse("observability,instance_mail,dispatch")
      assert reason =~ "unknown feature dispatch;"
    end

    test "all is not a feature to list" do
      for value <- ["security,all", "observability,all-security", "all,all"] do
        assert {:error, reason} = Features.parse(value)
        assert reason == "all is not a feature to list: all, all-<features>, or the features on"
      end
    end
  end

  describe "needs/1" do
    test "every feature but observability needs observability, itself or through what it needs" do
      assert Features.needs(:observability) == []

      for feature <- Features.all() -- [:observability] do
        assert :observability in needs_all(feature)
      end
    end

    test "the Install guide says no feature needs observability that does not" do
      guide = File.read!(Path.expand("../../guides/install.md", __DIR__))

      free =
        for f <- Features.all() -- [:observability], :observability not in needs_all(f), do: f

      if free != [], do: refute(guide =~ ~r/every other feature\s+needs it/)
    end

    @tag :feature_sets
    test "a name that is no feature is a mistake in the caller" do
      assert_raise ArgumentError, ~r/:dispatch is not a feature/, fn ->
        Features.needs(:dispatch)
      end

      assert_raise ArgumentError, ~r/:dispatch is not a feature/, fn ->
        Features.on?(:dispatch)
      end

      assert_raise ArgumentError, ~r/:dispatch is not a feature/, fn ->
        Features.visible?(nil, :dispatch)
      end

      assert_raise ArgumentError, ~r/:dispatch is not a feature/, fn ->
        Features.visible?(%Scope{user: %User{}, hidden: []}, :dispatch)
      end
    end
  end

  describe "visible?/2" do
    @describetag :feature_sets

    setup do
      organisation = %Organisation{id: Ecto.UUID.generate()}
      workspace = %Workspace{id: Ecto.UUID.generate(), organisation_id: organisation.id}

      key = %AccessKey{
        organisation_id: organisation.id,
        workspace_id: workspace.id,
        workspace: workspace
      }

      person = %Scope{user: %User{}, organisation: organisation, workspace: workspace}
      %{organisation: organisation, workspace: workspace, key: key, person: person}
    end

    test "a person is shown what the instance has and the scope does not hide", ctx do
      for hidden <- [[], [:observability], [:security, :secrets], Features.all()] do
        scope = %{ctx.person | hidden: hidden}

        for feature <- Features.all() do
          assert Features.visible?(scope, feature) ==
                   (Features.on?(feature) and feature not in hidden),
                 inspect({hidden, feature})
        end
      end
    end

    test "an access key, its scope, the instance's, nil and a scope with hidden nil answer the instance",
         ctx do
      hidden = Features.all()

      scopes = [
        ctx.key,
        %{Scope.for_access_key(ctx.key) | hidden: hidden},
        %{Scope.for_instance(ctx.organisation, ctx.workspace) | hidden: hidden},
        nil,
        %{ctx.person | hidden: nil}
      ]

      for scope <- scopes, feature <- Features.all() do
        assert Features.visible?(scope, feature) == Features.on?(feature),
               inspect({scope, feature})
      end
    end

    test "a part is shown where its feature is and the scope hides neither", ctx do
      part = :"observability.terminal"

      for hidden <- [[], [part], [:observability], [:observability, part], [:security]] do
        scope = %{ctx.person | hidden: hidden}

        assert Features.visible?(scope, part) ==
                 (Features.on?(:observability) and :observability not in hidden and
                    part not in hidden),
               inspect(hidden)

        # Hiding a part hides nothing else of its feature.
        assert Features.visible?(scope, :observability) ==
                 (Features.on?(:observability) and :observability not in hidden)
      end

      for scope <- [ctx.key, nil, %{ctx.person | hidden: nil}] do
        assert Features.visible?(scope, part) == Features.on?(:observability)
      end

      assert_raise ArgumentError, ~r/:"observability.dispatch" is not a feature/, fn ->
        Features.visible?(%{ctx.person | hidden: []}, :"observability.dispatch")
      end
    end

    test "a part of no feature is shown on every instance where the scope does not hide it",
         ctx do
      for hidden <- [[], [:nodes], [:observability], Features.all(), [:"observability.terminal"]] do
        scope = %{ctx.person | hidden: hidden}
        assert Features.visible?(scope, :nodes) == :nodes not in hidden, inspect(hidden)
      end

      # An access key, the instance, nil and a scope that carries no `hidden` are shown it.
      scopes = [
        ctx.key,
        %{Scope.for_access_key(ctx.key) | hidden: [:nodes]},
        %{Scope.for_instance(ctx.organisation, ctx.workspace) | hidden: [:nodes]},
        nil,
        %{ctx.person | hidden: nil}
      ]

      for scope <- scopes, do: assert(Features.visible?(scope, :nodes), inspect(scope))
    end

    test "a person's scope keeps what the edition hides, as the core asks it", ctx do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.WithoutRecordOrPolicy)
      scope = %{ctx.person | hidden: Features.hidden_of(Apiary.Edition.hidden(ctx.person))}

      refute Features.visible?(scope, :observability)
      refute Features.visible?(scope, :security)

      for feature <- Features.all() do
        assert Features.visible?(ctx.key, feature) == Features.on?(feature), inspect(feature)
      end
    end

    test "a feature that needs a hidden one is not shown, as the scope keeps it", ctx do
      for {named, hidden} <- [
            {[:secrets], [:secrets, :factory, :workflow_model, :organisation_variables]},
            {[:path_rules], [:path_rules]},
            {[:factory], [:factory, :workflow_model]},
            {[:registry], [:registry]},
            {[:security],
             [
               :security,
               :secrets,
               :path_rules,
               :factory,
               :registry,
               :workflow_model,
               :organisation_policy,
               :organisation_variables
             ]},
            {[:observability],
             [
               :observability,
               :security,
               :secrets,
               :path_rules,
               :factory,
               :registry,
               :workflow_model,
               :managed_organisations,
               :organisation_policy,
               :organisation_variables,
               :feature_visibility
             ]}
          ] do
        scope = %{ctx.person | hidden: Features.hidden_of(named)}

        for feature <- Features.all() do
          assert Features.visible?(scope, feature) ==
                   (Features.on?(feature) and feature not in hidden),
                 inspect({named, feature})

          # An access key and the instance answer as the instance still.
          assert Features.visible?(ctx.key, feature) == Features.on?(feature)
        end
      end
    end
  end

  describe "hidden_of/1" do
    @describetag :feature_sets

    test "keeps the features the instance has, in the order of all/0" do
      assert Features.hidden_of([]) == []
      assert Features.hidden_of(Enum.reverse(Features.all())) == Features.enabled()

      assert Features.hidden_of([:secrets, :security, :secrets]) ==
               Enum.filter(
                 Features.enabled(),
                 &(&1 in [
                     :security,
                     :secrets,
                     :path_rules,
                     :factory,
                     :registry,
                     :workflow_model,
                     :organisation_policy,
                     :organisation_variables
                   ])
               )
    end

    test "adds every feature that needs a hidden one, directly or through another" do
      for feature <- Features.all() do
        assert Features.hidden_of([feature]) ==
                 Enum.filter(Features.enabled(), &(&1 == feature or feature in needs_all(&1))),
               inspect(feature)
      end

      assert Features.hidden_of([:secrets]) ==
               Enum.filter(
                 Features.enabled(),
                 &(&1 in [:secrets, :factory, :workflow_model, :organisation_variables])
               )

      assert Features.hidden_of([:path_rules]) ==
               Enum.filter(Features.enabled(), &(&1 == :path_rules))

      assert Features.hidden_of([:factory]) ==
               Enum.filter(Features.enabled(), &(&1 in [:factory, :workflow_model]))

      assert Features.hidden_of([:security]) ==
               Enum.filter(
                 Features.enabled(),
                 &(&1 in [
                     :security,
                     :secrets,
                     :path_rules,
                     :factory,
                     :registry,
                     :workflow_model,
                     :organisation_policy,
                     :organisation_variables
                   ])
               )

      assert Features.hidden_of([:observability]) ==
               Enum.filter(
                 Features.enabled(),
                 &(&1 in [
                     :observability,
                     :security,
                     :secrets,
                     :path_rules,
                     :factory,
                     :registry,
                     :workflow_model,
                     :managed_organisations,
                     :organisation_policy,
                     :organisation_variables,
                     :feature_visibility
                   ])
               )
    end

    test "keeps parts after the features, in the order of parts/0" do
      part = :"observability.terminal"

      assert Features.hidden_of([part]) == [part]

      assert Features.hidden_of([part, :secrets, part]) ==
               Enum.filter(
                 Features.enabled(),
                 &(&1 in [:secrets, :factory, :workflow_model, :organisation_variables])
               ) ++
                 [part]

      # A part is hidden with its feature without being named (`visible?/2`), so hiding
      # the feature adds no part.
      assert Features.hidden_of([part, :observability]) ==
               Enum.filter(
                 Features.enabled(),
                 &(&1 in [
                     :observability,
                     :security,
                     :secrets,
                     :path_rules,
                     :factory,
                     :registry,
                     :workflow_model,
                     :managed_organisations,
                     :organisation_policy,
                     :organisation_variables,
                     :feature_visibility
                   ])
               ) ++
                 [part]

      assert Features.hidden_of([:observability]) ==
               Enum.filter(
                 Features.enabled(),
                 &(&1 in [
                     :observability,
                     :security,
                     :secrets,
                     :path_rules,
                     :factory,
                     :registry,
                     :workflow_model,
                     :managed_organisations,
                     :organisation_policy,
                     :organisation_variables,
                     :feature_visibility
                   ])
               )
    end

    test "keeps the part of no feature, after the others, whatever the instance has" do
      part = :"observability.terminal"

      assert Features.hidden_of([:nodes]) == [:nodes]
      assert Features.hidden_of([:nodes, part, :nodes]) == [part, :nodes]

      assert Features.hidden_of([:nodes, :observability]) ==
               Enum.filter(
                 Features.enabled(),
                 &(&1 in [
                     :observability,
                     :security,
                     :secrets,
                     :path_rules,
                     :factory,
                     :registry,
                     :workflow_model,
                     :managed_organisations,
                     :organisation_policy,
                     :organisation_variables,
                     :feature_visibility
                   ])
               ) ++
                 [:nodes]
    end

    test "raises on a name that is no feature or part: an edition's mistake" do
      assert_raise ArgumentError, ~r/:dispatch is not a feature/, fn ->
        Features.hidden_of([:observability, :dispatch])
      end

      assert_raise ArgumentError, ~r/:"observability.dispatch" is not a feature/, fn ->
        Features.hidden_of([:"observability.dispatch"])
      end

      assert_raise ArgumentError, ~r/:terminal is not a feature/, fn ->
        Features.hidden_of([:terminal])
      end
    end
  end

  describe "the core's features and the edition's" do
    test "the core's come first, the edition's after, each built or not" do
      core = [:observability, :security, :secrets, :path_rules, :factory]
      edition = Enum.map(Apiary.Edition.features(), &elem(&1, 0))

      assert Enum.take(Features.all(), 5) == core
      assert Enum.take(Features.all(), -length(edition)) == edition

      # An opt-in feature is never offered for an organisation's switch.
      assert Features.built() ==
               [:observability, :security, :secrets, :path_rules, :factory, :workflow_model] ++
                 for(
                   {name, opts} <- Apiary.Edition.features(),
                   opts[:built] and Keyword.get(opts, :default, true),
                   do: name
                 )

      assert Features.opt_in() ==
               [:registry] ++
                 for(
                   {name, opts} <- Apiary.Edition.features(),
                   Keyword.get(opts, :default, true) == false,
                   do: name
                 )

      refute :registry in Features.built()
    end

    test "registry/1 takes each name once, with needs it has and built or not" do
      core = [observability: [needs: [], built: true]]

      assert %{all: [:observability, :security], built: [:observability]} =
               Features.registry(core ++ [security: [needs: [:observability], built: false]])

      assert_raise ArgumentError, ~r/listed once, got twice: observability/, fn ->
        Features.registry(core ++ [observability: [needs: [], built: true]])
      end

      assert_raise ArgumentError, ~r/needs records, which is no other feature/, fn ->
        Features.registry(core ++ [security: [needs: [:records], built: true]])
      end

      assert_raise ArgumentError, ~r/needs security, which is no other feature/, fn ->
        Features.registry(core ++ [security: [needs: [:security], built: true]])
      end

      assert_raise ArgumentError, ~r/a feature is \{name, needs/, fn ->
        Features.registry(core ++ [security: [needs: [:observability]]])
      end
    end

    test "documented/0 is every feature but path_rules, registry and the edition's switch, which the documentation does not differ by" do
      assert Features.documented() ==
               Features.all() -- [:path_rules, :registry, :feature_visibility]
    end

    test "registry/1 takes docs: false for a feature the documentation does not differ by" do
      core = [observability: [needs: [], built: true]]

      assert %{
               all: [:observability, :security, :rules],
               documented: [:observability, :security],
               opt_in: [:rules]
             } =
               Features.registry(
                 core ++
                   [
                     security: [needs: [:observability], built: true, docs: true],
                     rules: [needs: [:security], built: true, default: false, docs: false]
                   ]
               )

      assert %{documented: [:observability]} = Features.registry(core)

      assert_raise ArgumentError, ~r/docs: boolean where they are given/, fn ->
        Features.registry(core ++ [security: [needs: [:observability], built: true, docs: nil]])
      end
    end

    test "the core's observability has one part, the run's Terminal" do
      assert :"observability.terminal" in Features.parts()
      assert Enum.take(Features.parts(), 1) == [:"observability.terminal"]

      for part <- Features.parts() -- [:nodes] do
        assert Features.feature_of(part) in Features.all()
      end

      assert Features.feature_of(:"observability.terminal") == :observability
      assert Features.feature_of(:security) == :security

      assert_raise ArgumentError, ~r/:terminal is not a feature/, fn ->
        Features.feature_of(:terminal)
      end
    end

    @tag :feature_sets
    test "the nodes are the part nodes, of no feature, after the features' parts" do
      assert List.last(Features.parts()) == :nodes
      assert Features.feature_of(:nodes) == nil
      refute :nodes in Features.all()

      # A part is never on or off: on?/1 and needs/1 take features alone.
      assert_raise ArgumentError, ~r/:nodes is not a feature/, fn -> Features.on?(:nodes) end
      assert_raise ArgumentError, ~r/:nodes is not a feature/, fn -> Features.needs(:nodes) end
    end

    test "registry/1 refuses a feature named as the part of no feature" do
      assert_raise ArgumentError, ~r/a part is listed once, got twice: nodes/, fn ->
        Features.registry(
          observability: [needs: [], built: true],
          nodes: [needs: [:observability], built: true]
        )
      end
    end

    test "registry/1 names each part after its feature, in the order of the features" do
      core = [observability: [needs: [], built: true, parts: [:terminal, :timeline]]]

      assert %{
               parts: [
                 :"observability.terminal",
                 :"observability.timeline",
                 :"security.rules",
                 :nodes
               ],
               part_of: %{
                 "observability.terminal": :observability,
                 "observability.timeline": :observability,
                 "security.rules": :security,
                 nodes: nil
               }
             } =
               Features.registry(
                 core ++ [security: [needs: [:observability], built: true, parts: [:rules]]]
               )

      # A part of no feature follows the features' parts, whatever they are.
      assert %{parts: [:nodes], part_of: part_of} =
               Features.registry(observability: [needs: [], built: true])

      assert part_of == %{nodes: nil}
    end

    test "registry/1 refuses a part listed twice, one named as a feature, and one not an atom" do
      assert_raise ArgumentError,
                   ~r/a part is listed once, got twice: observability.terminal/,
                   fn ->
                     Features.registry(
                       observability: [needs: [], built: true, parts: [:terminal, :terminal]]
                     )
                   end

      assert_raise ArgumentError,
                   ~r/a part is listed once, got twice: observability.terminal/,
                   fn ->
                     Features.registry(
                       observability: [needs: [], built: true, parts: [:terminal]],
                       "observability.terminal": [needs: [:observability], built: true]
                     )
                   end

      for part <- ["terminal", 1, nil, true] do
        assert_raise ArgumentError, ~r/a part of observability is an atom, got: /, fn ->
          Features.registry(observability: [needs: [], built: true, parts: [part]])
        end
      end

      assert_raise ArgumentError, ~r/parts: \[atom\] where they are/, fn ->
        Features.registry(observability: [needs: [], built: true, parts: :terminal])
      end
    end

    test "registry/1 takes default: false for an opt-in feature, which built/0 leaves out" do
      core = [observability: [needs: [], built: true]]

      assert %{
               all: [:observability, :security, :secrets],
               built: [:observability, :security],
               opt_in: [:secrets]
             } =
               Features.registry(
                 core ++
                   [
                     security: [needs: [:observability], built: true, default: true],
                     secrets: [needs: [:security], built: true, default: false]
                   ]
               )

      assert %{opt_in: []} = Features.registry(core)

      assert_raise ArgumentError,
                   ~r/security needs secrets, which is opt-in: so is a feature that needs one/,
                   fn ->
                     Features.registry(
                       core ++
                         [
                           secrets: [needs: [:observability], built: true, default: false],
                           security: [needs: [:secrets], built: true]
                         ]
                     )
                   end

      assert_raise ArgumentError,
                   ~r/with default: boolean and docs: boolean where they are given/,
                   fn ->
                     Features.registry(
                       core ++ [security: [needs: [:observability], built: true, default: nil]]
                     )
                   end
    end
  end

  describe "the routes' features, checked at boot" do
    defmodule UnknownFeaturePlug do
      @moduledoc false
      def __feature__, do: :dispatch
      def init(opts), do: opts
      def call(conn, _opts), do: conn
    end

    defmodule UnknownFeatureRouter do
      @moduledoc false
      use Phoenix.Router
      get "/dispatch", UnknownFeaturePlug, :index
    end

    test "every page of the router names a feature there is" do
      assert ApiaryWeb.Features.check_routes!(ApiaryWeb.Router) == :ok
    end

    test "a page whose feature is none of them stops the boot, naming it" do
      error =
        assert_raise ArgumentError, fn ->
          ApiaryWeb.Features.check_routes!(UnknownFeatureRouter)
        end

      assert error.message =~ "UnknownFeaturePlug uses ApiaryWeb.Features with :dispatch"
    end
  end

  # Whether another feature of `features` needs `feature`.
  defp needed?(feature, features), do: Enum.any?(features, &(feature in Features.needs(&1)))

  # Every feature `feature` needs, through what those need.
  defp needs_all(feature) do
    feature
    |> Features.needs()
    |> Enum.flat_map(&[&1 | needs_all(&1)])
    |> Enum.uniq()
  end
end

defmodule Apiary.FeaturesBootTest do
  # Not async: boot!/0 sets the features of the whole node.
  use ExUnit.Case, async: false

  @moduletag :feature_sets

  alias Apiary.Features

  setup do
    setting = Application.get_env(:apiary, :features_setting)
    features = Application.get_env(:apiary, :features)
    registry = Application.get_env(:apiary, :registry_setting)

    on_exit(fn ->
      Application.put_env(:apiary, :features_setting, setting)
      Application.put_env(:apiary, :features, features)
      Application.put_env(:apiary, :registry_setting, registry)
    end)
  end

  test "boot!/0 fixes what QORY_FEATURES lists, and on?/1 and visible?/2 answer from it" do
    Application.put_env(:apiary, :features_setting, "observability,security")
    assert Features.boot!() == [:observability, :security]
    assert Features.enabled() == [:observability, :security]
    assert Features.on?(:security)

    for feature <- Features.all() -- [:observability, :security],
        do: refute(Features.on?(feature) or Features.visible?(nil, feature))
  end

  test "the part of no feature is there whatever features the instance has" do
    person = %Apiary.Accounts.Scope{user: %Apiary.Accounts.User{}}
    part = :"observability.terminal"

    for features <- [[:observability], []] do
      Application.put_env(:apiary, :features, features)

      assert Features.visible?(%{person | hidden: []}, :nodes)
      refute Features.visible?(%{person | hidden: [:nodes]}, :nodes)
      assert Features.visible?(nil, :nodes)
      assert Features.visible?(%{person | hidden: []}, part) == (features != [])

      # A part of a feature the instance lacks goes; the part of no feature stays.
      assert Features.hidden_of([:nodes, :security, part]) ==
               if(features == [], do: [], else: [part]) ++ [:nodes]
    end
  end

  test "boot!/0 has secrets, path_rules, factory and workflow_model on unless a list leaves them out" do
    default = [:secrets, :path_rules, :factory, :workflow_model]

    for value <- [nil, "", "all", "all-registry"] do
      Application.put_env(:apiary, :features_setting, value)
      assert default -- Features.boot!() == [], inspect(value)
      assert Enum.all?(default, &Features.on?/1)
    end

    Application.put_env(:apiary, :features_setting, "observability,security")
    assert Features.boot!() == [:observability, :security]
    refute Enum.any?(default, &Features.on?/1)

    Application.put_env(:apiary, :features_setting, "observability,security,path_rules")
    assert Features.boot!() == [:observability, :security, :path_rules]
    assert Features.on?(:path_rules)

    Application.put_env(:apiary, :features_setting, "observability,security,secrets,factory")
    assert Features.boot!() == [:observability, :security, :secrets, :factory]
    assert Features.on?(:factory)
    refute Features.on?(:workflow_model)
  end

  test "boot!/0 has registry on by default only where QORY_REGISTRY is set" do
    for {setting, on?} <- [{"registry.example.com", true}, {nil, false}, {" ", false}],
        value <- [nil, "", "all", "all-path_rules"] do
      Application.put_env(:apiary, :registry_setting, setting)
      Application.put_env(:apiary, :features_setting, value)
      assert :registry in Features.boot!() == on?, inspect({value, setting})
      assert Features.on?(:registry) == on?
    end

    Application.put_env(:apiary, :registry_setting, "registry.example.com")
    Application.put_env(:apiary, :features_setting, "observability,security")
    assert Features.boot!() == [:observability, :security]

    Application.put_env(:apiary, :registry_setting, nil)
    Application.put_env(:apiary, :features_setting, "observability,security,registry")
    assert Features.boot!() == [:observability, :security, :registry]
  end

  test "boot!/0 stops the boot where QORY_FEATURES names factory without secrets" do
    Application.put_env(:apiary, :features_setting, "observability,security,factory")
    error = assert_raise ArgumentError, fn -> Features.boot!() end
    assert error.message =~ "QORY_FEATURES is not valid: factory needs secrets, which is left out"

    Application.put_env(:apiary, :features_setting, "factory")
    error = assert_raise ArgumentError, fn -> Features.boot!() end
    assert error.message =~ "QORY_FEATURES is not valid: factory needs security"
  end

  test "boot!/0 boots where QORY_FEATURES still names instance_mail, as if it did not" do
    Application.put_env(:apiary, :features_setting, "observability,security,instance_mail")
    assert Features.boot!() == [:observability, :security]
    assert Features.enabled() == [:observability, :security]
  end

  test "boot!/0 stops the boot on a value parse/1 refuses, saying how to fix it" do
    Application.put_env(:apiary, :features_setting, "secrets")
    error = assert_raise ArgumentError, fn -> Features.boot!() end
    assert error.message =~ "QORY_FEATURES is not valid: secrets needs security"

    assert error.message =~
             "Remove it to use the saved features, set it to all, or name the features, " <>
               "for example:\n"

    assert error.message =~ "QORY_FEATURES=observability\n"
  end
end
