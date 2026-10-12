defmodule Apiary.FeaturesTest do
  use ExUnit.Case, async: true

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Features
  alias Apiary.Organisations.{Organisation, Workspace}

  describe "parse/1, the value of QORY_FEATURES" do
    test "unset, empty or blank is every feature but the opt-in ones" do
      for value <- [nil, "", "  ", " , "] do
        assert Features.parse(value) == {:ok, Features.all() -- Features.opt_in()}
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

    test "a feature without the features it needs is refused" do
      for feature <- Features.all() -- [:observability] do
        assert {:error, reason} = Features.parse(to_string(feature))
        [need | _] = Features.needs(feature)
        assert reason == "#{feature} needs #{need}, which is left out"
      end
    end

    test "all is every feature but the opt-in ones, and all- those but the ones it names" do
      default = Features.all() -- Features.opt_in()
      assert Features.parse("all") == {:ok, default}
      assert Features.parse(" all ") == {:ok, default}

      # A feature nothing else needs can be left out on its own; one another needs takes
      # that one with it.
      leaf = Enum.find(default -- [:observability], &(not needed?(&1, default)))
      assert Features.parse("all-#{leaf}") == {:ok, default -- [leaf]}

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

      assert {:error, reason} = Features.parse("all-observability")
      assert reason == "security needs observability, which is left out"
    end

    test "an opt-in feature is off unless a list names it" do
      assert :secrets in Features.opt_in()

      for value <- [nil, "", "  ", "all", all_but_a_leaf()] do
        assert {:ok, features} = Features.parse(value)
        refute :secrets in features, inspect(value)
      end

      assert Features.parse("observability,security,secrets") ==
               {:ok, [:observability, :security, :secrets]}

      assert Features.parse("secrets, security, observability") ==
               {:ok, [:observability, :security, :secrets]}
    end

    test "an opt-in feature named without the features it needs is refused" do
      assert Features.parse("observability,secrets") ==
               {:error, "secrets needs security, which is left out"}

      assert Features.parse("secrets") == {:error, "secrets needs security, which is left out"}
    end

    test "instance_mail, a name the list once took, is accepted and ignored" do
      refute :instance_mail in Features.all()

      assert Features.parse("observability,instance_mail") == {:ok, [:observability]}
      assert Features.parse(" instance_mail , observability ") == {:ok, [:observability]}
      assert Features.parse("instance_mail") == {:ok, []}
      assert Features.parse("all-instance_mail") == Features.parse("all")
      assert Features.parse("all-security,instance_mail") == Features.parse("all-security")

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

    test "a person's scope keeps what the edition hides, as the core asks it", ctx do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.WithoutRecordOrPolicy)
      scope = %{ctx.person | hidden: Features.hidden_of(Apiary.Edition.hidden(ctx.person))}

      refute Features.visible?(scope, :observability)
      refute Features.visible?(scope, :security)

      for feature <- Features.all() do
        assert Features.visible?(ctx.key, feature) == Features.on?(feature), inspect(feature)
      end
    end
  end

  describe "hidden_of/1" do
    test "keeps the features the instance has, in the order of all/0" do
      assert Features.hidden_of([]) == []
      assert Features.hidden_of(Enum.reverse(Features.all())) == Features.enabled()

      assert Features.hidden_of([:security, :observability, :security]) ==
               Enum.filter(Features.enabled(), &(&1 in [:observability, :security]))
    end

    test "keeps parts after the features, in the order of parts/0" do
      part = :"observability.terminal"

      assert Features.hidden_of([part]) == [part]
      assert Features.hidden_of([part, :security, part]) ==
               Enum.filter(Features.enabled(), &(&1 == :security)) ++ [part]

      assert Features.hidden_of([part, :observability]) == [:observability, part]
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
      core = [:observability, :security, :secrets]
      edition = Enum.map(Apiary.Edition.features(), &elem(&1, 0))

      assert Enum.take(Features.all(), 3) == core
      assert Enum.take(Features.all(), -length(edition)) == edition

      # An opt-in feature is never offered for an organisation's switch.
      assert Features.built() ==
               [:observability, :security] ++
                 for(
                   {name, opts} <- Apiary.Edition.features(),
                   opts[:built] and Keyword.get(opts, :default, true),
                   do: name
                 )

      assert :secrets in Features.opt_in()
      refute :secrets in Features.built()
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

    test "the core's observability has one part, the run's Terminal" do
      assert :"observability.terminal" in Features.parts()
      assert Enum.take(Features.parts(), 1) == [:"observability.terminal"]

      for part <- Features.parts() do
        assert Features.feature_of(part) in Features.all()
      end

      assert Features.feature_of(:"observability.terminal") == :observability
      assert Features.feature_of(:security) == :security

      assert_raise ArgumentError, ~r/:terminal is not a feature/, fn ->
        Features.feature_of(:terminal)
      end
    end

    test "registry/1 names each part after its feature, in the order of the features" do
      core = [observability: [needs: [], built: true, parts: [:terminal, :timeline]]]

      assert %{
               parts: [:"observability.terminal", :"observability.timeline", :"security.rules"],
               part_of: %{
                 "observability.terminal": :observability,
                 "observability.timeline": :observability,
                 "security.rules": :security
               }
             } =
               Features.registry(
                 core ++ [security: [needs: [:observability], built: true, parts: [:rules]]]
               )

      assert %{parts: [], part_of: part_of} =
               Features.registry(observability: [needs: [], built: true])

      assert part_of == %{}
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

      assert_raise ArgumentError, ~r/with default: boolean where it is given/, fn ->
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

  # `all-` and a feature on by default that no other needs, of the core's and the edition's
  # (`all-security` in the core alone).
  defp all_but_a_leaf do
    default = Features.all() -- Features.opt_in()
    "all-#{Enum.find(default -- [:observability], &(not needed?(&1, default)))}"
  end

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

  alias Apiary.Features

  setup do
    setting = Application.get_env(:apiary, :features_setting)
    features = Application.get_env(:apiary, :features)

    on_exit(fn ->
      Application.put_env(:apiary, :features_setting, setting)
      Application.put_env(:apiary, :features, features)
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

  test "boot!/0 leaves an opt-in feature off unless QORY_FEATURES names it" do
    for value <- [nil, "", "all", all_but_a_leaf()] do
      Application.put_env(:apiary, :features_setting, value)
      refute :secrets in Features.boot!(), inspect(value)
      refute Features.on?(:secrets)
    end

    Application.put_env(:apiary, :features_setting, "observability,security,secrets")
    assert Features.boot!() == [:observability, :security, :secrets]
    assert Features.on?(:secrets)
  end

  test "boot!/0 boots where QORY_FEATURES still names instance_mail, as if it did not" do
    Application.put_env(:apiary, :features_setting, "observability,security,instance_mail")
    assert Features.boot!() == [:observability, :security]
    assert Features.enabled() == [:observability, :security]
  end

  test "boot!/0 stops the boot on a value parse/1 refuses, saying how to fix it" do
    Application.put_env(:apiary, :features_setting, "security")
    error = assert_raise ArgumentError, fn -> Features.boot!() end
    assert error.message =~ "QORY_FEATURES is not valid: security needs observability"
    assert error.message =~ "QORY_FEATURES=observability\n"
  end

  # `all-` and a feature on by default that no other needs, of the core's and the edition's
  # (`all-security` in the core alone).
  defp all_but_a_leaf do
    default = Features.all() -- Features.opt_in()

    leaf =
      Enum.find(default -- [:observability], fn feature ->
        not Enum.any?(default, &(feature in Features.needs(&1)))
      end)

    "all-#{leaf}"
  end
end
