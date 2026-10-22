defmodule Apiary.RegistryTest do
  # The registry's setting and signing key (`Apiary.Registry`): `QORY_REGISTRY` read, and
  # each line that stops the boot with the fix first. Not async: the settings are the
  # whole node's, and each test puts them back.
  use ExUnit.Case, async: false

  alias Apiary.Registry

  @moduletag needs: :registry
  @moduletag :tmp_dir

  setup do
    setting = Application.get_env(:apiary, :registry_setting)
    config = Application.get_env(:apiary, Registry)
    settings = Application.fetch_env(:apiary, Registry.Settings)

    on_exit(fn ->
      Application.put_env(:apiary, :registry_setting, setting)
      Application.put_env(:apiary, Registry, config)

      case settings do
        {:ok, kept} -> Application.put_env(:apiary, Registry.Settings, kept)
        :error -> Application.delete_env(:apiary, Registry.Settings)
      end
    end)
  end

  defp boot(setting, config) do
    Application.put_env(:apiary, :registry_setting, setting)
    Application.put_env(:apiary, Registry, config)
    Application.delete_env(:apiary, Registry.Settings)
    Registry.boot!()
  end

  defp pem(key), do: :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])

  describe "parse/1" do
    test "reads a host and an optional port" do
      assert Registry.parse("registry.qory.example") ==
               {:ok, %{service: "registry.qory.example", host: "registry.qory.example"}}

      assert Registry.parse(" registry.qory.example:5000 ") ==
               {:ok, %{service: "registry.qory.example:5000", host: "registry.qory.example"}}

      assert Registry.parse("10.0.0.7:5000") ==
               {:ok, %{service: "10.0.0.7:5000", host: "10.0.0.7"}}

      assert Registry.parse("localhost") == {:ok, %{service: "localhost", host: "localhost"}}
    end

    test "is :unset for nil or blank, :error for any other value" do
      assert Registry.parse(nil) == :unset
      assert Registry.parse("  ") == :unset

      for value <- [
            "https://registry.qory.example",
            "registry.qory.example/v2",
            "Registry.Qory.Example",
            "registry.qory.example:0",
            "registry.qory.example:65536",
            "registry.qory.example:",
            "registry..example",
            "-registry.example",
            "user@registry.example",
            "[::1]:5000",
            "300.0.0.1"
          ] do
        assert Registry.parse(value) == :error, value
      end
    end
  end

  test "decode_key/1 reads a P-256 key and nothing else" do
    key = :public_key.generate_key({:namedCurve, {1, 2, 840, 10045, 3, 1, 7}})
    assert {:ok, ^key} = Registry.decode_key(pem(key))

    other = :public_key.generate_key({:namedCurve, {1, 3, 132, 0, 34}})
    assert Registry.decode_key(pem(other)) == :error
    assert Registry.decode_key("not a key") == :error
    assert Registry.decode_key("") == :error
  end

  describe "boot!/0 with the feature on" do
    test "keeps the setting and the key from the key file", %{tmp_dir: dir} do
      key = :public_key.generate_key({:namedCurve, {1, 2, 840, 10045, 3, 1, 7}})
      path = Path.join(dir, "registry-token.key")
      File.write!(path, pem(key))

      assert boot("registry.qory.example:5000", key_file: path) == :ok

      assert %{service: "registry.qory.example:5000", host: "registry.qory.example", key: ^key} =
               settings = Registry.settings()

      assert settings.kid =~ ~r/\A[0-9a-f]{16}\z/

      assert settings.kid ==
               :crypto.hash(:sha256, settings.public_der)
               |> binary_part(0, 8)
               |> Base.encode16(case: :lower)
    end

    test "stops with B1 where QORY_REGISTRY is not set" do
      error = assert_raise ArgumentError, fn -> boot(nil, generate_key: true) end

      assert error.message ==
               "Set QORY_REGISTRY to the registry's host, for example " <>
                 "QORY_REGISTRY=registry.qory.example.\n" <>
                 "The feature registry is on in QORY_FEATURES, and QORY_REGISTRY is not set.\n"
    end

    test "stops with B2 where QORY_REGISTRY is not a host" do
      error =
        assert_raise ArgumentError, fn ->
          boot("https://registry.qory.example", generate_key: true)
        end

      assert error.message ==
               "Set QORY_REGISTRY to a host and an optional port, with no scheme or path, " <>
                 "for example registry.qory.example.\n" <>
                 "QORY_REGISTRY is set to https://registry.qory.example.\n"
    end

    test "stops where QORY_REGISTRY's host is the host of PUBLIC_URL" do
      endpoint = Application.get_env(:apiary, ApiaryWeb.Endpoint)
      on_exit(fn -> Application.put_env(:apiary, ApiaryWeb.Endpoint, endpoint) end)

      Application.put_env(
        :apiary,
        ApiaryWeb.Endpoint,
        Keyword.put(endpoint, :url, host: "Registry.Qory.Example", port: 443, scheme: "https")
      )

      for setting <- ["registry.qory.example", "registry.qory.example:5000"] do
        error = assert_raise ArgumentError, fn -> boot(setting, generate_key: true) end

        assert error.message ==
                 "Set QORY_REGISTRY to a host other than registry.qory.example.\n" <>
                   "PUBLIC_URL uses the same host, and a run's egress rules work only when " <>
                   "the registry and Qory Apiary are on separate hosts.\n"
      end

      assert boot("other.qory.example", generate_key: true) == :ok
    end

    test "stops with B3 where the key file does not exist", %{tmp_dir: dir} do
      path = Path.join(dir, "registry-token.key")

      error =
        assert_raise ArgumentError, fn -> boot("registry.qory.example", key_file: path) end

      assert error.message ==
               "Run bin/keys with QORY_REGISTRY set, so it writes the registry signing key " <>
                 "to #{path}.\nThe feature registry is on, and that file does not exist.\n"
    end

    test "stops with B4 where the key file is not a P-256 key, and shows no key", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "registry-token.key")
      other = :public_key.generate_key({:namedCurve, {1, 3, 132, 0, 34}})
      File.write!(path, pem(other))

      error =
        assert_raise ArgumentError, fn -> boot("registry.qory.example", key_file: path) end

      assert error.message ==
               "Delete #{path}, run bin/keys again, then restart the registry.\n" <>
                 "The file is not a P-256 private key in PEM form.\n"

      refute error.message =~ "BEGIN"
    end
  end
end
