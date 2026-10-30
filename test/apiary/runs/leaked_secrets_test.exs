defmodule Apiary.Runs.LeakedSecretsTest do
  # The secrets a run prints, found as the projection stores its log chunks and folds its
  # events (`Apiary.Runs.LeakedSecrets`): where each one is kept, never the secret; one
  # that two chunks split, in one pass and in two; the cap and the count beyond it, which a
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
             "This key is compromised: it was printed into the run's log. Replace it."
  end

  test "finds a secret that two chunks of a step split, in one pass and in two", ctx do
    {head, tail} = String.split_at(ctx.secret, 10)

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

  test "event_text/1 is each key and string, keys sorted, one per line" do
    assert LeakedSecrets.event_text(%{"b" => ["x", 1, %{"d" => "y", "c" => nil}], "a" => "z"}) ==
             "a\nz\nb\nx\nc\nd\ny"
  end
end
