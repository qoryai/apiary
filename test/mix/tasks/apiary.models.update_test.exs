defmodule Mix.Tasks.Apiary.Models.UpdateTest do
  # `mix apiary.models.update` against a saved copy of the models.dev list, trimmed to a
  # few models of each mapped provider, with entries it must leave out beside them; no
  # test downloads anything.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Apiary.Models.Update

  @moduletag :tmp_dir

  @fixture "test/fixtures/models_dev/api.json"

  @expected """
  {
    "anthropic": [
      {"id": "claude-fable-5-1", "title": "Claude Fable 5.1"},
      {"id": "claude-haiku-5-5", "title": "Claude Haiku 5.5"},
      {"id": "claude-opus-4-7", "title": "Claude Opus 4.7"},
      {"id": "claude-opus-5-5", "title": "Claude Opus 5.5"},
      {"id": "claude-sonnet-5-5", "title": "Claude Sonnet 5.5"}
    ],
    "claude-subscription": [
      {"id": "claude-fable-5-1", "title": "Claude Fable 5.1"},
      {"id": "claude-haiku-5-5", "title": "Claude Haiku 5.5"},
      {"id": "claude-opus-4-7", "title": "Claude Opus 4.7"},
      {"id": "claude-opus-5-5", "title": "Claude Opus 5.5"},
      {"id": "claude-sonnet-5-5", "title": "Claude Sonnet 5.5"}
    ],
    "deepseek": [
      {"id": "deepseek-flash", "title": "DeepSeek V4.1 Flash 1017"},
      {"id": "deepseek-v4-pro", "title": "DeepSeek V4 Pro"}
    ],
    "litellm": [],
    "openrouter": [
      {"id": "anthropic/claude-opus-5.5", "title": "Claude Opus 5.5"},
      {"id": "anthropic/claude-sonnet-5.5", "title": "Claude Sonnet 5.5"},
      {"id": "openai/o3-mini", "title": "o3-mini"}
    ]
  }
  """

  setup %{tmp_dir: dir} do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
    %{output: Path.join(dir, "suggestions.json")}
  end

  test "writes each provider's models in the order of the id, the same bytes each run", %{
    output: output
  } do
    Update.run(["--file", @fixture, "--output", output])
    assert File.read!(output) == @expected

    assert_received {:mix_shell, :info, [line]}

    assert line ==
             "Wrote #{output}: anthropic 5, claude-subscription 5, deepseek 2, litellm 0, openrouter 3."

    Update.run(["--file", @fixture, "--output", output])
    assert File.read!(output) == @expected
    assert Path.wildcard(output <> ".*") == []
  end

  test "leaves out and prints each deprecated model and each odd id, title or entry", %{
    output: output
  } do
    Update.run(["--file", @fixture, "--output", output])

    left_out =
      for {:mix_shell, :error, [line]} <- Process.info(self(), :messages) |> elem(1), do: line

    assert left_out == [
             ~s|Left out deepseek "deepseek-v4-flash": models.dev marks it deprecated.|,
             ~s|Left out deepseek "deepseek-v4-pro": another model has the same id.|,
             ~s|Left out openrouter "example bad id": the id is not 1 to 128 letters, digits and ._:/@+-, from a letter or digit.|,
             ~s|Left out openrouter "example/markup": the title is not 1 to 128 letters, digits, spaces and .,:()/+&'_-, from a letter or digit.|,
             ~s|Left out openrouter "example/no-title": it has no title string.|,
             ~s|Left out openrouter "google/gemini-2.5-pro": models.dev marks it deprecated.|,
             ~s|Left out openrouter "openai/o3-mini": another model has the same id.|,
             ~s|Left out openrouter "~anthropic/claude-opus-latest": the id is not 1 to 128 letters, digits and ._:/@+-, from a letter or digit.|,
             "Left out openrouter nil: it is not an object with an id."
           ]
  end

  test "keeps one model per id, the first in the order of the title, and leaves out the rest" do
    api = Jason.decode!(File.read!(@fixture))
    {[{"deepseek", models}], left_out} = Update.build(api, ["deepseek"])

    assert %{id: "deepseek-v4-pro", title: "DeepSeek V4 Pro"} in models
    assert Enum.count(models, &(&1.id == "deepseek-v4-pro")) == 1
    assert {"deepseek", "deepseek-v4-pro", "another model has the same id"} in left_out
  end

  test "maps claude-subscription to Anthropic's ids and gives litellm none" do
    api = Jason.decode!(File.read!(@fixture))

    {suggestions, _left_out} =
      Update.build(api, ["litellm", "claude-subscription", "anthropic"])

    assert [{"anthropic", same}, {"claude-subscription", same}, {"litellm", []}] = suggestions
    assert length(same) == 5
  end

  test "stops at a provider it does not map, at a missing provider and at too many models" do
    api = Jason.decode!(File.read!(@fixture))

    assert_raise Mix.Error, ~r/Add example to @sources/, fn -> Update.build(api, ["example"]) end

    assert_raise Mix.Error, "The models.dev list has no models object for deepseek.", fn ->
      Update.build(Map.delete(api, "deepseek"), ["deepseek"])
    end

    models = Map.new(1..1_001, &{"m-#{&1}", %{"id" => "m-#{&1}", "name" => "M #{&1}"}})

    assert_raise Mix.Error, "models.dev lists 1001 models for deepseek, over 1000.", fn ->
      Update.build(%{"deepseek" => %{"models" => models}}, ["deepseek"])
    end
  end

  test "refuses a file over 32 MB and input that is not a JSON object, and writes nothing", %{
    tmp_dir: dir,
    output: output
  } do
    File.write!(output, "kept")

    big = Path.join(dir, "big.json")
    {:ok, file} = :file.open(big, [:write, :raw, :binary])
    :ok = :file.pwrite(file, 32_000_000, "x")
    :ok = :file.close(file)

    assert_raise Mix.Error, "#{big} has 32000001 bytes, over the limit of 32000000.", fn ->
      Update.run(["--file", big, "--output", output])
    end

    for {body, message} <- [
          {"{\"anthropic\": ", ~r/\AThe models.dev list is not JSON: /},
          {"[1, 2]", ~r/\AThe models.dev list is not a JSON object\.\z/},
          {~s({"anthropic": {"models": []}}), ~r/no models object for anthropic/}
        ] do
      bad = Path.join(dir, "bad.json")
      File.write!(bad, body)
      assert_raise Mix.Error, message, fn -> Update.run(["--file", bad, "--output", output]) end
    end

    assert File.read!(output) == "kept"
  end
end
