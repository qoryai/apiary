defmodule ApiaryWeb.PolicyLive.ReadingTest do
  use ExUnit.Case, async: true

  # The security policy: left out of a run without the security feature.
  @moduletag needs: :security

  alias Apiary.Policy.Entry
  alias ApiaryWeb.PolicyLive.Reading

  defp context(attrs \\ %{}) do
    Map.merge(
      %{scope: :workspace, own: [], entries: [], owner: true, locked_by: %{}},
      Map.new(attrs)
    )
  end

  defp read(form, context \\ context()) do
    Reading.host_rule(
      Map.merge(%{"action" => "allow", "paths" => "", "every" => "false"}, form),
      context
    )
  end

  defp flat(text) when is_binary(text), do: text
  defp flat({_tag, inner}), do: flat(inner)
  defp flat(list) when is_list(list), do: Enum.map_join(list, &flat/1)

  defp own(attrs) do
    Map.merge(
      %{
        kind: "host",
        action: "allow",
        host: nil,
        paths: nil,
        locked: false,
        by: "beekeeper",
        at: "2 Sep"
      },
      Map.new(attrs)
    )
  end

  defp entry(attrs),
    do:
      struct!(
        Entry,
        Map.merge(%{kind: :host, action: :allow, source: :workspace}, Map.new(attrs))
      )

  test "empty is the hint, and the form's preview asks for a host" do
    assert %{kind: :hint, preview: {:idle, idle}} = read(%{"host" => "  "})
    assert flat(idle) == "Type a host to see the rule in plain words before you add it."

    assert flat(Reading.hint().text) ==
             "The name runs connect to, in lower case, without https:// or a port. Start it with *. to cover every host below a domain, such as *.example.com."

    assert flat(Reading.paths_hint()) ==
             "Leave it empty to allow every path. Separate paths with spaces; end one with * for everything below it, such as /v1/*."

    # Sent with no host, the error is said under Host.
    assert %{kind: :error, invalid: [:host], errors: [{:host, text, nil}]} = Reading.empty_host()
    assert flat(text) == "Enter a host, such as api.example.com."
  end

  test "reads back a host, a suffix, paths and a deny" do
    assert flat(read(%{"host" => "api.example"}).text) ==
             "Allow api.example, on every path."

    assert flat(read(%{"host" => "*.internal.example"}).text) ==
             "Allow every host below internal.example, on every path. It does not allow internal.example itself."

    assert flat(read(%{"host" => "api.example", "paths" => "/v1/*  /health"}).text) =~
             "Allow api.example on 2 paths: everything below /v1/, and /health exactly."

    assert flat(read(%{"host" => "*.paste.example", "action" => "deny"}).text) ==
             "Deny every host below paste.example, and every allow rule it covers. It is denied in either mode, observe too."

    # The form's "What this rule does" is the same sentence.
    assert %{kind: :ok, invalid: [], button: nil, errors: [], preview: {:ok, text}} =
             reading = read(%{"host" => "api.example"})

    assert text == reading.text
  end

  test "a deny never reads paths" do
    assert %{kind: :ok} =
             read(%{"host" => "x.example", "action" => "deny", "paths" => "not a path"})
  end

  test "what is not in the grammar is an error on its field, with the repair when there is one" do
    assert %{
             kind: :error,
             invalid: [:host],
             fix:
               {"Use api.example with the path /v1/messages", "rule_use",
                %{"host" => "api.example", "paths" => "/v1/messages"}} = fix,
             errors: [{:host, _text, fix}],
             preview: {:idle, idle}
           } = read(%{"host" => "https://API.Example:443/v1/messages"})

    assert flat(idle) == "Fix the host to see the rule in plain words."

    assert %{fix: {"Use api.example", _, _}} = read(%{"host" => "API.example"})
    assert %{kind: :error, fix: nil} = read(%{"host" => "exa mple"})
    assert flat(read(%{"host" => "*"}).text) =~ "may only lead a host"
    assert flat(read(%{"host" => "a_b.example"}).text) =~ "Each part of a host"
    assert flat(read(%{"host" => "[::1]:80"}).text) =~ "An address is written like a host"
    assert flat(read(%{"host" => "10.0.0.12:443"}).text) =~ "An address is written like a host"

    assert %{kind: :error, invalid: [:paths], errors: [{:paths, _, nil}], preview: {:idle, idle}} =
             read(%{"host" => "api.example", "paths" => "v1"})

    assert flat(idle) == "Fix the paths to see the rule in plain words."

    # Both wrong: each is said under its own field, the host's first.
    assert %{invalid: [:host, :paths], errors: [{:host, _, _}, {:paths, _, _}]} =
             read(%{"host" => "a.*.example", "paths" => "/a?b"})
  end

  test "the same rule again, the opposite rule, other paths" do
    context =
      context(own: [own(host: "registry.example"), own(host: "api.example", paths: ["/v1/*"])])

    assert %{kind: :error, fix: {"Show it", "show_rule", %{"host" => "registry.example"}}} =
             reading = read(%{"host" => "registry.example"}, context)

    assert flat(reading.text) ==
             "registry.example is already allowed for the workspace, by beekeeper on 2 Sep."

    assert [{:host, _, {"Show it", _, _}}] = reading.errors

    assert flat(elem(reading.preview, 1)) ==
             "Nothing new: this rule is already in the list. To change its paths, edit it from its row."

    # On the Edit rule page the same rule is nothing to save, and no error under a field.
    assert %{kind: :error, errors: [], preview: {:idle, nothing}} =
             read(%{"host" => "registry.example"}, Map.put(context, :editing, true))

    assert flat(nothing) == "Nothing to save: the rule is as it was."

    assert %{kind: :note, button: "Replace with deny", preview: {:note, _}} =
             read(%{"host" => "registry.example", "action" => "deny"}, context)

    assert %{kind: :error, fix: {"Every path", "rule_every", _}, errors: [{:paths, _, _}]} =
             read(%{"host" => "api.example"}, context)

    assert %{kind: :note, button: "Change paths"} =
             read(%{"host" => "api.example", "every" => "true"}, context)

    assert %{kind: :note, button: "Change paths"} =
             read(%{"host" => "api.example", "paths" => "/v2/*"}, context)

    assert %{kind: :error} = read(%{"host" => "api.example", "paths" => "/v1/*"}, context)
  end

  test "covered by an allowed suffix is a note; a deny under it is said, with the suffix" do
    context = context(entries: [entry(host: "*.cdn.example")])

    assert %{kind: :note} = reading = read(%{"host" => "files.cdn.example"}, context)
    assert flat(reading.text) =~ "Already allowed by *.cdn.example."

    # A deny below an allowed suffix stands beside it: the gateway decides deny first.
    assert %{kind: :ok, acts: []} =
             reading = read(%{"host" => "files.cdn.example", "action" => "deny"}, context)

    assert flat(reading.text) ==
             "Deny files.cdn.example. It takes the host out of what the workspace allows; a repository can still allow it unless you lock this rule. It is denied in either mode, observe too. *.cdn.example still allows the other hosts below it."

    # A narrower suffix under a broader one is said the same way.
    assert %{kind: :ok} =
             reading = read(%{"host" => "*.eu.cdn.example", "action" => "deny"}, context)

    assert flat(reading.text) =~ "*.cdn.example still allows the other hosts below it."
    # A suffix that is out of force covers nothing.
    assert %{kind: :ok} =
             reading =
             read(
               %{"host" => "files.cdn.example", "action" => "deny"},
               context(entries: [entry(host: "*.cdn.example", in_force: false)])
             )

    refute flat(reading.text) =~ "still allows"
  end

  test "on a target page the workspace's suffix is said, a locked one refuses, and a lock refuses" do
    entries = [
      entry(host: "*.cdn.example"),
      entry(host: "*.paste.example", action: :deny, locked: true),
      entry(host: "github.example", locked: true),
      entry(host: "*.internal.example", locked: true)
    ]

    context =
      context(
        scope: :target,
        entries: entries,
        owner: false,
        locked_by: %{"*.paste.example" => %{by: "beekeeper@example.com", at: "2 Sep 2026"}}
      )

    assert %{kind: :ok} =
             reading = read(%{"host" => "files.cdn.example", "action" => "deny"}, context)

    assert flat(reading.text) =~ "*.cdn.example still allows the other hosts below it."

    # A locked allow of a suffix holds against a deny below it.
    assert %{kind: :refusal} =
             refusal = read(%{"host" => "tax.internal.example", "action" => "deny"}, context)

    assert flat(refusal.text) =~
             "A locked workspace rule allows *.internal.example. It holds against every repository, so a deny added here would change nothing."

    refusal = read(%{"host" => "bin.paste.example"}, context)
    assert refusal.kind == :refusal

    assert flat(refusal.text) ==
             "A locked workspace rule denies *.paste.example. It holds against every repository, so no rule added here would change what happens. Locked by beekeeper@example.com on 2 Sep 2026. Only an owner can change or unlock it."

    assert flat(read(%{"host" => "github.example", "action" => "deny"}, context).text) =~
             "A locked workspace rule allows github.example. It holds against every repository, so a deny added here would change nothing."

    assert flat(read(%{"host" => "bin.paste.example"}, %{context | owner: true}).text) =~
             "You can change or unlock it on the workspace's policy page."
  end

  test "a member cannot change a locked rule of the scope" do
    context = context(own: [own(host: "github.example", locked: true)], owner: false)

    assert %{kind: :refusal} =
             reading = read(%{"host" => "github.example", "action" => "deny"}, context)

    assert flat(reading.text) == "Only an owner can lock, unlock or change a locked rule."
    # A refusal takes the preview's place on the form.
    assert reading.preview == nil
  end

  test "a refusal of a locked rule says the edition's sentence of who may in place of the core's" do
    who = "Only the stub's owners lock, unlock or change a locked rule."

    context =
      context(own: [own(host: "github.example", locked: true)], owner: false, who_locks: who)

    assert flat(read(%{"host" => "github.example", "action" => "deny"}, context).text) == who

    target =
      context(
        scope: :target,
        entries: [entry(host: "*.paste.example", action: :deny, locked: true)],
        owner: false,
        who_locks: who
      )

    assert flat(read(%{"host" => "bin.paste.example"}, target).text) ==
             "A locked workspace rule denies *.paste.example. It holds against every repository, so no rule added here would change what happens. #{who}"

    # One who may change it is told where, whatever the edition says of who may.
    assert flat(read(%{"host" => "bin.paste.example"}, %{target | owner: true}).text) =~
             "You can change or unlock it on the workspace's policy page."
  end

  test "an address in another form than a.b.c.d is refused under Host, saying the form" do
    for host <- ~w(127.1 0x7f.0.0.1 010.0.0.1 10.0.0.256 2130706433 example.123 0X7F.0.0.1) do
      assert %{kind: :error, invalid: [:host], fix: nil, errors: [{:host, text, nil}]} =
               read(%{"host" => host})

      assert flat(text) ==
               "An address is four numbers from 0 to 255 with dots between them and no leading zeros, such as 10.0.0.12.",
             host

      assert [_, {:m, "10.0.0.12"}, _] = text
    end

    # The address in its one form is a host like any other.
    assert %{kind: :ok} = read(%{"host" => "10.0.0.12"})
  end

  test "*. before an address is refused: it leads a host name only" do
    for host <- ~w(*.0.0.1 *.10.0.0.1 *.127.1 *.example.123) do
      assert %{kind: :error, invalid: [:host], errors: [{:host, text, nil}]} =
               read(%{"host" => host})

      assert flat(text) == "*. leads a host name, never an address.", host
      assert [{:code, "*."}, _] = text
    end

    # A `*.` elsewhere is still the sentence it was.
    assert flat(read(%{"host" => "*.*.0.0.1"}).text) =~ "may only lead a host"
  end

  describe "a level above the workspace (scope :organisation)" do
    defp level(own, attrs \\ %{}),
      do: context(Map.merge(%{scope: :organisation, own: own}, Map.new(attrs)))

    defp said(form, context), do: flat(read(form, context).text)

    test "the same rule again says every workspace, with who and when where known" do
      for {action, word} <- [{"allow", "allowed"}, {"deny", "denied"}] do
        by = level([own(host: "a.example", action: action)])
        since = level([own(host: "a.example", action: action, by: nil)])
        nobody = level([own(host: "a.example", action: action, by: nil, at: nil)])
        form = %{"host" => "a.example", "action" => action}

        assert said(form, by) ==
                 "a.example is already #{word} for every workspace, by beekeeper on 2 Sep."

        assert said(form, since) ==
                 "a.example is already #{word} for every workspace, since 2 Sep."

        assert said(form, nobody) == "a.example is already #{word} for every workspace."
      end
    end

    test "the opposite rule, a host held to paths and other paths say every workspace" do
      context =
        level([
          own(host: "registry.example"),
          own(host: "paste.example", action: "deny"),
          own(host: "api.example", paths: ["/v1/*"])
        ])

      assert %{kind: :note, button: "Replace with deny"} =
               reading = read(%{"host" => "registry.example", "action" => "deny"}, context)

      assert flat(reading.text) ==
               "registry.example is allowed for every workspace. Adding this deny replaces that rule."

      assert %{kind: :note, button: "Replace with allow"} =
               reading = read(%{"host" => "paste.example"}, context)

      assert flat(reading.text) ==
               "paste.example is denied for every workspace. Adding this allow replaces that rule."

      assert %{kind: :error, fix: {"Every path", "rule_every", _}} =
               reading = read(%{"host" => "api.example"}, context)

      assert flat(reading.text) ==
               "api.example is held to /v1/* for every workspace. Name the paths it should have, or choose Every path to open them all."

      assert %{kind: :note, button: "Change paths"} =
               reading = read(%{"host" => "api.example", "paths" => "/v2/*"}, context)

      assert flat(reading.text) ==
               "api.example is allowed for every workspace on /v1/*. Saving changes its paths to /v2/*."
    end

    test "a deny of a host holds in every workspace and target; a suffix's reads as before" do
      context = level([])

      assert %{kind: :ok} =
               reading = read(%{"host" => "telemetry.example", "action" => "deny"}, context)

      assert flat(reading.text) ==
               "Deny telemetry.example. It holds in every workspace and repository, and no rule of theirs can allow it. It is denied in either mode, observe too."

      # The engine's words, the message as written.
      Gettext.with_locale(ApiaryWeb.Gettext, "en", fn ->
        assert said(%{"host" => "telemetry.example", "action" => "deny"}, context) =~
                 "Deny telemetry.example. It holds in every workspace and target, and no rule of theirs can allow it."
      end)

      assert said(%{"host" => "*.paste.example", "action" => "deny"}, context) =~
               "Deny every host below paste.example, and every allow rule it covers."
    end

    test "no locked rule of a workspace refuses it" do
      entries = [
        entry(host: "*.paste.example", action: :deny, locked: true),
        entry(host: "github.example", locked: true)
      ]

      context = level([], entries: entries, owner: false)

      assert %{kind: :ok} = read(%{"host" => "bin.paste.example"}, context)
      assert %{kind: :ok} = read(%{"host" => "github.example", "action" => "deny"}, context)

      # The same entries refuse on a target's page.
      assert %{kind: :refusal} =
               read(%{"host" => "bin.paste.example"}, %{context | scope: :target})
    end
  end
end
