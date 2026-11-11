defmodule Apiary.Contract.ModelKeysFixturesTest do
  # The Forager contract's fixtures of a model keys report and its answer, vendored at the
  # commit in `.forager-contract-ref`: each report fixture passes the vendored schema and
  # `Apiary.ModelKeys.Report.parse/3`, each invalid report fixture is refused by both,
  # the invalid answer fixture is refused by the schema, and the answer the server writes
  # for the states of the answer fixture is that fixture.
  use ExUnit.Case, async: true

  alias Apiary.ForagerSchemas
  alias Apiary.ModelKeys.{Report, State}
  alias Apiary.Runs.Batch

  @moduletag :contract

  @root Path.expand("../..", __DIR__)
  @fixtures "test/fixtures/forager-contract/"

  defp fixture(path), do: File.read!(Path.join([@root, @fixtures, path]))

  test "each report fixture passes the schema and is read as it is" do
    for path <- ~w(model-keys-report/report.json model-keys-report/report-cooldowns.json
                   model-keys-report/report-empty.json) do
      assert (@fixtures <> path) in Apiary.ContractFixtures.vendored(), path
      bytes = fixture(path)
      body = Jason.decode!(bytes)
      assert ForagerSchemas.validate("model-keys-report.schema.json", body) == :ok, path

      {:ok, time} = Batch.time(body["time"])
      assert {:ok, report} = Report.parse(bytes, body["run_id"], time), path
      assert report.time == time

      assert Enum.map(report.keys, &{&1.credential, &1.window, &1.status}) ==
               Enum.map(body["keys"], &{&1["credential"], &1["window"], &1["status"]})

      for {item, wire} <- Enum.zip(report.keys, body["keys"]) do
        assert item.cooldown_until == time(wire["cooldown_until"]), path
        assert item.observed_at == time(wire["observed_at"]), path
      end
    end
  end

  test "each invalid report fixture is refused by the schema and by the server" do
    for {file, name} <- [
          {"model-keys-report-cooldown-allowed.json", "keys.cooldown_until"},
          {"model-keys-report-no-observed-at.json", "keys"},
          {"model-keys-report-rejected-without-cooldown.json", "keys.cooldown_until"},
          {"model-keys-report-time-fraction.json", "time"},
          {"model-keys-report-unknown-source.json", "keys.source"},
          {"model-keys-report-unknown-status.json", "keys.status"},
          {"model-keys-report-utilization-over-100.json", "keys.utilization"},
          {"model-keys-report-window-upper-case.json", "keys.window"}
        ] do
      path = "invalid/" <> file
      assert (@fixtures <> path) in Apiary.ContractFixtures.vendored(), path
      bytes = fixture(path)
      body = Jason.decode!(bytes)
      assert {:error, _} = ForagerSchemas.validate("model-keys-report.schema.json", body), path

      {:ok, time} = Batch.time(body["time"])
      assert Report.parse(bytes, body["run_id"], time) == {:error, :invalid_request, name}, path
    end
  end

  test "the invalid answer fixture is refused by the schema" do
    path = "invalid/model-keys-answer-no-version.json"
    assert (@fixtures <> path) in Apiary.ContractFixtures.vendored()
    assert {:error, _} = ForagerSchemas.validate("model-keys-answer.schema.json", fixture(path))
  end

  test "the answer to the answer fixture's states is that fixture" do
    for path <- ~w(model-keys-answer/answer.json model-keys-answer/answer-empty.json) do
      assert (@fixtures <> path) in Apiary.ContractFixtures.vendored(), path
      body = Jason.decode!(fixture(path))
      assert ForagerSchemas.validate("model-keys-answer.schema.json", body) == :ok, path

      states =
        for wire <- body["keys"] do
          {wire["credential"],
           %State{
             window: wire["window"],
             status: wire["status"],
             resets_at: time(wire["resets_at"]),
             utilization: wire["utilization"],
             cooldown_until: time(wire["cooldown_until"]),
             source: wire["source"],
             observed_at: time(wire["observed_at"])
           }}
        end

      answer = Report.body(states)
      assert Jason.decode!(answer) == body, path
      assert ForagerSchemas.validate("model-keys-answer.schema.json", answer) == :ok, path
    end
  end

  defp time(nil), do: nil

  defp time(wire) do
    {:ok, time} = Batch.time(wire)
    time
  end
end
