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
end
