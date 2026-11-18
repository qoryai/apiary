defmodule Apiary.ModelKeys.GateTest do
  # A model key's value reaches a run through one function only,
  # `Apiary.ModelKeys.reveal_for_sealing/4`. The test reads the source of `lib/`: no module
  # but the gate calls `Login.access_token/3`, the one function that returns a sign-in's
  # token, and the secrets request calls the gate and no reveal of its own.
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)

  defp files do
    @lib |> Path.join("**/*.ex") |> Path.wildcard() |> Enum.sort()
  end

  defp files_with(pattern) do
    for file <- files(), File.read!(file) =~ pattern, do: Path.relative_to(file, @lib)
  end

  test "the gate is the only caller of Login.access_token/3 outside Login" do
    assert files_with(~r/\baccess_token\(/) == [
             "apiary/model_keys.ex",
             "apiary/model_keys/login.ex"
           ]

    assert files_with(~r/Login\.access_token\(/) == ["apiary/model_keys.ex"]
  end

  test "the secrets request reveals a key through the gate alone" do
    source = File.read!(Path.join(@lib, "apiary/runs/secrets_request.ex"))

    assert source =~ "ModelKeys.reveal_for_sealing("
    refute source =~ ~r/access_token\(/
    refute source =~ ~r/reveal_key_(and_set_at|for_sealing)\(/
    refute source =~ ~r/reveal_login/
  end

  test "no module but the gate and the sign-in's own refresh reads a key's value for sealing" do
    assert files_with(~r/Secrets\.reveal_key_and_set_at\(/) == ["apiary/model_keys.ex"]
    assert files_with(~r/Secrets\.reveal_key_for_sealing\(/) == []
  end

  test "access_token/3 is not documented" do
    {:docs_v1, _anno, _lang, _format, _doc, _meta, docs} = Code.fetch_docs(Apiary.ModelKeys.Login)

    assert {_name, _anno, _signature, :hidden, _meta} =
             Enum.find(docs, &match?({{:function, :access_token, 3}, _, _, _, _}, &1))
  end
end
