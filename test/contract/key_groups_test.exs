defmodule Apiary.Contract.KeyGroupsTest do
  # A run's model keys of two providers against Forager's contract at the commit in
  # `.forager-contract-ref`: the run configuration's API credentials, as
  # `Apiary.Runs.ProviderCredential.entry/4` writes them, each with `group`, its
  # provider's public id, pass the vendored run configuration schema, and fail it without
  # `group` or with more than 6 of them; and a link run answer whose `credential_hosts`
  # entries of those keys have `group` passes the contract's schema, and fails it with
  # `group` and no `format`.
  use ExUnit.Case, async: true

  import Apiary.ContractFixtures

  alias Apiary.{ContractSchema, ForagerSchemas}
  alias Apiary.Policy.Schema
  alias Apiary.Runs.ProviderCredential

  @moduletag :contract

  @northwind %{
    "format" => "anthropic-messages",
    "endpoint" => "https://api.northwind.example/anthropic",
    "auth" => %{"scheme" => "header", "header" => "x-api-key"}
  }

  @checkout %{
    "format" => "openai-responses",
    "endpoint" => "https://api.checkout.example/v1",
    "auth" => %{"scheme" => "bearer"}
  }

  # The keys of the two providers in the order a claim stores them: the start key's
  # provider's first, then one key of the other provider.
  defp entries do
    [
      ProviderCredential.entry("con_n0rthw1nd0000001-1", "con_n0rthw1nd0000001", @northwind, %{
        "chosen" => true,
        "pause_for_s" => 60
      }),
      ProviderCredential.entry("con_n0rthw1nd0000001-2", "con_n0rthw1nd0000001", @northwind, %{
        "pause_for_s" => 60
      }),
      ProviderCredential.entry("con_ch3ck0ut00000001-1", "con_ch3ck0ut00000001", @checkout, %{
        "pause_for_s" => 60
      })
    ]
  end

  defp configuration(credentials) do
    %{
      "version" => 1,
      "model_credential" => "con_n0rthw1nd0000001-1",
      "credentials" => credentials
    }
    |> Jason.encode!()
  end

  defp valid?(bytes),
    do:
      ForagerSchemas.validate("run-configuration.schema.json", bytes) == :ok and
        Schema.validate(bytes) == :ok

  test "the API credentials of two providers, each with its group, pass the run configuration schema" do
    entries = entries()

    assert Enum.map(entries, &Jason.decode!(Jason.encode!(&1))["group"]) ==
             ~w(con_n0rthw1nd0000001 con_n0rthw1nd0000001 con_ch3ck0ut00000001)

    assert valid?(configuration(entries))
  end

  test "an API credential without group fails the run configuration schema" do
    [first | rest] = entries() |> Jason.encode!() |> Jason.decode!()
    refute valid?(configuration([Map.delete(first, "group") | rest]))
  end

  test "a seventh API credential across the groups fails the run configuration schema" do
    seven =
      for n <- 1..7 do
        {group, api} =
          if n <= 4,
            do: {"con_n0rthw1nd0000001", @northwind},
            else: {"con_ch3ck0ut00000001", @checkout}

        ProviderCredential.entry("#{group}-#{n}", group, api)
      end

    assert valid?(configuration(Enum.take(seven, 6)))
    refute valid?(configuration(seven))
  end

  describe "the link run answer" do
    defp schema, do: ContractSchema.schema!(contract_dir(), "link-run-answer.schema.json")

    # The contract's answer with a sealed credential, its model key replaced by the keys
    # of two providers, each entry with its group.
    defp answer do
      answer = Jason.decode!(contract_file!("link/link-run-answer-sealed-credential.json"))
      [forge | _model] = answer["credential_hosts"]

      model = fn name, group, api ->
        %{
          "name" => name,
          "hosts" => [URI.parse(api["endpoint"]).host],
          "placeholders" => [],
          "auth" => api["auth"],
          "format" => api["format"],
          "endpoint" => api["endpoint"],
          "group" => group
        }
      end

      %{
        answer
        | "credential_hosts" => [
            forge,
            model.("con_n0rthw1nd0000001-1", "con_n0rthw1nd0000001", @northwind),
            model.("con_ch3ck0ut00000001-1", "con_ch3ck0ut00000001", @checkout)
          ],
          "model_credential" => "con_n0rthw1nd0000001-1"
      }
    end

    test "with credential_hosts of two groups passes the contract's schema" do
      assert ContractSchema.validate(schema(), answer()) == :ok
    end

    test "with group and no format on a credential_hosts entry fails the contract's schema" do
      answer = answer()
      [forge, northwind, checkout] = answer["credential_hosts"]

      broken = %{
        answer
        | "credential_hosts" => [forge, Map.drop(northwind, ["format", "endpoint"]), checkout]
      }

      assert {:error, _refused} = ContractSchema.validate(schema(), broken)
    end
  end
end
