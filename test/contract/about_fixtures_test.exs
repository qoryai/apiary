defmodule Apiary.Contract.AboutFixturesTest do
  @moduledoc """
  Folds every `fixtures/run/about-*.json` of the server contract, from the runner's
  contract directory at the commit in `.runner-contract-ref`, as the `about` of a
  `dev.qory.run.started` (`Apiary.Runs.Fold`):

    * an accepted one keeps every member as given;
    * a refused one, `about-refused-<reason>.json`, loses the part its name says breaks a
      rule, and keeps the rest. The runner refuses the whole run for it; the fold, which
      reads what was stored, drops the part alone.

  A fixture this test does not know fails it, so a new rule is read here too.
  """
  use ExUnit.Case, async: true

  alias Apiary.Runs.Fold

  @moduletag :contract

  @fixtures (case Apiary.ContractFixtures.contract_dir() do
               nil ->
                 []

               dir ->
                 dir |> Path.join("fixtures/run/about-*.json") |> Path.wildcard() |> Enum.sort()
             end)

  @run %Apiary.Runs.Run{state: "pending", labels: %{}, args: []}
  @t0 ~U[2026-09-16 12:00:00.000000Z]

  defp fold(about) do
    data = %{
      "runtime" => "claude",
      "runtime_version" => "2.1.0",
      "command" => "claude",
      "args" => [],
      "dir" => "/work",
      "interactive" => false,
      "runner_version" => "0.4.0",
      "host" => "dev-laptop",
      "about" => about
    }

    event = %{
      sequence: 2,
      type: "dev.qory.run.started",
      data: data,
      time: @t0,
      received_at: @t0
    }

    %{run: run} = Fold.fold(@run, [event])
    {run.about_kind, run.about_title, run.about_subjects, run.about_details}
  end

  defp as_given(about),
    do: {about["kind"], about["title"], about["subjects"] || [], about["details"]}

  # What the fold keeps of a refused fixture: everything but the part its name says
  # breaks a rule.
  defp kept("about-refused-" <> reason, about) do
    {kind, title, subjects, details} = as_given(about)
    reason = reason |> String.trim_leading("beyond-schema-") |> String.trim_trailing(".json")
    bare = Enum.map(subjects, &Map.take(&1, ["type", "ref"]))

    case reason do
      r when r in ~w(kind-too-long kind-too-many-bytes) -> {nil, title, subjects, details}
      "title-" <> _ -> {kind, nil, subjects, details}
      "details-" <> _ when reason != "details-duplicate-key" -> {kind, title, subjects, nil}
      "url-" <> _ -> {kind, title, bare, details}
      "subject-unknown-member" -> {kind, title, bare, details}
      "subject-without-ref" -> {kind, title, [], details}
      "ref-too-long" -> {kind, title, [], details}
      "type-" <> _ -> {kind, title, [], details}
      "duplicate-subject" -> {kind, title, Enum.take(subjects, 1), details}
      "too-many-subjects" -> {kind, title, Enum.take(subjects, 16), details}
      "unknown-member" -> {kind, title, subjects, details}
      # A name given twice is gone once the event is decoded, the last value kept: the
      # runner refuses it, and the fold cannot see it.
      "details-duplicate-key" -> {kind, title, subjects, details}
    end
  end

  test "the contract has accepted and refused about fixtures" do
    names = Enum.map(@fixtures, &Path.basename/1)
    assert Enum.any?(names, &String.starts_with?(&1, "about-refused-"))
    assert Enum.any?(names, &(not String.starts_with?(&1, "about-refused-")))
  end

  for file <- @fixtures do
    @file_path file
    @name Path.basename(file)

    if String.starts_with?(@name, "about-refused-") do
      test "#{@name} loses what breaks the rule and keeps the rest" do
        about = @file_path |> File.read!() |> Jason.decode!()
        expected = kept(@name, about)

        assert fold(about) == expected
        assert expected != as_given(about) or @name =~ "duplicate-key" or @name =~ "unknown"
      end
    else
      test "#{@name} is kept as given" do
        about = @file_path |> File.read!() |> Jason.decode!()
        assert fold(about) == as_given(about)
      end
    end
  end

  test "a refused fixture loses its part, and only that" do
    about = fn name -> name |> fixture() |> Jason.decode!() end

    assert {nil, nil, [], nil} = fold(about.("about-refused-kind-too-long.json"))

    assert {_, _, [%{"url" => "https://qory.example/examples/7"}], _} =
             fold(about.("about-refused-beyond-schema-duplicate-subject.json"))

    assert {_, _, subjects, _} = fold(about.("about-refused-too-many-subjects.json"))
    assert Enum.map(subjects, & &1["ref"]) == Enum.map(0..15, &Integer.to_string/1)

    assert {nil, "Fix the failing build", [], nil} =
             fold(about.("about-refused-unknown-member.json"))

    assert {_, _, [%{"type" => "example", "ref" => "7"} = subject], _} =
             fold(about.("about-refused-subject-unknown-member.json"))

    assert map_size(subject) == 2
  end

  defp fixture(name) do
    Apiary.ContractFixtures.contract_dir()
    |> Path.join("fixtures/run")
    |> Path.join(name)
    |> File.read!()
  end
end
