defmodule Apiary.ModelKeys.GateTest do
  # A model key's value reaches a run through one function only,
  # `Apiary.ModelKeys.reveal_for_sealing/4`. The test reads the source of `lib/`: no module
  # but the gate calls `Login.access_token/3`, the one function that returns a sign-in's
  # token, no module outside `Login` calls `Login.tokens/2`, which returns both tokens,
  # and the secrets request calls the gate and reveals nothing itself. The reveal of a
  # secret by its public id (`Apiary.Secrets.reveal_for_sealing/3`) has no caller, and
  # refuses the secret of a provider whose keys are sign-ins (`secrets/login_secret_test`).
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

  test "no module reads a key's value for sealing but the gate and the sign-in refresh" do
    assert files_with(~r/Secrets\.reveal_key_and_set_at\(/) == ["apiary/model_keys.ex"]
    assert files_with(~r/reveal_key_for_sealing/) == []
  end

  test "only Login reads the document of a sign-in, with its refresh token" do
    assert files_with(~r/Secrets\.reveal_login/) == ["apiary/model_keys/login.ex"]
    assert files_with(~r/import Apiary\.Secrets\b/) == []
  end

  test "no module outside Login calls Login.tokens/2" do
    assert files_with(~r/Login\.tokens\b/) == []
  end

  test "no module calls Secrets.reveal_for_sealing/3, which refuses a sign-in's secret" do
    assert files_with(~r/Secrets\.reveal_for_sealing\(/) == []

    assert files_with(~r/\breveal_for_sealing\(/) == [
             "apiary/model_keys.ex",
             "apiary/runs/secrets_request.ex",
             "apiary/secrets.ex"
           ]
  end

  test "tokens/2 is not documented" do
    {:docs_v1, _anno, _lang, _format, _doc, _meta, docs} = Code.fetch_docs(Apiary.ModelKeys.Login)

    assert {_name, _anno, _signature, :hidden, _meta} =
             Enum.find(docs, &match?({{:function, :tokens, 2}, _, _, _, _}, &1))
  end

  test "access_token/3 is not documented" do
    {:docs_v1, _anno, _lang, _format, _doc, _meta, docs} = Code.fetch_docs(Apiary.ModelKeys.Login)

    assert {_name, _anno, _signature, :hidden, _meta} =
             Enum.find(docs, &match?({{:function, :access_token, 3}, _, _, _, _}, &1))
  end
end
