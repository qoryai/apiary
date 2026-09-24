defmodule ApiaryWeb.PolicyLive.ReadingTest do
  use ExUnit.Case, async: true

  alias Apiary.Policy.Entry
  alias ApiaryWeb.PolicyLive.Reading

  defp context(attrs \\ %{}) do
    Map.merge(%{scope: :hive, own: [], entries: [], owner: true, locked_by: %{}}, Map.new(attrs))
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
        name: nil,
        argument: nil,
        paths: nil,
        locked: false,
        by: "beekeeper",
        at: "2 Sep"
      },
      Map.new(attrs)
    )
  end

  defp entry(attrs),
    do: struct!(Entry, Map.merge(%{kind: :host, action: :allow, source: :hive}, Map.new(attrs)))

  test "empty is the hint" do
    assert %{kind: :hint} = read(%{"host" => "  "})
    assert flat(Reading.hint().text) =~ "No scheme, no port."
  end

  test "reads back a host, a suffix, paths and a deny" do
    assert flat(read(%{"host" => "api.example"}).text) ==
             "Reads as: allow api.example, on every path."

    assert flat(read(%{"host" => "*.internal.example"}).text) ==
             "Reads as: allow every host below internal.example, on every path. It does not allow internal.example itself."

    assert flat(read(%{"host" => "api.example", "paths" => "/v1/*  /health"}).text) =~
             "allow api.example on 2 paths: everything below /v1/, and /health exactly."

    assert flat(read(%{"host" => "*.paste.example", "action" => "deny"}).text) ==
             "Reads as: deny every host below paste.example, and every allow rule it covers. It is denied in either mode, observe too."

    assert %{kind: :ok, invalid: [], button: nil} = read(%{"host" => "api.example"})
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
               {"Use api.example with the path /v1/messages", "composer_use",
                %{"host" => "api.example", "paths" => "/v1/messages"}}
           } =
             read(%{"host" => "https://API.Example:443/v1/messages"})

    assert %{fix: {"Use api.example", _, _}} = read(%{"host" => "API.example"})
    assert %{kind: :error, fix: nil} = read(%{"host" => "exa mple"})
    assert flat(read(%{"host" => "*"}).text) =~ "may only lead a host"
    assert flat(read(%{"host" => "a_b.example"}).text) =~ "Each part of a host"
    assert flat(read(%{"host" => "[::1]:80"}).text) =~ "An address is written like a host"
    assert %{kind: :error, invalid: [:paths]} = read(%{"host" => "api.example", "paths" => "v1"})
    assert %{invalid: [:host, :paths]} = read(%{"host" => "a.*.example", "paths" => "/a?b"})
  end

  test "the same rule again, the opposite rule, other paths" do
    context =
      context(own: [own(host: "registry.example"), own(host: "api.example", paths: ["/v1/*"])])

    assert %{kind: :error, fix: {"Show it", "show_rule", %{"host" => "registry.example"}}} =
             reading = read(%{"host" => "registry.example"}, context)

    assert flat(reading.text) ==
             "registry.example is already allowed for the workplace, by beekeeper on 2 Sep."

    assert %{kind: :note, button: "Replace with deny"} =
             read(%{"host" => "registry.example", "action" => "deny"}, context)

    assert %{kind: :error, fix: {"Every path", "composer_every", _}} =
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

    # A deny below an allowed suffix stands beside it: the runner decides deny first.
    assert %{kind: :ok, acts: []} =
             reading = read(%{"host" => "files.cdn.example", "action" => "deny"}, context)

    assert flat(reading.text) ==
             "Reads as: deny files.cdn.example. It takes the host out of what the workplace allows; a repository can still allow it unless you lock this rule. It is denied in either mode, observe too. *.cdn.example still allows the other hosts below it."

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

  test "on a target page the hive's suffix is said, a locked one refuses, and a lock refuses" do
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
             "A locked workplace rule allows *.internal.example. It holds against every repository, so a deny added here would change nothing."

    refusal = read(%{"host" => "bin.paste.example"}, context)
    assert refusal.kind == :refusal

    assert flat(refusal.text) ==
             "A locked workplace rule denies *.paste.example. It holds against every repository, so no rule added here would change what happens. Locked by beekeeper@example.com on 2 Sep 2026. Only an owner can change or unlock it."

    assert flat(read(%{"host" => "github.example", "action" => "deny"}, context).text) =~
             "A locked workplace rule allows github.example. It holds against every repository, so a deny added here would change nothing."

    assert flat(read(%{"host" => "bin.paste.example"}, %{context | owner: true}).text) =~
             "You can change or unlock it on the workplace's policy page."
  end

  test "a member cannot change a locked rule of the scope" do
    context = context(own: [own(host: "github.example", locked: true)], owner: false)

    assert %{kind: :refusal} =
             reading = read(%{"host" => "github.example", "action" => "deny"}, context)

    assert flat(reading.text) == "Only an owner can lock, unlock or change a locked rule."
  end

  test "a credential: its name, its argument, one already named" do
    assert %{kind: :hint} = Reading.credential(%{"name" => ""}, [])

    assert %{kind: :ok} =
             Reading.credential(%{"name" => "forge-token", "argument" => "acme/shop"}, [])

    assert %{kind: :error, invalid: [:name]} = Reading.credential(%{"name" => "Forge"}, [])

    assert %{kind: :error, invalid: [:argument]} =
             Reading.credential(%{"name" => "k", "argument" => String.duplicate("a", 257)}, [])

    named = [own(kind: "credential", name: "model-key")]
    assert %{kind: :error} = Reading.credential(%{"name" => "model-key"}, named)
    assert %{kind: :note} = Reading.credential(%{"name" => "model-key", "argument" => "x"}, named)
  end
end
