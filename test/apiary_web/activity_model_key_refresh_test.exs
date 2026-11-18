defmodule ApiaryWeb.ActivityModelKeyRefreshTest do
  # The Activity lines of the refresh of a model key's sign-in (`model_key.refresh`,
  # `Apiary.ModelKeys.Login`): the sentences, made from the entry's details alone, and the
  # filter, which does not offer the action.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer
  alias ApiaryWeb.Activity.Describer.Core

  @details %{
    "provider_id" => "pr_0123456789abcdef",
    "provider" => "OpenAI subscription",
    "value_id" => "main",
    "trigger" => "run",
    "run_id" => "run-1",
    "refresh_reason" => "proactive_expiry"
  }

  defp sentence(details) do
    entry = %Entry{action: "model_key.refresh", actor_kind: :instance, details: details}
    Enum.find_value(Describer.describers(), & &1.sentence(:"model_key.refresh", entry, %{}))
  end

  test "the sentence of a refresh that worked" do
    assert sentence(Map.put(@details, "outcome", "refreshed")) ==
             "Qory Apiary refreshed the sign-in of the key main of OpenAI subscription"
  end

  @key_of "the key main of OpenAI subscription"

  test "a refusal that stays asks the person to sign in again, in words, with the code" do
    for {cause, words} <- [
          {"refresh_token_expired", "the saved sign-in has expired"},
          {"refresh_token_reused",
           "this sign-in's refresh token was already used, for example by another program"},
          {"refresh_token_invalidated", "OpenAI ended this sign-in"},
          {"invalid_grant", "OpenAI no longer accepts this sign-in"},
          {"refresh_unauthorized", "OpenAI returned HTTP 401 to the refresh"}
        ] do
      assert sentence(Map.merge(@details, %{"outcome" => "sign_in_needed", "cause" => cause})) ==
               "Sign in again on the key main of OpenAI subscription: Qory Apiary could not " <>
                 "refresh its sign-in, because #{words} (#{cause})"
    end
  end

  test "a failure that may pass says why and when the next call is, at the stored time" do
    retry_at = "2026-11-18T14:05:30.123456Z"

    for {cause, words} <- [
          {"http_503", "OpenAI returned HTTP 503 to the refresh"},
          {"http_429", "OpenAI returned HTTP 429 to the refresh"},
          {"timeout", "the refresh request to OpenAI timed out"},
          {"network", "Qory Apiary could not connect to OpenAI"},
          {"bad_response", "OpenAI's response to the refresh was not in the expected form"}
        ] do
      details =
        Map.merge(@details, %{"outcome" => "failed", "cause" => cause, "retry_at" => retry_at})

      assert sentence(details) ==
               "Qory Apiary could not refresh the sign-in of #{@key_of}: #{words} (#{cause}). " <>
                 "It tries again at 2026-11-18 14:05 UTC"
    end
  end

  test "a failure with no stored retry time says no time" do
    assert sentence(Map.merge(@details, %{"outcome" => "failed", "cause" => "timeout"})) ==
             "Qory Apiary could not refresh the sign-in of #{@key_of}: the refresh request " <>
               "to OpenAI timed out (timeout)"
  end

  test "a refresh address off the allowed list asks the author of the description" do
    text =
      sentence(
        Map.merge(@details, %{
          "outcome" => "failed",
          "cause" => "bad_endpoint",
          "retry_at" => "2026-11-18T14:05:30Z"
        })
      )

    assert text ==
             "Qory Apiary could not refresh the sign-in of #{@key_of}: the refresh address in " <>
               "the description of OpenAI subscription is not on the allowed list " <>
               "(bad_endpoint). Ask the author of that description to correct it"
  end

  test "a cause that is no word of the refresh has no sentence, so no raw code stands alone" do
    for cause <- ["superseded", "not_stored", "other", "http_", "http_5000"] do
      assert sentence(Map.merge(@details, %{"outcome" => "failed", "cause" => cause})) == nil
    end

    for cause <- ["refreshed", "x", "http_503"] do
      assert sentence(Map.merge(@details, %{"outcome" => "sign_in_needed", "cause" => cause})) ==
               nil
    end
  end

  test "no sentence has a token of the details in it" do
    details =
      Map.merge(@details, %{
        "outcome" => "failed",
        "cause" => "http_503",
        "retry_at" => "2026-11-18T14:05:30Z",
        "access_token" => "eyJ-secret-access",
        "refresh_token" => "rt-secret"
      })

    refute sentence(details) =~ "secret"
  end

  test "an entry that lacks what the sentence needs has no sentence" do
    assert sentence(%{"outcome" => "refreshed"}) == nil
    assert sentence(Map.put(@details, "outcome", "failed")) == nil
  end

  test "the filter does not offer the action, and no label is made for it" do
    %{scope: scope} = sign_up_fixture()
    refute Core.offered?(scope, :"model_key.refresh")
    assert Core.label(:"model_key.refresh") == nil
  end
end
