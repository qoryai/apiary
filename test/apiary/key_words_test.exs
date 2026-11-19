defmodule Apiary.KeyWordsTest do
  # Each value once called "machine key" or "start key" is named for what it is: a
  # machine's access key, a machine harness setting, a machine type, a local model
  # provider credential, and the default model provider credential. The credential a
  # session starts on is `model_provider_credential_name`, once `model_credential`. This
  # test checks that no file of the code, the documents, the guides or the messages
  # contains "machine key", "machine's key" or "start key", in the singular or the plural,
  # on one line or across two, with a comment's `#` between the words too, or
  # `model_credential`.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  @files ["lib/**/*", "docs/**/*", "guides/**/*", "priv/gettext/**/*"]

  @words [
    ~r/\bmachine(?:'s)?(?:\s|#)+keys?\b/i,
    ~r/\bstart(?:\s|#)+keys?\b/i,
    ~r/\bmodel_credential\b/
  ]

  defp files do
    for pattern <- @files,
        path <- Path.wildcard(Path.join(@root, pattern)),
        File.regular?(path),
        relative = Path.relative_to(path, @root),
        uniq: true,
        do: relative
  end

  defp findings(file) do
    text = File.read!(Path.join(@root, file))

    if String.valid?(text) do
      for word <- @words,
          [{at, _length}] <- Regex.scan(word, text, return: :index),
          do: "#{file}:#{line(text, at)}: #{binary_part(text, at, min(20, byte_size(text) - at))}"
    else
      []
    end
  end

  defp line(text, at), do: text |> binary_part(0, at) |> String.split("\n") |> length()

  test "the words match the old names, on one line or across two" do
    for text <- [
          "a machine key",
          "the machine's keys",
          "the start key",
          "the start\n  # key",
          ~s("model_credential")
        ] do
      assert Enum.any?(@words, &Regex.match?(&1, text)), text
    end

    for text <- [
          "a machine's access key",
          "a machine type key",
          "the start of a key",
          "default_model_provider_credential_name"
        ] do
      refute Enum.any?(@words, &Regex.match?(&1, text)), text
    end
  end

  test "no code, document, guide or message contains machine key, start key or model_credential" do
    held = files()
    assert "lib/apiary_web/live/node_live/access_key.ex" in held
    assert "priv/gettext/default.pot" in held
    assert "lib/apiary/stacks/documents.schema.json" in held

    found = Enum.flat_map(held, &findings/1)
    assert found == [], "these files use an old name:\n" <> Enum.join(found, "\n")
  end
end
