defmodule Apiary.Contract.DemoRunsTest do
  @moduledoc """
  The recorded runs under `priv/demo`, which `mix apiary.demo` replays, are the server
  contract's: each registration validates against `run-registration.schema.json`, every
  line of its events against `event.schema.json` and so against the data schema of its
  type, `about` of `run.started` among it, and the two read as the record of one run.
  """
  use ExUnit.Case, async: true

  alias Apiary.ContractSchema

  @files Mix.Tasks.Apiary.Demo.files()

  # Only the tests tagged :contract read the schema; without the contract's directory
  # they are excluded (test/test_helper.exs) and the rest still runs.
  setup_all do
    case Apiary.ContractFixtures.contract_dir() do
      nil ->
        :ok

      dir ->
        %{
          schema: ContractSchema.event!(dir),
          registration_schema: ContractSchema.schema!(dir, "run-registration.schema.json")
        }
    end
  end

  defp events(file) do
    file |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp registration(file),
    do:
      file |> Path.dirname() |> Path.join("registration.json") |> File.read!() |> Jason.decode!()

  test "there are demo runs" do
    assert length(@files) >= 3
  end

  @tag :contract
  test "the schema refuses an event that is not the contract's", %{schema: schema} do
    [event | _] = events(hd(@files))

    assert :ok = ContractSchema.validate(schema, event)
    assert {:error, _} = ContractSchema.validate(schema, Map.put(event, "sequence", "2"))
    # The ping has left the contract.
    assert {:error, _} = ContractSchema.validate(schema, Map.put(event, "type", "dev.qory.ping"))
  end

  for file <- @files do
    @file_path file
    @name file |> Path.dirname() |> Path.basename()

    @tag :contract
    test "the registration of #{@name} is valid under run-registration.schema.json", %{
      registration_schema: schema
    } do
      assert :ok = ContractSchema.validate(schema, registration(@file_path))
    end

    @tag :contract
    test "every line of #{@name} is valid under event.schema.json", %{schema: schema} do
      for event <- events(@file_path) do
        assert :ok = ContractSchema.validate(schema, event),
               "sequence #{event["sequence"]} of #{@name}"
      end
    end

    # A gateway's start says only the details its run credential maps, never a title.
    test "#{@name} says in its start what the run is about, with a title from a session" do
      case Enum.filter(events(@file_path), &(&1["type"] == "dev.qory.run.started")) do
        [] ->
          assert @name == "registered-only"

        [%{"data" => %{"opened_by" => "gateway"}} = started] ->
          assert %{"details" => %{}} = started["data"]["about"]

        [started] ->
          assert %{"title" => "" <> _} = started["data"]["about"]
      end
    end

    test "#{@name} is the record of one run: one subject, contiguous sequences after the registration's, unique ids, time in order" do
      %{"run_id" => subject, "time" => registered} = registration(@file_path)
      events = events(@file_path)

      assert Enum.all?(events, &(&1["subject"] == subject))
      assert Enum.all?(events, &(&1["source"] == "urn:qory:run:" <> subject))

      # The registration stands for sequence 1, which is never posted.
      assert Enum.map(events, &String.to_integer(&1["sequence"])) ==
               Enum.to_list(2..(length(events) + 1)//1)

      assert events |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == length(events)

      times = Enum.map(events, &(&1["time"] |> DateTime.from_iso8601() |> elem(1)))
      {:ok, registered, 0} = DateTime.from_iso8601(registered)
      assert [registered | times] == Enum.sort([registered | times], DateTime)
    end
  end
end
