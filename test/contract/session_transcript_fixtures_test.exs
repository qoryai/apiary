defmodule Apiary.Contract.SessionTranscriptFixturesTest do
  # The Forager contract's fixtures of a session's transcript and of a run configuration
  # with `resume`, vendored at the commit in `.forager-contract-ref`: each chunk of the
  # transcript batch passes the vendored schema and `Apiary.Runs.Transcript.parse/1`, each
  # invalid chunk is refused by both, the resume fixture passes the run configuration
  # schema as Forager and Qory Apiary read it, and each invalid resume is refused by both.
  use ExUnit.Case, async: true

  alias Apiary.ForagerSchemas
  alias Apiary.Policy.Schema
  alias Apiary.Runs.Transcript

  @moduletag :contract

  @root Path.expand("../..", __DIR__)
  @fixtures "test/fixtures/forager-contract/"
  @schema "events/session.transcript.schema.json"

  defp fixture(path) do
    assert (@fixtures <> path) in Apiary.ContractFixtures.vendored(), path
    File.read!(Path.join([@root, @fixtures, path]))
  end

  test "each chunk of the transcript batch passes the schema and is read as it is" do
    events = "link/link-batch-session-transcript.json" |> fixture() |> Jason.decode!()
    chunks = for %{"type" => "dev.qory.session.transcript"} = event <- events, do: event
    assert length(chunks) >= 2

    for %{"data" => data} <- chunks do
      assert ForagerSchemas.validate(@schema, data) == :ok
      assert {:ok, chunk} = Transcript.parse(data)
      assert chunk.bytes == Base.decode64!(data["bytes"])

      assert {chunk.session, chunk.session_id, chunk.path, chunk.offset} ==
               {data["session"], data["session_id"], data["path"], data["offset"]}
    end
  end

  test "each invalid chunk is refused by the schema and by the server" do
    for file <- ~w(event-session-transcript-no-session-id.json
                   event-session-transcript-offset-negative.json
                   event-session-transcript-over-32-kib.json
                   event-session-transcript-session-zero.json) do
      %{"data" => data} = ("invalid/" <> file) |> fixture() |> Jason.decode!()
      assert {:error, _} = ForagerSchemas.validate(@schema, data), file
      assert Transcript.parse(data) == :error, file
    end
  end

  test "the resume fixture passes the run configuration schema, and each invalid one fails" do
    bytes = fixture("run-configuration/resume.json")
    assert ForagerSchemas.validate("run-configuration.schema.json", bytes) == :ok
    assert Schema.validate(bytes) == :ok

    for file <- ~w(run-configuration-resume-no-session-id.json
                   run-configuration-resume-run-id-upper-case.json) do
      bytes = fixture("invalid/" <> file)
      assert {:error, _} = ForagerSchemas.validate("run-configuration.schema.json", bytes), file
      assert {:error, _} = Schema.validate(bytes), file
    end
  end
end
