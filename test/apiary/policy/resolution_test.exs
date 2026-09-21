defmodule Apiary.Policy.ResolutionTest do
  @moduledoc """
  The table of cases of rule resolution: add, disable, conflict, lock, wildcards, paths,
  credentials, and the deny list the document carries. Every case that resolves is
  rendered, and the render validated against the contract's schema.
  """
  use ExUnit.Case, async: true

  alias Apiary.Policy.{Render, Resolution, Rule, Schema}

  defp allow(host, opts \\ []), do: host_rule("allow", host, opts)
  defp deny(host, opts \\ []), do: host_rule("deny", host, opts)

  defp host_rule(action, host, opts) do
    %Rule{kind: "host", action: action, host: host, paths: opts[:paths], locked: !!opts[:locked]}
  end

  defp credential(action, name, opts \\ []) do
    %Rule{
      kind: "credential",
      action: action,
      name: name,
      argument: opts[:argument],
      locked: !!opts[:locked]
    }
  end

  # {name, hive rules, repository rules, allow, deny, paths, credentials}
  @resolved [
    {"nothing", [], [], [], [], %{}, []},
    {"add: the hive allows", [{:allow, "api.example"}], [], ["api.example"], [], %{}, []},
    {"add: the repository allows on top", [{:allow, "api.example"}], [{:allow, "mcp.example"}],
     ["api.example", "mcp.example"], [], %{}, []},
    {"disable: the repository denies a host of the hive, and the document says so",
     [{:allow, "api.example"}, {:allow, "cdn.example"}], [{:deny, "cdn.example"}],
     ["api.example"], ["cdn.example"], %{}, []},
    {"conflict: the repository's allow wins over the hive's deny", [{:deny, "mcp.example"}],
     [{:allow, "mcp.example"}], ["mcp.example"], [], %{}, []},
    {"lock: a locked deny holds against a repository allow, in deny",
     [{:deny, "mcp.example", locked: true}], [{:allow, "mcp.example"}], [], ["mcp.example"], %{},
     []},
    {"lock: a locked allow holds against a repository deny",
     [{:allow, "api.example", locked: true}], [{:deny, "api.example"}], ["api.example"], [], %{},
     []},
    {"a deny of something nothing allows is in deny: it holds under observe",
     [{:deny, "ads.example"}], [], [], ["ads.example"], %{}, []},
    {"deny: an exact deny under an allowed *. suffix stands beside it",
     [{:allow, "*.example"}, {:deny, "tracker.example"}], [], ["*.example"], ["tracker.example"],
     %{}, []},
    {"deny: a repository's deny under the hive's unlocked suffix stands",
     [{:allow, "*.s.example"}], [{:deny, "a.s.example"}], ["*.s.example"], ["a.s.example"], %{},
     []},
    {"deny: a narrower suffix denied under a wider one", [{:allow, "*.example"}],
     [{:deny, "*.s.example"}], ["*.example"], ["*.s.example"], %{}, []},
    {"deny: a locked suffix allow of the hive beats the repository's deny below it",
     [{:allow, "*.s.example", locked: true}], [{:deny, "a.s.example"}], ["*.s.example"], [], %{},
     []},
    {"deny: names before *. suffixes", [{:deny, "*.ads.example"}, {:deny, "tracker.example"}], [],
     [], ["tracker.example", "*.ads.example"], %{}, []},
    {"wildcards: names sort before suffixes", [{:allow, "*.example"}, {:allow, "example"}], [],
     ["example", "*.example"], [], %{}, []},
    {"wildcards: a *. deny takes out the allows it covers and is in deny",
     [{:allow, "a.s.example"}, {:allow, "*.b.s.example"}, {:allow, "s.example"}],
     [{:deny, "*.s.example"}], ["s.example"], ["*.s.example"], %{}, []},
    {"wildcards: a locked *. deny takes out the repository's allows below it",
     [{:deny, "*.s.example", locked: true}], [{:allow, "a.s.example"}, {:allow, "t.example"}],
     ["t.example"], ["*.s.example"], %{}, []},
    {"wildcards: an unlocked *. deny of the hive loses to a repository allow below it, and is not written",
     [{:deny, "*.s.example"}, {:allow, "b.s.example"}], [{:allow, "a.s.example"}],
     ["a.s.example"], [], %{}, []},
    {"wildcards: a locked allow stands under the hive's own unlocked *. deny, which is not written",
     [{:deny, "*.s.example"}, {:allow, "a.s.example", locked: true}], [], ["a.s.example"], [],
     %{}, []},
    {"wildcards: a repository's *. allow overrides the hive's deny below it",
     [{:deny, "a.s.example"}], [{:allow, "*.s.example"}], ["*.s.example"], [], %{}, []},
    {"paths: a host held to paths is in allow and in paths",
     [{:allow, "git.example", paths: ["/acme/shop.git/info/refs", "/acme/shop.git/*"]}], [],
     ["git.example"], [], %{"git.example" => ["/acme/shop.git/*", "/acme/shop.git/info/refs"]},
     []},
    {"paths: no path at all", [{:allow, "git.example", paths: []}], [], ["git.example"], [],
     %{"git.example" => []}, []},
    {"paths: the repository's rule decides the host whole",
     [{:allow, "git.example", paths: ["/a"]}], [{:allow, "git.example", paths: ["/b"]}],
     ["git.example"], [], %{"git.example" => ["/b"]}, []},
    {"paths: the repository opens every path", [{:allow, "git.example", paths: ["/a"]}],
     [{:allow, "git.example"}], ["git.example"], [], %{}, []},
    {"paths: a locked path list holds", [{:allow, "git.example", paths: ["/a"], locked: true}],
     [{:allow, "git.example"}], ["git.example"], [], %{"git.example" => ["/a"]}, []},
    {"paths: a name held to paths under a free suffix",
     [{:allow, "*.example"}, {:allow, "git.example", paths: ["/a"]}], [],
     ["git.example", "*.example"], [], %{"git.example" => ["/a"]}, []},
    {"paths: a denied host is never in paths", [{:allow, "git.example", paths: ["/a"]}],
     [{:deny, "git.example"}], [], ["git.example"], %{}, []},
    {"credentials: selected by name, sorted, with an argument",
     [{:credential, "allow", "product", argument: "acme/shop"}, {:credential, "allow", "model"}],
     [], [], [], %{}, [%{name: "model"}, %{name: "product", argument: "acme/shop"}]},
    {"credentials: the repository's argument wins",
     [{:credential, "allow", "product", argument: "acme/shop"}],
     [{:credential, "allow", "product", argument: "acme/site"}], [], [], %{},
     [%{name: "product", argument: "acme/site"}]},
    {"credentials: the repository disables one", [{:credential, "allow", "model"}],
     [{:credential, "deny", "model"}], [], [], %{}, []},
    {"credentials: a locked deny holds", [{:credential, "deny", "model", locked: true}],
     [{:credential, "allow", "model"}], [], [], %{}, []}
  ]

  # {name, hive rules, repository rules, what the sentence says}
  @refused [
    {"a suffix held to paths above another entry",
     [{:allow, "*.example", paths: ["/a"]}, {:allow, "git.example"}], [], ~r/one list of paths/},
    {"two suffixes held to paths, one above the other", [{:allow, "*.example", paths: ["/a"]}],
     [{:allow, "*.s.example", paths: ["/b"]}], ~r/one list of paths/}
  ]

  defp rules(specs) do
    Enum.map(specs, fn
      {:allow, host} -> allow(host)
      {:allow, host, opts} -> allow(host, opts)
      {:deny, host} -> deny(host)
      {:deny, host, opts} -> deny(host, opts)
      {:credential, action, name} -> credential(action, name)
      {:credential, action, name, opts} -> credential(action, name, opts)
    end)
  end

  for {name, hive, repository, allow, deny, paths, credentials} <- @resolved,
      mode <- ~w(observe enforce) do
    test "#{name} (#{mode})" do
      assert {:ok, effective} =
               Resolution.resolve(
                 unquote(mode),
                 rules(unquote(Macro.escape(hive))),
                 rules(unquote(Macro.escape(repository)))
               )

      assert effective.mode == unquote(mode)
      assert effective.allow == unquote(allow)
      assert effective.deny == unquote(deny)
      assert effective.paths == unquote(Macro.escape(paths))
      assert effective.credentials == unquote(Macro.escape(credentials))

      document = Render.document(effective)
      assert :ok = Schema.validate(document)
      assert document == Render.document(effective)

      policy = Jason.decode!(document)["security_policy"]
      assert policy["egress"]["allow"] == unquote(allow)
      # The deny list is written only when it holds something: the same rules render the
      # same bytes as before the document had one, and it holds under either mode.
      assert policy["egress"]["deny"] == if(unquote(deny) == [], do: nil, else: unquote(deny))
      # What the runner's proxy needs: a host in `paths` is in `allow`, and never in `deny`.
      assert Enum.all?(
               Map.keys(policy["egress"]["paths"] || %{}),
               &(&1 in policy["egress"]["allow"] and &1 not in unquote(deny))
             )
    end
  end

  for {name, hive, repository, sentence} <- @refused do
    test "refused: #{name}" do
      assert {:error, %Apiary.Policy.Error{reason: :conflict, message: message}} =
               Resolution.resolve(
                 "enforce",
                 rules(unquote(Macro.escape(hive))),
                 rules(unquote(Macro.escape(repository)))
               )

      assert message =~ unquote(Macro.escape(sentence))
    end
  end

  describe "the mode" do
    # {name, hive mode, the repository's own, repository?, mode in force, where from}
    @modes [
      {"the baseline has the hive's", "observe", nil, false, "observe", :hive},
      {"a repository follows the hive by default", "enforce", nil, true, "enforce", :hive},
      {"hive observe, repository enforce", "observe", "enforce", true, "enforce", :repository},
      {"hive enforce, repository observe", "enforce", "observe", true, "observe", :repository},
      {"the same mode said by the repository is still its own", "enforce", "enforce", true,
       "enforce", :repository},
      {"a mode without a repository is not the baseline's", "observe", "enforce", false,
       "observe", :hive},
      {"what is no mode follows the hive", "enforce", "log", true, "enforce", :hive}
    ]

    for {name, hive, own, repository?, mode, source} <- @modes do
      test name do
        id = if unquote(repository?), do: Ecto.UUID.generate()

        assert {:ok, effective} =
                 Resolution.resolve_for(
                   unquote(hive),
                   unquote(own),
                   [allow("api.example"), deny("mcp.example", locked: true)],
                   if(id, do: [allow("mcp.example")], else: []),
                   id
                 )

        assert effective.mode == unquote(mode)
        assert effective.mode_source == unquote(source)

        # The rules resolve the same under either mode: the locked deny holds, and it is
        # in the document's deny list, which a runner decides first whatever the mode.
        assert effective.allow == ["api.example"]
        assert effective.deny == ["mcp.example"]
        document = Render.document(effective)
        assert :ok = Schema.validate(document)
        egress = Jason.decode!(document)["security_policy"]["egress"]
        assert egress["mode"] == unquote(mode)
        assert egress["deny"] == ["mcp.example"]
      end
    end
  end

  describe "entries" do
    test "say where they came from, what is in force and what overrode what" do
      {:ok, effective} =
        Resolution.resolve(
          "enforce",
          [allow("api.example"), deny("mcp.example", locked: true), allow("cdn.example")],
          [deny("api.example"), allow("mcp.example")]
        )

      by = fn host, source ->
        Enum.find(effective.entries, &(&1.host == host and &1.source == source))
      end

      assert %{in_force: false, overridden_by: %{source: :repository, action: :deny}} =
               by.("api.example", :hive)

      assert %{in_force: true, overrides: [%{source: :hive, action: :allow}]} =
               by.("api.example", :repository)

      assert %{in_force: true, locked: true, overrides: [%{source: :repository}]} =
               by.("mcp.example", :hive)

      assert %{in_force: false, overridden_by: %{source: :hive, locked: true, action: :deny}} =
               by.("mcp.example", :repository)

      assert %{in_force: true, overridden_by: nil, overrides: []} = by.("cdn.example", :hive)
      assert effective.deny == ["api.example", "mcp.example"]
    end

    test "an allow a *. deny covers names the deny" do
      {:ok, effective} =
        Resolution.resolve("enforce", [allow("a.s.example")], [deny("*.s.example")])

      assert [
               %{host: "*.s.example", in_force: true},
               %{host: "a.s.example", in_force: false} = allow
             ] =
               Enum.sort_by(effective.entries, & &1.host)

      assert allow.overridden_by.host == "*.s.example"
    end

    test "a deny a locked *. allow covers names the allow; an unlocked one stands beside it" do
      {:ok, effective} =
        Resolution.resolve("observe", [allow("*.s.example", locked: true)], [deny("a.s.example")])

      assert %{in_force: false, overridden_by: %{host: "*.s.example", locked: true}} =
               Enum.find(effective.entries, &(&1.host == "a.s.example"))

      assert effective.deny == []

      {:ok, effective} =
        Resolution.resolve("observe", [allow("*.s.example")], [deny("a.s.example")])

      assert %{in_force: true, overridden_by: nil} =
               Enum.find(effective.entries, &(&1.host == "a.s.example"))

      assert effective.deny == ["a.s.example"]
    end

    test "a *. deny with a winning allow below it is in force, takes out what it outranks, and is not written" do
      {:ok, effective} =
        Resolution.resolve(
          "observe",
          [deny("*.s.example"), allow("b.s.example")],
          [allow("a.s.example")]
        )

      assert %{in_force: true, overrides: [%{host: "b.s.example"}]} =
               Enum.find(effective.entries, &(&1.host == "*.s.example"))

      assert effective.allow == ["a.s.example"]
      assert effective.deny == []
    end
  end

  describe "rendering" do
    test "is the same bytes whatever order the rules come in" do
      rules = [
        allow("b.example"),
        deny("*.ads.example"),
        allow("*.a.example"),
        deny("t.example"),
        allow("a.example", paths: ["/z", "/a"])
      ]

      documents =
        for order <- [rules, Enum.reverse(rules)] do
          {:ok, effective} = Resolution.resolve("enforce", order, [])
          Render.document(effective)
        end

      assert [document, document] = documents

      assert document ==
               ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"enforce","allow":["a.example","b.example","*.a.example"],"deny":["t.example","*.ads.example"],"paths":{"a.example":["/a","/z"]}}}})

      assert Render.digest(document) =~ ~r/\Asha256=[0-9a-f]{64}\z/
    end

    test "a hive with no rules renders observe and an empty allow, and no deny" do
      {:ok, effective} = Resolution.resolve("observe", [], [])

      assert Render.document(effective) ==
               ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"observe","allow":[]}}})
    end

    test "observe with a deny list: the contract's observe-deny fixture, from rules" do
      {:ok, effective} =
        Resolution.resolve(
          "observe",
          [
            allow("api.example"),
            allow("*.example"),
            deny("tracker.example"),
            deny("*.ads.example")
          ],
          []
        )

      assert Render.document(effective) ==
               ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"observe","allow":["api.example","*.example"],"deny":["tracker.example","*.ads.example"]}}})
    end
  end
end
