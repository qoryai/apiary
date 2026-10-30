defmodule Apiary.Runs.LeakedSecretsTest do
  # The secrets a run prints, found as the projection stores its log chunks and folds its
  # events (`Apiary.Runs.LeakedSecrets`): where each one is kept, never the secret; one
  # that two chunks split, in one pass and in two, across the events between them, and
  # none across an event that has not arrived; the cap and the count beyond it, which a
  # rebuild does not count twice; and what is read back, with the value while the text is
  # kept. A machine log's and a release reason's are `Apiary.Runs.DiagnosticsTest`'s.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Repo
  alias Apiary.Runs.{Event, LeakedSecret, LeakedSecrets, LogChunk, Projector, Run}

  @github "ghp_" <> String.duplicate("c", 36)

  setup do
    %{scope: scope} = sign_up_fixture()
    %{access_key: key, secret: seed} = access_key_fixture(scope)
    secret = "qak_" <> Base.url_encode64(seed, padding: false)
    run = run_fixture(scope, %{public_id: Run.new_public_id()})
    %{scope: scope, run: run, key: key, secret: secret}
  end

  defp log_data(text), do: %{"stream" => "terminal", "bytes" => Base.encode64(text)}

  defp project!(run) do
    {:ok, run} = Projector.project(run)
    run
  end

  defp rows(run) do
    Repo.all(
      from l in LeakedSecret,
        where: l.run_id == ^run.id,
        order_by: [l.source_sequence, l.offset]
    )
  end

  defp read(run) do
    run = Repo.get!(Run, run.id)
    LeakedSecrets.read(run, nil, events: from(e in Event, where: e.run_id == ^run.id))
  end

  test "keeps where a secret in the log, a step's output and an event is, never the secret",
       ctx do
    events_fixture(ctx.run, [
      {1, "run.log", log_data("token #{@github}\n")},
      {2, "run.log", step_log_data(3, "key=#{ctx.secret}\n")},
      {3, "run.started", %{"env" => %{"TOKEN" => ctx.secret}, "list" => [1, @github]}}
    ])

    project!(ctx.run)

    assert [
             %LeakedSecret{place: "log", kind: "github_token", step: nil, source_sequence: 1} =
               log,
             %LeakedSecret{place: "step", kind: "access_key", step: 3, source_sequence: 2} =
               step,
             %LeakedSecret{place: "event", kind: "access_key", source_sequence: 3} = event,
             %LeakedSecret{place: "event", kind: "github_token", source_sequence: 3}
           ] = rows(ctx.run)

    assert {log.offset, log.length} == {6, 40}
    assert {step.offset, step.length, step.matched_id} == {4, 47, ctx.key.key_id}
    assert event.matched_id == ctx.key.key_id and log.matched_id == nil
    assert DateTime.compare(step.at, at(2)) == :eq and DateTime.compare(event.at, at(3)) == :eq

    # No column holds the secret.
    for row <- rows(ctx.run), {_field, value} <- Map.from_struct(row), is_binary(value) do
      refute value =~ "qak_" or value =~ "ghp_"
    end

    {entries, 0} = read(ctx.run)
    assert Enum.map(entries, & &1.value) == [@github, ctx.secret, ctx.secret, @github]

    assert [
             %{place: "log", step: nil, sequence: nil, id: nil},
             %{place: "step", step: 3, sequence: nil, id: id},
             %{place: "event", step: nil, sequence: 3},
             %{place: "event", sequence: 3}
           ] = entries

    assert id == ctx.key.key_id

    assert hd(entries).message ==
             "This secret is compromised: it was printed into the run's log. Replace it."
  end

  test "finds a secret that two chunks of a step split, in one pass and in two", ctx do
    {head, tail} = String.split_at(ctx.secret, 10)

    # Another event's output between the two pieces.
    events_fixture(ctx.run, [
      {1, "run.log", step_log_data(1, "first #{head}")},
      {2, "run.log", log_data("outside every step\n")},
      {3, "run.log", step_log_data(1, tail <> " end\n")}
    ])

    project!(ctx.run)
    assert [%{place: "step", source_sequence: 1, offset: 6, length: 47}] = rows(ctx.run)

    other = run_fixture(ctx.scope, %{public_id: Run.new_public_id()})
    events_fixture(other, [{1, "run.log", log_data("a\nkey " <> head)}])
    project!(other)
    assert rows(other) == []

    {middle, last} = String.split_at(tail, 20)
    events_fixture(other, [{2, "run.log", log_data(middle)}])
    project!(other)
    events_fixture(other, [{3, "run.log", log_data(last <> "\n")}])
    project!(other)

    assert [%{place: "log", source_sequence: 1, offset: 6, length: 47, matched_id: id}] =
             rows(other)

    assert id == ctx.key.key_id
    assert {[%{value: value}], 0} = read(other)
    assert value == ctx.secret
  end

  @heartbeat %{"elapsed_seconds" => 30, "interval_seconds" => 30}

  test "finds a secret that a heartbeat splits, in one pass and in two", ctx do
    key = "sk-ant-api03-" <> String.duplicate("a", 95)
    assert byte_size(key) == 108
    {head, tail} = String.split_at(key, 20)

    events_fixture(ctx.run, [
      {1, "run.log", log_data("k " <> head)},
      {2, "run.heartbeat", @heartbeat},
      {3, "run.log", log_data(tail <> "\n")}
    ])

    project!(ctx.run)

    assert [%{kind: "anthropic_api_key", source_sequence: 1, offset: 2, length: 108}] =
             rows(ctx.run)

    assert {[%{value: ^key}], 0} = read(ctx.run)

    # The heartbeat in the pass of the first piece, or in that of the second.
    for passes <- [[[1, 2], [3]], [[1], [2, 3]], [[1], [2], [3]]] do
      other = run_fixture(ctx.scope, %{public_id: Run.new_public_id()})

      events = %{
        1 => {1, "run.log", log_data("k " <> head)},
        2 => {2, "run.heartbeat", @heartbeat},
        3 => {3, "run.log", log_data(tail <> "\n")}
      }

      for pass <- passes do
        events_fixture(other, Enum.map(pass, &events[&1]))
        project!(other)
      end

      assert [%{source_sequence: 1, offset: 2, length: 108}] = rows(other), inspect(passes)
      assert {[%{value: ^key}], 0} = read(other)
    end
  end

  test "reads no secret across an event that has not arrived, and finds it once it has",
       ctx do
    {head, tail} = String.split_at(ctx.secret, 10)

    # Both pieces in one pass, without the event between them.
    events_fixture(ctx.run, [
      {1, "run.log", log_data("key " <> head)},
      {3, "run.log", log_data(tail <> "\n")}
    ])

    project!(ctx.run)
    assert rows(ctx.run) == []

    # The second piece projected while the chunk before it has not arrived, then that
    # chunk late.
    ctx = %{ctx | run: run_fixture(ctx.scope, %{public_id: Run.new_public_id()})}
    events_fixture(ctx.run, [{1, "run.log", log_data("key " <> head)}])
    project!(ctx.run)
    events_fixture(ctx.run, [{3, "run.log", log_data(tail <> "\n")}])
    project!(ctx.run)
    events_fixture(ctx.run, [{2, "run.log", log_data("late\n")}])
    project!(ctx.run)
    assert rows(ctx.run) == []

    # The event between the pieces projected while an earlier event of the run had not
    # arrived, and that event still missing as the pass of the second piece begins.
    other = run_fixture(ctx.scope, %{public_id: Run.new_public_id()})

    events_fixture(other, [
      {2, "run.log", log_data("key " <> head)},
      {3, "run.heartbeat", @heartbeat}
    ])

    project!(other)
    events_fixture(other, [{4, "run.log", log_data(tail <> "\n")}])
    project!(other)
    assert rows(other) == []

    # The same, with the earlier event arriving before the pass of the second piece: no
    # event before the one between is missing then, and the secret is found.
    late = run_fixture(ctx.scope, %{public_id: Run.new_public_id()})

    events_fixture(late, [
      {2, "run.log", log_data("key " <> head)},
      {3, "run.heartbeat", @heartbeat}
    ])

    project!(late)
    events_fixture(late, [{1, "run.log", log_data("start\n")}])
    project!(late)
    assert Repo.get!(Run, late.id).projected_sequence == 3
    events_fixture(late, [{4, "run.log", log_data(tail <> "\n")}])
    project!(late)

    assert [%{source_sequence: 2, offset: 4, length: 47}] = rows(late)
  end

  test "finds a secret that starts a chunk after a colour code that ends the one before",
       ctx do
    events_fixture(ctx.run, [
      {1, "run.log", log_data("token: \e[32m")},
      {2, "run.log", log_data(@github <> "\e[0m\n")}
    ])

    project!(ctx.run)

    assert [%{kind: "github_token", source_sequence: 2, offset: 0, length: 40}] =
             rows(ctx.run)

    assert {[%{value: @github}], 0} = read(ctx.run)
  end

  test "finds a secret after a colour code that the end of a pass cut", ctx do
    for {head, rest} <- [{"token \e", "[32m"}, {"token \e[1", ";32m"}] do
      run = run_fixture(ctx.scope, %{public_id: Run.new_public_id()})
      events_fixture(run, [{1, "run.log", log_data(head)}])
      project!(run)
      events_fixture(run, [{2, "run.log", log_data(rest <> @github <> "\n")}])
      project!(run)

      assert [%{kind: "github_token", source_sequence: 2, offset: 4, length: 40}] = rows(run),
             inspect(head)
    end
  end

  test "keeps the whole of a secret that two chunks of one pass split", ctx do
    key = "sk-ant-api03-" <> String.duplicate("x", 93) <> "AA"
    assert byte_size(key) == 108
    {head, tail} = String.split_at(key, 60)

    events_fixture(ctx.run, [
      {1, "run.log", log_data("export KEY=" <> head)},
      {2, "run.log", log_data(tail <> "\n")}
    ])

    project!(ctx.run)

    assert [%{kind: "anthropic_api_key", source_sequence: 1, offset: 11, length: 108}] =
             rows(ctx.run)

    assert {[%{value: ^key}], 0} = read(ctx.run)
  end

  test "keeps the first 1000, counts the rest, and counts none twice when rebuilt", ctx do
    text = Enum.map_join(1..1001, "\n", fn _ -> @github end)
    events_fixture(ctx.run, [{1, "run.log", log_data(text)}])
    project!(ctx.run)

    assert length(rows(ctx.run)) == 1000
    assert Repo.get!(Run, ctx.run.id).leaked_secrets_omitted == 1

    {:ok, _run} = Projector.rebuild(Repo.get!(Run, ctx.run.id))
    assert length(rows(ctx.run)) == 1000
    assert Repo.get!(Run, ctx.run.id).leaked_secrets_omitted == 1

    {entries, omitted} = read(ctx.run)
    assert length(entries) == 1000 and omitted == 1
  end

  test "a secret has no value once its text is gone", ctx do
    events_fixture(ctx.run, [
      {1, "run.log", log_data("token #{@github}\n")},
      {2, "run.started", %{"token" => @github}}
    ])

    project!(ctx.run)
    Repo.delete_all(from l in LogChunk, where: l.run_id == ^ctx.run.id)
    Repo.delete_all(from e in Event, where: e.run_id == ^ctx.run.id)

    assert {[%{place: "log"} = log, %{place: "event"} = event], 0} = read(ctx.run)
    assert log.value == nil and event.value == nil
  end

  test "the table is indexed by organisation and by workspace, for the purge" do
    %{rows: rows} =
      Repo.query!("SELECT indexdef FROM pg_indexes WHERE tablename = 'leaked_secrets'")

    definitions = List.flatten(rows)
    assert Enum.any?(definitions, &(&1 =~ ~r/\(organisation_id\)\z/))
    assert Enum.any?(definitions, &(&1 =~ ~r/\(workspace_id\)\z/))
  end

  test "event_text/1 is each key and string, keys sorted, one per line" do
    assert LeakedSecrets.event_text(%{"b" => ["x", 1, %{"d" => "y", "c" => nil}], "a" => "z"}) ==
             "a\nz\nb\nx\nc\nd\ny"
  end
end
