defmodule ApiaryWeb.ActivityModelKeyRefreshTest do
  # The Activity lines of the refresh of a model key's sign-in (`model_key.refresh`,
  # `Apiary.ModelKeys.Login`): the sentences, made from the entry's details alone, and the
  # filter, which does not offer the action. An entry names the key by the identity line it
  # stored (`Apiary.ModelKeys.Identity`); an entry written before that has the key's value
  # id and the provider's name, and keeps its words.
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
  @identity "OpenAI subscription · dana@example.com"
  @with_identity Map.put(@details, "identity", @identity)

  describe "an entry with the identity line of the key" do
    test "a refresh that worked, with no value id or provider's name in the words" do
      assert sentence(Map.put(@with_identity, "outcome", "refreshed")) ==
               "Qory Apiary refreshed the sign-in of #{@identity}"

      # No value id and no provider's name: the line is all an entry needs.
      assert sentence(%{"outcome" => "refreshed", "identity" => @identity}) ==
               "Qory Apiary refreshed the sign-in of #{@identity}"
    end

    test "a refusal that stays asks the person to sign in again" do
      for {cause, words} <- [
            {"refresh_token_expired", "the saved sign-in has expired"},
            {"invalid_grant", "OpenAI no longer accepts this sign-in"},
            {"token_not_stored", "Qory Apiary could not save the new sign-in"}
          ] do
        details = Map.merge(@with_identity, %{"outcome" => "sign_in_needed", "cause" => cause})

        assert sentence(details) ==
                 "Sign in again on #{@identity}: Qory Apiary could not refresh its sign-in, " <>
                   "because #{words} (#{cause})"
      end
    end

    test "an answer with no account id asks to sign in to ChatGPT again for the key" do
      details =
        Map.merge(@with_identity, %{"outcome" => "sign_in_needed", "cause" => "no_account"})

      assert sentence(details) ==
               "Sign in to ChatGPT again for #{@identity}: Qory Apiary could not refresh the " <>
                 "sign-in, because OpenAI returned no account id (no_account)"

      # An entry with the account line as its identity names it the same way.
      assert sentence(%{
               "outcome" => "sign_in_needed",
               "cause" => "no_account",
               "identity" => "OpenAI subscription · account …4f2a"
             }) =~ "again for OpenAI subscription · account …4f2a: Qory Apiary"
    end

    test "a failure that may pass says why and when the next call is" do
      details =
        Map.merge(@with_identity, %{
          "outcome" => "failed",
          "cause" => "timeout",
          "retry_at" => "2026-11-18T14:05:30Z"
        })

      assert sentence(details) ==
               "Qory Apiary could not refresh the sign-in of #{@identity}: the refresh request " <>
                 "to OpenAI timed out (timeout). It tries again at 2026-11-18 14:05 UTC"

      assert sentence(Map.delete(details, "retry_at")) == nil
      assert sentence(Map.put(details, "cause", "superseded")) == nil
    end

    test "a refresh address off the allowed list names the identity and the description's provider" do
      details =
        Map.merge(@with_identity, %{
          "outcome" => "failed",
          "cause" => "bad_endpoint",
          "retry_at" => "2026-11-18T14:05:30Z"
        })

      assert sentence(details) ==
               "Qory Apiary could not refresh the sign-in of #{@identity}: the refresh address " <>
                 "in the description of OpenAI subscription is not on the allowed list " <>
                 "(bad_endpoint). Ask the author of that description to correct it"
    end

    test "a refusal with a cause that is no word of the refresh has no sentence" do
      for cause <- ["refreshed", "x", "http_503"] do
        details = Map.merge(@with_identity, %{"outcome" => "sign_in_needed", "cause" => cause})
        assert sentence(details) == nil
      end
    end
  end

  describe "an entry written before the identity line" do
    test "keeps its words, with the key's value id and the provider's name" do
      assert sentence(Map.put(@details, "outcome", "refreshed")) ==
               "Qory Apiary refreshed the sign-in of the key main of OpenAI subscription"

      details = Map.merge(@details, %{"outcome" => "sign_in_needed", "cause" => "no_account"})

      assert sentence(details) ==
               "Sign in again on #{@key_of}: Qory Apiary could not refresh its sign-in, " <>
                 "because OpenAI returned no account id (no_account)"
    end
  end

  test "a refusal that stays asks the person to sign in again, in words, with the code" do
    for {cause, words} <- [
          {"refresh_token_expired", "the saved sign-in has expired"},
          {"refresh_token_reused",
           "this sign-in's refresh token was already used, for example by another program"},
          {"refresh_token_invalidated", "OpenAI ended this sign-in"},
          {"invalid_grant", "OpenAI no longer accepts this sign-in"},
          {"refresh_unauthorized", "OpenAI returned HTTP 401 to the refresh"},
          {"token_not_stored", "Qory Apiary could not save the new sign-in"},
          {"no_account", "OpenAI returned no account id"}
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

  test "a failure that may pass with no stored retry time has no sentence" do
    assert sentence(Map.merge(@details, %{"outcome" => "failed", "cause" => "timeout"})) == nil
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
