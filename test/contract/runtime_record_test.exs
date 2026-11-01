defmodule Apiary.Contract.RuntimeRecordTest do
  @moduledoc """
  The synthetic run with runtime texts, tool results and denials
  (`Apiary.RunEventsFixtures.runtime_record/0`), which the run page's Transcript is tested
  on, is the server contract's: every event, in its envelope, is valid under
  `event.schema.json` and so under the data schema of its type, from Forager's contract
  directory at the commit in `.forager-contract-ref`.
  """
  use ExUnit.Case, async: true

  alias Apiary.ContractSchema

  @moduletag :contract

  @run_id "2291d8cd-c310-711e-bec2-7378a661c935"

  setup_all do
    case Apiary.ContractFixtures.contract_dir() do
      nil -> :ok
      dir -> %{schema: ContractSchema.event!(dir)}
    end
  end

  # The event as Forager sends it: the CloudEvents envelope around the data.
  defp envelope({sequence, type, data}) do
    %{
      "specversion" => "1.0",
      "id" => Ecto.UUID.generate(),
      "source" => "urn:qory:run:" <> @run_id,
      "type" => "dev.qory." <> type,
      "subject" => @run_id,
      "time" => "2026-11-01T12:00:00.000Z",
      "sequence" => String.pad_leading(Integer.to_string(sequence), 10, "0"),
      "dataschema" => "https://qory.dev/contracts/forager/v1/events/#{type}.schema.json",
      "data" => data
    }
  end

  test "every event of the runtime record is valid under event.schema.json", %{schema: schema} do
    refused =
      for {sequence, type, _data} = event <- Apiary.RunEventsFixtures.runtime_record(),
          ContractSchema.validate(schema, envelope(event)) != :ok,
          do: {sequence, type}

    assert refused == []
  end

  test "the schema refuses a text without its kind", %{schema: schema} do
    text = {1, "runtime.text", %{"session_id" => "s", "text" => "Hello, Dana"}}
    assert {:error, _} = ContractSchema.validate(schema, envelope(text))
  end
end
