defmodule Apiary.Connections.IntegrityVectorsTest do
  # Not async: the secret is the application's configuration, set for a test and put
  # back after it.
  use ExUnit.Case, async: false

  alias Apiary.{Integrity, KeyDerivation}
  alias Apiary.Connections.{Connection, ServiceDefinition}
  alias Apiary.Integrations.Release

  # The codes below were computed outside the application, with Python's hmac, from the
  # encoding `Apiary.Integrity` documents and the integrity key of the secret 00 01 … 1f,
  # over the fields each schema names at its version: none of them names a workspace.
  @secret :binary.list_to_bin(Enum.to_list(0..31))
  @organisation "6f1c0b52-3c1e-4b8a-9d2f-0a1b2c3d4e5f"
  @release_id "2a3b4c5d-6e7f-4a8b-9c0d-1e2f3a4b5c6d"

  setup do
    previous = Application.get_env(:apiary, KeyDerivation)
    Application.put_env(:apiary, KeyDerivation, secret: @secret)
    on_exit(fn -> Application.put_env(:apiary, KeyDerivation, previous) end)
  end

  defp known_answer(module, row, version \\ nil) do
    version = version || module.integrity_version()
    fields = module.integrity_fields(row, version)
    {key_id, code} = Integrity.code(module.integrity_kind(), version, fields)
    assert key_id == "00c237515a3185d8"
    {version, Keyword.keys(fields), Base.encode16(code, case: :lower)}
  end

  test "a connection is coded at version 2, without a workspace" do
    row = %Connection{
      id: "0f9b6a8e-1d2c-4e3f-8a7b-6c5d4e3f2a10",
      organisation_id: @organisation,
      public_id: "con_0123456789abcdef",
      kind: "integration",
      name: "github",
      applies_to: "selected",
      settings: ~s({"app_id":"1"}),
      argument: "acme/shop",
      release_id: @release_id,
      source: "github.com/qoryai/qory-github",
      forge_kind: "github",
      version: "0.1.0",
      description_sha256: String.duplicate("a", 64)
    }

    assert Connection.integrity_versions() == [2, 3]

    assert known_answer(Connection, row, 2) ==
             {2,
              [
                :id,
                :organisation_id,
                :public_id,
                :kind,
                :name,
                :applies_to,
                :settings,
                :argument,
                :release_id,
                :source,
                :forge_kind,
                :version,
                :description_sha256,
                :service_builtin,
                :service_definition_id
              ], "32ccf4feab5faa41168fa81a87cb5251fb0344110b35efb9a820b32a59dd3ae1"}
  end

  test "a connection is coded at version 3, with a model provider's columns" do
    row = %Connection{
      id: "0f9b6a8e-1d2c-4e3f-8a7b-6c5d4e3f2a11",
      organisation_id: @organisation,
      public_id: "con_0123456789abcdeg",
      kind: "integration",
      name: "LiteLLM",
      applies_to: "all",
      settings: ~s({"address":"https://litellm.example.com"}),
      description_sha256: String.duplicate("b", 64),
      provider_kind: "litellm",
      description_ref: String.duplicate("c", 40),
      secret_id: "4d5e6f7a-8b9c-4d0e-9f1a-2b3c4d5e6f7a",
      default_value_id: "main",
      chain: "organisation"
    }

    assert Connection.integrity_version() == 3

    assert known_answer(Connection, row) ==
             {3,
              [
                :id,
                :organisation_id,
                :public_id,
                :kind,
                :name,
                :applies_to,
                :settings,
                :argument,
                :release_id,
                :source,
                :forge_kind,
                :version,
                :description_sha256,
                :service_builtin,
                :service_definition_id,
                :provider_kind,
                :description_ref,
                :secret_id,
                :default_value_id,
                :chain
              ], "0850fdfc5591d44419e1b098acaf5e4f1f5948575c300e9730811de41918603a"}
  end

  test "a service definition is coded at version 2, without a workspace" do
    row = %ServiceDefinition{
      id: "3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f",
      organisation_id: @organisation,
      public_id: "svc_0123456789abcdef",
      key: "status-api",
      definition: ~s({"key":"status-api"}),
      digest: String.duplicate("b", 64)
    }

    assert ServiceDefinition.integrity_versions() == [2]

    assert known_answer(ServiceDefinition, row) ==
             {2, [:id, :organisation_id, :public_id, :key, :definition, :digest],
              "00e2d6ab3551762c9df8866c8524434735f3a82cce1c98397b70302aea598bae"}
  end

  test "a release is coded at version 3, without a workspace" do
    row = %Release{
      id: @release_id,
      organisation_id: @organisation,
      source: "github.com/qoryai/qory-github",
      forge_kind: "github",
      requested_version: "0.1.0",
      state: "ready",
      name: "github",
      version: "0.1.0",
      description_sha256: String.duplicate("a", 64)
    }

    assert Release.integrity_versions() == [3]

    assert known_answer(Release, row) ==
             {3,
              [
                :id,
                :organisation_id,
                :source,
                :forge_kind,
                :requested_version,
                :state,
                :failure,
                :name,
                :version,
                :description_sha256
              ], "fd6bcdb0ee4035e7c9924106d385aa82f94f9928b111badca325be2a6449c4b4"}
  end

  test "a row coded at an earlier version does not verify" do
    for {module, row, old} <- [
          {Connection, %Connection{id: "0f9b6a8e-1d2c-4e3f-8a7b-6c5d4e3f2a10"}, 1},
          {ServiceDefinition, %ServiceDefinition{id: "3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f"}, 1},
          {Release, %Release{id: @release_id}, 2}
        ] do
      fields = module.integrity_fields(row, module.integrity_version())
      {key_id, code} = Integrity.code(module.integrity_kind(), old, fields)

      assert Apiary.Kinds.Coded.verify(%{
               row
               | integrity_key_id: key_id,
                 integrity_code: code,
                 integrity_version: old
             }) == {:error, :mismatch}
    end
  end
end
