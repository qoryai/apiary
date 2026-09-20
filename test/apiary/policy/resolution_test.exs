defmodule Apiary.Policy.ResolutionTest do
  @moduledoc """
  The table of cases of rule resolution: add, disable, conflict, lock, wildcards, paths,
  credentials. Every case that resolves is rendered, and the render validated against
  the contract's schema.
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

  # {name, hive rules, repository rules, allow, paths, credentials}
  @resolved [
    {"nothing", [], [], [], %{}, []},
    {"add: the hive allows", [{:allow, "api.example"}], [], ["api.example"], %{}, []},
    {"add: the repository allows on top", [{:allow, "api.example"}], [{:allow, "mcp.example"}],
     ["api.example", "mcp.example"], %{}, []},
    {"disable: the repository denies a host of the hive",
     [{:allow, "api.example"}, {:allow, "cdn.example"}], [{:deny, "cdn.example"}],
     ["api.example"], %{}, []},
    {"conflict: the repository's allow wins over the hive's deny", [{:deny, "mcp.example"}],
     [{:allow, "mcp.example"}], ["mcp.example"], %{}, []},
    {"lock: a locked deny holds against a repository allow",
     [{:deny, "mcp.example", locked: true}], [{:allow, "mcp.example"}], [], %{}, []},
    {"lock: a locked allow holds against a repository deny",
     [{:allow, "api.example", locked: true}], [{:deny, "api.example"}], ["api.example"], %{}, []},
    {"a deny of something nothing allows changes nothing", [{:deny, "ads.example"}], [], [], %{},
     []},
    {"wildcards: names sort before suffixes", [{:allow, "*.example"}, {:allow, "example"}], [],
     ["example", "*.example"], %{}, []},
    {"wildcards: a *. deny removes the allows it covers",
     [{:allow, "a.s.example"}, {:allow, "*.b.s.example"}, {:allow, "s.example"}],
     [{:deny, "*.s.example"}], ["s.example"], %{}, []},
    {"wildcards: a locked *. deny removes the repository's allows below it",
     [{:deny, "*.s.example", locked: true}], [{:allow, "a.s.example"}, {:allow, "t.example"}],
     ["t.example"], %{}, []},
    {"wildcards: an unlocked *. deny of the hive loses to a repository allow below it",
     [{:deny, "*.s.example"}, {:allow, "b.s.example"}], [{:allow, "a.s.example"}],
     ["a.s.example"], %{}, []},
    {"wildcards: a locked allow stands under the hive's own unlocked *. deny",
     [{:deny, "*.s.example"}, {:allow, "a.s.example", locked: true}], [], ["a.s.example"], %{},
     []},
    {"wildcards: a repository's *. allow overrides the hive's deny below it",
     [{:deny, "a.s.example"}], [{:allow, "*.s.example"}], ["*.s.example"], %{}, []},
    {"paths: a host held to paths is in allow and in paths",
     [{:allow, "git.example", paths: ["/acme/shop.git/info/refs", "/acme/shop.git/*"]}], [],
     ["git.example"], %{"git.example" => ["/acme/shop.git/*", "/acme/shop.git/info/refs"]}, []},
    {"paths: no path at all", [{:allow, "git.example", paths: []}], [], ["git.example"],
     %{"git.example" => []}, []},
    {"paths: the repository's rule decides the host whole",
     [{:allow, "git.example", paths: ["/a"]}], [{:allow, "git.example", paths: ["/b"]}],
     ["git.example"], %{"git.example" => ["/b"]}, []},
    {"paths: the repository opens every path", [{:allow, "git.example", paths: ["/a"]}],
     [{:allow, "git.example"}], ["git.example"], %{}, []},
    {"paths: a locked path list holds", [{:allow, "git.example", paths: ["/a"], locked: true}],
     [{:allow, "git.example"}], ["git.example"], %{"git.example" => ["/a"]}, []},
    {"paths: a name held to paths under a free suffix",
     [{:allow, "*.example"}, {:allow, "git.example", paths: ["/a"]}], [],
     ["git.example", "*.example"], %{"git.example" => ["/a"]}, []},
    {"credentials: selected by name, sorted, with an argument",
     [{:credential, "allow", "product", argument: "acme/shop"}, {:credential, "allow", "model"}],
     [], [], %{}, [%{name: "model"}, %{name: "product", argument: "acme/shop"}]},
    {"credentials: the repository's argument wins",
     [{:credential, "allow", "product", argument: "acme/shop"}],
     [{:credential, "allow", "product", argument: "acme/site"}], [], %{},
     [%{name: "product", argument: "acme/site"}]},
    {"credentials: the repository disables one", [{:credential, "allow", "model"}],
     [{:credential, "deny", "model"}], [], %{}, []},
    {"credentials: a locked deny holds", [{:credential, "deny", "model", locked: true}],
     [{:credential, "allow", "model"}], [], %{}, []}
  ]

  # {name, hive rules, repository rules, what the sentence says}
  @refused [
    {"an exact deny under an allowed suffix, both the hive's",
     [{:allow, "*.s.example"}, {:deny, "a.s.example"}], [], ~r/can only allow/},
    {"a repository's deny under the hive's suffix", [{:allow, "*.s.example"}],
     [{:deny, "a.s.example"}], ~r/a\.s\.example cannot be denied in the repository/},
    {"a locked deny under a repository's suffix", [{:deny, "a.s.example", locked: true}],
     [{:allow, "*.s.example"}], ~r/in the hive \(locked\)/},
    {"a narrower suffix denied under a wider one", [{:allow, "*.example"}],
     [{:deny, "*.s.example"}], ~r/can only allow/},
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

  for {name, hive, repository, allow, paths, credentials} <- @resolved,
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
      assert effective.paths == unquote(Macro.escape(paths))
      assert effective.credentials == unquote(Macro.escape(credentials))

      document = Render.document(effective)
      assert :ok = Schema.validate(document)
      assert document == Render.document(effective)

      policy = Jason.decode!(document)["security_policy"]
      assert policy["egress"]["allow"] == unquote(allow)
      # What the runner's proxy needs: a host in `paths` is in `allow`.
      assert Enum.all?(
               Map.keys(policy["egress"]["paths"] || %{}),
               &(&1 in policy["egress"]["allow"])
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
  end

  describe "rendering" do
    test "is the same bytes whatever order the rules come in" do
      rules = [allow("b.example"), allow("*.a.example"), allow("a.example", paths: ["/z", "/a"])]

      documents =
        for order <- [rules, Enum.reverse(rules)] do
          {:ok, effective} = Resolution.resolve("enforce", order, [])
          Render.document(effective)
        end

      assert [document, document] = documents

      assert document ==
               ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"enforce","allow":["a.example","b.example","*.a.example"],"paths":{"a.example":["/a","/z"]}}}})

      assert Render.digest(document) =~ ~r/\Asha256=[0-9a-f]{64}\z/
    end

    test "a hive with no rules renders observe and an empty allow" do
      {:ok, effective} = Resolution.resolve("observe", [], [])

      assert Render.document(effective) ==
               ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"observe","allow":[]}}})
    end
  end
end
