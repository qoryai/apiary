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

  test "the sentence of a call that did not end in a new sign-in names its cause" do
    for {outcome, cause} <- [
          {"sign_in_needed", "refresh_token_reused"},
          {"failed", "http_503"},
          {"failed", "superseded"}
        ] do
      assert sentence(Map.merge(@details, %{"outcome" => outcome, "cause" => cause})) ==
               "Qory Apiary could not refresh the sign-in of the key main of OpenAI subscription: #{cause}"
    end
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
