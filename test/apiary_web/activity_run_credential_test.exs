defmodule ApiaryWeb.ActivityRunCredentialTest do
  # The Activity lines of a run's work credential, sent to its gateway or refused
  # (`run_credential.issue`, `Apiary.Runs.WorkCredential`): the label in the filter,
  # offered there, and the sentences, made from the entry's details alone.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer
  alias ApiaryWeb.Activity.Describer.Core

  @details %{
    "run_id" => "6f1c2a40-1d2e-4b5f-9a8b-0c1d2e3f4a5b",
    "connection_id" => "ac_0123456789abcdef",
    "adapter_id" => "na_0123456789abcdef",
    "collection_id" => "sc_0123456789abcdef",
    "target_path" => "acme/shop",
    "access" => "write",
    "purpose" => "work",
    "credential" => "work-1"
  }

  defp sentence(details) do
    entry = %Entry{action: "run_credential.issue", actor_kind: :access_key, details: details}
    Enum.find_value(Describer.describers(), & &1.sentence(:"run_credential.issue", entry, %{}))
  end

  test "the label, offered in the filter" do
    %{scope: scope} = sign_up_fixture()
    assert Core.label(:"run_credential.issue") == "Run access sent or refused"
    assert Core.offered?(scope, :"run_credential.issue")
  end

  test "the sentence of a credential sent, with its expiry or none" do
    issued =
      Map.merge(@details, %{"outcome" => "issued", "expires_at" => "2026-10-25T13:00:00Z"})

    assert sentence(issued) ==
             "Received write access to acme/shop for the run, until 2026-10-25 13:00 UTC"

    assert sentence(Map.delete(issued, "expires_at")) ==
             "Received write access to acme/shop for the run, with no end time"
  end

  test "the sentence of a refusal names its cause in a few groups" do
    for {outcome, cause} <- [
          {"connection_gone", "the connection is no longer connected"},
          {"adapter_key_missing", "the adapter has no access key in use"},
          {"timeout", "the call to the adapter timed out"},
          {"unreachable", "the call to the adapter failed"},
          {"refused", "the adapter returned a refusal"},
          {"host_outside_entry",
           "the credential from the adapter reaches beyond the run's access"},
          {"token_padded", "the credential from the adapter is invalid"},
          {"invalid_answer", "the credential from the adapter is invalid"},
          {"apply_moved",
           "the credential from the adapter covers other hosts or paths than at the run's start"}
        ] do
      assert sentence(Map.merge(@details, %{"outcome" => outcome, "access" => "read"})) ==
               "Was refused read access to acme/shop for the run: #{cause}"
    end
  end

  test "every cause of a refusal has its words" do
    for cause <- Apiary.Runs.WorkCredential.causes() do
      assert sentence(Map.put(@details, "outcome", Atom.to_string(cause))) =~
               ~r/\AWas refused write access to acme\/shop for the run: the /
    end
  end
end
