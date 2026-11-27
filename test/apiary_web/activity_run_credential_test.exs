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
          {"connection_gone",
           "the connection is not connected, or does not match the run's organisation and adapter"},
          {"adapter_key_missing", "the adapter is deleted or has no access key in use"},
          {"timeout", "the call to the adapter timed out"},
          {"unreachable", "the call to the adapter failed"},
          {"call_failed", "the call to the adapter failed"},
          {"refused", "the adapter returned a refusal"},
          {"entry_invalid", "Qory Apiary could not check the credential from the adapter"},
          {"now_invalid", "Qory Apiary could not check the credential from the adapter"},
          {"host_outside_entry",
           "the credential from the adapter reaches beyond the run's access"},
          {"token_padded", "the credential from the adapter is invalid"},
          {"invalid_answer", "the credential from the adapter is invalid"},
          {"apply_moved",
           "the credential from the adapter differs from the one at the run's start"},
          {"run_not_live", "the run ended before the credential could be sealed"},
          {"seal_failed", "the credential could not be sealed for the gateway"},
          {"not_recorded", "the credential could not be recorded, so it was not sent"},
          {"other_credential_failed",
           "the request failed for another credential of the run, so this one was not sent"}
        ] do
      assert sentence(Map.merge(@details, %{"outcome" => outcome, "access" => "read"})) ==
               "Was refused read access to acme/shop for the run: #{cause}"
    end
  end

  test "every cause of a refusal has its words" do
    for cause <- Apiary.Runs.WorkCredential.causes() do
      assert sentence(Map.put(@details, "outcome", Atom.to_string(cause))) =~
               ~r/\AWas refused write access to acme\/shop for the run: (the|Qory Apiary|only) /
    end
  end

  describe "a harness credential" do
    @harness %{
      "run_id" => "6f1c2a40-1d2e-4b5f-9a8b-0c1d2e3f4a5b",
      "adapter_id" => "na_0123456789abcdef",
      "access" => "read",
      "purpose" => "harness",
      "credential" => "harness-1",
      "sources" => ["code.example.com/acme/harness", "code.example.com/acme/tools"]
    }

    test "sent: the sources it reads, and its expiry" do
      issued =
        Map.merge(@harness, %{"outcome" => "issued", "expires_at" => "2026-10-25T13:00:00Z"})

      assert sentence(issued) ==
               "Received read access to the harness sources code.example.com/acme/harness, code.example.com/acme/tools for the run, until 2026-10-25 13:00 UTC"
    end

    test "refused: the sources and the cause" do
      assert sentence(Map.put(@harness, "outcome", "timeout")) ==
               "Was refused read access to the harness sources code.example.com/acme/harness, code.example.com/acme/tools for the run: the call to the adapter timed out"
    end

    test "for a hidden harness, no source" do
      hidden = @harness |> Map.delete("sources") |> Map.put("harness_hidden", true)

      assert sentence(
               Map.merge(hidden, %{"outcome" => "issued", "expires_at" => "2026-10-25T13:00:00Z"})
             ) ==
               "Received read access to the run's harness sources, until 2026-10-25 13:00 UTC"

      assert sentence(Map.put(hidden, "outcome", "refused")) ==
               "Was refused read access to the run's harness sources: the adapter returned a refusal"
    end

    test "sent with no end time, with the sources or without" do
      issued = Map.put(@harness, "outcome", "issued")

      assert sentence(issued) ==
               "Received read access to the harness sources code.example.com/acme/harness, code.example.com/acme/tools for the run, with no end time"

      hidden = issued |> Map.delete("sources") |> Map.put("harness_hidden", true)

      assert sentence(hidden) ==
               "Received read access to the run's harness sources, with no end time"
    end

    test "refused because the run's machine is not one Qory Apiary provides" do
      assert sentence(Map.put(@harness, "outcome", "machine_not_provided")) ==
               "Was refused read access to the harness sources code.example.com/acme/harness, code.example.com/acme/tools for the run: only machines that Qory Apiary provides may receive these sources"
    end

    test "refused because the run may no longer use the grant" do
      assert sentence(Map.put(@harness, "outcome", "harness_not_allowed")) ==
               "Was refused read access to the harness sources code.example.com/acme/harness, code.example.com/acme/tools for the run: the access to these sources has ended for this organisation"
    end
  end
end
