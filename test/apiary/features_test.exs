defmodule Apiary.FeaturesTest do
  use ExUnit.Case, async: true

  alias Apiary.Features

  describe "parse/1, the value of QORY_FEATURES" do
    test "unset, empty or blank is every feature" do
      for value <- [nil, "", "  ", " , "] do
        assert Features.parse(value) == {:ok, Features.all()}
      end
    end

    test "a list is taken in the order of all/0, with spaces and repeats forgiven" do
      assert Features.parse("security, observability,security") ==
               {:ok, [:observability, :security]}

      assert Features.parse("observability,security,managed_organisations") ==
               {:ok, [:observability, :security, :managed_organisations]}

      assert Features.parse("observability") == {:ok, [:observability]}
    end

    test "an unknown name is refused, naming it and not the features there are" do
      assert {:error, reason} = Features.parse("observability,dispatch")
      assert reason =~ "unknown feature dispatch; the Install guide at /docs lists the features"
      refute reason =~ "managed_organisations"

      assert {:error, reason} = Features.parse("Observability,records")
      assert reason =~ "unknown features Observability, records"
    end

    test "a feature without the features it needs is refused" do
      for feature <- Features.all() -- [:observability] do
        assert {:error, reason} = Features.parse(to_string(feature))
        assert reason == "#{feature} needs observability, which is left out"
      end
    end

    test "all is every feature, and all- every feature but those it names" do
      assert Features.parse("all") == {:ok, Features.all()}
      assert Features.parse(" all ") == {:ok, Features.all()}

      assert Features.parse("all-security") == {:ok, Features.all() -- [:security]}

      assert Features.parse("all-security,managed_organisations") ==
               {:ok, Features.all() -- [:security, :managed_organisations]}

      all_but_the_record = Enum.join(Features.all() -- [:observability], ", ")
      assert Features.parse("all-" <> all_but_the_record) == {:ok, [:observability]}
    end

    test "all- is refused for a name that is no feature, for none, and for leaving out a need" do
      assert {:error, reason} = Features.parse("all-dispatch")
      assert reason =~ "unknown feature dispatch; the Install guide"

      assert {:error, reason} = Features.parse("all-security-managed_organisations")
      assert reason =~ "unknown feature security-managed_organisations; the Install guide"

      for value <- ["all-", "all-,"] do
        assert {:error, reason} = Features.parse(value)
        assert reason =~ ~s(unknown feature ""; the Install guide)
      end

      assert {:error, reason} = Features.parse("all-observability")
      assert reason == "security needs observability, which is left out"
    end

    test "all is not a feature to list" do
      for value <- ["security,all", "observability,all-security", "all,all"] do
        assert {:error, reason} = Features.parse(value)
        assert reason == "all is not a feature to list: all, all-<features>, or the features on"
      end
    end
  end

  describe "needs/1" do
    test "every feature but observability needs observability" do
      assert Features.needs(:observability) == []

      for feature <- Features.all() -- [:observability] do
        assert Features.needs(feature) == [:observability]
      end
    end
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

  test "boot!/0 fixes what QORY_FEATURES lists, and on?/1 and on?/2 answer from it" do
    Application.put_env(:apiary, :features_setting, "observability,security")
    assert Features.boot!() == [:observability, :security]
    assert Features.enabled() == [:observability, :security]
    assert Features.on?(:security)
    refute Features.on?(nil, :managed_organisations)
  end

  test "boot!/0 stops the boot on a value parse/1 refuses, saying how to fix it" do
    Application.put_env(:apiary, :features_setting, "security")
    error = assert_raise ArgumentError, fn -> Features.boot!() end
    assert error.message =~ "QORY_FEATURES is not valid: security needs observability"
    assert error.message =~ "QORY_FEATURES=observability\n"
  end
end
