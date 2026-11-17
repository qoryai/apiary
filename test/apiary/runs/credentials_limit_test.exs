defmodule Apiary.Runs.CredentialsLimitTest do
  # The most credentials a run configuration, a secrets request and a sealed plaintext take:
  # 16, so that a write run with 6 model keys, the registry credential and the work and push
  # credentials, 9 entries, is served. The :contract tests replay the vendored schemas, whose
  # limit is the Forager contract's.
  use ExUnit.Case, async: true

  alias Apiary.ForagerSchemas
  alias Apiary.Runs.SecretsRequest

  @run_id "0192f0c1-7d4e-7a2b-8c3d-4e5f6a7b8c9d"
  @digest "sha256=" <> String.duplicate("a1", 32)

  defp names(count), do: for(n <- 1..count, do: "key-#{String.pad_leading("#{n}", 2, "0")}")

  defp request(count) do
    Jason.encode!(%{
      "version" => 1,
      "run_id" => @run_id,
      "run_configuration" => @digest,
      "credentials" => names(count),
      "timestamp" => 1_790_000_000
    })
  end

  test "a secrets request takes 16 credentials and refuses 17" do
    assert {:ok, %{credentials: names}} = SecretsRequest.parse(request(16))
    assert length(names) == 16
    assert SecretsRequest.parse(request(17)) == {:error, :invalid_request}
  end

  describe "the vendored schemas" do
    @describetag :contract

    test "take a secrets request of 9 credentials" do
      assert ForagerSchemas.validate("secrets-request.schema.json", request(9)) == :ok
    end

    test "take a sealed plaintext of 9 credentials" do
      plaintext =
        Jason.encode!(%{
          "version" => 1,
          "run_configuration" => @digest,
          "credentials" => names(9),
          "values" => for(name <- names(9), do: %{"credential" => name, "value" => "v"})
        })

      assert ForagerSchemas.validate("sealed-plaintext.schema.json", plaintext) == :ok
    end

    defp configuration(count) do
      entry = fn name ->
        %{"name" => name, "apply" => [%{"hosts" => ["git.example"], "scheme" => "bearer"}]}
      end

      Jason.encode!(%{"version" => 1, "credentials" => Enum.map(names(count), entry)})
    end

    test "take a run configuration of 9 credentials" do
      document = configuration(9)
      assert ForagerSchemas.validate("run-configuration.schema.json", document) == :ok
      assert Apiary.Policy.Schema.validate(document) == :ok
    end

    test "take a run configuration of 16 credentials and refuse 17" do
      assert ForagerSchemas.validate("run-configuration.schema.json", configuration(16)) == :ok

      assert {:error, _reason} =
               ForagerSchemas.validate("run-configuration.schema.json", configuration(17))
    end

    test "take a secrets request of 16 credentials and refuse 17" do
      assert ForagerSchemas.validate("secrets-request.schema.json", request(16)) == :ok

      assert {:error, _reason} =
               ForagerSchemas.validate("secrets-request.schema.json", request(17))
    end

    test "take a sealed plaintext of 16 credentials and refuse 17" do
      plaintext = fn count ->
        Jason.encode!(%{
          "version" => 1,
          "run_configuration" => @digest,
          "credentials" => names(count),
          "values" => for(name <- names(count), do: %{"credential" => name, "value" => "v"})
        })
      end

      assert ForagerSchemas.validate("sealed-plaintext.schema.json", plaintext.(16)) == :ok

      assert {:error, _reason} =
               ForagerSchemas.validate("sealed-plaintext.schema.json", plaintext.(17))
    end
  end
end
