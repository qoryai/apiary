defmodule ApiaryPro.FlagsFeaturesTest do
  @moduledoc """
  One of the edition's flags is an opt-in feature (`ApiaryPro.Flags`, `ApiaryPro.Features`):
  `feature_visibility`. The flag is read from its feature, after a test's override; the
  feature needs what it needs; and a config value of an older release turns it on in the
  saved list once, at the first boot that reads it, or at every boot while
  `QORY_FEATURES` is set (`Apiary.Features.Saved`). `transfers` and
  `operator_infrastructure` stay config values.
  """
  # Not async: the features, the config values and the instance's row are the whole node's.
  use Apiary.DataCase, async: false

  alias Apiary.Features
  alias Apiary.Features.Saved
  alias Apiary.Features.Saved.Row
  alias ApiaryPro.Flags

  @moduletag :feature_sets

  @flags [:operator_infrastructure, :feature_visibility, :transfers]

  setup do
    for {app, key} <-
          [apiary: :features, apiary: :features_setting, apiary: :registry_setting] ++
            Enum.map(@flags, &{:apiary_pro, &1}) do
      before = Application.fetch_env(app, key)

      on_exit(fn ->
        case before do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end)
    end

    Application.put_env(:apiary, :features_setting, nil)
    Application.put_env(:apiary, :registry_setting, nil)
    for flag <- @flags, do: Application.delete_env(:apiary_pro, flag)
    :ok
  end

  defp defaults, do: Features.all() -- Features.opt_in()
  defp row, do: Repo.get(Row, true)

  describe "the flag is read from its feature" do
    test "feature_visibility?/0 follows the feature, not the config" do
      Application.put_env(:apiary, :features, defaults())
      Application.put_env(:apiary_pro, :feature_visibility, true)
      refute Flags.feature_visibility?()

      Application.put_env(:apiary, :features, defaults() ++ [:feature_visibility])
      Application.put_env(:apiary_pro, :feature_visibility, false)
      assert Flags.feature_visibility?()
    end

    test "a test's override wins over the feature" do
      Application.put_env(:apiary, :features, defaults() ++ [:feature_visibility])
      Flags.put_feature_visibility(false)
      refute Flags.feature_visibility?()

      Application.put_env(:apiary, :features, defaults())
      Flags.put_feature_visibility(true)
      assert Flags.feature_visibility?()
    end

    test "transfers and operator_infrastructure stay config values, and are no features" do
      for flag <- [:transfers, :operator_infrastructure] do
        refute flag in Features.all()
        refute flag in Enum.map(Apiary.Edition.config_features(), &elem(&1, 0))
      end

      Application.put_env(:apiary_pro, :transfers, true)
      Application.put_env(:apiary_pro, :operator_infrastructure, true)
      assert Flags.transfers?()
      assert Flags.operator_infrastructure?()
    end
  end

  describe "the features" do
    test "feature_visibility is opt-in, off by default, and offered to no organisation" do
      assert :feature_visibility in Features.opt_in()
      refute :feature_visibility in Features.built()
      refute :feature_visibility in Features.documented()
      assert :feature_visibility in ApiaryPro.Features.instance_switched()
      refute :feature_visibility in defaults()

      assert {:ok, features} = Features.parse("all")
      refute :feature_visibility in features
    end

    test "feature_visibility needs observability" do
      assert Features.needs(:feature_visibility) == [:observability]

      assert {:ok, [:observability, :feature_visibility]} =
               Features.parse("feature_visibility")
    end
  end

  describe "the first boot after the upgrade" do
    test "turns on in the saved list the feature whose config value is on, once" do
      Application.put_env(:apiary_pro, :feature_visibility, true)

      on = Enum.filter(Features.all(), &(&1 in defaults() or &1 == :feature_visibility))

      assert Saved.boot() == on
      assert Flags.feature_visibility?()
      assert row().features == Enum.map(on, &to_string/1)
      assert row().features_version == 1

      # The list is written, so every feature of the release is seen, but registry, locked
      # off without QORY_REGISTRY.
      assert Enum.sort(row().features_seen) ==
               Enum.sort(Enum.map(Features.all() -- [:registry], &to_string/1))
    end

    test "a second boot reads the config no more: the page decides" do
      Application.put_env(:apiary_pro, :feature_visibility, true)
      Saved.boot()
      assert Flags.feature_visibility?()

      # An instance admin turns it off, as the page saves it.
      Repo.update_all(from(r in Row, where: r.id == true),
        set: [features: Enum.map(defaults(), &to_string/1)],
        inc: [features_version: 1]
      )

      # The config value is still on, and is not read again.
      Saved.boot()

      refute Flags.feature_visibility?()
      assert row().features == Enum.map(defaults(), &to_string/1)
      assert row().features_version == 2
    end

    test "with no config value on, only the names are kept, and the defaults stay in force" do
      assert Saved.boot() == defaults()
      assert row().features == nil
      assert row().features_version == 0
      assert Saved.current().source == :default

      assert row().features_seen == ["feature_visibility"]

      # Set after that first boot, the value is not read.
      Application.put_env(:apiary_pro, :feature_visibility, true)
      assert Saved.boot() == defaults()
      assert row().features == nil
    end

    test "a transfers config value is never saved" do
      Application.put_env(:apiary_pro, :transfers, true)
      Saved.boot()

      assert row().features == nil
      refute "transfers" in row().features_seen
      assert Flags.transfers?()
    end

    test "while QORY_FEATURES is set, a config value on counts as listed in it, at every boot" do
      Application.put_env(:apiary_pro, :feature_visibility, true)
      Application.put_env(:apiary, :features_setting, "observability,security")

      assert Saved.boot() == [:observability, :security, :feature_visibility]
      assert Flags.feature_visibility?()
      assert row().features == ["observability", "security", "feature_visibility"]
      assert "feature_visibility" in row().features_seen

      # A second boot with the variable keeps it, and so does the first boot without it.
      assert Saved.boot() == [:observability, :security, :feature_visibility]
      assert row().features_version == 1

      Application.put_env(:apiary, :features_setting, nil)
      assert Saved.boot() == [:observability, :security, :feature_visibility]
      assert Flags.feature_visibility?()
      assert row().features_version == 1
    end

    test "while QORY_FEATURES leaves a config feature out by name, the variable applies" do
      Application.put_env(:apiary_pro, :feature_visibility, true)
      Application.put_env(:apiary, :features_setting, "all-feature_visibility")

      refute :feature_visibility in Saved.boot()
      refute Flags.feature_visibility?()
      refute "feature_visibility" in row().features

      Application.put_env(:apiary, :features_setting, nil)
      refute :feature_visibility in Saved.boot()
    end

    test "a config feature counted as listed is checked for its needs, as a listed one is" do
      assert Features.parse("observability", config: [:secrets]) ==
               {:error, "secrets needs security, which is left out"}

      # Left out by name, it stays out.
      assert Features.parse("all-feature_visibility", config: [:feature_visibility]) ==
               Features.parse("all-feature_visibility")
    end

    test "an operator_infrastructure config value is never saved" do
      Application.put_env(:apiary_pro, :operator_infrastructure, true)
      Application.put_env(:apiary, :features_setting, "all")
      Saved.boot()
      refute "operator_infrastructure" in row().features_seen

      Application.put_env(:apiary, :features_setting, nil)
      assert Saved.boot() == defaults()
      refute "operator_infrastructure" in row().features_seen
      assert Flags.operator_infrastructure?()
    end
  end
end
