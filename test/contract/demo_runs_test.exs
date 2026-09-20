defmodule Apiary.Contract.DemoRunsTest do
  @moduledoc """
  The recorded runs under `priv/demo`, which `mix apiary.demo` replays, are events of the
  server contract: every line validates against the contract's `event.schema.json` and
  so against the data schema of its type, and a file reads as the record of one run.
  """
  use ExUnit.Case, async: true

  alias Apiary.ContractSchema

  @files Mix.Tasks.Apiary.Demo.files()

  # Only the tests tagged :contract read the schema; without the contract's directory
  # they are excluded (test/test_helper.exs) and the rest still runs.
  setup_all do
    case Apiary.ContractFixtures.contract_dir() do
      nil -> :ok
      dir -> %{schema: ContractSchema.event!(dir)}
    end
  end

  defp events(file) do
    file |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  test "there are demo runs" do
    assert length(@files) >= 3
  end

  @tag :contract
  test "the schema refuses an event that is not the contract's", %{schema: schema} do
    [ping | _] = events(hd(@files))

    assert :ok = ContractSchema.validate(schema, ping)
    assert {:error, _} = ContractSchema.validate(schema, put_in(ping, ["data", "events"], "*"))
    assert {:error, _} = ContractSchema.validate(schema, Map.put(ping, "sequence", "1"))
  end

  for file <- @files do
    @file_path file
    @name file |> Path.dirname() |> Path.basename()

    @tag :contract
    test "every line of #{@name} is valid under event.schema.json", %{schema: schema} do
      for event <- events(@file_path) do
        assert :ok = ContractSchema.validate(schema, event),
               "sequence #{event["sequence"]} of #{@name}"
      end
    end

    test "#{@name} is the record of one run: one subject, contiguous sequences, unique ids, time in order" do
      events = events(@file_path)
      [%{"subject" => subject, "type" => first} | _] = events

      assert first == "ai.qory.ping"
      assert Enum.all?(events, &(&1["subject"] == subject))
      assert Enum.all?(events, &(&1["source"] == "urn:qory:run:" <> subject))

      assert Enum.map(events, &String.to_integer(&1["sequence"])) ==
               Enum.to_list(1..length(events))

      assert events |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == length(events)

      times = Enum.map(events, & &1["time"])
      assert times == Enum.sort(times)
    end
  end
end
