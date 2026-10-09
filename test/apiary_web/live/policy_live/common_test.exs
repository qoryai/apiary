defmodule ApiaryWeb.PolicyLive.CommonTest do
  use ExUnit.Case, async: true

  # The security policy: left out of a run without the security feature.
  @moduletag needs: :security

  alias ApiaryWeb.PolicyLive.Common

  describe "export_head/3" do
    test "a subject that breaks a line stays inside its comment" do
      for breaker <- ["\n", "\r\n", "\r", <<0x85::utf8>>, <<0x2028::utf8>>, <<0x2029::utf8>>] do
        head =
          Common.export_head(
            "git.example/acme#{breaker}server: https://evil.example",
            3,
            "sha256=ab"
          )

        assert [first, second, ""] = String.split(head, "\n")

        assert first ==
                 "# Qory policy of git.example/acme server: https://evil.example, version 3"

        assert second == "# sha256=ab"
        refute head =~ ~r/[\r\x{85}\x{2028}\x{2029}]/u
      end
    end
  end

  test "pretty/1 keeps the served order and shows what is not JSON as it is" do
    document =
      ~s({"version":1,"security_policy":{"egress":{"mode":"observe","allow":["a.example"]}}})

    assert Common.pretty(document) ==
             """
             {
               "version": 1,
               "security_policy": {
                 "egress": {
                   "mode": "observe",
                   "allow": [
                     "a.example"
                   ]
                 }
               }
             }\
             """

    assert Common.pretty("not json") == "not json"
  end

  test "parameters: a page is a small positive integer, a rule a host in the grammar" do
    assert Common.page_param("3") == 3

    for bad <- ["-1", "0", "9999999", "1e3", "\0", "", nil, ["1"]],
        do: assert(Common.page_param(bad) == 1)

    assert Common.rule_param(" api.example ") == "api.example"
    for bad <- ["API.example", "a\0b", "", nil, %{}], do: assert(Common.rule_param(bad) == nil)
  end

  describe "a change made while the policy still named credentials" do
    # As the history holds one: a credential rule has a name and an argument, no host.
    defp change(action, before, after_) do
      %Apiary.Policy.Change{
        action: action,
        subject: "forge-token",
        before: %{"mode" => "observe", "rules" => before},
        after: %{"mode" => "observe", "rules" => after_}
      }
    end

    @credential %{
      "kind" => "credential",
      "action" => "allow",
      "host" => nil,
      "paths" => nil,
      "name" => "forge-token",
      "argument" => "acme/shop",
      "locked" => false
    }

    test "reads in plain words" do
      added = change("rule_added", [], [@credential])
      removed = change("rule_removed", [@credential], [])
      changed = change("rule_changed", [@credential], [%{@credential | "argument" => "acme/lib"}])

      assert flat(Common.change_sentence(added, "dana")) ==
               "dana added the credential forge-token acme/shop"

      assert flat(Common.change_sentence(removed, "dana")) ==
               "dana removed the credential forge-token acme/shop"

      assert flat(Common.change_sentence(changed, "dana")) ==
               "dana changed the argument of the credential forge-token acme/lib"

      assert Common.change_words(added) == "Credential forge-token"
      assert flat(Common.rule_words(@credential)) == "Credential forge-token acme/shop"
      assert %{added: [@credential]} = Apiary.Policy.diff(added)
    end
  end

  defp flat(text) when is_binary(text), do: text
  defp flat({_tag, inner}), do: flat(inner)
  defp flat({_tag, inner, _class}), do: flat(inner)
  defp flat(list) when is_list(list), do: Enum.map_join(list, &flat/1)
end
